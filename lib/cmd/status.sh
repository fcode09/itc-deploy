#!/usr/bin/env bash
# ./deltactl status [instance] [--json] [--stats] [--strict] [--watch [seconds]]
# Status panel: for every instance and active service it shows the configured tag, the running one,
# the health, the port, the uptime, the data state and the mismatches found.
# It is READ-ONLY: it never modifies instances or containers.

status_table() { # [instance]
  local only="${1:-}" f name svc first stats
  local -a widths=(16 4 10 10 17 6 8 12) row=() orphans=()
  local -a head=("$(t status.col.instance)" SVC "$(t status.col.config)" "$(t status.col.running)" "$(t status.col.state)" \
    "$(t status.col.port)" UPTIME "$(t status.col.data)")
  if [ "$STATUS_STATS" -eq 1 ]; then widths+=(17 7); head+=("$(t status.col.memory)" CPU); fi
  widths+=(20)
  head+=("$(t status.col.notes)")
  ui_table_cols "${widths[@]}"
  ui_th "${head[@]}"
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    name="$(basename "$(dirname "$f")")"
    [ -z "$only" ] || [ "$only" = "$name" ] || continue
    STATUS_INSTANCES=$((STATUS_INSTANCES + 1))
    st_enabled "$name"
    st_instance_hints "$name"
    first=1
    if [ "${#ST_ENABLED[@]}" -eq 0 ]; then
      ui_tr "bold:$name" "-" "-" "-" "err:$(t status.state.empty_profile)" "-" "-" "-" "$(t status.empty_profile_note)"
      STATUS_ISSUES=$((STATUS_ISSUES + 1))
      continue
    fi
    for svc in "${ST_ENABLED[@]}"; do
      st_eval "$name" "$svc"
      st_notes "$name" "$svc"
      STATUS_SERVICES=$((STATUS_SERVICES + 1))
      case "$E_KIND" in warn | err) STATUS_ISSUES=$((STATUS_ISSUES + 1)) ;; esac
      row=()
      if [ "$first" -eq 1 ]; then row+=("bold:$name"); else row+=("dim:$name"); fi
      first=0
      row+=("$svc")
      if [ -n "$E_CFG" ]; then row+=("$E_CFG"); else row+=("err:$(t status.empty_paren)"); fi
      case " $E_CODES " in *" tag-drift "*) row+=("warn:$E_RUN") ;; *) row+=("$E_RUN") ;; esac
      row+=("st-$E_KIND:$E_TEXT")
      case " $E_CODES " in *" port-conflict "*) row+=("err:$E_PORT") ;; *) row+=("$E_PORT") ;; esac
      row+=("${E_UP:--}")
      if [ "$E_DATA" = "unseeded" ]; then row+=("warn:$(data_label "$E_DATA")"); else row+=("$(data_label "$E_DATA")"); fi
      if [ "$STATUS_STATS" -eq 1 ]; then
        stats="$(st_stats_cells "$name" "$svc")"
        row+=("${stats%%|*}" "${stats#*|}")
      fi
      row+=("dim:$E_NOTES")
      ui_tr "${row[@]}"
    done
    mapfile -t orphans < <(st_orphans "$name")
    for svc in ${orphans[@]+"${orphans[@]}"}; do
      ui_tr "dim:$name" "$svc" "-" "-" "st-warn:$(t status.state.orphan)" "-" "-" "-" "warn:$(t status.orphan_note)"
      STATUS_ISSUES=$((STATUS_ISSUES + 1))
      STATUS_SERVICES=$((STATUS_SERVICES + 1))
      st_hint "./deltactl stop $name $svc" "$(t status.hint.orphan "$svc" "$name")"
    done
  done
  if [ "$STATUS_INSTANCES" -eq 0 ]; then
    if [ -n "$only" ]; then die "$(t err.instance_not_found "$only")"; fi
    info "$(t status.none)"
    st_hint "$(t status.hint.new_cmd)" "$(t status.hint.new_first)"
  fi
}

# JSON output (without depending on jq). Every text is a code, never translated: data is
# init | existing | unseeded, status is ok | warn | err | dim, issues are the mismatch codes.
status_json() { # [instance]
  local only="${1:-}" f name svc first=1 codes c cfirst up
  printf '[\n'
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    name="$(basename "$(dirname "$f")")"
    [ -z "$only" ] || [ "$only" = "$name" ] || continue
    st_enabled "$name"
    for svc in ${ST_ENABLED[@]+"${ST_ENABLED[@]}"}; do
      st_eval "$name" "$svc"
      st_notes "$name" "$svc"
      case "$E_KIND" in warn | err) STATUS_ISSUES=$((STATUS_ISSUES + 1)) ;; esac
      [ "$first" -eq 1 ] || printf ',\n'
      first=0
      up="${E_UPSECS:-null}"
      codes=""
      cfirst=1
      for c in $E_CODES; do
        [ "$cfirst" -eq 1 ] || codes+=","
        cfirst=0
        codes+="\"$(ui_json_escape "$c")\""
      done
      printf '  {"instance":"%s","service":"%s","configured_tag":"%s","running_tag":"%s","deployed_tag":"%s","previous_tag":"%s","state":"%s","health":"%s","status":"%s","port":"%s","uptime_seconds":%s,"data":"%s","issues":[%s]}' \
        "$(ui_json_escape "$name")" "$svc" "$(ui_json_escape "$E_CFG")" "$(ui_json_escape "$E_RUN")" \
        "$(ui_json_escape "$E_DEP")" "$(ui_json_escape "$E_PREV")" "$(ui_json_escape "$E_STATE")" \
        "$(ui_json_escape "$E_HEALTH")" "$(ui_json_escape "$E_KIND")" "$(ui_json_escape "$E_PORT")" \
        "$up" "$(ui_json_escape "$E_DATA")" "$codes"
    done
  done
  printf '\n]\n'
}

# Detail view of an instance.
status_detail() { # instance
  local name="$1" dir svc marker raw errs
  dir="$(instance_dir "$name")"
  st_enabled "$name"
  st_instance_hints "$name"
  STATUS_INSTANCES=1
  marker="$(marker_file "$name")"
  ui_h1 "$(t status.detail.title "$name")"
  ui_kv "$(t status.kv.services)" "$(IFS=,; echo "${ST_ENABLED[*]:-}")"
  if [ -f "$marker" ]; then
    ui_kv "$(t status.kv.data)" "$(t status.detail.data_since "$(get_var "$marker" SOURCE)" "$(get_var "$marker" INITIALIZED_AT)")"
  else
    ui_kv "$(t status.kv.data)" "$(data_label unseeded)"
  fi
  ui_kv "$(t status.kv.images)" "$(if uses_local_images "$name"; then t status.detail.images_local; else t status.detail.images_registry "$(get_var "$dir/.env.instance" REGISTRY)"; fi)"
  ui_kv "$(t status.kv.folder)" "instances/$name"
  for svc in ${ST_ENABLED[@]+"${ST_ENABLED[@]}"}; do
    st_eval "$name" "$svc"
    st_notes "$name" "$svc"
    STATUS_SERVICES=$((STATUS_SERVICES + 1))
    case "$E_KIND" in warn | err) STATUS_ISSUES=$((STATUS_ISSUES + 1)) ;; esac
    ui_h2 "$(t status.detail.service "$svc")"
    printf '  %s%-14s%s ' "$C_GRY" "$(t status.kv.state)" "$C_OFF"
    ui_cell 12 "st-$E_KIND" "$E_TEXT" 1
    [ -z "$E_UP" ] || printf '  %s' "$(t status.detail.since "$E_UP")"
    printf '\n'
    ui_kv "$(t status.kv.version)" "$(t status.detail.version "${E_CFG:-$(t status.empty_paren)}" "$E_RUN" "${E_DEP:--}")"
    ui_kv "$(t status.kv.image)" "$E_REF"
    if [ -n "$E_PREV" ] && [ "$E_PREV" != "$E_CFG" ]; then
      ui_kv "$(t status.kv.previous)" "$(t status.detail.previous "$E_PREV" "$name" "$svc")"
    fi
    ui_kv "$(t status.kv.port)" "$(t status.detail.port "$E_PORT")"
    if [ "$ST_DOCKER" -eq 1 ] && [ "$E_STATE" = "running" ]; then
      raw="$(st_stats_cells "$name" "$svc")"
      ui_kv "$(t status.kv.resources)" "$(t status.detail.resources "${raw%%|*}" "${raw#*|}")"
      errs="$(dk_log_error_count "${ST_CNAME[$name/$svc]}")"
      ui_kv "$(t status.kv.errors)" "$(t status.detail.errors "${errs:-0}" "$name" "$svc")"
    fi
    [ -z "$E_NOTES" ] || ui_kv "$(t status.kv.notes)" "$E_NOTES"
  done
}

status_footer() {
  local h cmd why
  printf '\n'
  if [ "$STATUS_ISSUES" -eq 0 ]; then
    printf '  %s %s%s%s\n' "$(ui_sym ok)" "$C_GRN" "$(t status.footer.ok "$STATUS_INSTANCES" "$STATUS_SERVICES")" "$C_OFF"
  else
    printf '  %s %s%s%s\n' "$(ui_sym warn)" "$C_YEL" "$(t status.footer.issues "$STATUS_INSTANCES" "$STATUS_SERVICES" "$STATUS_ISSUES")" "$C_OFF"
  fi
  if [ "${#HINTS[@]}" -gt 0 ]; then
    printf '\n  %s%s%s\n' "$C_BLD" "$(t status.footer.next_steps)" "$C_OFF"
    for h in "${HINTS[@]}"; do
      cmd="${h%%|*}"
      why="${h#*|}"
      printf '  %s%s%s %s%s%s  %s# %s%s\n' "$C_CYN" "$UI_S_ARROW" "$C_OFF" "$C_GRN" "$cmd" "$C_OFF" "$C_GRY" "$why" "$C_OFF"
    done
  fi
}

# Header of the status screen: host, memory, load and Docker, then the n/m of every instance
# (n services fully OK out of the m that should run).
status_header() {
  local sep line host total avail pct cells=10 v f name n m kind strip=""
  sep="  $UI_S_DOT  "
  host="$(host_name)"
  [ -n "$host" ] || host="$(t ui.host_fallback)"
  line="  $C_BLD$host$C_OFF"
  total="$(host_mem_total_kb)"
  avail="$(host_mem_available_kb)"
  # Without both figures (a system that does not report MemAvailable) the memory is left out, not guessed.
  if [[ "$total" =~ ^[0-9]+$ ]] && [[ "$avail" =~ ^[0-9]+$ ]] && [ "$total" -gt 0 ]; then
    pct=$(((total - avail) * 100 / total))
    [ "$UI_W" -ge 70 ] || cells=6
    line+="$sep$C_GRY$(t status.hdr.memory)$C_OFF $(ui_bar "$pct" "$cells") $(host_kb_to_gb $((total - avail)))/$(host_kb_to_gb "$total") GB $pct%"
  fi
  v="$(host_load1)"
  [ -z "$v" ] || line+="$sep$C_GRY$(t status.hdr.load)$C_OFF $v"
  if [ "$ST_DOCKER" -eq 1 ]; then
    v="$(dk_info ServerVersion)"
    [ -z "$v" ] || line+="$sep${C_GRY}Docker$C_OFF $v"
  fi
  printf '\n%s\n' "$line"
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    name="$(basename "$(dirname "$f")")"
    read -r n m kind <<< "$(st_instance_counts "$name")"
    strip+="${strip:+$sep}$(ui_sym "$kind") $name $C_BLD$n/$m$C_OFF"
  done
  [ -z "$strip" ] || printf '  %s%s%s %s\n' "$C_GRY" "$(t status.hdr.instances)" "$C_OFF" "$strip"
}

status_once() { # instance
  local name="${1:-}"
  HINTS=() HINT_SEEN=() STATUS_ISSUES=0 STATUS_SERVICES=0 STATUS_INSTANCES=0
  st_collect
  st_load_ports
  [ "$ST_DOCKER" -eq 1 ] || warn "$(t status.no_docker)"
  if [ "$STATUS_STATS" -eq 1 ] || { [ -n "$name" ] && [ "$STATUS_FORMAT" != "json" ]; }; then st_collect_stats; fi
  if [ "$STATUS_FORMAT" = "json" ]; then
    status_json "$name"
    return 0
  fi
  if [ -n "$name" ]; then
    status_detail "$name"
  else
    status_header
    ui_h1 "$(t status.title)"
    status_table
  fi
  status_footer
}

cmd_status() {
  local name="" a interval=2
  STATUS_FORMAT=table STATUS_STATS=0
  local strict=0 watch=0
  while [ "$#" -gt 0 ]; do
    a="$1"
    case "$a" in
      --json) STATUS_FORMAT=json ;;
      --stats) STATUS_STATS=1 ;;
      --strict) strict=1 ;;
      --watch)
        watch=1
        if [ "$#" -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]]; then interval="$2"; shift; fi
        ;;
      -*) die "$(t status.unknown_option "$a")" ;;
      *)
        [ -z "$name" ] || die "$(t status.extra_arg "$a")"
        name="$a"
        ;;
    esac
    shift
  done
  if [ -n "$name" ]; then require_instance "$name"; fi

  if [ "$watch" -eq 1 ]; then
    [ "$UI_RICH" -eq 1 ] && [ "$STATUS_FORMAT" != "json" ] || die "$(t status.watch_needs_tty)"
    trap 'printf "\n"; exit 0' INT
    while true; do
      printf '\033[H\033[2J'
      ui_banner "$(t status.live_subtitle "$interval")"
      status_once "$name"
      sleep "$interval"
    done
  fi

  status_once "$name"
  if [ "$strict" -eq 1 ] && [ "$STATUS_ISSUES" -gt 0 ]; then return 2; fi
  return 0
}

# Home screen: ./deltactl without arguments in a terminal.
cmd_home() {
  ui_banner
  STATUS_FORMAT=table STATUS_STATS=0
  status_once ""
  printf '\n  %s%s%s ./deltactl help   %s%s%s ./deltactl menu   %s%s%s ./deltactl help %s\n\n' \
    "$C_GRY" "$(t status.home.help)" "$C_OFF" "$C_GRY" "$(t status.home.menu)" "$C_OFF" \
    "$C_GRY" "$(t status.home.guide)" "$C_OFF" "$(topic_label new-instance)"
}

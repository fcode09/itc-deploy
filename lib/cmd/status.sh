#!/usr/bin/env bash
# ./deltactl status [instance] [--json] [--stats] [--strict] [--watch [seconds]]
# Status panel: for every instance and active service it shows the configured tag, the running one,
# the health, the port, the uptime, the data state and the mismatches found.
# It is READ-ONLY: it never modifies instances or containers.

# State of the containers indexed by "<project>/<service>". The Compose project is the name of the
# instance, so they are not mixed with other projects of the server.
declare -A ST_STATE=() ST_HEALTH=() ST_CIMAGE=() ST_STARTED=() ST_CNAME=() ST_STATS=()
declare -A ST_PORTS=() HINT_SEEN=()
ST_DOCKER=0
HINTS=()
STATUS_ISSUES=0
STATUS_SERVICES=0
STATUS_INSTANCES=0

# A single query to Docker for all the containers of Compose projects.
st_collect() {
  ST_STATE=() ST_HEALTH=() ST_CIMAGE=() ST_STARTED=() ST_CNAME=() ST_STATS=()
  ST_DOCKER=0
  dk_ready || return 0
  ST_DOCKER=1
  local -a ids=()
  local proj svc state health image started cname
  mapfile -t ids < <(dk_project_container_ids)
  [ "${#ids[@]}" -gt 0 ] || return 0
  while IFS='|' read -r proj svc state health image started cname; do
    [ -n "$proj" ] && [ -n "$svc" ] || continue
    ST_STATE["$proj/$svc"]="$state"
    ST_HEALTH["$proj/$svc"]="$health"
    ST_CIMAGE["$proj/$svc"]="$image"
    ST_STARTED["$proj/$svc"]="$started"
    ST_CNAME["$proj/$svc"]="${cname#/}"
  done < <(dk_container_rows "${ids[@]}")
}

# Memory and CPU usage of the running containers (takes 1-2 s: only with --stats or in the detail view).
st_collect_stats() {
  ST_STATS=()
  [ "$ST_DOCKER" -eq 1 ] || return 0
  local name mem cpu
  while IFS='|' read -r name mem cpu; do
    [ -n "$name" ] || continue
    ST_STATS["$name"]="${mem// /}|$cpu"
  done < <(dk_stats_rows)
}

# 3725 -> 1h02m
st_duration() { # seconds
  local s="$1" d h m
  [[ "$s" =~ ^[0-9]+$ ]] || { printf -- '-'; return 0; }
  d=$((s / 86400)); h=$(((s % 86400) / 3600)); m=$(((s % 3600) / 60))
  if [ "$d" -gt 0 ]; then printf '%dd%02dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf '%dm' "$m"
  else printf '%ds' "$s"; fi
}

# Seconds elapsed since an ISO 8601 instant (containers report StartedAt in UTC).
st_uptime_secs() { # iso
  local t now
  t="$(date -d "$1" +%s 2>/dev/null)" || return 1
  now="$(date +%s)"
  [ "$t" -gt 0 ] && [ "$now" -ge "$t" ] || return 1
  printf '%s' "$((now - t))"
}

# Records a next-step suggestion (without repeating it).
st_hint() { # command reason
  [ -z "${HINT_SEEN[$1]:-}" ] || return 0
  HINT_SEEN["$1"]=1
  HINTS+=("$1|$2")
}

# Active services of an instance, error tolerant (it does not abort the panel if a file is wrong).
ST_ENABLED=()
st_enabled() { # instance
  ST_ENABLED=()
  local raw part
  local -a parts=()
  raw="$(get_var "$(instance_dir "$1")/.env.instance" COMPOSE_PROFILES)"
  IFS=',' read -ra parts <<< "$raw"
  for part in ${parts[@]+"${parts[@]}"}; do
    part="${part// /}"
    if [ -n "$part" ] && valid_service "$part"; then ST_ENABLED+=("$part"); fi
  done
}

# Image reference that Compose would use for the service (the same rule as the compose files).
st_ref() { # instance service
  local dir reg tag
  dir="$(instance_dir "$1")"
  reg="$(get_var "$dir/.env.instance" REGISTRY)"
  tag="$(get_var "$dir/.env.instance" "$(tag_var "$2")")"
  printf '%s%s:%s' "${reg:+$reg/}" "$(service_repo "$2" "$1")" "$tag"
}

# Tag of a reference "[registry/]name:tag"; empty if it has none.
st_tag_of() {
  local last="${1##*/}"
  case "$last" in *:*) printf '%s' "${last##*:}" ;; *) printf '' ;; esac
}

# Map port -> "instance/service" of the active services, to detect repeated ports.
st_load_ports() {
  ST_PORTS=()
  local f name svc p
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    name="$(basename "$(dirname "$f")")"
    st_enabled "$name"
    for svc in ${ST_ENABLED[@]+"${ST_ENABLED[@]}"}; do
      p="$(get_var "$f" "${svc^^}_PORT")"
      [ -n "$p" ] || continue
      ST_PORTS["$p"]="${ST_PORTS[$p]:+${ST_PORTS[$p]} }$name/$svc"
    done
  done
}

# Evaluates a row: it leaves the result in the E_* variables.
#   E_KIND/E_TEXT  state (ok|warn|err|dim) and its text     E_CODES  mismatch codes
#   E_CFG/E_RUN/E_DEP/E_PREV  configured, running, deployed and previous tags
#   E_DATA         data state code: init | existing | unseeded (translated only when shown)
E_KIND="" E_TEXT="" E_CODES="" E_CFG="" E_RUN="" E_DEP="" E_PREV="" E_PORT="" E_UP="" E_UPSECS=""
E_DATA="" E_NOTES="" E_REF="" E_HEALTH="" E_STATE=""
st_eval() { # instance service
  local name="$1" svc="$2" dir key f cur_id dep_id owners
  dir="$(instance_dir "$name")"
  f="$dir/.env.instance"
  key="$name/$svc"
  E_KIND="" E_TEXT="" E_CODES="" E_NOTES="" E_UP="" E_UPSECS=""
  E_CFG="$(get_var "$f" "$(tag_var "$svc")")"
  E_PORT="$(get_var "$f" "${svc^^}_PORT")"
  E_DEP="$(get_var "$dir/.deployed" "$(tag_var "$svc")")"
  E_PREV="$(get_var "$dir/.previous" "$(tag_var "$svc")")"
  E_REF="$(st_ref "$name" "$svc")"
  E_STATE="${ST_STATE[$key]:-}"
  E_HEALTH="${ST_HEALTH[$key]:-}"
  E_RUN="-"
  E_DATA="$(data_state "$name")"

  if [ "$ST_DOCKER" -eq 0 ]; then
    E_KIND=warn E_TEXT="$(t status.state.no_docker)"
    return 0
  fi

  if [ -z "$E_STATE" ]; then
    E_KIND=dim E_TEXT="$(t status.state.not_created)"
    E_CODES="not-created"
  else
    local rt
    rt="$(st_tag_of "${ST_CIMAGE[$key]:-}")"
    E_RUN="${rt:-?}"
    case "$E_STATE" in
      running)
        case "$E_HEALTH" in
          healthy) E_KIND=ok E_TEXT=healthy ;;
          starting) E_KIND=warn E_TEXT=starting E_CODES+=" starting" ;;
          unhealthy) E_KIND=err E_TEXT=unhealthy E_CODES+=" unhealthy" ;;
          *) E_KIND=ok E_TEXT=running ;;
        esac
        E_UPSECS="$(st_uptime_secs "${ST_STARTED[$key]:-}" 2>/dev/null || true)"
        E_UP="$(st_duration "$E_UPSECS")"
        ;;
      restarting) E_KIND=err E_TEXT="$(t status.state.restarting)" E_CODES+=" restarting" ;;
      exited | dead) E_KIND=warn E_TEXT="$(t status.state.stopped)" E_CODES+=" stopped" ;;
      *) E_KIND=warn E_TEXT="$E_STATE" E_CODES+=" stopped" ;;
    esac
    # The running tag is not the configured one: a `deploy` is missing.
    if [ -n "$rt" ] && [ -n "$E_CFG" ] && [ "$rt" != "$E_CFG" ]; then
      E_CODES+=" tag-drift"
      [ "$E_KIND" = "err" ] || E_KIND=warn
    fi
  fi

  # Local image: it must exist, and its tag must not have moved to another image since the deploy.
  if uses_local_images "$name" && [ -n "$E_CFG" ]; then
    if ! dk_image_exists "$E_REF"; then
      E_CODES+=" image-missing"
      [ "$E_KIND" = "err" ] || E_KIND=warn
    else
      dep_id="$(get_var "$dir/.deployed" "${svc^^}_IMAGE_ID")"
      if [ -n "$dep_id" ] && [ "$E_DEP" = "$E_CFG" ]; then
        cur_id="$(dk_image_id "$E_REF")"
        if [ -n "$cur_id" ] && [ "$cur_id" != "$dep_id" ]; then
          E_CODES+=" image-rebuilt"
          [ "$E_KIND" = "err" ] || E_KIND=warn
        fi
      fi
    fi
  fi

  # Port repeated with another instance or service.
  owners=""
  [ -z "$E_PORT" ] || owners="${ST_PORTS[$E_PORT]:-}"
  if [ -n "$owners" ] && [ "$owners" != "$name/$svc" ]; then
    E_CODES+=" port-conflict"
    E_KIND=err
  fi

  E_CODES="${E_CODES# }"
  [ -n "$E_KIND" ] || E_KIND=ok
}

# Readable text of the mismatch codes of the current row (and next-step suggestions).
st_notes() { # instance service
  local name="$1" svc="$2" code notes="" owners
  for code in $E_CODES; do
    case "$code" in
      tag-drift)
        notes+="$(t status.note.drift "$E_CFG" "$E_RUN"); "
        st_hint "./deltactl deploy $name $svc" "$(t status.hint.drift "$name" "$svc" "$E_RUN" "$E_CFG")"
        ;;
      image-rebuilt)
        notes+="$(t status.note.rebuilt "$E_CFG"); "
        st_hint "./deltactl deploy $name $svc" "$(t status.hint.rebuilt "$name" "$svc")"
        ;;
      image-missing)
        notes+="$(t status.note.missing "$E_REF"); "
        st_hint "$(t status.hint.load_cmd)" "$(t status.hint.load "$E_REF")"
        ;;
      port-conflict)
        owners=""
        [ -z "$E_PORT" ] || owners="${ST_PORTS[$E_PORT]:-}"
        notes+="$(t status.note.port "$E_PORT" "$owners"); "
        st_hint "$(t status.hint.port_cmd "$name")" "$(t status.hint.port "$E_PORT" "$owners")"
        ;;
      stopped)
        notes+="$(t status.note.stopped); "
        st_hint "./deltactl deploy $name $svc" "$(t status.hint.stopped "$name" "$svc")"
        ;;
      unhealthy | restarting)
        notes+="$(t status.note.unhealthy); "
        st_hint "./deltactl logs $name $svc" "$(t status.hint.unhealthy "$name" "$svc")"
        ;;
      not-created)
        st_hint "./deltactl deploy $name" "$(t status.hint.not_created "$name")"
        ;;
    esac
  done
  if [ -n "$E_PREV" ] && [ "$E_PREV" != "$E_CFG" ]; then notes+="$(t status.note.previous "$E_PREV"); "; fi
  E_NOTES="${notes%; }"
}

# Hints at instance level (not service level).
st_instance_hints() { # instance
  local name="$1" marker
  marker="$(marker_file "$name")"
  if [ ! -f "$marker" ]; then
    st_hint "./deltactl init $name" "$(t status.hint.no_data "$name")"
  fi
}

# Services that run in the instance but are no longer in COMPOSE_PROFILES.
st_orphans() { # instance
  local name="$1" key svc s found
  for key in "${!ST_STATE[@]}"; do
    [ "${key%%/*}" = "$name" ] || continue
    svc="${key#*/}"
    found=0
    for s in ${ST_ENABLED[@]+"${ST_ENABLED[@]}"}; do [ "$s" = "$svc" ] && found=1; done
    [ "$found" -eq 1 ] && continue
    [ "${ST_STATE[$key]}" = "running" ] || continue
    printf '%s\n' "$svc"
  done
}

st_stats_cells() { # instance service -> "mem|cpu" ("-|-" if the container does not exist)
  local cn="${ST_CNAME[$1/$2]:-}"
  [ -n "$cn" ] || { printf '%s' '-|-'; return 0; }
  printf '%s' "${ST_STATS[$cn]:--|-}"
}

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

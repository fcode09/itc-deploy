#!/usr/bin/env bash
# ./deltactl doctor
# Server diagnosis, READ-ONLY: Docker and Compose, disk, memory, Mongo, instance permissions and helper
# tools. Every failure says how to fix it. It exits with code 1 if there are errors.

# ck (report with symbols) comes from check.sh
source "$ROOT/lib/cmd/check.sh"

# 512m -> 512, 2g -> 2048, 1.5g -> 1536 (megabytes)
dr_mem_mb() { # value
  awk -v v="$1" 'BEGIN {
    u = tolower(substr(v, length(v))); n = substr(v, 1, length(v) - 1) + 0
    if (u == "g") n *= 1024; else if (u == "k") n /= 1024; else if (u != "m") n = v / 1048576
    printf "%d", n }'
}

# Can a TCP connection be opened? (3 s limit, no external tools)
dr_tcp() { # host port
  timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" >/dev/null 2>&1
}

# Host and port of a URI mongodb://[user:password@]host[:port]/database
dr_mongo_hostport() { # uri -> "host port"
  local u="${1#*://}" h p
  u="${u#*@}"
  u="${u%%/*}"
  u="${u%%,*}"
  h="${u%%:*}"
  p="${u##*:}"
  [ "$p" != "$u" ] || p=27017
  printf '%s %s' "$h" "$p"
}

dr_kb_to_gb() { awk -v k="$1" 'BEGIN { printf "%.1f", k / 1048576 }'; }

cmd_doctor() {
  [ "$#" -eq 0 ] || die "$(t doctor.no_args)"
  local v cv root free total avail line f name svc raw mb sum=0 gw h p seen="" uri var pid lim

  ui_h1 "$(t doctor.title)"

  # --- Docker ------------------------------------------------------------------------------
  ui_h2 "$(t doctor.sec.docker)"
  if ! dk_installed; then
    ck err "$(t doctor.docker_missing)" "$(t doctor.docker_missing_hint)"
  elif ! dk_daemon_ok; then
    ck err "$(t doctor.daemon_down)" \
      "$(t doctor.daemon_down_hint1)" "$(t doctor.daemon_down_hint2)"
  else
    v="$(dk_info ServerVersion)"
    ck ok "$(t doctor.docker_ok "$v" "$(server_arch)")"
    cv="$(dk_compose_version)"
    if [ -z "$cv" ]; then
      ck err "$(t doctor.compose_missing)" "$(t doctor.compose_missing_hint)"
    elif [ "$(printf '%s\n%s\n' 2.20.0 "$cv" | sort -V | head -n1)" != "2.20.0" ]; then
      ck err "$(t doctor.compose_old "$cv")" "$(t doctor.compose_old_hint)"
    else
      ck ok "$(t doctor.compose_ok "$cv")"
    fi
  fi

  # --- Resources ---------------------------------------------------------------------------
  ui_h2 "$(t doctor.sec.resources)"
  root="$(dk_info DockerRootDir)"
  [ -n "$root" ] && [ -d "$root" ] || root="$ROOT"
  free="$(host_free_kb "$root")"
  if [[ "${free:-}" =~ ^[0-9]+$ ]]; then
    if [ "$free" -lt 3145728 ]; then
      ck err "$(t doctor.disk_low "$root" "$(dr_kb_to_gb "$free")")" "$(t doctor.disk_low_hint)"
    elif [ "$free" -lt 10485760 ]; then
      ck warn "$(t doctor.disk_warn "$root" "$(dr_kb_to_gb "$free")")"
    else
      ck ok "$(t doctor.disk_ok "$root" "$(dr_kb_to_gb "$free")")"
    fi
  else
    ck info "$(t doctor.disk_unknown)"
  fi

  total="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || true)"
  avail="$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo 2>/dev/null || true)"
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    name="$(basename "$(dirname "$f")")"
    st_enabled "$name" 2>/dev/null || ST_ENABLED=()
    for svc in ${ST_ENABLED[@]+"${ST_ENABLED[@]}"}; do
      raw="$(get_var "$f" "${svc^^}_MEM_LIMIT")"
      [ -n "$raw" ] || continue
      mb="$(dr_mem_mb "$raw")"
      sum=$((sum + mb))
    done
  done
  if [[ "${total:-}" =~ ^[0-9]+$ ]]; then
    ck ok "$(t doctor.mem_ok "$((total / 1024))" "$((${avail:-0} / 1024))")"
    if [ "$sum" -gt $((total / 1024)) ]; then
      ck warn "$(t doctor.mem_over "$sum")" "$(t doctor.mem_over_hint)"
    elif [ "$sum" -gt 0 ]; then
      ck ok "$(t doctor.mem_limits "$sum")"
    fi
  else
    ck info "$(t doctor.mem_unknown)"
  fi

  # --- MongoDB -----------------------------------------------------------------------------
  ui_h2 "$(t doctor.sec.mongo)"
  gw=""
  if dk_daemon_ok; then
    gw="$(dk_network_gateway)"
  fi
  for f in "$INSTANCES_DIR"/*/.env.s0 "$INSTANCES_DIR"/*/.env.s1; do
    [ -f "$f" ] || continue
    for var in MONGO_URI MONGO_DELTA_DISPATCH_URI MONGO_AUTHSOFTWARE_URI MONGO_ROBIN_URI; do
      uri="$(get_var "$f" "$var")"
      [ -n "$uri" ] || continue
      read -r h p <<< "$(dr_mongo_hostport "$uri")"
      case " $seen " in *" $h:$p "*) continue ;; esac
      seen+=" $h:$p"
      if [ "$h" = "host.docker.internal" ]; then
        # That is how containers get there: to Docker's gateway, not to the server's 127.0.0.1.
        if [ -z "$gw" ]; then
          ck info "$(t doctor.mongo_gw_unknown "$h:$p")"
        elif dr_tcp "$gw" "$p"; then
          ck ok "$(t doctor.mongo_via_gw "$h:$p" "$gw")"
        else
          ck err "$(t doctor.mongo_gw_fail "$h:$p" "$gw" "$p")" \
            "$(t doctor.mongo_gw_fail_hint "$gw")"
        fi
      elif dr_tcp "$h" "$p"; then
        ck ok "$(t doctor.mongo_reach "$h:$p")"
      else
        ck err "$(t doctor.mongo_noresp "$h:$p")" "$(t doctor.mongo_noresp_hint "$(basename "$(dirname "$f")")/$(basename "$f")")"
      fi
    done
  done
  [ -n "$seen" ] || ck info "$(t doctor.mongo_none)"

  pid="$(pgrep -x mongod 2>/dev/null | head -n1 || true)"
  if [ -n "$pid" ] && [ -r "/proc/$pid/limits" ]; then
    lim="$(awk '/^Max open files/ { print $4 }' "/proc/$pid/limits")"
    if [[ "$lim" =~ ^[0-9]+$ ]] && [ "$lim" -lt 64000 ]; then
      ck warn "$(t doctor.nofile_warn "$lim")" "$(t doctor.nofile_warn_hint)"
    elif [[ "$lim" =~ ^[0-9]+$ ]]; then
      ck ok "$(t doctor.nofile_ok "$lim")"
    fi
  else
    ck info "$(t doctor.nofile_unknown)" \
      "$(t doctor.nofile_unknown_hint "$(topic_label troubleshooting)")"
  fi

  # --- Instances ---------------------------------------------------------------------------
  ui_h2 "$(t doctor.sec.instances)"
  local n=0 dir bad uid fstype
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    dir="$(dirname "$f")"
    name="$(basename "$dir")"
    bad=""
    # Windows mounted in WSL (/mnt/c...) and other systems without Unix permissions show everything as 777:
    # nothing can be checked and warning would be a false positive. DELTACTL_FSTYPE lets tests force it.
    fstype="$(host_fs_type "$dir")"
    case "$fstype" in
      9p | drvfs | ntfs | fuseblk | vfat | msdos | exfat)
        ck info "$(t doctor.fs_noperm "$name" "$fstype")"
        continue
        ;;
    esac
    for v in .env.instance .env.s0 .env.s1; do
      [ -f "$dir/$v" ] || continue
      p="$(host_file_mode "$dir/$v" 600)"
      case "$p" in *00) ;; *) bad+="$v ($p) " ;; esac
    done
    uid="$(host_owner_uid "$dir/data" "$RUNTIME_UID")"
    if [ -n "$bad" ]; then
      ck warn "$(t doctor.secrets_readable "$name" "$bad")" "$(t doctor.secrets_readable_hint "$dir")"
    elif [ "$uid" != "$RUNTIME_UID" ]; then
      ck warn "$(t doctor.data_uid "$name" "$uid" "$RUNTIME_UID")" \
        "$(t doctor.data_uid_hint "$RUNTIME_UID" "$dir")"
    else
      ck ok "$(t doctor.perms_ok "$name")"
    fi
  done
  [ "$n" -gt 0 ] || ck info "$(t doctor.no_instances)"

  # --- Tools -------------------------------------------------------------------------------
  ui_h2 "$(t doctor.sec.tools)"
  for v in ss openssl gunzip; do
    if host_has "$v"; then
      ck ok "$(t doctor.tool_ok "$v")"
    else
      ck warn "$(t "doctor.tool_missing.$v")" "$(t "doctor.tool_missing_hint.$v")"
    fi
  done

  printf '\n'
  if [ "$CK_ERR" -gt 0 ]; then
    printf '  %s %s%s%s\n' "$(ui_sym err)" "$C_RED" "$(t doctor.summary_err "$CK_ERR" "$CK_WARN")" "$C_OFF"
    return 1
  fi
  if [ "$CK_WARN" -gt 0 ]; then
    printf '  %s %s%s%s\n' "$(ui_sym warn)" "$C_YEL" "$(t doctor.summary_warn "$CK_WARN")" "$C_OFF"
  else
    printf '  %s %s%s%s\n' "$(ui_sym ok)" "$C_GRN" "$(t doctor.summary_ok)" "$C_OFF"
  fi
}

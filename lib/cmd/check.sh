#!/usr/bin/env bash
# ./deltactl check <instance> [service] [--mongo]
# Checks, WITHOUT starting anything, everything ./deltactl deploy would require, and shows it as a report:
# configuration, compose, images, tags, ports and data. With --mongo it also tests that each service
# reaches its databases (with a one-off container). It is read-only.

# preflight, check_images and warn_changed_images come from deploy.sh
source "$ROOT/lib/cmd/deploy.sh"

CK_ERR=0
CK_WARN=0

# ck <state> <text> [detail...]   state: ok | warn | err | info
ck() {
  local st="$1" msg="$2" d
  shift 2
  case "$st" in err) CK_ERR=$((CK_ERR + 1)) ;; warn) CK_WARN=$((CK_WARN + 1)) ;; esac
  printf '  %s %s\n' "$(ui_sym "$st")" "$msg"
  for d in "$@"; do
    [ -z "$d" ] || printf '      %s%s%s\n' "$C_GRY" "$d" "$C_OFF"
  done
}

# Removes the colors and the warning/error labels (in the UI language) from captured messages, one line each.
ck_lines() {
  local warn_label error_label
  warn_label="$(t label.warn)"
  error_label="$(t label.error)"
  sed -e 's/\x1b\[[0-9;]*m//g' -e "s/^$warn_label //" -e "s/^$error_label //" | sed '/^$/d'
}

# Tests the connection to a database with a one-off container (uses the image's own mongoose).
ck_mongo() { # instance service variable
  local name="$1" svc="$2" var="$3" dir ref out
  dir="$(instance_dir "$name")"
  ref="$(service_image_ref "$name" "$svc")"
  out="$(dk_run_once "$dir/.env.$svc" "$ref" -- node -e '
    const m = require("mongoose");
    (async () => {
      const uri = process.env[process.argv[1]];
      await m.connect(uri, { serverSelectionTimeoutMS: 6000 });
      await m.connection.db.admin().ping();
      console.log("OK=" + m.connection.name);
      await m.disconnect();
    })().catch((e) => { console.log("ERR=" + e.message); process.exit(2); });
  ' "$var" 2>&1)" || true
  if [[ "$out" =~ OK=([^[:space:]]*) ]]; then
    ck ok "$(t check.mongo_ok "$svc" "$var" "${BASH_REMATCH[1]}")"
  else
    ck err "$(t check.mongo_fail "$svc" "$var")" "$(printf '%s' "$out" | grep -a 'ERR=' | head -1)" \
      "$(t check.mongo_fail_hint)"
  fi
}

# Variables holding the Mongo URI of each service.
ck_mongo_vars() { # service
  case "$1" in
    s0) echo MONGO_URI ;;
    s1) echo MONGO_DELTA_DISPATCH_URI MONGO_AUTHSOFTWARE_URI MONGO_ROBIN_URI ;;
  esac
}

cmd_check() {
  local name="" only="" mongo=0 a
  while [ "$#" -gt 0 ]; do
    a="$1"
    case "$a" in
      --mongo) mongo=1 ;;
      -*) die "$(t check.unknown_option "$a")" ;;
      *)
        if [ -z "$name" ]; then name="$a"
        elif [ -z "$only" ]; then only="$a"
        else die "$(t check.extra_arg "$a")"; fi
        ;;
    esac
    shift
  done
  require_instance "$name"
  select_services "$name" "$only"
  check_docker
  local dir svc ref out rc owner p var arch srv
  dir="$(instance_dir "$name")"

  ui_h1 "$(t check.title "$name")"
  ui_kv "$(t check.kv.services)" "${SELECTED[*]}" 12
  printf '\n'

  # 1. Configuration (the same validations as ./deltactl deploy).
  out="$( (preflight "$name" "${SELECTED[@]}") 2>&1 )" && rc=0 || rc=$?
  out="$(printf '%s\n' "$out" | ck_lines)"
  if [ "$rc" -ne 0 ]; then
    mapfile -t lines <<< "$out"
    ck err "$(t check.config_incomplete)" "${lines[@]}"
  elif [ -n "$out" ]; then
    mapfile -t lines <<< "$out"
    ck warn "$(t check.config_warn)" "${lines[@]}"
  else
    ck ok "$(t check.config_ok)"
  fi

  # 2. Compose.
  if [ -n "$only" ]; then
    out="$(dk_compose "$name" --profile "$only" config -q 2>&1)" && rc=0 || rc=$?
  else
    out="$(dk_compose "$name" config -q 2>&1)" && rc=0 || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    ck ok "$(t check.compose_ok)"
  else
    ck err "$(t check.compose_bad)" "$(printf '%s' "$out" | head -n2 | tr '\n' ' ')"
  fi

  # 3. Images.
  srv="$(server_arch)"
  for svc in "${SELECTED[@]}"; do
    ref="$(service_image_ref "$name" "$svc")"
    if ! uses_local_images "$name"; then
      ck info "$(t check.image_pull "$svc" "$ref")"
    elif dk_image_exists "$ref"; then
      arch="$(dk_image_arch "$ref")"
      [ -n "$arch" ] || arch='?'
      if [ -n "$srv" ] && [ "$arch" != "$srv" ] && [ "$arch" != "?" ]; then
        ck err "$(t check.image_arch "$svc" "$ref" "$arch" "$srv")" "$(t check.image_arch_hint "$srv")"
      else
        ck ok "$(t check.image_ok "$svc" "$ref" "$(short_id "$(dk_image_id "$ref")")" "$arch")"
      fi
    else
      ck err "$(t check.image_missing "$svc" "$ref")" "$(t check.image_missing_hint)"
    fi
  done

  # 4. Tags that point to another image than the deployed one.
  out="$( (warn_changed_images "$name" "${SELECTED[@]}") 2>&1 | ck_lines)"
  if [ -n "$out" ]; then
    ck warn "$(t check.tag_changed)" "$out"
  fi

  # 5. Ports.
  for svc in "${SELECTED[@]}"; do
    p="$(get_var "$dir/.env.instance" "${svc^^}_PORT")"
    [ -n "$p" ] || continue
    owner="$(port_owner "$p" "$name")"
    if [ -n "$owner" ]; then
      ck err "$(t check.port_taken "$svc" "$p" "$owner")" "$(t check.port_taken_hint "${svc^^}_PORT")"
    elif host_port_in_use "$p"; then
      if dk_project_publishes_port "$name" "$p"; then
        ck ok "$(t check.port_same "$svc" "$p")"
      else
        ck warn "$(t check.port_busy "$svc" "$p")" "$(t check.port_busy_hint "$p")"
      fi
    else
      ck ok "$(t check.port_free "$svc" "$p")"
    fi
  done

  # 6. Data.
  if [ -f "$(marker_file "$name")" ]; then
    ck ok "$(t check.data_marked "$(get_var "$(marker_file "$name")" SOURCE)")"
  else
    ck info "$(t check.data_unseeded "$name")"
  fi

  # 7. Mongo (optional: it takes time and needs the images).
  if [ "$mongo" -eq 1 ]; then
    for svc in "${SELECTED[@]}"; do
      ref="$(service_image_ref "$name" "$svc")"
      if uses_local_images "$name" && ! dk_image_exists "$ref"; then
        ck warn "$(t check.mongo_skip_image "$svc" "$ref")"
        continue
      fi
      for var in $(ck_mongo_vars "$svc"); do ck_mongo "$name" "$svc" "$var"; done
    done
  else
    ck info "$(t check.mongo_not_tested)"
  fi

  printf '\n'
  if [ "$CK_ERR" -gt 0 ]; then
    printf '  %s %s%s%s\n' "$(ui_sym err)" "$C_RED" "$(t check.summary_err "$CK_ERR" "$CK_WARN" "$name")" "$C_OFF"
    ui_hint "$(t check.help_hint "$(topic_label troubleshooting)")"
    return 1
  fi
  if [ "$CK_WARN" -gt 0 ]; then
    printf '  %s %s%s%s\n' "$(ui_sym warn)" "$C_YEL" "$(t check.ready_warn "$CK_WARN")" "$C_OFF"
  else
    printf '  %s %s%s%s\n' "$(ui_sym ok)" "$C_GRN" "$(t check.ready_ok)" "$C_OFF"
  fi
  ui_hint "./deltactl deploy $name"
}

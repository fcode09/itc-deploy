#!/usr/bin/env bash
# ./deltactl service list   <instance>
#                   add    <instance> <service> [--tag <tag|latest>] [--port <n>] [--generate-secrets] [--yes]
#                   remove <instance> <service> [--yes]
#                   set    <instance> <service> tag|image|port|memory <value>
# The services an instance runs: see them, add one, remove one (its data stays) and change its version, port or memory limit. The rules are in
# lib/core/svcmgmt.sh, shared with the Services tab of the panel. Nothing here deploys: it says what is left (variables, then deploy).

service_list() { # instance
  local name="$1" s state tag port mem active line
  svc_active_r "$name"
  info "$(t service.list_title "$name")"
  for s in "${KNOWN_SERVICES[@]}"; do
    active=0
    for line in "${SVC_ACTIVE[@]}"; do [ "$line" != "$s" ] || active=1; done
    get_var_r "$INSTANCES_DIR/$name/.env.instance" "$(tag_var "$s")"; tag="${GV:--}"
    get_var_r "$INSTANCES_DIR/$name/.env.instance" "${s^^}_PORT"; port="${GV:--}"
    get_var_r "$INSTANCES_DIR/$name/.env.instance" "${s^^}_MEM_LIMIT"; mem="${GV:-${CAT_MEM[$s]:-}}"
    if [ "$active" -eq 1 ]; then state="$(t service.state_active)"; else state="$(t service.state_off)"; fi
    printf '  %-4s %-16s %-10s %-18s %-7s %s\n' "$s" "${CAT_NAME[$s]}" "$state" "$tag" "$port" "$mem"
  done
}

# `--tag latest`: the most recent version this server can run (lib/core/imagecat.sh), written as the tag it is, never the word latest.
service_resolve_latest() { # instance service [soft] -> tag in SVC_TAG ("" when Docker does not answer: the template's tag stays)
  # soft: with no image to pick (the service has none loaded yet) it warns and leaves the tag empty instead of stopping; `service add` uses it
  # so a service can be activated before its image exists (the panel's `a` key asks for latest).
  local name="$1" svc="$2" soft="${3:-}" repo
  SVC_TAG=""
  repo="$(service_repo "$svc" "$name")"
  if ! ic_load "$svc=$repo"; then warn "$(t new.latest_nodocker "$svc" "$(tag_var "$svc")")"; return 0; fi
  if ! ic_latest "$svc" "$repo"; then
    [ "$soft" = soft ] || die "$(t new.latest_none "$svc" "$repo" "$IC_SERVER_ARCH")$(see local-images)"
    warn "$(t service.latest_none "$svc" "$repo" "$(tag_var "$svc")" "$name")"
    return 0
  fi
  info "$(t new.latest_resolved "$svc" "$repo" "$IC_LATEST")"
  SVC_TAG="$IC_LATEST"
}

service_add() { # instance service tag port generate
  local name="$1" svc="$2" tag="$3" port="$4" gen="$5" dir
  local -a opts=()
  valid_service "$svc" || die "$(t err.service_unknown "$svc" "${KNOWN_SERVICES[*]}")$(see services)"
  if svc_is_active "$name" "$svc"; then die "$(t service.already "$svc" "$name")"; fi
  if [ "$tag" = latest ]; then service_resolve_latest "$name" "$svc" soft; tag="$SVC_TAG"; fi
  [ -z "$tag" ] || opts+=("tag=$tag")
  [ -z "$port" ] || opts+=("port=$port")
  [ "$gen" -eq 0 ] || opts+=("generate=1")
  svc_add "$name" "$svc" ${opts[@]+"${opts[@]}"} || die "$SVC_MSG"
  dir="$(instance_dir "$name")"
  get_var_r "$dir/.env.instance" "${svc^^}_PORT"
  ok "$(t service.added "$svc" "${CAT_NAME[$svc]}" "$name" "$GV")"
  if host_port_in_use "$GV"; then warn "$(t new.port_busy "$GV")"; fi
  info ""
  info "$(t new.pending_title)"
  # shellcheck source=lib/cmd/new.sh
  source "$ROOT/lib/cmd/new.sh"
  new_pending "$name"
  info ""
  info "$(t service.next_title)"
  info "$(t service.next_env "$name" "$svc")"
  info "$(t service.next_deploy "$name" "$svc")"
}

service_remove() { # instance service
  local name="$1" svc="$2" typed u
  valid_service "$svc" || die "$(t err.service_unknown "$svc" "${KNOWN_SERVICES[*]}")$(see services)"
  svc_is_active "$name" "$svc" || die "$(t service.not_active "$svc" "$name")"
  if [ "${#SVC_ACTIVE[@]}" -le 1 ]; then die "$(t service.last "$svc" "$name")"; fi
  svc_users_of "$name" "$svc"
  for u in ${SVC_USERS[@]+"${SVC_USERS[@]}"}; do warn "$(t service.used_by "$u" "$svc")"; done
  info "$(t service.remove_info "$svc" "$name" "$(instance_dir "$name")/data/$svc")"
  if [ "${ASSUME_YES:-0}" != "1" ]; then
    [ -t 0 ] || die "$(t err.confirm_needed)"
    read -r -p "$(t service.type_key "$svc")" typed
    [ "$typed" = "$svc" ] || die "$(t err.cancelled)"
  fi
  # The container stops (when Docker answers); the files and the data do not go anywhere.
  if dk_installed && dk_daemon_ok && dk_compose_ok; then
    dk_compose "$name" --profile "$svc" stop "$svc" > /dev/null 2>&1 || warn "$(t service.stop_failed "$svc")"
  else
    warn "$(t service.not_stopped "$svc")"
  fi
  svc_remove "$name" "$svc" || die "$SVC_MSG"
  ok "$(t service.removed "$svc" "$name")"
  info "$(t service.kept "$svc" "$(instance_dir "$name")")"
}

service_set() { # instance service field value
  local name="$1" svc="$2" field="$3" value="$4"
  valid_service "$svc" || die "$(t err.service_unknown "$svc" "${KNOWN_SERVICES[*]}")$(see services)"
  svc_is_active "$name" "$svc" || die "$(t service.not_active "$svc" "$name")"
  [ -n "$field" ] || die "$(t service.set_usage "$name" "$svc")"
  if [ "$field" = tag ] && [ "$value" = latest ]; then
    service_resolve_latest "$name" "$svc"
    [ -n "$SVC_TAG" ] || die "$(t service.latest_unknown)"
    value="$SVC_TAG"
  fi
  [ -n "$value" ] || die "$(t service.set_usage "$name" "$svc")"
  svc_set "$name" "$svc" "$field" "$value" || die "$SVC_MSG"
  ok "$(t service.set_done "$svc" "$field" "$value" "$name")"
  info "$(t service.next_deploy "$name" "$svc")"
}

cmd_service() {
  local sub="${1:-}" inst="${2:-}" svc="" tag="" port="" gen=0 a field="" value=""
  [ -n "$sub" ] || die "$(t service.usage)"
  shift
  case "$sub" in list | add | remove | set) ;; *) die "$(t service.unknown_sub "$sub")" ;; esac
  [ -n "$inst" ] || die "$(t service.usage)"
  shift
  require_instance "$inst"
  parse_yes "$@"
  set -- ${ARGS[@]+"${ARGS[@]}"}
  while [ "$#" -gt 0 ]; do
    a="$1"
    shift
    case "$a" in
      --tag) [ "$#" -gt 0 ] || die "$(t service.opt_value "$a")"; tag="$1"; shift ;;
      --port) [ "$#" -gt 0 ] || die "$(t service.opt_value "$a")"; port="$1"; shift ;;
      --generate-secrets) gen=1 ;;
      -*) die "$(t service.unknown_option "$a")" ;;
      *)
        if [ -z "$svc" ]; then svc="$a"
        elif [ "$sub" = set ] && [ -z "$field" ]; then field="$a"
        elif [ "$sub" = set ] && [ -z "$value" ]; then value="$a"
        else die "$(t service.extra_arg "$a")"; fi
        ;;
    esac
  done
  if [ "$sub" != list ] && [ -z "$svc" ]; then die "$(t service.service_missing "$sub" "$inst")"; fi
  case "$sub" in
    list) service_list "$inst" ;;
    add) service_add "$inst" "$svc" "$tag" "$port" "$gen" ;;
    remove) service_remove "$inst" "$svc" ;;
    set) service_set "$inst" "$svc" "$field" "$value" ;;
  esac
}

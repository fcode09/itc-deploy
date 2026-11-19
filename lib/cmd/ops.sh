#!/usr/bin/env bash
# ./deltactl ps | logs | stop | down <instance>: operation shortcuts.
# They use --profile '*' to also show or clean services that are no longer in COMPOSE_PROFILES.

cmd_ps() {
  require_instance "${1:-}"
  check_docker
  dk_compose "$1" --profile '*' ps
}

cmd_logs() {
  local name="${1:-}"
  require_instance "$name"
  check_docker
  shift
  dk_compose "$name" --profile '*' logs --tail 200 "$@"
}

# Stops one service without touching the others (it does not remove it; ./deltactl deploy starts it again).
cmd_stop() {
  local name="${1:-}" svc="${2:-}"
  require_instance "$name"
  [ -n "$svc" ] || die "$(t ops.stop_usage "$name")"
  valid_service "$svc" || die "$(t err.service_unknown "$svc" "${KNOWN_SERVICES[*]}")$(see services)"
  check_docker
  dk_compose "$name" --profile "$svc" stop "$svc"
  ok "$(t ops.stopped "$svc" "$name")"
}

cmd_down() {
  parse_yes "$@"
  local name="${ARGS[0]:-}"
  require_instance "$name"
  check_docker
  info "$(t ops.down_info "$name")"
  confirm "$(t prompt.continue)" || die "$(t err.cancelled)"
  dk_compose "$name" --profile '*' down
  ok "$(t ops.down_done "$name")"
}

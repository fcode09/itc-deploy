#!/usr/bin/env bash
# ./itc ps | logs | down <instancia>: atajos de operación.

cmd_ps() {
  require_instance "${1:-}"
  check_docker
  dc "$1" ps
}

cmd_logs() {
  local name="${1:-}"
  require_instance "$name"
  check_docker
  shift
  dc "$name" logs --tail 200 "$@"
}

cmd_down() {
  parse_yes "$@"
  local name="${ARGS[0]:-}"
  require_instance "$name"
  check_docker
  info "Detiene y elimina los contenedores de '$name'. Los datos (data/) y secretos se conservan."
  confirm "¿Continuar?" || die "cancelado"
  dc "$name" down
  ok "instancia '$name' detenida"
}

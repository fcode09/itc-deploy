#!/usr/bin/env bash
# ./itc ps | logs | stop | down <instancia>: atajos de operación.
# Usan --profile '*' para ver o limpiar también servicios que ya no están en COMPOSE_PROFILES.

cmd_ps() {
  require_instance "${1:-}"
  check_docker
  dc "$1" --profile '*' ps
}

cmd_logs() {
  local name="${1:-}"
  require_instance "$name"
  check_docker
  shift
  dc "$name" --profile '*' logs --tail 200 "$@"
}

# Detiene un servicio sin tocar los demás (no lo elimina; ./itc deploy lo vuelve a levantar).
cmd_stop() {
  local name="${1:-}" svc="${2:-}"
  require_instance "$name"
  [ -n "$svc" ] || die "uso: ./itc stop <instancia> <servicio>  (para detener todo: ./itc down $name)"
  valid_service "$svc" || die "servicio desconocido: '$svc' (válidos: ${KNOWN_SERVICES[*]})$(see servicios)"
  check_docker
  dc "$name" --profile "$svc" stop "$svc"
  ok "$svc detenido en '$name'"
}

cmd_down() {
  parse_yes "$@"
  local name="${ARGS[0]:-}"
  require_instance "$name"
  check_docker
  info "Detiene y elimina los contenedores de '$name'. Los datos (data/) y secretos se conservan."
  confirm "¿Continuar?" || die "cancelado"
  dc "$name" --profile '*' down
  ok "instancia '$name' detenida"
}

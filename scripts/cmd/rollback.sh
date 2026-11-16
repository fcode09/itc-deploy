#!/usr/bin/env bash
# ./itc rollback <instancia> [--yes]: vuelve a las etiquetas del despliegue anterior.

# deploy_up viene de deploy.sh
source "$ROOT/scripts/cmd/deploy.sh"

cmd_rollback() {
  parse_yes "$@"
  local name="${ARGS[0]:-}"
  require_instance "$name"
  local dir
  dir="$(instance_dir "$name")"

  [ -f "$dir/.previous" ] || die "no hay un despliegue previo registrado para '$name'"

  local cur0 cur1 prev0 prev1
  cur0="$(get_var "$dir/instance.env" S0_TAG)"
  cur1="$(get_var "$dir/instance.env" S1_TAG)"
  prev0="$(get_var "$dir/.previous" S0_TAG)"
  prev1="$(get_var "$dir/.previous" S1_TAG)"
  [ -n "$prev0" ] && [ -n "$prev1" ] || die "el archivo .previous de '$name' está incompleto"

  info "Instancia: $name"
  info "  s0: $cur0 -> $prev0"
  info "  s1: $cur1 -> $prev1"
  confirm "¿Volver a estas etiquetas?" || die "cancelado"

  check_docker

  # Lo que estaba desplegado pasa a ser "previo", así un segundo rollback lo restaura.
  local keep=""
  if [ -f "$dir/.deployed" ]; then
    keep="$(mktemp)"
    cp "$dir/.deployed" "$keep"
  fi

  set_var "$dir/instance.env" S0_TAG "$prev0"
  set_var "$dir/instance.env" S1_TAG "$prev1"

  if ! deploy_up "$name"; then
    [ -z "$keep" ] || rm -f "$keep"
    die "el rollback de '$name' no llegó a healthy"
  fi

  if [ -n "$keep" ]; then
    mv "$keep" "$dir/.previous"
  fi
  ok "rollback de '$name' completado"
}

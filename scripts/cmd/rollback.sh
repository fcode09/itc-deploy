#!/usr/bin/env bash
# ./itc rollback <instancia> [servicio] [--yes]: vuelve a las etiquetas del despliegue anterior.
# Sin servicio, revierte todos los activos que tengan una etiqueta previa distinta de la actual.

# deploy_up viene de deploy.sh
source "$ROOT/scripts/cmd/deploy.sh"

cmd_rollback() {
  parse_yes "$@"
  local name="${ARGS[0]:-}" only="${ARGS[1]:-}"
  require_instance "$name"
  select_services "$name" "$only"

  local dir svc tag_name cur prev
  local -a roll=()
  local -A prevs=() deployed=()
  dir="$(instance_dir "$name")"

  info "Instancia: $name"
  for svc in "${SELECTED[@]}"; do
    tag_name="$(tag_var "$svc")"
    cur="$(get_var "$dir/instance.env" "$tag_name")"
    prev="$(get_var "$dir/.previous" "$tag_name")"
    if [ -z "$prev" ] || [ "$prev" = "$cur" ]; then
      [ -z "$only" ] || die "no hay una etiqueta previa registrada para $svc en '$name'"
      continue
    fi
    roll+=("$svc")
    prevs[$svc]="$prev"
    deployed[$svc]="$(get_var "$dir/.deployed" "$tag_name")"
    info "  $svc: $cur -> $prev"
  done
  [ "${#roll[@]}" -gt 0 ] || die "no hay nada que revertir en '$name'"

  confirm "¿Volver a estas etiquetas?" || die "cancelado"
  check_docker

  for svc in "${roll[@]}"; do
    set_var "$dir/instance.env" "$(tag_var "$svc")" "${prevs[$svc]}"
  done

  deploy_up 1 "$name" "${roll[@]}" || die "el rollback de '$name' no llegó a healthy"

  # Lo que estaba desplegado pasa a ser "previo", así un segundo rollback lo restaura.
  for svc in "${roll[@]}"; do
    [ -z "${deployed[$svc]}" ] || set_var "$dir/.previous" "$(tag_var "$svc")" "${deployed[$svc]}"
  done
  ok "rollback de '$name' completado (${roll[*]})"
}

#!/usr/bin/env bash
# ./itc rollback <instancia> [servicio] [--yes]: vuelve a las etiquetas del despliegue anterior.
# Sin servicio, revierte todos los activos que tengan una etiqueta previa distinta de la actual.
# Con imágenes locales, la imagen previa debe seguir cargada en este Docker.

# deploy_up viene de deploy.sh
source "$ROOT/scripts/cmd/deploy.sh"

cmd_rollback() {
  parse_yes "$@"
  local name="${ARGS[0]:-}" only="${ARGS[1]:-}"
  require_instance "$name"
  select_services "$name" "$only"

  local dir svc tag_name cur prev prev_id ref_prev missing=0
  local -a roll=()
  local -A prevs=() deployed=() deployed_ids=()
  dir="$(instance_dir "$name")"

  check_docker

  info "Instancia: $name"
  for svc in "${SELECTED[@]}"; do
    tag_name="$(tag_var "$svc")"
    cur="$(get_var "$dir/.env.instance" "$tag_name")"
    prev="$(get_var "$dir/.previous" "$tag_name")"
    if [ -z "$prev" ] || [ "$prev" = "$cur" ]; then
      [ -z "$only" ] || die "no hay una etiqueta previa registrada para $svc en '$name'$(see actualizar)"
      continue
    fi

    # Con imágenes locales no hay de dónde bajarla: debe seguir cargada, con el mismo ID.
    if uses_local_images "$name"; then
      ref_prev="$(service_repo "$svc" "$name"):$prev"
      if ! image_exists "$ref_prev"; then
        warn "la imagen previa $ref_prev ($svc) ya no está en este servidor (¿se borró?)"
        missing=$((missing + 1))
        continue
      fi
      prev_id="$(get_var "$dir/.previous" "${svc^^}_IMAGE_ID")"
      if [ -n "$prev_id" ] && [ "$(image_id "$ref_prev")" != "$prev_id" ]; then
        warn "$svc: la etiqueta $prev ahora apunta a otra imagen ($(short_id "$(image_id "$ref_prev")")) distinta de la que estaba desplegada ($(short_id "$prev_id"))"
      fi
    fi

    roll+=("$svc")
    prevs[$svc]="$prev"
    deployed[$svc]="$(get_var "$dir/.deployed" "$tag_name")"
    deployed_ids[$svc]="$(get_var "$dir/.deployed" "${svc^^}_IMAGE_ID")"
    info "  $svc: $cur -> $prev"
  done

  [ "$missing" -eq 0 ] || die "faltan imágenes previas en este servidor: no se cambió nada. Revisa ./itc images$(see actualizar)"
  [ "${#roll[@]}" -gt 0 ] || die "no hay nada que revertir en '$name'"

  confirm "¿Volver a estas etiquetas?" || die "cancelado"

  for svc in "${roll[@]}"; do
    set_var "$dir/.env.instance" "$(tag_var "$svc")" "${prevs[$svc]}"
  done

  deploy_up 1 "$name" "${roll[@]}" || die "el rollback de '$name' no llegó a healthy"

  # Lo que estaba desplegado pasa a ser "previo", así un segundo rollback lo restaura.
  for svc in "${roll[@]}"; do
    if [ -n "${deployed[$svc]}" ]; then
      set_var "$dir/.previous" "$(tag_var "$svc")" "${deployed[$svc]}"
      set_var "$dir/.previous" "${svc^^}_IMAGE_ID" "${deployed_ids[$svc]}"
    fi
  done
  ok "rollback de '$name' completado (${roll[*]})"
}

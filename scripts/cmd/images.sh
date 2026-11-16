#!/usr/bin/env bash
# ./itc images [servicio]: versiones de imagen cargadas en este Docker y qué instancias las usan.

cmd_images() {
  local only="${1:-}" svc repo f name cur prev found shown=0
  if [ -n "$only" ]; then
    valid_service "$only" || die "servicio desconocido: '$only' (válidos: ${KNOWN_SERVICES[*]})"
  fi
  check_docker

  # Uso por etiqueta: "<sN>:<tag>" -> instancias que la tienen como actual o como previa (rollback).
  local -A used=()
  for f in "$INSTANCES_DIR"/*/instance.env; do
    [ -f "$f" ] || continue
    name="$(basename "$(dirname "$f")")"
    for svc in "${KNOWN_SERVICES[@]}"; do
      cur="$(get_var "$f" "$(tag_var "$svc")")"
      prev="$(get_var "$(dirname "$f")/.previous" "$(tag_var "$svc")")"
      [ -z "$cur" ] || used["$svc:$cur"]+="$name(actual) "
      if [ -n "$prev" ] && [ "$prev" != "$cur" ]; then used["$svc:$prev"]+="$name(previa) "; fi
    done
  done

  info "Arquitectura de este servidor: $(server_arch)"
  for svc in "${KNOWN_SERVICES[@]}"; do
    if [ -n "$only" ] && [ "$svc" != "$only" ]; then continue; fi
    repo="$(service_repo "$svc")"
    info ""
    info "$svc = $repo"
    found=0
    while IFS='|' read -r full tag id created size; do
      [ -n "$tag" ] && [ "$tag" != "<none>" ] || continue
      if [ "$found" -eq 0 ]; then
        printf '  %-18s %-13s %-8s %-14s %-9s %s\n' ETIQUETA ID ARQ CREADA TAMAÑO USADA_POR
      fi
      found=1
      shown=$((shown + 1))
      printf '  %-18s %-13s %-8s %-14s %-9s %s\n' "$tag" "$(short_id "$id")" \
        "$(docker image inspect --format '{{.Architecture}}' "$full:$tag" 2>/dev/null || echo '?')" \
        "$created" "$size" "${used["$svc:$tag"]:-sin uso (candidata a borrar)}"
    done < <(docker image ls --format '{{.Repository}}|{{.Tag}}|{{.ID}}|{{.CreatedSince}}|{{.Size}}' \
      | awk -F'|' -v r="$repo" '$1 == r || $1 ~ ("/" r "$")')
    [ "$found" -eq 1 ] || info "  (sin imágenes cargadas; cárgalas con ./itc load <archivo>)"
  done

  info ""
  info "Las versiones 'sin uso' no las usa ninguna instancia (ni como actual ni como previa)."
  info "Este comando solo lista: borrar imágenes lo decides tú. Evita 'docker image prune -a'."
}

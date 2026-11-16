#!/usr/bin/env bash
# ./itc images [servicio]: versiones de imagen cargadas en este Docker y qué instancias las usan.
# Si alguna instancia usa un nombre propio (<SN>_IMAGE en .env.instance), también se lista.

cmd_images() {
  local only="${1:-}" svc repo f name cur prev found r seen
  if [ -n "$only" ]; then
    valid_service "$only" || die "servicio desconocido: '$only' (válidos: ${KNOWN_SERVICES[*]})"
  fi
  check_docker

  # Uso por imagen y etiqueta: "<nombre>:<tag>" -> instancias que la tienen como actual o como previa (rollback).
  # Nombres usados por servicio: el por defecto más los propios de cada instancia.
  local -A used=() repos=()
  for svc in "${KNOWN_SERVICES[@]}"; do repos[$svc]="$(service_repo "$svc")"; done
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    name="$(basename "$(dirname "$f")")"
    for svc in "${KNOWN_SERVICES[@]}"; do
      r="$(service_repo "$svc" "$name")"
      case " ${repos[$svc]} " in *" $r "*) ;; *) repos[$svc]+=" $r" ;; esac
      cur="$(get_var "$f" "$(tag_var "$svc")")"
      prev="$(get_var "$(dirname "$f")/.previous" "$(tag_var "$svc")")"
      [ -z "$cur" ] || used["$r:$cur"]+="$name(actual) "
      if [ -n "$prev" ] && [ "$prev" != "$cur" ]; then used["$r:$prev"]+="$name(previa) "; fi
    done
  done

  info "Arquitectura de este servidor: $(server_arch)"
  for svc in "${KNOWN_SERVICES[@]}"; do
    if [ -n "$only" ] && [ "$svc" != "$only" ]; then continue; fi
    for repo in ${repos[$svc]}; do
      info ""
      info "$svc = $repo"
      found=0
      while IFS='|' read -r full tag id created size; do
        [ -n "$tag" ] && [ "$tag" != "<none>" ] || continue
        if [ "$found" -eq 0 ]; then
          printf '  %-18s %-13s %-8s %-14s %-9s %s\n' ETIQUETA ID ARQ CREADA TAMAÑO USADA_POR
        fi
        found=1
        printf '  %-18s %-13s %-8s %-14s %-9s %s\n' "$tag" "$(short_id "$id")" \
          "$(docker image inspect --format '{{.Architecture}}' "$full:$tag" 2>/dev/null || echo '?')" \
          "$created" "$size" "${used["$repo:$tag"]:-sin uso (candidata a borrar)}"
      done < <(docker image ls --format '{{.Repository}}|{{.Tag}}|{{.ID}}|{{.CreatedSince}}|{{.Size}}' \
        | awk -F'|' -v r="$repo" '$1 == r || (length($1) > length(r) && substr($1, length($1) - length(r)) == "/" r)')
      [ "$found" -eq 1 ] || info "  (sin imágenes cargadas; cárgalas con ./itc load <archivo>)"
    done
  done

  info ""
  info "Las versiones 'sin uso' no las usa ninguna instancia (ni como actual ni como previa)."
  info "Este comando solo lista: borrar imágenes lo decides tú. Evita 'docker image prune -a'."
}

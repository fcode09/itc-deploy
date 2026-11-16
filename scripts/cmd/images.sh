#!/usr/bin/env bash
# ./itc images [servicio] [--json]  (alias: ./itc versions)
# Versiones de imagen cargadas en este Docker y qué instancias las usan.
# Si alguna instancia usa un nombre propio (<SN>_IMAGE en .env.instance), también se lista.
# Solo lista: nunca borra imágenes.

cmd_images() {
  local only="" json=0 a svc repo f name cur prev found r
  while [ "$#" -gt 0 ]; do
    a="$1"
    case "$a" in
      --json) json=1 ;;
      -*) die "opción desconocida: $a (ver ./itc help images)" ;;
      *)
        [ -z "$only" ] || die "sobra el argumento '$a'"
        only="$a"
        ;;
    esac
    shift
  done
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

  local full tag id created size arch use kind total=0 unused=0 first_json=1
  if [ "$json" -eq 1 ]; then
    printf '[\n'
  else
    ui_h1 "Imágenes de este servidor"
    info "Arquitectura de este servidor: $(server_arch)"
    ui_table_cols 18 13 8 14 9
  fi

  for svc in "${KNOWN_SERVICES[@]}"; do
    if [ -n "$only" ] && [ "$svc" != "$only" ]; then continue; fi
    for repo in ${repos[$svc]}; do
      found=0
      if [ "$json" -eq 0 ]; then
        # Formato estable: "<sN> = <repo>" en su propia línea, precedida de una línea en blanco.
        printf '\n%s%s%s\n' "$C_BLD" "$svc = $repo" "$C_OFF"
      fi
      while IFS='|' read -r full tag id created size; do
        [ -n "$tag" ] && [ "$tag" != "<none>" ] || continue
        arch="$(docker image inspect --format '{{.Architecture}}' "$full:$tag" 2>/dev/null || echo '?')"
        use="${used["$repo:$tag"]:-}"
        use="${use% }"
        total=$((total + 1))
        if [ -z "$use" ]; then
          kind=dim
          unused=$((unused + 1))
        elif [[ "$use" == *"(actual)"* ]]; then
          kind=ok
        else
          kind=warn
        fi
        if [ "$json" -eq 1 ]; then
          [ "$first_json" -eq 1 ] || printf ',\n'
          first_json=0
          printf '  {"service":"%s","repository":"%s","tag":"%s","id":"%s","architecture":"%s","created":"%s","size":"%s","used_by":"%s","in_use":%s}' \
            "$svc" "$(ui_json_escape "$repo")" "$(ui_json_escape "$tag")" "$(short_id "$id")" "$(ui_json_escape "$arch")" \
            "$(ui_json_escape "$created")" "$(ui_json_escape "$size")" "$(ui_json_escape "$use")" \
            "$([ -n "$use" ] && echo true || echo false)"
        else
          if [ "$found" -eq 0 ]; then ui_th ETIQUETA ID ARQ CREADA TAMAÑO USADA_POR; fi
          ui_tr "bold:$tag" "$(short_id "$id")" "$arch" "$created" "$size" "$kind:${use:-sin uso (candidata a borrar)}"
        fi
        found=1
      done < <(docker image ls --format '{{.Repository}}|{{.Tag}}|{{.ID}}|{{.CreatedSince}}|{{.Size}}' \
        | awk -F'|' -v r="$repo" '$1 == r || (length($1) > length(r) && substr($1, length($1) - length(r)) == "/" r)')
      if [ "$json" -eq 0 ] && [ "$found" -eq 0 ]; then
        info "  (sin imágenes cargadas; cárgalas con ./itc load <archivo>)"
      fi
    done
  done

  if [ "$json" -eq 1 ]; then
    printf '\n]\n'
    return 0
  fi
  printf '\n'
  info "Las versiones 'sin uso' no las usa ninguna instancia (ni como actual ni como previa)."
  info "Este comando solo lista: borrar imágenes lo decides tú. Evita 'docker image prune -a'."
  if [ "$unused" -gt 0 ]; then
    ui_hint "$unused de $total imagen(es) sin uso. Para borrar una concreta: docker image rm <nombre>:<etiqueta>"
  fi
}

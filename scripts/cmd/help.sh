#!/usr/bin/env bash
# ./itc help [comando | tema | variable [CLAVE] | buscar <texto>]
# La ayuda vive en scripts/help/*.txt (una sola fuente de verdad); este archivo solo la busca y la muestra.
#   cmd-<comando>.txt   una página por comando
#   topic-<tema>.txt    guías completas
#   overview.txt        pantalla principal
#   variables.txt       glosario de variables de .env.instance, .env.s0 y .env.s1
# tests/test-help.sh comprueba que todo comando, tema y variable tenga su página.

HELP_DIR="$ROOT/scripts/help"
HELP_COMMANDS=(new init adopt deploy rollback stop down load images versions list status ps logs check doctor menu completion help)
HELP_TOPICS=(nueva-instancia instancia-existente actualizar imagenes servicios red datos secretos archivos puertos solucion-problemas glosario)

# Título (primera línea "# ...") de una página de ayuda.
help_title() { # archivo
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '# '*) printf '%s' "${line#\# }"; return 0 ;; esac
  done < "$1"
}

help_topics_list() {
  local t
  ui_h2 "Guías  (./itc help <tema>)"
  for t in "${HELP_TOPICS[@]}"; do
    printf '  %s%-24s%s %s\n' "$C_GRN" "$t" "$C_OFF" "$(help_title "$HELP_DIR/topic-$t.txt")"
  done
}

help_overview() {
  ui_banner
  ui_render_file "$HELP_DIR/overview.txt"
  help_topics_list
  printf '\n'
  ui_hint "Variables:  ./itc help variable <NOMBRE>   (sin nombre, las lista todas)"
  ui_hint "Buscar:     ./itc help buscar <texto>"
  ui_hint "Cualquier comando acepta --help:  ./itc deploy --help"
}

# Sugerencias para un nombre que no existe: páginas cuyo nombre se parece.
help_unknown() { # texto
  local q="$1" f n found=0
  warn "no hay ayuda para '$q'"
  for f in "$HELP_DIR"/cmd-*.txt "$HELP_DIR"/topic-*.txt; do
    n="$(basename "$f" .txt)"
    n="${n#cmd-}"
    n="${n#topic-}"
    case "$n" in *"$q"* | "${q:0:3}"*)
      [ "$found" -eq 1 ] || info "¿Quisiste decir?"
      found=1
      info "  ./itc help $n"
      ;;
    esac
  done
  info "Índice completo: ./itc help      Buscar texto: ./itc help buscar $q"
  return 1
}

help_page() { # nombre
  local n="$1" f
  [ "$n" != "versions" ] || n=images
  for f in "$HELP_DIR/cmd-$n.txt" "$HELP_DIR/topic-$n.txt"; do
    if [ -f "$f" ]; then
      ui_render_file "$f"
      printf '\n'
      return 0
    fi
  done
  help_unknown "$1"
}

# Registros "H<TAB>cabecera" y "T<TAB>línea" de las variables que coinciden con la clave (todas si no hay).
help_var_records() { # [CLAVE]
  awk -v k="${1:-}" '
    /^@ / {
      h = substr($0, 3)
      n = split(h, a, " \\| ")
      gsub(/^ +| +$/, "", a[1])
      p = (k == "" || a[1] == k)
      if (p) print "H\t" h
      next
    }
    p { print "T\t" $0 }
  ' "$HELP_DIR/variables.txt"
}

help_variable() { # [CLAVE]
  local key="${1:-}" tag rest k f t d first
  key="${key^^}"
  if [ -z "$key" ]; then
    ui_h1 "Variables de entorno"
    ui_table_cols 34 14 11
    ui_th VARIABLE ARCHIVO TIPO
    first=0
    while IFS=$'\t' read -r tag rest; do
      if [ "$tag" = "H" ]; then
        IFS='|' read -r k f t d <<< "$rest"
        k="${k# }"; k="${k% }"; f="${f# }"; f="${f% }"; t="${t# }"; t="${t% }"
        case "$t" in obligatoria) first="err" ;; fija) first="dim" ;; *) first="" ;; esac
        ui_tr "bold:$k" "$f" "${first:+$first:}$t"
      fi
    done < <(help_var_records "")
    printf '\n'
    ui_hint "Detalle de una variable: ./itc help variable <NOMBRE>"
    return 0
  fi

  first=1
  while IFS=$'\t' read -r tag rest; do
    if [ "$tag" = "H" ]; then
      IFS='|' read -r k f t d <<< "$rest"
      k="${k# }"; k="${k% }"; f="${f# }"; f="${f% }"; t="${t# }"; t="${t% }"; d="${d# }"; d="${d% }"
      ui_h1 "$k  ($f)"
      ui_kv "archivo" "$f" 12
      ui_kv "tipo" "$t" 12
      ui_kv "por defecto" "${d:-ninguno}" 12
      printf '\n'
      first=0
    else
      printf '  %s\n' "$(ui_inline "$rest")"
    fi
  done < <(help_var_records "$key")
  if [ "$first" -eq 1 ]; then
    warn "no hay una variable llamada '$key' en el glosario"
    local near
    near="$(grep -E '^@ ' "$HELP_DIR/variables.txt" | grep -iF -- "${key:0:4}" | cut -d' ' -f2 | sort -u | head -5 | tr '\n' ' ')"
    [ -z "$near" ] || info "Parecidas: $near"
    info "Lista completa: ./itc help variable"
    return 1
  fi
}

help_search() { # texto...
  local q="$*" f n found=0
  [ -n "$q" ] || die "uso: ./itc help buscar <texto>"
  for f in "$HELP_DIR"/*.txt; do
    grep -qiF -- "$q" "$f" || continue
    n="$(basename "$f" .txt)"
    case "$n" in
      cmd-*) n="${n#cmd-}" ;;
      topic-*) n="${n#topic-}" ;;
      variables) n="variable" ;;
      overview) n="" ;;
    esac
    found=1
    ui_h2 "./itc help $n"
    grep -iF -m3 -- "$q" "$f" | while IFS= read -r line; do printf '    %s\n' "$(ui_inline "$line")"; done
  done
  [ "$found" -eq 1 ] || { warn "no hay coincidencias para '$q' en la ayuda"; return 1; }
}

cmd_help() {
  local what="${1:-}"
  case "$what" in
    "" | overview) help_overview ;;
    -h | --help) help_page help ;;
    topics | temas) help_topics_list ;;
    variable | variables | var) shift; help_variable "${1:-}" ;;
    buscar | search) shift; help_search "$@" ;;
    *) help_page "$what" ;;
  esac
}

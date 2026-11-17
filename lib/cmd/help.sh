#!/usr/bin/env bash
# ./deltactl help [command | topic | variable [KEY] | search <text>]
# The help lives in lib/help/*.txt (a single source of truth); this file only looks it up and shows it.
#   cmd-<command>.txt   one page per command
#   topic-<topic>.txt   full guides
#   overview.txt        main screen
#   variables.txt       glossary of the variables of .env.instance, .env.s0 and .env.s1
# tests/test-help.sh checks that every command, topic and variable has its page.
#
# The page files are still Spanish; the labels and messages around them come from the catalogs.

HELP_DIR="$ROOT/lib/help"
# shellcheck disable=SC2034  # read by completion.sh and the tests
HELP_COMMANDS=(new init adopt deploy rollback stop down load images versions list status ps logs check doctor menu completion help)
# Topic ids as the page files are named (topic-<id>.txt). topic_label shows them in the UI language.
HELP_TOPICS=(nueva-instancia instancia-existente actualizar imagenes servicios red datos secretos archivos puertos solucion-problemas glosario)

# Title (first line "# ...") of a help page.
help_title() { # file
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '# '*) printf '%s' "${line#\# }"; return 0 ;; esac
  done < "$1"
}

help_topics_list() {
  local t
  ui_h2 "$(t help.guides)"
  for t in "${HELP_TOPICS[@]}"; do
    printf '  %s%-24s%s %s\n' "$C_GRN" "$(topic_label "$t")" "$C_OFF" "$(help_title "$HELP_DIR/topic-$t.txt")"
  done
}

help_overview() {
  ui_banner
  ui_render_file "$HELP_DIR/overview.txt"
  help_topics_list
  printf '\n'
  ui_hint "$(t help.hint_variables)"
  ui_hint "$(t help.hint_search)"
  ui_hint "$(t help.hint_flag)"
}

# Suggestions for a name that does not exist: pages whose name looks similar.
help_unknown() { # text
  local q="$1" f n found=0
  warn "$(t help.no_page "$q")"
  for f in "$HELP_DIR"/cmd-*.txt "$HELP_DIR"/topic-*.txt; do
    n="$(basename "$f" .txt)"
    n="${n#cmd-}"
    n="${n#topic-}"
    case "$n" in *"$q"* | "${q:0:3}"*)
      [ "$found" -eq 1 ] || info "$(t help.did_you_mean)"
      found=1
      info "  ./deltactl help $n"
      ;;
    esac
  done
  info "$(t help.full_index "$q")"
  return 1
}

help_page() { # name
  local n="$1" f
  [ "$n" != "versions" ] || n=images
  # A guide may be asked for by its English id or its Spanish name; the page files still use the Spanish ids.
  n="$(topic_file_id "$n")"
  for f in "$HELP_DIR/cmd-$n.txt" "$HELP_DIR/topic-$n.txt"; do
    if [ -f "$f" ]; then
      ui_render_file "$f"
      printf '\n'
      return 0
    fi
  done
  help_unknown "$1"
}

# "H<TAB>header" and "T<TAB>line" records of the variables that match the key (all of them if none).
help_var_records() { # [KEY]
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

help_variable() { # [KEY]
  local key="${1:-}" tag rest k f t d first
  key="${key^^}"
  if [ -z "$key" ]; then
    ui_h1 "$(t help.vars_title)"
    ui_table_cols 34 14 11
    ui_th "$(t help.col.variable)" "$(t help.col.file)" "$(t help.col.type)"
    first=0
    while IFS=$'\t' read -r tag rest; do
      if [ "$tag" = "H" ]; then
        IFS='|' read -r k f t d <<< "$rest"
        k="${k# }"; k="${k% }"; f="${f# }"; f="${f% }"; t="${t# }"; t="${t% }"
        # The type words come from the glossary page (Spanish today, English once it is translated).
        case "$t" in obligatoria | required) first="err" ;; fija | fixed) first="dim" ;; *) first="" ;; esac
        ui_tr "bold:$k" "$f" "${first:+$first:}$t"
      fi
    done < <(help_var_records "")
    printf '\n'
    ui_hint "$(t help.var_detail_hint)"
    return 0
  fi

  first=1
  while IFS=$'\t' read -r tag rest; do
    if [ "$tag" = "H" ]; then
      IFS='|' read -r k f t d <<< "$rest"
      k="${k# }"; k="${k% }"; f="${f# }"; f="${f% }"; t="${t# }"; t="${t% }"; d="${d# }"; d="${d% }"
      ui_h1 "$k  ($f)"
      ui_kv "$(t help.kv.file)" "$f" 12
      ui_kv "$(t help.kv.type)" "$t" 12
      ui_kv "$(t help.kv.default)" "${d:-$(t help.kv.none)}" 12
      printf '\n'
      first=0
    else
      printf '  %s\n' "$(ui_inline "$rest")"
    fi
  done < <(help_var_records "$key")
  if [ "$first" -eq 1 ]; then
    warn "$(t help.no_variable "$key")"
    local near
    near="$(grep -E '^@ ' "$HELP_DIR/variables.txt" | grep -iF -- "${key:0:4}" | cut -d' ' -f2 | sort -u | head -5 | tr '\n' ' ')"
    [ -z "$near" ] || info "$(t help.similar "$near")"
    info "$(t help.full_list)"
    return 1
  fi
}

help_search() { # text...
  local q="$*" f n found=0
  [ -n "$q" ] || die "$(t help.search_usage)"
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
    ui_h2 "./deltactl help $n"
    grep -iF -m3 -- "$q" "$f" | while IFS= read -r line; do printf '    %s\n' "$(ui_inline "$line")"; done
  done
  [ "$found" -eq 1 ] || { warn "$(t help.search_none "$q")"; return 1; }
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

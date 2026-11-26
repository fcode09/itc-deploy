#!/usr/bin/env bash
# ./deltactl help [command | topic | variable [KEY] | search <text>]
# The help lives in lib/help (a single source of truth); this file only looks it up and shows it.
#   cmd-<command>.txt   one page per command
#   topic-<topic>.txt   full guides
#   overview.txt        main screen
#   variables.txt       glossary of the variables of .env.instance, .env.s0 and .env.s1
# tests/test-help.sh checks that every command, topic and variable has its page.
#
# Spanish (the default UI language) pages live in lib/help/. Every other language has its pages in
# lib/help/<code>/ (lib/help/en/ for English) with English guide ids in the file names (topic-new-instance.txt).
# A page that is not translated yet is shown in Spanish. The labels and messages around the pages come
# from the catalogs.

HELP_DIR="$ROOT/lib/help"
# shellcheck disable=SC2034  # read by completion.sh and the tests
HELP_COMMANDS=(new init adopt deploy rollback stop down load images versions list status runs ps logs check doctor env service access menu completion help)
# Topic ids as the Spanish page files are named (topic-<id>.txt). topic_label shows them in the UI language.
HELP_TOPICS=(nueva-instancia instancia-existente actualizar imagenes servicios red datos secretos archivos puertos solucion-problemas glosario)

# Path of a help page in the active language, or of the Spanish one when it is not translated.
# usage: help_page_file overview | variables | cmd <command> | topic <guide id or name>
# It prints nothing and fails when there is no such page.
help_page_file() { # kind [id]
  local kind="$1" id="${2:-}" lang="${DELTACTL_LANG_ACTIVE:-es}" name f
  case "$kind" in
    cmd) name="cmd-$id.txt" ;;
    topic) name="topic-$(topic_canonical "$id").txt" ;;
    *) name="$kind.txt" ;;
  esac
  if [ "$lang" != "es" ]; then
    f="$HELP_DIR/$lang/$name"
    if [ -f "$f" ]; then
      printf '%s' "$f"
      return 0
    fi
  fi
  # Spanish page: the guide files keep their Spanish ids.
  if [ "$kind" = "topic" ]; then name="topic-$(topic_file_id "$id").txt"; fi
  f="$HELP_DIR/$name"
  [ -f "$f" ] || return 1
  printf '%s' "$f"
}

# Title (first line "# ...") of a help page.
help_title() { # file
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '# '*) printf '%s' "${line#\# }"; return 0 ;; esac
  done < "$1"
}

# A help page with its generated parts: the line "@@services@@" is replaced by the services of the catalog (lib/core/catalog.data),
# so a new service shows up in the guide without touching the page. Everything else goes through as it is.
help_expand() { # file
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "${line%$'\r'}" in
      '@@services@@') catalog_help_lines ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$1"
}

help_topics_list() {
  local t
  ui_h2 "$(t help.guides)"
  for t in "${HELP_TOPICS[@]}"; do
    printf '  %s%-24s%s %s\n' "$C_GRN" "$(topic_label "$t")" "$C_OFF" "$(help_title "$(help_page_file topic "$t")")"
  done
}

help_overview() {
  ui_banner
  ui_render_file "$(help_page_file overview)"
  help_topics_list
  printf '\n'
  ui_hint "$(t help.hint_variables)"
  ui_hint "$(t help.hint_search)"
  ui_hint "$(t help.hint_flag)"
}

# Suggestions for a name that does not exist: pages whose name looks similar (in the UI language).
help_unknown() { # text
  local q="$1" f n found=0
  warn "$(t help.no_page "$q")"
  for f in "$HELP_DIR"/cmd-*.txt "$HELP_DIR"/topic-*.txt; do
    n="$(basename "$f" .txt)"
    case "$n" in
      cmd-*) n="${n#cmd-}" ;;
      topic-*) n="$(topic_label "${n#topic-}")" ;;
    esac
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
  # A command page first; then a guide, asked for by its English id or its Spanish name.
  f="$(help_page_file cmd "$n" || true)"
  [ -n "$f" ] || f="$(help_page_file topic "$n" || true)"
  if [ -n "$f" ]; then
    ui_render_file <(help_expand "$f")
    printf '\n'
    return 0
  fi
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
  ' "$(help_page_file variables)"
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
        # The type words come from the glossary page, in the language of that page.
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
    near="$(grep -E '^@ ' "$(help_page_file variables)" | grep -iF -- "${key:0:4}" | cut -d' ' -f2 | sort -u | head -5 | tr '\n' ' ')"
    [ -z "$near" ] || info "$(t help.similar "$near")"
    info "$(t help.full_list)"
    return 1
  fi
}

# The lines of a help page as they are read: an item (-, !, >, |) with the lines that go on it (those that start with two spaces),
# joined into one, so a search finds an item whole, even a phrase that falls where the source line was cut.
help_logical_lines() { # file
  awk '{ sub(/\r$/, "") }
    /^  [^ ]/ && item { sub(/^ +/, ""); buf = buf " " $0; next }
    { if (started) print buf; buf = $0; started = 1; item = ($0 ~ /^(- |! |> |\| )/) }
    END { if (started) print buf }' "$1"
}

help_search() { # text...
  local q="$*" f base n pf found=0 lines line
  [ -n "$q" ] || die "$(t help.search_usage)"
  # The Spanish files give the list and the order; each page is searched in the UI language.
  for f in "$HELP_DIR"/*.txt; do
    base="$(basename "$f" .txt)"
    case "$base" in
      cmd-*) n="${base#cmd-}"; pf="$(help_page_file cmd "$n" || true)" ;;
      topic-*) n="$(topic_label "${base#topic-}")"; pf="$(help_page_file topic "${base#topic-}" || true)" ;;
      variables) n="variable"; pf="$(help_page_file variables || true)" ;;
      overview) n=""; pf="$(help_page_file overview || true)" ;;
      *) continue ;;
    esac
    [ -n "$pf" ] || pf="$f"
    lines="$(help_logical_lines <(help_expand "$pf"))"
    grep -qiF -- "$q" <<< "$lines" || continue
    found=1
    ui_h2 "./deltactl help $n"
    # (a command line is shown as it is, never cut; an item goes on under its text)
    while IFS= read -r line; do
      case "$line" in
        '$ '*) printf '    %s\n' "$line" ;;
        '- '* | '! '* | '> '*) ui_render_wrapped "${line:2}" "    ${line:0:2}" 6 ;;
        *) ui_render_wrapped "$line" "    " 4 ;;
      esac
    done < <(grep -iF -m3 -- "$q" <<< "$lines")
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

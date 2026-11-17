#!/usr/bin/env bash
# Tests of the i18n layer: language selection, message lookup, catalog consistency and help topic names.
# Runs from the root of the isolated copy made by tests/run.sh.
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS

ROOT="$PWD"
export ROOT
CFG="$(mktemp -d)"
trap 'rm -rf "$CFG"' EXIT

# Runs a snippet in a fresh shell with the common library loaded (it loads the i18n layer and `see`).
# The environment is given as arguments.
# usage: i18n_run 'DELTACTL_LANG=en' -- 'code'
i18n_run() {
  local -a envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  env -u DELTACTL_LANG -u DELTACTL_CONFIG -u DELTACTL_I18N_STRICT "${envs[@]}" bash -c 'source lib/bootstrap.sh; '"$1" 2>&1
}

section "1. language selection"
check "default language is Spanish" '[ "$(i18n_run DELTACTL_CONFIG=/nonexistent -- "echo \$DELTACTL_LANG_ACTIVE")" = "es" ]'
check "DELTACTL_LANG=en selects English" '[ "$(i18n_run DELTACTL_LANG=en -- "echo \$DELTACTL_LANG_ACTIVE")" = "en" ]'
check "DELTACTL_LANG is case-insensitive" '[ "$(i18n_run DELTACTL_LANG=EN -- "echo \$DELTACTL_LANG_ACTIVE")" = "en" ]'
check "an unsupported DELTACTL_LANG falls back to Spanish" '[ "$(i18n_run DELTACTL_LANG=fr DELTACTL_CONFIG=/nonexistent -- "echo \$DELTACTL_LANG_ACTIVE")" = "es" ]'
printf 'UI_LANG=en\n' > "$CFG/config"
check "the config file selects the language" '[ "$(i18n_run DELTACTL_CONFIG="$CFG/config" -- "echo \$DELTACTL_LANG_ACTIVE")" = "en" ]'
check "DELTACTL_LANG wins over the config file" '[ "$(i18n_run DELTACTL_LANG=es DELTACTL_CONFIG="$CFG/config" -- "echo \$DELTACTL_LANG_ACTIVE")" = "es" ]'
printf 'UI_LANG=xx\r\n' > "$CFG/bad"
check "an invalid config value falls back to Spanish" '[ "$(i18n_run DELTACTL_CONFIG="$CFG/bad" -- "echo \$DELTACTL_LANG_ACTIVE")" = "es" ]'
printf 'OTHER=1\r\nUI_LANG=EN\r\n' > "$CFG/crlf"
check "a config file with CRLF and uppercase still works" '[ "$(i18n_run DELTACTL_CONFIG="$CFG/crlf" -- "echo \$DELTACTL_LANG_ACTIVE")" = "en" ]'

section "2. message lookup"
check "t returns the Spanish text" '[ "$(i18n_run DELTACTL_LANG=es -- "t label.warn")" = "AVISO" ]'
check "t returns the English text" '[ "$(i18n_run DELTACTL_LANG=en -- "t label.warn")" = "WARN" ]'
check "placeholders are replaced" '[ "$(i18n_run DELTACTL_LANG=es -- "t err.instance_not_found colorado")" = "la instancia '"'"'colorado'"'"' no existe. Créala con: ./deltactl new colorado" ]'
check "an argument may contain & and braces literally" '[ "$(i18n_run DELTACTL_LANG=es -- "t err.service_unknown \"a&b\" \"{1}\"")" = "servicio desconocido: '"'"'a&b'"'"' (válidos: {1})" ]'
check "a missing key prints ??key??" '[ "$(i18n_run DELTACTL_LANG=en -- "t no.such.key")" = "??no.such.key??" ]'
check "strict mode makes a missing key an error" '! i18n_run DELTACTL_LANG=en DELTACTL_I18N_STRICT=1 -- "t no.such.key" >/dev/null'
check "a key missing in English falls back to Spanish" '[ "$(i18n_run DELTACTL_LANG=en -- "unset MSG_en[label.warn]; t label.warn")" = "AVISO" ]'
check "\\n in a message becomes a line break" '[ "$(i18n_run DELTACTL_LANG=es -- "MSG_es[x.y]=\"a\\\\nb\"; t x.y | wc -l")" = "1" ]'

section "3. both catalogs define the same keys and placeholders"
keys_of() { # lang
  bash -c 'ROOT="$PWD"; source lib/i18n/i18n.sh; DELTACTL_LANG='"$1"'; i18n_load_lang '"$1"'; for k in "${!MSG_'"$1"'[@]}"; do echo "$k"; done' | sort
}
check "es and en have exactly the same keys" 'diff <(keys_of es) <(keys_of en)'
placeholders_of() { # lang
  bash -c 'ROOT="$PWD"; source lib/i18n/i18n.sh; i18n_load_lang '"$1"'; for k in $(printf "%s\n" "${!MSG_'"$1"'[@]}" | sort); do v="${MSG_'"$1"'[$k]}"; printf "%s:" "$k"; grep -oE "\{[0-9]\}" <<<"$v" | sort -u | tr "\n" " "; echo; done'
}
check "es and en use the same placeholders in every message" 'diff <(placeholders_of es) <(placeholders_of en)'
check "no catalog message contains a printf-style %s (use {1})" '! grep -nE "MSG_(es|en)\[.*\]=.*%[sd]" lib/i18n/*/*.sh'

section "4. every key used in the code exists in the catalog"
used_keys() {
  # t <key> / t "<key>" with a literal key (dynamic ones, like topic.$id, are skipped)
  grep -rhoE "\bt[[:space:]]+[\"']?[a-z_]+\.[a-z0-9_.-]+" lib deltactl --include='*.sh' --include=deltactl \
    | sed -E "s/^t[[:space:]]+[\"']?//" | grep -vE '[.-]$' | sort -u
}
check "the scan finds the keys in use" '[ "$(used_keys | wc -l)" -ge 20 ]'
check "every key used with t exists in es.sh" 'missing=0; for k in $(used_keys); do bash -c "ROOT=\"\$PWD\"; source lib/i18n/i18n.sh; [ -n \"\${MSG_es[$k]+x}\" ]" || { echo "missing: $k"; missing=1; }; done; [ "$missing" -eq 0 ]'

section "5. help topic names (English ids with Spanish aliases)"
check "every topic id has a name in both languages" 'for id in $(bash -c "ROOT=\"\$PWD\"; source lib/i18n/i18n.sh; echo \${TOPIC_IDS[*]}"); do for l in es en; do bash -c "ROOT=\"\$PWD\"; source lib/i18n/i18n.sh; i18n_load_lang $l; [ -n \"\${MSG_$l[topic.$id]+x}\" ]" || exit 1; done; done'
check "a Spanish alias maps to its English id" '[ "$(i18n_run -- "topic_canonical nueva-instancia")" = "new-instance" ]'
check "an English id maps back to the page file id" '[ "$(i18n_run -- "topic_file_id new-instance")" = "nueva-instancia" ]'
check "a command name is left alone" '[ "$(i18n_run -- "topic_label deploy")" = "deploy" ]'
check "see shows the Spanish name in Spanish" '[ "$(i18n_run DELTACTL_LANG=es -- "see new-instance")" = " (ayuda: ./deltactl help nueva-instancia)" ]'
check "see shows the English name in English" '[ "$(i18n_run DELTACTL_LANG=en -- "see nueva-instancia")" = " (help: ./deltactl help new-instance)" ]'
check "help new-instance shows the same page as help nueva-instancia" 'diff <(DELTACTL_LANG=en bash ./deltactl help new-instance 2>&1) <(DELTACTL_LANG=es bash ./deltactl help nueva-instancia 2>&1)'
check "help local-images shows the images guide" 'DELTACTL_LANG=en bash ./deltactl help local-images 2>&1 | grep -q "Imágenes locales\|imágenes"'
check "help images is still the command page" 'DELTACTL_UI=plain bash ./deltactl help images 2>&1 | grep -q "./deltactl images"'

section "6. the English interface"
check "unknown command: English message and hint" 'out="$(DELTACTL_LANG=en bash ./deltactl frobnicate 2>&1)"; echo "$out" | grep -q "^WARN unknown command: frobnicate" && echo "$out" | grep -q "help search frobnicate"'
check "missing instance: English message" 'DELTACTL_LANG=en bash ./deltactl deploy 2>&1 | grep -q "^ERROR missing instance name. Usage: ./deltactl deploy <instance>"'
check "unknown instance: English message with the help hint" 'DELTACTL_LANG=en bash ./deltactl status nonexistent 2>&1 | grep -q "does not exist. Create it with: ./deltactl new nonexistent (help: ./deltactl help new-instance)"'
check "the Spanish interface is unchanged" 'DELTACTL_LANG=es bash ./deltactl deploy 2>&1 | grep -q "^ERROR falta el nombre de la instancia. Uso: ./deltactl deploy <instancia>"'
check "the default (no DELTACTL_LANG) is Spanish" 'env -u DELTACTL_LANG DELTACTL_CONFIG=/nonexistent bash ./deltactl deploy 2>&1 | grep -q "^ERROR falta el nombre"'

check "load without a file: English usage" 'DELTACTL_LANG=en bash ./deltactl load 2>&1 | grep -q "^ERROR usage: ./deltactl load <file.tar|file.tar.gz>"'
check "load of a missing file: English message" 'DELTACTL_LANG=en bash ./deltactl load /no/such.tar 2>&1 | grep -q "^ERROR the file does not exist: /no/such.tar"'
check "list without instances: English hint" 'DELTACTL_LANG=en bash ./deltactl list 2>&1 | grep -q "(no instances; create one with ./deltactl new <instance>)"'
check "list header is translated" 'DELTACTL_LANG=en bash ./deltactl list 2>&1 | grep -q "^INSTANCE .*SERVICES"'
check "stop without a service: English usage" 'bash ./deltactl new i18n-tmp >/dev/null 2>&1; out="$(DELTACTL_LANG=en bash ./deltactl stop i18n-tmp 2>&1)"; rm -rf instances/i18n-tmp; echo "$out" | grep -q "usage: ./deltactl stop <instance> <service>"'

check "images with a bad option: English message" 'DELTACTL_LANG=en bash ./deltactl images --bogus 2>&1 | grep -q "^ERROR unknown option: --bogus (see ./deltactl help images)"'
check "completion without a shell: English usage" 'DELTACTL_LANG=en bash ./deltactl completion 2>&1 | grep -q "^ERROR usage: ./deltactl completion bash"'
check "completion for another shell: English message" 'DELTACTL_LANG=en bash ./deltactl completion zsh 2>&1 | grep -q "completion is only available for bash (got: .zsh.)"'
check "help index: English guides heading and hints" 'out="$(DELTACTL_LANG=en DELTACTL_UI=plain bash ./deltactl help 2>&1)"; echo "$out" | grep -q "^Guides  (./deltactl help <topic>)" && echo "$out" | grep -q "Search:     ./deltactl help search <text>"'
check "help guide names are English in the English index" 'DELTACTL_LANG=en DELTACTL_UI=plain bash ./deltactl help 2>&1 | grep -qE "^  (new-instance|troubleshooting) "'
check "help variable: unknown variable in English" 'DELTACTL_LANG=en bash ./deltactl help variable NO_SUCH_VAR 2>&1 | grep -q "there is no variable named .NO_SUCH_VAR. in the glossary"'
check "help search: English usage" 'DELTACTL_LANG=en bash ./deltactl help search 2>&1 | grep -q "^ERROR usage: ./deltactl help search <text>"'

check "check with a bad option: English message" 'DELTACTL_LANG=en bash ./deltactl check x --bogus 2>&1 | grep -q "^ERROR unknown option: --bogus (see ./deltactl help check)"'
check "adopt: English messages (done, then already marked)" 'bash ./deltactl new i18n-ad >/dev/null 2>&1; a="$(DELTACTL_LANG=en bash ./deltactl adopt i18n-ad 2>&1)"; b="$(DELTACTL_LANG=en bash ./deltactl adopt i18n-ad 2>&1)"; rm -rf instances/i18n-ad; echo "$a" | grep -q "^OK instance .i18n-ad. marked as existing" && echo "$b" | grep -q "^ERROR .i18n-ad. is already marked (existing): nothing to do"'
check "adopt: Spanish messages are unchanged" 'bash ./deltactl new i18n-ad >/dev/null 2>&1; a="$(DELTACTL_LANG=es bash ./deltactl adopt i18n-ad 2>&1)"; rm -rf instances/i18n-ad; echo "$a" | grep -q "^OK instancia .i18n-ad. marcada como existente"'
check "preflight validations: English warnings" 'printf "A=\nB=CAMBIAR_X\n" > "$CFG/e"; out="$(DELTACTL_LANG=en bash -c '"'"'ROOT="$PWD"; source lib/bootstrap.sh; source lib/cmd/deploy.sh; check_required "$1" A B'"'"' _ "$CFG/e" 2>&1)"; echo "$out" | grep -q "^WARN e: A is empty (help: ./deltactl help variable A)" && echo "$out" | grep -q "^WARN e: B still has the example value"'
check "check strips the English labels from captured messages" 'out="$(printf "WARN one\nERROR two\n" | DELTACTL_LANG=en bash -c '"'"'ROOT="$PWD"; source lib/bootstrap.sh; source lib/cmd/check.sh; ck_lines'"'"')"; [ "$out" = "$(printf "one\ntwo")" ]'

check "the dynamic doctor tool keys exist in both languages" 'for k in ss openssl gunzip; do for l in es en; do bash -c "ROOT=\"\$PWD\"; source lib/i18n/i18n.sh; i18n_load_lang $l; [ -n \"\${MSG_$l[doctor.tool_missing.$k]+x}\" ] && [ -n \"\${MSG_$l[doctor.tool_missing_hint.$k]+x}\" ]" || exit 1; done; done'
check "doctor with an argument: English message" 'DELTACTL_LANG=en bash ./deltactl doctor extra 2>&1 | grep -q "^ERROR doctor takes no arguments (see ./deltactl help doctor)"'
check "new with a bad option: English message" 'DELTACTL_LANG=en bash ./deltactl new --bogus 2>&1 | grep -q "^ERROR unknown option: --bogus"'
check "new without a name: English usage" 'DELTACTL_LANG=en bash ./deltactl new < /dev/null 2>&1 | grep -q "^ERROR usage: ./deltactl new <instance>"'
check "new creates an instance and prints the English next steps" 'out="$(DELTACTL_LANG=en bash ./deltactl new i18n-nw 2>&1)"; rm -rf instances/i18n-nw; echo "$out" | grep -q "^OK instance .i18n-nw. created in .* (ports [0-9]*/[0-9]*)" && echo "$out" | grep -q "^Next steps:" && echo "$out" | grep -q "full guide: ./deltactl help new-instance"'
check "new: the Spanish output is unchanged" 'out="$(DELTACTL_LANG=es bash ./deltactl new i18n-nw 2>&1)"; rm -rf instances/i18n-nw; echo "$out" | grep -q "^OK instancia .i18n-nw. creada en" && echo "$out" | grep -q "^Siguientes pasos:" && echo "$out" | grep -q "guía completa: ./deltactl help nueva-instancia"'

check "every menu option has a label and a description in both languages" 'for k in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do for l in es en; do bash -c "ROOT=\"\$PWD\"; source lib/i18n/i18n.sh; i18n_load_lang $l; [ -n \"\${MSG_$l[menu.opt.$k.label]+x}\" ] && [ -n \"\${MSG_$l[menu.opt.$k.desc]+x}\" ]" || exit 1; done; done'
check "menu with an argument: English message" 'DELTACTL_LANG=en bash ./deltactl menu extra 2>&1 | grep -q "^ERROR menu takes no arguments (see ./deltactl help menu)"'
check "menu: English title, options and prompt" 'out="$(printf "0\n" | DELTACTL_LANG=en DELTACTL_UI=plain bash ./deltactl menu 2>&1)"; echo "$out" | grep -q "^Menu" && echo "$out" | grep -q "1) View status" && echo "$out" | grep -q "0) Quit" && echo "$out" | grep -q "Choose an option (with ? first, help: ?4):"'
check "menu: an invalid option is reported in English" 'printf "99\n0\n" | DELTACTL_LANG=en DELTACTL_UI=plain bash ./deltactl menu 2>&1 | grep -q "WARN invalid option: .99. (choose a number from the menu or 0 to quit)"'
check "menu: the help of option 5 (update) resolves the English guide id" 'out="$(printf "?5\n0\n" | DELTACTL_LANG=en DELTACTL_UI=plain bash ./deltactl menu 2>&1)"; ! echo "$out" | grep -q "there is no help for"'

check "status without instances: English title and hint" 'out="$(DELTACTL_LANG=en DELTACTL_UI=plain bash ./deltactl status 2>&1)"; echo "$out" | grep -q "^Status of the instances" && echo "$out" | grep -q "(no instances; create one with ./deltactl new <instance>)"'
check "status with a bad option: English message" 'DELTACTL_LANG=en bash ./deltactl status --bogus 2>&1 | grep -q "^ERROR unknown option: --bogus (see ./deltactl help status)"'
check "status --watch with --json: English message" 'DELTACTL_LANG=en bash ./deltactl status --watch --json 2>&1 | grep -q "^ERROR --watch needs a terminal and cannot be combined with --json"'
check "status table: English headers and data labels" 'bash ./deltactl new i18n-st >/dev/null 2>&1; bash ./deltactl adopt i18n-st >/dev/null 2>&1; en="$(DELTACTL_LANG=en DELTACTL_UI=plain bash ./deltactl status 2>&1)"; es="$(DELTACTL_LANG=es DELTACTL_UI=plain bash ./deltactl status 2>&1)"; rm -rf instances/i18n-st; echo "$en" | grep -q "^INSTANCE .*RUNNING" && echo "$en" | grep "i18n-st" | grep -q "existing" && echo "$es" | grep -q "^INSTANCIA .*CORRIENDO" && echo "$es" | grep "i18n-st" | grep -q "existente"'
check "status --json does not depend on the language" 'bash ./deltactl new i18n-st >/dev/null 2>&1; a="$(DELTACTL_LANG=es bash ./deltactl status --json 2>&1)"; b="$(DELTACTL_LANG=en bash ./deltactl status --json 2>&1)"; rm -rf instances/i18n-st; [ "$a" = "$b" ] && echo "$a" | grep -q "\"data\":\"unseeded\""'
check "status detail: English labels" 'bash ./deltactl new i18n-st >/dev/null 2>&1; out="$(DELTACTL_LANG=en DELTACTL_UI=plain bash ./deltactl status i18n-st 2>&1)"; rm -rf instances/i18n-st; echo "$out" | grep -q "^Instance i18n-st" && echo "$out" | grep -q "Service s0" && echo "$out" | grep -qE "^  version +configured"'


section "7. the code is English: Spanish lives only in the catalogs, the help pages and the templates"
check "no accented letters or inverted punctuation in the code" '! LC_ALL=C.UTF-8 grep -rnE "[áéíóúñÁÉÍÓÚÑ¿¡]" deltactl lib/bootstrap.sh lib/cmd lib/core lib/ui lib/adapters lib/i18n/i18n.sh'
check "every lib/cmd command has a catalog file in both languages (or needs none)" 'for c in ops load list rollback images completion help check deploy init doctor new menu status; do for l in es en; do [ -f "lib/i18n/$l/$c.sh" ] || { echo "missing lib/i18n/$l/$c.sh"; exit 1; }; done; done'


section "8. help pages by language (English in lib/help/en with fallback to the Spanish page)"
mkdir -p "$CFG/h/en"
touch "$CFG/h/cmd-a.txt" "$CFG/h/cmd-b.txt" "$CFG/h/en/cmd-a.txt" "$CFG/h/topic-nueva-instancia.txt" "$CFG/h/en/topic-new-instance.txt" "$CFG/h/topic-red.txt"
hf() { # lang kind [id]
  local lang="$1"
  shift
  DELTACTL_LANG="$lang" bash -c 'ROOT="$PWD"; source lib/bootstrap.sh; source lib/cmd/help.sh; HELP_DIR="$1"; shift; help_page_file "$@"' _ "$CFG/h" "$@"
}
check "English prefers its own page" '[ "$(hf en cmd a)" = "$CFG/h/en/cmd-a.txt" ]'
check "English falls back to the Spanish page when it is not translated" '[ "$(hf en cmd b)" = "$CFG/h/cmd-b.txt" ]'
check "Spanish never uses the English folder" '[ "$(hf es cmd a)" = "$CFG/h/cmd-a.txt" ]'
check "a guide is found by its English id in English" '[ "$(hf en topic new-instance)" = "$CFG/h/en/topic-new-instance.txt" ]'
check "a guide is found by its Spanish name in English" '[ "$(hf en topic nueva-instancia)" = "$CFG/h/en/topic-new-instance.txt" ]'
check "a guide is found by its English id in Spanish" '[ "$(hf es topic new-instance)" = "$CFG/h/topic-nueva-instancia.txt" ]'
check "an untranslated guide falls back to the Spanish file" '[ "$(hf en topic network)" = "$CFG/h/topic-red.txt" ]'
check "a page that does not exist is an error" '! hf es cmd zzz >/dev/null && ! hf en topic zzz >/dev/null'
check "help for an unknown page in English" 'DELTACTL_LANG=en bash ./deltactl help nosuchpage 2>&1 | grep -q "there is no help for .nosuchpage."'


section "9. English help pages match their Spanish originals"
# Spanish page that corresponds to an English one (guide files are named by English id in lib/help/en).
es_page() { # english page path
  local name id es
  name="$(basename "$1")"
  case "$name" in
    topic-*)
      id="${name#topic-}"
      id="${id%.txt}"
      es="$(bash -c 'ROOT="$PWD"; source lib/i18n/i18n.sh; topic_file_id "$1"' _ "$id")"
      printf 'lib/help/topic-%s.txt' "$es"
      ;;
    *) printf 'lib/help/%s' "$name" ;;
  esac
}
# Command words of the "$ ./deltactl <word>" lines and of the "| <word>" rows, in order, plus every option mentioned.
help_signature() { # file
  grep -oE '^(\$ \./deltactl [a-z]+|\| [a-z]+)' "$1" | sed -E 's/^\$ \.\/deltactl //; s/^\| //' | tr '\n' ' '
  echo
  grep -oE -- '--[a-z][a-z-]*' "$1" | sort -u | tr '\n' ' '
  echo
}
en_pages="$(ls lib/help/en/*.txt 2>/dev/null)"
check "there are English pages to compare" '[ -n "$en_pages" ]'
check "every English page has a Spanish original" 'for p in $en_pages; do [ -f "$(es_page "$p")" ] || { echo "no original for $p"; exit 1; }; done'
check "commands and options match the Spanish page" 'for p in $en_pages; do case "$(basename "$p")" in variables.txt) continue ;; esac; diff <(help_signature "$p") <(help_signature "$(es_page "$p")") >/dev/null || { echo "differs: $p"; exit 1; }; done'
glossary_keys() { grep -E "^@ " "$1" | awk -F" [|] " "{ sub(/^@ /, \"\", \$1); print \$1 \" \" \$2 }"; }
check "the English glossary has the same variables, files and order" '[ ! -f lib/help/en/variables.txt ] || diff <(glossary_keys lib/help/en/variables.txt) <(glossary_keys lib/help/variables.txt) >/dev/null'
glossary_types() { grep -E "^@ " "$1" | awk -F" [|] " "{ print \$3 }" | sed -e "s/obligatoria/required/" -e "s/opcional/optional/" -e "s/fija/fixed/"; }
check "the English glossary types are required, optional or fixed, as in Spanish" '[ ! -f lib/help/en/variables.txt ] || diff <(glossary_types lib/help/en/variables.txt) <(glossary_types lib/help/variables.txt) >/dev/null'
check "English pages fit in 130 columns" '! awk "length(\$0) > 130 { exit 1 }" lib/help/en/*.txt'
check "English pages have no accented letters or inverted punctuation" '! LC_ALL=C.UTF-8 grep -nE "[áéíóúñÁÉÍÓÚÑ¿¡]" lib/help/en/*.txt'
check "English pages refer to guides by English id" '! grep -nE "help (nueva-instancia|instancia-existente|actualizar|imagenes|servicios|red|datos|secretos|archivos|puertos|solucion-problemas|glosario)\b" lib/help/en/*.txt'

check "the English help overview is shown in English" 'out="$(DELTACTL_LANG=en DELTACTL_UI=plain bash ./deltactl help 2>&1)"; echo "$out" | grep -q "DELTACTL · help" && echo "$out" | grep -q "Deploys and operates one instance per municipality" && ! echo "$out" | grep -q "Despliega y opera"'
check "the English glossary answers help variable" 'out="$(DELTACTL_LANG=en DELTACTL_UI=plain bash ./deltactl help variable S0_TAG 2>&1)"; echo "$out" | grep -qE "^  type +required" && echo "$out" | grep -q "Tag (version) of the s0 image"'
check "the English glossary table uses English type words" 'DELTACTL_LANG=en DELTACTL_UI=plain bash ./deltactl help variable 2>&1 | grep "S0_TAG" | grep -q "required"'
check "the Spanish glossary is unchanged" 'DELTACTL_LANG=es DELTACTL_UI=plain bash ./deltactl help variable S0_TAG 2>&1 | grep -qE "^  tipo +obligatoria"'
check "help search finds English text in English" 'DELTACTL_LANG=en DELTACTL_UI=plain bash ./deltactl help search "private network" 2>&1 | grep -q "private network"'

finish

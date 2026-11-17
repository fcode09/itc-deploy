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
    | sed -E "s/^t[[:space:]]+[\"']?//" | sort -u
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

finish

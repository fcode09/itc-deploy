#!/usr/bin/env bash
# Internationalization layer of ./deltactl: language selection and message lookup.
# Sourced from lib.sh; not meant to be executed.
#
# Source code, comments and identifiers are English. Everything the user reads lives in catalogs:
#   lib/i18n/es.sh   Spanish (the default UI language, and the fallback for any missing key)
#   lib/i18n/en.sh   English
#
# Messages use numbered placeholders {1}..{9} instead of printf formats: bash printf has no positional
# arguments, and a translation must be free to reorder them. A literal newline is written as \n.
#
# The language is resolved once, when this file is sourced:
#   1. DELTACTL_LANG (es|en)
#   2. UI_LANG=<code> in the config file ($DELTACTL_CONFIG, else ${XDG_CONFIG_HOME:-$HOME/.config}/deltactl/config)
#   3. es
#
# Requires bash 4.3+ (namerefs). Test hook: DELTACTL_I18N_STRICT=1 makes a missing key an error instead of
# printing ??key??.

DELTACTL_SUPPORTED_LANGS=(es en)
DELTACTL_DEFAULT_LANG=es

# shellcheck disable=SC2034  # filled by the catalogs; read through a nameref in t
declare -gA MSG_es=()
# shellcheck disable=SC2034
declare -gA MSG_en=()

# Is $1 a supported language code?
i18n_valid_lang() {
  local l
  for l in "${DELTACTL_SUPPORTED_LANGS[@]}"; do [ "$l" = "$1" ] && return 0; done
  return 1
}

# Path of the user config file (it may not exist).
i18n_config_file() {
  printf '%s' "${DELTACTL_CONFIG:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/deltactl/config}"
}

# Language stored in the config file, or nothing.
i18n_config_lang() {
  local f line val=""
  f="$(i18n_config_file)"
  [ -r "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in UI_LANG=*) val="${line#UI_LANG=}" ;; esac
  done < "$f"
  printf '%s' "${val,,}"
}

# Chooses the language (see the order above) and loads its catalog. Spanish is always loaded: it is the
# fallback for keys missing in another language.
i18n_init() {
  local want="${DELTACTL_LANG:-}"
  want="${want,,}"
  i18n_valid_lang "$want" || want="$(i18n_config_lang)"
  i18n_valid_lang "$want" || want="$DELTACTL_DEFAULT_LANG"
  DELTACTL_LANG_ACTIVE="$want"
  # shellcheck source=lib/i18n/es.sh
  source "$ROOT/lib/i18n/es.sh"
  if [ "$want" != "es" ]; then
    # shellcheck source=/dev/null
    source "$ROOT/lib/i18n/$want.sh"
  fi
}

# t <key> [arg1 ... arg9]   prints the message of the active language with {1}..{9} replaced.
# Falls back to Spanish, then to ??key??.
t() {
  local key="$1" msg a i=1
  shift
  local -n _t_cat="MSG_${DELTACTL_LANG_ACTIVE:-$DELTACTL_DEFAULT_LANG}"
  if [ -n "${_t_cat[$key]+x}" ]; then
    msg="${_t_cat[$key]}"
  elif [ -n "${MSG_es[$key]+x}" ]; then
    msg="${MSG_es[$key]}"
  else
    if [ "${DELTACTL_I18N_STRICT:-0}" = "1" ]; then
      printf 'i18n: missing key %s\n' "$key" >&2
      return 1
    fi
    printf '??%s??' "$key"
    return 0
  fi
  for a in "$@"; do
    msg=${msg//"{$i}"/"$a"}
    i=$((i + 1))
  done
  msg=${msg//\\n/$'\n'}
  printf '%s' "$msg"
}

# --- Help topics -------------------------------------------------------------------------------------
# Each guide has an English id (used in code) and a display name per language (catalog key topic.<id>).
# The Spanish names were the original ids, so they stay valid as aliases: ./deltactl help nueva-instancia
# keeps working. (The help page files are still named after the Spanish ids until the help is moved to
# per-language folders.)
# shellcheck disable=SC2034  # the list of valid ids is read by the tests and by the help
TOPIC_IDS=(new-instance existing-instance update local-images services network data secrets files ports troubleshooting glossary)
declare -gA TOPIC_LEGACY=(
  [nueva-instancia]=new-instance
  [instancia-existente]=existing-instance
  [actualizar]=update
  [imagenes]=local-images
  [servicios]=services
  [red]=network
  [datos]=data
  [secretos]=secrets
  [archivos]=files
  [puertos]=ports
  [solucion-problemas]=troubleshooting
  [glosario]=glossary
)

# Any accepted name (English id or Spanish alias) -> English id. Anything else is returned unchanged.
topic_canonical() { # name
  printf '%s' "${TOPIC_LEGACY[$1]:-$1}"
}

# Any accepted name -> the id of the help page file (the Spanish one, for now).
topic_file_id() { # name
  local k
  for k in "${!TOPIC_LEGACY[@]}"; do
    if [ "${TOPIC_LEGACY[$k]}" = "$1" ]; then
      printf '%s' "$k"
      return 0
    fi
  done
  printf '%s' "$1"
}

# Name to show the user for a help topic or command, in the active language.
topic_label() { # name
  local id
  id="$(topic_canonical "$1")"
  if [ -n "${MSG_es[topic.$id]+x}" ]; then t "topic.$id"; else printf '%s' "$1"; fi
}

i18n_init

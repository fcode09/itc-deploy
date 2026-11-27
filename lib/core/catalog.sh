#!/usr/bin/env bash
# shellcheck disable=SC2034  # tables read by the commands, the screens and the tests; REQUIRED_<SN> are named at run time
# Service catalog as data. Sourced by lib/bootstrap.sh right after config.sh; requires ROOT.
# lib/core/catalog.data defines every service once; from it come KNOWN_SERVICES, the default image name, the required
# variables (REQUIRED_<SN>), the Mongo URI variables, the data folders and the help text of the services.

KNOWN_SERVICES=()
declare -gA CAT_NAME=() CAT_REPO=() CAT_PORT=() CAT_OFFSET=() CAT_TEMPLATE=() CAT_REQUIRED=() CAT_MONGO=() CAT_DEPENDS=() \
  CAT_MEM=() CAT_DATA=() CAT_SECRET_FILES=() CAT_SECRETS=()

# Reads the data file. It starts no process: every field is split by `read`.
catalog_load() { # [file]
  local file="${1:-$ROOT/lib/core/catalog.data}" key name repo port offset tpl req mongo deps mem data sfiles secrets
  KNOWN_SERVICES=()
  CAT_NAME=() CAT_REPO=() CAT_PORT=() CAT_OFFSET=() CAT_TEMPLATE=() CAT_REQUIRED=() CAT_MONGO=() CAT_DEPENDS=()
  CAT_MEM=() CAT_DATA=() CAT_SECRET_FILES=() CAT_SECRETS=()
  [ -r "$file" ] || return 1
  while IFS='|' read -r key name repo port offset tpl req mongo deps mem data sfiles secrets || [ -n "$key" ]; do
    key="${key%$'\r'}"
    case "$key" in '' | '#'*) continue ;; esac
    # a key is a lowercase word that starts with a letter (s0, s1, robin); "instance" is the name of .env.instance in --env-file
    { [[ "$key" =~ ^[a-z][a-z0-9]*$ ]] && [ "$key" != instance ]; } || continue
    KNOWN_SERVICES+=("$key")
    CAT_NAME[$key]="$name" CAT_REPO[$key]="$repo" CAT_PORT[$key]="$port" CAT_OFFSET[$key]="$offset"
    CAT_TEMPLATE[$key]="$tpl" CAT_REQUIRED[$key]="$req" CAT_MONGO[$key]="$mongo" CAT_DEPENDS[$key]="$deps"
    CAT_MEM[$key]="$mem" CAT_DATA[$key]="$data" CAT_SECRET_FILES[$key]="$sfiles" CAT_SECRETS[$key]="${secrets%$'\r'}"
    read -ra "REQUIRED_${key^^}" <<< "$req"
  done < "$file"
}
catalog_load

# Services on which the given one depends (soft: "if it runs in the instance"), one per line.
catalog_depends() { # service
  local d
  for d in ${CAT_DEPENDS[$1]:-}; do printf '%s\n' "$d"; done
}

# Lines of the "services" help guide: one item per service, in the UI language (what each one is comes from lib/i18n).
catalog_help_lines() {
  local s q=$'\x60'   # (the backtick, as the guides write a name)
  for s in "${KNOWN_SERVICES[@]}"; do
    printf -- '- %s%s%s %s %s. %s %s.\n' "$q" "$s" "$q" "${CAT_NAME[$s]}" "$(t "catalog.desc.$s")" "$(t catalog.internal_port)" "${CAT_PORT[$s]}"
  done
}

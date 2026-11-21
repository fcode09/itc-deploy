#!/usr/bin/env bash
# shellcheck disable=SC2034  # the DASH_* variables are shared with lib/cmd/dashboard.sh
# Aliases of the console: short names for the commands typed often. Sourced by lib/cmd/dashboard.sh.
#
#   alias                    lists them
#   alias up                 shows one
#   alias up=deploy colorado defines (or replaces) one
#   unalias up               removes it
#
# Typed as the first word of a line, an alias is replaced by its command and the rest of the line follows it: with
# `alias lg=logs colorado`, `lg s0 -f` runs `logs colorado s0 -f`. It is replaced once (an alias inside an alias is just a word).
#
# They live in a file next to the history (aliases, one `name=command` per line, mode 600), rewritten whole through a temporary
# file and a rename. The file is data: a line that is not a valid alias is skipped, never run. An alias runs exactly what typing
# its command would, so it can only hold deltactl commands and the panel's own: a line for the terminal (`!`) is refused, and so
# is a name that would hide a command.

declare -gA DASH_ALIAS=()
DASH_ALIAS_NAMES=()        # in the order they were defined
DASH_ALIAS_MAX_LEN=200

dash_alias_file() { printf '%s/aliases' "$(dirname "$(i18n_config_file)")"; }

# Can $1 be the name of an alias? Lowercase letters, digits, - and _ (up to 24), starting with a letter, and neither a deltactl
# command nor one of the panel's own.
dash_alias_valid_name() { # name
  local c
  [[ "$1" =~ ^[a-z][a-z0-9_-]{0,23}$ ]] || return 1
  for c in "${HELP_COMMANDS[@]}" "${DASH_BUILTINS[@]}" cls view '?'; do [ "$c" != "$1" ] || return 1; done
}

# Can $1 be the command of an alias? Not empty, not too long, no control characters and not for the terminal.
dash_alias_valid_cmd() { # command
  [ -n "${1//[[:space:]]/}" ] || return 1
  [ "${#1}" -le "$DASH_ALIAS_MAX_LEN" ] || return 1
  [[ "$1" != *[[:cntrl:]]* ]] || return 1
  [[ "${1#"${1%%[![:space:]]*}"}" != '!'* ]]
}

# Is $1 the name of an alias? (a text that cannot be a name is not even looked up)
dash_alias_known() { [[ "$1" =~ ^[a-z][a-z0-9_-]{0,23}$ ]] && [ -n "${DASH_ALIAS[$1]+x}" ]; }

# Sets one alias in memory (no check: the callers did it).
dash_alias_put() { # name command
  [ -n "${DASH_ALIAS[$1]+x}" ] || DASH_ALIAS_NAMES+=("$1")
  DASH_ALIAS[$1]="$2"
}

dash_alias_load() {
  local f line name cmd
  DASH_ALIAS=() DASH_ALIAS_NAMES=()
  f="$(dash_alias_file)"
  [ -r "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ "$line" == *=* ]] || continue
    name="${line%%=*}" cmd="${line#*=}"
    if ! dash_alias_valid_name "$name" || ! dash_alias_valid_cmd "$cmd"; then continue; fi
    dash_alias_put "$name" "$cmd"
  done 2>/dev/null < "$f"
}

# Writes every alias to the file. Returns 1 when it could not (the aliases then last until the panel ends).
dash_alias_save() {
  local f tmp n
  f="$(dash_alias_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  tmp="$(umask 077; mktemp "$f.XXXXXX" 2>/dev/null)" || return 1
  {
    if [ "${#DASH_ALIAS_NAMES[@]}" -gt 0 ]; then
      for n in "${DASH_ALIAS_NAMES[@]}"; do printf '%s=%s\n' "$n" "${DASH_ALIAS[$n]}"; done
    fi
  } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# The `alias` and `unalias` commands of the console. The words come as typed, split by spaces.
dash_alias_cmd() { # alias|unalias words...
  local what="$1" line name cmd n
  shift
  line="$*"
  if [ "$what" = "unalias" ]; then
    name="${1:-}"
    if [ "$#" -ne 1 ]; then dash_con_add "$C_YEL$(t tui.con.alias_usage)$C_OFF"; return 0; fi
    if ! dash_alias_known "$name"; then dash_con_add "$C_RED$(t tui.con.alias_unknown "$name")$C_OFF"; return 0; fi
    unset "DASH_ALIAS[$name]"
    local -a keep=()
    for n in "${DASH_ALIAS_NAMES[@]}"; do [ "$n" = "$name" ] || keep+=("$n"); done
    DASH_ALIAS_NAMES=()
    [ "${#keep[@]}" -eq 0 ] || DASH_ALIAS_NAMES=("${keep[@]}")
    dash_alias_save || dash_con_add "$C_YEL$(t tui.con.alias_not_saved)$C_OFF"
    dash_con_add "$(t tui.con.alias_removed "$name")"
    return 0
  fi
  if [ "$#" -eq 0 ]; then
    if [ "${#DASH_ALIAS_NAMES[@]}" -eq 0 ]; then dt tui.con.alias_none; dash_con_add "$C_GRY$DTV$C_OFF"; return 0; fi
    for n in "${DASH_ALIAS_NAMES[@]}"; do dash_con_add "  $n=${DASH_ALIAS[$n]}"; done
    return 0
  fi
  if [[ "$line" != *=* ]]; then
    if [ "$#" -eq 1 ] && dash_alias_known "$1"; then dash_con_add "  $1=${DASH_ALIAS[$1]}"
    elif [ "$#" -eq 1 ]; then dash_con_add "$C_RED$(t tui.con.alias_unknown "$1")$C_OFF"
    else dash_con_add "$C_YEL$(t tui.con.alias_usage)$C_OFF"; fi
    return 0
  fi
  name="${line%%=*}" cmd="${line#*=}"
  cmd="${cmd#"${cmd%%[![:space:]]*}"}"
  if ! dash_alias_valid_name "$name"; then dash_con_add "$C_RED$(t tui.con.alias_bad_name "$name")$C_OFF"; return 0; fi
  if ! dash_alias_valid_cmd "$cmd"; then dash_con_add "$C_RED$(t tui.con.alias_bad_cmd "$DASH_ALIAS_MAX_LEN")$C_OFF"; return 0; fi
  dash_alias_put "$name" "$cmd"
  dash_alias_save || dash_con_add "$C_YEL$(t tui.con.alias_not_saved)$C_OFF"
  dash_con_add "$(t tui.con.alias_set "$name" "$cmd")"
}

# A line whose first word is an alias, with the alias replaced. Into DASH_ALIAS_LINE (the line itself when it has none).
dash_alias_expand() { # line
  local line="$1" first rest
  DASH_ALIAS_LINE="$line"
  first="${line%%[[:space:]]*}"
  rest="${line:${#first}}"
  dash_alias_known "$first" || return 0
  DASH_ALIAS_LINE="${DASH_ALIAS[$first]}$rest"
}
DASH_ALIAS_LINE=""

#!/usr/bin/env bash
# Messages to the user: plain lines, labeled warnings and errors, help pointers, usage.
# Sourced by lib/bootstrap.sh after the i18n and ui layers.

info() { printf '%s\n' "$*"; }
ok()   { printf '%s%s%s %s\n' "$C_GRN" "$(t label.ok)" "$C_OFF" "$*"; }
warn() { printf '%s%s%s %s\n' "$E_YEL" "$(t label.warn)" "$E_OFF" "$*" >&2; }
die()  { printf '%s%s%s %s\n' "$E_RED" "$(t label.error)" "$E_OFF" "$*" >&2; exit 1; }
# Hint at the end of a message: "... (help: ./deltactl help <topic>)". Called through command
# substitution inside the message. It accepts a topic id, a legacy Spanish topic name or a command name.
see()  { t see.hint "$(topic_label "$1")"; }

usage() {
  # The full help lives in lib/help/ (see lib/cmd/help.sh).
  # shellcheck source=lib/cmd/help.sh
  source "$ROOT/lib/cmd/help.sh"
  help_overview
}

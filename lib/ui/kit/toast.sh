#!/usr/bin/env bash
# shellcheck disable=SC2034  # KT_TOAST_* are read by the views and the tests
# UI kit: the toast, a short confirmation that shows for a few seconds ("✔ S0_TAG saved") instead of dirtying the console. Sourced
# after lib/ui/tui.sh, lib/ui/tokens.sh and lib/ui/kit/state.sh; pure Bash, no fork.
#
#   kit_toast_set <ok|warn|err|info> <text> [seconds]   shows it (default 3 s)
#   kit_toast_active                                    returns 0 while there is one to show
#   kit_toast_line <width>                              -> KIT_OUT: the toast as one line of exactly <width> cells (blank when none)
#   kit_toast_clear
# The clock is $KIT_NOW when set (tests), else $SECONDS.

KT_TOAST_KIND="" KT_TOAST_TEXT="" KT_TOAST_UNTIL=0

kit_toast_set() { # kind text [seconds]
  KT_TOAST_KIND="$1" KT_TOAST_TEXT="$2"
  KT_TOAST_UNTIL=$((${KIT_NOW:-$SECONDS} + ${3:-3}))
}
kit_toast_clear() { KT_TOAST_TEXT="" KT_TOAST_UNTIL=0; }
kit_toast_active() { [ -n "$KT_TOAST_TEXT" ] && [ "${KIT_NOW:-$SECONDS}" -lt "$KT_TOAST_UNTIL" ]; }
kit_toast_line() { # width
  local w="$1"
  if ! kit_toast_active; then tui_fit "" "$w"; KIT_OUT="$TUI_OUT"; return 0; fi
  kit_state_icon "$KT_TOAST_KIND"
  tui_fit " $KIT_ICON $KT_TOAST_TEXT " "$w"
  KIT_OUT="${TH[sel]:-}$TUI_OUT$TH_RESET"
}

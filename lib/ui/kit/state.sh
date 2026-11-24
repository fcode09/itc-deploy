#!/usr/bin/env bash
# shellcheck disable=SC2034  # KIT_ICON and KIT_COL are read by the other kit components
# UI kit: the vocabulary of states every component shares (the checklist, the field, the stepper, the toast): one icon and one colour
# each, taken from the theme tokens. Sourced after lib/ui/tokens.sh; pure Bash, no fork.
#
#   kit_state_color <state>   -> KIT_COL   the colour sequence of a state
#   kit_state_icon <state>    -> KIT_ICON  the icon of a state, coloured and reset
# States: ok (●) · warn (▲) · err (✖) · pend (○, also "pending") · run (◐) · info (ℹ) · dim (·). An unknown state is dim.
# Without colour the icon alone says it (and in ASCII: * ! x . ~ i), so a state is never only a colour.

KIT_COL="" KIT_ICON=""

kit_state_color() { # state
  case "$1" in
    ok) KIT_COL="${TH[ok]:-}" ;;
    warn) KIT_COL="${TH[warn]:-}" ;;
    err) KIT_COL="${TH[err]:-}" ;;
    run) KIT_COL="${TH[accent]:-}" ;;
    info) KIT_COL="${TH[info]:-}" ;;
    *) KIT_COL="${TH[dim]:-}" ;;
  esac
}

kit_state_icon() { # state
  local sym
  kit_state_color "$1"
  case "$1" in
    ok) sym="$UI_S_OK" ;;
    warn) sym="$UI_S_WARN" ;;
    err) sym="$UI_S_ERR" ;;
    pend | pending) sym="$UI_S_PEND" ;;
    run) sym="$UI_S_RUN" ;;
    info) sym="$UI_S_INFO" ;;
    *) sym="$UI_S_DOT" ;;
  esac
  KIT_ICON="$KIT_COL$sym$TH_RESET"
}

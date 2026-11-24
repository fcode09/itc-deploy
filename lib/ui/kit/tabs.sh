#!/usr/bin/env bash
# shellcheck disable=SC2034  # KT_* results are read by the views and the tests
# UI kit: tabs on one line (Resumen  Servicios  Variables ...). Sourced after lib/ui/tui.sh, lib/ui/tokens.sh and lib/ui/kit/box.sh;
# pure Bash, no fork.
#
#   kit_tabs <width> <active> <label> ...     -> KT_LINE (exactly <width> cells), KT_COLS, KT_WID
# <active> is 1-based. Labels accept the shortcut markup of box.sh (^r for the letter r). The open tab is drawn as a badge (without
# colour: [Name] instead of " Name "). When the tabs do not fit, the line scrolls to keep the open one in view and shows ‹ and ›
# at the ends. KT_COLS has the first column (0-based, as drawn) of every tab that is visible, "" for the ones that are not, and
# KT_WID the width of each tab, so a click can find its tab.

KT_LINE="" KT_COLS=() KT_WID=()

kit_tabs() { # width active label...
  local w="$1" act="$2" n i first last total lab plain pw out="" left_more=0 right_more=0 col=0 seg badge_on
  local -a P=() W=() T=()
  shift 2
  n=$#
  KT_LINE="" KT_COLS=() KT_WID=()
  [ "$n" -gt 0 ] || return 0
  i=0
  for lab in "$@"; do
    i=$((i + 1))
    kit_plain "$lab"; P[i]="$KIT_OUT"
    W[i]=$((${#KIT_OUT} + 2))
    KT_WID[i - 1]="${W[$i]}"
  done
  # The window of tabs that is shown: from `first` to `last`, widening around the open one until the width is used.
  first=$act last=$act
  total=${W[$act]}
  while :; do
    if [ "$first" -gt 1 ] && [ $((total + W[first - 1])) -le "$w" ]; then first=$((first - 1)); total=$((total + W[first])); continue; fi
    if [ "$last" -lt "$n" ] && [ $((total + W[last + 1])) -le "$w" ]; then last=$((last + 1)); total=$((total + W[last])); continue; fi
    break
  done
  [ "$first" -le 1 ] || left_more=1
  [ "$last" -ge "$n" ] || right_more=1
  for ((i = 1; i <= n; i++)); do KT_COLS[i - 1]=""; done
  for ((i = first; i <= last; i++)); do
    lab="${!i}"
    if [ "$i" -eq "$act" ]; then
      if [ -n "${TH[badge]:-}" ]; then
        kit_chip_plain "$lab"; seg="${TH[badge]} $KIT_OUT $TH_RESET"
      else
        kit_chip_plain "$lab"; seg="[$KIT_OUT]"
      fi
    else
      kit_hotkey "$lab" "${TH[dim]:-}"; seg="${TH[dim]:-} $KIT_OUT $TH_RESET"
    fi
    KT_COLS[i - 1]="$col"
    col=$((col + W[i]))
    out+="$seg"
  done
  if [ "$left_more" -eq 1 ] || [ "$right_more" -eq 1 ]; then
    local la="‹" ra="›"
    [ "${UI_UTF8:-0}" -eq 1 ] && [ "${UI_RICH:-0}" -eq 1 ] || { la="<" ra=">"; }
    # the arrows replace the first / last cell of the line (a margin of the edge tabs)
    tui_fit "$out" "$w"; out="$TUI_OUT"
    if [ "$left_more" -eq 1 ]; then kit_slice "$out" 1 $((w - 1)); out="${TH[accent]:-}$la$TH_RESET$KIT_OUT"; fi
    if [ "$right_more" -eq 1 ]; then kit_slice "$out" 0 $((w - 1)); out="$KIT_OUT${TH[accent]:-}$ra$TH_RESET"; fi
  fi
  tui_fit "$out" "$w"; KT_LINE="$TUI_OUT"
}

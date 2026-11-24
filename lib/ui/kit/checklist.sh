#!/usr/bin/env bash
# shellcheck disable=SC2034  # KCK_* results are read by the views and the tests
# UI kit: the checklist, rows that say what is done and what is left AND what Enter does about it ("Para desplegar"). Sourced after
# lib/ui/tui.sh, lib/ui/tokens.sh and lib/ui/kit/state.sh; pure Bash, no fork.
#
#   kit_checklist <width> <items-array> [sel=N]    -> KCK_LINES (one per item; the selected one starts with TUI_SEL),
#                                                     KCK_OK (items done), KCK_TOTAL, KCK_NEXT (index of the first one not done, -1)
# Items, one element each: "state|title|detail|action": state ok | warn | err | pend | run; detail is a faint text after the title;
# action is what Enter does ("completar"), drawn at the right as "⏎ completar" in the accent colour; an item that is ok has none
# unless it gives one. The title column is as wide as the longest title (at most a third of the width).

KCK_LINES=() KCK_OK=0 KCK_TOTAL=0 KCK_NEXT=-1

kit_checklist() { # width items [sel=N]
  local w="$1" sel=-1 i n tw=0 st title detail action icon left act aw dw line
  local -n _items="$2"
  local -a S=() T=() D=() A=()
  [[ "${3:-}" != sel=* ]] || sel="${3#sel=}"
  n="${#_items[@]}"
  KCK_LINES=() KCK_OK=0 KCK_TOTAL="$n" KCK_NEXT=-1
  for ((i = 0; i < n; i++)); do
    st="${_items[$i]%%|*}"; line="${_items[$i]#*|}"
    title="${line%%|*}"; line="${line#*|}"
    detail="${line%%|*}"; action="${line#*|}"
    [ "$action" != "$line" ] || action=""
    S[i]="$st" T[i]="$title" D[i]="$detail" A[i]="$action"
    [ "${#title}" -le "$tw" ] || tw="${#title}"
    if [ "$st" = ok ]; then KCK_OK=$((KCK_OK + 1)); elif [ "$KCK_NEXT" -lt 0 ]; then KCK_NEXT="$i"; fi
  done
  [ "$tw" -le $((w / 3)) ] || tw=$((w / 3))
  for ((i = 0; i < n; i++)); do
    kit_state_icon "${S[$i]}"; icon="$KIT_ICON"
    tui_fit "${T[$i]}" "$tw"; left="$icon $TUI_OUT"
    act=""; aw=0
    if [ -n "${A[$i]}" ]; then act="${TH[accent]:-}$C_BLD$UI_S_ENTER ${A[$i]}$TH_RESET"; aw=$((${#UI_S_ENTER} + 1 + ${#A[i]})); fi
    dw=$((w - 2 - tw - 2 - (aw > 0 ? aw + 2 : 0)))
    if [ "$dw" -lt 0 ]; then dw=0; fi
    tui_fit "${TH[dim]:-}${D[$i]}$TH_RESET" "$dw"
    line="$left  $TUI_OUT"
    [ "$aw" -eq 0 ] || line+="  $act"
    tui_fit "$line" "$w"; line="$TUI_OUT"
    if [ "$i" -eq "$sel" ]; then KCK_LINES+=("$TUI_SEL$line"); else KCK_LINES+=("$line"); fi
  done
}

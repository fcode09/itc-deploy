#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1010  # KS_* results are read by the views and the tests; "done" is a state name
# UI kit: the stepper, a row of numbered steps with the state of each one (the progress bar of the new-instance wizard). Sourced after
# lib/ui/tui.sh, lib/ui/tokens.sh and lib/ui/kit/state.sh; pure Bash, no fork.
#
#   kit_stepper <width> <current> [counter=<text>] <label:state> ...      -> KS_LINES (2 lines), KS_COLS, KS_CW
# <current> is the step that is open (1-based). A step is "label:state" with state done | active | todo | warn | err; if the state is
# left out it is derived from <current> (before it: done, it: active, after it: todo). Line 1 holds the marks and the connectors
# (●━━━━◉━━━━○), line 2 the labels; counter= (for example "Paso 3 de 8") goes at the right of line 1, or of line 2, when there is room.
# KS_COLS has the first column (0-based) of every step and KS_CW the width of a step, so a click can find its step.
# In a narrow terminal (a step would be under 7 cells) the labels give way: line 2 shows only the open step as "3/8 label".

KS_LINES=() KS_COLS=() KS_CW=0

kit_stepper() { # width current [counter=text] label[:state] ...
  local w="$1" cur="$2" counter="" n i lab st cw mark conn marks="" labels="" lw pad col sc used open_label="" mark_on mark_off
  local -a L=() S=()
  shift 2
  if [[ "${1:-}" == counter=* ]]; then counter="${1#counter=}"; shift; fi
  n=$#
  KS_LINES=() KS_COLS=() KS_CW=0
  [ "$n" -gt 0 ] || return 0
  i=0
  for lab in "$@"; do
    i=$((i + 1))
    st=""
    if [[ "$lab" == *:* ]]; then st="${lab##*:}"; lab="${lab%:*}"; fi
    if [ -z "$st" ]; then if [ "$i" -lt "$cur" ]; then st=done; elif [ "$i" -eq "$cur" ]; then st=active; else st=todo; fi; fi
    L[i]="$lab" S[i]="$st"
    [ "$st" != active ] || open_label="$lab"
  done
  cw=$((w / n))
  if [ "${UI_UTF8:-0}" -eq 1 ] && [ "${UI_RICH:-0}" -eq 1 ]; then mark_on="◉"; else mark_on="@"; fi
  mark_off="$UI_S_STEP_OFF"
  KS_CW="$cw"
  for ((i = 1; i <= n; i++)); do
    case "${S[$i]}" in
      done) kit_state_color ok; mark="$KIT_COL$UI_S_OK$TH_RESET" ;;
      active) mark="${TH[accent]:-}$C_BLD$mark_on$TH_RESET" ;;
      warn) kit_state_icon warn; mark="$KIT_ICON" ;;
      err) kit_state_icon err; mark="$KIT_ICON" ;;
      *) mark="${TH[dim]:-}$UI_S_PEND$TH_RESET" ;;
    esac
    # (the connector after a step is solid when that step is done, faint otherwise)
    if [ "${S[$i]}" = done ]; then conn="${TH[ok]:-}"; else conn="${TH[faint]:-}"; fi
    if [ "$cw" -ge 7 ]; then
      KS_COLS[i - 1]=$(((i - 1) * cw))
      if [ "$i" -lt "$n" ]; then
        printf -v pad '%*s' $((cw - 1)) ''
        marks+="$mark$conn${pad// /$UI_S_STEP_ON}$TH_RESET"
      else
        marks+="$mark"
        used=$((cw * (n - 1) + 1))
        [ "$used" -ge "$w" ] || { printf -v pad '%*s' $((w - used)) ''; marks+="$pad"; }
      fi
      tui_fit "${L[$i]}" $((cw - 1)); lw="$TUI_OUT"
      if [ "${S[$i]}" = active ]; then labels+="${TH[accent]:-}$C_BLD$lw$TH_RESET "
      elif [ "${S[$i]}" = todo ]; then labels+="${TH[dim]:-}$lw$TH_RESET "
      else labels+="$lw "; fi
    else
      # compact: one cell per step plus one for the connector
      KS_COLS[i - 1]=$(((i - 1) * 2))
      marks+="$mark"
      if [ "$i" -lt "$n" ]; then marks+="$conn$UI_S_STEP_ON$TH_RESET"; fi
    fi
  done
  # The counter goes at the right of the marks line when the last step leaves room for it there, else at the right of the labels.
  local on_marks=0 on_labels=0
  if [ -n "$counter" ] && [ "$cw" -ge 7 ]; then
    if [ $(((n - 1) * cw + 2 + ${#counter})) -lt "$w" ]; then on_marks=1
    elif [ $(((n - 1) * cw + ${#L[n]} + 1 + ${#counter})) -lt "$w" ]; then on_labels=1; fi
  fi
  if [ "$on_marks" -eq 1 ]; then
    tui_fit "$marks" $((w - ${#counter})); marks="$TUI_OUT${TH[dim]:-}$counter$TH_RESET"
  fi
  tui_fit "$marks" "$w"; KS_LINES[0]="$TUI_OUT"
  if [ "$cw" -ge 7 ]; then
    if [ "$on_labels" -eq 1 ]; then
      tui_fit "$labels" $((w - ${#counter})); labels="$TUI_OUT${TH[dim]:-}$counter$TH_RESET"
    fi
    tui_fit "$labels" "$w"; KS_LINES[1]="$TUI_OUT"
  else
    tui_fit "${TH[accent]:-}$C_BLD$cur/$n$TH_RESET $open_label" "$w"; KS_LINES[1]="$TUI_OUT"
  fi
}

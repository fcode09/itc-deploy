#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153  # KM_LINES and KIT_OUT are read by the callers; KG_LINES comes from graph_braille.sh
# UI kit: the row of a metric as btop draws memory: "label ····· value", the percentage under it and a small graph of its own in
# the colour of its magnitude. Sourced after lib/ui/tui.sh, lib/ui/tokens.sh and graph_braille.sh; pure Bash, no fork.
#
#   kit_leader <label> <value> <width>                 -> KIT_OUT: label at the left, value at the right, dots between (faint)
#   kit_metric_row <label> <value> <percent> <hist> <max|auto> <width> <graph-rows> [magnitude]
#                                                      -> KM_LINES: the leader line, the percentage line and the graph lines
# Both fit exactly <width> cells; a label that does not fit is cut (with …) before the value.

KM_LINES=()

kit_leader() { # label value width
  local l="$1" v="$2" w="$3" lw vw gap run
  tui_vlen "$l"; lw="$TUI_VL"
  tui_vlen "$v"; vw="$TUI_VL"
  if [ $((lw + vw + 3)) -gt "$w" ]; then
    # The label gives way (the value is what the row is for).
    lw=$((w - vw - 3))
    if [ "$lw" -lt 1 ]; then tui_fit "$v" "$w"; KIT_OUT="$TUI_OUT"; return 0; fi
    tui_clip "$l" $((lw - 1)); l="$TUI_OUT$UI_S_ELL"
  fi
  tui_vlen "$l"; lw="$TUI_VL"
  gap=$((w - lw - vw - 2))
  printf -v run '%*s' "$gap" ''
  KIT_OUT="$l ${TH[track]:-}${run// /$UI_S_LEAD}$TH_RESET $v"
}

kit_metric_row() { # label value percent hist max width graph-rows [magnitude]
  local label="$1" value="$2" pct="$3" hist="$4" max="$5" w="$6" gr="$7" mag="${8:-ramp}"
  KM_LINES=()
  kit_leader "$label" "$value" "$w"; KM_LINES+=("$KIT_OUT")
  th_grad "$mag" "${pct:-0}"
  tui_fit "${TH_C}${pct}%${TH_RESET}" "$w"; KM_LINES+=("$TUI_OUT")
  if [ "$gr" -gt 0 ]; then
    kit_graph "$hist" "$max" "$w" "$gr" "mag=$mag" zero=1
    KM_LINES+=("${KG_LINES[@]}")
  fi
}

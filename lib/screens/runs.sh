#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Screen: Runs (view 4). The history of the operations that changed something, with their consumption and saved logs.

scr_runs_render() { dash_view_runs "$2"; } # width height
scr_runs_key() { dash_key_runs "$1"; }
# The statistics and the log viewer have their own hints.
scr_runs_keys() { # width
  local kv=runs
  { [ "$DASH_RUNS_MODE" != "stats" ] && [ "$DASH_RUNS_MODE" != "log" ]; } || kv="runs_$DASH_RUNS_MODE"
  dash_keys_view "$kv" "$1"
}
scr_runs_texts() {
  DASH_KEYS[runs]="$(t tui.keys.runs "$DASH_UD")"
  DASH_KEYS[runs_stats]="$(t tui.keys.runs_stats)"
  DASH_KEYS[runs_log]="$(t tui.keys.runs_log "$DASH_UD")"
}
scr_runs_sig() {
  DASH_SIG+="|$DASH_RUNS_SEL|$DASH_RUNS_OFF|$DASH_RUNS_MODE|$DASH_RUNS_N|$DASH_RUNS_STATS_INST|$DASH_RV_TOP|$DASH_RV_END|$DASH_RV_TOTAL"
}
# Esc closes the statistics (or the log) before it leaves the view.
scr_runs_back() { [ "$DASH_RUNS_MODE" != "list" ] || return 1; DASH_RUNS_MODE=list; }
scr_runs_tick() { dash_runs_tick; }

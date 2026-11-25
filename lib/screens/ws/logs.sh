#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Tab of the workspace: Logs. The logs pane of the selected service (lib/screens/instances_logs.sh) with the whole workspace for itself. On a
# wide screen the same pane already sits under the summary, so the tab is hidden there; on the others it is the way to the logs.
# Loaded by lib/screens/instances_ws.sh (dash_ws_register).

ws_logs_avail() { # instance
  [ -n "${DASH_SVCS[$1]:-}" ] && ! dash_overview_fits
}

ws_logs_box() { # instance width height
  local name="$1" svc
  local -a svcs shown=()
  read -ra svcs <<< "${DASH_SVCS[$name]:-}"
  svc="${svcs[$DASH_SVC]:-${svcs[0]:-}}"
  if [ -z "$svc" ]; then
    dt tui.logs.none; shown=("$C_GRY$DTV$C_OFF")
    tui_box "" "$2" "$3" shown
    return 0
  fi
  dash_logs_box "$name/$svc" "$svc" "$2" "$3"
}

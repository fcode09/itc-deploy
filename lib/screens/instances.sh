#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# shellcheck disable=SC2034  # DASH_* variables are shared with the rest of the panel
# Screen: Instances (view 1). The list of instances, the detail of the selected one (its services, figures, charts, logs and next
# steps) and the strip of the console. Wide screens get the Overview; small ones the compact view; `z` zooms one pane.

scr_instances_render() { # width height
  if [ "$DASH_ZOOM" -eq 1 ]; then dash_view_zoom "$2"
  elif dash_overview_fits; then dash_view_overview "$2"
  else dash_view_instances "$2"; fi
}

scr_instances_key() { dash_key_instances "$1"; }

# The hints follow the focus: on the New button, inside the services, or on the list of instances.
scr_instances_keys() { # width
  local kv=instances
  if [ "$DASH_ZOOM" -eq 1 ]; then kv=zoom
  elif [ "$DASH_ON_NEW" -eq 1 ]; then kv=new
  elif [ "$DASH_FOCUS" = "svc" ]; then kv=services
  elif [ "$DASH_FOCUS" = "logs" ]; then kv=logs; fi
  dash_keys_view "$kv" "$1"
}

scr_instances_texts() {
  DASH_KEYS[instances]="$(t tui.keys.instances "$DASH_UD" "$DASH_RIGHT")"
  DASH_KEYS[services]="$(t tui.keys.services "$DASH_UD" "$DASH_LEFT")"
  DASH_KEYS[new]="$(t tui.keys.new "$DASH_UD")"
  DASH_KEYS[logs]="$(t tui.keys.logs "$DASH_UD" "$DASH_LEFT")"
  DASH_KEYS[zoom]="$(t tui.keys.zoom "$DASH_UD")"
}

scr_instances_sig() {
  DASH_SIG+="|$DASH_SEL|$DASH_SVC|$DASH_FOCUS|$DASH_ON_NEW|$DASH_ZOOM|$DASH_LOG_SCROLL|$DASH_LOG_FILTER"
  DASH_SIG+="|$DASH_LOG_ERRONLY|$DASH_LOG_FIND|$DASH_LS_PAUSED|$DASH_LS_PEND|$DASH_LOG_MIDX"
}

# Tab walks the panes (list, services, logs) instead of leaving the view.
scr_instances_tab() { dash_focus_cycle "$1"; }

# Esc: the zoom first, then one step back to the list; with nothing left to close it returns 1 (the router then quits).
scr_instances_back() {
  if [ "$DASH_ZOOM" -eq 1 ]; then DASH_ZOOM=0
  elif [ "$DASH_FOCUS" != "list" ]; then DASH_FOCUS=list
  else return 1; fi
}

scr_instances_tick() { dash_ls_tick; }

scr_instances_poll() {
  # The log tail of the selected service: only while the overview shows it, and every 5 s.
  if dash_overview_fits && dash_current_target; then
    local lk="$DASH_T_INST/$DASH_T_SVC"
    # While the user reads older lines the log stands still (no new request); a focused pane refreshes faster.
    local every=5
    [ "$DASH_FOCUS" != "logs" ] || every=3
    # (a stream feeds the pane when there is one; paused, the pane stands still)
    if [ "${ST_STATE[$lk]:-}" = "running" ] && [ "$DASH_LOG_SCROLL" -eq 0 ] && [ "$DASH_LS_PAUSED" -eq 0 ] && ! dash_ls_active "$lk" && { [ -z "${DASH_LOGS_AT[$lk]:-}" ] || [ $((SECONDS - DASH_LOGS_AT[$lk])) -ge "$every" ]; }; then
      dash_logs_request "$lk"
    fi
  fi
  # Error counts of the selected instance: when the user pauses on it, then every 30 s.
  if [ "$DASH_IDLE" -eq 1 ] && [ "$DASH_ON_NEW" -eq 0 ] && [ "${#DASH_NAMES[@]}" -gt 0 ]; then
    local sel="${DASH_NAMES[$DASH_SEL]}"
    if [ -z "${DASH_ERRS_AT[$sel]:-}" ] || [ $((SECONDS - DASH_ERRS_AT[$sel])) -ge $((DASH_AWAY == 1 ? 120 : 30)) ]; then dash_errors_request "$sel"; fi
  fi
}

# A click on the list: the New button, or an instance (a second click on the selected one opens its actions).
scr_instances_click() { # column row
  local x="$1" y="$2" j i n="${#DASH_NAMES[@]}"
  { [ "$DASH_LIST_SHOWN" -eq 1 ] && [ "$x" -le "$DASH_LIST_W" ]; } || return 0
  if [ "$y" -eq 4 ]; then
    if [ "$DASH_ON_NEW" -eq 1 ] && [ "$DASH_FOCUS" = "list" ]; then dash_key_instances enter; else DASH_ON_NEW=1 DASH_SVC=0 DASH_DET_OFF=0 DASH_FOCUS=list; fi
    return 0
  fi
  [ "$n" -gt 0 ] || return 0
  j=$((y - 6))
  { [ "$j" -ge 0 ] && [ "$j" -lt "$DASH_LIST_AVAIL" ]; } || return 0
  i=$((DASH_LIST_START + j))
  [ "$i" -lt "$n" ] || return 0
  if [ "$DASH_ON_NEW" -eq 0 ] && [ "$i" -eq "$DASH_SEL" ] && [ "$DASH_FOCUS" = "list" ]; then dash_key_instances enter; return 0; fi
  DASH_ON_NEW=0 DASH_SEL="$i" DASH_SVC=0 DASH_DET_OFF=0 DASH_FOCUS=list
}

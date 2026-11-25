#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Mode: the filter of the list of instances (`/` while the list or the workspace has the focus; with the logs pane focused `/` filters its
# lines, see lib/screens/filter.sh). The list narrows as the text is typed; Enter keeps it, Esc leaves the list as it was, an empty line
# shows every instance again. The prompt is the last line of the list's own box.

scr_lfilter_key() { # key
  case "$1" in
    enter)
      DASH_LIST_FILTER="$DASH_BUF" DASH_MODE=normal DASH_CUR=0 DASH_LIST_OFF=0
      dash_list_order
      dash_list_pos
      # The instance in the workspace is one the list shows: when the filter hides it, the first one that matches takes its place.
      if [ "$DASH_VPOS" -lt 0 ] && [ "${#DASH_VIS[@]}" -gt 0 ]; then DASH_SEL="${DASH_VIS[0]}" DASH_ON_NEW=0 DASH_SVC=0 DASH_DET_OFF=0 DASH_TODO_SEL=0; fi
      ;;
    esc) DASH_MODE=normal DASH_CUR=0; dash_msg info "$(t tui.msg.cancelled)" ;;
    *) dash_key_edit "$1" ;;
  esac
}
scr_lfilter_keys() { dt tui.keys.filter; dash_keyfit "$DTV" "$1"; TUI_FRAME+=(" $C_GRY$DASH_KF$C_OFF"); } # width
scr_lfilter_sig() { [ "$DASH_MODE" != "lfilter" ] || DASH_SIG+="|$DASH_BUF|$DASH_CUR"; }

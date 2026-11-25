#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Mode: the public domain of an instance, typed in the Access tab of its workspace (Enter on the tab). The line is the first one of the tab's box
# (lib/screens/ws/acceso.sh draws it with the cursor). Enter keeps a valid name (an empty line removes it) and leaves the line open when it is
# not a name; Esc leaves it as it was. Nothing is written to disk until the block is saved with g.

scr_accdom_key() { # key
  case "$1" in
    enter) if dash_acc_set_domain "$DASH_BUF"; then DASH_MODE=normal DASH_CUR=0; fi ;;
    esc) DASH_MODE=normal DASH_CUR=0; dash_msg info "$(t tui.msg.cancelled)" ;;
    *) dash_key_edit "$1" ;;
  esac
}
scr_accdom_keys() { dt tui.acc.keys.domain; dash_keyfit "$DTV" "$1"; TUI_FRAME+=(" $C_GRY$DASH_KF$C_OFF"); } # width
scr_accdom_sig() { [ "$DASH_MODE" != "accdom" ] || DASH_SIG+="|$DASH_BUF|$DASH_CUR"; }

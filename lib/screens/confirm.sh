#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Mode: a yes/no confirmation before an action that changes something.

scr_confirm_render() { dash_dialog_confirm "$2"; } # width height
scr_confirm_key() { dash_key_confirm "$1"; }
scr_confirm_keys() { # width
  if [ "$UI_UTF8" -eq 1 ] && [ "$UI_RICH" -eq 1 ]; then dt tui.confirm.keys; else dt tui.confirm.keys.ascii; fi
  dash_keyfit "$DTV" "$1"; TUI_FRAME+=(" $C_GRY$DASH_KF$C_OFF")
}
scr_confirm_sig() { DASH_SIG+="|$DASH_CONF_TEXT"; }

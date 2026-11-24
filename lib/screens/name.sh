#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Mode: type the name of the instance to confirm an action that cannot be undone.

scr_name_render() { dash_dialog_name "$2"; } # width height
scr_name_key() { dash_key_edit "$1"; }
scr_name_keys() { dt tui.name.keys; dash_keyfit "$DTV" "$1"; TUI_FRAME+=(" $C_GRY$DASH_KF$C_OFF"); } # width
scr_name_sig() {
  DASH_SIG+="|$DASH_NAME_TARGET"
  [ "$DASH_MODE" != "name" ] || DASH_SIG+="|$DASH_BUF"
}

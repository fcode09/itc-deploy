#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Mode: the new-instance form (n).

scr_wizard_render() { dash_dialog_wizard "$2"; } # width height
scr_wizard_key() { dash_key_wizard "$1"; }
scr_wizard_keys() { dash_nw_keys "$1"; TUI_FRAME+=(" $DASH_KBV"); } # width
scr_wizard_sig() {
  [ "$DASH_MODE" != "wizard" ] || DASH_SIG+="|$DASH_NW_V|$DASH_NW_SEC|$DASH_NW_F|$DASH_NW_FOCUS|$DASH_BUF|$DASH_CUR|$DASH_NW_ERR"
}

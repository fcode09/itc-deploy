#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Mode: the actions menu of an instance or service (Enter on an instance).

scr_menu_render() { dash_dialog_menu "$2"; } # width height
scr_menu_key() { dash_key_menu "$1"; }
scr_menu_keys() { # width
  dt tui.dialog.keys; dash_keyfit "${DTV//\{1\}/$DASH_UD}" "$1"; TUI_FRAME+=(" $C_GRY$DASH_KF$C_OFF")
}
scr_menu_sig() { DASH_SIG+="|$DASH_MENU_SEL"; }

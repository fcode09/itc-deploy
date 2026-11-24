#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Mode: the palette of actions (Ctrl+P).

scr_palette_render() { dash_dialog_palette "$2"; } # width height
scr_palette_key() { dash_key_palette "$1"; }
scr_palette_keys() { # width
  dt tui.pal.keys; dash_keyfit "${DTV//\{1\}/$DASH_UD}" "$1"; TUI_FRAME+=(" $C_GRY$DASH_KF$C_OFF")
}
scr_palette_sig() { DASH_SIG+="|$DASH_PAL_Q|$DASH_PAL_SEL"; }

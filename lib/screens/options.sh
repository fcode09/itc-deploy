#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Mode: the options screen (o).

scr_options_render() { dash_dialog_options "$2"; } # width height
scr_options_key() { dash_key_options "$1"; }
scr_options_keys() { # width
  local line
  dt tui.opt.keys; line="${DTV//\{1\}/$DASH_UD}"
  dash_keybar "${line//\{2\}/$DASH_LR}" "$1"; TUI_FRAME+=(" $DASH_KBV")
}
scr_options_sig() { DASH_SIG+="|$DASH_OPT_SEL|$DASH_OPT_N"; }

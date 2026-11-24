#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Screen: Console (view 6). The console of the Instances strip over the whole body. The key 6 gives the line the keyboard at once;
# Tab only shows the view.

scr_console_render() { dash_view_console "$2"; } # width height
scr_console_key() { dash_key_console "$1"; }
scr_console_keys() { dash_keys_view console "$1"; } # width
scr_console_texts() { DASH_KEYS[console]="$(t tui.keys.console "$DASH_UD")"; }
scr_console_sig() { DASH_SIG+="|$DASH_CON_N|$DASH_CON_SCROLL"; }
scr_console_enter() { dash_open_console; }
scr_console_click() { dash_key_console enter; } # column row

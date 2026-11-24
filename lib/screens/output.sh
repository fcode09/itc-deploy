#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Screen: Output (view 3). The full output of the last command, scrollable.

scr_output_render() { dash_view_output "$2"; } # width height
scr_output_key() { dash_key_output "$1"; }
scr_output_keys() { dash_keys_view output "$1"; } # width
scr_output_texts() { DASH_KEYS[output]="$(t tui.keys.output "$DASH_UD" "$DASH_LR")"; }
scr_output_sig() { DASH_SIG+="|$DASH_OUT_SCROLL|$DASH_OUT_ERRORS"; }

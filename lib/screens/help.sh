#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Mode: the keys screen (?).

scr_help_render() { dash_dialog_help "$2"; } # width height
scr_help_key() { dash_key_help "$1"; }
scr_help_keys() { dash_help_keys "$1"; TUI_FRAME+=(" $C_GRY$DASH_KF$C_OFF"); } # width
scr_help_sig() { DASH_SIG+="|$DASH_HELP_OFF"; }

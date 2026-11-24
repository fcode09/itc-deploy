#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Screen: Processes (view 5). What the running command is made of and what the panel itself costs.

scr_procs_render() { dash_view_procs "$2"; } # width height
scr_procs_key() { dash_key_procs "$1"; }
scr_procs_keys() { dash_keys_view procs "$1"; } # width
scr_procs_texts() { DASH_KEYS[procs]="$(t tui.keys.procs "$DASH_UD")"; }
scr_procs_sig() { DASH_SIG+="|$DASH_PROCS_N|$DASH_PROCS_OFF|$DASH_PC_TXT"; }
scr_procs_tick() { dash_procs_tick; }

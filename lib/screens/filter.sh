#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Mode: the text filter of the logs pane (`/`).

scr_filter_key() { dash_key_edit "$1"; }
scr_filter_keys() { dt tui.keys.filter; dash_keyfit "$DTV" "$1"; TUI_FRAME+=(" $C_GRY$DASH_KF$C_OFF"); } # width
scr_filter_sig() { [ "$DASH_MODE" != "filter" ] || DASH_SIG+="|$DASH_BUF|$DASH_CUR"; }

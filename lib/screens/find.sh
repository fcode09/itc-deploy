#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Mode: the search text of the logs pane (`s`).

scr_find_key() { dash_key_edit "$1"; }
scr_find_keys() { dt tui.keys.find; dash_keyfit "$DTV" "$1"; TUI_FRAME+=(" $C_GRY$DASH_KF$C_OFF"); } # width
scr_find_sig() { [ "$DASH_MODE" != "find" ] || DASH_SIG+="|$DASH_BUF|$DASH_CUR"; }

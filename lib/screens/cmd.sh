#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Mode: a command being typed (`:` or `!`, or the Console view). It draws nothing of its own: the console box (or the last line) shows it.

scr_cmd_key() { dash_key_edit "$1"; }
scr_cmd_keys() { # width
  local w="$1"
  if [ "$DASH_VIEW" = "instances" ] || [ "$DASH_VIEW" = "console" ]; then
    # The console box holds the prompt: the last line only lists the keys of the line editor.
    dt tui.con.keys; dash_keybar "${DTV//\{1\}/$DASH_UD}" "$w"
    TUI_FRAME+=(" $DASH_KBV")
    return 0
  fi
  dt tui.cmd.prompt
  TUI_FRAME+=(" $C_GRY$DTV$C_OFF $C_BLD:$C_OFF$DASH_BUF")
  tui_vlen " $DTV :$DASH_BUF"
  TUI_CURSOR="$TUI_ROWS;$((TUI_VL + 2))"
}
# The line is part of the body only inside the console box.
scr_cmd_sig() {
  { [ "$DASH_MODE" != "cmd" ] || { [ "$DASH_VIEW" != "instances" ] && [ "$DASH_VIEW" != "console" ]; }; } || DASH_SIG+="|$DASH_BUF|$DASH_CUR"
}

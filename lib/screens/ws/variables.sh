#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Tab of the workspace: Variables. The editor of the Variables view (lib/ui/kit/env_editor.sh, driven by lib/screens/env.sh) inside the workspace
# of the instance: its files grouped, what is still to fill in, the description of each variable, live validation, generated secrets, the ↻ of what
# is not deployed yet, save, and save and deploy. It is the SAME editor as view 9 (one model), so what is staged is kept when the tab or the view
# is left, and the instance in it does not change while there are changes: choosing another instance says so instead of losing them.
#
# The keyboard goes through the mode `envedit` (lib/screens/envedit.sh), as in the view: the one-letter keys are the editor's (`d` default,
# `r` show a secret, `g` generate...) and the keys it does not use reach the panel (the digits, Tab, ?, : and q; the left arrow goes back to
# the list). Opening the tab gives the editor the keyboard (ws_variables_enter). Loaded by lib/screens/instances_ws.sh (dash_ws_register).

ws_variables_avail() { # instance
  [ -n "$1" ]
}

# Puts the editor on the instance. Returns 1 when it cannot: it holds changes of another one.
dash_ws_vars_sync() { # instance
  [ "$DASH_ENV_INST" != "$1" ] || return 0
  if [ -n "$DASH_ENV_INST" ] && kee_dirty; then return 1; fi
  dash_env_load "$1"
}

ws_variables_enter() { # instance
  # (the same instance may have got a file since the editor read it)
  [ "$DASH_ENV_INST" != "$1" ] || dash_env_refresh_files || true
  if dash_ws_vars_sync "$1"; then DASH_MODE=envedit; else dash_msg warn "$(t tui.env.switch_dirty "$DASH_ENV_INST")"; fi
}

# The keys of the editor come through the mode; this only says that the tab has keys of its own (so it takes the focus).
ws_variables_key() { return 1; }

ws_variables_sig() {
  DASH_WS_SIG+="|$DASH_ENV_INST|$KEE_REV|$DASH_ENV_N|$KEE_EDIT|$KEE_PROMPT"
}

ws_variables_box() { # instance width height
  local name="$1" w="$2" h="$3" foc=0 msg
  local -a lines=()
  if [ "$DASH_MODE" = "envedit" ]; then foc=1; fi
  if ! dash_ws_vars_sync "$name"; then
    t_r tui.wsv.dirty "$DASH_ENV_INST" "$name"; msg="${TH[yellow]:-$C_YEL}$T_OUT$TH_RESET"
    lines=("" "$msg")
    while [ "${#lines[@]}" -lt $((h - 2)) ]; do lines+=(""); done
    kit_box "$w" "$h" lines "chips=$name"
    TUI_BOX=("${KIT_BOX[@]}")
    return 0
  fi
  kee_render "$w" "$h" "chips=$name" "focus=$foc"
  TUI_BOX=("${KEE_BOX[@]}")
}

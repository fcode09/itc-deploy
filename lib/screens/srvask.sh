#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Mode: a question about the server's requirements. For now one kind:
#   run   the Server view wants to run the install command of a requirement in the terminal. The command is shown whole and nothing runs
#         until the person answers y: deltactl never installs anything on its own.

DASH_SA_KIND="" DASH_SA_CMD=""

# Asks before running a command in the terminal.
dash_srv_ask_run() { # command
  DASH_SA_KIND=run DASH_SA_CMD="$1"
  DASH_MODE=srvask
}

dash_key_srvask() { # key
  local cmd="$DASH_SA_CMD"
  DASH_MODE=normal
  case "$1" in
    y | Y | s | S) dash_srv_terminal "$cmd" ;;
    *) dash_msg info "$(t tui.msg.cancelled)" ;;
  esac
}

dash_dialog_srvask() { # body_height
  local l title ww=66
  [ "$ww" -le $((TUI_COLS - 10)) ] || ww=$((TUI_COLS - 10))
  DASH_DLG=("")
  dt tui.srv.run.text; dash_wrap "$DTV" "$ww"
  for l in "${DASH_WRAP[@]}"; do DASH_DLG+=("  $l"); done
  DASH_DLG+=("")
  dash_wrap "$DASH_SA_CMD" "$ww"
  for l in "${DASH_WRAP[@]}"; do DASH_DLG+=("  ${TH[accent]:-$C_CYN}$l$C_OFF"); done
  DASH_DLG+=("")
  dt tui.srv.run.sudo; dash_wrap "$DTV" "$ww"
  for l in "${DASH_WRAP[@]}"; do DASH_DLG+=("  $C_GRY$l$C_OFF"); done
  DASH_DLG+=("")
  dt tui.srv.run.title; title="$DTV"
  dash_dialog "$1" "$title" 50
}

# --- The contract of lib/screens/registry.sh --------------------------------------------------------------------
scr_srvask_render() { dash_dialog_srvask "$2"; } # width height
scr_srvask_key() { dash_key_srvask "$1"; }
scr_srvask_keys() { # width
  local k=tui.srv.run.keys
  if [ "$UI_UTF8" -ne 1 ] || [ "$UI_RICH" -ne 1 ]; then k+=.ascii; fi
  dt "$k"
  dash_keyfit "$DTV" "$1"; TUI_FRAME+=(" $C_GRY$DASH_KF$C_OFF")
}
scr_srvask_sig() { DASH_SIG+="|$DASH_SA_KIND|$DASH_SA_CMD"; }

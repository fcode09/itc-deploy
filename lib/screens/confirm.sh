#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Mode: a yes/no confirmation before an action that changes something.

# Asks yes/no inside the panel and then runs ./deltactl <args>.
dash_confirm() { # text view args...
  DASH_CONF_TEXT="$1" DASH_CONF_VIEW="$2"
  shift 2
  DASH_CONF_ARGV=("$@")
  DASH_MODE=confirm
}

dash_key_confirm() {
  local argv=("${DASH_CONF_ARGV[@]}")
  DASH_MODE=normal
  case "$1" in
    y | Y | s | S) dash_start_job "$DASH_CONF_VIEW" "${argv[@]}" ;;
    *) dash_msg info "$(t tui.msg.cancelled)" ;;
  esac
}

dash_dialog_confirm() { # body_height
  local l
  dash_wrap "$DASH_CONF_TEXT" 58
  DASH_DLG=("")
  for l in "${DASH_WRAP[@]}"; do DASH_DLG+=(" $l"); done
  # The keys go inside the box too (the bar under the body is easy to miss, and Enter here means "no": pressing it looked like "nothing happened").
  DASH_DLG+=("")
  if [ "$UI_UTF8" -eq 1 ] && [ "$UI_RICH" -eq 1 ]; then dt tui.confirm.keys; else dt tui.confirm.keys.ascii; fi
  DASH_DLG+=(" $C_BLD$DTV$C_OFF" "")
  dash_dialog "$1" "?" 50
}

# --- The contract of lib/screens/registry.sh --------------------------------------------------------------------
scr_confirm_render() { dash_dialog_confirm "$2"; } # width height
scr_confirm_key() { dash_key_confirm "$1"; }
scr_confirm_keys() { # width
  if [ "$UI_UTF8" -eq 1 ] && [ "$UI_RICH" -eq 1 ]; then dt tui.confirm.keys; else dt tui.confirm.keys.ascii; fi
  dash_keyfit "$DTV" "$1"; TUI_FRAME+=(" $C_GRY$DASH_KF$C_OFF")
}
scr_confirm_sig() { DASH_SIG+="|$DASH_CONF_TEXT"; }

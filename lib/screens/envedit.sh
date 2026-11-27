#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Mode: the Variables editor has the keyboard (lib/screens/env.sh draws it). While it has it the one-letter keys are the editor's (`d` default,
# `r` show a secret, `g` generate...) and typed text goes to the field; what the editor does not use still reaches the panel, so the digits
# change the view, Tab moves on, `?` opens the help, `:` the command line and `q` leaves (asking first when there are changes). The mode draws
# nothing of its own: the view stays visible.

# What the editor asked for after a key: a message for the status line, and an action of the panel.
dash_env_after() {
  local inst="$DASH_ENV_INST" i n="${#DASH_NAMES[@]}" cur=-1 step
  if [ -n "$KEE_NOTE" ]; then dash_msg "${KEE_NOTE_KIND:-info}" "$KEE_NOTE"; fi
  # Something was written: the file changed, so the marks of what is deployed are read again.
  if [ "$KEE_COMMIT_N" -gt 0 ]; then KEE_COMMIT_N=0; dash_env_request; fi
  case "$KEE_ACTION" in
    leave)
      # (from the view: back to the first one; from the tab of the workspace: back to the list)
      DASH_MODE=normal
      if [ "$DASH_VIEW" = instances ]; then DASH_FOCUS=list; else DASH_VIEW="${DASH_SCREENS[0]}"; fi
      ;;
    deploy)
      if job_running; then dash_msg warn "$(t tui.msg.busy)"; return 0; fi
      dash_start_job stay deploy "$inst"
      ;;
    secfile)
      # A file of secrets/ given by its path: `secret add` copies it (in the background, as the load of an image: the panel keeps working) and the
      # editor reads what the files are again when the command ends (kee_tick).
      if job_running; then dash_msg warn "$(t tui.msg.busy)"; return 0; fi
      if [ "$KEE_FILE_FORCE" -eq 1 ]; then dash_start_job stay secret add "$inst" "$KEE_FILE_NAME" "$KEE_FILE_SRC" --force
      else dash_start_job stay secret add "$inst" "$KEE_FILE_NAME" "$KEE_FILE_SRC"; fi
      KEE_FILEWAIT=1
      ;;
    sync)
      # The variables the templates have and the files lack: `env sync --apply` writes them (in the background, behind a question) and the
      # editor reads the instance again when the command ends (scr_env_tick). With changes staged it asks to save or discard first.
      if kee_dirty; then dash_msg warn "$(t tui.env.sync_dirty "$inst")"; return 0; fi
      if job_running; then dash_msg warn "$(t tui.msg.busy)"; return 0; fi
      dash_confirm "$(t tui.env.sync_confirm "$inst" "$KEE_N_SYNC")" stay env "$inst" sync --apply
      ;;
    prev | next)
      # In the tab the instance is the one chosen in the list: another one is chosen there.
      [ "$DASH_VIEW" != instances ] || return 0
      if kee_dirty; then dash_msg warn "$(t tui.env.switch_dirty "$inst")"; return 0; fi
      for i in "${!DASH_NAMES[@]}"; do [ "${DASH_NAMES[$i]}" != "$inst" ] || cur="$i"; done
      [ "$n" -gt 1 ] || return 0
      step=1; [ "$KEE_ACTION" = prev ] && step=-1
      [ "$cur" -ge 0 ] || cur=0
      dash_env_load "${DASH_NAMES[$(((cur + n + step) % n))]}"
      ;;
  esac
}

scr_envedit_key() { # key
  local k="$1"
  # With the vim keys off (Options), j and k are only letters where a value is typed.
  if [ "$KEE_EDIT" -eq 0 ] && [ -z "$KEE_PROMPT" ] && [ "$DASH_VIM" -eq 0 ]; then case "$k" in j | k) return 0 ;; esac; fi
  if kee_key "$k"; then
    dash_env_after
    return 0
  fi
  # Not the editor's: the panel's own keys (the views by number, Tab, ?, :, q...). They leave the mode first, and it comes back when the
  # key did nothing that took the keyboard elsewhere.
  DASH_MODE=normal
  if dash_key_global "$k"; then
    if dash_envedit_here && [ "$DASH_MODE" = normal ] && [ "$DASH_QUIT" -eq 0 ]; then DASH_MODE=envedit; fi
  elif [ "$DASH_VIEW" = instances ]; then
    # in the workspace the keys of the Instances view are the rest (< and > change tab)
    dash_key_instances "$k"
    if dash_envedit_here && [ "$DASH_MODE" = normal ]; then DASH_MODE=envedit; fi
  else
    DASH_MODE=envedit
  fi
}

# Is the editor where the mode lives: the view Variables, or the Variables tab of the workspace with the focus in it?
dash_envedit_here() {
  [ "$DASH_VIEW" = env ] && return 0
  [ "$DASH_VIEW" = instances ] && [ "$DASH_FOCUS" = tab ] && [ "$DASH_WS_TAB" = variables ]
}

scr_envedit_keys() { # width
  kee_hint "$1"
  DASH_KEYS[envhint]="$KEE_HINT"
  dash_keys_view envhint "$1"
}

scr_envedit_sig() { DASH_SIG+="|$KEE_EDIT|$KEE_PROMPT"; }

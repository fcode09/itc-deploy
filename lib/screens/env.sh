#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Screen: Variables (view 9). The environment variables of ONE instance in one place: grouped by file, with what is still to fill in, the
# description of each one, live validation, generated secrets, and what changed since the last deploy (↻). The editor itself is the kit's
# (lib/ui/kit/env_editor.sh, shared with the new-instance wizard and the instance workspace); this file is what the panel adds: which
# instance, the keyboard, the messages, the deploy that follows a save and the "not deployed yet" marks, which are read in the background
# (summing a file takes a process; the screen never waits for it).
#
# It opens on the instance chosen in Instances. Digit 9 gives the editor the keyboard (the mode `envedit`, lib/screens/envedit.sh: `d` is
# "default" there, not "diagnose"; the keys the editor does not use still reach the panel). Esc with changes asks first; the changes
# live in memory until `s`, so leaving the view with Tab or a digit loses nothing, and the instance does not change while there are any.
#
# Keys (see the kit for the whole list): Up/Down move · Enter edits a variable or folds a file · g generate · r show a secret · d default ·
# a advanced · s save · u save and deploy · [ ] other instance · Esc leave.

DASH_ENV_INST=""         # the instance in the editor
DASH_ENV_BUSY=0          # 1 while the deploy marks are being read
DASH_ENV_N=0             # answers applied, for the frame signature
DASH_ENV_SEEN=0          # JOB_SEQ of the last command seen ending

# The instance the editor should open on: the one chosen in Instances, else the one it already has, else the first. Into DASH_ENV_WANT.
DASH_ENV_WANT=""
dash_env_target() {
  local n
  DASH_ENV_WANT=""
  if [ "$DASH_ON_NEW" -eq 0 ] && [ -n "${DASH_NAMES[$DASH_SEL]:-}" ]; then DASH_ENV_WANT="${DASH_NAMES[$DASH_SEL]}"; return 0; fi
  for n in "${DASH_NAMES[@]}"; do [ "$n" != "$DASH_ENV_INST" ] || { DASH_ENV_WANT="$n"; return 0; }; done
  DASH_ENV_WANT="${DASH_NAMES[0]:-}"
}

# Reads the instance into the editor and asks for its deploy marks.
dash_env_load() { # instance
  DASH_ENV_INST="$1"
  KEE_UD="$DASH_UD"
  kee_open "$1"
  dash_env_request
  DASH_DIRTY=1
}

# Puts the editor on the right instance when the view is chosen: with changes staged it keeps the one it has (nothing is lost by walking
# away); otherwise it opens the instance chosen in Instances, reading its files again (they may have changed outside).
dash_env_sync() {
  dash_env_target
  if [ -n "$DASH_ENV_INST" ] && kee_dirty; then
    case " ${DASH_NAMES[*]} " in *" $DASH_ENV_INST "*) return 0 ;; esac
  fi
  if [ -n "$DASH_ENV_WANT" ]; then dash_env_load "$DASH_ENV_WANT"; else DASH_ENV_INST=""; fi
}

# --- The deploy marks, read in the background ----------------------------------------------------------------------------------

# Runs in the background: for each file of the instance, whether it is as it was at the last deploy (one `file state` line each).
dash_env_dump() { # instance
  local f
  envedit_files_r "$1"
  for f in "${ENVEDIT_FILES[@]}"; do
    envedit_deploy_state_r "$1" "$f"
    printf '%s %s\n' "$f" "$ED_DEPLOY"
  done
}

# Applies the lines of dash_env_dump to the editor (ignoring an answer for another instance).
dash_env_apply() { # instance text
  local f st
  [ "$1" = "$DASH_ENV_INST" ] || return 0
  while read -r f st; do
    [ -n "$f" ] || continue
    KEE_DEPLOY["$f"]="$st"
  done <<< "$2"
  kee_rows
  kee_touch
  DASH_ENV_BUSY=0 DASH_ENV_N=$((DASH_ENV_N + 1)) DASH_DIRTY=1
}

dash_env_request() {
  [ -n "$DASH_ENV_INST" ] || return 0
  if tui_test_mode; then dash_env_apply "$DASH_ENV_INST" "$(dash_env_dump "$DASH_ENV_INST")"; return 0; fi
  [ -z "${DASH_AS_PID[env]:-}" ] || return 0
  DASH_ENV_BUSY=1
  dash_async env "$DASH_ENV_INST" dash_env_dump "$DASH_ENV_INST" || true
}

# --- Drawing -----------------------------------------------------------------------------------------------------------------

scr_env_render() { # width height
  local w="$1" h="$2" chips body foc=0 msg
  local -a lines=()
  if [ "$DASH_MODE" = "envedit" ]; then foc=1; fi
  # The view can be reached without its digit (the palette, `goto env`): the editor opens on its instance the first time it is drawn.
  if [ -z "$DASH_ENV_INST" ] && [ "${#DASH_NAMES[@]}" -gt 0 ]; then dash_env_sync; fi
  t_r tui.env.title; chips="9:$T_OUT"
  if [ -z "$DASH_ENV_INST" ]; then
    t_r tui.env.none; msg="${TH[dim]:-}$T_OUT$TH_RESET"
    lines=("" "$msg")
    while [ "${#lines[@]}" -lt $((h - 2)) ]; do lines+=(""); done
    kit_box "$w" "$h" lines "chips=$chips" "focus=$foc"
    TUI_FRAME+=("${KIT_BOX[@]}")
    return 0
  fi
  kee_render "$w" "$h" "chips=$chips|$DASH_ENV_INST" "focus=$foc"
  TUI_FRAME+=("${KEE_BOX[@]}")
}

# --- The contract of lib/screens/registry.sh ---------------------------------------------------------------------------------

# The released state (the view is on screen but the editor has not got the keyboard: it came with Tab): any key the panel does not take
# gives it the keyboard and goes to the editor, so Enter is "start editing".
scr_env_key() { # key
  [ -n "$DASH_ENV_INST" ] || dash_env_sync
  [ -n "$DASH_ENV_INST" ] || return 0
  DASH_MODE=envedit
  scr_envedit_key "$1"
}

scr_env_keys() { dash_keys_view env "$1"; } # width
scr_env_texts() { DASH_KEYS[env]="$(t tui.keys.env "$DASH_UD")"; KEE_UD="$DASH_UD"; }
scr_env_sig() { DASH_SIG+="|$DASH_ENV_INST|$KEE_REV|$DASH_ENV_N"; }

# Chosen with its digit (or a click): the editor opens on the instance and takes the keyboard.
scr_env_enter() {
  dash_env_sync
  [ -z "$DASH_ENV_INST" ] || DASH_MODE=envedit
}

# Every turn of the loop, whatever the view: the answer of the marks, a command that ended (a deploy changes what is deployed), and a
# secret that was shown for long enough.
scr_env_tick() {
  [ -n "$DASH_ENV_INST" ] || return 0
  if dash_async_take env; then dash_env_apply "${DASH_AS_ARG[env]:-}" "$DASH_AS_TEXT"; fi
  if [ -n "$JOB_RC" ] && [ "$JOB_SEQ" -ne "$DASH_ENV_SEEN" ]; then DASH_ENV_SEEN="$JOB_SEQ"; dash_env_request; fi
  if kee_tick; then DASH_DIRTY=1; fi
}

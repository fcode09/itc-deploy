#!/usr/bin/env bash
# shellcheck disable=SC2034  # the DASH_* variables are read by the rest of the panel
# Screen registry and router of the interactive panel. Sourced by lib/cmd/dashboard.sh.
#
# The panel is made of SCREENS. There are two kinds:
#   views   the tabs (1-9 or Tab): instances, resources, output, runs, procs, console. One is current (DASH_VIEW).
#   modes   what takes the keyboard over a view: dialogs (menu, confirm, name, palette, help, options, wizard) and lines being typed
#           (cmd, filter, find). One is current (DASH_MODE); `normal` means none.
# To add a screen: write lib/screens/<id>.sh with the functions of the contract below and add ONE line to the registry at the end of
# this file (`dash_screen_register <id> <title key> <live>` for a view, `dash_mode_register <id>` for a mode). Nothing else knows it.
#
# The contract. Every function is optional unless it says otherwise; "the screen" is its id, "the width" the columns of the terminal.
#   scr_<id>_render <width> <height>   (required) appends exactly <height> lines to TUI_FRAME. A mode with no render leaves the view visible.
#   scr_<id>_key <key>                 (required) handles a key. A view's keys run after the global ones (dash_key_global).
#   scr_<id>_keys <width>              (required) appends ONE line to TUI_FRAME: the key hints of the last line (it may set TUI_CURSOR).
#   scr_<id>_texts                     rebuilds the texts that depend on the language (DASH_KEYS[...]); runs after DT=() is cleared.
#   scr_<id>_sig                       appends "|value" pieces to DASH_SIG: every variable the screen's drawing depends on. The body of a
#                                      frame is reused while the signature is the same, so a missing value is a stale screen.
#   scr_<id>_enter                     (views) runs when the view is chosen with its number or a click (not with Tab).
#   scr_<id>_tab <+1|-1>               (views) Tab and Shift+Tab inside the view; without it they move to the next or previous view.
#   scr_<id>_back                      (views) Esc: return 0 when it took a step back inside the view; without it Esc leaves the view.
#   scr_<id>_tick                      (views) runs at every turn of the loop, whatever view is current (background work).
#   scr_<id>_poll                      (views) runs at every turn only while the view is current and the panel is not paused.
#   scr_<id>_click <column> <row>      (views) a left click in the body (rows and columns of the screen, starting at 1).

DASH_SCREENS=()                                # ids of the views, in tab order
declare -gA DASH_SCREEN_TITLE=() DASH_SCREEN_LIVE=()
DASH_MODES=()                                  # ids of the modes
DASH_SIG=""                                    # the signature being built (see dash_render)

# Registers a view: its id (also the name of its file), the key of its tab title and whether its body depends on the figures (the
# samples, the state of Docker, the logs: 1) or only on what the user did (0). Loads its file.
dash_screen_register() { # id title_key live
  DASH_SCREENS+=("$1")
  DASH_SCREEN_TITLE[$1]="$2"
  DASH_SCREEN_LIVE[$1]="$3"
  # shellcheck source=/dev/null
  source "$ROOT/lib/screens/$1.sh"
}

# Registers a mode (a dialog or a line being typed). Loads its file.
dash_mode_register() { # id
  DASH_MODES+=("$1")
  # shellcheck source=/dev/null
  source "$ROOT/lib/screens/$1.sh"
}

# Is $1 the id of a view?
dash_screen_valid() { # id
  local v
  for v in "${DASH_SCREENS[@]}"; do [ "$v" != "$1" ] || return 0; done
  return 1
}

# The id of the view whose tab number is $1 (1 = the first registered), into DASH_SCR_ID. 1 when there is none.
DASH_SCR_ID=""
dash_screen_by_number() { # number
  DASH_SCR_ID=""
  [[ "$1" =~ ^[1-9]$ ]] || return 1
  [ "$1" -le "${#DASH_SCREENS[@]}" ] || return 1
  DASH_SCR_ID="${DASH_SCREENS[$(($1 - 1))]}"
}

# Chooses a view with its number or a click: it becomes current and its enter hook runs.
dash_screen_goto() { # id
  DASH_VIEW="$1"
  if declare -F "scr_$1_enter" > /dev/null; then "scr_$1_enter"; fi
}

# Tab (+1) and Shift+Tab (-1): the view's own hook, or the next/previous view (the ring wraps around).
dash_screen_tab() { # +1 | -1
  local i n="${#DASH_SCREENS[@]}" cur=0
  if declare -F "scr_${DASH_VIEW}_tab" > /dev/null; then "scr_${DASH_VIEW}_tab" "$1"; return 0; fi
  for ((i = 0; i < n; i++)); do [ "${DASH_SCREENS[$i]}" != "$DASH_VIEW" ] || cur="$i"; done
  DASH_VIEW="${DASH_SCREENS[$(((cur + n + $1) % n))]}"
}

# Esc inside a view: its own step back, else the first view, else (already there) quit.
dash_screen_back() {
  if declare -F "scr_${DASH_VIEW}_back" > /dev/null && "scr_${DASH_VIEW}_back"; then return 0; fi
  if [ "$DASH_VIEW" != "${DASH_SCREENS[0]}" ]; then DASH_VIEW="${DASH_SCREENS[0]}"; else DASH_QUIT=1; fi
}

# Does the body of the current view depend on the figures? Unknown views count as live.
dash_screen_live() { [ "${DASH_SCREEN_LIVE[$DASH_VIEW]:-1}" -eq 1 ]; }

# Appends the body of the current mode (or, when it draws nothing of its own, of the current view) to TUI_FRAME.
dash_screen_render() { # height
  if [ "$DASH_MODE" != "normal" ] && declare -F "scr_${DASH_MODE}_render" > /dev/null; then
    "scr_${DASH_MODE}_render" "$TUI_COLS" "$1"
  else
    "scr_${DASH_VIEW}_render" "$TUI_COLS" "$1"
  fi
}

# Hands a key to the current mode, or to the current view.
dash_screen_key() { # key
  if [ "$DASH_MODE" != "normal" ]; then "scr_${DASH_MODE}_key" "$1"; else "scr_${DASH_VIEW}_key" "$1"; fi
}

# Appends the key hints line of the current mode or view to TUI_FRAME.
dash_screen_keys() { # width
  if [ "$DASH_MODE" != "normal" ]; then "scr_${DASH_MODE}_keys" "$1"; else "scr_${DASH_VIEW}_keys" "$1"; fi
}

# Rebuilds the language-dependent texts of every screen.
dash_screen_texts() {
  local id
  for id in "${DASH_SCREENS[@]}" "${DASH_MODES[@]}"; do
    if declare -F "scr_${id}_texts" > /dev/null; then "scr_${id}_texts"; fi
  done
}

# Adds to DASH_SIG what every screen's drawing depends on.
dash_screen_sig() {
  local id
  for id in "${DASH_SCREENS[@]}" "${DASH_MODES[@]}"; do
    if declare -F "scr_${id}_sig" > /dev/null; then "scr_${id}_sig"; fi
  done
}

# Background work of every view, then of the current one only while the panel runs (not paused).
dash_screen_tick() {
  local id
  for id in "${DASH_SCREENS[@]}"; do
    if declare -F "scr_${id}_tick" > /dev/null; then "scr_${id}_tick"; fi
  done
}
dash_screen_poll() {
  if declare -F "scr_${DASH_VIEW}_poll" > /dev/null; then "scr_${DASH_VIEW}_poll"; fi
}

# A left click in the body of the current view. 1 when the view has no click hook.
dash_screen_click() { # column row
  if declare -F "scr_${DASH_VIEW}_click" > /dev/null; then "scr_${DASH_VIEW}_click" "$1" "$2"; return 0; fi
  return 1
}

# --- The registry: ONE line per screen ------------------------------------------------------------------------------------
# Views, in tab order (their number is their position). The title is the key of its tab text; `live` is 1 when the body shows figures.
dash_screen_register instances tui.tab.instances 1
dash_screen_register resources tui.tab.resources 1
dash_screen_register output tui.tab.output 0
dash_screen_register runs tui.tab.runs 0
dash_screen_register procs tui.tab.procs 0
dash_screen_register console tui.tab.console 0
# Modes.
dash_mode_register menu
dash_mode_register confirm
dash_mode_register name
dash_mode_register cmd
dash_mode_register filter
dash_mode_register find
dash_mode_register wizard
dash_mode_register palette
dash_mode_register help
dash_mode_register options

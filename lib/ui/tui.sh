#!/usr/bin/env bash
# shellcheck disable=SC2034  # TUI_KEY and TUI_FRAME are read by the commands that use this layer
# Terminal primitives of the interactive panel: alternate screen, key reading and flicker-free drawing.
# Sourced on demand by lib/cmd/dashboard.sh; pure Bash, no external dependency.
#
# Test mode (no terminal needed): DELTACTL_TUI_KEYS=<file> makes tui_key read one key name per line from that file
# (up, down, left, right, enter, esc, tab, timeout, or a character; the end of the file means q) and tui_draw print
# every frame as plain text between "=== frame N ===" lines, without any escape sequence.

TUI_KEY=""
TUI_FRAME=()
TUI_FRAMES=0
TUI_ACTIVE=0
TUI_KEYS_OPEN=0

tui_test_mode() { [ -n "${DELTACTL_TUI_KEYS:-}" ]; }

# Can the interactive panel run? A real terminal on both ends and a color-capable one, or the test mode.
tui_interactive() {
  tui_test_mode && return 0
  [ -t 0 ] && [ -t 1 ] && [ "${UI_RICH:-0}" -eq 1 ] && [ "${TERM:-dumb}" != "dumb" ]
}

# Enters the alternate screen and hides the cursor.
tui_enter() {
  tui_test_mode && return 0
  [ "$TUI_ACTIVE" -eq 1 ] && return 0
  printf '\033[?1049h\033[?25l'
  TUI_ACTIVE=1
}

# Leaves the alternate screen and shows the cursor again. Safe to call twice.
tui_leave() {
  [ "$TUI_ACTIVE" -eq 1 ] || return 0
  printf '\033[?25h\033[?1049l'
  TUI_ACTIVE=0
}

# Reads one key into TUI_KEY, waiting at most $1 seconds (none = forever). The result is a name (up, down, left,
# right, enter, esc, tab, backspace, timeout) or the typed character.
tui_key() { # [timeout]
  local t="${1:-}" k rest rc=0
  if tui_test_mode; then
    if [ "$TUI_KEYS_OPEN" -eq 0 ]; then
      exec 9< "$DELTACTL_TUI_KEYS"
      TUI_KEYS_OPEN=1
    fi
    if IFS= read -r k <&9; then TUI_KEY="$k"; else TUI_KEY="q"; fi
    return 0
  fi
  if [ -n "$t" ]; then
    IFS= read -rsn1 -t "$t" k || rc=$?
    if [ "$rc" -gt 128 ]; then TUI_KEY="timeout"; return 0; fi
  else
    IFS= read -rsn1 k || { TUI_KEY="q"; return 0; }
  fi
  case "$k" in
    $'\033')
      # An arrow key is ESC [ A..D; a lone ESC is the Escape key.
      if IFS= read -rsn2 -t 0.05 rest; then
        case "$rest" in
          '[A' | 'OA') TUI_KEY="up" ;;
          '[B' | 'OB') TUI_KEY="down" ;;
          '[C' | 'OC') TUI_KEY="right" ;;
          '[D' | 'OD') TUI_KEY="left" ;;
          *) TUI_KEY="esc" ;;
        esac
      else
        TUI_KEY="esc"
      fi
      ;;
    '') TUI_KEY="enter" ;;
    $'\t') TUI_KEY="tab" ;;
    $'\177' | $'\b') TUI_KEY="backspace" ;;
    *) TUI_KEY="$k" ;;
  esac
}

# Draws TUI_FRAME (one line per element) from the top-left corner, clearing the rest of every line and of the
# screen, so nothing flickers. In test mode it prints the lines as text.
tui_draw() {
  local line
  if tui_test_mode; then
    TUI_FRAMES=$((TUI_FRAMES + 1))
    printf '=== frame %d ===\n' "$TUI_FRAMES"
    printf '%s\n' "${TUI_FRAME[@]}"
    return 0
  fi
  printf '\033[H'
  for line in "${TUI_FRAME[@]}"; do printf '%s\033[K\n' "$line"; done
  printf '\033[J'
}

# Height of the terminal in rows (24 when it cannot be read).
tui_rows() {
  local r="${LINES:-}"
  [[ "$r" =~ ^[0-9]+$ ]] || r="$(tput lines 2>/dev/null || echo 24)"
  [[ "$r" =~ ^[0-9]+$ ]] || r=24
  printf '%s' "$r"
}

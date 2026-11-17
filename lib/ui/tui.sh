#!/usr/bin/env bash
# shellcheck disable=SC2034  # TUI_KEY, TUI_FRAME and the other TUI_* variables are read by the commands that use this layer
# Terminal primitives of the interactive panel: alternate screen, key reading, boxes and flicker-free drawing.
# Sourced on demand by lib/cmd/dashboard.sh; pure Bash, no external dependency.
#
# Drawing works on a frame: an array of lines (TUI_FRAME). tui_draw repaints only the lines that changed since the
# previous frame, in a single write, so a clock or a counter ticking does not make the screen flicker.
#
# Test mode (no terminal needed): DELTACTL_TUI_KEYS=<file> makes tui_key read one key name per line from that file
# (up, down, left, right, enter, esc, tab, pgup, pgdn, home, end, timeout, or a character; the end of the file is the key
# eof) and tui_draw print every frame as plain text between "=== frame N ===" lines, without any escape sequence. The
# size is then DELTACTL_TUI_ROWS x COLUMNS (30 x 100 by default).

shopt -s extglob

TUI_KEY=""
TUI_FRAME=()
TUI_PREV=()
TUI_FRAMES=0
TUI_ACTIVE=0
TUI_KEYS_OPEN=0
TUI_ROWS=24
TUI_COLS=80
TUI_RESIZED=0
TUI_FORCE=1
TUI_CURSOR=""
TUI_VL=0
TUI_OUT=""
TUI_BOX=()

tui_test_mode() { [ -n "${DELTACTL_TUI_KEYS:-}" ]; }

# Can the interactive panel run? A real terminal on both ends and a color-capable one, or the test mode.
tui_interactive() {
  tui_test_mode && return 0
  [ -t 0 ] && [ -t 1 ] && [ "${UI_RICH:-0}" -eq 1 ] && [ "${TERM:-dumb}" != "dumb" ]
}

# Reads the size of the terminal into TUI_ROWS / TUI_COLS (it forks `stty`, so it only runs at start and on resize).
tui_size() {
  local r c
  if tui_test_mode; then
    r="${DELTACTL_TUI_ROWS:-30}" c="${COLUMNS:-100}"
  else
    read -r r c < <(stty size 2>/dev/null) || true
    [[ "${r:-}" =~ ^[0-9]+$ ]] && [[ "${c:-}" =~ ^[0-9]+$ ]] || { r="$(tput lines 2>/dev/null || echo 24)"; c="$(tput cols 2>/dev/null || echo 80)"; }
  fi
  [[ "$r" =~ ^[0-9]+$ ]] || r=24
  [[ "$c" =~ ^[0-9]+$ ]] || c=80
  [ "$r" -ge 10 ] || r=10
  [ "$c" -ge 40 ] || c=40
  TUI_ROWS="$r" TUI_COLS="$c"
  TUI_RESIZED=0 TUI_FORCE=1
}

# Enters the alternate screen, hides the cursor and stops lines from wrapping.
tui_enter() {
  tui_test_mode && { tui_size; return 0; }
  [ "$TUI_ACTIVE" -eq 1 ] && return 0
  printf '\033[?1049h\033[?25l\033[?7l'
  TUI_ACTIVE=1
  trap 'TUI_RESIZED=1' WINCH
  tui_size
}

# Leaves the alternate screen and shows the cursor again. Safe to call twice.
tui_leave() {
  [ "$TUI_ACTIVE" -eq 1 ] || return 0
  printf '\033[?7h\033[?25h\033[?1049l'
  TUI_ACTIVE=0
  trap - WINCH
}

# Reads one key into TUI_KEY, waiting at most $1 seconds (none = forever). The result is a name (up, down, left,
# right, home, end, pgup, pgdn, delete, enter, esc, tab, backspace, timeout, eof, other) or the typed character.
tui_key() { # [timeout]
  local t="${1:-}" k rest="" c rc=0
  if tui_test_mode; then
    if [ "$TUI_KEYS_OPEN" -eq 0 ]; then
      exec 9< "$DELTACTL_TUI_KEYS"
      TUI_KEYS_OPEN=1
    fi
    if IFS= read -r k <&9; then TUI_KEY="$k"; else TUI_KEY="eof"; fi
    return 0
  fi
  if [ -n "$t" ]; then
    IFS= read -rsn1 -t "$t" k || rc=$?
    if [ "$rc" -gt 128 ]; then TUI_KEY="timeout"; return 0; fi
    # A resize interrupts the read with a signal status: report it as a timeout so the loop redraws.
    if [ "$rc" -ne 0 ]; then TUI_KEY="timeout"; return 0; fi
  else
    IFS= read -rsn1 k || { TUI_KEY="eof"; return 0; }
  fi
  case "$k" in
    $'\033')
      # An escape sequence is ESC [ ... <letter or ~> (or ESC O <letter>); a lone ESC is the Escape key.
      if IFS= read -rsn1 -t 0.05 c; then
        if [ "$c" = "[" ] || [ "$c" = "O" ]; then
          rest="$c"
          while IFS= read -rsn1 -t 0.05 c; do
            rest+="$c"
            case "$c" in [A-Za-z~]) break ;; esac
            [ "${#rest}" -lt 8 ] || break
          done
        else
          rest="$c"
        fi
        case "$rest" in
          '[A' | 'OA') TUI_KEY="up" ;;
          '[B' | 'OB') TUI_KEY="down" ;;
          '[C' | 'OC') TUI_KEY="right" ;;
          '[D' | 'OD') TUI_KEY="left" ;;
          '[H' | 'OH' | '[1~' | '[7~') TUI_KEY="home" ;;
          '[F' | 'OF' | '[4~' | '[8~') TUI_KEY="end" ;;
          '[5~') TUI_KEY="pgup" ;;
          '[6~') TUI_KEY="pgdn" ;;
          '[3~') TUI_KEY="delete" ;;
          *) TUI_KEY="other" ;;
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

# Blank padding for tui_fit (cut from this string instead of building it each time).
printf -v TUI_SPACES '%*s' 400 ''

# Visible length of a text (color sequences do not count) into TUI_VL.
tui_vlen() { # text
  if [[ "$1" != *$'\033'* ]]; then TUI_VL="${#1}"; return 0; fi
  local s="${1//$'\033'\[+([0-9;])m/}"
  TUI_VL="${#s}"
}

# Cuts a text to $2 visible cells keeping its color sequences, into TUI_OUT.
tui_clip() { # text width
  local s="$1" w="$2" out="" vis=0 chunk rest seq final room
  [ "$w" -gt 0 ] || { TUI_OUT=""; return 0; }
  tui_vlen "$s"
  if [ "$TUI_VL" -le "$w" ]; then TUI_OUT="$s"; return 0; fi
  # Without colors it is a plain cut.
  if [[ "$s" != *$'\033'* ]]; then TUI_OUT="${s:0:$w}"; return 0; fi
  while [ -n "$s" ] && [ "$vis" -lt "$w" ]; do
    if [[ "$s" == $'\033['* ]]; then
      rest="${s#$'\033['}"
      seq="${rest%%[A-Za-z]*}"
      final="${rest:${#seq}:1}"
      out+=$'\033['"$seq$final"
      s="${rest:$((${#seq} + 1))}"
    else
      # Text up to the next color sequence, taken whole when it fits.
      chunk="${s%%$'\033'*}"
      room=$((w - vis))
      if [ "${#chunk}" -le "$room" ]; then
        out+="$chunk"
        vis=$((vis + ${#chunk}))
        s="${s:${#chunk}}"
      else
        out+="${chunk:0:$room}"
        vis="$w"
        s=""
      fi
    fi
  done
  # Close any color left open by the cut.
  TUI_OUT="$out"$'\033[0m'
}

# Fits a text to exactly $2 visible cells (cut or padded with spaces) into TUI_OUT.
tui_fit() { # text width
  local w="$2"
  tui_vlen "$1"
  if [ "$TUI_VL" -gt "$w" ]; then
    tui_clip "$1" "$w"
  else
    TUI_OUT="$1${TUI_SPACES:0:$((w - TUI_VL))}"
  fi
}

# A line of $2 copies of the character $1 into TUI_OUT (remembered: the same borders repeat in every frame).
declare -gA TUI_REPS=()
tui_rep() { # char count
  local k="$1$2" s
  if [ -z "${TUI_REPS[$k]+x}" ]; then
    printf -v s '%*s' "$2" ''
    TUI_REPS[$k]="${s// /$1}"
  fi
  TUI_OUT="${TUI_REPS[$k]}"
}

# Draws a box of $2 x $3 cells around the lines of the array named $4 (it must hold at most $3 - 2 lines; missing ones are
# blank). $1 is the title; $5 (optional) is a color for the border. The result is in TUI_BOX, one element per line.
tui_box() { # title width height array [color]
  local title="$1" w="$2" h="$3" col="${5:-$C_GRY}" i inner fill
  local -n _tb="$4"
  inner=$((w - 2))
  TUI_BOX=()
  # Top: ┌─ title ───────┐
  tui_vlen " $title "
  if [ -n "$title" ] && [ "$TUI_VL" -le $((inner - 2)) ]; then
    tui_rep "$UI_S_H" $((inner - 1 - TUI_VL))
    TUI_BOX+=("$col$UI_S_TL$UI_S_H$C_OFF$C_BLD $title $C_OFF$col$TUI_OUT$UI_S_TR$C_OFF")
  else
    tui_rep "$UI_S_H" "$inner"
    TUI_BOX+=("$col$UI_S_TL$TUI_OUT$UI_S_TR$C_OFF")
  fi
  for ((i = 0; i < h - 2; i++)); do
    tui_fit " ${_tb[$i]:-}" "$inner"
    TUI_BOX+=("$col$UI_S_V$C_OFF$TUI_OUT$col$UI_S_V$C_OFF")
  done
  tui_rep "$UI_S_H" "$inner"
  TUI_BOX+=("$col$UI_S_BL$TUI_OUT$UI_S_BR$C_OFF")
}

# Draws TUI_FRAME (one line per element) from the top-left corner. Only the lines that differ from the previous
# frame are repainted, all in one write. In test mode it prints the lines as text.
tui_draw() {
  local i n="${#TUI_FRAME[@]}" out="" line
  if tui_test_mode; then
    TUI_FRAMES=$((TUI_FRAMES + 1))
    printf '=== frame %d ===\n' "$TUI_FRAMES"
    printf '%s\n' "${TUI_FRAME[@]}"
    return 0
  fi
  [ "$TUI_FORCE" -eq 0 ] || { out=$'\033[2J'; TUI_PREV=(); }
  [ "$n" -le "$TUI_ROWS" ] || n="$TUI_ROWS"
  for ((i = 0; i < n; i++)); do
    line="${TUI_FRAME[$i]}"
    if [ "$TUI_FORCE" -eq 1 ] || [ "$line" != "${TUI_PREV[$i]-}" ]; then
      out+=$'\033['"$((i + 1));1H$line"$'\033[0m\033[K'
    fi
  done
  # Lines of the previous frame that no longer exist.
  for ((i = n; i < ${#TUI_PREV[@]} && i < TUI_ROWS; i++)); do
    out+=$'\033['"$((i + 1));1H"$'\033[K'
  done
  if [ -n "$TUI_CURSOR" ]; then out+=$'\033['"${TUI_CURSOR}H"$'\033[?25h'; else out+=$'\033[?25l'; fi
  printf '%s' "$out"
  TUI_PREV=("${TUI_FRAME[@]:0:$n}")
  TUI_FORCE=0
}

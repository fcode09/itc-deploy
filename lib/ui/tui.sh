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
TUI_STTY=""
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
  printf '\033[?1049h\033[?25l\033[?7l%s' "$TH_RESET"
  # Keys that arrive while the screen is being drawn would be echoed by the terminal itself, in the middle of the frame: the
  # echo is off for as long as the panel is on (tui_leave restores the settings it found).
  TUI_STTY="$(stty -g 2> /dev/null || true)"
  stty -echo 2> /dev/null || true
  TUI_ACTIVE=1
  trap 'TUI_RESIZED=1' WINCH
  tui_size
}

# Leaves the alternate screen and shows the cursor again. Safe to call twice.
tui_leave() {
  [ "$TUI_ACTIVE" -eq 1 ] || return 0
  printf '\033[0m\033[?7h\033[?25h\033[?1049l\033[0m'
  if [ -n "$TUI_STTY" ]; then stty "$TUI_STTY" 2> /dev/null || stty echo 2> /dev/null || true; else stty echo 2> /dev/null || true; fi
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
          '[Z') TUI_KEY="btab" ;;
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

# A line of a box that starts with this marker is drawn as the selected row (see tui_box).
TUI_SEL=$'\001'

# Blank padding for tui_fit (cut from this string instead of building it each time).
printf -v TUI_SPACES '%*s' 400 ''

# Removes every `ESC [ ... <letter>` sequence and any other control character from a text into TUI_OUT: text that comes from
# outside (container logs) must never move the cursor or change colours of the panel.
tui_strip_ansi() { # text
  local s="$1" out="" pre rest seq
  s="${s//$'\r'/}"
  s="${s//$'\t'/    }"
  while [[ "$s" == *$'\033['* ]]; do
    pre="${s%%$'\033['*}"
    rest="${s#*$'\033['}"
    seq="${rest%%[A-Za-z]*}"
    if [ "$seq" = "$rest" ]; then s="$pre"; break; fi   # an unfinished sequence: drop the rest
    out+="$pre"
    s="${rest:$((${#seq} + 1))}"
  done
  out+="$s"
  out="${out//$'\033'/}"
  TUI_OUT="$out"
}

# Like tui_strip_ansi but keeps the colour sequences (`ESC [ ... m`): the output of a command is shown with its own colours, yet it
# can never move the cursor or run a terminal command. The result is in TUI_OUT.
tui_sanitize() { # text
  local s="$1" out="" pre rest seq final
  s="${s//$'\r'/}"
  s="${s//$'\t'/    }"
  while [[ "$s" == *$'\033['* ]]; do
    pre="${s%%$'\033['*}"
    rest="${s#*$'\033['}"
    seq="${rest%%[A-Za-z]*}"
    if [ "$seq" = "$rest" ]; then s="$pre"; break; fi   # an unfinished sequence: drop the rest
    final="${rest:${#seq}:1}"
    out+="${pre//$'\033'/}"
    if [ "$final" = "m" ] && [[ "$seq" =~ ^[0-9\;]*$ ]]; then out+=$'\033['"${seq}m"; fi
    s="${rest:$((${#seq} + 1))}"
  done
  s="${s//$'\033'/}"
  out+="$s"
  TUI_OUT="${out//$'\a'/}"
}

# Visible length of a text (color sequences do not count) into TUI_VL.
# Lines repeat from one frame to the next, so the result is remembered (only for texts with colors, the slow ones).
# Do not strip the sequences with `${1//$'\033'\[+([0-9;])m/}`: that extglob replacement takes ~25 ms on a coloured line.
declare -gA TUI_VL_CACHE=()
TUI_VL_CACHED=0
tui_vlen() { # text
  local s="$1" n=0 pre rest seq
  if [[ "$s" != *$'\033'* ]]; then TUI_VL="${#s}"; return 0; fi
  if [[ -n "${TUI_VL_CACHE[$s]+x}" ]]; then TUI_VL="${TUI_VL_CACHE[$s]}"; return 0; fi
  while [[ "$s" == *$'\033['* ]]; do
    pre="${s%%$'\033['*}"
    n=$((n + ${#pre}))
    rest="${s#*$'\033['}"
    seq="${rest%%[!0-9;]*}"
    if [ -n "$seq" ] && [ "${rest:${#seq}:1}" = "m" ]; then
      s="${rest:$((${#seq} + 1))}"   # a color sequence: it takes no cells
    else
      n=$((n + 2))                   # any other ESC [ stays counted, as before
      s="$rest"
    fi
  done
  TUI_VL=$((n + ${#s}))
  if [ "$TUI_VL_CACHED" -ge 4096 ]; then TUI_VL_CACHE=() TUI_VL_CACHED=0; fi
  TUI_VL_CACHE[$1]="$TUI_VL"
  TUI_VL_CACHED=$((TUI_VL_CACHED + 1))
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
  TUI_OUT="$out$TH_RESET"
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
tui_box() { # title width height array [color] [focused]
  local title="$1" w="$2" h="$3" foc="${6:-0}" i inner fill ttl styled
  local -n _tb="$4"
  local col="${5:-${TH[border]:-$C_GRY}}"
  inner=$((w - 2))
  TUI_BOX=()
  # A focused box shows it with the border colour AND the title as a badge; without colours (NO_COLOR, mono) a marker
  # in front of the title keeps the focus visible.
  if [ "$foc" -eq 1 ]; then
    [ -n "${5:-}" ] || col="${TH[border_focus]:-$C_CYN}"
    # Inside the badge the title is plain text: its own colours (a state in green) would vanish on the badge background.
    tui_strip_ansi "$title"; ttl="$TUI_OUT"
    [ -n "${TH[badge]:-}" ] || ttl="$UI_S_SEL$ttl"
    styled="${TH[badge]:-$C_BLD} $ttl $C_OFF"
  else
    ttl="$title"
    styled="${TH[title]:-}$C_BLD $ttl $C_OFF"
  fi
  # Top: ╭─ title ───────╮
  tui_vlen " $ttl "
  if [ -n "$title" ] && [ "$TUI_VL" -le $((inner - 2)) ]; then
    tui_rep "$TH_B_H" $((inner - 1 - TUI_VL))
    TUI_BOX+=("$col$TH_B_TL$TH_B_H$C_OFF$styled$col$TUI_OUT$TH_B_TR$C_OFF")
  else
    tui_rep "$TH_B_H" "$inner"
    TUI_BOX+=("$col$TH_B_TL$TUI_OUT$TH_B_TR$C_OFF")
  fi
  local raw
  for ((i = 0; i < h - 2; i++)); do
    raw="${_tb[$i]:-}"
    if [[ "$raw" == "$TUI_SEL"* ]]; then
      # A selected row: the theme's selection colours across the whole inner width (resets inside the row bring them back).
      raw="${raw#"$TUI_SEL"}"
      tui_fit "${TH[sel]:-} ${raw//"$C_OFF"/"$C_OFF${TH[sel]:-}"}" "$inner"
    else
      tui_fit " $raw" "$inner"
    fi
    TUI_BOX+=("$col$TH_B_V$C_OFF$TUI_OUT$C_OFF$col$TH_B_V$C_OFF")
  done
  tui_rep "$TH_B_H" "$inner"
  TUI_BOX+=("$col$TH_B_BL$TUI_OUT$TH_B_BR$C_OFF")
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
  [ "$TUI_FORCE" -eq 0 ] || { out="$TH_RESET"$'\033[2J'; TUI_PREV=(); }
  [ "$n" -le "$TUI_ROWS" ] || n="$TUI_ROWS"
  for ((i = 0; i < n; i++)); do
    line="${TUI_FRAME[$i]}"
    if [ "$TUI_FORCE" -eq 1 ] || [ "$line" != "${TUI_PREV[$i]-}" ]; then
      # Clear first, then write: a trailing `ESC[K` would erase the last column (the cursor stays on it after a full-width
      # line), and with it the right border of every box.
      out+=$'\033['"$((i + 1));1H$TH_RESET"$'\033[K'"$line$TH_RESET"
    fi
  done
  # Lines of the previous frame that no longer exist.
  for ((i = n; i < ${#TUI_PREV[@]} && i < TUI_ROWS; i++)); do
    out+=$'\033['"$((i + 1));1H$TH_RESET"$'\033[K'
  done
  if [ -n "$TUI_CURSOR" ]; then out+=$'\033['"${TUI_CURSOR}H"$'\033[?25h'; else out+=$'\033[?25l'; fi
  printf '%s' "$out"
  TUI_PREV=("${TUI_FRAME[@]:0:$n}")
  TUI_FORCE=0
}

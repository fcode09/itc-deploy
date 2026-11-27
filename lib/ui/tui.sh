#!/usr/bin/env bash
# shellcheck disable=SC2034  # TUI_KEY, TUI_FRAME and the other TUI_* variables are read by the commands that use this layer
# Terminal primitives of the interactive panel: alternate screen, key reading, boxes and flicker-free drawing.
# Sourced on demand by lib/cmd/dashboard.sh; pure Bash, no external dependency.
#
# Drawing works on a frame: an array of lines (TUI_FRAME). tui_draw repaints only the lines that changed since the
# previous frame, in a single write, so a clock or a counter ticking does not make the screen flicker.
#
# Test mode (no terminal needed): DELTACTL_TUI_KEYS=<file> makes tui_key read one key name per line from that file
# (up, down, left, right, enter, esc, tab, pgup, pgdn, home, end, timeout, mouse:<button>:<column>:<row>[:up], paste:<text>, or a character;
# the end of the file is the key eof) and tui_draw print every frame as plain text between "=== frame N ===" lines, without any escape sequence. The
# size is then DELTACTL_TUI_ROWS x COLUMNS (30 x 100 by default).

shopt -s extglob

TUI_KEY=""
TUI_PASTE=""   # the text of the last key "paste" (bracketed paste: what the terminal pastes arrives as one key, not as many)
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
TUI_MOUSE=0                       # report the mouse (SGR mode: clicks and the wheel)? See tui_mouse.
TUI_MB=0 TUI_MX=0 TUI_MY=0 TUI_MUP=0   # the last mouse event: button, column, row (1-based), 1 for a release

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
  printf '\033[?1049h\033[?25l\033[?7l\033[?2004h%s' "$TH_RESET"   # (2004: what is pasted comes between ESC[200~ and ESC[201~)
  # Keys that arrive while the screen is being drawn would be echoed by the terminal itself, in the middle of the frame: the
  # echo is off for as long as the panel is on (tui_leave restores the settings it found).
  TUI_STTY="$(stty -g 2> /dev/null || true)"
  stty -echo 2> /dev/null || true
  TUI_ACTIVE=1
  [ "$TUI_MOUSE" -eq 0 ] || printf '\033[?1000h\033[?1006h'
  trap 'TUI_RESIZED=1' WINCH
  tui_size
}

# Leaves the alternate screen and shows the cursor again. Safe to call twice.
tui_leave() {
  [ "$TUI_ACTIVE" -eq 1 ] || return 0
  # The mouse goes off whatever TUI_MOUSE says (it costs nothing, and the terminal never keeps reporting to the shell). What it
  # had already sent (the release of the click that left the screen, a turn of the wheel) is read and dropped, or it would be
  # typed into the next prompt.
  printf '\033[?1006l\033[?1000l'
  if [ "$TUI_MOUSE" -eq 1 ]; then
    local _d _n=0
    while [ "$_n" -lt 256 ] && IFS= read -rsn1 -t 0.02 _d; do _n=$((_n + 1)); done
  fi
  printf '\033[?2004l\033[0m\033[?7h\033[?25h\033[?1049l\033[0m'
  if [ -n "$TUI_STTY" ]; then stty "$TUI_STTY" 2> /dev/null || stty echo 2> /dev/null || true; else stty echo 2> /dev/null || true; fi
  TUI_ACTIVE=0
  trap - WINCH
}

# Turns the report of the mouse on (1) or off (0). While it is on, the terminal sends clicks and the wheel to the panel instead of
# selecting text (most terminals still select with Shift held down).
tui_mouse() { # 1|0
  [ "$1" = "1" ] || [ "$1" = "0" ] || return 0
  [ "$TUI_MOUSE" != "$1" ] || return 0
  TUI_MOUSE="$1"
  { [ "$TUI_ACTIVE" -eq 1 ] && ! tui_test_mode; } || return 0
  if [ "$1" = "1" ]; then printf '\033[?1000h\033[?1006h'; else printf '\033[?1006l\033[?1000l'; fi
}

# A mouse report of the SGR mode, without its ESC: [<button;column;row then M (press) or m (release). Into TUI_KEY=mouse and
# TUI_MB / TUI_MX / TUI_MY / TUI_MUP; anything malformed is the key other. The numbers come from the terminal: they are checked
# to be short runs of digits before anything does arithmetic with them.
tui_mouse_parse() { # sequence
  local s="${1#\[<}" fin b x y
  fin="${s: -1}"
  s="${s%?}"
  b="${s%%;*}"; s="${s#*;}"
  x="${s%%;*}"; y="${s#*;}"
  if [[ "$b" =~ ^[0-9]{1,4}$ ]] && [[ "$x" =~ ^[0-9]{1,4}$ ]] && [[ "$y" =~ ^[0-9]{1,4}$ ]]; then
    TUI_KEY="mouse" TUI_MB=$((10#$b)) TUI_MX=$((10#$x)) TUI_MY=$((10#$y)) TUI_MUP=0
    [ "$fin" != "m" ] || TUI_MUP=1
  else
    TUI_KEY="other"
  fi
}

# Reads one key into TUI_KEY, waiting at most $1 seconds (none = forever). The result is a name (up, down, left,
# right, home, end, pgup, pgdn, delete, enter, esc, tab, backspace, timeout, eof, mouse, other) or the typed character.
# Is there input waiting that has not been read yet? (`read -t 0` only looks; it consumes nothing.) The panel uses it to keep a burst of keys
# (a held Tab, a finger drumming on the arrows) from drawing a whole screen for each one: see dash_loop.
tui_pending() { IFS= read -t 0 -r _ 2> /dev/null; }

tui_key() { # [timeout]
  local t="${1:-}" k rest="" c rc=0
  if tui_test_mode; then
    if [ "$TUI_KEYS_OPEN" -eq 0 ]; then
      exec 9< "$DELTACTL_TUI_KEYS"
      TUI_KEYS_OPEN=1
    fi
    if IFS= read -r k <&9; then TUI_KEY="$k"; else TUI_KEY="eof"; fi
    # paste:<text> is one pasted text (bracketed paste of a real terminal)
    if [[ "$TUI_KEY" == paste:* ]]; then TUI_PASTE="${TUI_KEY#paste:}" TUI_KEY="paste"; fi
    if [[ "$TUI_KEY" =~ ^mouse:([0-9]+):([0-9]+):([0-9]+)(:up)?$ ]]; then
      c=M
      [ -z "${BASH_REMATCH[4]}" ] || c=m
      tui_mouse_parse "[<${BASH_REMATCH[1]};${BASH_REMATCH[2]};${BASH_REMATCH[3]}$c"
    fi
    return 0
  fi
  if [ -n "$t" ]; then
    IFS= read -rsn1 -t "$t" k || rc=$?
    if [ "$rc" -gt 128 ]; then TUI_KEY="timeout"; return 0; fi
    # A resize interrupts the read with a signal status (above 128, handled above) and a timeout ends above 128 too. Status 1 is the end
    # of the input or a read error: the terminal is gone (a dropped SSH session). Calling that a timeout made the loop spin at full speed
    # forever, because read then fails at once instead of waiting.
    if [ "$rc" -eq 1 ]; then TUI_KEY="eof"; return 0; fi
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
            [ "${#rest}" -lt 16 ] || break   # (a mouse report is up to [<64;1234;1234M)
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
          '[<'*[Mm]) tui_mouse_parse "$rest" ;;
          '[200~')
            # A bracketed paste: everything up to ESC [ 201 ~ is one key (a line break reads as an empty character; the fields drop it).
            # It ends when the end marker comes, when 4096 characters came or when the terminal stops sending.
            local _pt="" _pn=0
            while [ "$_pn" -lt 4096 ] && IFS= read -rsn1 -t 0.2 c; do
              _pn=$((_pn + 1))
              [ -n "$c" ] || c=$'\n'
              _pt+="$c"
              case "$_pt" in *$'\033[201~') _pt="${_pt%$'\033[201~'}"; break ;; esac
            done
            TUI_KEY="paste" TUI_PASTE="$_pt"
            ;;
          '[M')
            # The old mouse format (a terminal without the SGR mode): three raw bytes follow. They are read and dropped, or a
            # click would type them as keys (a column can be an x, a q, a digit...).
            IFS= read -rsn3 -t 0.05 c || true
            TUI_KEY="other"
            ;;
          '[<'*)
            # A mouse report longer than expected: the rest of it is dropped too, up to its end.
            local _n=0
            while [ "$_n" -lt 32 ] && IFS= read -rsn1 -t 0.05 c; do _n=$((_n + 1)); case "$c" in [Mm]) break ;; esac; done
            TUI_KEY="other"
            ;;
          *) TUI_KEY="other" ;;
        esac
      else
        TUI_KEY="esc"
      fi
      ;;
    '') TUI_KEY="enter" ;;
    $'\t') TUI_KEY="tab" ;;
    $'\177' | $'\b') TUI_KEY="backspace" ;;
    # The Space bar arrives as a literal blank; every screen (and the test mode, which sends names) calls it "space".
    ' ') TUI_KEY="space" ;;
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
    # Where the real cursor would be (row;column), for the tests that check it: only when asked, so no frame changes otherwise.
    [ -z "${DELTACTL_TUI_SHOW_CURSOR:-}" ] || printf '=== cursor %s ===\n' "${TUI_CURSOR:-none}"
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

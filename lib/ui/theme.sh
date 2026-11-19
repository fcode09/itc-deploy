#!/usr/bin/env bash
# shellcheck disable=SC2034  # the TH_* variables are read by lib/ui/tui.sh and lib/cmd/dashboard*.sh
# Theme layer of the interactive panel. It re-skins ONLY the panel: the plain CLI keeps its fixed 16-colour palette (the golden
# snapshots depend on it). Sourced by lib/bootstrap.sh after lib/ui/ui.sh; not executed.
#
# A theme is a list of `key=value` lines (data, never sourced or evaluated):
#   bg fg dim faint border border_focus title accent ok warn err info key sel_bg sel_fg badge_bg badge_fg = #rrggbb  (bg may be `none`)
#   ramp = #rrggbb,#rrggbb,...   gradient from low to high (bars and graphs)
#   border = rounded | square | double | heavy
# The colours are written once as true colour (24-bit), then reduced to 256 or 16 colours when the terminal cannot show them.
# Built-ins: matrix (default), cyber, amber, nord, dracula, mono. Own themes: ~/.config/deltactl/themes/<name>.theme

declare -gA TH=() TH_HEX=() TH_BUILTIN=()
TH_NAME="" TH_MODE="none" TH_RESET=$'\033[0m' TH_BORDER="rounded" TH_C="" TH_SAVED=0
TH_RAMP=() TH_RAMP_N=0
TH_THEMES=(matrix cyber amber nord dracula mono)
TH_B_TL='╭' TH_B_TR='╮' TH_B_BL='╰' TH_B_BR='╯' TH_B_H='─' TH_B_V='│'
TH_BAR_ON='━' TH_BAR_OFF='─'
TH_SAVE_RED="" TH_SAVE_GRN="" TH_SAVE_YEL="" TH_SAVE_BLU="" TH_SAVE_MAG="" TH_SAVE_CYN="" TH_SAVE_GRY="" TH_SAVE_DIM="" TH_SAVE_OFF=""

TH_BUILTIN[matrix]='
bg=#050a06
fg=#c8f5d0
dim=#5f8f6a
faint=#1f3a26
border=#1f6b3a
border_focus=#00ff66
title=#6fd88a
accent=#00ff66
ok=#39ff7a
warn=#ffd23f
err=#ff3860
info=#2de2e6
key=#00ff66
sel_bg=#0f3d22
sel_fg=#eafff0
badge_bg=#00ff66
badge_fg=#03110a
ramp=#0f9d58,#39ff7a,#b5f23d,#ffd23f,#ff5a36
border=rounded'
TH_BUILTIN[cyber]='
bg=#0b0f1a
fg=#d6e4ff
dim=#6b7a99
faint=#1c2438
border=#2b3a67
border_focus=#00e5ff
title=#7aa2f7
accent=#00e5ff
ok=#00ffa3
warn=#ffcc00
err=#ff2e63
info=#b388ff
key=#ff2bd6
sel_bg=#1a2a55
sel_fg=#ffffff
badge_bg=#ff2bd6
badge_fg=#0b0f1a
ramp=#00e5ff,#00ffa3,#ffe14d,#ff9a3d,#ff2e63
border=rounded'
TH_BUILTIN[amber]='
bg=#0d0800
fg=#ffcf8a
dim=#8a6a2f
faint=#33270f
border=#6e4d12
border_focus=#ffb000
title=#d99a2b
accent=#ffb000
ok=#a6e22e
warn=#ffb000
err=#ff5f3a
info=#ffd479
key=#ffb000
sel_bg=#3a2a08
sel_fg=#fff1d6
badge_bg=#ffb000
badge_fg=#0d0800
ramp=#8bc34a,#cddc39,#ffb000,#ff7a00,#ff3d00
border=square'
TH_BUILTIN[nord]='
bg=#2e3440
fg=#d8dee9
dim=#7b88a1
faint=#3b4252
border=#4c566a
border_focus=#88c0d0
title=#81a1c1
accent=#88c0d0
ok=#a3be8c
warn=#ebcb8b
err=#bf616a
info=#81a1c1
key=#88c0d0
sel_bg=#434c5e
sel_fg=#eceff4
badge_bg=#88c0d0
badge_fg=#2e3440
ramp=#a3be8c,#ebcb8b,#d08770,#bf616a
border=rounded'
TH_BUILTIN[dracula]='
bg=#282a36
fg=#f8f8f2
dim=#6272a4
faint=#3a3d4d
border=#44475a
border_focus=#bd93f9
title=#8be9fd
accent=#bd93f9
ok=#50fa7b
warn=#f1fa8c
err=#ff5555
info=#8be9fd
key=#ff79c6
sel_bg=#44475a
sel_fg=#f8f8f2
badge_bg=#bd93f9
badge_fg=#282a36
ramp=#50fa7b,#f1fa8c,#ffb86c,#ff5555
border=rounded'
TH_BUILTIN[mono]='
border=square'

# Colour capability of the terminal: truecolor | 256 | 16 | none. DELTACTL_TRUECOLOR=1|0 overrides the detection.
th_detect() {
  TH_MODE=none
  [ "${UI_COLOR:-0}" -eq 1 ] || return 0
  case "${DELTACTL_TRUECOLOR:-auto}" in
    1 | yes | always) TH_MODE=truecolor; return 0 ;;
    0 | no | never) TH_MODE=16; [ "${UI_256:-0}" -eq 0 ] || TH_MODE=256; return 0 ;;
  esac
  case "${COLORTERM:-}" in truecolor | 24bit) TH_MODE=truecolor; return 0 ;; esac
  # Windows Terminal, VS Code and the like set their own markers instead of COLORTERM.
  if [ -n "${WT_SESSION:-}" ] || [ "${TERM_PROGRAM:-}" = "vscode" ] || [ "${TERM_PROGRAM:-}" = "WezTerm" ]; then TH_MODE=truecolor; return 0; fi
  case "${TERM:-}" in *-direct | *truecolor*) TH_MODE=truecolor; return 0 ;; esac
  if [ "${UI_256:-0}" -eq 1 ]; then TH_MODE=256; else TH_MODE=16; fi
}

# Escape sequence of a colour into TH_C: th_color <#rrggbb> [fg|bg]. Nothing when the terminal shows no colour.
th_color() {
  local hex="${1#\#}" kind="${2:-fg}" r g b base idx lum
  TH_C=""
  [ "$TH_MODE" != "none" ] || return 0
  r=$((16#${hex:0:2})) g=$((16#${hex:2:2})) b=$((16#${hex:4:2}))
  case "$TH_MODE" in
    truecolor)
      if [ "$kind" = "bg" ]; then base=48; else base=38; fi
      TH_C=$'\033['"$base;2;$r;$g;${b}m"
      ;;
    256)
      if [ "$kind" = "bg" ]; then base=48; else base=38; fi
      if [ $((r - g)) -ge -10 ] && [ $((r - g)) -le 10 ] && [ $((g - b)) -ge -10 ] && [ $((g - b)) -le 10 ]; then
        lum=$(((r + g + b) / 3))
        # The grey ramp 232..255 goes 8, 18, 28 ... 238 (steps of 10).
        if [ "$lum" -lt 4 ]; then idx=16; elif [ "$lum" -gt 243 ]; then idx=231; else idx=$((232 + (lum - 3) / 10)); [ "$idx" -le 255 ] || idx=255; fi
      else
        idx=$((16 + 36 * ((r * 5 + 127) / 255) + 6 * ((g * 5 + 127) / 255) + (b * 5 + 127) / 255))
      fi
      TH_C=$'\033['"$base;5;${idx}m"
      ;;
    *)
      idx=0
      [ "$r" -le 127 ] || idx=$((idx | 1))
      [ "$g" -le 127 ] || idx=$((idx | 2))
      [ "$b" -le 127 ] || idx=$((idx | 4))
      lum=$(((r * 299 + g * 587 + b * 114) / 1000))
      if [ "$kind" = "bg" ]; then
        if [ "$lum" -gt 170 ]; then base=$((100 + idx)); else base=$((40 + idx)); fi
      else
        if [ "$lum" -gt 170 ] || { [ "$idx" -eq 0 ] && [ "$lum" -gt 40 ]; }; then base=$((90 + idx)); else base=$((30 + idx)); fi
      fi
      TH_C=$'\033['"${base}m"
      ;;
  esac
}

# Reads theme text (key=value lines) into TH_HEX. Anything that is not a known key with a valid value is ignored.
th_parse() { # text
  local line k v item
  TH_HEX=()
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in '' | '#'*) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"
    k="${k// /}"; v="${v// /}"
    [[ "$k" =~ ^[a-z_0-9]+$ ]] || continue
    case "$k" in
      bg | fg | dim | faint | border_focus | title | accent | ok | warn | err | info | key | sel_bg | sel_fg | badge_bg | badge_fg)
        if [[ "$v" =~ ^#[0-9a-fA-F]{6}$ ]]; then TH_HEX[$k]="$v"; elif [ "$k" = "bg" ] && [ "$v" = "none" ]; then TH_HEX[bg]=""; fi ;;
      border)
        case "$v" in
          rounded | square | double | heavy) TH_HEX[border_style]="$v" ;;
          '#'*) [[ "$v" =~ ^#[0-9a-fA-F]{6}$ ]] && TH_HEX[border]="$v" ;;
        esac ;;
      ramp)
        local -a stops=()
        IFS=, read -ra stops <<< "$v"
        v=""
        for item in "${stops[@]}"; do
          [[ "$item" =~ ^#[0-9a-fA-F]{6}$ ]] && v+="${v:+,}$item"
        done
        [ -z "$v" ] || TH_HEX[ramp]="$v" ;;
    esac
  done <<< "$1"
}

# Text of a theme by name: a built-in or ~/.config/deltactl/themes/<name>.theme. The name is validated: it is a file name.
th_text() { # name -> TH_TEXT
  local name="$1" f
  TH_TEXT=""
  [[ "$name" =~ ^[a-z0-9_-]+$ ]] || return 1
  if [ -n "${TH_BUILTIN[$name]+x}" ]; then TH_TEXT="${TH_BUILTIN[$name]}"; return 0; fi
  f="${XDG_CONFIG_HOME:-${HOME:-}/.config}/deltactl/themes/$name.theme"
  [ -r "$f" ] || return 1
  TH_TEXT="$(head -c 4096 "$f")"
}
TH_TEXT=""

# Border characters of a style, with the ASCII fallback.
th_borders() { # style
  if [ "${UI_UTF8:-0}" -ne 1 ] || [ "${UI_RICH:-0}" -ne 1 ]; then
    TH_B_TL='+' TH_B_TR='+' TH_B_BL='+' TH_B_BR='+' TH_B_H='-' TH_B_V='|' TH_BAR_ON='#' TH_BAR_OFF='.'
    return 0
  fi
  TH_BAR_ON='█' TH_BAR_OFF='░'   # the empty part is drawn in the theme's faint colour, so it is a texture, not noise
  case "$1" in
    square) TH_B_TL='┌' TH_B_TR='┐' TH_B_BL='└' TH_B_BR='┘' TH_B_H='─' TH_B_V='│' ;;
    double) TH_B_TL='╔' TH_B_TR='╗' TH_B_BL='╚' TH_B_BR='╝' TH_B_H='═' TH_B_V='║' ;;
    heavy) TH_B_TL='┏' TH_B_TR='┓' TH_B_BL='┗' TH_B_BR='┛' TH_B_H='━' TH_B_V='┃' ;;
    *) TH_B_TL='╭' TH_B_TR='╮' TH_B_BL='╰' TH_B_BR='╯' TH_B_H='─' TH_B_V='│' ;;
  esac
}

# Applies a theme to the panel. Returns 1 when the name is unknown (nothing changes).
theme_apply() { # name
  local name="${1:-matrix}" k stop bgseq="" fgseq=""
  local -a stops=()
  th_text "$name" || return 1
  th_parse "$TH_TEXT"
  th_detect
  if [ "$TH_SAVED" -eq 0 ]; then
    TH_SAVE_RED="$C_RED" TH_SAVE_GRN="$C_GRN" TH_SAVE_YEL="$C_YEL" TH_SAVE_BLU="$C_BLU" TH_SAVE_MAG="$C_MAG"
    TH_SAVE_CYN="$C_CYN" TH_SAVE_GRY="$C_GRY" TH_SAVE_DIM="$C_DIM" TH_SAVE_OFF="$C_OFF"
    TH_SAVED=1
  fi
  TH_NAME="$name"
  TH=()
  TH_BORDER="${TH_HEX[border_style]:-rounded}"
  th_borders "$TH_BORDER"
  if [ "$TH_MODE" = "none" ]; then
    # No colour at all (NO_COLOR, pipes, dumb terminals): the panel falls back to the plain palette it always had.
    TH_RESET="$C_OFF"; TH_RAMP=(); TH_RAMP_N=0
    return 0
  fi
  if [ -n "${TH_HEX[bg]:-}" ]; then th_color "${TH_HEX[bg]}" bg; bgseq="$TH_C"; fi
  if [ -n "${TH_HEX[fg]:-}" ]; then th_color "${TH_HEX[fg]}" fg; fgseq="$TH_C"; fi
  TH_RESET=$'\033[0m'"$bgseq$fgseq"
  for k in fg dim faint accent ok warn err info key title; do
    if [ -n "${TH_HEX[$k]:-}" ]; then th_color "${TH_HEX[$k]}" fg; TH[$k]="$TH_C"; else TH[$k]=""; fi
  done
  if [ -n "${TH_HEX[border]:-}" ]; then th_color "${TH_HEX[border]}" fg; TH[border]="$TH_C"; else TH[border]="${TH[dim]}"; fi
  if [ -n "${TH_HEX[border_focus]:-}" ]; then th_color "${TH_HEX[border_focus]}" fg; TH[border_focus]="$TH_C"; else TH[border_focus]="${TH[accent]}"; fi
  # Combined styles. Without colours in the theme (mono) reverse video and bold keep the structure readable.
  if [ -n "${TH_HEX[sel_bg]:-}" ]; then
    th_color "${TH_HEX[sel_bg]}" bg; TH[sel]="$TH_C"
    th_color "${TH_HEX[sel_fg]:-${TH_HEX[fg]:-#ffffff}}" fg; TH[sel]+="$TH_C"
  else
    TH[sel]=$'\033[7m'
  fi
  if [ -n "${TH_HEX[badge_bg]:-}" ]; then
    th_color "${TH_HEX[badge_bg]}" bg; TH[badge]=$'\033[1m'"$TH_C"
    th_color "${TH_HEX[badge_fg]:-#000000}" fg; TH[badge]+="$TH_C"
  else
    TH[badge]=$'\033[1;7m'
  fi
  [ -n "${TH[dim]}" ] || TH[dim]=$'\033[2m'
  # Gradient for bars and graphs.
  TH_RAMP=()
  IFS=, read -ra stops <<< "${TH_HEX[ramp]:-}"
  for stop in "${stops[@]}"; do th_color "$stop" fg; TH_RAMP+=("$TH_C"); done
  TH_RAMP_N="${#TH_RAMP[@]}"
  if [ "$TH_RAMP_N" -eq 0 ]; then TH_RAMP=("${TH[ok]}" "${TH[warn]}" "${TH[err]}"); TH_RAMP_N=3; fi
  # The existing panel code colours with C_*: remap them so every part of it follows the theme at once.
  C_RED="${TH[err]}" C_GRN="${TH[ok]}" C_YEL="${TH[warn]}" C_BLU="${TH[info]}" C_MAG="${TH[key]}"
  C_CYN="${TH[accent]}" C_GRY="${TH[dim]}" C_DIM="${TH[faint]}" C_OFF="$TH_RESET"
  return 0
}

# Gives the CLI palette back (the panel calls it on exit).
theme_restore() {
  [ "$TH_SAVED" -eq 1 ] || return 0
  C_RED="$TH_SAVE_RED" C_GRN="$TH_SAVE_GRN" C_YEL="$TH_SAVE_YEL" C_BLU="$TH_SAVE_BLU" C_MAG="$TH_SAVE_MAG"
  C_CYN="$TH_SAVE_CYN" C_GRY="$TH_SAVE_GRY" C_DIM="$TH_SAVE_DIM" C_OFF="$TH_SAVE_OFF"
  TH_SAVED=0
}

# Colour of position $1 (0-based) in a bar of $2 cells along the ramp, into TH_C.
th_ramp_at() { # position cells
  local idx=0
  TH_C=""
  [ "$TH_RAMP_N" -gt 0 ] || return 0   # no colours (NO_COLOR, mono): nothing to pick
  if [ "$2" -gt 1 ] && [ "$TH_RAMP_N" -gt 1 ]; then idx=$(($1 * (TH_RAMP_N - 1) / ($2 - 1))); fi
  [ "$idx" -lt "$TH_RAMP_N" ] || idx=$((TH_RAMP_N - 1))
  TH_C="${TH_RAMP[$idx]:-}"
}

# Colour for a value that is $1 percent of its maximum (0-100) along the ramp, into TH_C: green when idle, hot when it is near
# its limit. Charts colour each row by the value that row stands for, so a quiet service never looks like an alarm.
th_ramp_pct() { # percent
  local p="$1" idx
  TH_C=""
  [ "$TH_RAMP_N" -gt 0 ] || return 0
  [ "$p" -ge 0 ] || p=0
  [ "$p" -le 100 ] || p=100
  idx=$(((p * (TH_RAMP_N - 1) + 50) / 100))
  TH_C="${TH_RAMP[$idx]:-}"
}

# Name of the theme to start with: DELTACTL_THEME, then UI_THEME in the config file, then matrix.
th_initial() {
  local want="${DELTACTL_THEME:-}" f line val=""
  if [ -z "$want" ]; then
    f="$(i18n_config_file)"
    if [ -r "$f" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in UI_THEME=*) val="${line#UI_THEME=}" ;; esac
      done < "$f"
      want="$val"
    fi
  fi
  want="${want,,}"
  [ -n "$want" ] || want="matrix"
  printf '%s' "$want"
}

# Remembers the theme in the config file (UI_THEME=<name>). A failure to write only means the choice lasts one run.
th_save() { # name
  local f
  f="$(i18n_config_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  [ -f "$f" ] || : > "$f" 2>/dev/null || return 0
  set_var "$f" UI_THEME "$1" 2>/dev/null || true
}

# Next built-in theme after the current one (for the key that cycles them), into TH_NEXT.
TH_NEXT=""
th_next() {
  local i n="${#TH_THEMES[@]}"
  for ((i = 0; i < n; i++)); do
    if [ "${TH_THEMES[$i]}" = "$TH_NAME" ]; then TH_NEXT="${TH_THEMES[$(((i + 1) % n))]}"; return 0; fi
  done
  TH_NEXT="${TH_THEMES[0]}"
}

# Border set for the current mode (rounded unless a theme says otherwise; ASCII outside a UTF-8 terminal).
th_borders rounded

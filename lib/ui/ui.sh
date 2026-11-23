#!/usr/bin/env bash
# Visual layer of ./deltactl: colors, banner, tables and help rendering.
# Sourced from lib.sh; not executed directly.
#
# Rules it follows (so scripts, pipes and tests do not break):
#   - Outside a terminal (stdout redirected) the output is plain text, with no escape codes.
#   - NO_COLOR (any value) or TERM=dumb disable colors.
#   - DELTACTL_COLOR=always|never|auto forces color. DELTACTL_UI=rich|plain|auto forces "rich" mode
#     (banner, symbols). DELTACTL_ASCII=1 avoids Unicode characters.

DELTACTL_VERSION="0.2.0"

# Computes the output mode. Called again only from the tests.
ui_init() {
  UI_RICH=0 UI_COLOR=0 UI_ERRCOLOR=0 UI_UTF8=0 UI_W=80 UI_256=0

  case "${DELTACTL_UI:-auto}" in
    rich) UI_RICH=1 ;;
    plain) UI_RICH=0 ;;
    *) [ -t 1 ] && UI_RICH=1 ;;
  esac

  local dumb=0
  [ "${TERM:-}" != "dumb" ] || dumb=1
  case "${DELTACTL_COLOR:-auto}" in
    always) UI_COLOR=1 UI_ERRCOLOR=1 ;;
    never) ;;
    *)
      if [ -z "${NO_COLOR:-}" ] && [ "$dumb" -eq 0 ]; then
        [ "$UI_RICH" -eq 1 ] && [ -t 1 ] && UI_COLOR=1
        [ -t 2 ] && UI_ERRCOLOR=1
      fi
      ;;
  esac

  if [ "${DELTACTL_ASCII:-0}" != "1" ]; then
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
      *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) UI_UTF8=1 ;;
    esac
  fi

  local cols="${COLUMNS:-}"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols="$(tput cols 2>/dev/null || echo 80)"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  UI_W="$cols"
  [ "$UI_W" -le 100 ] || UI_W=100
  [ "$UI_W" -ge 40 ] || UI_W=40

  if [ "$UI_COLOR" -eq 1 ] && [ "$(tput colors 2>/dev/null || echo 8)" -ge 256 ] 2>/dev/null; then UI_256=1; fi

  if [ "$UI_COLOR" -eq 1 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'
    C_MAG=$'\033[35m'; C_CYN=$'\033[36m'; C_GRY=$'\033[90m'
    C_BLD=$'\033[1m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
  else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_MAG=''; C_CYN=''; C_GRY=''; C_BLD=''; C_DIM=''; C_OFF=''
  fi
  # Colors for messages that go to stderr (decided by stderr, not stdout).
  if [ "$UI_ERRCOLOR" -eq 1 ]; then
    E_RED=$'\033[31m'; E_YEL=$'\033[33m'; E_OFF=$'\033[0m'
  else
    E_RED=''; E_YEL=''; E_OFF=''
  fi

  # Unicode symbols only in rich mode (terminal); in pipes and logs always ASCII.
  if [ "$UI_UTF8" -eq 1 ] && [ "$UI_RICH" -eq 1 ]; then
    UI_S_OK='●' UI_S_WARN='▲' UI_S_ERR='✖' UI_S_INFO='ℹ' UI_S_DOT='·' UI_S_ARROW='→' UI_S_RULE='─'
    UI_S_BAR_L='▕' UI_S_BAR_R='▏' UI_S_BAR_ON='█' UI_S_BAR_OFF='░' UI_S_SEL='▸'
    UI_S_TL='┌' UI_S_TR='┐' UI_S_BL='└' UI_S_BR='┘' UI_S_H='─' UI_S_V='│' UI_S_TJ='┬' UI_S_BJ='┴'
    UI_SPARK=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
  else
    UI_S_OK='*' UI_S_WARN='!' UI_S_ERR='x' UI_S_INFO='i' UI_S_DOT='.' UI_S_ARROW='->' UI_S_RULE='-'
    UI_S_BAR_L='[' UI_S_BAR_R=']' UI_S_BAR_ON='#' UI_S_BAR_OFF='.' UI_S_SEL='>'
    UI_S_TL='+' UI_S_TR='+' UI_S_BL='+' UI_S_BR='+' UI_S_H='-' UI_S_V='|' UI_S_TJ='+' UI_S_BJ='+'
    UI_SPARK=(_ . : - = + '*' '#')
  fi
  if [ "$UI_UTF8" -eq 1 ]; then UI_S_ELL='…'; else UI_S_ELL='~'; fi
}

ui_init

# Horizontal rule as wide as the terminal (max. 100).
ui_rule() {
  local n="${1:-$UI_W}" i line=""
  for ((i = 0; i < n; i++)); do line+="$UI_S_RULE"; done
  printf '%s%s%s\n' "$C_GRY" "$line" "$C_OFF"
}

# Section title: bold text with a rule underneath.
ui_h1() { # text
  printf '\n%s%s%s\n' "$C_BLD$C_CYN" "$1" "$C_OFF"
  ui_rule "$(( ${#1} > UI_W ? UI_W : ${#1} + 2 ))"
}

ui_h2() { printf '\n%s%s%s\n' "$C_BLD" "$1" "$C_OFF"; }

# Next-step hint: "→ text".
ui_hint() { printf '  %s%s %s%s\n' "$C_CYN" "$UI_S_ARROW" "$*" "$C_OFF"; }

# Aligned key: value (key in gray).
ui_kv() { # key value [width]
  # Padding is computed in characters (printf %-Ns counts bytes and misaligns accented text).
  local pad=$((${3:-14} - ${#1}))
  [ "$pad" -ge 0 ] || pad=0
  printf '  %s%s%*s%s %s\n' "$C_GRY" "$1" "$pad" "" "$C_OFF" "$2"
}

# Symbol colored by state: ok | warn | err | info | dim.
ui_sym() {
  case "$1" in
    ok) printf '%s%s%s' "$C_GRN" "$UI_S_OK" "$C_OFF" ;;
    warn) printf '%s%s%s' "$C_YEL" "$UI_S_WARN" "$C_OFF" ;;
    err) printf '%s%s%s' "$C_RED" "$UI_S_ERR" "$C_OFF" ;;
    info) printf '%s%s%s' "$C_CYN" "$UI_S_INFO" "$C_OFF" ;;
    *) printf '%s%s%s' "$C_GRY" "$UI_S_DOT" "$C_OFF" ;;
  esac
}

# Color associated with a state.
ui_state_color() {
  case "$1" in
    ok) printf '%s' "$C_GRN" ;;
    warn) printf '%s' "$C_YEL" ;;
    err) printf '%s' "$C_RED" ;;
    info) printf '%s' "$C_CYN" ;;
    dim) printf '%s' "$C_GRY" ;;
    bold) printf '%s' "$C_BLD" ;;
    *) printf '' ;;
  esac
}

# Usage meter: ui_bar <percent> [cells]  ->  ▕██████░░░░▏ (or [######....] without Unicode). It is green below
# 70 %, yellow below 85 % and red from there.
ui_bar() { # percent [cells]
  local pct="$1" cells="${2:-10}" on i out="" col
  [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
  [ "$pct" -le 100 ] || pct=100
  on=$(((pct * cells + 50) / 100))
  if [ "$pct" -lt 70 ]; then col="$C_GRN"; elif [ "$pct" -lt 85 ]; then col="$C_YEL"; else col="$C_RED"; fi
  for ((i = 0; i < cells; i++)); do
    if [ "$i" -lt "$on" ]; then out+="$UI_S_BAR_ON"; else out+="$UI_S_BAR_OFF"; fi
  done
  printf '%s%s%s%s%s%s%s' "$C_GRY" "$UI_S_BAR_L" "$col" "$out" "$C_GRY" "$UI_S_BAR_R" "$C_OFF"
}

# --- Tables -------------------------------------------------------------------------------------
# Usage:  ui_table_cols 12 5 10      defines the widths (the last column is not padded)
#         ui_th "INSTANCE" "SVC"     header
#         ui_tr "colorado" "ok:s0"   row; each cell is "text" or "<state>:text"
# <state> = ok | warn | err | info | dim | bold  (colors the cell)
#           st-ok | st-warn | st-err | st-dim    (state cell: symbol + text in rich mode)
# Padding is computed on the text WITHOUT color codes, so columns do not misalign.
UI_COLS_W=()
ui_table_cols() { UI_COLS_W=("$@"); }

# Prints one cell of width w. $1=width $2=state ("" = no color) $3=text $4=1 if it is the last one.
ui_cell() {
  local w="$1" kind="$2" text="$3" last="${4:-0}" sym="" extra=0 col shown
  case "$kind" in
    st-*)
      kind="${kind#st-}"
      if [ "$UI_RICH" -eq 1 ]; then
        sym="$(ui_sym "$kind") "
        extra=2
      fi
      ;;
  esac
  col="$(ui_state_color "$kind")"
  shown="$text"
  # The last column is neither truncated nor padded: it takes what it needs.
  if [ "$last" != "1" ] && [ $((${#text} + extra)) -gt "$w" ] && [ "$w" -gt 1 ]; then
    shown="${text:0:$((w - extra - 1))}$UI_S_ELL"
  fi
  if [ "$last" = "1" ]; then
    printf '%s%s%s%s' "$sym" "$col" "$shown" "$C_OFF"
  else
    printf '%s%s%s%s%*s' "$sym" "$col" "$shown" "$C_OFF" "$((w - extra - ${#shown}))" ""
  fi
}

ui_th() {
  local i n="$#" a
  printf '%s' "$C_BLD$C_GRY"
  i=0
  for a in "$@"; do
    i=$((i + 1))
    if [ "$i" -eq "$n" ]; then
      printf '%s' "$a"
    else
      # Padding in characters (not bytes) so headers with accents do not misalign.
      printf '%s%*s  ' "$a" "$((${UI_COLS_W[$((i - 1))]:-12} - ${#a}))" ""
    fi
  done
  printf '%s\n' "$C_OFF"
}

ui_tr() {
  local i=0 n="$#" a kind text
  for a in "$@"; do
    i=$((i + 1))
    kind="" text="$a"
    if [[ "$a" =~ ^(ok|warn|err|info|dim|bold|st-ok|st-warn|st-err|st-info|st-dim):(.*)$ ]]; then
      kind="${BASH_REMATCH[1]}"
      text="${BASH_REMATCH[2]}"
    fi
    if [ "$i" -eq "$n" ]; then
      ui_cell "${UI_COLS_W[$((i - 1))]:-12}" "$kind" "$text" 1
    else
      ui_cell "${UI_COLS_W[$((i - 1))]:-12}" "$kind" "$text"
      printf '  '
    fi
  done
  printf '\n'
}

# Escapes a text for JSON (quotes, backslashes and line breaks).
ui_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  printf '%s' "$s"
}

# --- Banner -------------------------------------------------------------------------------------
# Rich mode only (terminal). With a width < 78 or without Unicode a compact version is used.
ui_banner() { # [subtitle]
  [ "$UI_RICH" -eq 1 ] || return 0
  local sub="${1:-$(t ui.banner_subtitle)}" i line host
  host="$(hostname 2>/dev/null || t ui.host_fallback)"
  if [ "$UI_UTF8" -eq 1 ] && [ "$UI_W" -ge 78 ]; then
    local -a art=(
      '██████╗ ███████╗██╗     ████████╗ █████╗  ██████╗████████╗██╗     '
      '██╔══██╗██╔════╝██║     ╚══██╔══╝██╔══██╗██╔════╝╚══██╔══╝██║     '
      '██║  ██║█████╗  ██║        ██║   ███████║██║        ██║   ██║     '
      '██║  ██║██╔══╝  ██║        ██║   ██╔══██║██║        ██║   ██║     '
      '██████╔╝███████╗███████╗   ██║   ██║  ██║╚██████╗   ██║   ███████╗'
      '╚═════╝ ╚══════╝╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝   ╚═╝   ╚══════╝'
    )
    local -a grad=(51 45 39 33 27 63)
    printf '\n'
    i=0
    for line in "${art[@]}"; do
      if [ "$UI_256" -eq 1 ]; then
        printf '%s%s%s\n' $'\033[38;5;'"${grad[$i]}"'m' "$line" "$C_OFF"
      else
        printf '%s%s%s\n' "$C_BLD$C_CYN" "$line" "$C_OFF"
      fi
      i=$((i + 1))
    done
  else
    printf '\n  %sDELTACTL%s\n' "$C_BLD$C_CYN" "$C_OFF"
  fi
  printf '  %s%s  %s  v%s  %s  %s%s\n' "$C_GRY" "$sub" "$UI_S_DOT" "$DELTACTL_VERSION" "$UI_S_DOT" "$host" "$C_OFF"
  printf '\n'
}

# --- Help rendering -----------------------------------------------------------------------------
# Markup of the lib/help/*.txt files (a single source of truth for the help):
#   # Title              page heading
#   ## Section           subheading
#   $ command            command to copy (green)
#   ! text               warning
#   > text               note
#   - text               bullet
#   | command | text     table row (command in green, description aligned)
#   `code`               inline highlight
# Any other line is printed as is (with inline highlighting).
ui_inline() { # text
  local s="$1" out="" re='^([^`]*)`([^`]+)`(.*)$'
  if [ "$UI_COLOR" -ne 1 ]; then
    printf '%s' "$s"
    return 0
  fi
  while [[ "$s" =~ $re ]]; do
    out+="${BASH_REMATCH[1]}${C_CYN}${BASH_REMATCH[2]}${C_OFF}"
    s="${BASH_REMATCH[3]}"
  done
  printf '%s' "$out$s"
}

# Splits a text of the help into lines of at most $2 visible cells, by words, into UI_WRAP. Backticks are not visible when there
# is colour (ui_inline turns them into colour): they do not count then, and a `code span` cut by the end of a line is closed there
# and opened again on the next, so each line keeps its colour. A word longer than the width stays whole on its own line. Runs of
# spaces inside the text are kept (some pages use two spaces as a separator); at the start of a wrapped line they are dropped.
UI_WRAP=()
ui_wrap_text() { # text width
  local w="$2" word line="" n=0 wl ticks open=0 reopen=0 t rest="$1"
  local -a words=()
  UI_WRAP=()
  rest="${rest#"${rest%%[! ]*}"}"; rest="${rest%"${rest##*[! ]}"}"
  # Split on single spaces: an empty word stands for one more space of a run.
  while [[ "$rest" == *" "* ]]; do words+=("${rest%% *}"); rest="${rest#* }"; done
  words+=("$rest")
  for word in "${words[@]}"; do
    [ -n "$word" ] || [ -n "$line" ] || continue          # a space never starts a line
    wl="${#word}"
    if [ "$UI_COLOR" -eq 1 ]; then t="${word//[!\`]/}"; ticks="${#t}"; wl=$((wl - ticks)); else ticks=0; fi
    if [ -n "$line" ] && [ $((n + 1 + wl)) -gt "$w" ]; then
      # The line is full: a code span open at its end is closed here and opened again with the next word.
      line="${line%"${line##*[! ]}"}"
      if [ "$open" -eq 1 ]; then UI_WRAP+=("$line\`"); reopen=1; else UI_WRAP+=("$line"); fi
      line="" n=0
      [ -n "$word" ] || continue
    fi
    if [ -z "$line" ]; then
      line="$word" n="$wl"
      if [ "$reopen" -eq 1 ]; then line="\`$line"; reopen=0; fi
    else
      line+=" $word" n=$((n + 1 + wl))
    fi
    [ $((ticks % 2)) -eq 0 ] || open=$((1 - open))
  done
  [ -z "$line" ] || UI_WRAP+=("$line")
  [ "${#UI_WRAP[@]}" -gt 0 ] || UI_WRAP=("")
}

# Prints a help text wrapped to the width of the screen: the first line after $2 (already coloured, $3 cells wide), the others
# under it, indented by as many spaces.
ui_render_wrapped() { # text prefix prefix_width
  local i pad
  ui_wrap_text "$1" $((UI_W - $3))
  printf -v pad '%*s' "$3" ''
  printf '%s%s\n' "$2" "$(ui_inline "${UI_WRAP[0]}")"
  for ((i = 1; i < ${#UI_WRAP[@]}; i++)); do printf '%s%s\n' "$pad" "$(ui_inline "${UI_WRAP[$i]}")"; done
}

# Renders a help page. Items of a list (-, !, >), table rows (| command | description) and plain lines are wrapped to the width of
# the screen, the following lines under the text of their item (a hanging indent); a line that starts with two spaces right after
# an item or a row goes on that item, so a long one can be written over several lines. Command lines ($) are never wrapped.
ui_render_file() { # file
  local line rest cmd desc pad blank=1 i n next
  local -a lines=()
  mapfile -t lines < "$1"
  n="${#lines[@]}"
  for ((i = 0; i < n; i++)); do
    line="${lines[$i]%$'\r'}"
    # An item or a row takes the lines that go on it.
    case "$line" in
      '- '* | '! '* | '> '* | '| '*)
        while [ $((i + 1)) -lt "$n" ]; do
          next="${lines[$((i + 1))]%$'\r'}"
          [[ "$next" == "  "[![:space:]]* ]] || break
          line+=" ${next#"${next%%[![:space:]]*}"}"
          i=$((i + 1))
        done
        ;;
    esac
    # Sections already get a blank line before them: if the file brings one, it is not duplicated.
    if [ "${line:0:3}" = "## " ] && [ "$blank" -eq 1 ]; then
      printf '%s%s%s\n' "$C_BLD" "${line#\#\# }" "$C_OFF"
      blank=0
      continue
    fi
    if [ -z "$line" ]; then blank=1; else blank=0; fi
    case "$line" in
      '# '*) ui_h1 "${line#\# }" ;;
      '## '*) ui_h2 "${line#\#\# }" ;;
      '$ '*) printf '  %s$%s %s%s%s\n' "$C_GRY" "$C_OFF" "$C_GRN" "${line#\$ }" "$C_OFF" ;;
      '! '*) ui_render_wrapped "${line#! }" "  $(ui_sym warn) " 4 ;;
      '> '*) ui_render_wrapped "${line#> }" "  $(ui_sym info) " 4 ;;
      '- '*) ui_render_wrapped "${line#- }" "  $C_GRY$UI_S_DOT$C_OFF " 4 ;;
      '| '*)
        # Table row "| command | description": command in green, the description at column 52 going on under itself; on a screen
        # too narrow for that, the description goes under the command.
        rest="${line#| }"
        cmd="${rest%% | *}"
        desc="${rest#* | }"
        [ "$rest" != "$cmd" ] || desc=""
        pad=$((50 - ${#cmd}))
        [ "$pad" -ge 1 ] || pad=1
        if [ -z "$desc" ]; then
          printf '  %s%s%s\n' "$C_GRN" "$cmd" "$C_OFF"
        elif [ $((UI_W - 2 - ${#cmd} - pad)) -ge 24 ]; then
          ui_render_wrapped "$desc" "  $C_GRN$cmd$C_OFF$(printf '%*s' "$pad" '')" $((2 + ${#cmd} + pad))
        else
          printf '  %s%s%s\n' "$C_GRN" "$cmd" "$C_OFF"
          [ -z "$desc" ] || ui_render_wrapped "$desc" "    " 4
        fi
        ;;
      '') printf '\n' ;;
      *) ui_render_wrapped "$line" "" 0 ;;
    esac
  done
}

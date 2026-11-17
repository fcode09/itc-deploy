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
  else
    UI_S_OK='*' UI_S_WARN='!' UI_S_ERR='x' UI_S_INFO='i' UI_S_DOT='.' UI_S_ARROW='->' UI_S_RULE='-'
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

ui_render_file() { # file
  local line rest cmd desc pad blank=1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
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
      '! '*) printf '  %s %s\n' "$(ui_sym warn)" "$(ui_inline "${line#! }")" ;;
      '> '*) printf '  %s %s\n' "$(ui_sym info)" "$(ui_inline "${line#> }")" ;;
      '- '*) printf '  %s%s%s %s\n' "$C_GRY" "$UI_S_DOT" "$C_OFF" "$(ui_inline "${line#- }")" ;;
      '| '*)
        # Table row "| command | description": command in green, aligned at column 50.
        rest="${line#| }"
        cmd="${rest%% | *}"
        desc="${rest#* | }"
        [ "$rest" != "$cmd" ] || desc=""
        pad=$((50 - ${#cmd}))
        [ "$pad" -ge 1 ] || pad=1
        printf '  %s%s%s%*s%s\n' "$C_GRN" "$cmd" "$C_OFF" "$pad" "" "$(ui_inline "$desc")"
        ;;
      *) printf '%s\n' "$(ui_inline "$line")" ;;
    esac
  done < "$1"
}

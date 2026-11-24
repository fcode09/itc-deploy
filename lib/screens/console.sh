#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Screen: Console (view 6). The console of the Instances strip over the whole body. The key 6 gives the line the keyboard at once;
# Tab only shows the view. Loaded by lib/screens/registry.sh.

source "$ROOT/lib/screens/console_alias.sh"

DASH_CON=() DASH_CON_N=0 DASH_CON_SEQ=0 DASH_CON_COPIED=0 DASH_CON_MAX=500 DASH_CON_SCROLL=0

DASH_BUILTINS=(help clear theme history goto alias unalias refresh quit exit)

# How far PgUp/PgDn move the transcript: five lines in the strip, almost a screen in the Console view. Into DASH_CON_PAGE.
DASH_CON_PAGE=5

# Adds a line to the transcript. Colour sequences are kept, anything else dangerous is dropped (see tui_sanitize); a plain
# reset is replaced by the theme's, so the background of the theme survives it.
dash_con_add() { # text
  local rs=$'\033[0m'
  tui_sanitize "$1"
  DASH_CON+=("${TUI_OUT//"$rs"/$C_OFF}")
  if [ "${#DASH_CON[@]}" -gt "$DASH_CON_MAX" ]; then DASH_CON=("${DASH_CON[@]:100}"); fi
  DASH_CON_N=$((DASH_CON_N + 1))
  # Someone reading older lines keeps them on screen while a command goes on printing (the new lines push the end further away).
  if [ "$DASH_CON_SCROLL" -gt 0 ]; then DASH_CON_SCROLL=$((DASH_CON_SCROLL + 1)); dash_con_clamp; fi
}

# Copies to the transcript the lines the running command printed since the last time (the output buffer keeps only the last
# ~2000 lines, but this is called every few hundred milliseconds).
dash_con_mirror() {
  local n k t
  [ "$DASH_CON_SEQ" -eq "$JOB_SEQ" ] || return 0
  n=$((JOB_TOTAL - DASH_CON_COPIED))
  [ "$n" -gt 0 ] || return 0
  t="${#JOB_LINES[@]}"
  [ "$n" -le "$t" ] || n="$t"
  for ((k = t - n; k < t; k++)); do dash_con_add "${JOB_LINES[$k]}"; done
  DASH_CON_COPIED="$JOB_TOTAL"
}

# The name in the prompt: the selected instance, or deltactl when there is none (or the New button is selected).
dash_prompt_name() {
  if [ "$DASH_ON_NEW" -eq 0 ] && [ "${#DASH_NAMES[@]}" -gt 0 ]; then DASH_PN="${DASH_NAMES[$DASH_SEL]}"; else DASH_PN="deltactl"; fi
}

# --- The Console view (6): the same console, over the whole body. The key 6 (and `goto console`) give the line the keyboard at
# once; Tab only shows the view. Without the keyboard, the arrows and PgUp/PgDn move along the transcript and Enter or : type.
dash_open_console() {
  DASH_VIEW=console DASH_MODE=cmd DASH_BUF="" DASH_CUR=0 DASH_HIDX="${#DASH_HIST[@]}"
}

dash_con_page() {
  DASH_CON_PAGE=5
  [ "$DASH_VIEW" != "console" ] || DASH_CON_PAGE=$((TUI_ROWS - 8))
  [ "$DASH_CON_PAGE" -ge 1 ] || DASH_CON_PAGE=1
}

# Keeps the scroll of the transcript (0 = its end) between the end and the first line. In the Console view the first line stops at
# the top of the box, so the box is never left half empty.
dash_con_clamp() {
  local smax=$((${#DASH_CON[@]} - 1))
  [ "$DASH_VIEW" != "console" ] || smax=$((${#DASH_CON[@]} - (TUI_ROWS - 7)))
  [ "$smax" -ge 0 ] || smax=0
  [ "$DASH_CON_SCROLL" -ge 0 ] || DASH_CON_SCROLL=0
  [ "$DASH_CON_SCROLL" -le "$smax" ] || DASH_CON_SCROLL="$smax"
}

dash_key_console() { # key
  dash_con_page
  case "$1" in
    enter) DASH_MODE=cmd DASH_BUF="" DASH_CUR=0 DASH_HIDX="${#DASH_HIST[@]}" ;;
    up | k) DASH_CON_SCROLL=$((DASH_CON_SCROLL + 1)) ;;
    down | j) DASH_CON_SCROLL=$((DASH_CON_SCROLL - 1)) ;;
    pgup) DASH_CON_SCROLL=$((DASH_CON_SCROLL + DASH_CON_PAGE)) ;;
    pgdn) DASH_CON_SCROLL=$((DASH_CON_SCROLL - DASH_CON_PAGE)) ;;
    home | g) DASH_CON_SCROLL=1000000 ;;
    end | G) DASH_CON_SCROLL=0 ;;
    $'\014') DASH_CON=() DASH_CON_N=$((DASH_CON_N + 1)) DASH_CON_SCROLL=0 ;;   # Ctrl+L
  esac
  dash_con_clamp
}

# --- History on disk (next to the config file), the last 200 lines are loaded at start.
dash_hist_file() { printf '%s/history' "$(dirname "$(i18n_config_file)")"; }

dash_hist_load() {
  local f line
  f="$(dash_hist_file)"
  [ -r "$f" ] || return 0
  DASH_HIST=()
  while IFS= read -r line; do [ -z "$line" ] || DASH_HIST+=("$line"); done < <(tail -n 200 "$f" 2> /dev/null)
  DASH_HIDX="${#DASH_HIST[@]}"
}

dash_hist_save() { # line   (a failure to write only means the line is not remembered)
  local f
  f="$(dash_hist_file)"
  mkdir -p "$(dirname "$f")" 2> /dev/null || return 0
  (umask 077; printf '%s\n' "$1" >> "$f") 2> /dev/null || true
}

# --- Built-in commands: they run inside the panel and answer in the transcript. Returns 0 when it handled the command.
dash_con_help() {
  local line
  while IFS= read -r line; do dash_con_add "$line"; done <<< "$(t tui.con.help)"
}

dash_is_builtin() { # word [args...]
  case "$1" in
    help) [ "$#" -eq 1 ] ;;   # `help topic` is deltactl's own help
    '?' | clear | cls | theme | history | goto | view | alias | unalias | refresh | quit | exit) return 0 ;;
    *) return 1 ;;
  esac
}

dash_builtin() { # command args...
  local c="$1" i n start
  shift
  case "$c" in
    help | '?') dash_con_help ;;
    clear | cls) DASH_CON=() DASH_CON_N=$((DASH_CON_N + 1)) ;;
    theme)
      if [ "$#" -eq 0 ] || [ "$1" = "list" ]; then
        dash_con_add "$(t tui.con.theme_now "$TH_NAME")"
        dash_con_add "  ${TH_THEMES[*]}"
      elif theme_apply "$1"; then
        th_save "$1"
        dash_theme_refresh
        dash_con_add "$(t tui.msg.theme_set "$TH_NAME")"
      else
        dash_con_add "$C_RED$(t tui.con.bad_theme "$1" "${TH_THEMES[*]}")$C_OFF"
      fi
      ;;
    history)
      n="${#DASH_HIST[@]}"
      if [ "$n" -eq 0 ]; then dt tui.con.history_empty; dash_con_add "$C_GRY$DTV$C_OFF"; fi
      start=$((n - 20)); [ "$start" -ge 0 ] || start=0
      for ((i = start; i < n; i++)); do dash_con_add "$(printf '%4d  %s' $((i + 1)) "${DASH_HIST[$i]}")"; done
      ;;
    goto | view)
      if dash_screen_valid "${1:-}"; then DASH_VIEW="$1"; else dash_con_add "$C_RED$(t tui.con.bad_view)$C_OFF"; fi
      ;;
    alias | unalias) dash_alias_cmd "$c" "$@" ;;
    refresh) dash_refresh_request; dash_con_add "$(t tui.msg.refreshed)" ;;
    quit | exit) DASH_QUIT=1 ;;
    *) return 1 ;;
  esac
  return 0
}

# A real shell inside the installation: the panel steps aside and comes back when it ends.
dash_shell() {
  dash_con_add "$(dash_prompt_glyph) !"
  tui_leave
  printf '\n  %s\n\n' "$(t tui.con.shell_hint)"
  (cd "$ROOT" && "${SHELL:-bash}" -i) || true
  tui_enter
  DASH_SIGINT=0
  dash_refresh_request
}

dash_prompt_glyph() { printf '%s' "$DASH_PG"; }   # (set once by dash_symbols_init: a command substitution per frame is a process per frame)

# Completes the word being typed in the command line: commands (and the panel's own), then instances, then services.
dash_complete() {
  local buf="$DASH_BUF" bang="" idx prefix w common c head=""
  local -a toks cands=() pool=()
  case "$buf" in '!'*) bang="!"; buf="${buf#!}" ;; esac
  read -ra toks <<< "$buf"
  if [[ "$buf" == *" " ]]; then idx="${#toks[@]}" prefix=""; else idx=$((${#toks[@]} - 1)) prefix="${toks[$idx]:-}"; fi
  [ "$idx" -ge 0 ] || idx=0
  case "$idx" in
    0) pool=("${HELP_COMMANDS[@]}" "${DASH_BUILTINS[@]}" ${DASH_ALIAS_NAMES[@]+"${DASH_ALIAS_NAMES[@]}"}) ;;
    1)
      case "${toks[0]:-}" in
        theme) pool=("${TH_THEMES[@]}") ;;
        goto | view) pool=(instances resources output runs procs console server images) ;;
        alias | unalias) pool=(${DASH_ALIAS_NAMES[@]+"${DASH_ALIAS_NAMES[@]}"}) ;;
        *) pool=("${DASH_NAMES[@]}") ;;
      esac
      ;;
    2) pool=("${KNOWN_SERVICES[@]}") ;;
    *) return 0 ;;
  esac
  for w in "${pool[@]}"; do
    case "$w" in "$prefix"*) cands+=("$w") ;; esac
  done
  [ "${#cands[@]}" -gt 0 ] || return 0
  for ((c = 0; c < idx; c++)); do head+="${toks[$c]} "; done
  if [ "${#cands[@]}" -eq 1 ]; then
    DASH_BUF="$bang$head${cands[0]} "
    return 0
  fi
  common="${cands[0]}"
  for w in "${cands[@]}"; do
    while [ -n "$common" ] && [ "${w#"$common"}" = "$w" ]; do common="${common%?}"; done
  done
  DASH_BUF="$bang$head$common"
}

dash_submit_cmd() {
  local buf="$DASH_BUF" term=0 view=output
  local -a args
  DASH_MODE=normal DASH_CUR=0
  buf="${buf#"${buf%%[![:space:]]*}"}"
  buf="${buf%"${buf##*[![:space:]]}"}"
  [ -n "$buf" ] || return 0
  DASH_CON_SCROLL=0   # what a new command prints is read from its start
  if [ "${#DASH_HIST[@]}" -eq 0 ] || [ "${DASH_HIST[-1]}" != "$buf" ]; then DASH_HIST+=("$buf"); dash_hist_save "$buf"; fi
  DASH_HIDX="${#DASH_HIST[@]}"
  case "$buf" in '!'*) term=1; buf="${buf#!}"; buf="${buf#"${buf%%[![:space:]]*}"}" ;; esac
  # A lone `!` is a real shell.
  if [ "$term" -eq 1 ] && [ -z "$buf" ]; then dash_shell; return 0; fi
  # An alias as the first word is replaced by its command (the history keeps what was typed).
  if [ "$term" -eq 0 ]; then dash_alias_expand "$buf"; buf="$DASH_ALIAS_LINE"; fi
  read -ra args <<< "$buf"
  # The panel's own commands answer in the transcript (the other commands echo themselves when they start).
  if [ "$term" -eq 0 ] && dash_is_builtin "${args[@]}"; then
    dash_prompt_name
    dash_con_add "${TH[accent]:-$C_CYN}$DASH_PN $(dash_prompt_glyph)$C_OFF $buf"
    dash_builtin "${args[@]}"
    return 0
  fi
  case "${args[0]:-}" in ./deltactl | deltactl) args=("${args[@]:1}") ;; esac
  [ "${#args[@]}" -gt 0 ] || return 0
  # `new` and `new --wizard` open the form inside the panel (with a leading `!` they run in the terminal, as before).
  if [ "$term" -eq 0 ] && [ "${args[0]}" = "new" ]; then
    if [ "${#args[@]}" -eq 1 ] || { [ "${#args[@]}" -eq 2 ] && [ "${args[1]}" = "--wizard" ]; }; then
      dash_open_new
      return 0
    fi
  fi
  # The other wizards and the menu ask questions: they need the terminal.
  case " ${args[*]} " in *" --wizard "*) term=1 ;; esac
  case "${args[0]}" in menu) term=1 ;; new) [ "${#args[@]}" -gt 1 ] || term=1 ;; esac
  # On the Overview and in the Console view the answer stays in the console; in the other views it opens the Output view, as before.
  case "$DASH_VIEW" in instances | console) view=stay ;; esac
  if [ "$term" -eq 1 ]; then dash_terminal "${args[@]}"; else dash_start_job "$view" "${args[@]}"; fi
}

# --- Console box ------------------------------------------------------------------------------------------------------
# The strip at the bottom: the transcript of the console (what was typed, what the commands printed, how they ended) and, on its
# last line, the prompt. While the console has the keyboard (mode cmd) its box is the focused one and the prompt shows the line
# with a cursor.
dash_console_box() { # width height
  local w="$1" h="$2" inner avail n end start i acc pn pg before at after cur prompt title hint foc=0
  local -a body=()
  inner=$((h - 2))
  avail=$((inner - 1))
  [ "$avail" -ge 1 ] || avail=1
  [ "$DASH_MODE" != "cmd" ] || foc=1
  acc="${TH[accent]:-$C_CYN}"
  dash_prompt_name; pn="$DASH_PN"
  pg="$DASH_PG"
  n="${#DASH_CON[@]}"
  end=$((n - DASH_CON_SCROLL))
  [ "$end" -ge 0 ] || end=0
  start=$((end - avail)); [ "$start" -ge 0 ] || start=0
  for ((i = start; i < end; i++)); do body+=("${DASH_CON[$i]}"); done
  # The prompt is always on the last line of the box: short transcripts leave their blank lines between.
  while [ "${#body[@]}" -lt "$avail" ]; do body+=(""); done
  if [ "$DASH_MODE" = "cmd" ]; then
    before="${DASH_BUF:0:$DASH_CUR}"; at="${DASH_BUF:$DASH_CUR:1}"; after="${DASH_BUF:$((DASH_CUR + 1))}"
    if [ -n "$DASH_REV" ]; then cur="$DASH_REV${at:- }$C_OFF"; prompt="$acc$pn $pg$C_OFF $before$cur$after"
    else prompt="$pn $pg $before|$at$after"; fi
  else
    dt tui.con.hint; hint="$DTV"
    prompt="$C_GRY$pn $pg $hint$C_OFF"
  fi
  body+=("$prompt")
  dt tui.con.title; title="$DTV"
  dash_job_label
  [ -z "$DASH_JL" ] || title+=" $UI_S_DOT $DASH_JL"
  tui_box "$title" "$w" "$h" body "" "$foc"
}

# --- View: console ---------------------------------------------------------------------------------------------------
# The console of the Overview over the whole body: a workspace to type commands and read what they printed.
dash_view_console() { # body_height
  dash_console_box "$TUI_COLS" "$1"
  TUI_FRAME+=("${TUI_BOX[@]}")
}

# --- The contract of lib/screens/registry.sh --------------------------------------------------------------------
scr_console_render() { dash_view_console "$2"; } # width height
scr_console_key() { dash_key_console "$1"; }
scr_console_keys() { dash_keys_view console "$1"; } # width
scr_console_texts() { DASH_KEYS[console]="$(t tui.keys.console "$DASH_UD")"; }
scr_console_sig() { DASH_SIG+="|$DASH_CON_N|$DASH_CON_SCROLL"; }
scr_console_enter() { dash_open_console; }
scr_console_click() { dash_key_console enter; } # column row

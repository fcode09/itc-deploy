#!/usr/bin/env bash
# shellcheck disable=SC2034  # the DASH_RUNS_* variables are shared with lib/cmd/dashboard.sh and dashboard_view.sh
# The Runs view of the panel (key 4): the history of the operations that changed something (lib/core/runs.sh). A list of runs
# on one side, the detail of the selected one on the other (state, consumption, containers before/after, how it compares with the
# earlier runs of the same operation, the end of its output) and, with `t`, what each kind of operation costs on average.
# Sourced by lib/cmd/dashboard.sh. It only reads what the runs left on disk (as data, never sourced).
#
# Cost: the index is read again when the view is shown, every 5 s while it stays on screen, when a command of the panel ends and
# on `r`; the detail of a run is built once per selection (it reads a few small files), not once per frame.

# shellcheck source=lib/cmd/runs.sh
source "$ROOT/lib/cmd/runs.sh"

DASH_RUNS_LINES=()          # one index line per run: running ones first, then the finished ones, newest first
DASH_RUNS_SEL=0 DASH_RUNS_SEL_ID="" DASH_RUNS_OFF=0 DASH_RUNS_MODE=list   # list | stats
DASH_RUNS_AT=-1000 DASH_RUNS_N=0 DASH_RUNS_SIG="" DASH_RUNS_MAX=300
DASH_RUNS_STATS_INST="" DASH_RUNS_STATS_OK=0 DASH_RUNS_STATS_FOR=""
DASH_RUNS_DET=() DASH_RUNS_DET_KEY="" DASH_RUNS_LIST_L=() DASH_RUNS_STATS_L=()
DTF=""

# Cached translation with arguments: dtf <key> [a1 a2 ...] leaves the text in DTF.
dtf() {
  local a i=1
  dt "$1"; DTF="$DTV"
  shift
  for a in "$@"; do DTF="${DTF//"{$i}"/"$a"}"; i=$((i + 1)); done
}

# Pads a text to $2 characters, on the right (padr) or on the left (padl), into DASH_PAD. printf pads by bytes, which leaves a word
# with an accent one cell short.
DASH_PAD=""
dash_runs_padr() { # text width
  local s="${1:0:$2}"
  printf -v DASH_PAD '%s%*s' "$s" $(($2 - ${#s})) ''
}
dash_runs_padl() { # text width
  local s="${1:0:$2}"
  printf -v DASH_PAD '%*s%s' $(($2 - ${#s})) '' "$s"
}

# A line of a saved output as it can be shown: a CRLF ending is dropped, a progress bar that rewrites its line with \r shows what the
# terminal would have shown (the text after the last \r), colours stay, and every other control character (backspace, form feed,
# the charset switches...) goes. Into TUI_OUT.
dash_runs_logline() { # line
  local l="$1" keep
  l="${l%$'\r'}"
  l="${l##*$'\r'}"
  tui_sanitize "$l"
  if [[ "$TUI_OUT" == *[[:cntrl:]]* ]]; then
    # (after tui_sanitize the only ESC left starts a colour sequence: it is kept)
    keep="${TUI_OUT//$'\033'/$'\001'}"
    keep="${keep//[[:cntrl:]]/}"
    TUI_OUT="${keep//$'\001'/$'\033'}"
  fi
}

# A text that came from a file, without anything that could move the cursor or change the colours of the panel.
dash_runs_clean() { # variable_name
  local -n _v="$1"
  [[ "$_v" == *[[:cntrl:]]* ]] || return 0
  tui_strip_ansi "$_v"
  _v="${TUI_OUT//[[:cntrl:]]/}"
}

# --- Data -----------------------------------------------------------------------------------------------------------------

# Reads the index and the runs in progress. Marks the frame dirty only when something is different from last time.
dash_runs_load() {
  local base="$INSTANCES_DIR/.deltactl" f id pid i sel
  local -a fin=() lines=()
  DASH_RUNS_AT="$SECONDS"
  for f in "$base"/active/*; do
    [ -e "$f" ] || continue
    id="${f##*/}" pid=""
    read -r pid 2> /dev/null < "$f" || true
    runs_pid_alive "$pid" || continue
    runs_meta_read "$base/runs/$id" || continue
    lines+=("$id"$'\t'"${RUN[STARTED_AT]:-}"$'\t'"${RUN[OP]:-}"$'\t'"${RUN[INSTANCE]:--}"$'\trunning\t-\t-')
  done
  if [ -s "$base/runs.idx" ]; then
    mapfile -t fin < <(tail -n "$DASH_RUNS_MAX" "$base/runs.idx")
    for ((i = ${#fin[@]} - 1; i >= 0; i--)); do [ -z "${fin[$i]}" ] || lines+=("${fin[$i]}"); done
  fi
  DASH_RUNS_LINES=("${lines[@]+"${lines[@]}"}")
  # The selection follows the run, not the row: new runs at the top do not move it.
  sel="$DASH_RUNS_SEL"
  if [ -n "$DASH_RUNS_SEL_ID" ]; then
    for i in "${!DASH_RUNS_LINES[@]}"; do
      if [ "${DASH_RUNS_LINES[$i]%%$'\t'*}" = "$DASH_RUNS_SEL_ID" ]; then sel="$i"; break; fi
    done
  fi
  [ "$sel" -lt "${#DASH_RUNS_LINES[@]}" ] || sel=$((${#DASH_RUNS_LINES[@]} - 1))
  [ "$sel" -ge 0 ] || sel=0
  DASH_RUNS_SEL="$sel"
  id="${DASH_RUNS_LINES[$sel]:-}"
  DASH_RUNS_SEL_ID="${id%%$'\t'*}"
  f="${DASH_RUNS_LINES[*]-}"
  # A run in progress keeps writing: its detail (end of the output, figures) is built again at every load.
  if [ "$f" != "$DASH_RUNS_SIG" ] || [[ "$f" == *$'\trunning\t'* ]]; then
    DASH_RUNS_SIG="$f"
    DASH_RUNS_N=$((DASH_RUNS_N + 1))
    DASH_RUNS_STATS_FOR=""
    DASH_DIRTY=1
  fi
  [ "$DASH_RUNS_MODE" != "stats" ] || dash_runs_stats_load
}

dash_runs_stats_load() {
  local key="$DASH_RUNS_N|$DASH_RUNS_STATS_INST"
  [ "$key" != "$DASH_RUNS_STATS_FOR" ] || return 0
  DASH_RUNS_STATS_FOR="$key"
  if runs_stats_collect "$DASH_RUNS_STATS_INST" 100; then DASH_RUNS_STATS_OK=1; else DASH_RUNS_STATS_OK=0; fi
  DASH_DIRTY=1
}

# Called every loop. The data is only read while the view is on screen; leaving it forgets the clock so that coming back reads again.
dash_runs_tick() {
  if [ "$DASH_VIEW" != "runs" ]; then DASH_RUNS_AT=-1000; DASH_RUNS_MODE=list; fi
  [ "$DASH_RUNS_MODE" = "log" ] || [ -z "$DASH_RV_ID" ] || dash_runs_log_close   # (a viewer that is not shown holds nothing)
  [ "$DASH_VIEW" = "runs" ] || return 0
  if [ "$DASH_RUNS_AT" -lt 0 ] || { [ "$DASH_PAUSED" -eq 0 ] && [ $((SECONDS - DASH_RUNS_AT)) -ge 5 ]; }; then dash_runs_load; fi
}

# Fields of the line $1 of the index into RN_ID RN_WHEN RN_OP RN_INS RN_ST RN_RC RN_MS (cleaned).
dash_runs_fields() { # index
  IFS=$'\t' read -r RN_ID RN_WHEN RN_OP RN_INS RN_ST RN_RC RN_MS <<< "${DASH_RUNS_LINES[$1]:-}"
  dash_runs_clean RN_ID; dash_runs_clean RN_WHEN; dash_runs_clean RN_OP; dash_runs_clean RN_INS; dash_runs_clean RN_ST; dash_runs_clean RN_RC
}
RN_ID="" RN_WHEN="" RN_OP="" RN_INS="" RN_ST="" RN_RC="" RN_MS=""

# The glyph of a state into DASH_RUNS_SYM.
dash_runs_sym() { # state
  case "$1" in
    succeeded) DASH_RUNS_SYM="${DASH_SYM[ok]}" ;;
    failed) DASH_RUNS_SYM="${DASH_SYM[err]}" ;;
    running) DASH_RUNS_SYM="${DASH_SYM[info]}" ;;
    *) DASH_RUNS_SYM="${DASH_SYM[warn]}" ;;
  esac
}
DASH_RUNS_SYM=""

# --- List -------------------------------------------------------------------------------------------------------------------

dash_runs_list_lines() { # inner_height inner_width
  local h="$1" iw="$2" n="${#DASH_RUNS_LINES[@]}" i start=0 avail nw when dur ins acc
  DASH_RUNS_LIST_L=()
  [ "$n" -gt 0 ] || return 0
  acc="${TH[accent]:-$C_CYN}"
  # marker(1) + sp + glyph(1) + sp + date(11) + sp + command(8) + sp + instance + sp + duration(8)
  nw=$((iw - 34))
  [ "$nw" -ge 3 ] || nw=3
  avail="$h"
  [ "$avail" -ge 1 ] || avail=1
  [ "$DASH_RUNS_SEL" -lt "$avail" ] || start=$((DASH_RUNS_SEL - avail + 1))
  for ((i = start; i < n && i < start + avail; i++)); do
    dash_runs_fields "$i"
    dash_runs_sym "$RN_ST"
    when="${RN_WHEN:5:5} ${RN_WHEN:11:5}"
    if [ "$RN_ST" = "running" ]; then dt runs.state.running; dur="$DTV"; else runs_fmt_ms "$RN_MS"; dur="$RUNS_F"; fi
    printf -v ins '%-*s' "$nw" "${RN_INS:0:$nw}"
    printf -v when '%-11s %-8s %s %8s' "$when" "${RN_OP:0:8}" "$ins" "$dur"
    if [ "$i" -eq "$DASH_RUNS_SEL" ]; then DASH_RUNS_LIST_L+=("$TUI_SEL$acc$UI_S_SEL$C_OFF $DASH_RUNS_SYM $when")
    else DASH_RUNS_LIST_L+=("  $DASH_RUNS_SYM $when"); fi
  done
}

# --- Detail ---------------------------------------------------------------------------------------------------------------

dash_runs_kv() { # label value
  dash_runs_padr "$1" 14
  DASH_RUNS_DET+=(" $C_GRY$DASH_PAD$C_OFF $2")
}
dash_runs_head() { # text
  [ "${#DASH_RUNS_DET[@]}" -eq 0 ] || DASH_RUNS_DET+=("")
  DASH_RUNS_DET+=(" ${TH[accent]:-$C_CYN}$C_BLD$1$C_OFF")
}

# A change as text into DASH_RUNS_CELL, coloured by how much it costs more or less: "+12%".
dash_runs_dcell() { # old new width
  local d col="$C_GRY"
  runs_delta "$1" "$2"
  d="${RUNS_D%\%}"; d="${d#+}"
  if [[ "$d" =~ ^-?[0-9]+$ ]]; then
    if [ "$d" -ge 25 ]; then col="$C_RED"; elif [ "$d" -ge 10 ]; then col="$C_YEL"; elif [ "$d" -le -10 ]; then col="$C_GRN"; fi
  fi
  printf -v DASH_RUNS_CELL '%*s' "$3" "$RUNS_D"
  DASH_RUNS_CELL="$col$DASH_RUNS_CELL$C_OFF"
}
DASH_RUNS_CELL=""

# How the run compares with the earlier successful ones of the same command on the same instance (the previous one and the average
# of up to the five before it). RUN is replaced by what it reads. $1 is the row of the run in the list.
dash_runs_compare() { # index
  local i m id n=0 now pc ac op ins head
  local -a cur=("${RUN[DURATION_MS]:-}" "${RUN[CPU_MS]:-}" "${RUN[DOCKER_MS]:-}" "${RUN[PEAK_RSS_KB]:-}")
  local -a fmt=(runs_fmt_ms runs_fmt_ms runs_fmt_ms runs_fmt_kb)
  local -a lab=(runs.kv.duration runs.kv.cpu runs.kv.docker runs.kv.mem)
  local -a first=("" "" "" "") sum=(0 0 0 0) cnt=(0 0 0 0) val=()
  local -a ids=()
  op="${RUN[OP]}" ins="${RUN[INSTANCE]}"
  [ "${RUN[STATE]}" = "succeeded" ] && [[ "${cur[1]}" =~ ^[0-9]+$ ]] || return 0   # (no CPU figure: recorded before measuring)
  for ((i = $1 + 1; i < ${#DASH_RUNS_LINES[@]} && ${#ids[@]} < 5; i++)); do
    dash_runs_fields "$i"
    if [ "$RN_OP" = "$op" ] && [ "$RN_INS" = "$ins" ] && [ "$RN_ST" = "succeeded" ]; then ids+=("$RN_ID"); fi
  done
  dtf tui.runs.cmp_title "$op" "$ins"; head="$DTF"
  for id in "${ids[@]+"${ids[@]}"}"; do
    runs_meta_read "$INSTANCES_DIR/.deltactl/runs/$id" || continue
    [[ "${RUN[CPU_MS]:-}" =~ ^[0-9]+$ ]] || continue
    val=("${RUN[DURATION_MS]:-}" "${RUN[CPU_MS]:-}" "${RUN[DOCKER_MS]:-}" "${RUN[PEAK_RSS_KB]:-}")
    n=$((n + 1))
    for m in 0 1 2 3; do
      [[ "${val[$m]}" =~ ^[0-9]+$ ]] || continue
      [ -n "${first[$m]}" ] || first[$m]="${val[$m]}"
      sum[$m]=$((${sum[$m]} + ${val[$m]})) cnt[$m]=$((${cnt[$m]} + 1))
    done
  done
  dash_runs_head "$head"
  if [ "$n" -eq 0 ]; then
    dt tui.runs.nocmp
    DASH_RUNS_DET+=(" $C_GRY$DTV$C_OFF")
    return 0
  fi
  dt tui.runs.now; now="$DTV"
  dt tui.runs.vs_prev; pc="$DTV"
  dtf tui.runs.vs_avg "$n"; ac="$DTF"
  printf -v head '%-14s %9s %9s %11s' '' "$now" "$pc" "$ac"
  DASH_RUNS_DET+=(" $C_GRY$head$C_OFF")
  for m in 0 1 2 3; do
    [[ "${cur[$m]}" =~ ^[0-9]+$ ]] && [ "${cnt[$m]}" -gt 0 ] || continue
    dt "${lab[$m]}"
    "${fmt[$m]}" "${cur[$m]}"
    printf -v now '%9s' "$RUNS_F"
    dash_runs_padr "$DTV" 14; head="$DASH_PAD"
    dash_runs_dcell "${first[$m]}" "${cur[$m]}" 9; pc="$DASH_RUNS_CELL"
    if [ "${cnt[$m]}" -ge 2 ]; then
      dash_runs_dcell $((${sum[$m]} / ${cnt[$m]})) "${cur[$m]}" 11; ac="$DASH_RUNS_CELL"
    else
      printf -v ac '%11s' "-"
    fi
    DASH_RUNS_DET+=(" $C_GRY$head$C_OFF $now $pc $ac")
  done
}

# Consumption and containers (RUN is the run). Runs recorded before the measurements existed have no CPU figure and show nothing.
dash_runs_consumption() {
  local ms="${RUN[DURATION_MS]:-}" cpu="${RUN[CPU_MS]:-}" dms pct slow a b run tot mem rst
  [[ "$cpu" =~ ^[0-9]+$ ]] || return 0
  dt runs.cons_title; dash_runs_head "$DTV"
  pct="-"
  [[ "$ms" =~ ^[0-9]+$ ]] && [ "$ms" -gt 0 ] && pct=$((cpu * 100 / ms))
  runs_fmt_ms "$cpu"; dtf runs.cpu_fmt "$RUNS_F" "$pct"; dt runs.kv.cpu; dash_runs_kv "$DTV" "$DTF"
  dms="${RUN[DOCKER_MS]:-0}" pct="-"
  [[ "$dms" =~ ^[0-9]+$ ]] || dms=0
  [[ "$ms" =~ ^[0-9]+$ ]] && [ "$ms" -gt 0 ] && pct=$((dms * 100 / ms))
  runs_fmt_ms "$dms"; dtf tui.runs.docker_fmt "${RUN[DOCKER_CALLS]:-0}" "$RUNS_F" "$pct"; dt runs.kv.docker; dash_runs_kv "$DTV" "$DTF"
  slow="${RUN[DOCKER_SLOW]:-}"
  if [ -n "$slow" ] && [ "${slow%%|*}" -gt 0 ] 2> /dev/null; then
    runs_fmt_ms "${slow%%|*}"; dt runs.kv.slowest; dash_runs_kv "$DTV" "$RUNS_F $UI_S_DOT ${slow#*|}"
  fi
  if [ -n "${RUN[PEAK_RSS_KB]:-}" ]; then
    runs_fmt_kb "${RUN[PEAK_RSS_KB]}"; dtf tui.runs.mem_fmt "$RUNS_F" "${RUN[PEAK_PROCS]:-0}"; dt runs.kv.mem; dash_runs_kv "$DTV" "$DTF"
  fi
  runs_fmt_bytes "${RUN[OUT_BYTES]:-0}"; dtf runs.out_fmt "${RUN[OUT_LINES]:-0}" "$RUNS_F"; dt runs.kv.out; dash_runs_kv "$DTV" "$DTF"
  if [ -n "${RUN[FOOT_BEFORE]:-}" ] || [ -n "${RUN[FOOT_AFTER]:-}" ]; then
    dtf runs.foot_title "${RUN[INSTANCE]}"; dash_runs_head "$DTF"
    for a in before after; do
      if [ "$a" = before ]; then b="${RUN[FOOT_BEFORE]:-}"; else b="${RUN[FOOT_AFTER]:-}"; fi
      [ -n "$b" ] || continue
      read -r run mem rst <<< "$b"
      tot="${run#*/}" run="${run%/*}"
      runs_fmt_bytes "$mem"; dtf tui.runs.foot_fmt "$run" "$tot" "$RUNS_F" "${rst:-0}"; dt "runs.kv.$a"; dash_runs_kv "$DTV" "$DTF"
    done
  fi
}

# Builds DASH_RUNS_DET for the selected run (once per selection and per change of the data or the language).
dash_runs_detail() {
  local dir id i st sym line s rc k
  local -a tail_lines=()
  [ "${#DASH_RUNS_LINES[@]}" -gt 0 ] || { DASH_RUNS_DET=() DASH_RUNS_DET_KEY=""; return 0; }
  dash_runs_fields "$DASH_RUNS_SEL"
  id="$RN_ID" st="$RN_ST"
  line="$id|$st|$DASH_RUNS_N|$DASH_LANG_N"
  [ "$line" != "$DASH_RUNS_DET_KEY" ] || return 1   # unchanged: the lines already there are valid
  DASH_RUNS_DET_KEY="$line"
  DASH_RUNS_DET=()
  i="$DASH_RUNS_SEL"
  dir="$INSTANCES_DIR/.deltactl/runs/$id"
  if ! runs_meta_read "$dir"; then
    dt tui.runs.gone; DASH_RUNS_DET=(" $C_GRY$DTV$C_OFF")
    return 0
  fi
  # Whatever the file says is data: it is cleaned before it is drawn, and the keys a truncated file lacks get a value.
  for k in "${!RUN[@]}"; do s="${RUN[$k]}"; dash_runs_clean s; RUN[$k]="$s"; done
  : "${RUN[OP]:=?}" "${RUN[INSTANCE]:=-}" "${RUN[STATE]:=interrupted}" "${RUN[STARTED_AT]:=-}"
  dt runs.kv.command; dash_runs_kv "$DTV" "$C_BLD./deltactl ${RUN[OP]}${RUN[ARGS]:+ ${RUN[ARGS]}}$C_OFF"
  # (the instance is in the title of the box)
  dash_runs_sym "${RUN[STATE]}"; sym="$DASH_RUNS_SYM"
  dt "runs.state.${RUN[STATE]}"; s="$DTV"
  rc="${RUN[RC]:-}"
  if [ -n "$rc" ]; then dtf tui.runs.exit "$rc"; s+=" $UI_S_DOT $DTF"; fi
  dt runs.kv.state; dash_runs_kv "$DTV" "$sym $s"
  dt runs.kv.started; dash_runs_kv "$DTV" "${RUN[STARTED_AT]/T/ }"
  if [ -n "${RUN[ENDED_AT]:-}" ]; then dt runs.kv.ended; dash_runs_kv "$DTV" "${RUN[ENDED_AT]/T/ }"; fi
  runs_fmt_ms "${RUN[DURATION_MS]:-}"; dt runs.kv.duration; dash_runs_kv "$DTV" "$RUNS_F"
  dt runs.kv.who; dash_runs_kv "$DTV" "${RUN[USER]:--}@${RUN[HOST]:--}"
  # What matters most goes first (how it compares with the earlier runs), then the figures behind it. The comparison reads other
  # runs into RUN, so the run being shown is put back before its consumption is written.
  local -A mine=()
  for k in "${!RUN[@]}"; do mine[$k]="${RUN[$k]}"; done
  dash_runs_compare "$i"
  RUN=()
  for k in "${!mine[@]}"; do RUN[$k]="${mine[$k]}"; done
  dash_runs_consumption
  # The end of the output.
  if [ -s "$dir/out.log" ]; then
    mapfile -t tail_lines < <(tail -n 8 "$dir/out.log")
    dtf tui.runs.out_tail "${#tail_lines[@]}"; dash_runs_head "$DTF"
    for line in "${tail_lines[@]}"; do
      dash_runs_logline "$line"
      DASH_RUNS_DET+=(" $TUI_OUT$C_OFF")
    done
  fi
  return 0
}

# --- Statistics -------------------------------------------------------------------------------------------------------------

dash_runs_stats_lines() { # inner_width
  local iw=$(($1 - 1)) op f bad cols=0 head
  DASH_RUNS_STATS_L=()
  if [ "$DASH_RUNS_STATS_OK" -eq 0 ] || [ "${#RS_OPS[@]}" -eq 0 ]; then
    dt runs.none; DASH_RUNS_STATS_L=(" $C_GRY$DTV$C_OFF")
    return 0
  fi
  # The columns that do not fit are dropped from the right: peak memory first, then the Docker time.
  [ "$iw" -lt 59 ] || cols=1
  [ "$iw" -lt 69 ] || cols=2
  dt tui.runs.c.op; dash_runs_padr "$DTV" 12; head="$DASH_PAD"
  dt tui.runs.c.n; dash_runs_padl "$DTV" 6; head+="$DASH_PAD"
  dt tui.runs.c.ok; dash_runs_padl "$DTV" 5; head+="$DASH_PAD"
  dt tui.runs.c.bad; dash_runs_padl "$DTV" 7; head+="$DASH_PAD"
  dt tui.runs.c.dur; dash_runs_padl "$DTV" 10; head+="$DASH_PAD"
  dt tui.runs.c.cpu; dash_runs_padl "$DTV" 10; head+="$DASH_PAD"
  if [ "$cols" -ge 1 ]; then dt tui.runs.c.docker; dash_runs_padl "$DTV" 10; head+="$DASH_PAD"; fi
  if [ "$cols" -ge 2 ]; then dt tui.runs.c.mem; dash_runs_padl "$DTV" 10; head+="$DASH_PAD"; fi
  DASH_RUNS_STATS_L+=(" $C_GRY$head$C_OFF")
  for op in "${RS_OPS[@]}"; do
    runs_stats_cells "$op"
    bad="${RS_BAD[$op]:-0}"
    f="$op"; dash_runs_clean f
    dash_runs_padr "$f" 12; head="$DASH_PAD"
    printf -v f ' %5s %4s' "${RS_CNT[$op]}" "${RS_OK[$op]:-0}"
    head="$C_BLD$head$C_OFF$f"
    printf -v f ' %6s' "$bad"
    if [ "$bad" -gt 0 ]; then head+=" $C_RED${f# }$C_OFF"; else head+="$f"; fi
    printf -v f ' %9s %9s' "$RS_C_DUR" "$RS_C_CPU"; head+="$f"
    if [ "$cols" -ge 1 ]; then printf -v f ' %9s' "$RS_C_DK"; head+="$f"; fi
    if [ "$cols" -ge 2 ]; then printf -v f ' %9s' "$RS_C_PEAK"; head+="$f"; fi
    DASH_RUNS_STATS_L+=(" $head")
  done
  dt runs.cons_note
  dash_wrap "$DTV" "$iw"
  DASH_RUNS_STATS_L+=("")
  for f in "${DASH_WRAP[@]}"; do DASH_RUNS_STATS_L+=(" $C_GRY$f$C_OFF"); done
}

# --- Keys -------------------------------------------------------------------------------------------------------------------

dash_runs_select() { # row
  local n="${#DASH_RUNS_LINES[@]}"
  [ "$n" -gt 0 ] || return 0
  [ "$1" -ge 0 ] || set -- 0
  [ "$1" -lt "$n" ] || set -- $((n - 1))
  DASH_RUNS_SEL="$1" DASH_RUNS_SEL_ID="${DASH_RUNS_LINES[$1]%%$'\t'*}" DASH_RUNS_OFF=0
}

dash_key_runs() {
  local page=$((TUI_ROWS / 2))
  if [ "$DASH_RUNS_MODE" = "log" ]; then dash_key_runs_log "$1"; return 0; fi
  if [ "$DASH_RUNS_MODE" = "stats" ]; then
    case "$1" in
      t) DASH_RUNS_MODE=list ;;
      s)
        if [ -n "$DASH_RUNS_STATS_INST" ]; then DASH_RUNS_STATS_INST=""
        elif [ "${#DASH_RUNS_LINES[@]}" -gt 0 ]; then dash_runs_fields "$DASH_RUNS_SEL"; [ "$RN_INS" = "-" ] || DASH_RUNS_STATS_INST="$RN_INS"; fi
        dash_runs_stats_load
        ;;
    esac
    return 0
  fi
  case "$1" in
    up | k) dash_runs_select $((DASH_RUNS_SEL - 1)) ;;
    down | j) dash_runs_select $((DASH_RUNS_SEL + 1)) ;;
    home | g) dash_runs_select 0 ;;
    end | G) dash_runs_select 100000 ;;
    pgup) DASH_RUNS_OFF=$((DASH_RUNS_OFF - page)); [ "$DASH_RUNS_OFF" -ge 0 ] || DASH_RUNS_OFF=0 ;;
    pgdn) DASH_RUNS_OFF=$((DASH_RUNS_OFF + page)) ;;   # clamped to the last line when drawn
    t) DASH_RUNS_MODE=stats; dash_runs_stats_load ;;
    enter | l) [ -z "$DASH_RUNS_SEL_ID" ] || dash_runs_log_open "$DASH_RUNS_SEL_ID" ;;
  esac
}

# --- Drawing ----------------------------------------------------------------------------------------------------------------

dash_runs_stats_box() { # width height
  local title
  dtf runs.stats_title "$RS_N"; title="$DTF"
  if [ -n "$DASH_RUNS_STATS_INST" ]; then dtf tui.runs.scope "$DASH_RUNS_STATS_INST"; title+=" $UI_S_DOT $DTF"; fi
  dash_runs_stats_lines $(($1 - 3))
  tui_box "$title" "$1" "$2" DASH_RUNS_STATS_L "" 1
}

dash_runs_detail_box() { # width height
  local w="$1" h="$2" inner total off title
  local -a shown=()
  inner=$((h - 2))
  dash_runs_detail || true
  total="${#DASH_RUNS_DET[@]}"
  off="$DASH_RUNS_OFF"
  [ "$off" -le $((total - inner)) ] || off=$((total - inner))
  [ "$off" -ge 0 ] || off=0
  DASH_RUNS_OFF="$off"
  shown=("${DASH_RUNS_DET[@]:$off:$inner}")
  dash_runs_fields "$DASH_RUNS_SEL"
  title="$RN_OP $UI_S_DOT $RN_INS"
  if [ "$off" -gt 0 ]; then dt tui.out.scrolled; title+=" $UI_S_DOT $DTV +$off"; fi
  tui_box "$title" "$w" "$h" shown "" 0
}

dash_view_runs() { # body_height
  local bh="$1" lw lh dh title l
  if [ "$DASH_RUNS_MODE" = "log" ]; then
    dash_runs_log_box "$TUI_COLS" "$bh"
    TUI_FRAME+=("${TUI_BOX[@]}")
    return 0
  fi
  if [ "$DASH_RUNS_MODE" = "stats" ]; then
    dash_runs_stats_box "$TUI_COLS" "$bh"
    TUI_FRAME+=("${TUI_BOX[@]}")
    return 0
  fi
  dt tui.runs.title; title="$DTV"
  if [ "${#DASH_RUNS_LINES[@]}" -eq 0 ]; then
    local -a msg=()
    dt tui.runs.empty
    dash_wrap "$DTV" $((TUI_COLS - 6))
    for l in "${DASH_WRAP[@]}"; do msg+=(" $C_GRY$l$C_OFF"); done
    tui_box "$title" "$TUI_COLS" "$bh" msg "" 1
    TUI_FRAME+=("${TUI_BOX[@]}")
    return 0
  fi
  if [ "$TUI_COLS" -ge 100 ]; then
    lw=46; [ "$TUI_COLS" -lt 130 ] || lw=54
    dash_runs_list_lines $((bh - 2)) $((lw - 3))
    tui_box "$title" "$lw" "$bh" DASH_RUNS_LIST_L "" 1; DASH_L=("${TUI_BOX[@]}")
    dash_runs_detail_box $((TUI_COLS - lw)) "$bh"; DASH_R=("${TUI_BOX[@]}")
    dash_join DASH_L DASH_R
  else
    lh=$((${#DASH_RUNS_LINES[@]} + 2))
    [ "$lh" -le $((bh * 2 / 5)) ] || lh=$((bh * 2 / 5))
    [ "$lh" -ge 5 ] || lh=5
    dh=$((bh - lh))
    dash_runs_list_lines $((lh - 2)) $((TUI_COLS - 3))
    tui_box "$title" "$TUI_COLS" "$lh" DASH_RUNS_LIST_L "" 1
    TUI_FRAME+=("${TUI_BOX[@]}")
    dash_runs_detail_box "$TUI_COLS" "$dh"
    TUI_FRAME+=("${TUI_BOX[@]}")
  fi
}

# --- Saved output viewer (Enter on a run) ---------------------------------------------------------------------------------------
# A log can be of any size, so it is never loaded: one pass (awk, in the background when the file is big) writes the byte offset of
# every 500th line, and a page is read from the closest checkpoint with `tail -c +offset | sed`. What stays in memory is the offsets
# (1/500 of the number of lines) and the page on screen. Until the pass is over the viewer shows the end of the file.

DASH_RV_ID="" DASH_RV_FILE="" DASH_RV_TOTAL=-1 DASH_RV_TOP=0 DASH_RV_END=1
DASH_RV_EVERY=500 DASH_RV_SYNC_MAX=8388608
DASH_RV_CK=() DASH_RV_PAGE=() DASH_RV_PAGE_KEY="" DASH_RV_FIRST=0

# Offsets of the lines 1, 501, 1001... and, at the end, "L<number of lines>". Bytes, not characters: LC_ALL=C.
dash_runs_log_scan() { # file
  LC_ALL=C awk -v n="$DASH_RV_EVERY" 'BEGIN { off = 0 } (NR - 1) % n == 0 { print off } { off += length($0) + 1 } END { print "L" NR }' "$1"
}

# Takes the result of the pass (it can arrive after the user left: then it is of no use).
dash_runs_log_index() { # run_id text
  local -a a=()
  local n last
  [ "$DASH_RV_ID" = "$1" ] || return 0
  mapfile -t a <<< "$2"
  n="${#a[@]}"
  [ "$n" -gt 0 ] || return 0
  last="${a[$((n - 1))]}"
  [[ "$last" == L[0-9]* ]] || return 0
  DASH_RV_TOTAL="${last#L}"
  unset "a[$((n - 1))]"
  DASH_RV_CK=("${a[@]+"${a[@]}"}")
  DASH_RV_PAGE_KEY=""
  DASH_DIRTY=1
}

dash_runs_log_open() { # run_id
  local f="$INSTANCES_DIR/.deltactl/runs/$1/out.log" size txt
  if [ ! -s "$f" ]; then dash_msg warn "$(t tui.runs.no_output)"; return 1; fi
  DASH_RV_ID="$1" DASH_RV_FILE="$f" DASH_RV_TOTAL=-1 DASH_RV_TOP=0 DASH_RV_END=1 DASH_RV_CK=() DASH_RV_PAGE=() DASH_RV_PAGE_KEY=""
  DASH_RUNS_MODE=log
  size="$(stat -c %s "$f" 2> /dev/null || true)"
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  if tui_test_mode || [ "$size" -le "$DASH_RV_SYNC_MAX" ]; then
    txt="$(dash_runs_log_scan "$f")"
    dash_runs_log_index "$1" "$txt"
  else
    dash_runs_log_cancel_scan
    dash_async rvidx "$1" dash_runs_log_scan "$f" || true
  fi
  return 0
}

# Stops the pass over a log that nobody is waiting for any more: the subshell and the awk below it, and the files they leave.
dash_runs_log_cancel_scan() {
  local pid="${DASH_AS_PID[rvidx]:-}" f="${DASH_AS_FILE[rvidx]:-}"
  [ -n "$pid" ] || return 0
  pkill -P "$pid" 2> /dev/null || true
  kill "$pid" 2> /dev/null || true
  [ -z "$f" ] || rm -f "$f" "$f.tmp"
  DASH_AS_PID[rvidx]=""
}

# What is held for a viewer that is no longer shown goes away.
dash_runs_log_close() {
  dash_runs_log_cancel_scan
  DASH_RV_ID="" DASH_RV_FILE="" DASH_RV_TOTAL=-1 DASH_RV_CK=() DASH_RV_PAGE=() DASH_RV_PAGE_KEY=""
}

# $2 lines starting at line $1 (0-based) into DASH_RV_PAGE.
dash_runs_log_fetch() { # top count
  local top="$1" count="$2" ck skip off
  ck=$((top / DASH_RV_EVERY)) skip=$((top % DASH_RV_EVERY))
  off="${DASH_RV_CK[$ck]:-0}"
  mapfile -t DASH_RV_PAGE < <(tail -c +$((off + 1)) "$DASH_RV_FILE" | sed -n "$((skip + 1)),$((skip + count))p;$((skip + count))q")
}

dash_runs_log_box() { # width height
  local w="$1" h="$2" inner total="$DASH_RV_TOTAL" top max i line n gw key title="" shown last
  inner=$((h - 2))
  local -a body=()
  if [ "$total" -lt 0 ]; then
    key="tail|$inner|$DASH_RV_ID"
    if [ "$key" != "$DASH_RV_PAGE_KEY" ]; then
      mapfile -t DASH_RV_PAGE < <(tail -n "$inner" "$DASH_RV_FILE")
      DASH_RV_PAGE_KEY="$key"
    fi
    DASH_RV_FIRST=-1
    dt tui.runs.indexing; title="$DTV"
  else
    max=$((total - inner))
    [ "$max" -ge 0 ] || max=0
    top="$DASH_RV_TOP"
    if [ "$DASH_RV_END" -eq 1 ] || [ "$top" -gt "$max" ]; then top="$max"; fi
    [ "$top" -ge 0 ] || top=0
    DASH_RV_TOP="$top"
    key="$top|$inner|$total|$DASH_RV_ID"
    if [ "$key" != "$DASH_RV_PAGE_KEY" ]; then
      dash_runs_log_fetch "$top" "$inner"
      DASH_RV_PAGE_KEY="$key"
    fi
    DASH_RV_FIRST="$top"
    shown="${#DASH_RV_PAGE[@]}"
    last=$((top + shown))
    dtf tui.runs.log_lines $((top + 1)) "$last" "$total"; title="$DTF"
  fi
  gw="${#total}"; [ "$gw" -ge 3 ] || gw=3
  n="${#DASH_RV_PAGE[@]}"
  for ((i = 0; i < n; i++)); do
    line="${DASH_RV_PAGE[$i]}"
    dash_runs_logline "$line"
    if [ "$DASH_RV_FIRST" -ge 0 ]; then
      printf -v key '%*d' "$gw" $((DASH_RV_FIRST + i + 1))
      body+=("$C_GRY$key$C_OFF $TUI_OUT$C_OFF")
    else
      body+=("$TUI_OUT$C_OFF")
    fi
  done
  dtf tui.runs.log_title "$DASH_RV_ID"
  tui_box "$DTF $UI_S_DOT $title" "$w" "$h" body "" 1
}

dash_key_runs_log() { # key
  local inner page max top total="$DASH_RV_TOTAL"
  inner=$((TUI_ROWS - 6))
  [ "$total" -ge 0 ] || return 0   # still indexing
  page=$((inner - 1)); [ "$page" -ge 1 ] || page=1
  max=$((total - inner)); [ "$max" -ge 0 ] || max=0
  top="$DASH_RV_TOP"
  [ "$DASH_RV_END" -eq 0 ] || top="$max"
  case "$1" in
    up | k) top=$((top - 1)) ;;
    down | j) top=$((top + 1)) ;;
    pgup) top=$((top - page)) ;;
    pgdn) top=$((top + page)) ;;
    home | g) top=0 ;;
    end | G) top="$max" ;;
    *) return 0 ;;
  esac
  [ "$top" -ge 0 ] || top=0
  if [ "$top" -ge "$max" ]; then top="$max" DASH_RV_END=1; else DASH_RV_END=0; fi
  DASH_RV_TOP="$top"
}

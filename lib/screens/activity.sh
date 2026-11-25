#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_ACT_* variables are this view's; DASH_*, JOB_*, RUN... belong to lib/cmd/dashboard*.sh and the other screens
# Screen: Activity (view 10, key 0). Everything that was run, in one place: a list of operations on one side (the last command of this panel
# first, then the ones that are going on in any terminal, then the recent ones of every instance) and, for the selected one, a pane with four
# tabs: Resumen (what it was, how it ended, the summary of what it printed), Salida (the whole output, scrollable), Consumo (what it cost,
# how it compares with the earlier ones, and with `t` what each kind of operation costs on average) and Procesos (the tree of processes of
# the command and what the panel itself costs).
#
# It ABSORBS the views Output (3), Runs (4) and Processes (5): it is made of their own builders (dash_out_box, the log viewer and the
# statistics of lib/screens/runs.sh, dash_procs_tree_box of lib/screens/procs.sh) and does everything they do. They stay registered (the
# keys 3, 4 and 5, `goto output|runs|procs`) until the final numbering of the views; the first time one of them is chosen the panel says that
# this is where they live now. The data is read by the Runs view's tick (dash_runs_tick) while this view is on screen, and the processes by
# the Processes one (dash_procs_tick): this file only asks them to.
#
# Keys. The list is chosen with up/down (k j) and g/G (first, last). The pane is moved with PgUp PgDn Home End (and f: follow the end). The
# tabs are chosen with left/right or < >. Enter or l go to the output. t: the statistics (s: one instance or all). v and e: summary or raw
# text, errors only (the output of the command of this panel). Esc steps back: the statistics, the tab, the view.
#
# Cost: the detail of an operation is built once per selection, size and change of the data (it reads a few small files), not once per
# frame; the saved output is never loaded (the viewer of the Runs view reads a page at a time).

DASH_ACT_TABS=(resumen salida consumo procesos)
DASH_ACT_TAB=resumen            # the tab on screen
DASH_ACT_ON_JOB=0               # the row with the cursor is the last command of this panel (otherwise a recorded run: DASH_RUNS_SEL)
DASH_ACT_STATS=0                # Consumo shows the statistics of the kinds of operation (t)
DASH_ACT_OFF=0                  # scroll of the detail tabs
DASH_ACT_N=0                    # bumps when the selection or the tab changes, for the signature
DASH_ACT_NROWS=0 DASH_ACT_JOB=0 DASH_ACT_CUR=0
DASH_ACT_LIST_L=() DASH_ACT_RES=() DASH_ACT_CON=() DASH_ACT_DET_KEY=""
DASH_ACT_PANE_H=10              # inner height of the pane box, for the pages of the viewer
DASH_ACT_NOTED=0                # the notice that the old views moved here was shown
# Where things are on screen, for the mouse (columns and rows start at 1): the list box, its first row, how many rows it shows and the first
# one; the strip of tabs of the pane, its row and column and the first column and width of each tab.
DASH_ACT_LX=0 DASH_ACT_LW=0 DASH_ACT_Y0=4 DASH_ACT_START=0 DASH_ACT_SHOWN=0 DASH_ACT_STRIP_Y=0 DASH_ACT_PX=0
DASH_ACT_TAB_COL=() DASH_ACT_TAB_WID=()
DASH_ACT_STRIPLINE=""

# --- Rows ------------------------------------------------------------------------------------------------------------------------

# How many rows the list has (DASH_ACT_NROWS) and whether the first one is the command of this panel (DASH_ACT_JOB).
dash_act_rows() {
  DASH_ACT_JOB=0
  [ -z "${JOB_PID:-}" ] || DASH_ACT_JOB=1
  DASH_ACT_NROWS=$((${#DASH_RUNS_LINES[@]} + DASH_ACT_JOB))
  if [ "$DASH_ACT_JOB" -eq 0 ]; then DASH_ACT_ON_JOB=0; fi
}

# The row that has the cursor, into DASH_ACT_CUR.
dash_act_cur() {
  if [ "$DASH_ACT_ON_JOB" -eq 1 ] && [ "$DASH_ACT_JOB" -eq 1 ]; then DASH_ACT_CUR=0; else DASH_ACT_CUR=$((DASH_ACT_JOB + DASH_RUNS_SEL)); fi
}

# Puts the cursor on a row (the selection of a recorded run follows the run, not the row: dash_runs_load).
dash_act_select() { # row
  local r="$1"
  dash_act_rows
  [ "$DASH_ACT_NROWS" -gt 0 ] || return 0
  [ "$r" -ge 0 ] || r=0
  [ "$r" -lt "$DASH_ACT_NROWS" ] || r=$((DASH_ACT_NROWS - 1))
  if [ "$DASH_ACT_JOB" -eq 1 ] && [ "$r" -eq 0 ]; then
    DASH_ACT_ON_JOB=1
  else
    DASH_ACT_ON_JOB=0
    dash_runs_select $((r - DASH_ACT_JOB))
  fi
  DASH_ACT_OFF=0 DASH_ACT_N=$((DASH_ACT_N + 1)) DASH_DIRTY=1
  dash_act_sync
}

# Is the command of this panel running, or did it end less than two minutes ago? Then it is what the person came to see.
dash_act_job_fresh() {
  [ -n "${JOB_PID:-}" ] || return 1
  job_running && return 0
  [ "${JOB_END_US:-0}" -gt 0 ] || return 1
  host_now_us
  [ $((HOST_NOW_US - JOB_END_US)) -lt 120000000 ]
}

# A command was just started from this view: the cursor goes to it (the first row) and the output tab shows it.
dash_act_follow_job() {
  DASH_ACT_ON_JOB=1 DASH_ACT_OFF=0 DASH_ACT_N=$((DASH_ACT_N + 1)) DASH_DIRTY=1
  dash_act_tab_go salida
}

dash_act_move() { # +1 | -1
  dash_act_rows; dash_act_cur
  dash_act_select $((DASH_ACT_CUR + $1))
}

# The state of the command of this panel into DASH_ACT_JS (running | ok | failed | cancelled) and DASH_RUNS_SYM.
DASH_ACT_JS=""
dash_act_job_state() {
  if job_running; then DASH_ACT_JS=running; DASH_RUNS_SYM="${DASH_SYM[info]}"
  elif [ "${JOB_CANCELLED:-0}" -eq 1 ]; then DASH_ACT_JS=cancelled; DASH_RUNS_SYM="${DASH_SYM[warn]}"
  elif [ "${JOB_RC:-0}" -eq 0 ]; then DASH_ACT_JS=ok; DASH_RUNS_SYM="${DASH_SYM[ok]}"
  else DASH_ACT_JS=failed; DASH_RUNS_SYM="${DASH_SYM[err]}"; fi
}

# The viewer of the saved output follows the selection: open for the recorded run on screen while the tab Salida is the one shown, closed
# otherwise (a viewer that is not shown holds nothing).
dash_act_sync() {
  local f
  if [ "$DASH_VIEW" = "activity" ] && [ "$DASH_ACT_TAB" = "salida" ] && [ "$DASH_ACT_ON_JOB" -eq 0 ] && [ -n "$DASH_RUNS_SEL_ID" ]; then
    if [ "$DASH_RV_ID" != "$DASH_RUNS_SEL_ID" ]; then
      dash_runs_log_close
      f="$INSTANCES_DIR/.deltactl/runs/$DASH_RUNS_SEL_ID/out.log"
      if [ -s "$f" ]; then
        dash_runs_log_open "$DASH_RUNS_SEL_ID"
        DASH_RUNS_MODE=list      # (the Runs view's mode: the viewer is this view's)
        DASH_DIRTY=1
      fi
    fi
  elif [ -n "$DASH_RV_ID" ]; then
    dash_runs_log_close
  fi
}

# --- The tabs --------------------------------------------------------------------------------------------------------------------

dash_act_tab_go() { # id
  [ "$DASH_ACT_TAB" != "$1" ] || return 0
  DASH_ACT_TAB="$1" DASH_ACT_OFF=0 DASH_ACT_STATS=0 DASH_ACT_N=$((DASH_ACT_N + 1)) DASH_DIRTY=1
  dash_act_sync
}

dash_act_tab_step() { # +1 | -1
  local i n="${#DASH_ACT_TABS[@]}" cur=0
  for i in "${!DASH_ACT_TABS[@]}"; do [ "${DASH_ACT_TABS[$i]}" != "$DASH_ACT_TAB" ] || cur="$i"; done
  dash_act_tab_go "${DASH_ACT_TABS[$(((cur + n + $1) % n))]}"
}

# The strip of tabs (one line, $1 cells) into DASH_ACT_STRIPLINE; the mouse learns where each tab is.
dash_act_strip() { # width
  local id i cur=1 labels=()
  DASH_ACT_TAB_COL=() DASH_ACT_TAB_WID=()
  i=0
  for id in "${DASH_ACT_TABS[@]}"; do
    i=$((i + 1))
    dt "tui.act.tab.$id"; labels+=("$DTV")
    [ "$id" != "$DASH_ACT_TAB" ] || cur="$i"
  done
  kit_tabs "$1" "$cur" "${labels[@]}"
  DASH_ACT_STRIPLINE="$KT_LINE"
  for i in "${!KT_COLS[@]}"; do DASH_ACT_TAB_COL[i]="${KT_COLS[$i]}" DASH_ACT_TAB_WID[i]="${KT_WID[$i]}"; done
}

# --- Detail: what the Resumen and the Consumo tabs say ---------------------------------------------------------------------------

dash_act_kv() { # array label value
  local -n _kvarr="$1"
  dash_runs_padr "$2" 14
  _kvarr+=(" $C_GRY$DASH_PAD$C_OFF $3")
}
# A gray note, wrapped to $3 cells, appended to the array $1.
dash_act_note() { # array text width
  local -n _ntarr="$1"
  local l
  dash_wrap "$2" "$3"
  for l in "${DASH_WRAP[@]}"; do _ntarr+=(" $C_GRY$l$C_OFF"); done
}
dash_act_head() { # array text
  local -n _hdarr="$1"
  [ "${#_hdarr[@]}" -eq 0 ] || _hdarr+=("")
  _hdarr+=(" ${TH[accent]:-$C_CYN}$C_BLD$2$C_OFF")
}

# The detail of the command of this panel, for a pane of $1 cells of text: DASH_ACT_RES and DASH_ACT_CON.
dash_act_job_detail() { # width
  local iw="$1" s line running=0 n i
  local -a tail_lines=()
  DASH_ACT_RES=() DASH_ACT_CON=()
  dash_act_job_state
  job_running && running=1
  dt runs.kv.command; dash_act_kv DASH_ACT_RES "$DTV" "$C_BLD./deltactl $JOB_TITLE$C_OFF"
  dt "tui.act.job.$DASH_ACT_JS"; s="$DTV"
  if [ "$DASH_ACT_JS" = failed ]; then dtf tui.runs.exit "${JOB_RC:-0}"; s+=" $UI_S_DOT $DTF"; fi
  dt runs.kv.state; dash_act_kv DASH_ACT_RES "$DTV" "$DASH_RUNS_SYM $s"
  dash_job_secs; dash_clock "$DASH_JS"
  dt runs.kv.duration; dash_act_kv DASH_ACT_RES "$DTV" "$DASH_CLK"
  dt tui.act.panel_note; dash_act_note DASH_ACT_RES "$DTV" $((iw - 1))
  n="${#JOB_LINES[@]}"
  if [ "$n" -gt 0 ]; then
    if outsum_for JOB_LINES "$JOB_TITLE" "$running" "${JOB_RC-}" $((iw - 1)) "act|$TH_NAME|$TH_MODE|$DASH_LANG_N|$iw|$UI_S_OK"; then
      dt tui.his.summary; dash_act_head DASH_ACT_RES "$DTV"
      for line in "${OUTSUM_LINES[@]}"; do DASH_ACT_RES+=(" $line"); done
    else
      for ((i = n > 8 ? n - 8 : 0; i < n; i++)); do tail_lines+=("${JOB_LINES[$i]}"); done
      dtf tui.runs.out_tail "${#tail_lines[@]}"; dash_act_head DASH_ACT_RES "$DTF"
      for line in "${tail_lines[@]}"; do
        dash_runs_logline "$line"
        DASH_ACT_RES+=(" $TUI_OUT$C_OFF")
      done
    fi
  fi
  # What it costs: the commands of the panel are not recorded, but while one runs what it is made of is known.
  if [ "$running" -eq 1 ] && [ "$DASH_PT_N" -gt 0 ]; then
    runs_fmt_kb "$DASH_PT_SUM"
    dt tui.act.live_cost; dash_act_head DASH_ACT_CON "$DTV"
    dtf tui.procs.card "$DASH_PT_N" "$RUNS_F"; DASH_ACT_CON+=(" $DTF")
  else
    dt tui.act.job_nousage; dash_act_note DASH_ACT_CON "$DTV" $((iw - 1))
  fi
}

# The detail of the recorded run in the line $1 of the index, for a pane of $2 cells: DASH_ACT_RES and DASH_ACT_CON. The builders of the
# Runs view append to DASH_RUNS_DET and read other runs into RUN: the run being shown is put back before its consumption is written.
dash_act_run_detail() { # index width
  local i="$1" iw="$2" id dir k s rc sym line cmd
  local -a tail_lines=()
  local -A mine=()
  DASH_ACT_RES=() DASH_ACT_CON=()
  dash_runs_fields "$i"
  id="$RN_ID"
  dir="$INSTANCES_DIR/.deltactl/runs/$id"
  if ! runs_meta_read "$dir"; then dt tui.runs.gone; DASH_ACT_RES=(" $C_GRY$DTV$C_OFF"); return 0; fi
  # Whatever the file says is data: it is cleaned before it is drawn, and the keys a truncated file lacks get a value.
  for k in "${!RUN[@]}"; do s="${RUN[$k]}"; dash_runs_clean s; RUN[$k]="$s"; done
  : "${RUN[OP]:=?}" "${RUN[INSTANCE]:=-}" "${RUN[STATE]:=interrupted}" "${RUN[STARTED_AT]:=-}"
  dt runs.kv.command; dash_act_kv DASH_ACT_RES "$DTV" "$C_BLD./deltactl ${RUN[OP]}${RUN[ARGS]:+ ${RUN[ARGS]}}$C_OFF"
  dash_runs_sym "${RUN[STATE]}"; sym="$DASH_RUNS_SYM"
  dt "runs.state.${RUN[STATE]}"; s="$DTV"
  rc="${RUN[RC]:-}"
  if [ -n "$rc" ]; then dtf tui.runs.exit "$rc"; s+=" $UI_S_DOT $DTF"; fi
  dt runs.kv.state; dash_act_kv DASH_ACT_RES "$DTV" "$sym $s"
  dt runs.kv.started; dash_act_kv DASH_ACT_RES "$DTV" "${RUN[STARTED_AT]/T/ }"
  if [ -n "${RUN[ENDED_AT]:-}" ]; then dt runs.kv.ended; dash_act_kv DASH_ACT_RES "$DTV" "${RUN[ENDED_AT]/T/ }"; fi
  runs_fmt_ms "${RUN[DURATION_MS]:-}"; dt runs.kv.duration; dash_act_kv DASH_ACT_RES "$DTV" "$RUNS_F"
  dt runs.kv.who; dash_act_kv DASH_ACT_RES "$DTV" "${RUN[USER]:--}@${RUN[HOST]:--}"
  if [ -f "$INSTANCES_DIR/.deltactl/pending/$id" ]; then
    dt tui.runs.review_pending; s="$DTV"
    dt runs.kv.review; dash_act_kv DASH_ACT_RES "$DTV" "$C_RED$s$C_OFF"
    dtf tui.runs.resolve_cmd "$id"; DASH_ACT_RES+=("   $C_GRY$DTF$C_OFF")
  elif [ -n "${RUN[RESOLVED_AT]:-}" ]; then
    dtf runs.review.done "${RUN[RESOLVED_AT]/T/ }"; s="$DTF"
    [ -z "${RUN[NOTE]:-}" ] || s+=" $UI_S_DOT ${RUN[NOTE]}"
    dt runs.kv.review; dash_act_kv DASH_ACT_RES "$DTV" "$s"
  fi
  case "${RUN[STATE]}" in canceled | interrupted) dt tui.runs.partial; DASH_ACT_RES+=(" $C_GRY$DTV$C_OFF") ;; esac
  # The comparison with the earlier runs of the same command and then the figures behind it: the Consumo tab.
  for k in "${!RUN[@]}"; do mine[$k]="${RUN[$k]}"; done
  DASH_RUNS_DET=()
  dash_runs_compare "$i"
  RUN=()
  for k in "${!mine[@]}"; do RUN[$k]="${mine[$k]}"; done
  DASH_ACT_CON+=("${DASH_RUNS_DET[@]+"${DASH_RUNS_DET[@]}"}")
  DASH_RUNS_DET=()
  dash_runs_consumption
  if [ "${#DASH_RUNS_DET[@]}" -gt 0 ]; then
    [ "${#DASH_ACT_CON[@]}" -eq 0 ] || DASH_ACT_CON+=("")
    DASH_ACT_CON+=("${DASH_RUNS_DET[@]}")
  fi
  DASH_RUNS_DET=() DASH_RUNS_DET_KEY=""     # (the Runs view builds its own detail again)
  if [ "${#DASH_ACT_CON[@]}" -eq 0 ]; then dt tui.act.no_usage; dash_act_note DASH_ACT_CON "$DTV" $((iw - 1)); fi
  # What it printed: the summary when the command has a shape, else the end of the output.
  if [ -s "$dir/out.log" ]; then
    mapfile -t DASH_ACT_OUT < <(head -n 300 "$dir/out.log")
    cmd="${RUN[OP]}${RUN[ARGS]:+ ${RUN[ARGS]}}"
    if outsum_for DASH_ACT_OUT "$cmd" 0 "${RUN[RC]:-}" $((iw - 1)) "act|$id|$TH_NAME|$DASH_LANG_N|$iw|$UI_S_OK"; then
      dt tui.his.summary; dash_act_head DASH_ACT_RES "$DTV"
      for line in "${OUTSUM_LINES[@]}"; do DASH_ACT_RES+=(" $line"); done
    else
      mapfile -t tail_lines < <(tail -n 8 "$dir/out.log")
      dtf tui.runs.out_tail "${#tail_lines[@]}"; dash_act_head DASH_ACT_RES "$DTF"
      for line in "${tail_lines[@]}"; do
        dash_runs_logline "$line"
        DASH_ACT_RES+=(" $TUI_OUT$C_OFF")
      done
    fi
  fi
}
DASH_ACT_OUT=()

# Builds the detail of the row with the cursor if it is not already built (the key says what it was built from).
dash_act_detail() { # width
  local key
  dash_act_cur
  if [ "$DASH_ACT_ON_JOB" -eq 1 ] && [ "$DASH_ACT_JOB" -eq 1 ]; then
    key="job|$JOB_SEQ|$JOB_TOTAL|${JOB_RC-r}|${JOB_CANCELLED:-0}|$DASH_LANG_N|$TH_NAME|$1|$DASH_PC_TXT|$SECONDS"
    [ "$key" != "$DASH_ACT_DET_KEY" ] || return 0
    DASH_ACT_DET_KEY="$key"
    dash_act_job_detail "$1"
    return 0
  fi
  dash_runs_fields "$DASH_RUNS_SEL"
  key="run|$RN_ID|$RN_ST|$DASH_RUNS_N|$DASH_LANG_N|$TH_NAME|$1"
  [ "$key" != "$DASH_ACT_DET_KEY" ] || return 0
  DASH_ACT_DET_KEY="$key"
  dash_act_run_detail "$DASH_RUNS_SEL" "$1"
}

# --- Drawing ---------------------------------------------------------------------------------------------------------------------

# The lines of the list: $1 rows of height, $2 cells of width. The command of this panel first, then the recorded runs as the Runs view lists
# them. Where the window starts is kept for the mouse.
dash_act_list_lines() { # inner_height inner_width
  local h="$1" iw="$2" n="$DASH_ACT_NROWS" i r start=0 nw when dur ins acc op line sym
  DASH_ACT_LIST_L=()
  [ "$n" -gt 0 ] || return 0
  acc="${TH[accent]:-$C_CYN}"
  nw=$((iw - 34))
  [ "$nw" -ge 3 ] || nw=3
  [ "$h" -ge 1 ] || h=1
  [ "$DASH_ACT_CUR" -lt "$h" ] || start=$((DASH_ACT_CUR - h + 1))
  DASH_ACT_START="$start" DASH_ACT_SHOWN=0
  for ((i = start; i < n && i < start + h; i++)); do
    if [ "$DASH_ACT_JOB" -eq 1 ] && [ "$i" -eq 0 ]; then
      dash_act_job_state; sym="$DASH_RUNS_SYM"
      dt tui.act.panel; when="$DTV"
      op="${JOB_TITLE%% *}"
      if [[ "$JOB_TITLE" == *" "* ]]; then ins="${JOB_TITLE#* }"; else ins="-"; fi
      if [ "$DASH_ACT_JS" = running ]; then dt runs.state.running; dur="$DTV"; else dash_job_secs; dash_clock "$DASH_JS"; dur="$DASH_CLK"; fi
    else
      r=$((i - DASH_ACT_JOB))
      dash_runs_fields "$r"
      dash_runs_sym "$RN_ST"; sym="$DASH_RUNS_SYM"
      [ ! -f "$INSTANCES_DIR/.deltactl/pending/$RN_ID" ] || sym="${DASH_SYM[err]}"   # an interrupted run nobody has reviewed
      when="${RN_WHEN:5:5} ${RN_WHEN:11:5}"
      op="$RN_OP" ins="$RN_INS"
      if [ "$RN_ST" = "running" ]; then dt runs.state.running; dur="$DTV"; else runs_fmt_ms "$RN_MS"; dur="$RUNS_F"; fi
    fi
    printf -v ins '%-*s' "$nw" "${ins:0:$nw}"
    printf -v line '%-11s %-8s %s %8s' "${when:0:11}" "${op:0:8}" "$ins" "$dur"
    if [ "$i" -eq "$DASH_ACT_CUR" ]; then DASH_ACT_LIST_L+=("$TUI_SEL$acc$UI_S_SEL$C_OFF $sym $line")
    else DASH_ACT_LIST_L+=("  $sym $line"); fi
    DASH_ACT_SHOWN=$((DASH_ACT_SHOWN + 1))
  done
}

# The box of a tab made of lines (Resumen, Consumo): $1 wide, $2 high, the lines in the array named $3, the title in $4.
dash_act_lines_box() { # width height array title
  local w="$1" h="$2" inner total off title="$4"
  local -n _src="$3"
  local -a shown=()
  inner=$((h - 2))
  DASH_ACT_PANE_H="$inner"
  total="${#_src[@]}"
  off="$DASH_ACT_OFF"
  [ "$off" -le $((total - inner)) ] || off=$((total - inner))
  [ "$off" -ge 0 ] || off=0
  DASH_ACT_OFF="$off"
  shown=("${_src[@]+"${_src[@]:$off:$inner}"}")
  if [ "$off" -gt 0 ]; then dt tui.out.scrolled; title+=" $UI_S_DOT $DTV +$off"; fi
  tui_box "$title" "$w" "$h" shown "" 0
}

# The statistics of the kinds of operation, in the box of the pane.
dash_act_stats_box() { # width height
  local title
  DASH_ACT_PANE_H=$(($2 - 2))
  dtf runs.stats_title "$RS_N"; title="$DTF"
  if [ -n "$DASH_RUNS_STATS_INST" ]; then dtf tui.runs.scope "$DASH_RUNS_STATS_INST"; title+=" $UI_S_DOT $DTF"; fi
  dash_runs_stats_lines $(($1 - 3))
  tui_box "$title" "$1" "$2" DASH_RUNS_STATS_L "" 0
}

# The body of the pane for the tab on screen: $1 wide, $2 high, into TUI_BOX.
dash_act_body() { # width height
  local w="$1" h="$2" title sh
  local -a msg=() a=()
  if [ "$DASH_ACT_ON_JOB" -eq 1 ] && [ "$DASH_ACT_JOB" -eq 1 ]; then title="./deltactl $JOB_TITLE"
  else dash_runs_fields "$DASH_RUNS_SEL"; title="$RN_OP $UI_S_DOT $RN_INS"; fi
  case "$DASH_ACT_TAB" in
    resumen)
      dash_act_detail $((w - 3))
      dash_act_lines_box "$w" "$h" DASH_ACT_RES "$title"
      ;;
    consumo)
      if [ "$DASH_ACT_STATS" -eq 1 ]; then
        dash_runs_stats_load
        dash_act_stats_box "$w" "$h"
      else
        dash_act_detail $((w - 3))
        dash_act_lines_box "$w" "$h" DASH_ACT_CON "$title"
      fi
      ;;
    salida)
      DASH_ACT_PANE_H=$((h - 2))
      if [ "$DASH_ACT_ON_JOB" -eq 1 ] && [ "$DASH_ACT_JOB" -eq 1 ]; then
        dash_out_box "$w" "$h" "$DASH_OUT_SCROLL" "$DASH_OUT_ERRORS" 0
      elif [ -n "$DASH_RV_ID" ] && [ "$DASH_RV_ID" = "$DASH_RUNS_SEL_ID" ]; then
        dash_runs_log_box "$w" "$h"
      else
        dt tui.act.no_output; dash_act_note msg "$DTV" $((w - 4))
        tui_box "$title" "$w" "$h" msg "" 0
      fi
      ;;
    procesos)
      sh=$((h / 3))
      [ "$sh" -ge 6 ] || sh=6
      [ "$sh" -le 10 ] || sh=10
      [ "$h" -ge 14 ] || sh=$((h / 2))
      DASH_ACT_PANE_H=$((h - sh - 2))
      dash_procs_tree_box "$w" $((h - sh)); a=("${TUI_BOX[@]}")
      dash_procs_self_box "$w" "$sh"
      TUI_BOX=("${a[@]}" "${TUI_BOX[@]}")
      ;;
  esac
}

scr_activity_render() { # width height
  local w="$1" bh="$2" lw=0 lh ph pw title l
  local -a msg=() out=()
  dash_act_rows; dash_act_cur
  DASH_ACT_STRIP_Y=0 DASH_ACT_SHOWN=0 DASH_ACT_LW=0
  dt tui.act.title; title="$DTV"
  if [ "$DASH_ACT_NROWS" -eq 0 ]; then
    dt tui.act.empty
    dash_wrap "$DTV" $((w - 6))
    for l in "${DASH_WRAP[@]}"; do msg+=(" $C_GRY$l$C_OFF"); done
    tui_box "$title" "$w" "$bh" msg "" 1
    TUI_FRAME+=("${TUI_BOX[@]}")
    return 0
  fi
  title+=" ($DASH_ACT_NROWS)"
  if [ "$w" -ge 100 ]; then
    lw=46; [ "$w" -lt 130 ] || lw=54
    DASH_ACT_LX=0 DASH_ACT_LW="$lw" DASH_ACT_Y0=4
    dash_act_list_lines $((bh - 2)) $((lw - 3))
    tui_box "$title" "$lw" "$bh" DASH_ACT_LIST_L "" 1; DASH_L=("${TUI_BOX[@]}")
    dash_act_pane $((w - lw)) "$bh" "$lw" 3
    DASH_R=("${TUI_BOX[@]}")
    dash_join DASH_L DASH_R
  else
    lh=$((DASH_ACT_NROWS + 2))
    [ "$lh" -le $((bh * 2 / 5)) ] || lh=$((bh * 2 / 5))
    [ "$lh" -ge 5 ] || lh=5
    ph=$((bh - lh))
    DASH_ACT_LX=0 DASH_ACT_LW="$w" DASH_ACT_Y0=4
    dash_act_list_lines $((lh - 2)) $((w - 3))
    tui_box "$title" "$w" "$lh" DASH_ACT_LIST_L "" 1
    TUI_FRAME+=("${TUI_BOX[@]}")
    dash_act_pane "$w" "$ph" 0 $((3 + lh))
    TUI_FRAME+=("${TUI_BOX[@]}")
  fi
}

# The pane: its strip of tabs (when it has room) and the box of the tab on screen, into TUI_BOX. $3 is the column it starts at (0-based) and
# $4 the screen row of its first line, for the mouse.
dash_act_pane() { # width height col row
  local w="$1" h="$2" bh="$2"
  [ "$h" -ge 3 ] || h=3 bh=3
  if [ "$h" -ge 6 ]; then
    bh=$((h - 1))
    dash_act_strip "$w"
    DASH_ACT_STRIP_Y="$4" DASH_ACT_PX="$3"
  fi
  dash_act_body "$w" "$bh"
  if [ "$h" -ge 6 ]; then TUI_BOX=("$DASH_ACT_STRIPLINE" "${TUI_BOX[@]}"); fi
}

# --- Keys ------------------------------------------------------------------------------------------------------------------------

# The keys of the saved output viewer, for the height of the pane (the Runs view's own handler assumes the whole screen).
dash_act_log_key() { # key
  local inner="$DASH_ACT_PANE_H" page max top total="$DASH_RV_TOTAL"
  [ "$total" -ge 0 ] || return 0   # still indexing
  page=$((inner - 1)); [ "$page" -ge 1 ] || page=1
  max=$((total - inner)); [ "$max" -ge 0 ] || max=0
  top="$DASH_RV_TOP"
  [ "$DASH_RV_END" -eq 0 ] || top="$max"
  case "$1" in
    pgup) top=$((top - page)) ;;
    pgdn) top=$((top + page)) ;;
    home) top=0 ;;
    end | f) top="$max" ;;
    *) return 0 ;;
  esac
  [ "$top" -ge 0 ] || top=0
  if [ "$top" -ge "$max" ]; then top="$max" DASH_RV_END=1; else DASH_RV_END=0; fi
  DASH_RV_TOP="$top"
}

# PgUp PgDn Home End (and f, v, e, t, s): the pane of the tab on screen.
dash_act_pane_key() { # key
  local k="$1" page="$DASH_ACT_PANE_H"
  [ "$page" -ge 3 ] || page=3
  page=$((page - 1))
  case "$DASH_ACT_TAB" in
    salida)
      if [ "$DASH_ACT_ON_JOB" -eq 1 ] && [ "$DASH_ACT_JOB" -eq 1 ]; then
        case "$k" in pgup | pgdn | home | end | f | v | e) dash_key_output "$k" ;; esac
      else
        dash_act_log_key "$k"
      fi
      ;;
    procesos)
      case "$k" in
        pgup | pgdn | home) dash_key_procs "$k" ;;
        end | f) DASH_PROCS_OFF=100000 ;;
      esac
      ;;
    resumen | consumo)
      if [ "$DASH_ACT_STATS" -eq 1 ]; then
        case "$k" in s) dash_act_stats_scope ;; esac
      else
        case "$k" in
          pgup) DASH_ACT_OFF=$((DASH_ACT_OFF - page)); [ "$DASH_ACT_OFF" -ge 0 ] || DASH_ACT_OFF=0 ;;
          pgdn) DASH_ACT_OFF=$((DASH_ACT_OFF + page)) ;;   # clamped to the last line when drawn
          home) DASH_ACT_OFF=0 ;;
          end | f) DASH_ACT_OFF=100000 ;;
        esac
      fi
      ;;
  esac
}

# One line up (-1) or down (+1) in the pane of the tab on screen: the wheel.
dash_act_pane_scroll() { # -1 | +1
  local d="$1" inner="$DASH_ACT_PANE_H" max top total="$DASH_RV_TOTAL"
  case "$DASH_ACT_TAB" in
    resumen | consumo)
      [ "$DASH_ACT_STATS" -eq 0 ] || return 0
      DASH_ACT_OFF=$((DASH_ACT_OFF + d))
      [ "$DASH_ACT_OFF" -ge 0 ] || DASH_ACT_OFF=0
      ;;
    procesos) if [ "$d" -lt 0 ]; then dash_key_procs up; else dash_key_procs down; fi ;;
    salida)
      if [ "$DASH_ACT_ON_JOB" -eq 1 ] && [ "$DASH_ACT_JOB" -eq 1 ]; then
        if [ "$d" -lt 0 ]; then dash_key_output up; else dash_key_output down; fi
      else
        [ "$total" -ge 0 ] || return 0
        max=$((total - inner)); [ "$max" -ge 0 ] || max=0
        top="$DASH_RV_TOP"
        [ "$DASH_RV_END" -eq 0 ] || top="$max"
        top=$((top + d))
        [ "$top" -ge 0 ] || top=0
        if [ "$top" -ge "$max" ]; then top="$max" DASH_RV_END=1; else DASH_RV_END=0; fi
        DASH_RV_TOP="$top"
      fi
      ;;
  esac
}

# The wheel (64 up, 65 down): over the list it moves the cursor, over the pane it scrolls three lines a notch.
scr_activity_wheel() { # button column row
  local d=1 i
  [ "$1" -ne 64 ] || d=-1
  if [ "$DASH_ACT_LW" -gt 0 ] && [ "$2" -le $((DASH_ACT_LX + DASH_ACT_LW)) ]; then dash_act_move "$d"; return 0; fi
  for i in 1 2 3; do dash_act_pane_scroll "$d"; done
  DASH_ACT_N=$((DASH_ACT_N + 1)) DASH_DIRTY=1
}

# s in the statistics: one instance (the one of the selected run) or all.
dash_act_stats_scope() {
  if [ -n "$DASH_RUNS_STATS_INST" ]; then DASH_RUNS_STATS_INST=""
  elif [ "${#DASH_RUNS_LINES[@]}" -gt 0 ] && [ "$DASH_ACT_ON_JOB" -eq 0 ]; then dash_runs_fields "$DASH_RUNS_SEL"; [ "$RN_INS" = "-" ] || DASH_RUNS_STATS_INST="$RN_INS"; fi
  dash_runs_stats_load
}

scr_activity_key() { # key
  case "$1" in
    up | k) dash_act_move -1 ;;
    down | j) dash_act_move 1 ;;
    g) dash_act_select 0 ;;
    G) dash_act_select 100000 ;;
    left | '<') dash_act_tab_step -1 ;;
    right | '>') dash_act_tab_step 1 ;;
    enter | l) dash_act_tab_go salida ;;
    t)
      dash_act_tab_go consumo
      if [ "$DASH_ACT_STATS" -eq 1 ]; then DASH_ACT_STATS=0; else DASH_ACT_STATS=1; dash_runs_stats_load; fi
      DASH_ACT_N=$((DASH_ACT_N + 1)) DASH_DIRTY=1
      ;;
    pgup | pgdn | home | end | f | v | e | s) dash_act_pane_key "$1" ;;
  esac
  return 0
}

# Esc closes the statistics, then goes back to the first tab, before it leaves the view.
scr_activity_back() {
  if [ "$DASH_ACT_STATS" -eq 1 ]; then DASH_ACT_STATS=0 DASH_ACT_N=$((DASH_ACT_N + 1)); return 0; fi
  if [ "$DASH_ACT_TAB" != "resumen" ]; then dash_act_tab_go resumen; return 0; fi
  return 1
}

# A left click: a tab of the pane, or a row of the list (a second click on the selected row opens its output).
scr_activity_click() { # column row
  local x="$1" y="$2" i rel c row
  if [ "$DASH_ACT_STRIP_Y" -gt 0 ] && [ "$y" -eq "$DASH_ACT_STRIP_Y" ] && [ "$x" -gt "$DASH_ACT_PX" ]; then
    rel=$((x - 1 - DASH_ACT_PX))
    for i in "${!DASH_ACT_TAB_COL[@]}"; do
      c="${DASH_ACT_TAB_COL[$i]}"
      [ -n "$c" ] || continue
      if [ "$rel" -ge "$c" ] && [ "$rel" -lt $((c + DASH_ACT_TAB_WID[i])) ]; then dash_act_tab_go "${DASH_ACT_TABS[$i]}"; return 0; fi
    done
    return 0
  fi
  [ "$DASH_ACT_LW" -gt 0 ] && [ "$x" -le $((DASH_ACT_LX + DASH_ACT_LW)) ] || return 0
  [ "$y" -ge "$DASH_ACT_Y0" ] && [ "$y" -lt $((DASH_ACT_Y0 + DASH_ACT_SHOWN)) ] || return 0
  row=$((DASH_ACT_START + y - DASH_ACT_Y0))
  dash_act_cur
  if [ "$row" -eq "$DASH_ACT_CUR" ]; then dash_act_tab_go salida; else dash_act_select "$row"; fi
  return 0
}

# --- Moving in: the notice of the old views --------------------------------------------------------------------------------------

# The first time Output, Runs or Processes is chosen, the panel says that Activity is where they live now. Chosen on purpose, it shows once.
dash_act_moved_notice() {
  [ "$DASH_ACT_NOTED" -eq 0 ] || return 0
  DASH_ACT_NOTED=1
  dash_msg info "$(t tui.act.moved)"
}

# --- The contract of lib/screens/registry.sh -------------------------------------------------------------------------------------
scr_activity_enter() {
  DASH_RUNS_AT=-1000
  dash_runs_load
  ! dash_act_job_fresh || DASH_ACT_ON_JOB=1
  DASH_ACT_OFF=0 DASH_ACT_STATS=0 DASH_ACT_N=$((DASH_ACT_N + 1))
  dash_act_sync
}
scr_activity_keys() { # width
  local kv=activity_$DASH_ACT_TAB
  [ "$DASH_ACT_STATS" -eq 0 ] || kv=activity_stats
  dash_keys_view "$kv" "$1"
}
scr_activity_texts() {
  DASH_KEYS[activity_resumen]="$(t tui.keys.act_resumen "$DASH_UD")"
  DASH_KEYS[activity_salida]="$(t tui.keys.act_salida "$DASH_UD")"
  DASH_KEYS[activity_consumo]="$(t tui.keys.act_consumo "$DASH_UD")"
  DASH_KEYS[activity_procesos]="$(t tui.keys.act_procesos "$DASH_UD")"
  DASH_KEYS[activity_stats]="$(t tui.keys.act_stats)"
}
scr_activity_sig() {
  DASH_SIG+="|$DASH_ACT_TAB|$DASH_ACT_ON_JOB|$DASH_ACT_STATS|$DASH_ACT_OFF|$DASH_ACT_N|$DASH_RUNS_SEL|$DASH_RUNS_N|$DASH_RUNS_STATS_INST"
  DASH_SIG+="|$DASH_RV_TOP|$DASH_RV_END|$DASH_RV_TOTAL|$DASH_OUT_SCROLL|$DASH_OUT_ERRORS|$DASH_OUT_RAW|$DASH_OUT_STOP|$DASH_PROCS_N|$DASH_PROCS_OFF|$DASH_PC_TXT"
}
# The saved output follows the selection while the data changes under it.
scr_activity_tick() { [ "$DASH_VIEW" != "activity" ] || dash_act_sync; }

# The process of the operation that is selected, for the Procesos tab (dash_procs_root calls it while this view is on screen): the command of
# this panel while it runs, or a recorded run that is going on in some terminal. Nothing when the selection has finished.
dash_act_proc_root() {
  local base="$INSTANCES_DIR/.deltactl" pid=""
  DASH_PR_PID="" DASH_PR_LABEL=""
  dash_act_rows
  if [ "$DASH_ACT_ON_JOB" -eq 1 ] && [ "$DASH_ACT_JOB" -eq 1 ]; then
    if job_running; then DASH_PR_PID="$JOB_PID" DASH_PR_LABEL="./deltactl $JOB_TITLE"; fi
    return 0
  fi
  [ -n "$DASH_RUNS_SEL_ID" ] || return 0
  read -r pid 2> /dev/null < "$base/active/$DASH_RUNS_SEL_ID" || true
  runs_pid_alive "$pid" || return 0
  runs_meta_read "$base/runs/$DASH_RUNS_SEL_ID" || return 0
  DASH_PR_PID="$pid" DASH_PR_LABEL="./deltactl ${RUN[OP]:-?}${RUN[ARGS]:+ ${RUN[ARGS]}}"
  dash_runs_clean DASH_PR_LABEL
}

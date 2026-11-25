#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Tab of the workspace: Historial. The operations that changed something in THIS instance (lib/core/runs.sh: deploy, init, adopt, rollback, stop...),
# newest first, and the detail of the one that is selected: how it ended, when, how long, what it cost compared with the earlier ones of the same
# command, and what it printed: the summary of its output (lib/core/outparse.sh and lib/ui/outsummary.sh, the one the Output view draws) or, for a
# command with no shape, the end of it. Enter opens the whole saved output in the viewer of the Runs view (paged, with search), which is the same
# data seen without the filter by instance. It only reads what the runs left on disk, as data. Loaded by lib/screens/instances_ws.sh (dash_ws_register).
#
# It shares the index of the runs with the Runs view (dash_runs_load): the index is read again every five seconds while the tab is on screen and the
# detail of a run is built once per selection (it reads a few small files), never once per frame.

DASH_HIS_IDX=()                 # the lines of DASH_RUNS_LINES that belong to the instance on screen
DASH_HIS_SEL=0 DASH_HIS_ID="" DASH_HIS_OFF=0 DASH_HIS_INST="" DASH_HIS_N=0 DASH_HIS_AT=-1000
DASH_HIS_DET=() DASH_HIS_DET_KEY="" DASH_HIS_LIST=()
HIS_OUT=()                      # the lines of an output being summarised

ws_historial_avail() { # instance
  [ -n "${DASH_SVCS[$1]:-}" ]
}

# --- Data -----------------------------------------------------------------------------------------------------------------------

# The runs of an instance out of the index into DASH_HIS_IDX; the selection follows the run, not the row.
dash_his_filter() { # instance
  local name="$1" i sel
  DASH_HIS_IDX=()
  for i in "${!DASH_RUNS_LINES[@]}"; do
    dash_runs_fields "$i"
    if [ "$RN_INS" = "$name" ]; then DASH_HIS_IDX+=("$i"); fi
  done
  sel="$DASH_HIS_SEL"
  if [ -n "$DASH_HIS_ID" ]; then
    for i in "${!DASH_HIS_IDX[@]}"; do
      dash_runs_fields "${DASH_HIS_IDX[$i]}"
      if [ "$RN_ID" = "$DASH_HIS_ID" ]; then sel="$i"; break; fi
    done
  fi
  [ "$sel" -lt "${#DASH_HIS_IDX[@]}" ] || sel=$((${#DASH_HIS_IDX[@]} - 1))
  [ "$sel" -ge 0 ] || sel=0
  DASH_HIS_SEL="$sel" DASH_HIS_INST="$name"
  DASH_HIS_ID=""
  if [ "${#DASH_HIS_IDX[@]}" -gt 0 ]; then dash_runs_fields "${DASH_HIS_IDX[$sel]}"; DASH_HIS_ID="$RN_ID"; fi
  DASH_HIS_N=$((DASH_HIS_N + 1)) DASH_DIRTY=1
}

ws_historial_tick() {
  local name
  if [ "$DASH_VIEW" != "instances" ] || [ "$DASH_ON_NEW" -ne 0 ] || [ "${#DASH_NAMES[@]}" -eq 0 ] || [ "$DASH_WS_TAB" != "historial" ]; then
    DASH_HIS_AT=-1000                     # (leaving the tab forgets the clock: coming back reads again)
    return 0
  fi
  name="${DASH_NAMES[$DASH_SEL]}"
  dash_ws_effective "$name"
  [ "$DASH_WS_ID" = "historial" ] || { DASH_HIS_AT=-1000; return 0; }
  if [ "$DASH_HIS_AT" -lt 0 ] || { [ "$DASH_PAUSED" -eq 0 ] && [ $((SECONDS - DASH_HIS_AT)) -ge 5 ]; }; then
    DASH_HIS_AT="$SECONDS"
    dash_runs_load
    dash_his_filter "$name"
  elif [ "$DASH_HIS_INST" != "$name" ]; then
    dash_his_filter "$name"
  fi
}

# --- The detail of a run --------------------------------------------------------------------------------------------------------

dash_his_kv() { # label value
  dash_runs_padr "$1" 14
  DASH_HIS_DET+=(" $C_GRY$DASH_PAD$C_OFF $2")
}
dash_his_head() { # text
  [ "${#DASH_HIS_DET[@]}" -eq 0 ] || DASH_HIS_DET+=("")
  DASH_HIS_DET+=(" ${TH[accent]:-$C_CYN}$C_BLD$1$C_OFF")
}

# Builds DASH_HIS_DET for the line $1 of the index of runs, for a box of $2 cells of text.
dash_his_detail() { # index width
  local i="$1" iw="$2" id dir k s rc sym line cmd
  local -a tail_lines=()
  local -A mine=()
  DASH_HIS_DET=()
  dash_runs_fields "$i"
  id="$RN_ID"
  dir="$INSTANCES_DIR/.deltactl/runs/$id"
  if ! runs_meta_read "$dir"; then dt tui.runs.gone; DASH_HIS_DET=(" $C_GRY$DTV$C_OFF"); return 0; fi
  # Whatever the file says is data: it is cleaned before it is drawn, and the keys a truncated file lacks get a value.
  for k in "${!RUN[@]}"; do s="${RUN[$k]}"; dash_runs_clean s; RUN[$k]="$s"; done
  : "${RUN[OP]:=?}" "${RUN[INSTANCE]:=-}" "${RUN[STATE]:=interrupted}" "${RUN[STARTED_AT]:=-}"
  dt runs.kv.command; dash_his_kv "$DTV" "$C_BLD./deltactl ${RUN[OP]}${RUN[ARGS]:+ ${RUN[ARGS]}}$C_OFF"
  dash_runs_sym "${RUN[STATE]}"; sym="$DASH_RUNS_SYM"
  dt "runs.state.${RUN[STATE]}"; s="$DTV"
  rc="${RUN[RC]:-}"
  if [ -n "$rc" ]; then dtf tui.runs.exit "$rc"; s+=" $UI_S_DOT $DTF"; fi
  dt runs.kv.state; dash_his_kv "$DTV" "$sym $s"
  dt runs.kv.started; dash_his_kv "$DTV" "${RUN[STARTED_AT]/T/ }"
  runs_fmt_ms "${RUN[DURATION_MS]:-}"; dt runs.kv.duration; dash_his_kv "$DTV" "$RUNS_F"
  dt runs.kv.who; dash_his_kv "$DTV" "${RUN[USER]:--}@${RUN[HOST]:--}"
  if [ -f "$INSTANCES_DIR/.deltactl/pending/$id" ]; then
    dt tui.runs.review_pending; s="$DTV"
    dt runs.kv.review; dash_his_kv "$DTV" "$C_RED$s$C_OFF"
    dtf tui.runs.resolve_cmd "$id"; DASH_HIS_DET+=("   $C_GRY$DTF$C_OFF")
  fi
  case "${RUN[STATE]}" in canceled | interrupted) dt tui.runs.partial; DASH_HIS_DET+=(" $C_GRY$DTV$C_OFF") ;; esac
  # How it compares with the earlier ones of the same command (the Runs view's own builders, which append to DASH_RUNS_DET and read other runs
  # into RUN: the run being shown is put back before its consumption).
  for k in "${!RUN[@]}"; do mine[$k]="${RUN[$k]}"; done
  DASH_RUNS_DET=()
  dash_runs_compare "$i"
  RUN=()
  for k in "${!mine[@]}"; do RUN[$k]="${mine[$k]}"; done
  DASH_HIS_DET+=("${DASH_RUNS_DET[@]+"${DASH_RUNS_DET[@]}"}")
  DASH_RUNS_DET=()
  dash_runs_consumption
  DASH_HIS_DET+=("${DASH_RUNS_DET[@]+"${DASH_RUNS_DET[@]}"}")
  DASH_RUNS_DET=() DASH_RUNS_DET_KEY=""     # (the Runs view builds its own detail again)
  # What it printed: the summary when the command has a shape, else the end of the output.
  if [ -s "$dir/out.log" ]; then
    mapfile -t HIS_OUT < <(head -n 300 "$dir/out.log")
    cmd="${RUN[OP]}${RUN[ARGS]:+ ${RUN[ARGS]}}"
    if outsum_for HIS_OUT "$cmd" 0 "${RUN[RC]:-}" $((iw - 1)) "his|$id|$TH_NAME|$DASH_LANG_N|$iw|$UI_S_OK"; then
      dt tui.his.summary; dash_his_head "$DTV"
      for line in "${OUTSUM_LINES[@]}"; do DASH_HIS_DET+=(" $line"); done
    else
      mapfile -t tail_lines < <(tail -n 8 "$dir/out.log")
      dtf tui.runs.out_tail "${#tail_lines[@]}"; dash_his_head "$DTF"
      for line in "${tail_lines[@]}"; do
        dash_runs_logline "$line"
        DASH_HIS_DET+=(" $TUI_OUT$C_OFF")
      done
    fi
  fi
}

# --- Keys -----------------------------------------------------------------------------------------------------------------------

dash_his_select() { # row
  local n="${#DASH_HIS_IDX[@]}"
  [ "$n" -gt 0 ] || return 0
  [ "$1" -ge 0 ] || set -- 0
  [ "$1" -lt "$n" ] || set -- $((n - 1))
  DASH_HIS_SEL="$1" DASH_HIS_OFF=0
  dash_runs_fields "${DASH_HIS_IDX[$1]}"
  DASH_HIS_ID="$RN_ID" DASH_HIS_N=$((DASH_HIS_N + 1))
}

# Enter: the whole saved output in the viewer of the Runs view (the selection follows the run).
dash_his_open() {
  [ -n "$DASH_HIS_ID" ] || return 0
  DASH_RUNS_SEL_ID="$DASH_HIS_ID"
  dash_screen_goto runs
  dash_runs_load
  dash_runs_log_open "$DASH_HIS_ID" || true
}

ws_historial_key() { # key
  local page=$((TUI_ROWS / 2))
  case "$1" in
    up | k) dash_his_select $((DASH_HIS_SEL - 1)) ;;
    down | j) dash_his_select $((DASH_HIS_SEL + 1)) ;;
    home | g) dash_his_select 0 ;;
    end | G) dash_his_select 100000 ;;
    pgup) DASH_HIS_OFF=$((DASH_HIS_OFF - page)); [ "$DASH_HIS_OFF" -ge 0 ] || DASH_HIS_OFF=0 ;;
    pgdn) DASH_HIS_OFF=$((DASH_HIS_OFF + page)) ;;      # (clamped to the last line when drawn)
    enter) dash_his_open ;;
    *) return 1 ;;
  esac
  return 0
}

ws_historial_texts() {
  DASH_KEYS[ws_historial]="$(t tui.his.keys "$DASH_UD" "$DASH_LEFT")"
}

# What the box depends on.
ws_historial_sig() {
  DASH_WS_SIG+="|${DASH_NAMES[$DASH_SEL]:-}|$DASH_HIS_SEL|$DASH_HIS_OFF|$DASH_HIS_N|$DASH_RUNS_N|$TH_NAME|${UI_UTF8:-0}"
}

# --- Drawing --------------------------------------------------------------------------------------------------------------------

# The rows of the list ($1 rows, $2 cells) into DASH_HIS_LIST: the selected one marked, the window follows it.
dash_his_list() { # rows width
  local rows="$1" iw="$2" n="${#DASH_HIS_IDX[@]}" i start=0 when dur acc
  DASH_HIS_LIST=()
  acc="${TH[accent]:-$C_CYN}"
  [ "$DASH_HIS_SEL" -lt "$rows" ] || start=$((DASH_HIS_SEL - rows + 1))
  for ((i = start; i < n && i < start + rows; i++)); do
    dash_runs_fields "${DASH_HIS_IDX[$i]}"
    dash_runs_sym "$RN_ST"
    [ ! -f "$INSTANCES_DIR/.deltactl/pending/$RN_ID" ] || DASH_RUNS_SYM="${DASH_SYM[err]}"      # an interrupted run nobody has reviewed
    when="${RN_WHEN:5:5} ${RN_WHEN:11:5}"
    if [ "$RN_ST" = "running" ]; then dt runs.state.running; dur="$DTV"; else runs_fmt_ms "$RN_MS"; dur="$RUNS_F"; fi
    printf -v when '%-11s %-9s %9s' "$when" "${RN_OP:0:9}" "$dur"
    tui_fit "$DASH_RUNS_SYM $when" "$((iw - 2))"
    if [ "$i" -eq "$DASH_HIS_SEL" ]; then DASH_HIS_LIST+=("$TUI_SEL$acc$UI_S_SEL$C_OFF $TUI_OUT")
    else DASH_HIS_LIST+=("  $TUI_OUT"); fi
  done
}

ws_historial_box() { # instance width height
  local name="$1" w="$2" h="$3" iw ih n lh rows off total i sep key chip st foot
  local -a body=() opts=()
  iw=$((w - 3)) ih=$((h - 2))
  [ "$DASH_HIS_INST" = "$name" ] || dash_his_filter "$name"
  n="${#DASH_HIS_IDX[@]}"
  if [ "$n" -eq 0 ]; then
    dt tui.his.empty
    kit_wrap "$DTV" "$((iw - 2))"
    for i in "${!KW_LINES[@]}"; do body+=("  ${TH[dim]:-$C_GRY}${KW_LINES[$i]}$TH_RESET"); done
  else
    # The list on top (a third of the box, between three and eight rows) and the detail of the selected run under it; a box with no room
    # for both is the list.
    lh=$((ih * 2 / 5)); [ "$lh" -ge 3 ] || lh=3; [ "$lh" -le 8 ] || lh=8; [ "$lh" -le "$n" ] || lh="$n"
    if [ "$ih" -lt 9 ]; then lh="$ih"; [ "$lh" -le "$n" ] || lh="$n"; fi
    dash_his_list "$lh" "$iw"
    body=("${DASH_HIS_LIST[@]}")
    rows=$((ih - ${#body[@]} - 1))
    if [ "$rows" -ge 3 ]; then
      dash_runs_fields "${DASH_HIS_IDX[$DASH_HIS_SEL]}"
      key="$RN_ID|$RN_ST|$DASH_RUNS_N|$DASH_LANG_N|$iw|$TH_NAME|${UI_UTF8:-0}"
      if [ "$key" != "$DASH_HIS_DET_KEY" ]; then
        dash_his_detail "${DASH_HIS_IDX[$DASH_HIS_SEL]}" "$iw"
        DASH_HIS_DET_KEY="$key"
      fi
      total="${#DASH_HIS_DET[@]}"
      off="$DASH_HIS_OFF"
      [ "$off" -le $((total - rows)) ] || off=$((total - rows))
      [ "$off" -ge 0 ] || off=0
      DASH_HIS_OFF="$off"
      tui_rep "$TH_B_H" "$iw"; sep="${TH[border]:-$C_GRY}$TUI_OUT$TH_RESET"
      body+=("$sep")
      for ((i = off; i < off + rows && i < total; i++)); do body+=("${DASH_HIS_DET[$i]}"); done
    fi
  fi
  # The border: whose it is and how many operations it has; the keys of the tab at the bottom.
  dash_ws_esc "$name"; dt tui.ws.tab.historial
  chip="$DASH_WS_ESC|$DTV"
  dash_ws_t tui.his.count "$n"
  st="$C_GRY$DASH_T$C_OFF"
  foot=""
  for i in open scroll; do dt "tui.his.foot.$i"; foot+="${foot:+|}$DTV"; done
  if dash_ws_has_strip; then dt tui.ws.foot.tabs; foot+="|$DTV"; fi
  opts=("chips=$chip" "status=$st" "footer=$foot")
  if [ "$DASH_FOCUS" = "tab" ]; then opts+=(focus=1); fi
  [ "${#body[@]}" -le "$ih" ] || body=("${body[@]:0:$ih}")
  kit_box "$w" "$h" body "${opts[@]}"
  TUI_BOX=("${KIT_BOX[@]}")
}

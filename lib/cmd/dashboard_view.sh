#!/usr/bin/env bash
# shellcheck disable=SC2034  # the DASH_* and DSV_* variables are shared with lib/cmd/dashboard.sh
# Drawing of the interactive panel: header, tabs, the views (instances, resources, output; runs is in dashboard_runs.sh), the dialogs and
# the key bars. Sourced by lib/cmd/dashboard.sh. It only builds TUI_FRAME; it never runs anything.
#
# Speed matters here: a frame is built at most once per change and every helper returns its result in a variable
# (no `$(...)`, which would fork a process per call). Texts are translated once and cached (see dt).

declare -gA DT=() DASH_SYM=() DASH_KEYS=() DASH_KB=()
DTV="" DASH_BAR="" DASH_GB="" DASH_CLK="" DASH_KC="" DASH_KBV=""
DASH_REV="" DASH_UD="" DASH_LR="" DASH_LEFT="" DASH_RIGHT="" DASH_PG=">"
DASH_SPINNER=()
DASH_HOSTLINE=""
DASH_LIST_LINES=() DASH_DET_LINES=() DASH_DET_START=() DASH_DET_OFF=0 DASH_WRAP=()
DASH_L=() DASH_R=()

# Cached translation: dt <key> leaves the text in DTV.
dt() { [ -n "${DT[$1]+x}" ] || DT[$1]="$(t "$1")"; DTV="${DT[$1]}"; }

# Symbols, spinner and arrows for the current terminal (called once, after the UI mode is known).
dash_symbols_init() {
  local k
  for k in ok warn err info dim; do DASH_SYM[$k]="$(ui_sym "$k")"; done
  # U+2139 (the CLI's info glyph) is drawn at double width by some terminals and breaks the alignment: the panel uses another.
  # The panel's own icon set: a filled dot is "up", an empty circle is "stopped" (the CLI uses a bare dot for it), and U+2139
  # (the CLI's info glyph) is drawn at double width by some terminals and breaks the alignment, so info is a small diamond.
  if [ "$UI_UTF8" -eq 1 ] && [ "$UI_RICH" -eq 1 ]; then
    DASH_SYM[info]="$C_CYN◆$C_OFF"
    DASH_SYM[dim]="$C_GRY○$C_OFF"
  fi
  if [ "$UI_UTF8" -eq 1 ] && [ "$UI_RICH" -eq 1 ]; then
    DASH_SPINNER=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    DASH_UD='↑↓' DASH_LR='←→' DASH_LEFT='←' DASH_RIGHT='→' DASH_PG='❯'
  else
    DASH_SPINNER=('|' '/' '-' '\')
    DASH_UD='Up/Dn' DASH_LR='Lt/Rt' DASH_LEFT='Lt' DASH_RIGHT='Rt' DASH_PG='>'
  fi
  DASH_REV=""
  [ -z "$C_BLD" ] || DASH_REV=$'\033[7m'
}

# Texts that depend on the language (rebuilt when it changes).
dash_texts_build() {
  DT=()
  dash_screen_texts   # every screen builds its own key hints (scr_<id>_texts)
}

# A usage bar in a variable: dash_bar <percent> [cells]  (green below 70 %, yellow below 85 %, red above). Remembered.
declare -gA DASH_BARS=()
dash_bar() {
  local pct="$1" cells="${2:-10}" on i out="" k
  [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
  [ "$pct" -le 100 ] || pct=100
  k="$pct/$cells"
  if [ -z "${DASH_BARS[$k]+x}" ]; then
    on=$(((pct * cells + 50) / 100))
    # A thin rail: the filled part takes its colour from its POSITION along the theme's gradient (green at the start, hot
    # at the end), the rest is a faint line. No end caps and no hatching.
    for ((i = 0; i < on; i++)); do
      th_ramp_at "$i" "$cells"
      out+="${TH_C:-$C_GRN}$TH_BAR_ON"
    done
    [ "$on" -ge "$cells" ] || out+="${TH[faint]:-$C_GRY}"
    for ((i = on; i < cells; i++)); do out+="$TH_BAR_OFF"; done
    DASH_BARS[$k]="$out$C_OFF"
  fi
  DASH_BAR="${DASH_BARS[$k]}"
}

# Kilobytes as gigabytes with one decimal, in DASH_GB.
dash_gb() { # kb
  local t=$(($1 * 10 / 1048576))
  DASH_GB="$((t / 10)).$((t % 10))"
}

# Seconds as mm:ss in DASH_CLK.
dash_clock() { # seconds
  printf -v DASH_CLK '%02d:%02d' $(($1 / 60)) $(($1 % 60))
}

# Color of a state kind in DASH_KC.
dash_kcol() { # kind
  case "$1" in
    ok) DASH_KC="$C_GRN" ;;
    warn) DASH_KC="$C_YEL" ;;
    err) DASH_KC="$C_RED" ;;
    *) DASH_KC="$C_GRY" ;;
  esac
}

# Splits a text in lines of at most $2 cells into DASH_WRAP.
dash_wrap() { # text width
  local -a words
  local w line=""
  DASH_WRAP=()
  read -ra words <<< "$1"
  for w in "${words[@]}"; do
    if [ -n "$line" ] && [ $((${#line} + 1 + ${#w})) -gt "$2" ]; then
      DASH_WRAP+=("$line")
      line="$w"
    else
      line="${line:+$line }$w"
    fi
  done
  [ -z "$line" ] || DASH_WRAP+=("$line")
}

# --- Header -----------------------------------------------------------------------------------------------

# The line about the server: name, memory (bar, figures and trend), load, Docker version and what the containers use.
# Rebuilt after every sample, not at every frame.
dash_host_build() {
  local sep=" $C_DIM$UI_S_DOT$C_OFF " line k total=0 used chip
  local -a chips=()
  line=" ${TH[badge]:-$C_BLD} ITC $C_OFF ${TH[accent]:-}$C_BLD$DASH_HOST$C_OFF"
  # The chips are listed by priority and each one is added only while it still fits the screen: a narrow terminal loses the
  # last ones instead of cutting a word in half.
  if [ -n "$MT_HOST_PCT" ]; then
    dt status.hdr.memory
    dash_bar "$MT_HOST_PCT" 6
    dash_gb "$MT_HOST_USED_KB"; used="$DASH_GB"
    dash_gb "$MT_HOST_TOTAL_KB"
    chip="$C_GRY$DTV$C_OFF $DASH_BAR $used/$DASH_GB GB $MT_HOST_PCT%"
    mt_spark_v "$MT_HOST_HIST" 100 6 20
    [ -z "$MT_S" ] || chip+=" $C_GRY$MT_S$C_OFF"
    chips+=("$chip")
  fi
  if [ -n "$MT_HOST_LOAD" ]; then dt status.hdr.load; chips+=("$C_GRY$DTV$C_OFF $MT_HOST_LOAD"); fi
  [ -z "$DASH_DOCKER_VER" ] || chips+=("${C_GRY}Docker$C_OFF $DASH_DOCKER_VER")
  for k in "${!MT_MEM[@]}"; do total=$((total + MT_MEM[$k])); done
  if [ "$total" -gt 0 ]; then
    mt_bytes_v "$total"; dt tui.lbl.containers
    chips+=("$C_GRY$DTV$C_OFF $MT_B")
  fi
  for chip in "${chips[@]}"; do
    tui_vlen "$line$sep$chip"
    [ "$TUI_VL" -lt "$TUI_COLS" ] || continue
    line+="$sep$chip"
  done
  DASH_HOSTLINE="$line"
}

# Seconds the current job has been running into DASH_JS (the figure it had when it ended, afterwards).
DASH_JS=0
dash_job_secs() {
  local end="$JOB_END_US"
  if job_running && [ "$JOB_CANCELLED" -eq 0 ]; then host_now_us; end="$HOST_NOW_US"; fi
  [ "$end" -gt 0 ] || { host_now_us; end="$HOST_NOW_US"; }
  DASH_JS=$(((end - JOB_START_US) / 1000000))
}

# What the current job is doing, for the right end of the tab line (empty when there is none).
dash_job_label() {
  DASH_JL=""
  [ -n "$JOB_PID" ] || return 0
  dash_job_secs
  dash_clock "$DASH_JS"
  if job_running; then
    DASH_JL="$C_YEL${DASH_SPINNER[$((DASH_SPIN % ${#DASH_SPINNER[@]}))]}$C_OFF ./deltactl $JOB_TITLE $C_GRY$DASH_CLK$C_OFF"
  elif [ "$JOB_CANCELLED" -eq 1 ]; then
    dt tui.out.cancelled
    DASH_JL="$C_GRY$UI_S_DOT ./deltactl $JOB_TITLE $DTV$C_OFF"
  elif [ "${JOB_RC:-0}" -eq 0 ]; then
    dt tui.out.ok
    DASH_JL="${DASH_SYM[ok]} ./deltactl $JOB_TITLE $C_GRY$DTV$C_OFF"
  else
    dt tui.out.failed
    DASH_JL="${DASH_SYM[err]} ./deltactl $JOB_TITLE $C_RED${DTV//\{1\}/$JOB_RC}$C_OFF"
  fi
}
DASH_JL=""

# The tab line: the views and, at the right, the state of the current command.
dash_tabs_line() {
  local v i=0 left="" short="" right="" pad lw rw piece
  for v in "${DASH_SCREENS[@]}"; do
    i=$((i + 1))
    dt "${DASH_SCREEN_TITLE[$v]}"
    if [ "$DASH_VIEW" = "$v" ]; then
      # The active view is a filled pill; without colours it keeps the bracketed form.
      if [ -n "${TH[sel]:-}" ]; then piece=" ${TH[sel]}$C_BLD $i $DTV $C_OFF"; else piece=" $DASH_REV$C_BLD$C_CYN[$i $DTV]$C_OFF"; fi
      left+="$piece" short+="$piece"
    else
      left+="  ${TH[key]:-}$i$C_OFF $C_GRY$DTV$C_OFF "
      short+="  ${TH[key]:-}$i$C_OFF "
    fi
  done
  dash_job_label
  right="$DASH_JL"
  # The card of the command that is running: how many processes it has and what they use (see dashboard_procs.sh).
  if [ -n "$DASH_PC_TXT" ] && job_running; then right+=" $C_GRY$UI_S_DOT $DASH_PC_TXT$C_OFF"; fi
  if [ "$DASH_PAUSED" -eq 1 ]; then dt tui.paused; right="$C_YEL$DTV$C_OFF${right:+  $right}"; fi
  tui_vlen "$left"; lw="$TUI_VL"
  tui_vlen "$right"; rw="$TUI_VL"
  # What the running command says matters more than the names of the other views: they shrink to their numbers first.
  DASH_TAB_SHORT=0
  if [ $((lw + rw + 2)) -gt "$TUI_COLS" ]; then left="$short" DASH_TAB_SHORT=1; tui_vlen "$left"; lw="$TUI_VL"; fi
  if [ $((lw + rw + 2)) -gt "$TUI_COLS" ]; then
    tui_clip "$right" $((TUI_COLS - lw - 2)); right="$TUI_OUT"; tui_vlen "$right"; rw="$TUI_VL"
  fi
  pad=$((TUI_COLS - lw - rw - 1))
  [ "$pad" -ge 1 ] || pad=1
  printf -v TAB_PAD '%*s' "$pad" ''
  TUI_TABS="$left$TAB_PAD$right"
}
TUI_TABS="" TAB_PAD="" DASH_TAB_SHORT=0

# The view whose tab is at column $1 of the tab line, into DASH_TAB_I (1-6). Every tab is its name plus five cells (" [1 Name]",
# "  1 Name "), or four ("  1 ") when the line had to shrink the ones that are not active.
DASH_TAB_I=0
dash_tab_at() { # column
  local v i=0 start=0 w
  for v in "${DASH_SCREENS[@]}"; do
    i=$((i + 1))
    dt "${DASH_SCREEN_TITLE[$v]}"
    w=$((${#DTV} + 5))
    [ "$DASH_TAB_SHORT" -eq 0 ] || [ "$DASH_VIEW" = "$v" ] || w=4
    if [ "$1" -gt "$start" ] && [ "$1" -le $((start + w)) ]; then DASH_TAB_I="$i"; return 0; fi
    start=$((start + w))
  done
  return 1
}

# --- View: instances -------------------------------------------------------------------------------------

# The output box of the last command: $1 wide, $2 high, $3 scroll (lines above the end), $4 = 1 for errors only.
# The result is in TUI_BOX.
dash_out_box() { # width height scroll errors_only
  local w="$1" h="$2" scroll="${3:-0}" only="${4:-0}" focus="${5:-0}" inner title col st total start end i line
  local -a body=() errs_only=()
  local -n src=JOB_LINES   # read in place: copying up to ~2200 lines on every rebuild was the biggest cost of a frame
  inner=$((h - 2))
  if [ -z "$JOB_PID" ]; then
    dt tui.out.title; title="$DTV"
    dt tui.out.empty
    body=("$C_GRY$DTV$C_OFF")
    tui_box "$title" "$w" "$h" body "" "$focus"
    return 0
  fi
  dash_job_secs; dash_clock "$DASH_JS"
  if job_running; then
    col="$C_YEL"; dt tui.out.running; st="$DTV $DASH_CLK"
  elif [ "$JOB_CANCELLED" -eq 1 ]; then
    col="$C_GRY"; dt tui.out.cancelled; st="$DTV"
  elif [ "${JOB_RC:-0}" -eq 0 ]; then
    col="$C_GRN"; dt tui.out.ok; st="$DTV $DASH_CLK"
  else
    col="$C_RED"; dt tui.out.failed; st="${DTV//\{1\}/$JOB_RC} $DASH_CLK"
  fi
  dt tui.out.title
  title="$DTV $UI_S_DOT ./deltactl $JOB_TITLE $UI_S_DOT $st"
  if [ "$only" -eq 1 ]; then
    for line in "${JOB_LINES[@]}"; do
      case "$line" in *[Ee][Rr][Rr][Oo][Rr]* | *ECONN* | *[Ff][Aa][Ii][Ll]* | *"Unable to"* | *"✖"* | *"x "*) errs_only+=("$line") ;; esac
    done
    if [ "${#errs_only[@]}" -eq 0 ]; then dt tui.out.no_match; errs_only=("$C_GRY$DTV$C_OFF"); fi
    local -n src=errs_only   # re-point the reference (a plain assignment would write into JOB_LINES)
  fi
  total="${#src[@]}"
  [ "$scroll" -le $((total - inner)) ] || scroll=$((total - inner))
  [ "$scroll" -ge 0 ] || scroll=0
  DASH_OUT_SCROLL_EFF="$scroll"
  end=$((total - scroll))
  start=$((end - inner))
  [ "$start" -ge 0 ] || start=0
  for ((i = start; i < end; i++)); do body+=("${src[$i]}"); done
  if [ "$scroll" -gt 0 ]; then dt tui.out.scrolled; title+=" $UI_S_DOT $DTV -$scroll"; fi
  tui_box "$title" "$w" "$h" body "$col" "$focus"
}
DASH_OUT_SCROLL_EFF=0

# Adds the boxes of two arrays side by side to the frame (both are lists of equal-length lines).
dash_join() { # left_array right_array
  local -n _l="$1" _r="$2"
  local i
  for i in "${!_l[@]}"; do TUI_FRAME+=("${_l[$i]}${_r[$i]:-}"); done
}

# --- Per-panel cache ------------------------------------------------------------------------------------------------
# The body is rebuilt whenever anything on it changes: a log line, a typed character, a second of a running command. Most of its
# boxes did not change then. Each of those is kept with the state it was drawn from (its signature) and reused while that state is
# the same, so a rebuild only draws what moved. A box can carry a few values its drawing left behind (DASH_PC_M), which the caller
# restores along with it.
declare -gA DASH_PC_SIG=() DASH_PC_META=()
DASH_PC_list=() DASH_PC_host=() DASH_PC_center=() DASH_PC_detail=() DASH_PC_M=""
dash_pc_get() { # name signature -> 0 with TUI_BOX and DASH_PC_M when the box is still valid
  [ "${DASH_PC_SIG[$1]-}" = "$2" ] || return 1
  local -n _pc="DASH_PC_$1"
  TUI_BOX=("${_pc[@]}")
  DASH_PC_M="${DASH_PC_META[$1]-}"
}
dash_pc_put() { # name signature [meta]   (keeps TUI_BOX)
  local -n _pc="DASH_PC_$1"
  _pc=("${TUI_BOX[@]}")
  DASH_PC_SIG[$1]="$2" DASH_PC_META[$1]="${3-}"
}

# --- View: overview (wide screens) ------------------------------------------------------------------------
# Three columns over a strip with the output of the last command:
#   left   the instances and, under them, the server (memory chart, load, what the containers use)
#   center the services table, the charts of the selected service and a summary with the next steps
#   right  the feed of Docker events
# It is used when the screen is wide and tall enough; smaller screens keep the compact instances view above.

# --- View: resources ------------------------------------------------------------------------------------

# Services of every instance as "instance/service" keys, ordered by DASH_RES_SORT, into DASH_RES_KEYS.
DASH_RES_KEYS=()
dash_res_rows() {
  local name svc i j best tmp
  local -a keys=()
  for name in "${DASH_NAMES[@]}"; do
    for svc in ${DASH_SVCS[$name]}; do keys+=("$name/$svc"); done
  done
  case "$DASH_RES_SORT" in
    mem | cpu)
      local -a val=()
      for i in "${!keys[@]}"; do
        if [ "$DASH_RES_SORT" = "mem" ]; then val[i]="${MT_MEM[${keys[$i]}]:--1}"; else val[i]="${MT_CPU[${keys[$i]}]:--1}"; fi
      done
      for ((i = 0; i < ${#keys[@]}; i++)); do
        best="$i"
        for ((j = i + 1; j < ${#keys[@]}; j++)); do
          [ "${val[$j]}" -le "${val[$best]}" ] || best="$j"
        done
        if [ "$best" -ne "$i" ]; then
          tmp="${keys[$i]}"; keys[i]="${keys[$best]}"; keys[best]="$tmp"
          tmp="${val[$i]}"; val[i]="${val[$best]}"; val[best]="$tmp"
        fi
      done
      ;;
  esac
  DASH_RES_KEYS=("${keys[@]}")
}

dash_view_resources() { # body_height
  local bh="$1" inner w key inst svc sym row mem lim pct c up rs st i start avail wide=0 title
  local -a body=()
  inner=$((bh - 2))
  w=$((TUI_COLS - 2))
  [ "$w" -lt 91 ] || wide=1
  dash_res_rows
  # Summary of the server.
  dt tui.lbl.host; title="$DTV"
  if [ -n "$MT_HOST_PCT" ]; then
    dash_bar "$MT_HOST_PCT" 20
    dash_gb "$MT_HOST_USED_KB"; mem="$DASH_GB"; dash_gb "$MT_HOST_TOTAL_KB"
    dt status.hdr.memory
    row=" $C_GRY$DTV$C_OFF $DASH_BAR $mem/$DASH_GB GB $MT_HOST_PCT%"
    mt_spark_v "$MT_HOST_HIST" 100 20 20
    [ -z "$MT_S" ] || row+="  $C_GRY$MT_S$C_OFF"
    body+=("$row")
  fi
  c=0
  for key in "${!MT_MEM[@]}"; do c=$((c + MT_MEM[$key])); done
  if [ "$c" -gt 0 ] && [ -n "$MT_HOST_TOTAL_KB" ]; then
    mt_bytes_v "$c"; dt tui.lbl.containers; row=" $C_GRY$DTV$C_OFF $MT_B"
    pct=$((c / 1024 * 100 / MT_HOST_TOTAL_KB))
    dt tui.of_ram; row+="  $C_GRY(${DTV//\{1\}/$pct})$C_OFF"
    [ -z "$MT_HOST_LOAD" ] || { dt status.hdr.load; row+="  $UI_S_DOT  $C_GRY$DTV$C_OFF $MT_HOST_LOAD"; }
    body+=("$row")
  fi
  dt "tui.res.sort.$DASH_RES_SORT"; st="$DTV"
  dt tui.res.sort
  body+=("$C_GRY ${DTV//\{1\}/$st}$C_OFF" "")
  # Header and rows.
  if [ "$wide" -eq 1 ]; then
    dt tui.res.col.instance; local ci="$DTV"; dt tui.res.col.svc; local cs="$DTV"; dt tui.res.col.state; local ce="$DTV"
    dt tui.res.col.mem; local cm="$DTV"; dt tui.res.col.cpu; local cc="$DTV"; dt tui.res.col.trend; local ct="$DTV"
    dt tui.res.col.restarts; local cr="$DTV"; dt tui.res.col.up; local cu="$DTV"
    printf -v row '    %-12s %-3s %-10s %-25s %-6s %-9s %-7s %s' "$ci" "$cs" "$ce" "$cm" "$cc" "$ct" "$cr" "$cu"
  else
    dt tui.res.col.instance; local ci="$DTV"; dt tui.res.col.svc; local cs="$DTV"; dt tui.res.col.state; local ce="$DTV"
    dt tui.res.col.mem; local cm="$DTV"; dt tui.res.col.cpu; local cc="$DTV"
    printf -v row '    %-12s %-3s %-10s %-16s %s' "$ci" "$cs" "$ce" "$cm" "$cc"
  fi
  body+=("$C_GRY$row$C_OFF")
  if [ "${#DASH_RES_KEYS[@]}" -eq 0 ]; then
    dt tui.res.none; body+=("$C_GRY $DTV$C_OFF")
  fi
  [ "$DASH_RES_SEL" -lt "${#DASH_RES_KEYS[@]}" ] || DASH_RES_SEL=$((${#DASH_RES_KEYS[@]} - 1))
  [ "$DASH_RES_SEL" -ge 0 ] || DASH_RES_SEL=0
  avail=$((inner - ${#body[@]}))
  [ "$avail" -ge 1 ] || avail=1
  start=0
  [ "$DASH_RES_SEL" -lt "$avail" ] || start=$((DASH_RES_SEL - avail + 1))
  for ((i = start; i < ${#DASH_RES_KEYS[@]} && i < start + avail; i++)); do
    key="${DASH_RES_KEYS[$i]}"
    inst="${key%%/*}"; svc="${key#*/}"
    sym="${DASH_SYM[${DSV_KIND[$key]:-dim}]}"
    printf -v row '%-12.12s %-3s' "$inst" "$svc"
    tui_fit "${DSV_TEXT[$key]:-}" 10; row+=" $TUI_OUT"
    up="${DSV_UP[$key]:--}"
    rs="${ST_RESTARTS[$key]:-0}"
    if [ -n "${MT_MEM[$key]:-}" ]; then
      mem="${MT_MEM[$key]}"; lim="${MT_LIM[$key]:-0}"
      mt_bytes_v "$mem"; c="$MT_B"
      if [ "$lim" -gt 0 ]; then
        pct=$((mem * 100 / lim)); mt_bytes_v "$lim"; c="$c/$MT_B $pct%"
      else
        pct=0
        [ -z "$MT_HOST_TOTAL_KB" ] || pct=$((mem / 1024 * 100 / MT_HOST_TOTAL_KB))
      fi
      if [ "$wide" -eq 1 ]; then
        dash_bar "$pct" 8
        tui_fit "$DASH_BAR $c" 25; row+=" $TUI_OUT"
      else
        tui_fit "$c" 16; row+=" $TUI_OUT"
      fi
      if [ -n "${MT_CPU[$key]:-}" ]; then
        mt_tenths_v "${MT_CPU[$key]}"; c="$MT_T%"
      else
        c="-"
      fi
      tui_fit "$c" 6; row+=" $TUI_OUT"
      if [ "$wide" -eq 1 ]; then
        mt_spark_v "${MT_HCPU[$key]:-}" 0 8 100
        tui_fit "$C_GRY$MT_S$C_OFF" 9; row+=" $TUI_OUT"
      fi
    else
      if [ "$wide" -eq 1 ]; then tui_fit "$C_GRY-$C_OFF" 25; else tui_fit "$C_GRY-$C_OFF" 16; fi
      row+=" $TUI_OUT"
      tui_fit "$C_GRY-$C_OFF" 6; row+=" $TUI_OUT"
      if [ "$wide" -eq 1 ]; then tui_fit "" 9; row+=" $TUI_OUT"; fi
    fi
    if [ "$wide" -eq 1 ]; then
      printf -v c '%-7s %s' "$rs" "$up"
      row+=" $c"
    fi
    if [ "$i" -eq "$DASH_RES_SEL" ]; then
      body+=("$TUI_SEL$C_CYN$UI_S_SEL$C_OFF $sym $C_BLD$row$C_OFF")
    else
      body+=("  $sym $row")
    fi
  done
  tui_box "$title" "$TUI_COLS" "$bh" body "" 1
  TUI_FRAME+=("${TUI_BOX[@]}")
}

# --- View: output ---------------------------------------------------------------------------------------

dash_view_output() { # body_height
  dash_out_box "$TUI_COLS" "$1" "$DASH_OUT_SCROLL" "$DASH_OUT_ERRORS" 1
  TUI_FRAME+=("${TUI_BOX[@]}")
}

# --- Palette ---------------------------------------------------------------------------------------------------------
dash_dialog_palette() { # body_height
  local i n="${#DASH_PAL_LABELS[@]}" shown=10 start=0 acc cur
  acc="${TH[accent]:-$C_CYN}"
  DASH_DLG=("")
  if [ -n "$DASH_REV" ]; then cur="$DASH_REV $C_OFF"; else cur="_"; fi
  DASH_DLG+=("$acc$DASH_PG$C_OFF $DASH_PAL_Q$cur" "")
  if [ "$n" -eq 0 ]; then
    dt tui.pal.none; DASH_DLG+=("$C_GRY$DTV$C_OFF")
  else
    [ "$DASH_PAL_SEL" -lt "$shown" ] || start=$((DASH_PAL_SEL - shown + 1))
    for ((i = start; i < n && i < start + shown; i++)); do
      if [ "$i" -eq "$DASH_PAL_SEL" ]; then DASH_DLG+=("$TUI_SEL$acc$UI_S_SEL$C_OFF $C_BLD${DASH_PAL_LABELS[$i]}$C_OFF")
      else DASH_DLG+=("  ${DASH_PAL_LABELS[$i]}"); fi
    done
  fi
  DASH_DLG+=("")
  dt tui.pal.title
  dash_dialog "$1" "$DTV" 64
}

# --- Dialogs --------------------------------------------------------------------------------------------

# A box with the lines of the array DASH_DLG centered in the body ($1 rows high). $2 is its title.
dash_dialog() { # body_height title [min_width]
  local bh="$1" title="$2" w h top i left pad max=0 line
  for line in "${DASH_DLG[@]}"; do tui_vlen "$line"; [ "$TUI_VL" -le "$max" ] || max="$TUI_VL"; done
  w=$((max + 4))
  [ "$w" -ge "${3:-40}" ] || w="${3:-40}"
  [ "$w" -le $((TUI_COLS - 2)) ] || w=$((TUI_COLS - 2))
  h=$((${#DASH_DLG[@]} + 2))
  [ "$h" -le "$bh" ] || h="$bh"
  tui_box "$title" "$w" "$h" DASH_DLG "" 1
  top=$(((bh - h) / 2))
  left=$(((TUI_COLS - w) / 2))
  printf -v pad '%*s' "$left" ''
  for ((i = 0; i < top; i++)); do TUI_FRAME+=(""); done
  for line in "${TUI_BOX[@]}"; do TUI_FRAME+=("$pad$line"); done
}
DASH_DLG=()

dash_dialog_menu() { # body_height
  local i
  DASH_DLG=("")
  for i in "${!DASH_MENU_ITEMS[@]}"; do
    if [ "$i" -eq "$DASH_MENU_SEL" ]; then
      DASH_DLG+=("$TUI_SEL$C_CYN$UI_S_SEL$C_OFF $C_BLD${DASH_MENU_ITEMS[$i]}$C_OFF")
    else
      DASH_DLG+=("   ${DASH_MENU_ITEMS[$i]}")
    fi
  done
  DASH_DLG+=("")
  dash_dialog "$1" "$DASH_MENU_TITLE" 50
}

dash_dialog_confirm() { # body_height
  local l
  dash_wrap "$DASH_CONF_TEXT" 58
  DASH_DLG=("")
  for l in "${DASH_WRAP[@]}"; do DASH_DLG+=(" $l"); done
  DASH_DLG+=("")
  dash_dialog "$1" "?" 50
}

dash_dialog_name() { # body_height
  local l
  dash_wrap "$(t tui.type_name "$DASH_NAME_TARGET")" 58
  DASH_DLG=("")
  for l in "${DASH_WRAP[@]}"; do DASH_DLG+=(" $l"); done
  DASH_DLG+=("" " $C_BLD$DASH_BUF$C_OFF$C_CYN$UI_S_SEL$C_OFF" "")
  dash_dialog "$1" "init" 50
}

# The keys (?): the help text over the body. A line too long for the screen goes on under its description (a hanging indent),
# never cut; the heading of the current view stands out and, when the text is taller than the screen, it opens scrolled to it
# (DASH_HELP_OFF -1) and the arrows, PgUp/PgDn and Home/End move it (dash_key_help).
DASH_HELP_OFF=0 DASH_HELP_MAX=0
dash_dialog_help() { # body_height
  local bh="$1" w tw line i k ind n avail head hi=-1 acc first rest cur word pad title end started
  local -a out=() words=()
  w=$((TUI_COLS - 2)); [ "$w" -le 100 ] || w=100
  tw=$((w - 6))     # the borders, the box's own space, two of indent and one of margin
  acc="${TH[accent]:-$C_CYN}"
  dt "tui.help.head.$DASH_VIEW"; head="$DTV"
  dt tui.help
  while IFS= read -r line; do
    # (the heading of the current view is coloured after the line is wrapped: its colour codes take no room on screen)
    first="${line%% *}"
    [ -z "$first" ] || [ "$first" != "$head" ] || hi="${#out[@]}"
    tui_vlen "$line"
    if [ "$TUI_VL" -le "$tw" ]; then out+=("$line"); continue; fi
    # Where the description starts: after the first run of three or more spaces (the padding of the keys' column), or after the
    # first word of a heading at the start of the line ("RESOURCES ↑ ↓ ..."). The keys stay as they are on the first line; the
    # lines that follow start under the description.
    i=0; while [ "$i" -lt "${#line}" ] && [ "${line:$i:1}" = " " ]; do i=$((i + 1)); done
    rest="${line:$i}" k=0
    if [[ "$rest" == *"   "* ]]; then
      word="${rest#*   }"; k=$((i + ${#rest} - ${#word}))
    elif [ "$i" -eq 0 ] && [[ "$rest" == *" "* ]]; then
      word="${rest#* }"; k=$((${#rest} - ${#word}))
    fi
    while [ "$k" -gt 0 ] && [ "$k" -lt "${#line}" ] && [ "${line:$k:1}" = " " ]; do k=$((k + 1)); done
    if [ "$k" -gt 0 ] && [ "$k" -le $((tw / 2)) ]; then ind="$k"; cur="${line:0:$k}"; rest="${line:$k}"
    else ind=$((i + 2)); cur="${line:0:$i}"; rest="${line:$i}"; fi
    printf -v pad '%*s' "$ind" ''
    read -ra words <<< "$rest"
    started=0
    for word in "${words[@]}"; do
      if [ "$started" -eq 0 ]; then cur+="$word"; started=1
      elif [ $((${#cur} + 1 + ${#word})) -gt "$tw" ]; then out+=("$cur"); cur="$pad$word"
      else cur+=" $word"; fi
    done
    out+=("$cur")
  done <<< "$DTV"
  [ "$hi" -lt 0 ] || out[hi]="$acc$C_BLD$head$C_OFF${out[$hi]:${#head}}"
  n="${#out[@]}"
  avail=$((bh - 4)); [ "$avail" -ge 1 ] || avail=1
  DASH_HELP_MAX=$((n - avail)); [ "$DASH_HELP_MAX" -ge 0 ] || DASH_HELP_MAX=0
  if [ "$DASH_HELP_OFF" -lt 0 ]; then
    DASH_HELP_OFF=0
    [ "$hi" -lt "$avail" ] || DASH_HELP_OFF="$hi"
  fi
  [ "$DASH_HELP_OFF" -le "$DASH_HELP_MAX" ] || DASH_HELP_OFF="$DASH_HELP_MAX"
  DASH_DLG=("")
  for ((i = DASH_HELP_OFF; i < n && i < DASH_HELP_OFF + avail; i++)); do DASH_DLG+=("  ${out[$i]}"); done
  DASH_DLG+=("")
  dt tui.help_title; title="$DTV"
  if [ "$DASH_HELP_MAX" -gt 0 ]; then end=$((DASH_HELP_OFF + avail)); [ "$end" -le "$n" ] || end="$n"; title+=" $UI_S_DOT $((DASH_HELP_OFF + 1))-$end/$n"; fi
  dash_dialog "$bh" "$title" "$w"
}

# The last line while the keys are shown: how to scroll them when they do not fit, or that any key goes back.
dash_help_keys() { # width
  if [ "$DASH_HELP_MAX" -gt 0 ]; then dt tui.help_scroll; dash_keyfit "${DTV//\{1\}/$DASH_UD}" "$1"
  else dt tui.help_close; dash_keyfit "$DTV" "$1"; fi
}

# --- Frame ----------------------------------------------------------------------------------------------

# The line under the body: the current message or, while typing a command, its help.
dash_msg_line() {
  local col
  if [ "$DASH_MODE" = "cmd" ] && { [ "$DASH_VIEW" = "instances" ] || [ "$DASH_VIEW" = "console" ]; }; then
    TUI_FRAME+=("")
  elif [ "$DASH_MODE" = "cmd" ]; then
    if [ "$UI_UTF8" -eq 1 ] && [ "$UI_RICH" -eq 1 ]; then dt tui.cmd.keys; else dt tui.cmd.keys.ascii; fi
    TUI_FRAME+=(" $C_GRY$DTV$C_OFF")
  elif [ -n "$DASH_MSG" ]; then
    case "$DASH_MSG_KIND" in ok) col="$C_GRN" ;; warn) col="$C_YEL" ;; err) col="$C_RED" ;; *) col="$C_CYN" ;; esac
    TUI_FRAME+=(" $col$DASH_MSG$C_OFF")
  else
    TUI_FRAME+=("")
  fi
}

# Colours a key hint text ("Enter actions · u deploy · q quit"): the key of each item in the theme's key colour, its
# description dim, the separators faint. Remembered per text. Result in DASH_KBV.
# A key hint text that fits $2 cells, into DASH_KF. It loses whole items, never half of one: the first ones (how to move) and the
# last two (help and quit, or how to go back) stay, and the ones before those go first, the latest first. Only when that is not
# enough are the last ones given up too, keeping the items from the start that fit.
dash_keyfit() { # text width
  local t="$1" w="$2" rest part n d i j out
  local -a it=()
  DASH_KF="$t"
  [ "${#t}" -gt "$w" ] || return 0
  rest="$t"
  while [ -n "$rest" ]; do
    if [[ "$rest" == *" · "* ]]; then part="${rest%% · *}"; rest="${rest#* · }"; else part="$rest"; rest=""; fi
    it+=("$part")
  done
  n="${#it[@]}"
  local -a keep=()
  for ((i = 0; i < n; i++)); do keep[i]=1; done
  for ((d = n - 3; d >= 1; d--)); do
    keep[d]=0
    out=""
    for ((j = 0; j < n; j++)); do [ "${keep[j]}" -eq 0 ] || out+="${out:+ · }${it[$j]}"; done
    if [ "${#out}" -le "$w" ]; then DASH_KF="$out"; return 0; fi
  done
  out=""
  for ((j = 0; j < n; j++)); do
    [ $((${#out} + 3 + ${#it[$j]})) -le "$w" ] || [ -z "$out" ] || break
    out+="${out:+ · }${it[$j]}"
  done
  DASH_KF="${out:0:$w}"
}
DASH_KF=""

dash_keybar() { # text [width]
  local t="$1" rest part first out="" ck
  if [ -z "$t" ]; then DASH_KBV=""; return 0; fi   # (an empty text is not a valid array key)
  ck="${2:-0}|$t"
  if [ -n "${DASH_KB[$ck]+x}" ]; then DASH_KBV="${DASH_KB[$ck]}"; return 0; fi
  if [ "${2:-0}" -gt 0 ]; then dash_keyfit "$t" "$2"; t="$DASH_KF"; fi
  rest="$t"
  while [ -n "$rest" ]; do
    # The texts always separate the items with a middle dot, whatever the glyph set of the terminal is.
    if [[ "$rest" == *" · "* ]]; then part="${rest%% · *}"; rest="${rest#* · }"; else part="$rest"; rest=""; fi
    first="${part%% *}"
    if [ "$first" = "$part" ]; then
      out+="${TH[key]:-$C_BLD}$part$C_OFF"
    else
      out+="${TH[key]:-$C_BLD}$first$C_OFF $C_GRY${part#* }$C_OFF"
    fi
    [ -z "$rest" ] || out+=" $C_DIM$UI_S_DOT$C_OFF "
  done
  DASH_KB[$ck]="$out"
  DASH_KBV="$out"
}

# The hints of a view for the last line: the text of DASH_KEYS[$1] fitted to $2 cells, and what runs now ("x cancel") at its end.
dash_keys_view() { # key_of_the_hints width
  local kv="$1" w="$2" line
  # (room is kept for "x cancel" while a command runs)
  if job_running; then dt tui.keys.running; w=$((w - 3 - ${#DTV})); fi
  dash_keybar "${DASH_KEYS[$kv]}" "$w"
  line="$DASH_KBV"
  if job_running; then dt tui.keys.running; line+=" $C_DIM$UI_S_DOT$C_OFF $C_YEL$DTV$C_OFF"; fi
  TUI_FRAME+=(" $line")
}

# The last line: the keys of the current dialog, line being typed or view (each screen draws its own, scr_<id>_keys).
dash_key_line() {
  TUI_CURSOR=""
  dash_screen_keys $((TUI_COLS - 1))
}

# The body of the last frame and the state it was built from: when only the message or the command line changed (typing,
# a clock tick) the body is reused instead of being built again.
DASH_BODY=() DASH_BODY_SIG=""
DASH_REFRESH_N=0 DASH_ERRS_N=0 DASH_LANG_N=0

# Builds the body (everything between the tab line and the message line) into TUI_FRAME.
dash_build_body() { # body_height
  local bh="$1" total i
  DASH_LIST_SHOWN=0
  if [ "$TUI_ROWS" -lt 14 ] || [ "$TUI_COLS" -lt 60 ]; then
    # Too small to draw anything useful: say so instead of drawing broken boxes.
    DASH_HELP_MAX=0   # (no help is drawn: nothing to scroll)
    dt tui.too_small
    dash_wrap "${DTV//\{1\}/60x14}" $((TUI_COLS - 2))
    TUI_FRAME+=("")
    for i in "${!DASH_WRAP[@]}"; do TUI_FRAME+=(" $C_YEL${DASH_WRAP[$i]}$C_OFF"); done
  else
    dash_screen_render "$bh"   # the current dialog, or the current view
  fi
  # The body is exactly $bh lines: pad what is short and cut what is long.
  total=$((${#TUI_FRAME[@]} - 2))
  while [ "$total" -lt "$bh" ]; do TUI_FRAME+=(""); total=$((total + 1)); done
  TUI_FRAME=("${TUI_FRAME[@]:0:$((bh + 2))}")
}

# Builds the whole frame for the current state and draws it.
dash_render() {
  local bh i sig data
  bh=$((TUI_ROWS - 4))
  dash_tabs_line
  TUI_FRAME=("$DASH_HOSTLINE" "$TUI_TABS")
  # The figures (samples, state of Docker, errors, events, logs of a service) only matter to the views that draw them. The others keep
  # their body between samples: rebuilding it every 2 s would redraw exactly the same lines.
  if dash_screen_live; then data="$MT_SAMPLES|$DASH_REFRESH_N|$DASH_ERRS_N|$DASH_EV_N|$DASH_LOGS_N"; else data=""; fi
  # What the body depends on: the view and the mode, the figures, the language, the command and the size; then each screen's own state.
  DASH_SIG="$DASH_VIEW|$DASH_MODE|$data|$DASH_LANG_N|$JOB_SEQ|$JOB_TOTAL|${JOB_RC-r}|$JOB_CANCELLED|$TUI_ROWS|$TUI_COLS"
  dash_screen_sig
  if job_running; then DASH_SIG+="|$SECONDS"; fi
  sig="$DASH_SIG"
  if [ "$sig" = "$DASH_BODY_SIG" ]; then
    TUI_FRAME+=("${DASH_BODY[@]}")
  else
    dash_build_body "$bh"
    DASH_BODY=("${TUI_FRAME[@]:2:$bh}")
    DASH_BODY_SIG="$sig"
  fi
  dash_msg_line
  dash_key_line
  # The lines that are not boxes can be wider than the screen: cut them.
  for i in 0 1 $((bh + 2)) $((bh + 3)); do
    tui_clip "${TUI_FRAME[$i]}" "$TUI_COLS"
    TUI_FRAME[i]="$TUI_OUT"
  done
  tui_draw
}

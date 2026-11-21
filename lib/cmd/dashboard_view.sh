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
  DASH_KEYS[instances]="$(t tui.keys.instances "$DASH_UD" "$DASH_RIGHT")"
  DASH_KEYS[services]="$(t tui.keys.services "$DASH_UD" "$DASH_LEFT")"
  DASH_KEYS[new]="$(t tui.keys.new "$DASH_UD")"
  DASH_KEYS[logs]="$(t tui.keys.logs "$DASH_UD" "$DASH_LEFT")"
  DASH_KEYS[zoom]="$(t tui.keys.zoom "$DASH_UD")"
  DASH_KEYS[resources]="$(t tui.keys.resources "$DASH_UD" "$DASH_LR")"
  DASH_KEYS[output]="$(t tui.keys.output "$DASH_UD" "$DASH_LR")"
  DASH_KEYS[runs]="$(t tui.keys.runs "$DASH_UD")"
  DASH_KEYS[runs_stats]="$(t tui.keys.runs_stats)"
  DASH_KEYS[runs_log]="$(t tui.keys.runs_log "$DASH_UD")"
  DASH_KEYS[procs]="$(t tui.keys.procs "$DASH_UD")"
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
  for v in instances resources output runs procs; do
    i=$((i + 1))
    dt "tui.tab.$v"
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
  if [ $((lw + rw + 2)) -gt "$TUI_COLS" ]; then left="$short"; tui_vlen "$left"; lw="$TUI_VL"; fi
  if [ $((lw + rw + 2)) -gt "$TUI_COLS" ]; then
    tui_clip "$right" $((TUI_COLS - lw - 2)); right="$TUI_OUT"; tui_vlen "$right"; rw="$TUI_VL"
  fi
  pad=$((TUI_COLS - lw - rw - 1))
  [ "$pad" -ge 1 ] || pad=1
  printf -v TAB_PAD '%*s' "$pad" ''
  TUI_TABS="$left$TAB_PAD$right"
}
TUI_TABS="" TAB_PAD=""

# --- View: instances -------------------------------------------------------------------------------------

# Lines of the list of instances. The first row is the "New instance" button; then a header and one row per instance: a dot per
# service (green, yellow, red, or an empty circle when it is stopped), the name, n/m, memory and CPU. The selected row is a filled
# bar while the list has the focus and just a marker while the focus is in the services. Kept inside $1 rows and, when given,
# $2 cells.
dash_list_lines() { # inner_height [inner_width]
  local h="$1" iw="${2:-0}" i name n="${#DASH_NAMES[@]}" nw=8 start=0 avail row nm mem cpu kind nmp dots svc cnt dw=2 btn acc lf=0
  [ "$DASH_FOCUS" != "list" ] || lf=1
  acc="${TH[accent]:-$C_CYN}"
  DASH_LIST_LINES=()
  dt tui.new.button; btn="$DTV"
  if [ "$DASH_ON_NEW" -eq 1 ]; then
    if [ "$lf" -eq 1 ]; then DASH_LIST_LINES+=("$TUI_SEL$acc$UI_S_SEL$C_OFF $acc$C_BLD$btn$C_OFF")
    else DASH_LIST_LINES+=("$acc$UI_S_SEL$C_OFF $acc$C_BLD$btn$C_OFF"); fi
  else
    DASH_LIST_LINES+=("  $acc$btn$C_OFF")
  fi
  if [ "$n" -eq 0 ]; then
    dt tui.none
    DASH_LIST_LINES+=("" "$C_GRY$DTV$C_OFF")
    return 0
  fi
  for name in "${DASH_NAMES[@]}"; do
    [ "${#name}" -le "$nw" ] || nw="${#name}"
    cnt=0; for svc in ${DASH_SVCS[$name]:-}; do cnt=$((cnt + 1)); done
    [ "$cnt" -le "$dw" ] || dw="$cnt"
  done
  [ "$dw" -le 4 ] || dw=4
  [ "$nw" -le 16 ] || nw=16
  # In a narrow pane the name gives way: the other columns (n/m, memory, cpu) and the dots need the rest.
  if [ "$iw" -gt 0 ] && [ "$nw" -gt $((iw - 25 - dw)) ]; then nw=$((iw - 25 - dw)); [ "$nw" -ge 4 ] || nw=4; fi
  dt tui.lbl.mem; mem="$DTV"
  dt tui.lbl.cpu; cpu="$DTV"
  printf -v row '%*s %-*s %-5s %6s %6s' $((2 + dw)) '' "$nw" '' 'n/m' "$mem" "$cpu"
  DASH_LIST_LINES+=("$C_GRY$row$C_OFF")
  avail=$((h - 2))
  [ "$avail" -ge 1 ] || avail=1
  [ "$DASH_ON_NEW" -eq 1 ] || [ "$DASH_SEL" -lt "$avail" ] || start=$((DASH_SEL - avail + 1))
  for ((i = start; i < n && i < start + avail; i++)); do
    name="${DASH_NAMES[$i]}"
    kind="${DASH_KIND[$name]}"
    dash_kcol "$kind"
    dots=""; cnt=0
    for svc in ${DASH_SVCS[$name]:-}; do
      if [ "$cnt" -lt "$dw" ]; then dots+="${DASH_SYM[${DSV_KIND[$name/$svc]:-dim}]}"; cnt=$((cnt + 1)); fi
    done
    while [ "$cnt" -lt "$dw" ]; do dots+=" "; cnt=$((cnt + 1)); done
    mt_instance_sum "$name" ${DASH_SVCS[$name]}
    if [ "$MT_SUM_MEM" -gt 0 ]; then
      mt_bytes_v "$MT_SUM_MEM"; mem="$MT_B"
      mt_tenths_v "$MT_SUM_CPU"; cpu="$MT_T%"
    else
      mem="-" cpu="-"
    fi
    printf -v nmp '%-5s' "${DASH_NM[$name]}"
    printf -v row '%-*s' "$nw" "$name"
    printf -v mem '%6s' "$mem"; printf -v cpu '%6s' "$cpu"
    if [ "$DASH_ON_NEW" -eq 0 ] && [ "$i" -eq "$DASH_SEL" ]; then
      if [ "$lf" -eq 1 ]; then
        DASH_LIST_LINES+=("$TUI_SEL$acc$UI_S_SEL$C_OFF $dots $C_BLD$row$C_OFF $DASH_KC$nmp$C_OFF$C_BLD$mem $cpu$C_OFF")
      else
        DASH_LIST_LINES+=("$acc$UI_S_SEL$C_OFF $dots $C_BLD$row$C_OFF $DASH_KC$nmp$C_OFF$mem $cpu")
      fi
    else
      DASH_LIST_LINES+=("  $dots $row $DASH_KC$nmp$C_OFF$mem $cpu")
    fi
  done
}

# What the center shows while the New button is selected: what it does, and how else to get there.
dash_new_box() { # width height
  local w="$1" h="$2"
  local -a body=()
  dt tui.new.l1; body+=("" "$DTV")
  dt tui.new.l2; body+=("$DTV")
  dt tui.new.l3; body+=("" "$C_GRY$DTV$C_OFF")
  dt tui.new.title
  tui_box "$DTV" "$w" "$h" body
}

# Memory and CPU lines of a running service.
dash_service_meter_lines() { # key
  local key="$1" mem lim pct txt a c
  mem="${MT_MEM[$key]}"
  lim="${MT_LIM[$key]:-0}"
  mt_bytes_v "$mem"; a="$MT_B"
  if [ "$lim" -gt 0 ]; then
    pct=$((mem * 100 / lim))
    mt_bytes_v "$lim"
    txt="$a/$MT_B  $pct%"
  else
    pct=0
    [ -z "$MT_HOST_TOTAL_KB" ] || pct=$((mem / 1024 * 100 / MT_HOST_TOTAL_KB))
    dt tui.of_ram
    txt="$a  $C_GRY${DTV//\{1\}/$pct}$C_OFF"
  fi
  dash_bar "$pct" 12
  mt_spark_v "${MT_HMEM[$key]:-}" "$lim" 14 0
  dt tui.lbl.mem
  DASH_DET_LINES+=("    $C_GRY$DTV$C_OFF  $DASH_BAR $txt  $C_GRY$MT_S$C_OFF")
  c="${MT_CPU[$key]:-}"
  dt tui.lbl.cpu
  if [ -z "$c" ]; then
    local lbl="$DTV"
    dt tui.no_reading
    DASH_DET_LINES+=("    $C_GRY$lbl  $DTV$C_OFF")
  else
    pct=$((c / 10))
    dash_bar "$pct" 12
    mt_tenths_v "$c"
    mt_spark_v "${MT_HCPU[$key]:-}" 0 14 100
    DASH_DET_LINES+=("    $C_GRY$DTV$C_OFF  $DASH_BAR $MT_T%  $C_GRY$MT_S$C_OFF")
  fi
}

# Detail of the selected instance: one block per service, totals, errors and next steps. Result in DASH_DET_LINES,
# with the line where each service starts in DASH_DET_START.
dash_detail_lines() { # instance
  local name="$1" key svc idx=0 marker sym line rs h cmd why shown=0 n lbl errs="" facts
  local -a svcs
  DASH_DET_LINES=() DASH_DET_START=()
  read -ra svcs <<< "${DASH_SVCS[$name]:-}"
  for svc in "${svcs[@]}"; do
    key="$name/$svc"
    DASH_DET_START[idx]="${#DASH_DET_LINES[@]}"
    sym="${DASH_SYM[${DSV_KIND[$key]:-dim}]}"
    if [ "$idx" -eq "$DASH_SVC" ]; then
      marker="$C_CYN$UI_S_SEL$C_OFF"
      [ "$DASH_FOCUS" != "svc" ] || marker="$TUI_SEL$marker"
    else
      marker=" "
    fi
    line="$marker $C_BLD$svc$C_OFF $C_GRY${DSV_REF[$key]:-}$C_OFF  $sym ${DSV_TEXT[$key]:-}"
    DASH_DET_LINES+=("$line")
    facts=""
    if [ -n "${DSV_UP[$key]:-}" ]; then dt tui.lbl.up; facts+="$C_GRY$DTV$C_OFF ${DSV_UP[$key]}"; fi
    [ -z "${DSV_PORT[$key]:-}" ] || facts+="${facts:+  $UI_S_DOT  }$C_GRY:${DSV_PORT[$key]}$C_OFF"
    rs="${ST_RESTARTS[$key]:-0}"
    if [ "$rs" -gt 0 ] 2>/dev/null; then dt tui.lbl.restarts; facts+="${facts:+  $UI_S_DOT  }$C_YEL$DTV $rs$C_OFF"; fi
    [ -z "$facts" ] || DASH_DET_LINES+=("    $facts")
    [ -z "${DSV_NOTE[$key]:-}" ] || DASH_DET_LINES+=("    $C_YEL$UI_S_WARN$C_OFF ${DSV_NOTE[$key]}")
    if [ -n "${MT_MEM[$key]:-}" ]; then
      dash_service_meter_lines "$key"
    elif [ "${ST_STATE[$key]:-}" = "running" ]; then
      dt tui.no_reading
      DASH_DET_LINES+=("    $C_GRY$DTV$C_OFF")
    fi
    DASH_DET_LINES+=("")
    idx=$((idx + 1))
  done
  if [ "${#svcs[@]}" -gt 0 ]; then
    mt_instance_sum "$name" "${svcs[@]}"
    dt tui.lbl.total; lbl="$DTV"
    line="  $C_BLD$lbl$C_OFF"
    if [ "$MT_SUM_MEM" -gt 0 ]; then
      mt_bytes_v "$MT_SUM_MEM"; line+="  mem $MT_B"
      if [ "$MT_SUM_LIM" -gt 0 ]; then mt_bytes_v "$MT_SUM_LIM"; line+="/$MT_B"; fi
      mt_tenths_v "$MT_SUM_CPU"; line+="  cpu $MT_T%"
    fi
    dt tui.lbl.data; line+="  $C_GRY$DTV:$C_OFF "
    dt "tui.data.${DASH_DATA[$name]:-existing}"; line+="$DTV"
    DASH_DET_LINES+=("$line")
    if [ -n "${DASH_ERRS_AT[$name]:-}" ]; then
      for svc in "${svcs[@]}"; do
        n="${DASH_ERRS[$name/$svc]:-}"
        [ -n "$n" ] || continue
        if [ "$n" -gt 0 ]; then errs+="${errs:+ $UI_S_DOT }$C_RED$svc $n$C_OFF"; else errs+="${errs:+ $UI_S_DOT }$svc 0"; fi
      done
      if [ -n "$errs" ]; then dt tui.lbl.errors; DASH_DET_LINES+=("  $C_GRY$DTV:$C_OFF $errs"); fi
    fi
  fi
  for h in ${HINTS[@]+"${HINTS[@]}"}; do
    [ "$shown" -lt 3 ] || break
    cmd="${h%%|*}"; why="${h#*|}"
    case " $cmd " in *" $name "* | *" $name") ;; *) continue ;; esac
    [ "$shown" -ne 0 ] || DASH_DET_LINES+=("")
    DASH_DET_LINES+=("  $C_CYN$UI_S_ARROW$C_OFF $C_GRN$cmd$C_OFF  $C_GRY# $why$C_OFF")
    shown=$((shown + 1))
  done
}

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

dash_view_instances() { # body_height
  local bh="$1" oh th lw rw lh dh name inner_h title off n="${#DASH_NAMES[@]}" lf=0
  [ "$DASH_FOCUS" != "list" ] || lf=1
  if [ "$bh" -ge 40 ]; then oh=$((bh * 3 / 10))   # tall terminal: the output of a command (a check is ~15 lines) fits whole
  elif [ "$bh" -ge 22 ]; then oh=8; elif [ "$bh" -ge 16 ]; then oh=6; else oh=4; fi
  th=$((bh - oh))
  name="${DASH_NAMES[$DASH_SEL]:-}"
  if [ "$TUI_COLS" -ge 100 ]; then
    lw=44; rw=$((TUI_COLS - lw))
    dash_list_lines $((th - 2))
    dt tui.instances
    tui_box "$DTV" "$lw" "$th" DASH_LIST_LINES "" "$lf"; DASH_L=("${TUI_BOX[@]}")
    dash_detail_box "$name" "$rw" "$th"; DASH_R=("${TUI_BOX[@]}")
    dash_join DASH_L DASH_R
  else
    lh=$((n + 4))
    [ "$lh" -le $((th / 2)) ] || lh=$((th / 2))
    [ "$lh" -ge 4 ] || lh=4
    dh=$((th - lh))
    dash_list_lines $((lh - 2))
    dt tui.instances
    tui_box "$DTV" "$TUI_COLS" "$lh" DASH_LIST_LINES "" "$lf"
    TUI_FRAME+=("${TUI_BOX[@]}")
    dash_detail_box "$name" "$TUI_COLS" "$dh"
    TUI_FRAME+=("${TUI_BOX[@]}")
  fi
  dash_console_box "$TUI_COLS" "$oh"
  TUI_FRAME+=("${TUI_BOX[@]}")
}

# The box with the detail of an instance.
dash_detail_box() { # instance width height
  local name="$1" w="$2" h="$3" inner s e title sf=0
  local -a shown=()
  inner=$((h - 2))
  [ "$DASH_FOCUS" != "svc" ] || sf=1
  if [ "$DASH_ON_NEW" -eq 1 ]; then dash_new_box "$w" "$h"; return 0; fi
  if [ -z "$name" ]; then
    dt tui.select_one
    shown=("$C_GRY$DTV$C_OFF")
    tui_box "" "$w" "$h" shown
    return 0
  fi
  dash_detail_lines "$name"
  # Keep the selected service inside the box.
  s="${DASH_DET_START[$DASH_SVC]:-0}"
  e=$((s + 4))
  [ "$DASH_DET_OFF" -le "$s" ] || DASH_DET_OFF="$s"
  [ "$e" -le $((DASH_DET_OFF + inner)) ] || DASH_DET_OFF=$((e - inner))
  [ "$DASH_DET_OFF" -ge 0 ] || DASH_DET_OFF=0
  [ "${#DASH_DET_LINES[@]}" -gt "$inner" ] || DASH_DET_OFF=0
  shown=("${DASH_DET_LINES[@]:$DASH_DET_OFF:$inner}")
  dash_kcol "${DASH_KIND[$name]:-dim}"
  title="$name $UI_S_DOT $DASH_KC${DASH_NM[$name]:-}$C_OFF"
  tui_box "$title" "$w" "$h" shown "" "$sf"
}

# --- View: overview (wide screens) ------------------------------------------------------------------------
# Three columns over a strip with the output of the last command:
#   left   the instances and, under them, the server (memory chart, load, what the containers use)
#   center the services table, the charts of the selected service and a summary with the next steps
#   right  the feed of Docker events
# It is used when the screen is wide and tall enough; smaller screens keep the compact instances view above.

DASH_TBL=() DASH_GL=() DASH_CB=() DASH_NX=() DASH_TOT=() DASH_HB=()

dash_overview_fits() { [ "$TUI_COLS" -ge 120 ] && [ "$TUI_ROWS" -ge 28 ]; }

# Lines of the services table of an instance, $2 cells wide. Result in DASH_TBL (header first). The selected service gets the
# selection marker. The image reference never takes more than 24 cells; what is left goes to a memory trend.
dash_svc_table_lines() { # instance inner_width
  local name="$1" iw="$2" svc key idx=0 sym row img_w show_up=0 show_bar=0 mem lim pct c cpu used tw
  local -a svcs
  DASH_TBL=()
  read -ra svcs <<< "${DASH_SVCS[$name]:-}"
  [ "$iw" -lt 80 ] || show_up=1
  [ "$iw" -lt 64 ] || show_bar=1
  used=$((2 + 2 + 5 + 12 + 11 + 7))                      # marker, symbol, svc, state, cpu (the image comes next)
  [ "$show_up" -eq 0 ] || used=$((used + 8))
  if [ "$show_bar" -eq 1 ]; then used=$((used + 22)); else used=$((used + 11)); fi
  img_w=$((iw - used))
  [ "$img_w" -ge 8 ] || img_w=8
  [ "$img_w" -le 24 ] || img_w=24
  tw=$((iw - used - img_w - 2))
  [ "$tw" -ge 8 ] || tw=0
  [ "$tw" -le 30 ] || tw=30
  dt tui.res.col.svc; row="    "; tui_fit "$DTV" 6; row+="$TUI_OUT"
  dt tui.col.image; tui_fit "$DTV" $((img_w + 1)); row+="$TUI_OUT"
  dt tui.res.col.state; tui_fit "$DTV" 11; row+="$TUI_OUT"
  if [ "$show_up" -eq 1 ]; then dt tui.res.col.up; tui_fit "$DTV" 8; row+="$TUI_OUT"; fi
  dt tui.res.col.mem; if [ "$show_bar" -eq 1 ]; then tui_fit "$DTV" 22; else tui_fit "$DTV" 11; fi; row+="$TUI_OUT"
  dt tui.res.col.cpu; tui_fit "$DTV" 7; row+="$TUI_OUT"
  if [ "$tw" -gt 0 ]; then dt tui.res.col.trend; row+="$DTV"; fi
  DASH_TBL+=("$C_GRY$row$C_OFF")
  for svc in "${svcs[@]}"; do
    key="$name/$svc"
    sym="${DASH_SYM[${DSV_KIND[$key]:-dim}]}"
    row=""
    tui_fit "$svc" 6; row+="$C_BLD$TUI_OUT$C_OFF"
    tui_fit "${DSV_REF[$key]:-}" $((img_w + 1)); row+="$C_GRY$TUI_OUT$C_OFF"
    dash_kcol "${DSV_KIND[$key]:-dim}"
    tui_fit "${DSV_TEXT[$key]:-}" 11; row+="$DASH_KC$TUI_OUT$C_OFF"
    if [ "$show_up" -eq 1 ]; then tui_fit "${DSV_UP[$key]:--}" 8; row+="$TUI_OUT"; fi
    cpu="-"
    if [ -n "${MT_MEM[$key]:-}" ]; then
      mem="${MT_MEM[$key]}"; lim="${MT_LIM[$key]:-0}"
      mt_bytes_v "$mem"; c="$MT_B"
      pct=0
      if [ "$lim" -gt 0 ]; then
        pct=$((mem * 100 / lim)); mt_bytes_v "$lim"; c="$c/$MT_B"
      elif [ -n "$MT_HOST_TOTAL_KB" ]; then
        pct=$((mem / 1024 * 100 / MT_HOST_TOTAL_KB))
      fi
      if [ "$show_bar" -eq 1 ]; then dash_bar "$pct" 10; tui_fit "$c" 11; row+="$DASH_BAR $TUI_OUT"; else tui_fit "$c" 11; row+="$TUI_OUT"; fi
      if [ -n "${MT_CPU[$key]:-}" ]; then mt_tenths_v "${MT_CPU[$key]}"; cpu="$MT_T%"; fi
    else
      if [ "$show_bar" -eq 1 ]; then tui_fit "-" 22; else tui_fit "-" 11; fi
      row+="$C_GRY$TUI_OUT$C_OFF"
    fi
    tui_fit "$cpu" 7; row+="$TUI_OUT"
    if [ "$tw" -gt 0 ]; then
      mt_spark_v "${MT_HMEM[$key]:-}" "${MT_LIM[$key]:-0}" "$tw" 0
      row+="${TH[accent]:-$C_CYN}$MT_S$C_OFF"
    fi
    if [ "$idx" -eq "$DASH_SVC" ]; then
      if [ "$DASH_FOCUS" = "svc" ]; then DASH_TBL+=("$TUI_SEL$C_CYN$UI_S_SEL$C_OFF $sym $row"); else DASH_TBL+=("$C_CYN$UI_S_SEL$C_OFF $sym $row"); fi
    else
      DASH_TBL+=("  $sym $row")
    fi
    idx=$((idx + 1))
  done
}

# Charts and facts of a service: $2 cells wide, $3 rows per chart. Result in DASH_GL (3 + 2 * rows lines).
dash_graph_lines() { # key inner_width chart_rows
  local key="$1" w=$(($2 - 1)) rows="$3" mem lim pct txt scale peak h v k facts rs pk lbl full
  DASH_GL=()
  mem="${MT_MEM[$key]:-}"
  if [ -z "$mem" ]; then
    dt tui.no_reading; DASH_GL+=("$C_GRY$DTV$C_OFF")
    return 0
  fi
  # Memory: scaled to the limit when there is one, else to the highest value seen.
  lim="${MT_LIM[$key]:-0}"
  scale=0
  mt_bytes_v "$mem"; txt="$MT_B"
  if [ "$lim" -gt 0 ]; then pct=$((mem * 100 / lim)); mt_bytes_v "$lim"; txt+="/$MT_B  $pct%"; scale="$lim"; fi
  h="${MT_HMEM[$key]:-}"
  peak=0
  for v in $h; do [ "$v" -le "$peak" ] || peak="$v"; done
  # Autoscale (like btop): the chart fits the highest value seen plus 20 %, never above the limit, so changes are visible even
  # when the service uses a small part of its limit.
  scale=$((peak * 120 / 100))
  [ "$scale" -gt 0 ] || scale=1
  if [ "$lim" -gt 0 ] && [ "$scale" -gt "$lim" ]; then scale="$lim"; fi
  mt_bytes_v "$peak"; pk="$MT_B"
  dt tui.lbl.mem; lbl="$DTV"
  dt tui.stats.peak
  DASH_GL+=("$C_BLD$lbl$C_OFF $txt  $C_GRY${DTV//\{1\}/$pk}$C_OFF")
  full="$lim"
  [ "$full" -gt 0 ] || full=$((${MT_HOST_TOTAL_KB:-0} * 1024))
  [ "$full" -gt 0 ] || full="$scale"
  gfx_area_cached "mem/$key" "$h" "$scale" "$w" "$rows"
  for k in "${!GFX_LINES[@]}"; do
    th_ramp_pct $(((rows - k) * scale * 100 / (rows * full)))
    DASH_GL+=("${TH_C:-$C_GRN}${GFX_LINES[$k]}$C_OFF")
  done
  # CPU (tenths of a percent). The chart never scales below 20 %, so an idle service looks idle.
  txt="-"
  if [ -n "${MT_CPU[$key]:-}" ]; then mt_tenths_v "${MT_CPU[$key]}"; txt="$MT_T%"; fi
  h="${MT_HCPU[$key]:-}"
  peak=200
  for v in $h; do [ "$v" -le "$peak" ] || peak="$v"; done
  dt tui.lbl.cpu
  DASH_GL+=("$C_BLD$DTV$C_OFF $txt")
  gfx_area_cached "cpu/$key" "$h" "$peak" "$w" "$rows"
  for k in "${!GFX_LINES[@]}"; do
    th_ramp_pct $(((rows - k) * peak * 100 / (rows * 1000)))
    DASH_GL+=("${TH_C:-$C_GRN}${GFX_LINES[$k]}$C_OFF")
  done
  facts=""
  if [ -n "${DSV_UP[$key]:-}" ]; then dt tui.lbl.up; facts+="$C_GRY$DTV$C_OFF ${DSV_UP[$key]}"; fi
  [ -z "${DSV_PORT[$key]:-}" ] || facts+="${facts:+  $UI_S_DOT  }$C_GRY:${DSV_PORT[$key]}$C_OFF"
  rs="${ST_RESTARTS[$key]:-0}"
  if [ "$rs" -gt 0 ] 2>/dev/null; then dt tui.lbl.restarts; facts+="${facts:+  $UI_S_DOT  }$C_YEL$DTV $rs$C_OFF"; fi
  [ -z "$facts" ] || DASH_GL+=("$facts")
}

# Totals of an instance and the errors seen in the last minutes (DASH_TOT, shown under the services table) and the next steps
# (DASH_NX, a box of its own that only exists when there is something to suggest).
dash_summary_lines() { # instance
  local name="$1" svc n errs="" shown=0 h cmd why line lbl
  local -a svcs
  DASH_NX=() DASH_TOT=()
  read -ra svcs <<< "${DASH_SVCS[$name]:-}"
  [ "${#svcs[@]}" -gt 0 ] || return 0
  mt_instance_sum "$name" "${svcs[@]}"
  dt tui.lbl.total; lbl="$DTV"
  line="$C_BLD$lbl$C_OFF"
  if [ "$MT_SUM_MEM" -gt 0 ]; then
    mt_bytes_v "$MT_SUM_MEM"; line+="  mem $MT_B"
    if [ "$MT_SUM_LIM" -gt 0 ]; then mt_bytes_v "$MT_SUM_LIM"; line+="/$MT_B"; fi
    mt_tenths_v "$MT_SUM_CPU"; line+="  cpu $MT_T%"
  fi
  dt tui.lbl.data; line+="  $C_GRY$DTV:$C_OFF "
  dt "tui.data.${DASH_DATA[$name]:-existing}"; line+="$DTV"
  DASH_TOT+=("  $line")
  if [ -n "${DASH_ERRS_AT[$name]:-}" ]; then
    for svc in "${svcs[@]}"; do
      n="${DASH_ERRS[$name/$svc]:-}"
      [ -n "$n" ] || continue
      if [ "$n" -gt 0 ]; then errs+="${errs:+ $UI_S_DOT }$C_RED$svc $n$C_OFF"; else errs+="${errs:+ $UI_S_DOT }$svc 0"; fi
    done
    if [ -n "$errs" ]; then dt tui.lbl.errors; DASH_TOT+=("  $C_GRY$DTV:$C_OFF $errs"); fi
  fi
  for h in ${HINTS[@]+"${HINTS[@]}"}; do
    [ "$shown" -lt 4 ] || break
    cmd="${h%%|*}"; why="${h#*|}"
    case " $cmd " in *" $name "* | *" $name") ;; *) continue ;; esac
    DASH_NX+=("$C_CYN$UI_S_ARROW$C_OFF $C_GRN$cmd$C_OFF  $C_GRY# $why$C_OFF")
    shown=$((shown + 1))
  done
}

# The center column: services table, charts of the selected service and the summary. Result in DASH_CB ($3 lines).
dash_center_boxes() { # instance width height
  local name="$1" w="$2" h="$3" n st rem R gh sh lh title key svc sf=0
  [ "$DASH_FOCUS" != "svc" ] || sf=1
  local -a svcs shown=()
  DASH_CB=()
  if [ "$DASH_ON_NEW" -eq 1 ]; then
    dash_new_box "$w" "$h"
    DASH_CB=("${TUI_BOX[@]}")
    return 0
  fi
  if [ -z "$name" ]; then
    dt tui.select_one; shown=("$C_GRY$DTV$C_OFF")
    tui_box "" "$w" "$h" shown
    DASH_CB=("${TUI_BOX[@]}")
    return 0
  fi
  read -ra svcs <<< "${DASH_SVCS[$name]:-}"
  n="${#svcs[@]}"
  # The table carries the totals and the error counts under its rows; the box of next steps exists only when there are some.
  dash_summary_lines "$name"
  dash_svc_table_lines "$name" $((w - 3))
  DASH_TBL+=("${DASH_TOT[@]}")
  st=$((${#DASH_TBL[@]} + 2))
  [ "$st" -ge 5 ] || st=5
  [ "$st" -le $((h - 8)) ] || st=$((h - 8))
  dash_kcol "${DASH_KIND[$name]:-dim}"
  title="$name $UI_S_DOT $DASH_KC${DASH_NM[$name]:-}$C_OFF"
  tui_box "$title" "$w" "$st" DASH_TBL "" "$sf"
  DASH_CB=("${TUI_BOX[@]}")
  rem=$((h - st))
  svc="${svcs[$DASH_SVC]:-${svcs[0]:-}}"
  key="$name/$svc"
  # What goes under the table: charts (2 * rows + 5 lines), the next steps (when there are any) and the logs (at least 6 lines).
  sh=0
  [ "${#DASH_NX[@]}" -eq 0 ] || sh=$((${#DASH_NX[@]} + 2))
  [ "$sh" -le 9 ] || sh=9
  R=$(((rem - 5 - sh - 6) / 2))
  [ "$R" -le 6 ] || R=6
  lh=0
  if [ "$R" -ge 2 ]; then
    gh=$((2 * R + 5)); lh=$((rem - gh - sh))
  else
    R=$(((rem - 5 - sh) / 2))
    if [ "$R" -ge 1 ]; then gh=$((rem - sh)); else R=$(((rem - 5) / 2)); [ "$R" -ge 1 ] || R=1; gh="$rem"; sh=0; fi
  fi
  dash_graph_lines "$key" $((w - 2)) "$R"
  dt tui.lbl.mem; title="$DTV"
  dt tui.lbl.cpu; title="$svc $UI_S_DOT $title/$DTV"
  tui_box "$title" "$w" "$gh" DASH_GL
  DASH_CB+=("${TUI_BOX[@]}")
  if [ "$sh" -ge 3 ]; then
    dt tui.summary.title
    tui_box "$DTV" "$w" "$sh" DASH_NX
    DASH_CB+=("${TUI_BOX[@]}")
  fi
  if [ "$lh" -ge 5 ]; then
    dash_logs_box "$key" "$svc" "$w" "$lh"
    DASH_CB+=("${TUI_BOX[@]}")
  fi
}

# The logs box: the last lines of the service's log (cleaned when they arrived), errors in red and warnings in yellow. With the
# focus it scrolls (the title says how far back it is) and `/` filters the lines by a text (case-insensitive).
dash_logs_box() { # key service width height [focused]
  local key="$1" svc="$2" w="$3" h="$4" foc="${5:-0}" inner n i start end line sig flt="$DASH_LOG_FILTER" title before at after f low ed=0 mark
  local -a body=()
  { [ "$DASH_MODE" = "filter" ] || [ "$DASH_MODE" = "find" ]; } && ed=1
  [ "$DASH_FOCUS" != "logs" ] || foc=1
  sig="$key|$DASH_LOGS_N|$w|$h|$foc|$DASH_LOG_SCROLL|$flt|$DASH_MODE|$TH_NAME|$DASH_LANG_N|$DASH_LOG_ERRONLY|$DASH_LOG_FIND|$DASH_LS_PAUSED|$DASH_LS_PEND|$DASH_LOG_MIDX"
  [ "$ed" -eq 0 ] || sig+="|$DASH_BUF|$DASH_CUR"
  if [ "$sig" = "$DASH_LBOX_SIG" ]; then TUI_BOX=("${DASH_LBOX[@]}"); return 0; fi
  inner=$((h - 2))
  [ "$ed" -eq 0 ] || inner=$((inner - 1))     # one line for the prompt of the filter or of the search
  [ "$inner" -ge 1 ] || inner=1
  DASH_LOG_INNER="$inner"
  f="${DASH_LOG_FIND,,}"
  if [ -z "${DASH_LOGS_AT[$key]+x}" ]; then
    dt tui.logs.loading; body=("$C_GRY$DTV$C_OFF")
  elif [ -z "${DASH_LOGS[$key]}" ]; then
    dt tui.logs.none; body=("$C_GRY$DTV$C_OFF")
  else
    dash_logs_select "$key"
    n="${#DASH_LS_SEL[@]}"
    [ "$DASH_LOG_SCROLL" -le $((n - inner)) ] || DASH_LOG_SCROLL=$((n - inner))   # never past the oldest line
    [ "$DASH_LOG_SCROLL" -ge 0 ] || DASH_LOG_SCROLL=0
    end=$((n - DASH_LOG_SCROLL))
    start=$((end - inner)); [ "$start" -ge 0 ] || start=0
    if [ "$n" -eq 0 ]; then dt tui.logs.no_match; body=("$C_GRY$DTV$C_OFF"); fi
    for ((i = start; i < end; i++)); do
      line="${DASH_LS_SEL[$i]}"
      low="${line,,}"
      dash_log_class_l "$low"
      if [ -n "$f" ]; then dash_log_mark "$line" "$f"; line="$DASH_LH"; fi
      case "$DASH_LC" in
        err) body+=("$C_RED$line$C_OFF") ;;
        warn) body+=("$C_YEL$line$C_OFF") ;;
        *) body+=("$C_GRY$line$C_OFF") ;;
      esac
    done
  fi
  if [ "$ed" -eq 1 ]; then
    before="${DASH_BUF:0:$DASH_CUR}"; at="${DASH_BUF:$DASH_CUR:1}"; after="${DASH_BUF:$((DASH_CUR + 1))}"
    mark="/"; [ "$DASH_MODE" != "find" ] || mark="~"
    while [ "${#body[@]}" -lt "$inner" ]; do body+=(""); done
    if [ -n "$DASH_REV" ]; then body+=("${TH[accent]:-$C_CYN}$mark$C_OFF $before$DASH_REV${at:- }$C_OFF$after"); else body+=("$mark $before|$at$after"); fi
  fi
  dt tui.logs.title; title="$DTV $UI_S_DOT $svc"
  if [ "$DASH_LS_PAUSED" -eq 1 ]; then
    if [ "$DASH_LS_PEND" -gt 0 ]; then dtf tui.logs.paused_n "$DASH_LS_PEND"; else dt tui.logs.paused; DTF="$DTV"; fi
    title+=" $UI_S_DOT $DTF"
  fi
  if [ "$DASH_LOG_ERRONLY" -eq 1 ]; then dt tui.logs.errors; title+=" $UI_S_DOT $DTV"; fi
  [ -z "$flt" ] || title+=" $UI_S_DOT /$flt"
  [ -z "$DASH_LOG_FIND" ] || title+=" $UI_S_DOT ~$DASH_LOG_FIND"
  if [ "$DASH_LOG_SCROLL" -gt 0 ]; then dt tui.logs.scrolled; title+=" $UI_S_DOT ${DTV//\{1\}/$DASH_LOG_SCROLL}"
  elif [ "$DASH_LS_PAUSED" -eq 0 ]; then dt tui.logs.follow; title+=" $UI_S_DOT $DTV"; fi
  tui_box "$title" "$w" "$h" body "" "$foc"
  DASH_LBOX=("${TUI_BOX[@]}") DASH_LBOX_SIG="$sig"
}

# The box about the server: memory bar and chart, load, what the containers use and the Docker version. Result in TUI_BOX.
dash_host_box() { # width height
  local w="$1" h="$2" inner rows used total k chip
  DASH_HB=()
  inner=$((h - 2))
  if [ -n "$MT_HOST_PCT" ]; then
    dt status.hdr.memory
    dash_bar "$MT_HOST_PCT" 10
    dash_gb "$MT_HOST_USED_KB"; used="$DASH_GB"; dash_gb "$MT_HOST_TOTAL_KB"
    DASH_HB+=("$C_GRY$DTV$C_OFF $DASH_BAR $used/$DASH_GB GB $MT_HOST_PCT%")
    rows=$((inner - 3))
    [ "$rows" -le 6 ] || rows=6
    if [ "$rows" -ge 1 ]; then
      gfx_area_cached host "$MT_HOST_HIST" 100 $((w - 3)) "$rows"
      for k in "${!GFX_LINES[@]}"; do
        th_ramp_pct $(((rows - k) * 100 / rows))
        DASH_HB+=("${TH_C:-$C_GRN}${GFX_LINES[$k]}$C_OFF")
      done
    fi
  fi
  if [ -n "$MT_HOST_LOAD" ]; then dt status.hdr.load; DASH_HB+=("$C_GRY$DTV$C_OFF $MT_HOST_LOAD"); fi
  total=0
  for k in "${!MT_MEM[@]}"; do total=$((total + MT_MEM[$k])); done
  if [ "$total" -gt 0 ]; then mt_bytes_v "$total"; dt tui.lbl.containers; DASH_HB+=("$C_GRY$DTV$C_OFF $MT_B"); fi
  [ -z "$DASH_DOCKER_VER" ] || DASH_HB+=("${C_GRY}Docker$C_OFF $DASH_DOCKER_VER")
  dt tui.lbl.host
  tui_box "$DTV" "$w" "$h" DASH_HB
}

# The events box: the newest events at the bottom, with their time, a symbol for what happened and the container.
dash_events_box() { # width height
  local w="$1" h="$2" inner i n ep nm act t sym col start row sig
  local -a body=()
  # Rebuilt only when an event arrived or the size, theme or language changed (not at every sample).
  sig="$DASH_EV_N|$w|$h|$TH_NAME|$DASH_LANG_N"
  if [ "$sig" = "$DASH_EBOX_SIG" ]; then TUI_BOX=("${DASH_EBOX[@]}"); return 0; fi
  inner=$((h - 2))
  n="${#DASH_EVENTS[@]}"
  if [ "$n" -eq 0 ]; then
    dt tui.events.none; body=("$C_GRY$DTV$C_OFF")
  else
    start=$((n - inner)); [ "$start" -ge 0 ] || start=0
    for ((i = start; i < n; i++)); do
      ep="${DASH_EVENTS[$i]%%|*}"; row="${DASH_EVENTS[$i]#*|}"; nm="${row%%|*}"; act="${row#*|}"
      printf -v t '%(%H:%M:%S)T' "$ep"
      case "$act" in
        die | oom | kill | "health_status: unhealthy") sym="${DASH_SYM[err]}"; col="$C_RED" ;;
        start | restart | "health_status: healthy") sym="${DASH_SYM[ok]}"; col="$C_GRN" ;;
        stop | destroy) sym="${DASH_SYM[warn]}"; col="$C_YEL" ;;
        *) sym="${DASH_SYM[dim]}"; col="$C_GRY" ;;
      esac
      body+=("$C_GRY$t$C_OFF $sym $C_BLD$nm$C_OFF $col${act#health_status: }$C_OFF")
    done
  fi
  dt tui.events.title
  tui_box "$DTV" "$w" "$h" body
  DASH_EBOX=("${TUI_BOX[@]}") DASH_EBOX_SIG="$sig"
}
DASH_EBOX=() DASH_EBOX_SIG="" DASH_LBOX=() DASH_LBOX_SIG=""

# The whole overview body into TUI_FRAME ($1 lines).
dash_view_overview() { # body_height
  local bh="$1" lw=38 ew=0 cw cs top name i lh hh n="${#DASH_NAMES[@]}" lf=0
  [ "$DASH_FOCUS" != "list" ] || lf=1
  local -a left=() center=() right=()
  name="${DASH_NAMES[$DASH_SEL]:-}"
  [ "$TUI_COLS" -lt 160 ] || lw=42
  [ "$TUI_COLS" -lt 150 ] || ew=36
  cw=$((TUI_COLS - lw - ew))
  cs=8
  [ "$bh" -lt 40 ] || cs=$((bh * 22 / 100))
  [ "$cs" -le 16 ] || cs=16
  top=$((bh - cs))
  # Left: the list takes what it needs (at most 40 %) and the server box the rest.
  lh=$((n + 4)); [ "$lh" -ge 6 ] || lh=6
  [ "$lh" -le $((top * 40 / 100)) ] || lh=$((top * 40 / 100))
  hh=$((top - lh))
  if [ "$hh" -lt 6 ]; then lh="$top"; hh=0; fi
  dash_list_lines $((lh - 2)) $((lw - 3))
  dt tui.instances
  tui_box "$DTV" "$lw" "$lh" DASH_LIST_LINES "" "$lf"; left=("${TUI_BOX[@]}")
  if [ "$hh" -gt 0 ]; then dash_host_box "$lw" "$hh"; left+=("${TUI_BOX[@]}"); fi
  dash_center_boxes "$name" "$cw" "$top"; center=("${DASH_CB[@]}")
  if [ "$ew" -gt 0 ]; then dash_events_box "$ew" "$top"; right=("${TUI_BOX[@]}"); fi
  for ((i = 0; i < top; i++)); do TUI_FRAME+=("${left[$i]}${center[$i]:-}${right[$i]:-}"); done
  dash_console_box "$TUI_COLS" "$cs"
  TUI_FRAME+=("${TUI_BOX[@]}")
}

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

# --- Zoom ------------------------------------------------------------------------------------------------------------
# `z` gives the whole body to the focused pane: the list, the services of the instance, or its logs (a log viewer).
dash_view_zoom() { # body_height
  local bh="$1" name key svc
  name="${DASH_NAMES[$DASH_SEL]:-}"
  if [ "$DASH_ON_NEW" -eq 1 ]; then
    dash_new_box "$TUI_COLS" "$bh"
  else
    case "$DASH_FOCUS" in
      list)
        dash_list_lines $((bh - 2)) $((TUI_COLS - 3))
        dt tui.instances
        tui_box "$DTV" "$TUI_COLS" "$bh" DASH_LIST_LINES "" 1
        ;;
      logs)
        if dash_current_target; then
          dash_logs_box "$DASH_T_INST/$DASH_T_SVC" "$DASH_T_SVC" "$TUI_COLS" "$bh" 1
        else
          dash_detail_box "$name" "$TUI_COLS" "$bh"
        fi
        ;;
      *) dash_detail_box "$name" "$TUI_COLS" "$bh" ;;
    esac
  fi
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

dash_dialog_help() { # body_height
  local line
  DASH_DLG=("")
  dt tui.help
  while IFS= read -r line; do DASH_DLG+=("  $line"); done <<< "$DTV"
  DASH_DLG+=("")
  dt tui.help_title
  dash_dialog "$1" "$DTV" 60
}

# --- Frame ----------------------------------------------------------------------------------------------

# The line under the body: the current message or, while typing a command, its help.
dash_msg_line() {
  local col
  if [ "$DASH_MODE" = "cmd" ] && [ "$DASH_VIEW" = "instances" ]; then
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
dash_keybar() { # text
  local t="$1" rest part first out=""
  if [ -z "$t" ]; then DASH_KBV=""; return 0; fi   # (an empty text is not a valid array key)
  if [ -n "${DASH_KB[$t]+x}" ]; then DASH_KBV="${DASH_KB[$t]}"; return 0; fi
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
  DASH_KB[$t]="$out"
  DASH_KBV="$out"
}

# The last line: the keys of the current view, or the command being typed.
dash_key_line() {
  local line kv
  TUI_CURSOR=""
  case "$DASH_MODE" in
    cmd)
      if [ "$DASH_VIEW" = "instances" ]; then
        # The console box holds the prompt: the last line only lists the keys of the line editor.
        dt tui.con.keys; dash_keybar "${DTV//\{1\}/$DASH_UD}"
        TUI_FRAME+=(" $DASH_KBV")
        return 0
      fi
      dt tui.cmd.prompt
      TUI_FRAME+=(" $C_GRY$DTV$C_OFF $C_BLD:$C_OFF$DASH_BUF")
      tui_vlen " $DTV :$DASH_BUF"
      TUI_CURSOR="$TUI_ROWS;$((TUI_VL + 2))"
      return 0
      ;;
    menu) dt tui.dialog.keys; TUI_FRAME+=(" $C_GRY${DTV//\{1\}/$DASH_UD}$C_OFF") ;;
    confirm)
      if [ "$UI_UTF8" -eq 1 ] && [ "$UI_RICH" -eq 1 ]; then dt tui.confirm.keys; else dt tui.confirm.keys.ascii; fi
      TUI_FRAME+=(" $C_GRY$DTV$C_OFF")
      ;;
    name) dt tui.name.keys; TUI_FRAME+=(" $C_GRY$DTV$C_OFF") ;;
    filter) dt tui.keys.filter; TUI_FRAME+=(" $C_GRY$DTV$C_OFF") ;;
    find) dt tui.keys.find; TUI_FRAME+=(" $C_GRY$DTV$C_OFF") ;;
    palette) dt tui.pal.keys; TUI_FRAME+=(" $C_GRY${DTV//\{1\}/$DASH_UD}$C_OFF") ;;
    help) dt tui.help_close; TUI_FRAME+=(" $C_GRY$DTV$C_OFF") ;;
    options)
      dt tui.opt.keys; line="${DTV//\{1\}/$DASH_UD}"
      dash_keybar "${line//\{2\}/$DASH_LR}"; TUI_FRAME+=(" $DASH_KBV")
      ;;
    *)
      # The hints follow the focus: on the New button, inside the services, or on the list of instances.
      kv="$DASH_VIEW"
      if [ "$DASH_VIEW" = "instances" ]; then
        if [ "$DASH_ZOOM" -eq 1 ]; then kv=zoom
        elif [ "$DASH_ON_NEW" -eq 1 ]; then kv=new
        elif [ "$DASH_FOCUS" = "svc" ]; then kv=services
        elif [ "$DASH_FOCUS" = "logs" ]; then kv=logs; fi
      fi
      [ "$DASH_VIEW" != "runs" ] || { [ "$DASH_RUNS_MODE" != "stats" ] && [ "$DASH_RUNS_MODE" != "log" ]; } || kv="runs_$DASH_RUNS_MODE"
      dash_keybar "${DASH_KEYS[$kv]}"
      line="$DASH_KBV"
      if job_running; then dt tui.keys.running; line+=" $C_DIM$UI_S_DOT$C_OFF $C_YEL$DTV$C_OFF"; fi
      TUI_FRAME+=(" $line")
      ;;
  esac
}

# The body of the last frame and the state it was built from: when only the message or the command line changed (typing,
# a clock tick) the body is reused instead of being built again.
DASH_BODY=() DASH_BODY_SIG=""
DASH_REFRESH_N=0 DASH_ERRS_N=0 DASH_LANG_N=0

# Builds the body (everything between the tab line and the message line) into TUI_FRAME.
dash_build_body() { # body_height
  local bh="$1" total i
  if [ "$TUI_ROWS" -lt 14 ] || [ "$TUI_COLS" -lt 60 ]; then
    # Too small to draw anything useful: say so instead of drawing broken boxes.
    dt tui.too_small
    dash_wrap "${DTV//\{1\}/60x14}" $((TUI_COLS - 2))
    TUI_FRAME+=("")
    for i in "${!DASH_WRAP[@]}"; do TUI_FRAME+=(" $C_YEL${DASH_WRAP[$i]}$C_OFF"); done
  else
    case "$DASH_MODE" in
      menu) dash_dialog_menu "$bh" ;;
      palette) dash_dialog_palette "$bh" ;;
      confirm) dash_dialog_confirm "$bh" ;;
      name) dash_dialog_name "$bh" ;;
      help) dash_dialog_help "$bh" ;;
      options) dash_dialog_options "$bh" ;;
      *)
        case "$DASH_VIEW" in
          instances)
            if [ "$DASH_ZOOM" -eq 1 ]; then dash_view_zoom "$bh"
            elif dash_overview_fits; then dash_view_overview "$bh"
            else dash_view_instances "$bh"; fi
            ;;
          resources) dash_view_resources "$bh" ;;
          output) dash_view_output "$bh" ;;
          runs) dash_view_runs "$bh" ;;
          procs) dash_view_procs "$bh" ;;
        esac
        ;;
    esac
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
  case "$DASH_VIEW" in
    output | runs | procs) data="" ;;
    *) data="$MT_SAMPLES|$DASH_REFRESH_N|$DASH_ERRS_N|$DASH_EV_N|$DASH_LOGS_N" ;;
  esac
  sig="$DASH_VIEW|$DASH_MODE|$DASH_SEL|$DASH_SVC|$DASH_FOCUS|$DASH_ON_NEW|$DASH_RES_SEL|$DASH_RES_SORT|$data|$DASH_LANG_N"
  sig+="|$JOB_SEQ|$JOB_TOTAL|${JOB_RC-r}|$JOB_CANCELLED|$DASH_OUT_SCROLL|$DASH_OUT_ERRORS|$TUI_ROWS|$TUI_COLS|$DASH_MENU_SEL|$DASH_CONF_TEXT|$DASH_NAME_TARGET"
  [ "$DASH_MODE" != "name" ] || sig+="|$DASH_BUF"
  sig+="|$DASH_RUNS_SEL|$DASH_RUNS_OFF|$DASH_RUNS_MODE|$DASH_RUNS_N|$DASH_RUNS_STATS_INST|$DASH_RV_TOP|$DASH_RV_END|$DASH_RV_TOTAL|$DASH_PROCS_N|$DASH_PROCS_OFF|$DASH_PC_TXT"
  sig+="|$DASH_CON_N|$DASH_CON_SCROLL|$DASH_ZOOM|$DASH_LOG_SCROLL|$DASH_LOG_FILTER|$DASH_PAL_Q|$DASH_PAL_SEL"
  sig+="|$DASH_LOG_ERRONLY|$DASH_LOG_FIND|$DASH_LS_PAUSED|$DASH_LS_PEND|$DASH_LOG_MIDX|$DASH_OPT_SEL|$DASH_OPT_N"
  { [ "$DASH_MODE" != "filter" ] && [ "$DASH_MODE" != "find" ]; } || sig+="|$DASH_BUF|$DASH_CUR"
  { [ "$DASH_MODE" != "cmd" ] || [ "$DASH_VIEW" != "instances" ]; } || sig+="|$DASH_BUF|$DASH_CUR"
  if job_running; then sig+="|$SECONDS"; fi
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

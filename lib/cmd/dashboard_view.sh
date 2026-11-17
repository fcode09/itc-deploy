#!/usr/bin/env bash
# shellcheck disable=SC2034  # the DASH_* and DSV_* variables are shared with lib/cmd/dashboard.sh
# Drawing of the interactive panel: header, tabs, the three views (instances, resources, output), the dialogs and
# the key bars. Sourced by lib/cmd/dashboard.sh. It only builds TUI_FRAME; it never runs anything.
#
# Speed matters here: a frame is built at most once per change and every helper returns its result in a variable
# (no `$(...)`, which would fork a process per call). Texts are translated once and cached (see dt).

declare -gA DT=() DASH_SYM=() DASH_KEYS=()
DTV="" DASH_BAR="" DASH_GB="" DASH_CLK="" DASH_KC=""
DASH_REV="" DASH_UD="" DASH_LR=""
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
  if [ "$UI_UTF8" -eq 1 ] && [ "$UI_RICH" -eq 1 ]; then
    DASH_SPINNER=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    DASH_UD='↑↓' DASH_LR='←→'
  else
    DASH_SPINNER=('|' '/' '-' '\')
    DASH_UD='Up/Dn' DASH_LR='Lt/Rt'
  fi
  DASH_REV=""
  [ -z "$C_BLD" ] || DASH_REV=$'\033[7m'
}

# Texts that depend on the language (rebuilt when it changes).
dash_texts_build() {
  DT=()
  DASH_KEYS[instances]="$(t tui.keys.instances "$DASH_UD" "$DASH_LR")"
  DASH_KEYS[resources]="$(t tui.keys.resources "$DASH_UD" "$DASH_LR")"
  DASH_KEYS[output]="$(t tui.keys.output "$DASH_UD" "$DASH_LR")"
}

# A usage bar in a variable: dash_bar <percent> [cells]  (green below 70 %, yellow below 85 %, red above). Remembered.
declare -gA DASH_BARS=()
dash_bar() {
  local pct="$1" cells="${2:-10}" on i out="" col k
  [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
  [ "$pct" -le 100 ] || pct=100
  k="$pct/$cells"
  if [ -z "${DASH_BARS[$k]+x}" ]; then
    on=$(((pct * cells + 50) / 100))
    if [ "$pct" -lt 70 ]; then col="$C_GRN"; elif [ "$pct" -lt 85 ]; then col="$C_YEL"; else col="$C_RED"; fi
    for ((i = 0; i < cells; i++)); do
      if [ "$i" -lt "$on" ]; then out+="$UI_S_BAR_ON"; else out+="$UI_S_BAR_OFF"; fi
    done
    DASH_BARS[$k]="$C_GRY$UI_S_BAR_L$col$out$C_GRY$UI_S_BAR_R$C_OFF"
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
  local sep=" $UI_S_DOT " line k total=0 used
  line=" $C_BLD$DASH_HOST$C_OFF"
  if [ -n "$MT_HOST_PCT" ]; then
    dt status.hdr.memory
    dash_bar "$MT_HOST_PCT" 6
    dash_gb "$MT_HOST_USED_KB"; used="$DASH_GB"
    dash_gb "$MT_HOST_TOTAL_KB"
    line+="$sep$C_GRY$DTV$C_OFF $DASH_BAR $used/$DASH_GB GB $MT_HOST_PCT%"
    mt_spark_v "$MT_HOST_HIST" 100 6 20
    [ -z "$MT_S" ] || line+=" $C_GRY$MT_S$C_OFF"
  fi
  for k in "${!MT_MEM[@]}"; do total=$((total + MT_MEM[$k])); done
  if [ "$total" -gt 0 ]; then
    mt_bytes_v "$total"; dt tui.lbl.containers
    line+="$sep$C_GRY$DTV$C_OFF $MT_B"
  fi
  if [ -n "$MT_HOST_LOAD" ]; then dt status.hdr.load; line+="$sep$C_GRY$DTV$C_OFF $MT_HOST_LOAD"; fi
  [ -z "$DASH_DOCKER_VER" ] || line+="${sep}${C_GRY}Docker$C_OFF $DASH_DOCKER_VER"
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

# The tab line: the three views and, at the right, the state of the current command.
dash_tabs_line() {
  local v i=0 left="" right="" pad lw rw
  for v in instances resources output; do
    i=$((i + 1))
    dt "tui.tab.$v"
    if [ "$DASH_VIEW" = "$v" ]; then
      left+=" $DASH_REV$C_BLD$C_CYN[$i $DTV]$C_OFF"
    else
      left+="  $C_GRY$i $DTV$C_OFF "
    fi
  done
  dash_job_label
  right="$DASH_JL"
  if [ "$DASH_PAUSED" -eq 1 ]; then dt tui.paused; right="$C_YEL$DTV$C_OFF${right:+  $right}"; fi
  tui_vlen "$left"; lw="$TUI_VL"
  tui_vlen "$right"; rw="$TUI_VL"
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

# Lines of the list of instances (one per instance, with a header), kept inside $1 rows.
dash_list_lines() { # inner_height
  local h="$1" i name n="${#DASH_NAMES[@]}" nw=8 start=0 avail row nm mem cpu kind sym nmp
  DASH_LIST_LINES=()
  if [ "$n" -eq 0 ]; then
    dt tui.none
    DASH_LIST_LINES=("$C_GRY$DTV$C_OFF")
    return 0
  fi
  for name in "${DASH_NAMES[@]}"; do [ "${#name}" -le "$nw" ] || nw="${#name}"; done
  [ "$nw" -le 16 ] || nw=16
  dt tui.lbl.mem; mem="$DTV"
  dt tui.lbl.cpu; cpu="$DTV"
  printf -v row '    %-*s %-5s %6s %6s' "$nw" '' 'n/m' "$mem" "$cpu"
  DASH_LIST_LINES+=("$C_GRY$row$C_OFF")
  avail=$((h - 1))
  [ "$avail" -ge 1 ] || avail=1
  [ "$DASH_SEL" -lt "$avail" ] || start=$((DASH_SEL - avail + 1))
  for ((i = start; i < n && i < start + avail; i++)); do
    name="${DASH_NAMES[$i]}"
    kind="${DASH_KIND[$name]}"
    sym="${DASH_SYM[$kind]}"
    dash_kcol "$kind"
    mt_instance_sum "$name" ${DASH_SVCS[$name]}
    if [ "$MT_SUM_MEM" -gt 0 ]; then
      mt_bytes_v "$MT_SUM_MEM"; mem="$MT_B"
      mt_tenths_v "$MT_SUM_CPU"; cpu="$MT_T%"
    else
      mem="-" cpu="-"
    fi
    printf -v nmp '%-5s' "${DASH_NM[$name]}"
    printf -v row '%-*s' "$nw" "$name"
    if [ "$i" -eq "$DASH_SEL" ]; then
      printf -v mem '%6s' "$mem"; printf -v cpu '%6s' "$cpu"
      DASH_LIST_LINES+=("$C_CYN$UI_S_SEL$C_OFF $sym $C_BLD$row$C_OFF $DASH_KC$nmp$C_OFF$C_BLD$mem $cpu$C_OFF")
    else
      printf -v mem '%6s' "$mem"; printf -v cpu '%6s' "$cpu"
      DASH_LIST_LINES+=("  $sym $row $DASH_KC$nmp$C_OFF$mem $cpu")
    fi
  done
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
    if [ "$idx" -eq "$DASH_SVC" ]; then marker="$C_CYN$UI_S_SEL$C_OFF"; else marker=" "; fi
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
  local w="$1" h="$2" scroll="${3:-0}" only="${4:-0}" inner title col st total start end i line
  local -a body=() src=()
  inner=$((h - 2))
  if [ -z "$JOB_PID" ]; then
    dt tui.out.title; title="$DTV"
    dt tui.out.empty
    body=("$C_GRY$DTV$C_OFF")
    tui_box "$title" "$w" "$h" body
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
      case "$line" in *[Ee][Rr][Rr][Oo][Rr]* | *ECONN* | *[Ff][Aa][Ii][Ll]* | *"Unable to"* | *"✖"* | *"x "*) src+=("$line") ;; esac
    done
    if [ "${#src[@]}" -eq 0 ]; then dt tui.out.no_match; src=("$C_GRY$DTV$C_OFF"); fi
  else
    src=("${JOB_LINES[@]}")
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
  tui_box "$title" "$w" "$h" body "$col"
}
DASH_OUT_SCROLL_EFF=0

# Adds the boxes of two arrays side by side to the frame (both are lists of equal-length lines).
dash_join() { # left_array right_array
  local -n _l="$1" _r="$2"
  local i
  for i in "${!_l[@]}"; do TUI_FRAME+=("${_l[$i]}${_r[$i]:-}"); done
}

dash_view_instances() { # body_height
  local bh="$1" oh th lw rw lh dh name inner_h title off n="${#DASH_NAMES[@]}"
  if [ "$bh" -ge 22 ]; then oh=8; elif [ "$bh" -ge 16 ]; then oh=6; else oh=4; fi
  th=$((bh - oh))
  name="${DASH_NAMES[$DASH_SEL]:-}"
  if [ "$TUI_COLS" -ge 100 ]; then
    lw=44; rw=$((TUI_COLS - lw))
    dash_list_lines $((th - 2))
    dt tui.instances
    tui_box "$DTV" "$lw" "$th" DASH_LIST_LINES; DASH_L=("${TUI_BOX[@]}")
    dash_detail_box "$name" "$rw" "$th"; DASH_R=("${TUI_BOX[@]}")
    dash_join DASH_L DASH_R
  else
    lh=$((n + 3))
    [ "$lh" -le $((th / 2)) ] || lh=$((th / 2))
    [ "$lh" -ge 4 ] || lh=4
    dh=$((th - lh))
    dash_list_lines $((lh - 2))
    dt tui.instances
    tui_box "$DTV" "$TUI_COLS" "$lh" DASH_LIST_LINES
    TUI_FRAME+=("${TUI_BOX[@]}")
    dash_detail_box "$name" "$TUI_COLS" "$dh"
    TUI_FRAME+=("${TUI_BOX[@]}")
  fi
  dash_out_box "$TUI_COLS" "$oh" 0 0
  TUI_FRAME+=("${TUI_BOX[@]}")
}

# The box with the detail of an instance.
dash_detail_box() { # instance width height
  local name="$1" w="$2" h="$3" inner s e title
  local -a shown=()
  inner=$((h - 2))
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
  tui_box "$title" "$w" "$h" shown
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
      body+=("$C_CYN$UI_S_SEL$C_OFF $sym $C_BLD$row$C_OFF")
    else
      body+=("  $sym $row")
    fi
  done
  tui_box "$title" "$TUI_COLS" "$bh" body
  TUI_FRAME+=("${TUI_BOX[@]}")
}

# --- View: output ---------------------------------------------------------------------------------------

dash_view_output() { # body_height
  dash_out_box "$TUI_COLS" "$1" "$DASH_OUT_SCROLL" "$DASH_OUT_ERRORS"
  TUI_FRAME+=("${TUI_BOX[@]}")
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
  tui_box "$title" "$w" "$h" DASH_DLG "$C_CYN"
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
      DASH_DLG+=(" $C_CYN$UI_S_SEL$C_OFF $C_BLD${DASH_MENU_ITEMS[$i]}$C_OFF")
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
  if [ "$DASH_MODE" = "cmd" ]; then
    if [ "$UI_UTF8" -eq 1 ] && [ "$UI_RICH" -eq 1 ]; then dt tui.cmd.keys; else dt tui.cmd.keys.ascii; fi
    TUI_FRAME+=(" $C_GRY$DTV$C_OFF")
  elif [ -n "$DASH_MSG" ]; then
    case "$DASH_MSG_KIND" in ok) col="$C_GRN" ;; warn) col="$C_YEL" ;; err) col="$C_RED" ;; *) col="$C_CYN" ;; esac
    TUI_FRAME+=(" $col$DASH_MSG$C_OFF")
  else
    TUI_FRAME+=("")
  fi
}

# The last line: the keys of the current view, or the command being typed.
dash_key_line() {
  local line
  TUI_CURSOR=""
  case "$DASH_MODE" in
    cmd)
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
    help) dt tui.help_close; TUI_FRAME+=(" $C_GRY$DTV$C_OFF") ;;
    *)
      line="${DASH_KEYS[$DASH_VIEW]}"
      if job_running; then dt tui.keys.running; line+=" $UI_S_DOT $C_YEL$DTV$C_OFF$C_GRY"; fi
      TUI_FRAME+=(" $C_GRY$line$C_OFF")
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
      confirm) dash_dialog_confirm "$bh" ;;
      name) dash_dialog_name "$bh" ;;
      help) dash_dialog_help "$bh" ;;
      *)
        case "$DASH_VIEW" in
          instances) dash_view_instances "$bh" ;;
          resources) dash_view_resources "$bh" ;;
          output) dash_view_output "$bh" ;;
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
  local bh i sig
  bh=$((TUI_ROWS - 4))
  dash_tabs_line
  TUI_FRAME=("$DASH_HOSTLINE" "$TUI_TABS")
  sig="$DASH_VIEW|$DASH_MODE|$DASH_SEL|$DASH_SVC|$DASH_RES_SEL|$DASH_RES_SORT|$MT_SAMPLES|$DASH_REFRESH_N|$DASH_ERRS_N|$DASH_LANG_N"
  sig+="|$JOB_SEQ|$JOB_TOTAL|${JOB_RC-r}|$JOB_CANCELLED|$DASH_OUT_SCROLL|$DASH_OUT_ERRORS|$TUI_ROWS|$TUI_COLS|$DASH_MENU_SEL|$DASH_CONF_TEXT|$DASH_NAME_TARGET"
  [ "$DASH_MODE" != "name" ] || sig+="|$DASH_BUF"
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

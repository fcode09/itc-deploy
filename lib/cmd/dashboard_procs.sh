#!/usr/bin/env bash
# shellcheck disable=SC2034  # the DASH_P* variables are shared with lib/cmd/dashboard.sh and dashboard_view.sh
# The Processes view of the panel (key 5) and the card in the header: what the command that is running is made of, live, and what
# the panel itself costs. Sourced by lib/cmd/dashboard.sh. Everything is read with Bash builtins from /proc (DELTACTL_PROC_ROOT points
# to another tree in the tests), the same way the sampler of a recorded run does it, so looking costs next to nothing.
#
# "Memory" is the sum of the resident pages of the command's processes without the wrapper that waits for it, like `runs show`;
# it does not include dockerd or the containers.

DASH_PT_PID=() DASH_PT_DEP=() DASH_PT_RSS=() DASH_PT_CMD=() DASH_PT_SUM=0 DASH_PT_N=0
DASH_PR_PID="" DASH_PR_LABEL=""                       # the command shown: its root process and its name
DASH_PC_TXT=""                                        # the card of the header: "5 proc · 34.0 MB"
DASH_PS_RSS=0 DASH_PS_NOW="" DASH_PS_AVG="" DASH_PS_TICKS=0 DASH_PS_KIDS=() DASH_PS_KRSS=() DASH_PS_KCMD=()
DASH_PS_PREV_TICKS=-1 DASH_PS_PREV_US=0
DASH_PROCS_AT=-1000 DASH_PROCS_N=0 DASH_PROCS_SIG="" DASH_PROCS_OFF=0 DASH_PROCS_MAX=200
DASH_SELF_PID="$$" DASH_CLK_TCK=0 DASH_PAGE_KB=0
DASH_PI_RSS=0 DASH_PI_CMD=""

dash_proc_consts() {
  [ "$DASH_CLK_TCK" -gt 0 ] || { DASH_CLK_TCK="$(getconf CLK_TCK 2> /dev/null || echo 100)"; [[ "$DASH_CLK_TCK" =~ ^[0-9]+$ ]] && [ "$DASH_CLK_TCK" -gt 0 ] || DASH_CLK_TCK=100; }
  [ "$DASH_PAGE_KB" -gt 0 ] || { DASH_PAGE_KB=$(($(getconf PAGESIZE 2> /dev/null || echo 4096) / 1024)); [ "$DASH_PAGE_KB" -gt 0 ] || DASH_PAGE_KB=4; }
}

# Resident memory (KB) and a short command line of a process into DASH_PI_RSS and DASH_PI_CMD.
dash_proc_info() { # pid
  local pr="${DELTACTL_PROC_ROOT:-/proc}" p="$1" k a first=1 cmd=""
  DASH_PI_RSS=0 DASH_PI_CMD=""
  read -r _ k _ 2> /dev/null < "$pr/$p/statm" || k=0
  [[ "$k" =~ ^[0-9]+$ ]] || k=0
  DASH_PI_RSS=$((k * DASH_PAGE_KB))
  # The arguments are separated by NUL bytes. The program is shown without its directory.
  while IFS= read -r -d '' a; do
    if [ "$first" -eq 1 ]; then a="${a##*/}"; first=0; fi
    cmd+="${cmd:+ }$a"
  done 2> /dev/null < "$pr/$p/cmdline"
  [ -n "$cmd" ] || { read -r cmd 2> /dev/null < "$pr/$p/comm" || cmd="?"; cmd="[$cmd]"; }
  if [[ "$cmd" == *[[:cntrl:]]* ]]; then cmd="${cmd//[[:cntrl:]]/ }"; fi
  DASH_PI_CMD="$cmd"
}

# The processes that hang from $1, in tree order, into DASH_PT_*. The root is listed but its memory is not counted.
dash_proc_tree() { # root_pid
  local pr="${DELTACTL_PROC_ROOT:-/proc}" p d c line k i
  local -a stack=("$1") dep=(0) kids=()
  DASH_PT_PID=() DASH_PT_DEP=() DASH_PT_RSS=() DASH_PT_CMD=() DASH_PT_SUM=0 DASH_PT_N=0
  dash_proc_consts
  while [ "${#stack[@]}" -gt 0 ] && [ "${#DASH_PT_PID[@]}" -lt "$DASH_PROCS_MAX" ]; do
    i=$((${#stack[@]} - 1))
    p="${stack[$i]}" d="${dep[$i]}"
    unset "stack[$i]" "dep[$i]"
    [ -d "$pr/$p" ] || continue
    dash_proc_info "$p"
    DASH_PT_PID+=("$p") DASH_PT_DEP+=("$d") DASH_PT_RSS+=("$DASH_PI_RSS") DASH_PT_CMD+=("$DASH_PI_CMD")
    if [ "${#DASH_PT_PID[@]}" -gt 1 ]; then DASH_PT_SUM=$((DASH_PT_SUM + DASH_PI_RSS)) DASH_PT_N=$((DASH_PT_N + 1)); fi
    kids=()
    for c in "$pr/$p"/task/*/children; do
      line=""
      read -r line 2> /dev/null < "$c" || true   # (no trailing newline: read fails but fills the variable)
      for k in $line; do kids+=("$k"); done
    done
    # Pushed backwards so that the lowest pid is taken first.
    for ((i = ${#kids[@]} - 1; i >= 0; i--)); do stack+=("${kids[$i]}"); dep+=($((d + 1))); done
  done
}

# CPU as tenths of a percent of one core for $1 clock ticks over $2 microseconds, into DASH_TEN.
DASH_TEN=0
dash_proc_tenths() { # ticks elapsed_us
  DASH_TEN=0
  [ "$2" -gt 0 ] || return 0
  dash_proc_consts
  DASH_TEN=$(($1 * 1000000000 / (DASH_CLK_TCK * $2)))
}

# The panel itself: its resident memory, its CPU (now, and on average since it started) and what it has started.
dash_proc_self() {
  local pr="${DELTACTL_PROC_ROOT:-/proc}" me="$DASH_SELF_PID" line k c ticks us
  local -a f=()
  dash_proc_consts
  read -r _ k _ 2> /dev/null < "$pr/$me/statm" || k=0
  [[ "$k" =~ ^[0-9]+$ ]] || k=0
  DASH_PS_RSS=$((k * DASH_PAGE_KB))
  line=""
  read -r line 2> /dev/null < "$pr/$me/stat" || true
  line="${line##*) }"
  read -ra f <<< "$line"
  ticks=0
  if [[ "${f[11]:-}" =~ ^[0-9]+$ ]] && [[ "${f[12]:-}" =~ ^[0-9]+$ ]]; then ticks=$((f[11] + f[12])); fi
  host_now_us; us="$HOST_NOW_US"
  DASH_PS_NOW="-" DASH_PS_AVG="-"
  if [ "$DASH_PS_PREV_TICKS" -ge 0 ] && [ "$us" -gt "$DASH_PS_PREV_US" ]; then
    dash_proc_tenths $((ticks - DASH_PS_PREV_TICKS)) $((us - DASH_PS_PREV_US))
    DASH_PS_NOW="$((DASH_TEN / 10)).$((DASH_TEN % 10))%"
  fi
  if [ "$SECONDS" -ge 1 ]; then
    dash_proc_tenths "$ticks" $((SECONDS * 1000000))
    DASH_PS_AVG="$((DASH_TEN / 10)).$((DASH_TEN % 10))%"
  fi
  DASH_PS_PREV_TICKS="$ticks" DASH_PS_PREV_US="$us" DASH_PS_TICKS="$ticks"
  DASH_PS_KIDS=() DASH_PS_KRSS=() DASH_PS_KCMD=()
  for c in "$pr/$me"/task/*/children; do
    line=""
    read -r line 2> /dev/null < "$c" || true
    for k in $line; do
      [ -d "$pr/$k" ] || continue
      dash_proc_info "$k"
      DASH_PS_KIDS+=("$k") DASH_PS_KRSS+=("$DASH_PI_RSS") DASH_PS_KCMD+=("$DASH_PI_CMD")
    done
  done
}

# The command to show: the one the panel is running or, failing that, a recorded run that is going on in another terminal.
dash_procs_root() {
  local f id pid base="$INSTANCES_DIR/.deltactl"
  DASH_PR_PID="" DASH_PR_LABEL=""
  if job_running; then DASH_PR_PID="$JOB_PID" DASH_PR_LABEL="./deltactl $JOB_TITLE"; return 0; fi
  for f in "$base"/active/*; do
    [ -e "$f" ] || continue
    id="${f##*/}" pid=""
    read -r pid 2> /dev/null < "$f" || true
    runs_pid_alive "$pid" || continue
    runs_meta_read "$base/runs/$id" || continue
    DASH_PR_PID="$pid" DASH_PR_LABEL="./deltactl ${RUN[OP]:-?}${RUN[ARGS]:+ ${RUN[ARGS]}}"
    dash_runs_clean DASH_PR_LABEL
    return 0
  done
  return 1
}

# Called every loop: the header card while a command of the panel runs, and the whole view while it is on screen. At most once a
# second while a command runs and once every 2 s otherwise, and the frame is marked dirty only when what is drawn changed.
DASH_PROCS_LAST=-1
dash_procs_tick() {
  local sig card="" iv=2
  if [ "$DASH_VIEW" != "procs" ] && ! job_running; then
    [ -z "$DASH_PC_TXT" ] || { DASH_PC_TXT=""; DASH_DIRTY=1; }
    DASH_PROCS_LAST=-1 DASH_PS_PREV_TICKS=-1   # (the "now" CPU of the next visit must not average the time spent away)
    return 0
  fi
  if job_running; then iv=1; fi
  if [ "$DASH_PROCS_LAST" -ge 0 ]; then
    [ $((SECONDS - DASH_PROCS_LAST)) -ge "$iv" ] || return 0
    [ "$DASH_PAUSED" -eq 0 ] || return 0
  fi
  DASH_PROCS_LAST="$SECONDS"
  if [ "$DASH_VIEW" = "procs" ]; then
    dash_procs_root || true
    if [ -n "$DASH_PR_PID" ]; then dash_proc_tree "$DASH_PR_PID"; else DASH_PT_PID=() DASH_PT_SUM=0 DASH_PT_N=0; fi
    dash_proc_self
  elif job_running; then
    dash_proc_tree "$JOB_PID"
  fi
  if [ "$DASH_PT_N" -gt 0 ] && { job_running || [ "$DASH_VIEW" = "procs" ]; }; then
    runs_fmt_kb "$DASH_PT_SUM"
    dtf tui.procs.card "$DASH_PT_N" "$RUNS_F"; card="$DTF"
  fi
  if job_running && [ "$card" != "$DASH_PC_TXT" ]; then DASH_PC_TXT="$card"; DASH_DIRTY=1; fi
  sig="$DASH_PR_PID|$DASH_PT_SUM|$DASH_PT_N|${DASH_PT_PID[*]-}|$DASH_PS_RSS|$DASH_PS_NOW|$DASH_PS_AVG|${DASH_PS_KIDS[*]-}"
  if [ "$DASH_VIEW" = "procs" ] && [ "$sig" != "$DASH_PROCS_SIG" ]; then
    DASH_PROCS_SIG="$sig"
    DASH_PROCS_N=$((DASH_PROCS_N + 1))
    DASH_DIRTY=1
  fi
}

# --- Drawing --------------------------------------------------------------------------------------------------------------------

dash_procs_tree_box() { # width height
  local w="$1" h="$2" inner i n="${#DASH_PT_PID[@]}" off pad row title mem rows
  local -a body=() foot=()
  inner=$((h - 2))
  dt tui.procs.title; title="$DTV"
  if [ -z "$DASH_PR_PID" ] || [ "$n" -eq 0 ]; then
    dt tui.procs.none; dash_wrap "$DTV" $((w - 4))
    for row in "${DASH_WRAP[@]}"; do body+=(" $C_GRY$row$C_OFF"); done
    tui_box "$title" "$w" "$h" body "" 1
    return 0
  fi
  # Under the processes: a blank line and the total (which can take two lines). What is left is the room for the tree.
  runs_fmt_kb "$DASH_PT_SUM"
  dtf tui.procs.total "$DASH_PT_N" "$RUNS_F"
  dash_wrap "$DTF" $((w - 5))
  for row in "${DASH_WRAP[@]}"; do foot+=(" $C_GRY$row$C_OFF"); done
  rows=$((inner - 2 - ${#foot[@]}))
  dt tui.procs.c.pid; printf -v row '%7s' "$DTV"
  dt tui.procs.c.mem; printf -v pad '%10s' "$DTV"
  dt tui.procs.c.proc
  body+=("$C_GRY$row$pad  $DTV$C_OFF")
  # The first line is the header; the rest scrolls.
  off="$DASH_PROCS_OFF"
  [ "$off" -le $((n - rows)) ] || off=$((n - rows))
  [ "$off" -ge 0 ] || off=0
  DASH_PROCS_OFF="$off"
  for ((i = off; i < n && i < off + rows; i++)); do
    printf -v row '%7s' "${DASH_PT_PID[$i]}"
    if [ "$i" -eq 0 ]; then mem="-"; else runs_fmt_kb "${DASH_PT_RSS[$i]}"; mem="$RUNS_F"; fi
    printf -v pad '%10s' "$mem"
    printf -v mem '%*s' $((DASH_PT_DEP[i] * 2)) ''
    if [ "$i" -eq 0 ]; then body+=("$C_GRY$row$pad$C_OFF  $mem${DASH_PT_CMD[$i]}")
    else body+=("$row$pad  $mem${DASH_PT_CMD[$i]}"); fi
  done
  body+=("" "${foot[@]}")
  title="$DASH_PR_LABEL"
  [ "$off" -eq 0 ] || { dt tui.out.scrolled; title+=" $UI_S_DOT $DTV +$off"; }
  tui_box "$title" "$w" "$h" body "" 1
}

dash_procs_self_box() { # width height
  local w="$1" h="$2" i inner row
  local -a body=()
  inner=$((h - 2))
  runs_fmt_kb "$DASH_PS_RSS"
  dtf tui.procs.self_line "$DASH_SELF_PID" "$RUNS_F" "$DASH_PS_NOW" "$DASH_PS_AVG"
  body+=(" $DTF")
  dtf tui.procs.self_kids "${#DASH_PS_KIDS[@]}"
  body+=(" $C_GRY$DTF$C_OFF")
  for ((i = 0; i < ${#DASH_PS_KIDS[@]} && ${#body[@]} < inner; i++)); do
    printf -v row '%7s' "${DASH_PS_KIDS[$i]}"
    runs_fmt_kb "${DASH_PS_KRSS[$i]}"
    printf -v row '%s%10s  %s' "$row" "$RUNS_F" "${DASH_PS_KCMD[$i]}"
    body+=("$row")
  done
  dt tui.procs.self_title
  tui_box "$DTV" "$w" "$h" body "" 0
}

dash_view_procs() { # body_height
  local bh="$1" sh
  sh=$((bh / 3))
  [ "$sh" -ge 6 ] || sh=6
  [ "$sh" -le 10 ] || sh=10
  [ "$bh" -ge 14 ] || sh=$((bh / 2))
  dash_procs_tree_box "$TUI_COLS" $((bh - sh))
  TUI_FRAME+=("${TUI_BOX[@]}")
  dash_procs_self_box "$TUI_COLS" "$sh"
  TUI_FRAME+=("${TUI_BOX[@]}")
}

dash_key_procs() {
  local page=$((TUI_ROWS / 2))
  case "$1" in
    up | k) [ "$DASH_PROCS_OFF" -le 0 ] || DASH_PROCS_OFF=$((DASH_PROCS_OFF - 1)) ;;
    down | j) DASH_PROCS_OFF=$((DASH_PROCS_OFF + 1)) ;;
    pgup) DASH_PROCS_OFF=$((DASH_PROCS_OFF - page)); [ "$DASH_PROCS_OFF" -ge 0 ] || DASH_PROCS_OFF=0 ;;
    pgdn) DASH_PROCS_OFF=$((DASH_PROCS_OFF + page)) ;;   # clamped to the last process when drawn
    home | g) DASH_PROCS_OFF=0 ;;
  esac
}

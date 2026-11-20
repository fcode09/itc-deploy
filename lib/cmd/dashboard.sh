#!/usr/bin/env bash
# shellcheck disable=SC2034  # the DASH_* and DSV_* variables are shared with lib/cmd/dashboard_view.sh
# The interactive panel: one screen, four views, live figures. It is what ./deltactl and ./deltactl menu open in a
# real terminal; without one (a pipe, a script, TERM=dumb) they keep showing the static home screen and the numbered menu.
#
# Views (1 to 5 or Tab): Instances (list + detail of the selected one + output of the last command), Resources (every
# service with memory, CPU and trend), Output (the full output of the last command, scrollable) and Runs (the history of the
# operations that changed something, lib/cmd/dashboard_runs.sh) and Processes (what the running command is made of and what the
# panel itself costs, lib/cmd/dashboard_procs.sh).
# Commands run in the background inside the panel (lib/core/jobs.sh): the screen keeps updating while they run and
# `:` runs any ./deltactl command. Interactive commands (wizards) run in the terminal and come back.
#
# What keeps it light: it sleeps in `read -t` between keys; the figures come from the kernel through Bash builtins
# (lib/core/metrics.sh); Docker is queried only when it reports an event (or every 30 s as a safety net); and a frame
# is repainted only when something changed, line by line.

# menu_pause (wait for Enter) comes from menu.sh; the terminal layer from tui.sh; HELP_COMMANDS from help.sh
source "$ROOT/lib/cmd/menu.sh"
source "$ROOT/lib/cmd/status.sh"
source "$ROOT/lib/cmd/help.sh"
source "$ROOT/lib/ui/tui.sh"
source "$ROOT/lib/cmd/dashboard_view.sh"
source "$ROOT/lib/cmd/dashboard_runs.sh"
source "$ROOT/lib/cmd/dashboard_procs.sh"
source "$ROOT/lib/cmd/dashboard_logs.sh"

DASH_VIEW=instances       # instances | resources | output | runs | procs
DASH_MODE=normal          # normal | menu | confirm | name | cmd | help
DASH_SEL=0 DASH_SVC=0 DASH_RES_SEL=0 DASH_RES_SORT=name DASH_FOCUS=list DASH_ON_NEW=0
DASH_ZOOM=0 DASH_LOG_SCROLL=0 DASH_LOG_FILTER="" DASH_PAL_Q="" DASH_PAL_SEL=0
DASH_PAL_ALL_L=() DASH_PAL_ALL_A=() DASH_PAL_LABELS=() DASH_PAL_ACTS=() DASH_PAL_RECENT=() PAL_SCORE=0
DASH_OUT_SCROLL=0 DASH_OUT_ERRORS=0
DASH_PAUSED=0 DASH_DIRTY=1 DASH_QUIT=0 DASH_IDLE=0 DASH_SPIN=0 DASH_JOB_PENDING=0
DASH_MSG="" DASH_MSG_KIND=info DASH_MSG_UNTIL=0
DASH_HOST="" DASH_DOCKER_VER=""
DASH_REFRESH_SECONDS="${DELTACTL_REFRESH:-5}"   # without Docker events the state is read this often
DASH_SAFETY_SECONDS=30                           # with events it is still read this often, just in case
DASH_REFRESH_AT=0 DASH_FORCE_REFRESH=0 DASH_EV_PENDING=0 DASH_JOB_DONE=0
DASH_EV_FD="" DASH_EV_PID=""
DASH_NAMES=()
declare -gA DASH_KIND=() DASH_NM=() DASH_DATA=() DASH_SVCS=() DASH_ERRS=() DASH_ERRS_AT=()
declare -gA DSV_KIND=() DSV_TEXT=() DSV_UP=() DSV_PORT=() DSV_REF=() DSV_CODES=() DSV_NOTE=()
DASH_MENU_ITEMS=() DASH_MENU_IDS=() DASH_MENU_SEL=0 DASH_MENU_TITLE="" DASH_MENU_INST="" DASH_MENU_SVC=""
DASH_CONF_TEXT="" DASH_CONF_VIEW="" DASH_CONF_ARGV=() DASH_NAME_TARGET="" DASH_BUF=""
DASH_HIST=() DASH_HIDX=0

# --- Messages ---------------------------------------------------------------------------------------------

dash_msg() { # kind text
  DASH_MSG_KIND="$1" DASH_MSG="$2" DASH_MSG_UNTIL=$((SECONDS + 6)) DASH_DIRTY=1
}

# --- State ------------------------------------------------------------------------------------------------

# Collects the state of every instance (a few queries to Docker) into the DASH_*, DSV_* and ST_* tables of this shell.
dash_collect() {
  local f name svc n m kind key any
  HINTS=() HINT_SEEN=()
  st_collect
  st_load_ports
  DASH_NAMES=() DASH_KIND=() DASH_NM=() DASH_DATA=() DASH_SVCS=()
  DSV_KIND=() DSV_TEXT=() DSV_UP=() DSV_PORT=() DSV_REF=() DSV_CODES=() DSV_NOTE=()
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    name="$(basename "$(dirname "$f")")"
    st_enabled "$name"
    st_instance_hints "$name"
    n=0 m="${#ST_ENABLED[@]}" any=0
    for svc in ${ST_ENABLED[@]+"${ST_ENABLED[@]}"}; do
      key="$name/$svc"
      st_eval "$name" "$svc"
      st_notes "$name" "$svc"
      [ "$E_KIND" != "ok" ] || n=$((n + 1))
      DSV_KIND[$key]="$E_KIND" DSV_TEXT[$key]="$E_TEXT" DSV_UP[$key]="$E_UP" DSV_PORT[$key]="$E_PORT"
      DSV_REF[$key]="$E_REF" DSV_CODES[$key]="$E_CODES"
      case " $E_CODES " in *" tag-drift "*) DSV_NOTE[$key]="$(t tui.tag_drift "$E_RUN" "$E_CFG")" ;; esac
    done
    for key in "${!ST_STATE[@]}"; do [ "${key%%/*}" != "$name" ] || any=1; done
    if [ "$ST_DOCKER" -ne 1 ]; then kind=dim
    elif [ "$m" -eq 0 ]; then kind=err
    elif [ "$n" -eq "$m" ]; then kind=ok
    elif [ "$n" -gt 0 ]; then kind=warn
    elif [ "$any" -eq 1 ]; then kind=err
    else kind=dim; fi
    DASH_NAMES+=("$name")
    DASH_KIND[$name]="$kind"
    if [ "$ST_DOCKER" -eq 1 ]; then DASH_NM[$name]="$n/$m"; else DASH_NM[$name]="?/$m"; fi
    DASH_SVCS[$name]="${ST_ENABLED[*]:-}"
    DASH_DATA[$name]="$(data_state "$name")"
  done
  if [ "$ST_DOCKER" -eq 1 ] && [ -z "$DASH_DOCKER_VER" ]; then DASH_DOCKER_VER="$(dk_info ServerVersion)"; fi
}

# What the panel does once fresh data is in place.
dash_after_collect() {
  [ "$DASH_SEL" -lt "${#DASH_NAMES[@]}" ] || DASH_SEL=$((${#DASH_NAMES[@]} - 1))
  [ "$DASH_SEL" -ge 0 ] || DASH_SEL=0
  # With no instance the only thing to select is the New button; the services have no focus when there are none.
  if [ "${#DASH_NAMES[@]}" -eq 0 ]; then DASH_ON_NEW=1 DASH_FOCUS=list; fi
  [ "$ST_DOCKER" -ne 1 ] || DK_READY_AT="$SECONDS"
  DASH_REFRESH_AT="$SECONDS" DASH_FORCE_REFRESH=0 DASH_REFRESH_N=$((DASH_REFRESH_N + 1))
  # The pids may have changed: read the figures again at the next tick.
  MT_LAST_US=0
  DASH_DIRTY=1
}

# Synchronous refresh (start-up, the test mode).
dash_refresh() {
  DASH_EV_PENDING=0
  dash_collect
  dash_after_collect
}

# Counts the error lines of the last 10 minutes of the running services of an instance (one `docker logs` each).
# It prints "<instance/service> <count>" lines.
dash_errors_collect() { # instance
  local name="$1" svc key
  for svc in ${DASH_SVCS[$name]:-}; do
    key="$name/$svc"
    if [ "${ST_STATE[$key]:-}" = "running" ]; then printf '%s %s\n' "$key" "$(dk_log_error_count "${ST_CNAME[$key]}")"; fi
  done
}

dash_errors_apply() { # instance text
  local name="$1" key n line
  for key in "${!DASH_ERRS[@]}"; do [ "${key%%/*}" != "$name" ] || unset "DASH_ERRS[$key]"; done
  while read -r key n; do
    [ -n "$key" ] && [[ "$n" =~ ^[0-9]+$ ]] && DASH_ERRS[$key]="$n"
  done <<< "$2"
  DASH_ERRS_AT[$name]="$SECONDS" DASH_ERRS_N=$((DASH_ERRS_N + 1))
  DASH_DIRTY=1
}

dash_errors_refresh() { # instance (synchronous)
  dash_errors_apply "$1" "$(dash_errors_collect "$1")"
}

# The last lines of a service's log, for the logs box. Collected in the background every few seconds while the box is visible.
declare -gA DASH_LOGS=() DASH_LOGS_AT=()
DASH_LOGS_N=0
dash_logs_collect() { # key [lines]
  [ -n "${ST_CNAME[$1]:-}" ] || return 0
  dk_logs_tail "${ST_CNAME[$1]}" "${2:-80}"
}
dash_logs_apply() { # key text  (each line is cleaned once, here, not at every frame)
  local line out="" n=0
  while IFS= read -r line; do
    tui_strip_ansi "$line"
    out+="$TUI_OUT"$'\n'
    n=$((n + 1))
  done <<< "$2"
  DASH_LOGS[$1]="${out%$'\n'}" DASH_LOGS_AT[$1]="$SECONDS" DASH_LOGS_N=$((DASH_LOGS_N + 1))
  DASH_DIRTY=1
}
dash_logs_request() { # key
  if tui_test_mode; then dash_logs_apply "$1" "$(dash_logs_collect "$1")"; return 0; fi
  # A pane that is being read (focused or zoomed) asks for a longer tail than the small box of the Overview.
  local n=80
  { [ "$DASH_FOCUS" = "logs" ] || [ "$DASH_ZOOM" -eq 1 ]; } && n=400
  dash_async logs "$1" dash_logs_collect "$1" "$n" || true
}

# --- Background work ----------------------------------------------------------------------------------------
# Querying Docker takes a moment (from tens of milliseconds to seconds on a loaded host). The panel never waits for it: a
# producer runs in a background process, writes its result to a file, and the loop picks it up on a later tick.

declare -gA DASH_AS_PID=() DASH_AS_FILE=() DASH_AS_AT=() DASH_AS_ARG=()
DASH_AS_SEQ=0 DASH_AS_TEXT=""

# dash_async <slot> <argument> <function> [args...]: runs the function in the background. Fails if the slot is busy.
dash_async() {
  local slot="$1" arg="$2"
  shift 2
  [ -z "${DASH_AS_PID[$slot]:-}" ] || return 1
  job_init
  DASH_AS_SEQ=$((DASH_AS_SEQ + 1))
  DASH_AS_FILE[$slot]="$JOB_DIR/as.$slot.$DASH_AS_SEQ"
  DASH_AS_ARG[$slot]="$arg" DASH_AS_AT[$slot]="$SECONDS"
  ( "$@" > "${DASH_AS_FILE[$slot]}.tmp" 2> /dev/null && mv "${DASH_AS_FILE[$slot]}.tmp" "${DASH_AS_FILE[$slot]}" ) &
  DASH_AS_PID[$slot]=$!
}

# dash_async_take <slot>: when the result is ready it is left in DASH_AS_TEXT and the call returns 0.
dash_async_take() {
  local slot="$1" f pid
  f="${DASH_AS_FILE[$slot]:-}" pid="${DASH_AS_PID[$slot]:-}"
  [ -n "$pid" ] || return 1
  if [ -f "$f" ]; then
    wait "$pid" 2> /dev/null
    DASH_AS_TEXT="$(<"$f")"
    rm -f "$f"
    DASH_AS_PID[$slot]=""
    return 0
  fi
  # A producer that died, or that has been stuck for a minute, is forgotten.
  if ! kill -0 "$pid" 2> /dev/null; then
    DASH_AS_PID[$slot]=""
  elif [ $((SECONDS - DASH_AS_AT[$slot])) -ge 60 ]; then
    kill "$pid" 2> /dev/null
    DASH_AS_PID[$slot]=""
  fi
  return 1
}

dash_async_stop() {
  local slot
  for slot in "${!DASH_AS_PID[@]}"; do
    [ -z "${DASH_AS_PID[$slot]}" ] || kill "${DASH_AS_PID[$slot]}" 2> /dev/null || true
    DASH_AS_PID[$slot]=""
  done
}

# The state producer prints the tables as `declare -p` lines.
dash_state_dump() {
  dash_collect
  declare -p ST_DOCKER ST_STATE ST_HEALTH ST_CIMAGE ST_STARTED ST_CNAME ST_PID ST_RESTARTS ST_IMG ST_IMG_LOADED ST_PORTS \
    HINT_SEEN HINTS DASH_NAMES DASH_KIND DASH_NM DASH_DATA DASH_SVCS DSV_KIND DSV_TEXT DSV_UP DSV_PORT DSV_REF DSV_CODES \
    DSV_NOTE DASH_DOCKER_VER
}

# Loads the `declare -p` lines into the global tables.
dash_state_apply() { # text
  local line
  while IFS= read -r line; do
    case "$line" in declare\ *) eval "declare -g${line#declare}" ;; esac
  done <<< "$1"
  dash_after_collect
}

# Asks for a state refresh without waiting for it (the synchronous one in the test mode).
dash_refresh_request() {
  if tui_test_mode; then dash_refresh; return 0; fi
  DASH_REFRESH_WANT=1
}
DASH_REFRESH_WANT=0

# Error counts of an instance, in the background (the synchronous one in the test mode).
dash_errors_request() { # instance
  if tui_test_mode; then dash_errors_refresh "$1"; return 0; fi
  dash_async errors "$1" dash_errors_collect "$1" || true
}

# Starts what was asked and applies what finished. Returns 0 when something was applied.
dash_async_tick() {
  local changed=1
  if [ "$DASH_REFRESH_WANT" -eq 1 ] && [ -z "${DASH_AS_PID[state]:-}" ]; then
    DASH_REFRESH_WANT=0 DASH_EV_PENDING=0
    dash_async state "" dash_state_dump
  fi
  if dash_async_take state; then dash_state_apply "$DASH_AS_TEXT"; changed=0; fi
  if dash_async_take errors; then dash_errors_apply "${DASH_AS_ARG[errors]}" "$DASH_AS_TEXT"; changed=0; fi
  if dash_async_take logs; then dash_logs_apply "${DASH_AS_ARG[logs]}" "$DASH_AS_TEXT"; changed=0; fi
  if dash_async_take rvidx; then dash_runs_log_index "${DASH_AS_ARG[rvidx]}" "$DASH_AS_TEXT"; changed=0; fi
  return "$changed"
}

# --- Docker events ----------------------------------------------------------------------------------------

# Opens the stream of Docker events (a coprocess). In the test mode DELTACTL_TUI_EVENTS may point to a file.
dash_events_start() {
  if tui_test_mode; then
    [ -z "${DELTACTL_TUI_EVENTS:-}" ] || { exec {DASH_EV_FD}< "$DELTACTL_TUI_EVENTS"; }
    return 0
  fi
  [ "$ST_DOCKER" -eq 1 ] || return 0
  coproc DASH_EV { dk_events_stream; }
  DASH_EV_FD="${DASH_EV[0]}"
}

# Reads the events that arrived (without waiting). Returns 0 when there were some. When the stream ends, the panel falls
# back to reading the state at intervals.
# Keeps an event as "epoch|name|action" in a ring for the events feed. Lines without that shape (the test mode feeds bare
# actions) count as events of an unknown container, now.
DASH_EVENTS=() DASH_EV_N=0 DASH_EV_MAX=200
dash_event_add() { # line
  local ep name act rest inst known=0
  if [[ "$1" == *"|"*"|"* ]]; then
    ep="${1%%|*}"; rest="${1#*|}"; name="${rest%%|*}"; act="${rest#*|}"
  else
    ep="" name="-" act="$1"
  fi
  # Docker reports every container of the machine: the feed keeps those that belong to an instance of this installation
  # (their names carry the instance name, like s0_colorado).
  if [ "$name" != "-" ] && [ "${#DASH_NAMES[@]}" -gt 0 ]; then
    for inst in "${DASH_NAMES[@]}"; do
      case "$name" in *"$inst"*) known=1; break ;; esac
    done
    [ "$known" -eq 1 ] || return 0
  fi
  [[ "$ep" =~ ^[0-9]+$ ]] || printf -v ep '%(%s)T' -1
  DASH_EVENTS+=("$ep|$name|$act")
  if [ "${#DASH_EVENTS[@]}" -gt "$DASH_EV_MAX" ]; then DASH_EVENTS=("${DASH_EVENTS[@]:50}"); fi
  DASH_EV_N=$((DASH_EV_N + 1))
}

# Docker keeps no history of events for long, so a fresh panel would show an empty feed: it starts with one `start` entry per
# running container, dated from the container's own start time.
dash_events_seed() {
  local key up now row name svc
  local -a rows=()
  [ "${#DASH_EVENTS[@]}" -eq 0 ] || return 0
  printf -v now '%(%s)T' -1
  for name in "${DASH_NAMES[@]}"; do
    for svc in ${DASH_SVCS[$name]:-}; do
      key="$name/$svc"
      [ "${ST_STATE[$key]:-}" = "running" ] || continue
      up="$(st_uptime_secs "${ST_STARTED[$key]:-}" 2> /dev/null || true)"
      [[ "$up" =~ ^[0-9]+$ ]] || continue
      rows+=("$((now - up))|${ST_CNAME[$key]#/}|start")
    done
  done
  [ "${#rows[@]}" -gt 0 ] || return 0
  while IFS= read -r row; do dash_event_add "$row"; done < <(printf '%s\n' "${rows[@]}" | sort -n)
}

dash_events_drain() {
  local got=1 line
  [ -n "$DASH_EV_FD" ] || return 1
  while read -r -t 0 -u "$DASH_EV_FD" 2>/dev/null; do
    if read -r -t 0.05 -u "$DASH_EV_FD" line; then
      got=0
      dash_event_add "$line"
    else
      DASH_EV_FD=""
      tui_test_mode || dash_msg warn "$(t tui.msg.events_off)"
      break
    fi
  done
  return "$got"
}

dash_shutdown() {
  tui_leave
  theme_restore
  [ -z "$DASH_EV_PID" ] || kill "$DASH_EV_PID" 2>/dev/null || true
  dash_runs_log_cancel_scan
  dash_ls_stop
  dash_async_stop
  DASH_EV_PID=""
  job_cleanup
}

# --- Running commands ---------------------------------------------------------------------------------------

# Starts ./deltactl <args> in the background. $1 = output (jump to the Output view) or stay (keep the view).
dash_start_job() { # view args...
  local view="$1" color=never
  shift
  if job_running; then dash_msg warn "$(t tui.msg.busy)"; return 1; fi
  [ "$UI_COLOR" -ne 1 ] || color=always
  job_start "$*" env COLUMNS=$((TUI_COLS - 4)) DELTACTL_UI=rich DELTACTL_COLOR="$color" \
    DELTACTL_LANG="${DELTACTL_LANG_ACTIVE:-es}" "$ROOT/deltactl" "$@"
  DASH_OUT_SCROLL=0 DASH_JOB_DONE=0
  # The console keeps what was run and what it printed (dash_con_mirror copies the output as it arrives).
  dash_prompt_name
  dash_con_add "${TH[accent]:-$C_CYN}$DASH_PN $(dash_prompt_glyph)$C_OFF ./deltactl $*"
  DASH_CON_SEQ="$JOB_SEQ" DASH_CON_COPIED=0
  [ "$view" != "output" ] || DASH_VIEW=output
  dash_msg info "$(t tui.msg.started "$*")"
}

# Runs ./deltactl <args> in the terminal (for wizards that ask questions) and comes back to the panel.
dash_terminal() { # args...
  dash_msg info "$(t tui.msg.terminal "$*")"
  tui_leave
  printf '\n  %s%s ./deltactl %s%s\n\n' "$C_GRY" "$UI_S_ARROW" "$*" "$C_OFF"
  dash_prompt_name
  dash_con_add "${TH[accent]:-$C_CYN}$DASH_PN $(dash_prompt_glyph)$C_OFF ./deltactl $*"
  "$ROOT/deltactl" "$@" || printf '\n  %s %s\n' "$(ui_sym err)" "$(t menu.cmd_failed "$?")"
  menu_pause
  tui_enter
  DASH_SIGINT=0                      # a Ctrl+C meant for the command must not reach the panel
  dash_refresh_request
}

# Notices that the command ended: message, and a state refresh because it probably changed something.
dash_job_tick() {
  local secs
  if job_poll; then DASH_JOB_PENDING=1; dash_con_mirror; fi
  if job_running; then
    # The loop wakes up every 0.2 s to read the output, but the screen is redrawn every other wake-up (0.4 s): new lines and
    # the spinner are coalesced, which halves the cost of following a chatty command.
    DASH_SPIN=$((DASH_SPIN + 1))
    if [ $((DASH_SPIN % 2)) -eq 0 ]; then DASH_DIRTY=1 DASH_JOB_PENDING=0; fi
    return 0
  fi
  # The command ended (or was never started): whatever was waiting is drawn now.
  if [ "$DASH_JOB_PENDING" -eq 1 ]; then DASH_DIRTY=1 DASH_JOB_PENDING=0; fi
  if [ -n "$JOB_PID" ] && [ -n "$JOB_RC" ] && [ "$DASH_JOB_DONE" != "$JOB_SEQ" ]; then
    DASH_JOB_DONE="$JOB_SEQ"
    dash_job_secs; secs="$DASH_JS"
    dash_con_mirror
    if [ "$JOB_CANCELLED" -eq 1 ]; then dash_msg warn "$(t tui.msg.cancelled)"; dash_con_add "${DASH_SYM[warn]} $(t tui.msg.cancelled)"
    elif [ "$JOB_RC" -eq 0 ]; then
      dash_msg ok "$(t tui.msg.finished_ok "./deltactl $JOB_TITLE" "$secs")"
      dash_con_add "${DASH_SYM[ok]} $(t tui.msg.finished_ok "./deltactl $JOB_TITLE" "$secs")"
    else
      dash_msg err "$(t tui.msg.finished_err "./deltactl $JOB_TITLE" "$JOB_RC" "$secs")"
      dash_con_add "${DASH_SYM[err]} $(t tui.msg.finished_err "./deltactl $JOB_TITLE" "$JOB_RC" "$secs")"
    fi
    dash_refresh_request
    DASH_RUNS_AT=-1000   # the command left a run: the Runs view reads the history again
  fi
}

# --- Periodic work ----------------------------------------------------------------------------------------

dash_tick() {
  local interval
  dash_job_tick
  if dash_events_drain; then DASH_EV_PENDING=1; fi
  # What finished in the background is applied at once, even while paused (it was already asked for).
  if dash_async_tick; then DASH_DIRTY=1; fi
  dash_runs_tick
  dash_procs_tick
  dash_ls_tick
  if [ "$DASH_PAUSED" -eq 0 ]; then
    if [ -n "$DASH_EV_FD" ]; then interval="$DASH_SAFETY_SECONDS"; else interval="$DASH_REFRESH_SECONDS"; fi
    if [ "$DASH_EV_PENDING" -eq 1 ] || [ $((SECONDS - DASH_REFRESH_AT)) -ge "$interval" ]; then
      # In the test mode (synchronous) it waits for an idle tick, so a key press never blocks on Docker.
      if ! tui_test_mode || [ "$DASH_IDLE" -eq 1 ]; then dash_refresh_request; fi
    fi
    case "$DASH_VIEW" in output | runs | procs) MT_INTERVAL_MULT=2 ;; *) MT_INTERVAL_MULT=1 ;; esac
    if mt_due; then
      mt_sample
      dash_host_build
      DASH_DIRTY=1
    fi
    # The log tail of the selected service: only while the overview shows it, and every 5 s.
    if [ "$DASH_VIEW" = "instances" ] && dash_overview_fits && dash_current_target; then
      local lk="$DASH_T_INST/$DASH_T_SVC"
      # While the user reads older lines the log stands still (no new request); a focused pane refreshes faster.
      local every=5
      [ "$DASH_FOCUS" != "logs" ] || every=3
      # (a stream feeds the pane when there is one; paused, the pane stands still)
      if [ "${ST_STATE[$lk]:-}" = "running" ] && [ "$DASH_LOG_SCROLL" -eq 0 ] && [ "$DASH_LS_PAUSED" -eq 0 ] && ! dash_ls_active "$lk" && { [ -z "${DASH_LOGS_AT[$lk]:-}" ] || [ $((SECONDS - DASH_LOGS_AT[$lk])) -ge "$every" ]; }; then
        dash_logs_request "$lk"
      fi
    fi
    # Error counts of the selected instance: when the user pauses on it, then every 30 s.
    if [ "$DASH_IDLE" -eq 1 ] && [ "$DASH_VIEW" = "instances" ] && [ "$DASH_ON_NEW" -eq 0 ] && [ "${#DASH_NAMES[@]}" -gt 0 ]; then
      local sel="${DASH_NAMES[$DASH_SEL]}"
      if [ -z "${DASH_ERRS_AT[$sel]:-}" ] || [ $((SECONDS - DASH_ERRS_AT[$sel])) -ge 30 ]; then dash_errors_request "$sel"; fi
    fi
  fi
  if [ -n "$DASH_MSG" ] && [ "$SECONDS" -ge "$DASH_MSG_UNTIL" ]; then DASH_MSG=""; DASH_DIRTY=1; fi
}

# --- Actions of an instance -------------------------------------------------------------------------------

dash_open_actions() { # instance
  local inst="$1" svc id
  local -a svcs
  read -ra svcs <<< "${DASH_SVCS[$inst]:-}"
  if [ "${#svcs[@]}" -eq 0 ]; then dash_msg warn "$(t tui.msg.no_service)"; return 0; fi
  svc="${svcs[$DASH_SVC]:-${svcs[0]}}"
  DASH_MENU_INST="$inst" DASH_MENU_SVC="$svc"
  DASH_MENU_IDS=(status check deploy_all deploy_svc rollback logs_live logs_recent stop_svc down)
  [ "${DASH_DATA[$inst]:-}" != "unseeded" ] || DASH_MENU_IDS+=(init)
  DASH_MENU_IDS+=(help)
  DASH_MENU_ITEMS=()
  for id in "${DASH_MENU_IDS[@]}"; do DASH_MENU_ITEMS+=("$(t "tui.act.$id" "$svc")"); done
  DASH_MENU_TITLE="$(t tui.actions_title "$inst" "${DASH_NM[$inst]:-}")"
  DASH_MENU_SEL=0
  DASH_MODE=menu
}

# Asks yes/no inside the panel and then runs ./deltactl <args>.
dash_confirm() { # text view args...
  DASH_CONF_TEXT="$1" DASH_CONF_VIEW="$2"
  shift 2
  DASH_CONF_ARGV=("$@")
  DASH_MODE=confirm
}

dash_menu_run() {
  local id="${DASH_MENU_IDS[$DASH_MENU_SEL]}" inst="$DASH_MENU_INST" svc="$DASH_MENU_SVC"
  DASH_MODE=normal
  case "$id" in
    status) dash_start_job output status "$inst" ;;
    check) dash_start_job stay check "$inst" ;;
    deploy_all) dash_start_job stay deploy "$inst" ;;
    deploy_svc) dash_start_job stay deploy "$inst" "$svc" ;;
    rollback) dash_confirm "$(t menu.confirm_rollback "$(t menu.all_the_services)" "$inst")" stay rollback "$inst" --yes ;;
    logs_live) dash_start_job output logs "$inst" "$svc" -f ;;
    logs_recent) dash_start_job output logs "$inst" "$svc" ;;
    stop_svc) dash_confirm "$(t tui.confirm_stop "$svc" "$inst")" stay stop "$inst" "$svc" ;;
    down) dash_confirm "$(t menu.confirm_down "$inst")" stay down "$inst" --yes ;;
    init) DASH_NAME_TARGET="$inst" DASH_BUF="" DASH_CUR=0 DASH_MODE=name ;;
    help) dash_start_job output help status ;;
  esac
}

# --- Keys ------------------------------------------------------------------------------------------------

# The list of instances has one more position than instances: the "New instance" button, at the top. Up and down walk the
# whole ring (button, instance 1, ..., instance n, button).
dash_select() { # delta
  local n="${#DASH_NAMES[@]}" pos
  if [ "$DASH_ON_NEW" -eq 1 ]; then pos=0; else pos=$((DASH_SEL + 1)); fi
  pos=$(((pos + n + 1 + $1) % (n + 1)))
  if [ "$pos" -eq 0 ]; then
    DASH_ON_NEW=1
  else
    DASH_ON_NEW=0 DASH_SEL=$((pos - 1))
  fi
  DASH_SVC=0 DASH_DET_OFF=0 DASH_FOCUS=list
}

dash_select_service() { # delta
  local -a svcs
  [ "$DASH_ON_NEW" -eq 0 ] && [ "${#DASH_NAMES[@]}" -gt 0 ] || return 0
  read -ra svcs <<< "${DASH_SVCS[${DASH_NAMES[$DASH_SEL]}]:-}"
  [ "${#svcs[@]}" -gt 0 ] || return 0
  DASH_SVC=$(((DASH_SVC + ${#svcs[@]} + $1) % ${#svcs[@]}))
}

# Right arrow: the focus goes from the list of instances into the services of the selected instance.
dash_focus_services() {
  local -a svcs
  [ "$DASH_ON_NEW" -eq 0 ] && [ "${#DASH_NAMES[@]}" -gt 0 ] || return 0
  read -ra svcs <<< "${DASH_SVCS[${DASH_NAMES[$DASH_SEL]}]:-}"
  [ "${#svcs[@]}" -gt 0 ] || return 0
  DASH_FOCUS=svc
}

# Service of the selected instance as "instance service" (empty when there is none).
dash_current_target() {
  local name svc
  local -a svcs
  [ "$DASH_ON_NEW" -eq 0 ] || return 1
  [ "${#DASH_NAMES[@]}" -gt 0 ] || return 1
  name="${DASH_NAMES[$DASH_SEL]}"
  read -ra svcs <<< "${DASH_SVCS[$name]:-}"
  [ "${#svcs[@]}" -gt 0 ] || return 1
  svc="${svcs[$DASH_SVC]:-${svcs[0]}}"
  DASH_T_INST="$name" DASH_T_SVC="$svc"
}
DASH_T_INST="" DASH_T_SVC=""

dash_toggle_language() {
  local next=en
  [ "${DELTACTL_LANG_ACTIVE:-es}" != "en" ] || next=es
  i18n_save_lang "$next"
  DELTACTL_LANG="$next"
  export DELTACTL_LANG
  i18n_init
  dash_texts_build
  DASH_LANG_N=$((DASH_LANG_N + 1))
  dash_refresh_request
  dash_host_build
  dash_msg info "$(t tui.msg.lang_set "$(t tui.lang_name)")"
}

# Next theme (T): applied at once and remembered in the config file.
dash_theme_refresh() {
  DASH_BARS=() DASH_KB=()          # remembered pieces carry the old colours
  dash_symbols_init
  dash_texts_build
  DASH_LANG_N=$((DASH_LANG_N + 1)) # makes the cached body build again
  dash_host_build
  TUI_FORCE=1                      # repaint everything, background included
}
dash_cycle_theme() {
  th_next
  theme_apply "$TH_NEXT" || return 0
  th_save "$TH_NEXT"
  dash_theme_refresh
  dash_msg info "$(t tui.msg.theme_set "$TH_NAME")"
}

# Keys that work in every view.
dash_key_global() { # key ; returns 0 when handled
  case "$1" in
    q) DASH_QUIT=1 ;;
    esc)
      if [ "$DASH_VIEW" = "runs" ] && [ "$DASH_RUNS_MODE" != "list" ]; then DASH_RUNS_MODE=list   # the statistics first
      elif [ "$DASH_VIEW" != "instances" ]; then DASH_VIEW=instances
      elif [ "$DASH_ZOOM" -eq 1 ]; then DASH_ZOOM=0           # the zoom first
      elif [ "$DASH_FOCUS" != "list" ]; then DASH_FOCUS=list  # then one step back, like the left arrow
      else DASH_QUIT=1; fi
      ;;
    1) DASH_VIEW=instances ;;
    2) DASH_VIEW=resources ;;
    3) DASH_VIEW=output ;;
    4) DASH_VIEW=runs ;;
    5) DASH_VIEW=procs ;;
    tab)
      case "$DASH_VIEW" in instances) dash_focus_cycle 1 ;; resources) DASH_VIEW=output ;; output) DASH_VIEW=runs ;; runs) DASH_VIEW=procs ;; *) DASH_VIEW=instances ;; esac
      ;;
    btab)
      case "$DASH_VIEW" in instances) dash_focus_cycle -1 ;; resources) DASH_VIEW=instances ;; output) DASH_VIEW=resources ;; runs) DASH_VIEW=output ;; *) DASH_VIEW=runs ;; esac
      ;;
    $'\020') dash_open_palette ;;                                    # Ctrl+P
    '?') DASH_MODE=help ;;
    L) dash_toggle_language ;;
    T) dash_cycle_theme ;;
    r) dash_refresh_request; DASH_ERRS_AT=(); DASH_RUNS_AT=-1000; dash_msg info "$(t tui.msg.refreshed)" ;;
    p)
      if [ "$DASH_PAUSED" -eq 0 ]; then DASH_PAUSED=1; dash_msg info "$(t tui.msg.paused)"; else DASH_PAUSED=0; dash_msg info "$(t tui.msg.resumed)"; fi
      ;;
    x)
      if job_cancel; then dash_msg warn "$(t tui.msg.cancelling)"; else dash_msg info "$(t tui.msg.nothing_running)"; fi
      ;;
    ':') DASH_MODE=cmd DASH_BUF="" DASH_CUR=0 DASH_HIDX="${#DASH_HIST[@]}" ;;
    '!') DASH_MODE=cmd DASH_BUF="!" DASH_CUR=1 DASH_HIDX="${#DASH_HIST[@]}" ;;
    n) dash_terminal new --wizard ;;
    d) dash_start_job output doctor ;;
    i) dash_start_job output images ;;
    *) return 1 ;;
  esac
}

# Two places can have the focus: the list of instances (up/down choose an instance; right enters its services) and the services
# of the selected instance (up/down choose a service; left or Esc go back to the list). The first row of the list is the
# "New instance" button.
dash_key_instances() {
  local have=1
  { [ "$DASH_ON_NEW" -eq 0 ] && [ "${#DASH_NAMES[@]}" -gt 0 ]; } || have=0
  if [ "$DASH_FOCUS" = "logs" ] && dash_key_logs "$1"; then return 0; fi
  case "$1" in
    z) dash_toggle_zoom ;;
    up | k) if [ "$DASH_FOCUS" = "svc" ]; then dash_select_service -1; else dash_select -1; fi ;;
    down | j) if [ "$DASH_FOCUS" = "svc" ]; then dash_select_service 1; else dash_select 1; fi ;;
    left | h) DASH_FOCUS=list ;;
    right) if [ "$DASH_FOCUS" = "svc" ]; then dash_focus_logs; else dash_focus_services; fi ;;
    enter)
      if [ "$DASH_ON_NEW" -eq 1 ]; then dash_terminal new --wizard
      elif [ "$have" -eq 1 ]; then dash_open_actions "${DASH_NAMES[$DASH_SEL]}"; fi
      ;;
    l) [ "$have" -eq 0 ] || { dash_current_target && dash_start_job output logs "$DASH_T_INST" "$DASH_T_SVC" -f; } ;;
    u) [ "$have" -eq 0 ] || dash_start_job stay deploy "${DASH_NAMES[$DASH_SEL]}" ;;
    c) [ "$have" -eq 0 ] || dash_start_job stay check "${DASH_NAMES[$DASH_SEL]}" ;;
    s) [ "$have" -eq 0 ] || dash_start_job output status "${DASH_NAMES[$DASH_SEL]}" ;;
    e) [ "$have" -eq 0 ] || dash_errors_request "${DASH_NAMES[$DASH_SEL]}" ;;
  esac
}

dash_key_resources() {
  local key inst svc i name s
  case "$1" in
    up | k) [ "$DASH_RES_SEL" -le 0 ] || DASH_RES_SEL=$((DASH_RES_SEL - 1)) ;;
    down | j) DASH_RES_SEL=$((DASH_RES_SEL + 1)) ;;
    pgup) DASH_RES_SEL=$((DASH_RES_SEL - 10)); [ "$DASH_RES_SEL" -ge 0 ] || DASH_RES_SEL=0 ;;
    pgdn) DASH_RES_SEL=$((DASH_RES_SEL + 10)) ;;
    s)
      case "$DASH_RES_SORT" in name) DASH_RES_SORT=mem ;; mem) DASH_RES_SORT=cpu ;; *) DASH_RES_SORT=name ;; esac
      ;;
    enter)
      dash_res_rows
      key="${DASH_RES_KEYS[$DASH_RES_SEL]:-}"
      [ -n "$key" ] || return 0
      inst="${key%%/*}" svc="${key#*/}"
      for i in "${!DASH_NAMES[@]}"; do
        [ "${DASH_NAMES[$i]}" != "$inst" ] || DASH_SEL="$i"
      done
      DASH_SVC=0 s=0
      for name in ${DASH_SVCS[$inst]:-}; do
        [ "$name" != "$svc" ] || DASH_SVC="$s"
        s=$((s + 1))
      done
      DASH_DET_OFF=0 DASH_VIEW=instances DASH_ON_NEW=0 DASH_FOCUS=svc
      ;;
  esac
}

dash_key_output() {
  local page=$((TUI_ROWS - 7))
  [ "$page" -ge 3 ] || page=3
  case "$1" in
    up | k) DASH_OUT_SCROLL=$((DASH_OUT_SCROLL + 1)) ;;
    down | j) [ "$DASH_OUT_SCROLL" -le 0 ] || DASH_OUT_SCROLL=$((DASH_OUT_SCROLL - 1)) ;;
    pgup) DASH_OUT_SCROLL=$((DASH_OUT_SCROLL + page)) ;;
    pgdn) DASH_OUT_SCROLL=$((DASH_OUT_SCROLL - page)); [ "$DASH_OUT_SCROLL" -ge 0 ] || DASH_OUT_SCROLL=0 ;;
    home | g) DASH_OUT_SCROLL=100000 ;;
    end | G | f) DASH_OUT_SCROLL=0 ;;
    e) DASH_OUT_ERRORS=$((1 - DASH_OUT_ERRORS)); DASH_OUT_SCROLL=0 ;;
  esac
  # Do not scroll past the first line.
  [ "$DASH_OUT_SCROLL" -le "${#JOB_LINES[@]}" ] || DASH_OUT_SCROLL="${#JOB_LINES[@]}"
}

dash_key_menu() {
  local n="${#DASH_MENU_ITEMS[@]}"
  case "$1" in
    up | k) DASH_MENU_SEL=$(((DASH_MENU_SEL + n - 1) % n)) ;;
    down | j) DASH_MENU_SEL=$(((DASH_MENU_SEL + 1) % n)) ;;
    enter | right) dash_menu_run ;;
    esc | left | q | backspace) DASH_MODE=normal ;;
  esac
}

dash_key_confirm() {
  local argv=("${DASH_CONF_ARGV[@]}")
  DASH_MODE=normal
  case "$1" in
    y | Y | s | S) dash_start_job "$DASH_CONF_VIEW" "${argv[@]}" ;;
    *) dash_msg info "$(t tui.msg.cancelled)" ;;
  esac
}

# --- Panes: focus ring, zoom, logs, palette ------------------------------------------------------------------------------
# The Overview has up to three panes that take the keyboard: the instances, the services of the selected instance and its logs.
# Tab / Shift+Tab walk them, `z` zooms the focused one to the whole body (Esc comes back), and Ctrl+P opens a palette of actions.

dash_focus_cycle() { # +1 | -1
  local -a order=(list)
  local i cur=0 n
  { [ "$DASH_ON_NEW" -eq 0 ] && [ "${#DASH_NAMES[@]}" -gt 0 ]; } || { DASH_FOCUS=list; return 0; }
  order+=(svc)
  if dash_overview_fits; then order+=(logs); fi
  n="${#order[@]}"
  for i in "${!order[@]}"; do [ "${order[$i]}" != "$DASH_FOCUS" ] || cur="$i"; done
  DASH_FOCUS="${order[$(((cur + n + $1) % n))]}"
}

# Right arrow from the services: on to the logs (they only exist on the wide layout).
dash_focus_logs() { if dash_overview_fits; then DASH_FOCUS=logs; fi; }

dash_toggle_zoom() {
  [ "$DASH_VIEW" = "instances" ] || return 0
  if [ "$DASH_FOCUS" = "logs" ] && ! dash_overview_fits; then return 0; fi
  DASH_ZOOM=$((1 - DASH_ZOOM))
}

# Keys of the logs pane: scroll by line or page, Home/End, `/` to filter. Returns 0 when it handled the key.
dash_key_logs() { # key
  local page=$((TUI_ROWS / 2))
  case "$1" in
    up | k) DASH_LOG_SCROLL=$((DASH_LOG_SCROLL + 1)) ;;
    down | j) [ "$DASH_LOG_SCROLL" -le 0 ] || DASH_LOG_SCROLL=$((DASH_LOG_SCROLL - 1)) ;;
    pgup) DASH_LOG_SCROLL=$((DASH_LOG_SCROLL + page)) ;;
    pgdn) DASH_LOG_SCROLL=$((DASH_LOG_SCROLL - page)); [ "$DASH_LOG_SCROLL" -ge 0 ] || DASH_LOG_SCROLL=0 ;;
    home) DASH_LOG_SCROLL=100000 ;;           # clamped to the oldest line when drawn
    end | G | f)                              # follow the end again (and resume, if it was paused)
      DASH_LOG_SCROLL=0 DASH_LOG_MIDX=-1
      [ "$DASH_LS_PAUSED" -eq 0 ] || dash_logs_pause_toggle
      ;;
    space | ' ') dash_logs_pause_toggle ;;
    e) DASH_LOG_ERRONLY=$((1 - DASH_LOG_ERRONLY)) DASH_LOG_SCROLL=0 DASH_LOG_MIDX=-1 ;;
    '/') DASH_MODE=filter DASH_BUF="$DASH_LOG_FILTER" DASH_CUR="${#DASH_LOG_FILTER}" ;;
    s) DASH_MODE=find DASH_BUF="$DASH_LOG_FIND" DASH_CUR="${#DASH_LOG_FIND}" ;;
    ']') dash_logs_jump 1 ;;
    '[') dash_logs_jump -1 ;;
    left | h) DASH_FOCUS=svc ;;
    *) return 1 ;;
  esac
  return 0
}

# --- The palette: a fuzzy list of what can be done now. Actions reuse the menu runner (and so its confirmations).
dash_pal_add() { DASH_PAL_ALL_L+=("$1"); DASH_PAL_ALL_A+=("$2"); }

dash_pal_build() {
  local inst svc id i v th
  local -a svcs
  DASH_PAL_ALL_L=() DASH_PAL_ALL_A=()
  if [ "$DASH_ON_NEW" -eq 0 ] && [ "${#DASH_NAMES[@]}" -gt 0 ]; then
    inst="${DASH_NAMES[$DASH_SEL]}"
    read -ra svcs <<< "${DASH_SVCS[$inst]:-}"
    svc="${svcs[$DASH_SVC]:-${svcs[0]:-}}"
    for id in status check deploy_all deploy_svc rollback logs_live logs_recent stop_svc down; do
      if [ -z "$svc" ]; then case "$id" in deploy_svc | logs_live | logs_recent | stop_svc) continue ;; esac; fi
      dt "tui.act.$id"; dash_pal_add "${DTV//\{1\}/$svc}" "act:$id"
    done
    if [ "${DASH_DATA[$inst]:-}" = "unseeded" ]; then dt tui.act.init; dash_pal_add "${DTV//\{1\}/$svc}" "act:init"; fi
    dt tui.pal.svc
    for i in "${!svcs[@]}"; do dash_pal_add "${DTV//\{1\}/${svcs[$i]}}" "svc:$i"; done
  fi
  dt tui.pal.go
  for i in "${!DASH_NAMES[@]}"; do dash_pal_add "${DTV//\{1\}/${DASH_NAMES[$i]}}" "inst:$i"; done
  for v in instances resources output runs procs; do dt "tui.tab.$v"; id="$DTV"; dt tui.pal.view; dash_pal_add "${DTV//\{1\}/$id}" "view:$v"; done
  dt tui.pal.theme
  for th in "${TH_THEMES[@]}"; do dash_pal_add "${DTV//\{1\}/$th}" "theme:$th"; done
  dt tui.pal.new; dash_pal_add "$DTV" "new"
  dt tui.pal.lang; dash_pal_add "$DTV" "lang"
  dt tui.pal.clear; dash_pal_add "$DTV" "clear"
  dt tui.pal.quit; dash_pal_add "$DTV" "quit"
}

# Does the query appear in the label as a subsequence (case-insensitive)? PAL_SCORE gets the total gap: the lower, the better.
dash_pal_match() { # query label
  local q="${1,,}" l="${2,,}" qi=0 li=0 score=0 last=-1 ch
  while [ "$qi" -lt "${#q}" ]; do
    ch="${q:$qi:1}"
    while [ "$li" -lt "${#l}" ] && [ "${l:$li:1}" != "$ch" ]; do li=$((li + 1)); done
    [ "$li" -lt "${#l}" ] || return 1
    if [ "$last" -ge 0 ]; then score=$((score + li - last - 1)); else score=$((score + li)); fi
    last="$li" li=$((li + 1)) qi=$((qi + 1))
  done
  PAL_SCORE="$score"
}

# Filters and orders the items for the query. With no query the ones used recently come first.
dash_pal_filter() {
  local i r score a j k tmp
  local -a sc=() ix=()
  DASH_PAL_LABELS=() DASH_PAL_ACTS=()
  for i in "${!DASH_PAL_ALL_L[@]}"; do
    a="${DASH_PAL_ALL_A[$i]}"
    if [ -z "$DASH_PAL_Q" ]; then
      score="$i"
      for r in "${!DASH_PAL_RECENT[@]}"; do [ "${DASH_PAL_RECENT[$r]}" != "$a" ] || score=$((r - 1000)); done
    else
      dash_pal_match "$DASH_PAL_Q" "${DASH_PAL_ALL_L[$i]}" || continue
      score="$PAL_SCORE"
    fi
    sc+=("$score") ix+=("$i")
  done
  # Insertion sort by score (a few dozen items).
  for ((j = 1; j < ${#sc[@]}; j++)); do
    tmp="${sc[$j]}" k="${ix[$j]}" i=$((j - 1))
    while [ "$i" -ge 0 ] && [ "${sc[$i]}" -gt "$tmp" ]; do sc[i + 1]="${sc[$i]}" ix[i + 1]="${ix[$i]}"; i=$((i - 1)); done
    sc[i + 1]="$tmp" ix[i + 1]="$k"
  done
  for i in "${ix[@]}"; do DASH_PAL_LABELS+=("${DASH_PAL_ALL_L[$i]}"); DASH_PAL_ACTS+=("${DASH_PAL_ALL_A[$i]}"); done
  [ "$DASH_PAL_SEL" -lt "${#DASH_PAL_LABELS[@]}" ] || DASH_PAL_SEL=0
}

dash_open_palette() {
  dash_pal_build
  DASH_PAL_Q="" DASH_PAL_SEL=0
  dash_pal_filter
  DASH_MODE=palette
}

dash_pal_run() {
  local act="${DASH_PAL_ACTS[$DASH_PAL_SEL]:-}" kind arg a
  local -a keep=()
  DASH_MODE=normal
  [ -n "$act" ] || return 0
  keep=("$act")
  for a in "${DASH_PAL_RECENT[@]}"; do [ "$a" = "$act" ] || keep+=("$a"); done
  DASH_PAL_RECENT=("${keep[@]:0:5}")
  kind="${act%%:*}" arg="${act#*:}"
  case "$kind" in
    act)
      dash_current_target || return 0
      DASH_MENU_INST="$DASH_T_INST" DASH_MENU_SVC="$DASH_T_SVC" DASH_MENU_IDS=("$arg") DASH_MENU_SEL=0
      dash_menu_run
      ;;
    inst) DASH_ON_NEW=0 DASH_SEL="$arg" DASH_SVC=0 DASH_FOCUS=list DASH_VIEW=instances ;;
    svc) DASH_SVC="$arg" DASH_FOCUS=svc DASH_VIEW=instances ;;
    view) DASH_VIEW="$arg" ;;
    theme) if theme_apply "$arg"; then th_save "$arg"; dash_theme_refresh; fi ;;
    new) dash_terminal new --wizard ;;
    lang) dash_toggle_language ;;
    clear) DASH_CON=() DASH_CON_N=$((DASH_CON_N + 1)) ;;
    quit) DASH_QUIT=1 ;;
  esac
}

dash_key_palette() { # key
  case "$1" in
    esc) DASH_MODE=normal ;;
    enter) dash_pal_run ;;
    up) [ "$DASH_PAL_SEL" -le 0 ] || DASH_PAL_SEL=$((DASH_PAL_SEL - 1)) ;;
    down) [ "$DASH_PAL_SEL" -ge $((${#DASH_PAL_LABELS[@]} - 1)) ] || DASH_PAL_SEL=$((DASH_PAL_SEL + 1)) ;;
    backspace) DASH_PAL_Q="${DASH_PAL_Q%?}" DASH_PAL_SEL=0; dash_pal_filter ;;
    $'\025') DASH_PAL_Q="" DASH_PAL_SEL=0; dash_pal_filter ;;     # Ctrl+U
    space) DASH_PAL_Q+=" " DASH_PAL_SEL=0; dash_pal_filter ;;
    *) if [ "${#1}" -eq 1 ] && [[ "$1" != [[:cntrl:]] ]]; then DASH_PAL_Q+="$1" DASH_PAL_SEL=0; dash_pal_filter; fi ;;
  esac
}

# --- Console -----------------------------------------------------------------------------------------------------------
# The strip at the bottom of the Overview is a console: what was typed, what the commands printed and how they ended stay in a
# transcript, and the prompt is always on its last line. `:` gives it the keyboard (`!` starts a line that runs in the terminal).
# While it has the keyboard, typed text always goes to the line: the one-letter shortcuts of the panel are off.

DASH_CON=() DASH_CON_N=0 DASH_CON_SEQ=0 DASH_CON_COPIED=0 DASH_CON_MAX=500 DASH_CON_SCROLL=0
DASH_CUR=0 DASH_SIGINT=0 DASH_LAST_INT=-10 DASH_PN="deltactl"
DASH_BUILTINS=(help clear theme history goto refresh quit exit)

# Adds a line to the transcript. Colour sequences are kept, anything else dangerous is dropped (see tui_sanitize); a plain
# reset is replaced by the theme's, so the background of the theme survives it.
dash_con_add() { # text
  local rs=$'\033[0m'
  tui_sanitize "$1"
  DASH_CON+=("${TUI_OUT//"$rs"/$C_OFF}")
  if [ "${#DASH_CON[@]}" -gt "$DASH_CON_MAX" ]; then DASH_CON=("${DASH_CON[@]:100}"); fi
  DASH_CON_N=$((DASH_CON_N + 1)) DASH_CON_SCROLL=0
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
    '?' | clear | cls | theme | history | goto | view | refresh | quit | exit) return 0 ;;
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
      case "${1:-}" in
        instances | resources | output | runs | procs) DASH_VIEW="$1" ;;
        *) dash_con_add "$C_RED$(t tui.con.bad_view)$C_OFF" ;;
      esac
      ;;
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

# Ctrl+C: it cancels what is running; with nothing running it clears the line, and a second one in a row leaves the panel.
dash_ctrl_c() {
  if job_running; then
    job_cancel && dash_msg warn "$(t tui.msg.cancelling)"
  elif [ "$DASH_MODE" = "cmd" ] && [ -n "$DASH_BUF" ]; then
    DASH_BUF="" DASH_CUR=0
  elif [ "$DASH_MODE" != "normal" ]; then
    DASH_MODE=normal
  elif [ $((SECONDS - DASH_LAST_INT)) -le 2 ]; then
    DASH_QUIT=1
  else
    DASH_LAST_INT="$SECONDS"
    dash_msg info "$(t tui.msg.ctrl_c_again)"
  fi
}

# Completes the word being typed in the command line: commands (and the panel's own), then instances, then services.
dash_complete() {
  local buf="$DASH_BUF" bang="" idx prefix w common c head=""
  local -a toks cands=() pool=()
  case "$buf" in '!'*) bang="!"; buf="${buf#!}" ;; esac
  read -ra toks <<< "$buf"
  if [[ "$buf" == *" " ]]; then idx="${#toks[@]}" prefix=""; else idx=$((${#toks[@]} - 1)) prefix="${toks[$idx]:-}"; fi
  [ "$idx" -ge 0 ] || idx=0
  case "$idx" in
    0) pool=("${HELP_COMMANDS[@]}" "${DASH_BUILTINS[@]}") ;;
    1)
      case "${toks[0]:-}" in
        theme) pool=("${TH_THEMES[@]}") ;;
        goto | view) pool=(instances resources output) ;;
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
  if [ "${#DASH_HIST[@]}" -eq 0 ] || [ "${DASH_HIST[-1]}" != "$buf" ]; then DASH_HIST+=("$buf"); dash_hist_save "$buf"; fi
  DASH_HIDX="${#DASH_HIST[@]}"
  case "$buf" in '!'*) term=1; buf="${buf#!}"; buf="${buf#"${buf%%[![:space:]]*}"}" ;; esac
  # A lone `!` is a real shell.
  if [ "$term" -eq 1 ] && [ -z "$buf" ]; then dash_shell; return 0; fi
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
  # Wizards and the menu ask questions: they need the terminal.
  case " ${args[*]} " in *" --wizard "*) term=1 ;; esac
  case "${args[0]}" in menu) term=1 ;; new) [ "${#args[@]}" -gt 1 ] || term=1 ;; esac
  # On the Overview the answer stays in the console; in the other views it opens the Output view, as before.
  [ "$DASH_VIEW" != "instances" ] || view=stay
  if [ "$term" -eq 1 ]; then dash_terminal "${args[@]}"; else dash_start_job "$view" "${args[@]}"; fi
}

# Typing in the command line (mode cmd) or in the name confirmation (mode name). The line has a cursor.
dash_key_edit() {
  local k="$1" b
  case "$k" in
    enter)
      if [ "$DASH_MODE" = "name" ]; then
        DASH_MODE=normal
        if [ "$DASH_BUF" = "$DASH_NAME_TARGET" ]; then dash_start_job stay init "$DASH_NAME_TARGET" --yes; else dash_msg warn "$(t tui.msg.bad_name)"; fi
      elif [ "$DASH_MODE" = "filter" ]; then
        DASH_MODE=normal DASH_LOG_FILTER="$DASH_BUF" DASH_LOG_SCROLL=0 DASH_CUR=0 DASH_LOG_MIDX=-1   # an empty line removes the filter
      elif [ "$DASH_MODE" = "find" ]; then
        DASH_MODE=normal DASH_LOG_FIND="$DASH_BUF" DASH_CUR=0 DASH_LOG_MIDX=-1      # an empty line removes the search
        [ -z "$DASH_LOG_FIND" ] || dash_logs_jump 0                                   # and a text goes to the newest match
      else
        dash_submit_cmd
      fi
      ;;
    esc) DASH_MODE=normal DASH_CUR=0; dash_msg info "$(t tui.msg.cancelled)" ;;
    backspace) if [ "$DASH_CUR" -gt 0 ]; then DASH_BUF="${DASH_BUF:0:$((DASH_CUR - 1))}${DASH_BUF:$DASH_CUR}"; DASH_CUR=$((DASH_CUR - 1)); fi ;;
    delete) DASH_BUF="${DASH_BUF:0:$DASH_CUR}${DASH_BUF:$((DASH_CUR + 1))}" ;;
    left) [ "$DASH_CUR" -le 0 ] || DASH_CUR=$((DASH_CUR - 1)) ;;
    right) [ "$DASH_CUR" -ge "${#DASH_BUF}" ] || DASH_CUR=$((DASH_CUR + 1)) ;;
    home | $'\001') DASH_CUR=0 ;;                                   # Ctrl+A
    end | $'\005') DASH_CUR="${#DASH_BUF}" ;;                       # Ctrl+E
    $'\025') DASH_BUF="${DASH_BUF:$DASH_CUR}" DASH_CUR=0 ;;         # Ctrl+U: up to the start of the line
    $'\013') DASH_BUF="${DASH_BUF:0:$DASH_CUR}" ;;                  # Ctrl+K: to the end of the line
    $'\027')                                                        # Ctrl+W: the word before the cursor
      b="${DASH_BUF:0:$DASH_CUR}"
      b="${b%"${b##*[![:space:]]}"}"
      b="${b%"${b##*[[:space:]]}"}"
      DASH_BUF="$b${DASH_BUF:$DASH_CUR}" DASH_CUR="${#b}"
      ;;
    $'\014') DASH_CON=() DASH_CON_N=$((DASH_CON_N + 1)) ;;          # Ctrl+L: clear the transcript
    space) DASH_BUF="${DASH_BUF:0:$DASH_CUR} ${DASH_BUF:$DASH_CUR}"; DASH_CUR=$((DASH_CUR + 1)) ;;
    tab) if [ "$DASH_MODE" = "cmd" ]; then dash_complete; DASH_CUR="${#DASH_BUF}"; fi ;;
    up)
      if [ "$DASH_MODE" = "cmd" ] && [ "$DASH_HIDX" -gt 0 ]; then DASH_HIDX=$((DASH_HIDX - 1)); DASH_BUF="${DASH_HIST[$DASH_HIDX]}"; DASH_CUR="${#DASH_BUF}"; fi
      ;;
    down)
      if [ "$DASH_MODE" = "cmd" ]; then
        if [ "$DASH_HIDX" -lt $((${#DASH_HIST[@]} - 1)) ]; then DASH_HIDX=$((DASH_HIDX + 1)); DASH_BUF="${DASH_HIST[$DASH_HIDX]}"
        else DASH_HIDX="${#DASH_HIST[@]}"; DASH_BUF=""; fi
        DASH_CUR="${#DASH_BUF}"
      fi
      ;;
    pgup) [ "$DASH_MODE" != "cmd" ] || DASH_CON_SCROLL=$((DASH_CON_SCROLL + 5)) ;;
    pgdn) [ "$DASH_MODE" != "cmd" ] || { DASH_CON_SCROLL=$((DASH_CON_SCROLL - 5)); [ "$DASH_CON_SCROLL" -ge 0 ] || DASH_CON_SCROLL=0; } ;;
    other | timeout) ;;
    *)
      if [ "${#k}" -eq 1 ] && [[ "$k" != [[:cntrl:]] ]]; then DASH_BUF="${DASH_BUF:0:$DASH_CUR}$k${DASH_BUF:$DASH_CUR}"; DASH_CUR=$((DASH_CUR + 1)); fi
      ;;
  esac
}

dash_handle_key() {
  local k="$TUI_KEY"
  [ "$k" != "timeout" ] || return 0
  if [ "$k" = "eof" ]; then DASH_QUIT=1; return 0; fi
  DASH_DIRTY=1
  case "$DASH_MODE" in
    menu) dash_key_menu "$k" ;;
    confirm) dash_key_confirm "$k" ;;
    name | cmd | filter | find) dash_key_edit "$k" ;;
    palette) dash_key_palette "$k" ;;
    help) DASH_MODE=normal ;;
    *)
      # The test mode has one more key: "wait" waits for the running command to end.
      if [ "$k" = "wait" ] && tui_test_mode; then
        local i
        for i in $(seq 1 100); do job_poll || true; job_running || break; sleep 0.1; done
        return 0
      fi
      if [ "$k" = "sample" ] && tui_test_mode; then
        HOST_FAKE_NOW_US=$((${HOST_FAKE_NOW_US:-1000000} + 1000000))
        mt_sample; dash_host_build
        return 0
      fi
      dash_key_global "$k" && return 0
      case "$DASH_VIEW" in
        instances) dash_key_instances "$k" ;;
        resources) dash_key_resources "$k" ;;
        output) dash_key_output "$k" ;;
        runs) dash_key_runs "$k" ;;
        procs) dash_key_procs "$k" ;;
      esac
      ;;
  esac
}

# --- Main loop ---------------------------------------------------------------------------------------------

dash_loop() {
  local tick
  DASH_DIRTY=1
  while [ "$DASH_QUIT" -eq 0 ]; do
    if [ "$TUI_RESIZED" -eq 1 ]; then tui_size; dash_host_build; DASH_DIRTY=1; fi
    dash_tick
    if [ "$DASH_DIRTY" -eq 1 ]; then
      DASH_DIRTY=0
      dash_render
    fi
    # Waiting costs nothing: `read -t` sleeps. A running command makes the loop wake up more often.
    # A running command, a log that grows faster than one turn can read and a stream waiting to start all ask to be back soon.
    if job_running || [ "$DASH_LS_MORE" -eq 1 ]; then tick=0.2; elif [ "$DASH_LS_DEFER" -eq 1 ]; then tick=0.3; else tick=1; fi
    tui_key "$tick"
    if [ "$DASH_SIGINT" -eq 1 ]; then DASH_SIGINT=0; dash_ctrl_c; DASH_DIRTY=1; fi
    DASH_IDLE=0
    [ "$TUI_KEY" != "timeout" ] || DASH_IDLE=1
    dash_handle_key
  done
}

dash_init() {
  # The theme first: the symbols and every cached string below are coloured with it.
  theme_apply "$(th_initial)" || theme_apply matrix || true
  DASH_HOST="$(host_name)"
  [ -n "$DASH_HOST" ] || DASH_HOST="$(t ui.host_fallback)"
  DK_READY_TTL=10   # `docker info` is not repeated at every refresh
  dash_symbols_init
  dash_texts_build
  DASH_LANG_N=$((DASH_LANG_N + 1))
}

cmd_dashboard() {
  if ! tui_interactive; then
    cmd_home
    return 0
  fi
  # ./deltactl runs with `set -e`: inside the panel a function that answers "no" (a busy job, a missing reading) must not
  # end the whole program, so errexit is off while it runs and restored afterwards.
  local errexit=0
  case "$-" in *e*) errexit=1 ;; esac
  set +e
  dash_init
  dash_hist_load
  trap 'dash_shutdown' EXIT
  trap 'dash_shutdown; exit 130' TERM
  trap 'DASH_SIGINT=1' INT          # Ctrl+C is handled by the loop (see dash_ctrl_c), it does not end the panel by itself
  tui_enter
  dash_refresh
  dash_events_seed
  mt_reset
  mt_sample
  dash_host_build
  dash_events_start
  dash_loop
  dash_shutdown
  [ "$errexit" -eq 0 ] || set -e
  return 0
}

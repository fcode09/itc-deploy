#!/usr/bin/env bash
# shellcheck disable=SC2034  # the DASH_* and DSV_* variables are shared with lib/cmd/dashboard_view.sh
# The interactive panel: one screen, seven views, live figures. It is what ./deltactl and ./deltactl menu open in a
# real terminal; without one (a pipe, a script, TERM=dumb) they keep showing the static home screen and the numbered menu.
#
# This file is the controller: the state every screen shares, the background work (Docker state, errors, events, logs of a
# service), the commands that run inside the panel (lib/core/jobs.sh), the global keys, the mouse and the main loop.
# Drawing the shared parts (header, tabs, dialog frame, key bar, the frame itself) is lib/cmd/dashboard_view.sh. Everything
# else is a SCREEN in lib/screens/, registered in lib/screens/registry.sh (read its header for the contract, and to add one):
#   views (tabs 1 to 9)  instances, resources, output, runs, procs, console, server, images, env (the variables of an instance)
#   modes (they take the keyboard over a view)  menu, confirm, name, cmd, filter, find, wizard (the new-instance form),
#                        palette, help, options, srvask (a question about the server's requirements), imguse (use a version in an instance),
#                        imgload (load an image archive), envedit (the variables editor has the keyboard)
# The other interactive commands (the menu, a leading `!`) run in the terminal and come back.
#
# What keeps it light: it sleeps in `read -t` between keys; the figures come from the kernel through Bash builtins
# (lib/core/metrics.sh); Docker is queried only when it reports an event (or every 30 s as a safety net); and a frame
# is repainted only when something changed, line by line.

# menu_pause (wait for Enter) comes from menu.sh; the terminal layer from tui.sh; HELP_COMMANDS from help.sh
source "$ROOT/lib/cmd/menu.sh"
source "$ROOT/lib/cmd/status.sh"
source "$ROOT/lib/cmd/help.sh"
source "$ROOT/lib/ui/tui.sh"
source "$ROOT/lib/ui/layout.sh"
source "$ROOT/lib/ui/kit/kit.sh"
# The interpreter of what a command printed and the summary the Output view draws with it.
source "$ROOT/lib/core/outparse.sh"
source "$ROOT/lib/ui/outsummary.sh"
source "$ROOT/lib/cmd/dashboard_view.sh"
# The screens and the router (lib/screens/registry.sh): the views and modes below are the ones it registers.
source "$ROOT/lib/screens/registry.sh"

DASH_VIEW=instances       # instances | resources | output | runs | procs | console
DASH_MODE=normal          # normal | menu | confirm | name | cmd | help | wizard (and others: filter find palette options)
DASH_SEL=0 DASH_SVC=0 DASH_RES_SEL=0 DASH_RES_SORT=name DASH_FOCUS=list DASH_ON_NEW=0
DASH_ZOOM=0 DASH_LOG_SCROLL=0 DASH_LOG_FILTER="" DASH_PAL_Q="" DASH_PAL_SEL=0
DASH_PAL_ALL_L=() DASH_PAL_ALL_A=() DASH_PAL_LABELS=() DASH_PAL_ACTS=() DASH_PAL_RECENT=() PAL_SCORE=0
DASH_OUT_SCROLL=0 DASH_OUT_ERRORS=0
DASH_OUT_RAW=0 DASH_OUT_STOP=0 DASH_OUT_SUM=0   # the Output view: 1 = the raw text, the lines hidden above the summary, 1 while the summary is on screen
DASH_PAUSED=0 DASH_DIRTY=1 DASH_QUIT=0 DASH_IDLE=0 DASH_SPIN=0 DASH_JOB_PENDING=0
DASH_MSG="" DASH_MSG_KIND=info DASH_MSG_UNTIL=0
DASH_HOST="" DASH_DOCKER_VER=""
DASH_REFRESH_SECONDS="${DELTACTL_REFRESH:-5}"   # without Docker events the state is read this often
DASH_SAFETY_SECONDS=30                           # with events it is still read this often, just in case
# Nobody at the keyboard for this long and nothing running: the figures are sampled half as often (and the error counts a quarter as
# often) until the next key, which takes a fresh sample at once. An idle panel left open on a server costs half as much.
DASH_IDLE_AFTER="${DELTACTL_TUI_IDLE_AFTER:-30}"
[[ "$DASH_IDLE_AFTER" =~ ^[1-9][0-9]{0,5}$ ]] || DASH_IDLE_AFTER=30   # 1 s to ~11 days; 0 would make every key a "return"
DASH_KEY_AT=0 DASH_AWAY=0
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
    name="${f%/.env.instance}"; name="${name##*/}"
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
      case " $E_CODES " in *" tag-drift "*) t_r tui.tag_drift "$E_RUN" "$E_CFG"; DSV_NOTE[$key]="$T_OUT" ;; esac
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
    data_state_r "$name"; DASH_DATA[$name]="$DS"
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
  # The pids may have changed: read the figures again at the next tick (not while away: without Docker events this runs every few
  # seconds, and sampling after each one would undo the slower pace; a new pid is still picked up at the next sample).
  [ "$DASH_AWAY" -eq 1 ] || MT_LAST_US=0
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
  if declare -F dash_nz_tmp_clean > /dev/null; then dash_nz_tmp_clean; fi   # (the answers of the wizard: a secret may be in them)
}

# --- Running commands ---------------------------------------------------------------------------------------

# Starts ./deltactl <args> in the background. $1 = output (jump to the Output view) or stay (keep the view).
dash_start_job() { # view args...
  local view="$1" color=never
  shift
  # A command that has just ended still counts as running until the next tick collects it: collect (and announce) it now, or the new
  # command would be refused and that warning lost under the "finished" message of the old one.
  if job_running; then dash_job_tick; fi
  # Refused: the console keeps it too, as the transcript of what was asked (the status line can be replaced by the running command's
  # "finished" message before a frame shows the warning, when it ends right after).
  if job_running; then dash_msg warn "$(t tui.msg.busy)"; dash_con_add "${DASH_SYM[warn]} $DASH_MSG ($*)"; return 1; fi
  [ "$UI_COLOR" -ne 1 ] || color=always
  job_start "$*" env COLUMNS=$((TUI_COLS - 4)) DELTACTL_UI=rich DELTACTL_COLOR="$color" \
    DELTACTL_LANG="${DELTACTL_LANG_ACTIVE:-es}" "$ROOT/deltactl" "$@"
  DASH_OUT_SCROLL=0 DASH_OUT_STOP=0 DASH_JOB_DONE=0
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
  dash_key_seen                      # (someone was at the keyboard all along)
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
  # The command ended (or was never started): whatever was waiting is drawn now, and the files with the answers of the wizard are gone.
  if [ "$DASH_JOB_PENDING" -eq 1 ]; then DASH_DIRTY=1 DASH_JOB_PENDING=0; fi
  if [ "${#DASH_NZ_TMPS[@]}" -gt 0 ]; then dash_nz_tmp_clean; fi
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
  dash_screen_tick
  if [ "$DASH_PAUSED" -eq 0 ]; then
    if [ -n "$DASH_EV_FD" ]; then interval="$DASH_SAFETY_SECONDS"; else interval="$DASH_REFRESH_SECONDS"; fi
    if [ "$DASH_EV_PENDING" -eq 1 ] || [ $((SECONDS - DASH_REFRESH_AT)) -ge "$interval" ]; then
      # In the test mode (synchronous) it waits for an idle tick, so a key press never blocks on Docker.
      if ! tui_test_mode || [ "$DASH_IDLE" -eq 1 ]; then dash_refresh_request; fi
    fi
    if dash_screen_live; then MT_INTERVAL_MULT=1; else MT_INTERVAL_MULT=2; fi
    if [ $((SECONDS - DASH_KEY_AT)) -ge "$DASH_IDLE_AFTER" ] && ! job_running; then
      DASH_AWAY=1 MT_INTERVAL_MULT=$((MT_INTERVAL_MULT * 2))
    else
      DASH_AWAY=0
    fi
    if mt_due; then
      mt_sample
      dash_host_build
      DASH_DIRTY=1
    fi
    # What the current view polls for (the instances: the log tail and the error counts of the selected one).
    dash_screen_poll
  fi
  if [ -n "$DASH_MSG" ] && [ "$SECONDS" -ge "$DASH_MSG_UNTIL" ]; then DASH_MSG=""; DASH_DIRTY=1; fi
}

# --- Actions of an instance -------------------------------------------------------------------------------

# --- Keys ------------------------------------------------------------------------------------------------

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
    esc) dash_screen_back ;;   # a step back inside the view (the statistics, the zoom, the pane), else the first view, else quit
    [1-9]) dash_screen_by_number "$1" || return 1; dash_screen_goto "$DASH_SCR_ID" ;;   # the view of that tab
    tab) dash_screen_tab 1 ;;
    btab) dash_screen_tab -1 ;;
    $'\020') dash_open_palette ;;                                    # Ctrl+P
    '?') DASH_MODE=help DASH_HELP_OFF=-1 ;;
    L) dash_toggle_language ;;
    T) dash_cycle_theme ;;
    o) dash_open_options ;;
    r) dash_refresh_request; DASH_ERRS_AT=(); DASH_RUNS_AT=-1000; dash_msg info "$(t tui.msg.refreshed)" ;;
    p)
      if [ "$DASH_PAUSED" -eq 0 ]; then DASH_PAUSED=1; dash_msg info "$(t tui.msg.paused)"; else DASH_PAUSED=0; dash_msg info "$(t tui.msg.resumed)"; fi
      ;;
    x)
      if job_cancel; then dash_msg warn "$(t tui.msg.cancelling)"; else dash_msg info "$(t tui.msg.nothing_running)"; fi
      ;;
    ':') DASH_MODE=cmd DASH_BUF="" DASH_CUR=0 DASH_HIDX="${#DASH_HIST[@]}" ;;
    '!')
      # A view can take the key for itself (the Server view runs the command of a requirement); else it opens a command line for the terminal.
      if declare -F "scr_${DASH_VIEW}_bang" > /dev/null && "scr_${DASH_VIEW}_bang"; then :; else DASH_MODE=cmd DASH_BUF="!" DASH_CUR=1 DASH_HIDX="${#DASH_HIST[@]}"; fi
      ;;
    n) dash_open_new ;;
    d) dash_start_job output doctor ;;
    i) dash_start_job output images ;;
    *) return 1 ;;
  esac
}

# --- Panes: focus ring, zoom, logs, palette ------------------------------------------------------------------------------
# The Overview has up to three panes that take the keyboard: the instances, the services of the selected instance and its logs.
# Tab / Shift+Tab walk them, `z` zooms the focused one to the whole body (Esc comes back), and Ctrl+P opens a palette of actions.

# --- Console -----------------------------------------------------------------------------------------------------------
# The strip at the bottom of the Overview is a console: what was typed, what the commands printed and how they ended stay in a
# transcript, and the prompt is always on its last line. `:` gives it the keyboard (`!` starts a line that runs in the terminal).
# While it has the keyboard, typed text always goes to the line: the one-letter shortcuts of the panel are off.

DASH_CUR=0 DASH_SIGINT=0 DASH_LAST_INT=-10 DASH_PN="deltactl"

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

dash_handle_key() {
  local k="$TUI_KEY"
  [ "$k" != "timeout" ] || return 0
  if [ "$k" = "eof" ]; then DASH_QUIT=1; return 0; fi
  DASH_DIRTY=1
  if [ "$k" = "mouse" ]; then dash_mouse; return 0; fi
  # With the vim keys off (Options), j k h g G do nothing where they would move: they are only letters where text is typed.
  if [ "$DASH_VIM" -eq 0 ]; then
    case "$DASH_MODE" in normal | menu | options) case "$k" in j | k | h | g | G) return 0 ;; esac ;; esac
  fi
  if [ "$DASH_MODE" != "normal" ]; then
    # A dialog or a line being typed has the keyboard: its screen handles the key.
    dash_screen_key "$k"
    return 0
  fi
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
  dash_screen_key "$k"
}

# --- Mouse (Options: off by default) ---------------------------------------------------------------------------
# A click on a tab opens that view; on an instance it selects it, and a second click on the selected one opens its actions (like
# Enter); on the New button it selects it, then starts the wizard. In the Console view a click gives the line the keyboard. The
# wheel moves like the arrows wherever they move something; on a line being typed it scrolls the transcript instead of walking the
# history. Releases, drags and other buttons do nothing, and clicks only act where no dialog or line has the keyboard.
dash_mouse() {
  local b="$TUI_MB" y="$TUI_MY" x="$TUI_MX"
  [ "$TUI_MUP" -eq 0 ] || return 0
  [ $((b & 32)) -eq 0 ] || return 0      # a drag
  b=$((b & ~28))                          # Shift, Alt and Ctrl held down do not change the button
  case "$b" in
    64 | 65)
      if [ "$DASH_MODE" = "cmd" ]; then
        if [ "$b" -eq 64 ]; then DASH_CON_SCROLL=$((DASH_CON_SCROLL + 3)); else DASH_CON_SCROLL=$((DASH_CON_SCROLL - 3)); fi
        dash_con_clamp
        return 0
      fi
      case "$DASH_MODE" in name | filter | lfilter | find | confirm | wizard) return 0 ;; help) [ "$DASH_HELP_MAX" -gt 0 ] || return 0 ;; esac
      if [ "$b" -eq 64 ]; then TUI_KEY=up; else TUI_KEY=down; fi
      dash_handle_key
      return 0
      ;;
    0) ;;
    *) return 0 ;;
  esac
  if [ "$DASH_MODE" != "normal" ]; then
    # A mode that has a click hook (the bar of steps of the new-instance wizard) takes the click; the others ignore the mouse.
    if declare -F "scr_${DASH_MODE}_click" > /dev/null; then "scr_${DASH_MODE}_click" "$x" "$y"; fi
    return 0
  fi
  if [ "$y" -eq 2 ]; then
    if dash_tab_at "$x"; then dash_key_global "$DASH_TAB_I"; fi
    return 0
  fi
  # Anywhere else in the body: the current view decides what a click means (a view with no click hook ignores it).
  dash_screen_click "$x" "$y" || true
  return 0
}

# --- Main loop ---------------------------------------------------------------------------------------------

# A key (or a click) arrived. Back from away, the figures on screen may be several seconds old: the next turn samples at once.
dash_key_seen() {
  [ "$DASH_AWAY" -eq 0 ] || MT_LAST_US=0
  DASH_KEY_AT="$SECONDS" DASH_AWAY=0
}

dash_loop() {
  local tick
  DASH_DIRTY=1 DASH_KEY_AT="$SECONDS"
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
    if [ "$DASH_SIGINT" -eq 1 ]; then DASH_SIGINT=0; dash_key_seen; dash_ctrl_c; DASH_DIRTY=1; fi
    DASH_IDLE=0
    if [ "$TUI_KEY" = "timeout" ]; then DASH_IDLE=1; else dash_key_seen; fi
    dash_handle_key
  done
}

dash_init() {
  # The theme first: the symbols and every cached string below are coloured with it.
  theme_apply "$(th_initial)" || theme_apply matrix || true
  dash_opts_load
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
  dash_alias_load
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
  dash_srv_startup      # the server's requirements are checked in the background; with one missing the panel opens on the Server view
  dash_loop
  dash_shutdown
  [ "$errexit" -eq 0 ] || set -e
  return 0
}

#!/usr/bin/env bash
# shellcheck disable=SC2034  # the DASH_* and DSV_* variables are shared with lib/cmd/dashboard_view.sh
# The interactive panel: one screen, three views, live figures. It is what ./deltactl and ./deltactl menu open in a
# real terminal; without one (a pipe, a script, TERM=dumb) they keep showing the static home screen and the numbered menu.
#
# Views (1, 2, 3 or Tab): Instances (list + detail of the selected one + output of the last command), Resources (every
# service with memory, CPU and trend) and Output (the full output of the last command, scrollable).
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

DASH_VIEW=instances       # instances | resources | output
DASH_MODE=normal          # normal | menu | confirm | name | cmd | help
DASH_SEL=0 DASH_SVC=0 DASH_RES_SEL=0 DASH_RES_SORT=name
DASH_OUT_SCROLL=0 DASH_OUT_ERRORS=0
DASH_PAUSED=0 DASH_DIRTY=1 DASH_QUIT=0 DASH_IDLE=0 DASH_SPIN=0
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
  local slot="$1" f="${DASH_AS_FILE[$slot]:-}" pid="${DASH_AS_PID[$slot]:-}"
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
dash_events_drain() {
  local got=1 line
  [ -n "$DASH_EV_FD" ] || return 1
  while read -r -t 0 -u "$DASH_EV_FD" 2>/dev/null; do
    if read -r -t 0.05 -u "$DASH_EV_FD" line; then
      got=0
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
  [ -z "$DASH_EV_PID" ] || kill "$DASH_EV_PID" 2>/dev/null || true
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
  [ "$view" != "output" ] || DASH_VIEW=output
  dash_msg info "$(t tui.msg.started "$*")"
}

# Runs ./deltactl <args> in the terminal (for wizards that ask questions) and comes back to the panel.
dash_terminal() { # args...
  dash_msg info "$(t tui.msg.terminal "$*")"
  tui_leave
  printf '\n  %s%s ./deltactl %s%s\n\n' "$C_GRY" "$UI_S_ARROW" "$*" "$C_OFF"
  "$ROOT/deltactl" "$@" || printf '\n  %s %s\n' "$(ui_sym err)" "$(t menu.cmd_failed "$?")"
  menu_pause
  tui_enter
  dash_refresh_request
}

# Notices that the command ended: message, and a state refresh because it probably changed something.
dash_job_tick() {
  local secs
  if job_poll; then DASH_DIRTY=1; fi
  if job_running; then
    DASH_SPIN=$((DASH_SPIN + 1))
    DASH_DIRTY=1
    return 0
  fi
  if [ -n "$JOB_PID" ] && [ -n "$JOB_RC" ] && [ "$DASH_JOB_DONE" != "$JOB_SEQ" ]; then
    DASH_JOB_DONE="$JOB_SEQ"
    dash_job_secs; secs="$DASH_JS"
    if [ "$JOB_CANCELLED" -eq 1 ]; then dash_msg warn "$(t tui.msg.cancelled)"
    elif [ "$JOB_RC" -eq 0 ]; then dash_msg ok "$(t tui.msg.finished_ok "./deltactl $JOB_TITLE" "$secs")"
    else dash_msg err "$(t tui.msg.finished_err "./deltactl $JOB_TITLE" "$JOB_RC" "$secs")"; fi
    dash_refresh_request
  fi
}

# --- Periodic work ----------------------------------------------------------------------------------------

dash_tick() {
  local interval
  dash_job_tick
  if dash_events_drain; then DASH_EV_PENDING=1; fi
  # What finished in the background is applied at once, even while paused (it was already asked for).
  if dash_async_tick; then DASH_DIRTY=1; fi
  if [ "$DASH_PAUSED" -eq 0 ]; then
    if [ -n "$DASH_EV_FD" ]; then interval="$DASH_SAFETY_SECONDS"; else interval="$DASH_REFRESH_SECONDS"; fi
    if [ "$DASH_EV_PENDING" -eq 1 ] || [ $((SECONDS - DASH_REFRESH_AT)) -ge "$interval" ]; then
      # In the test mode (synchronous) it waits for an idle tick, so a key press never blocks on Docker.
      if ! tui_test_mode || [ "$DASH_IDLE" -eq 1 ]; then dash_refresh_request; fi
    fi
    if mt_due; then
      mt_sample
      dash_host_build
      DASH_DIRTY=1
    fi
    # Error counts of the selected instance: when the user pauses on it, then every 30 s.
    if [ "$DASH_IDLE" -eq 1 ] && [ "$DASH_VIEW" = "instances" ] && [ "${#DASH_NAMES[@]}" -gt 0 ]; then
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
    init) DASH_NAME_TARGET="$inst" DASH_BUF="" DASH_MODE=name ;;
    help) dash_start_job output help status ;;
  esac
}

# --- Keys ------------------------------------------------------------------------------------------------

dash_select() { # delta
  local n="${#DASH_NAMES[@]}"
  [ "$n" -gt 0 ] || return 0
  DASH_SEL=$(((DASH_SEL + n + $1) % n))
  DASH_SVC=0 DASH_DET_OFF=0
}

dash_select_service() { # delta
  local -a svcs
  [ "${#DASH_NAMES[@]}" -gt 0 ] || return 0
  read -ra svcs <<< "${DASH_SVCS[${DASH_NAMES[$DASH_SEL]}]:-}"
  [ "${#svcs[@]}" -gt 0 ] || return 0
  DASH_SVC=$(((DASH_SVC + ${#svcs[@]} + $1) % ${#svcs[@]}))
}

# Service of the selected instance as "instance service" (empty when there is none).
dash_current_target() {
  local name svc
  local -a svcs
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

# Keys that work in every view.
dash_key_global() { # key ; returns 0 when handled
  case "$1" in
    q) DASH_QUIT=1 ;;
    esc) if [ "$DASH_VIEW" = "instances" ]; then DASH_QUIT=1; else DASH_VIEW=instances; fi ;;
    1) DASH_VIEW=instances ;;
    2) DASH_VIEW=resources ;;
    3) DASH_VIEW=output ;;
    tab)
      case "$DASH_VIEW" in instances) DASH_VIEW=resources ;; resources) DASH_VIEW=output ;; *) DASH_VIEW=instances ;; esac
      ;;
    '?') DASH_MODE=help ;;
    L) dash_toggle_language ;;
    r) dash_refresh_request; DASH_ERRS_AT=(); dash_msg info "$(t tui.msg.refreshed)" ;;
    p)
      if [ "$DASH_PAUSED" -eq 0 ]; then DASH_PAUSED=1; dash_msg info "$(t tui.msg.paused)"; else DASH_PAUSED=0; dash_msg info "$(t tui.msg.resumed)"; fi
      ;;
    x)
      if job_cancel; then dash_msg warn "$(t tui.msg.cancelling)"; else dash_msg info "$(t tui.msg.nothing_running)"; fi
      ;;
    ':') DASH_MODE=cmd DASH_BUF="" DASH_HIDX="${#DASH_HIST[@]}" ;;
    '!') DASH_MODE=cmd DASH_BUF="!" DASH_HIDX="${#DASH_HIST[@]}" ;;
    n) dash_terminal new --wizard ;;
    d) dash_start_job output doctor ;;
    i) dash_start_job output images ;;
    *) return 1 ;;
  esac
}

dash_key_instances() {
  case "$1" in
    up | k) dash_select -1 ;;
    down | j) dash_select 1 ;;
    left | h) dash_select_service -1 ;;
    right) dash_select_service 1 ;;
    enter) [ "${#DASH_NAMES[@]}" -eq 0 ] || dash_open_actions "${DASH_NAMES[$DASH_SEL]}" ;;
    l) dash_current_target && dash_start_job output logs "$DASH_T_INST" "$DASH_T_SVC" -f ;;
    u) [ "${#DASH_NAMES[@]}" -eq 0 ] || dash_start_job stay deploy "${DASH_NAMES[$DASH_SEL]}" ;;
    c) [ "${#DASH_NAMES[@]}" -eq 0 ] || dash_start_job stay check "${DASH_NAMES[$DASH_SEL]}" ;;
    s) [ "${#DASH_NAMES[@]}" -eq 0 ] || dash_start_job output status "${DASH_NAMES[$DASH_SEL]}" ;;
    e) [ "${#DASH_NAMES[@]}" -eq 0 ] || dash_errors_request "${DASH_NAMES[$DASH_SEL]}" ;;
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
      DASH_DET_OFF=0 DASH_VIEW=instances
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

# Completes the word being typed in the command line: commands, then instances, then services.
dash_complete() {
  local buf="$DASH_BUF" bang="" idx prefix w common c head=""
  local -a toks cands=() pool=()
  case "$buf" in '!'*) bang="!"; buf="${buf#!}" ;; esac
  read -ra toks <<< "$buf"
  if [[ "$buf" == *" " ]]; then idx="${#toks[@]}" prefix=""; else idx=$((${#toks[@]} - 1)) prefix="${toks[$idx]:-}"; fi
  [ "$idx" -ge 0 ] || idx=0
  case "$idx" in
    0) pool=("${HELP_COMMANDS[@]}") ;;
    1) pool=("${DASH_NAMES[@]}") ;;
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
  local buf="$DASH_BUF" term=0
  local -a args
  DASH_MODE=normal
  buf="${buf#"${buf%%[![:space:]]*}"}"
  [ -n "$buf" ] || return 0
  if [ "${#DASH_HIST[@]}" -eq 0 ] || [ "${DASH_HIST[-1]}" != "$buf" ]; then DASH_HIST+=("$buf"); fi
  case "$buf" in '!'*) term=1; buf="${buf#!}" ;; esac
  read -ra args <<< "$buf"
  case "${args[0]:-}" in ./deltactl | deltactl) args=("${args[@]:1}") ;; esac
  [ "${#args[@]}" -gt 0 ] || return 0
  # Wizards and the menu ask questions: they need the terminal.
  case " ${args[*]} " in *" --wizard "*) term=1 ;; esac
  case "${args[0]}" in menu) term=1 ;; new) [ "${#args[@]}" -gt 1 ] || term=1 ;; esac
  if [ "$term" -eq 1 ]; then dash_terminal "${args[@]}"; else dash_start_job output "${args[@]}"; fi
}

# Typing in the command line (mode cmd) or in the name confirmation (mode name).
dash_key_edit() {
  local k="$1"
  case "$k" in
    enter)
      if [ "$DASH_MODE" = "name" ]; then
        DASH_MODE=normal
        if [ "$DASH_BUF" = "$DASH_NAME_TARGET" ]; then dash_start_job stay init "$DASH_NAME_TARGET" --yes; else dash_msg warn "$(t tui.msg.bad_name)"; fi
      else
        dash_submit_cmd
      fi
      ;;
    esc) DASH_MODE=normal; dash_msg info "$(t tui.msg.cancelled)" ;;
    backspace) DASH_BUF="${DASH_BUF%?}" ;;
    space) DASH_BUF+=" " ;;
    tab) [ "$DASH_MODE" != "cmd" ] || dash_complete ;;
    up)
      if [ "$DASH_MODE" = "cmd" ] && [ "$DASH_HIDX" -gt 0 ]; then DASH_HIDX=$((DASH_HIDX - 1)); DASH_BUF="${DASH_HIST[$DASH_HIDX]}"; fi
      ;;
    down)
      if [ "$DASH_MODE" = "cmd" ]; then
        if [ "$DASH_HIDX" -lt $((${#DASH_HIST[@]} - 1)) ]; then DASH_HIDX=$((DASH_HIDX + 1)); DASH_BUF="${DASH_HIST[$DASH_HIDX]}"
        else DASH_HIDX="${#DASH_HIST[@]}"; DASH_BUF=""; fi
      fi
      ;;
    left | right | home | end | delete | pgup | pgdn | other | timeout) ;;
    *) [ "${#k}" -ne 1 ] || DASH_BUF+="$k" ;;
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
    name | cmd) dash_key_edit "$k" ;;
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
      esac
      ;;
  esac
}

# --- Main loop ---------------------------------------------------------------------------------------------

dash_loop() {
  local tick
  DASH_DIRTY=1
  while [ "$DASH_QUIT" -eq 0 ]; do
    if [ "$TUI_RESIZED" -eq 1 ]; then tui_size; DASH_DIRTY=1; fi
    dash_tick
    if [ "$DASH_DIRTY" -eq 1 ]; then
      DASH_DIRTY=0
      dash_render
    fi
    # Waiting costs nothing: `read -t` sleeps. A running command makes the loop wake up more often.
    if job_running; then tick=0.2; else tick=1; fi
    tui_key "$tick"
    DASH_IDLE=0
    [ "$TUI_KEY" != "timeout" ] || DASH_IDLE=1
    dash_handle_key
  done
}

dash_init() {
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
  trap 'dash_shutdown' EXIT
  trap 'dash_shutdown; exit 130' INT TERM
  tui_enter
  dash_refresh
  mt_reset
  mt_sample
  dash_host_build
  dash_events_start
  dash_loop
  dash_shutdown
  [ "$errexit" -eq 0 ] || set -e
  return 0
}

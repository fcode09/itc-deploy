#!/usr/bin/env bash
# shellcheck disable=SC2034  # the DASH_LS_* and DASH_LOG_* variables are shared with lib/cmd/dashboard.sh, dashboard_view.sh and the other screens
# The logs pane of the panel: what it shows of the selected service, live. Loaded by lib/screens/instances.sh.
#
# While the pane is on screen (the Overview with the services of an instance selected, or its zoom) and the service is running, a
# `docker logs --tail 200 -f` runs and feeds the pane (through a file, see below); when the pane is not shown the process is stopped, so a panel
# that sits on another view or on a narrow screen costs nothing here. The lines are read without waiting (like the Docker events),
# cleaned once, kept in a ring of the last DASH_LS_MAX lines, and the screen is updated at most once a second however fast the log
# grows. Without a stream (a stopped service, no Docker) the pane keeps polling `docker logs --tail` as before.
#
# Keys of the pane (see dash_key_logs): Space pauses and resumes, f / End follow the end again, e shows only errors and warnings,
# / filters by a text (hides the other lines), s searches a text (highlights it; [ and ] jump to the previous / next match).

DASH_LS_KEY="" DASH_LS_FD="" DASH_LS_PID="" DASH_LS_ENDED=0
DASH_LS_RING=() DASH_LS_MAX=1500 DASH_LS_PUB=0 DASH_LS_CUT=0 DASH_LS_PART=""   # lines held, how many of them are in the pane, how many
                                                                               # left from the front since, and a line still being written
DASH_LS_PAUSED=0 DASH_LS_PEND=0 DASH_LS_WANT="" DASH_LS_CN=""   # paused; lines waiting; the key (and container) the pane wants a stream for
DASH_LS_FRESH=0 DASH_LS_AT=-1 DASH_LS_END_AT=0 DASH_LS_START_US=0 DASH_LS_BEGAN=0 DASH_LS_MORE=0 DASH_LS_DEFER=0
DASH_LS_FILE="" DASH_LS_SEQ=0 DASH_LS_BYTES=0 DASH_LS_LIMIT=4194304 DASH_LS_STATIC=0   # the file of the stream, bytes read from it, its limit
DASH_LOG_ERRONLY=0 DASH_LOG_FIND="" DASH_LOG_MIDX=-1 DASH_LOG_INNER=8 DASH_LC=""
DASH_LS_SEL=() DASH_LS_FIRST=1

# --- Classes of lines ------------------------------------------------------------------------------------------------

# The class of a line into DASH_LC: err, warn or empty. $1 must already be in lower case.
dash_log_class_l() {
  case "$1" in
    *error* | *econn* | *fail* | *"unable to"* | *fatal* | *panic* | *exception*) DASH_LC=err ;;
    *warn*) DASH_LC=warn ;;
    *) DASH_LC="" ;;
  esac
}

# The lines of a service's log that the pane shows, after the errors-only switch and the text filter, into DASH_LS_SEL. With neither
# of them on, nothing is looked at line by line (a log can have thousands of lines and this runs at every update).
dash_logs_select() { # key
  local flt="${DASH_LOG_FILTER,,}" i low
  local -a all=() lows=()
  DASH_LS_SEL=()
  [ -n "${DASH_LOGS[$1]:-}" ] || return 0
  mapfile -t all <<< "${DASH_LOGS[$1]}"
  if [ "$DASH_LOG_ERRONLY" -eq 0 ] && [ -z "$flt" ]; then DASH_LS_SEL=("${all[@]}"); return 0; fi
  low="${DASH_LOGS[$1],,}"
  mapfile -t lows <<< "$low"
  for i in "${!all[@]}"; do
    if [ "$DASH_LOG_ERRONLY" -eq 1 ]; then dash_log_class_l "${lows[$i]}"; [ -n "$DASH_LC" ] || continue; fi
    if [ -n "$flt" ] && [[ "${lows[$i]}" != *"$flt"* ]]; then continue; fi
    DASH_LS_SEL+=("${all[$i]}")
  done
}

# A line with the text of the search marked (the first occurrence): in reverse video, or between [ ] when the terminal has no colours.
# Result in DASH_LH.
DASH_LH=""
dash_log_mark() { # line lowered_find
  local line="$1" f="$2" low="${1,,}" pre
  DASH_LH="$line"
  [ -n "$f" ] && [[ "$low" == *"$f"* ]] || return 0
  pre="${low%%"$f"*}"
  if [ -n "$DASH_REV" ]; then DASH_LH="${line:0:${#pre}}$DASH_REV${line:${#pre}:${#f}}$C_OFF${line:$((${#pre} + ${#f}))}"
  else DASH_LH="${line:0:${#pre}}[${line:${#pre}:${#f}}]${line:$((${#pre} + ${#f}))}"; fi
}

# --- The stream --------------------------------------------------------------------------------------------------------
# `docker logs -f` writes to a file in the temporary folder of the panel and the pane reads that file. Not a pipe: bash reads a pipe one
# byte at a time (about 500 us a line), a regular file by blocks (about 20 us), which is what makes following a busy log affordable. It
# is the same thing the commands of the panel do (lib/core/jobs.sh). The file is cut down when it grows past DASH_LS_LIMIT.

# Should a stream be running now? The pane has to be on screen and its service running. Sets DASH_LS_WANT to its key and DASH_LS_CN to
# the container name.
dash_ls_wanted() {
  DASH_LS_WANT="" DASH_LS_CN=""
  [ "$DASH_VIEW" = "instances" ] || return 1
  if [ "$DASH_ZOOM" -eq 1 ]; then [ "$DASH_FOCUS" = "logs" ] || return 1; else dash_overview_fits || return 1; fi
  dash_current_target || return 1
  DASH_LS_WANT="$DASH_T_INST/$DASH_T_SVC"
  [ "${ST_STATE[$DASH_LS_WANT]:-}" = "running" ] && [ -n "${ST_CNAME[$DASH_LS_WANT]:-}" ] || { DASH_LS_WANT=""; return 1; }
  DASH_LS_CN="${ST_CNAME[$DASH_LS_WANT]}"
}

# Stops the stream: the process (when it is still ours to stop), the descriptor and the file. $1 = ended: it finished by itself, so there
# is nothing to kill (its pid could already be somebody else's).
dash_ls_stop() { # [ended]
  if [ -n "$DASH_LS_PID" ] && [ "${1:-}" != "ended" ]; then kill "$DASH_LS_PID" 2> /dev/null || true; fi
  # (the braces keep the redirection of the error output temporary: `exec ... 2>` would redirect the panel's for good)
  [ -z "$DASH_LS_FD" ] || { exec {DASH_LS_FD}<&-; } 2> /dev/null || true
  [ -z "$DASH_LS_FILE" ] || rm -f "$DASH_LS_FILE"
  DASH_LS_FD="" DASH_LS_PID="" DASH_LS_KEY="" DASH_LS_FILE="" DASH_LS_STATIC=0 DASH_LS_MORE=0 DASH_LS_PART="" DASH_LS_BYTES=0
}

# Starts the stream of a service. The process is a background job that is let go (disown): when it is killed bash does not print a
# "Terminated" notice on the screen of the panel.
dash_ls_start() { # key container
  dash_ls_stop
  DASH_LS_KEY="$1" DASH_LS_RING=() DASH_LS_PUB=0 DASH_LS_PEND=0 DASH_LS_ENDED=0 DASH_LS_FRESH=0 DASH_LS_AT=-1 DASH_LS_CUT=0 DASH_LS_PART=""
  host_now_us; DASH_LS_START_US="$HOST_NOW_US" DASH_LS_BEGAN="$SECONDS"
  if [ -n "${DELTACTL_TUI_LOGSTREAM:-}" ]; then   # the tests feed the stream from a file that does not grow: its end is the end
    exec {DASH_LS_FD}< "$DELTACTL_TUI_LOGSTREAM"
    DASH_LS_STATIC=1
    return 0
  fi
  job_init
  DASH_LS_SEQ=$((DASH_LS_SEQ + 1))
  DASH_LS_FILE="$JOB_DIR/logs.$DASH_LS_SEQ"
  : > "$DASH_LS_FILE"
  exec {DASH_LS_FD}< "$DASH_LS_FILE"
  ( dk_logs_stream "$2" 200 ) >> "$DASH_LS_FILE" 2>&1 &
  DASH_LS_PID=$!
  disown "$DASH_LS_PID" 2> /dev/null || true
}

# Keeps the ring to DASH_LS_MAX lines (it is cut in steps of 200, not at every line). What was published moves with it, and DASH_LS_CUT
# remembers how many lines went from the front, to move the position of the search too.
dash_ls_trim() {
  local cut
  [ "${#DASH_LS_RING[@]}" -gt $((DASH_LS_MAX + 200)) ] || return 0
  cut=$((${#DASH_LS_RING[@]} - DASH_LS_MAX))
  DASH_LS_RING=("${DASH_LS_RING[@]:$cut}")
  DASH_LS_PUB=$((DASH_LS_PUB > cut ? DASH_LS_PUB - cut : 0))
  DASH_LS_CUT=$((DASH_LS_CUT + cut))
}

# The file only needs what has not been read: once it is past the limit and everything in it was read, it is emptied and opened again from
# the start (the process appends, so it carries on at the new end). A line written between the last read and the cut is lost; it is a matter of
# microseconds, once every few megabytes.
dash_ls_rotate() {
  [ -n "$DASH_LS_FILE" ] && [ -z "$DASH_LS_PART" ] || return 0
  : > "$DASH_LS_FILE"
  { exec {DASH_LS_FD}<&-; } 2> /dev/null || true
  exec {DASH_LS_FD}< "$DASH_LS_FILE"
  DASH_LS_BYTES=0
}

# Is the process that writes the file still running? (A stream with no process, the one of the tests, is "ended" at its end.)
dash_ls_alive() {
  [ -n "$DASH_LS_PID" ] || return 1
  kill -0 "$DASH_LS_PID" 2> /dev/null
}

# Reads the lines that are in the file and have not been read, for at most 50 ms (a log that grows faster than that is read on the next turns:
# DASH_LS_MORE asks the loop to come back soon). Returns 0 when there were new lines. A line that is still being written is kept for the next
# time. When the process has gone and everything it wrote was read, the stream is closed and the pane goes back to polling.
dash_ls_drain() {
  local line got=1 rc n=0 t0 alive=0 k
  DASH_LS_MORE=0
  [ -n "$DASH_LS_FD" ] || return 1
  # Looked at BEFORE reading: if it was gone then, all it wrote is already in the file, and the read below finds the end of it.
  if dash_ls_alive || { [ -z "$DASH_LS_PID" ] && [ "$DASH_LS_STATIC" -eq 0 ]; }; then alive=1; fi
  host_now_us; t0="$HOST_NOW_US"
  while :; do
    rc=0
    IFS= read -r -u "$DASH_LS_FD" line 2> /dev/null || rc=$?
    if [ "$rc" -eq 0 ]; then
      DASH_LS_BYTES=$((DASH_LS_BYTES + ${#line} + 1))
      line="$DASH_LS_PART$line" DASH_LS_PART=""
      # Cleaning costs ~50 us a line and does nothing to a line with no escape, carriage return or tab: only those are cleaned.
      if [[ "$line" == *[$'\033\r\t']* ]]; then tui_strip_ansi "$line"; line="$TUI_OUT"; fi
      DASH_LS_RING+=("$line")
      got=0 n=$((n + 1))
      if [ $((n % 64)) -eq 0 ]; then
        host_now_us
        if [ $((HOST_NOW_US - t0)) -gt 50000 ]; then DASH_LS_MORE=1; break; fi
      fi
    else
      DASH_LS_PART+="$line"   # what there is so far; a line without its end waits for the rest
      break
    fi
  done
  if [ "$DASH_LS_MORE" -eq 0 ]; then
    if [ "$alive" -eq 0 ]; then
      # the end: a last line without a newline is still a line
      if [ -n "$DASH_LS_PART" ]; then tui_strip_ansi "$DASH_LS_PART"; DASH_LS_RING+=("$TUI_OUT"); got=0; fi   # (once: not worth a fast path)
      k="$DASH_LS_KEY"
      dash_ls_stop ended
      DASH_LS_KEY="$k" DASH_LS_ENDED=1 DASH_LS_END_AT="$SECONDS"
    elif [ "$DASH_LS_BYTES" -gt "$DASH_LS_LIMIT" ]; then
      dash_ls_rotate
    fi
  fi
  dash_ls_trim
  return "$got"
}

# Puts the ring in the pane. Returns 0 when it did, 1 when it waited: paused, or the user is reading older lines (the pane stands still
# then, as it always did: new lines would slide what is being read). Then only the count of what is waiting changes.
dash_ls_publish() {
  local text pend
  if [ "$DASH_LS_PAUSED" -eq 1 ] || [ "$DASH_LOG_SCROLL" -gt 0 ]; then
    pend=$((${#DASH_LS_RING[@]} - DASH_LS_PUB))
    [ "$pend" -ge 0 ] || pend=0
    if [ "$pend" -ne "$DASH_LS_PEND" ]; then
      DASH_LS_PEND="$pend"
      [ "$DASH_LS_PAUSED" -eq 0 ] || DASH_DIRTY=1
    fi
    return 1
  fi
  [ "${#DASH_LS_RING[@]}" -gt 0 ] || return 0
  printf -v text '%s\n' "${DASH_LS_RING[@]}"
  DASH_LOGS[$DASH_LS_KEY]="${text%$'\n'}" DASH_LOGS_AT[$DASH_LS_KEY]="$SECONDS" DASH_LOGS_N=$((DASH_LOGS_N + 1))
  DASH_LS_PUB="${#DASH_LS_RING[@]}" DASH_LS_PEND=0
  # The position of the search is a position among the lines shown: lines that left from the front move it (with a filter on it is just forgotten).
  if [ "$DASH_LOG_MIDX" -ge 0 ] && [ "$DASH_LS_CUT" -gt 0 ]; then
    if [ "$DASH_LOG_ERRONLY" -eq 1 ] || [ -n "$DASH_LOG_FILTER" ]; then DASH_LOG_MIDX=-1; else DASH_LOG_MIDX=$((DASH_LOG_MIDX - DASH_LS_CUT)); fi
    [ "$DASH_LOG_MIDX" -ge 0 ] || DASH_LOG_MIDX=-1
  fi
  DASH_LS_CUT=0
  DASH_DIRTY=1
  return 0
}

# A service with no log at all is told so (the pane would say "loading" for ever: with a stream it is not polled).
dash_ls_empty_check() {
  [ -n "$DASH_LS_KEY" ] && [ -z "${DASH_LOGS_AT[$DASH_LS_KEY]+x}" ] || return 0
  if { [ -n "$DASH_LS_FD" ] && [ $((SECONDS - DASH_LS_BEGAN)) -ge 2 ]; } || [ "$DASH_LS_ENDED" -eq 1 ]; then
    DASH_LOGS[$DASH_LS_KEY]="" DASH_LOGS_AT[$DASH_LS_KEY]="$SECONDS" DASH_LOGS_N=$((DASH_LOGS_N + 1))
    DASH_DIRTY=1
  fi
}

# Called every loop: starts the stream when the pane needs one, stops it when it does not, reads what arrived and updates the pane: once a
# second when the pane has the focus, every 2 s when it is just there to be looked at (every update costs a rebuild of the screen).
# Moving the selection stops the old stream at once but starts the new one only when 300 ms went by since the last start, so holding j or k
# does not spawn a docker per key repeat (DASH_LS_DEFER asks the loop to come back).
dash_ls_tick() {
  local now every=2
  DASH_LS_DEFER=0
  if dash_ls_wanted; then
    if [ "$DASH_LS_KEY" != "$DASH_LS_WANT" ]; then
      [ -z "$DASH_LS_FD" ] && [ -z "$DASH_LS_KEY" ] || { dash_ls_stop; DASH_LS_RING=(); }
      host_now_us; now="$HOST_NOW_US"
      if [ $((now - DASH_LS_START_US)) -lt 300000 ]; then DASH_LS_DEFER=1; return 0; fi
      DASH_LS_PAUSED=0 DASH_LOG_MIDX=-1
      dash_ls_start "$DASH_LS_WANT" "$DASH_LS_CN"
    elif [ -z "$DASH_LS_FD" ] && [ "$DASH_LS_ENDED" -eq 1 ] && [ $((SECONDS - DASH_LS_END_AT)) -ge 5 ] && [ "$DASH_LS_FRESH" -eq 0 ]; then
      dash_ls_start "$DASH_LS_WANT" "$DASH_LS_CN"   # it ended and the service is running again: follow it again
    fi
  elif [ -n "$DASH_LS_FD" ] || [ -n "$DASH_LS_KEY" ]; then
    dash_ls_stop
    DASH_LS_RING=()
  fi
  dash_ls_empty_check
  [ -n "$DASH_LS_FD" ] || { [ "$DASH_LS_ENDED" -eq 1 ] && [ "$DASH_LS_FRESH" -eq 1 ] || return 0; }
  [ "$DASH_PAUSED" -eq 0 ] || return 0
  if dash_ls_drain; then DASH_LS_FRESH=1; fi
  { [ "$DASH_FOCUS" = "logs" ] || [ "$DASH_ZOOM" -eq 1 ]; } && every=1
  # The first lines are shown at once; after that, as often as `every` says.
  if [ "$DASH_LS_FRESH" -eq 1 ] && { [ "$DASH_LS_AT" -lt 0 ] || [ $((SECONDS - DASH_LS_AT)) -ge "$every" ]; }; then
    if dash_ls_publish; then DASH_LS_FRESH=0 DASH_LS_AT="$SECONDS"; fi
  fi
}

# Is the pane fed by a stream (so that polling it too would be a waste)?
dash_ls_active() { # key
  [ "$DASH_LS_KEY" = "$1" ] && [ -n "$DASH_LS_FD" ]
}

# --- Keys ----------------------------------------------------------------------------------------------------------------------

dash_logs_pause_toggle() {
  if [ "$DASH_LS_PAUSED" -eq 0 ]; then
    DASH_LS_PAUSED=1 DASH_LS_PUB="${#DASH_LS_RING[@]}"
    [ -n "$DASH_LS_KEY" ] || DASH_LS_PUB=0
    dash_msg info "$(t tui.logs.paused_msg)"
  else
    DASH_LS_PAUSED=0 DASH_LOG_SCROLL=0
    [ -z "$DASH_LS_KEY" ] || dash_ls_publish
    dash_msg info "$(t tui.logs.resumed_msg)"
  fi
  DASH_DIRTY=1
}

# Jumps to the previous (-1) or next (1) line that holds the text of the search, or to the last one (0). The pane scrolls to leave it in the
# middle. DASH_LOG_MIDX remembers which one it is (a position in the lines shown).
dash_logs_jump() { # -1 | 1 | 0
  local key f i n m=-1 first=-1 last=-1 total=0 end
  local -a hits=()
  dash_current_target || return 0
  key="$DASH_T_INST/$DASH_T_SVC"
  f="${DASH_LOG_FIND,,}"
  if [ -z "$f" ]; then dash_msg info "$(t tui.logs.no_find)"; return 0; fi
  dash_logs_select "$key"
  n="${#DASH_LS_SEL[@]}"
  for ((i = 0; i < n; i++)); do
    if [[ "${DASH_LS_SEL[$i],,}" == *"$f"* ]]; then hits+=("$i"); fi
  done
  total="${#hits[@]}"
  if [ "$total" -eq 0 ]; then dash_msg warn "$(t tui.logs.find_none "$DASH_LOG_FIND")"; DASH_LOG_MIDX=-1; return 0; fi
  first="${hits[0]}" last="${hits[$((total - 1))]}"
  case "$1" in
    0) m="$last" ;;
    1) m="$first"; for i in "${hits[@]}"; do if [ "$i" -gt "$DASH_LOG_MIDX" ]; then m="$i"; break; fi; done ;;
    *) m="$last"; for ((i = total - 1; i >= 0; i--)); do if [ "${hits[$i]}" -lt "$DASH_LOG_MIDX" ]; then m="${hits[$i]}"; break; fi; done ;;
  esac
  DASH_LOG_MIDX="$m"
  end=$((m + 1 + DASH_LOG_INNER / 2))
  [ "$end" -le "$n" ] || end="$n"
  DASH_LOG_SCROLL=$((n - end))
  for ((i = 0; i < total; i++)); do [ "${hits[$i]}" -ne "$m" ] || break; done
  dash_msg info "$(t tui.logs.find_at "$((i + 1))" "$total" "$DASH_LOG_FIND")"
  DASH_DIRTY=1
}

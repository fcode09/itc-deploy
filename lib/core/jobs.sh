#!/usr/bin/env bash
# shellcheck disable=SC2034  # the JOB_* variables are read by the panel that draws them
# A single background command whose output the panel shows live: the panel keeps drawing and reading keys while
# the command runs. The command gets no input (stdin is /dev/null, so a prompt ends at once instead of hanging),
# its output goes to a file and job_poll reads only the lines added since the last call (no fork, no re-reading).
# Sourced by lib/bootstrap.sh.

JOB_DIR="" JOB_PID="" JOB_TITLE="" JOB_RC="" JOB_FD="" JOB_CANCELLED=0 JOB_KILLED=0
JOB_START_US=0 JOB_END_US=0 JOB_SEQ=0 JOB_TOTAL=0 JOB_MAX=2000
JOB_LINES=()

job_init() {
  [ -n "$JOB_DIR" ] && [ -d "$JOB_DIR" ] || JOB_DIR="$(mktemp -d)"
}

# Removes the temporary files (call it when the panel ends).
job_cleanup() {
  job_cancel 2>/dev/null || true
  [ -z "$JOB_FD" ] || { exec {JOB_FD}<&-; JOB_FD=""; }
  [ -z "$JOB_DIR" ] || rm -rf "$JOB_DIR"
  JOB_DIR=""
}

job_running() { [ -n "$JOB_PID" ] && [ -z "$JOB_RC" ]; }

# Starts a command in the background: job_start <title> <command> [args...]. Fails when another one is running.
job_start() {
  local title="$1" out
  shift
  job_running && return 1
  job_init
  [ -z "$JOB_FD" ] || { exec {JOB_FD}<&-; JOB_FD=""; }
  JOB_SEQ=$((JOB_SEQ + 1))
  out="$JOB_DIR/out.$JOB_SEQ"
  : > "$out"
  JOB_LINES=() JOB_TOTAL=0 JOB_RC="" JOB_CANCELLED=0 JOB_KILLED=0 JOB_TITLE="$title"
  exec {JOB_FD}< "$out"
  host_now_us; JOB_START_US="$HOST_NOW_US"; JOB_END_US=0
  # setsid gives the command its own process group, so cancelling stops it and everything it started.
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" < /dev/null > "$out" 2>&1 &
  else
    "$@" < /dev/null > "$out" 2>&1 &
  fi
  JOB_PID=$!
}

# Appends a line to the buffer (kept to JOB_MAX lines).
job_add() { # line
  local line="${1//$'\r'/}"
  line="${line//$'\t'/    }"
  JOB_LINES+=("$line")
  JOB_TOTAL=$((JOB_TOTAL + 1))
  if [ "${#JOB_LINES[@]}" -gt $((JOB_MAX + 200)) ]; then
    JOB_LINES=("${JOB_LINES[@]:200}")
  fi
}

# Reads what the command wrote since the last call and detects its end. Returns 0 when something changed (new lines
# or the command finished), 1 when nothing did.
job_poll() {
  local line="" changed=1 now
  [ -n "$JOB_PID" ] || return 1
  if [ -n "$JOB_FD" ]; then
    while IFS= read -r line <&"$JOB_FD"; do job_add "$line"; changed=0; line=""; done
    [ -z "$line" ] || { job_add "$line"; changed=0; }
  fi
  if [ -z "$JOB_RC" ] && ! kill -0 "$JOB_PID" 2>/dev/null; then
    # The command ended: read the last lines and collect its exit status.
    if [ -n "$JOB_FD" ]; then
      line=""
      while IFS= read -r line <&"$JOB_FD"; do job_add "$line"; line=""; done
      [ -z "$line" ] || job_add "$line"
      exec {JOB_FD}<&-; JOB_FD=""
    fi
    wait "$JOB_PID" 2>/dev/null
    JOB_RC=$?
    host_now_us; JOB_END_US="$HOST_NOW_US"
    changed=0
  elif [ -z "$JOB_RC" ] && [ "$JOB_CANCELLED" -eq 1 ] && [ "$JOB_KILLED" -eq 0 ]; then
    host_now_us; now="$HOST_NOW_US"
    # A command that ignores the polite signal is killed after two seconds.
    if [ $((now - JOB_END_US)) -ge 2000000 ]; then job_signal KILL; JOB_KILLED=1; fi
  fi
  return "$changed"
}

job_signal() { # signal
  [ -n "$JOB_PID" ] || return 1
  if command -v setsid >/dev/null 2>&1; then
    kill -"$1" -- "-$JOB_PID" 2>/dev/null || kill -"$1" "$JOB_PID" 2>/dev/null || true
  else
    pkill -"$1" -P "$JOB_PID" 2>/dev/null || true
    kill -"$1" "$JOB_PID" 2>/dev/null || true
  fi
}

# Asks the running command to stop.
job_cancel() {
  job_running || return 1
  JOB_CANCELLED=1
  host_now_us; JOB_END_US="$HOST_NOW_US"   # while it runs, JOB_END_US holds the moment of the request
  job_signal TERM
}

# Seconds the command has been running (or ran for).
job_elapsed() {
  local end="$JOB_END_US"
  [ "$JOB_START_US" -gt 0 ] || { printf '0'; return 0; }
  if job_running && [ "$JOB_CANCELLED" -eq 0 ]; then host_now_us; end="$HOST_NOW_US"; fi
  [ "$end" -gt 0 ] || { host_now_us; end="$HOST_NOW_US"; }
  printf '%s' $(((end - JOB_START_US) / 1000000))
}

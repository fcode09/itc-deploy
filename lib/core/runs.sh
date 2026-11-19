#!/usr/bin/env bash
# shellcheck disable=SC2034  # RUN and the RUNS_* variables are read by lib/cmd/runs.sh
# Recorded runs. Every operation that changes something (deploy, init, adopt, rollback, load, stop, down, new) runs inside a
# record: its own folder under instances/.deltactl/runs/<id>/ with the metadata (`meta`) and the whole output (`out.log`), one line
# in the index (`runs.idx`), and a lock so that two operations never change things at the same time. Queries, the menu and the
# wizards are not recorded. Sourced on demand by ./deltactl; not executed.
#
# How it works: the command is started again as a child of the wrapper (`bash deltactl <command> ...`) with DELTACTL_RUN_ID set,
# its output goes through `tee` into the log, and the wrapper writes the result when the child ends. The commands themselves do
# not know about any of this. Standard error is merged into standard output (one ordered log).
#
# State (all private, mode 700/600, under instances/.deltactl/, which is never versioned):
#   runs/<id>/meta        KEY=VALUE lines (read as data, never sourced)
#   runs/<id>/out.log     what the command printed, colours included
#   runs.idx              id, started, command, instance, state, exit code, duration in ms (tab separated, append only)
#   active/<id>           the PID of the wrapper while the run is going (a missing PID means it was interrupted)
#   locks/mutation.lock   folder created with mkdir (atomic); pid inside
# DELTACTL_NO_RUNS=1 turns the whole thing off.

declare -gA RUN=()
RUNS_OWNER_PID="" RUNS_OWNER_RUN="" RUNS_OWNER_WHAT=""

runs_dir() { printf '%s/.deltactl' "$INSTANCES_DIR"; }

# Operations that change something are recorded; queries, the menu and the wizards (which ask questions) are not.
runs_is_mutation() { # command [args...]
  local c="$1"
  shift
  case "$c" in
    deploy | rollback | load | init | adopt | stop | down) return 0 ;;
    new)
      [ "$#" -gt 0 ] || return 1
      case " $* " in *" --wizard "*) return 1 ;; esac
      return 0
      ;;
    *) return 1 ;;
  esac
}

# The instance an operation is about (the first argument that is not a flag), or "-".
runs_instance_of() { # command [args...]
  local c="$1" a
  shift
  if [ "$c" != "load" ]; then
    for a in "$@"; do
      case "$a" in -*) ;; *) printf '%s' "$a"; return 0 ;; esac
    done
  fi
  printf '%s' "-"
}

# Is that PID alive and still one of ours? (A reused PID belongs to some other program: it must mention deltactl.)
runs_pid_alive() { # pid
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2> /dev/null || return 1
  if [ -r "/proc/$pid/cmdline" ]; then
    tr '\0' ' ' < "/proc/$pid/cmdline" 2> /dev/null | grep -q "deltactl" || return 1
  fi
  return 0
}

runs_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- Metadata -----------------------------------------------------------------------------------------------------------

runs_meta_write() { # dir   (from RUN)
  local dir="$1" tmp k
  tmp="$(mktemp "$dir/.meta.XXXXXX")" || return 1
  for k in RUN_ID OP ARGS INSTANCE STATE STARTED_AT ENDED_AT DURATION_MS RC PID HOST USER VERSION; do
    printf '%s=%s\n' "$k" "${RUN[$k]:-}"
  done > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp"
  mv -f "$tmp" "$dir/meta" || { rm -f "$tmp"; return 1; }
}

runs_meta_read() { # dir -> RUN
  local line k
  RUN=()
  [ -r "$1/meta" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    k="${line%%=*}"
    [[ "$k" =~ ^[A-Z_]+$ ]] && RUN[$k]="${line#*=}"
  done < "$1/meta"
  return 0
}

# One line of the index from RUN.
runs_idx_add() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${RUN[RUN_ID]}" "${RUN[STARTED_AT]}" "${RUN[OP]}" "${RUN[INSTANCE]}" "${RUN[STATE]}" \
    "${RUN[RC]}" "${RUN[DURATION_MS]}" >> "$(runs_dir)/runs.idx"
}

# What a finished command's exit code means: 0 succeeded; 129, 130 and 143 (hang-up, Ctrl+C, termination) canceled.
runs_state_of() { # exit_code
  case "$1" in 0) printf succeeded ;; 129 | 130 | 143) printf canceled ;; *) printf failed ;; esac
}

# --- Lock ---------------------------------------------------------------------------------------------------------------

# Takes the lock of the mutation or tells who has it (RUNS_OWNER_*). A lock whose owner is gone is taken over.
runs_lock() { # run_id what
  local base d pid i
  base="$(runs_dir)/locks"
  d="$base/mutation.lock"
  mkdir -p "$base" || return 2
  for i in 1 2; do
    if mkdir "$d" 2> /dev/null; then
      printf '%s\n' "$$" > "$d/pid"
      printf '%s\n' "$1" > "$d/run"
      printf '%s\n' "$2" > "$d/what"
      return 0
    fi
    pid="$(cat "$d/pid" 2> /dev/null || true)"
    # The owner may be between `mkdir` and writing its PID: give it a moment before calling the lock stale.
    if [ -z "$pid" ]; then sleep 0.2; pid="$(cat "$d/pid" 2> /dev/null || true)"; fi
    if runs_pid_alive "$pid"; then
      RUNS_OWNER_PID="$pid"
      RUNS_OWNER_RUN="$(cat "$d/run" 2> /dev/null || true)"
      RUNS_OWNER_WHAT="$(cat "$d/what" 2> /dev/null || true)"
      return 1
    fi
    rm -rf "$d"
  done
  return 1
}

runs_unlock() {
  local d
  d="$(runs_dir)/locks/mutation.lock"
  if [ "$(cat "$d/pid" 2> /dev/null || true)" = "$$" ]; then rm -rf "$d"; fi
}

# --- Recovery -----------------------------------------------------------------------------------------------------------

# A run whose wrapper is gone (killed, power loss) is still marked as running: it is closed as `interrupted`, never as a success.
runs_recover() {
  local f id dir pid now
  for f in "$(runs_dir)"/active/*; do
    [ -e "$f" ] || continue
    id="${f##*/}"
    pid="$(cat "$f" 2> /dev/null || true)"
    runs_pid_alive "$pid" && continue
    dir="$(runs_dir)/runs/$id"
    if runs_meta_read "$dir"; then
      now="$(runs_now_iso)"
      RUN[STATE]="interrupted" RUN[ENDED_AT]="$now" RUN[RC]="-"
      runs_meta_write "$dir" && runs_idx_add
      warn "$(t runs.recovered "$id")"
    fi
    rm -f "$f"
  done
}

# --- The recorded execution ---------------------------------------------------------------------------------------------

# Runs the command inside a record and exits with its exit code. It never returns.
runs_exec() { # command args...
  local cmd="$1" state id dir log rc t0 t1 inst what
  local -a envs=()
  shift
  state="$(runs_dir)"
  umask 077
  mkdir -p "$state/runs" "$state/active" 2> /dev/null || die "$(t runs.cannot_record "$state")"
  runs_recover
  what="$cmd $*"
  id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  if ! runs_lock "$id" "$what"; then
    die "$(t runs.busy "$RUNS_OWNER_WHAT" "$RUNS_OWNER_RUN" "$RUNS_OWNER_PID")"
  fi
  dir="$state/runs/$id"
  log="$dir/out.log"
  mkdir -p "$dir" 2> /dev/null && : > "$log" || { runs_unlock; die "$(t runs.cannot_record "$state")"; }
  inst="$(runs_instance_of "$cmd" "$@")"
  host_now_us; t0="$HOST_NOW_US"
  RUN=()
  RUN[RUN_ID]="$id" RUN[OP]="$cmd" RUN[ARGS]="${*//$'\n'/ }" RUN[INSTANCE]="$inst" RUN[STATE]="running"
  RUN[STARTED_AT]="$(runs_now_iso)" RUN[ENDED_AT]="" RUN[DURATION_MS]="" RUN[RC]="" RUN[PID]="$$"
  RUN[HOST]="$(host_name)" RUN[USER]="${USER:-${LOGNAME:-}}" RUN[VERSION]="$DELTACTL_VERSION"
  runs_meta_write "$dir" || { runs_unlock; die "$(t runs.cannot_record "$state")"; }
  printf '%s\n' "$$" > "$state/active/$id"
  envs=(DELTACTL_RUN_ID="$id" DELTACTL_RUN_DIR="$dir")
  # The child's output is a pipe: it would turn the colours and the width off. When the wrapper writes to a terminal, the child
  # is told what the terminal can do.
  if [ -t 1 ]; then
    if [ "$UI_RICH" -eq 1 ]; then envs+=(DELTACTL_UI=rich); else envs+=(DELTACTL_UI=plain); fi
    if [ "$UI_COLOR" -eq 1 ]; then envs+=(DELTACTL_COLOR=always); else envs+=(DELTACTL_COLOR=never); fi
    envs+=(COLUMNS="${COLUMNS:-$(tput cols 2> /dev/null || echo 80)}")
  fi
  # Ctrl+C and friends reach the child (same process group); the wrapper stays to write the result.
  trap ':' INT TERM HUP
  set +e
  env "${envs[@]}" bash "$ROOT/deltactl" "$cmd" "$@" 2>&1 | tee -ia "$log"
  rc="${PIPESTATUS[0]}"
  set -e
  host_now_us; t1="$HOST_NOW_US"
  RUN[STATE]="$(runs_state_of "$rc")" RUN[RC]="$rc" RUN[ENDED_AT]="$(runs_now_iso)" RUN[DURATION_MS]="$(((t1 - t0) / 1000))"
  runs_meta_write "$dir" || true
  runs_idx_add || true
  rm -f "$state/active/$id"
  runs_unlock
  exit "$rc"
}

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
# What it measures (all of it with Bash builtins and /proc, no extra tools):
#   CPU_MS         user+system CPU of everything the command started (the `times` builtin of the wrapper, before and after)
#   DOCKER_*       calls to docker and the time spent inside them (a shell function `docker` in the child appends to docker.tsv)
#   PEAK_RSS_KB    highest sum of the resident memory of the command's process tree, sampled once a second (samples.tsv); an
#                  approximation (shared pages are counted once per process) and short peaks between samples are missed
#   OUT_LINES/BYTES  size of what it printed
#   FOOT_BEFORE/AFTER  the instance's containers (running/total, memory in bytes, restarts) before and after the operation
# It does NOT include what dockerd and the containers themselves use: that is what FOOT_* shows.
#
# State (all private, mode 700/600, under instances/.deltactl/, which is never versioned):
#   runs/<id>/meta        KEY=VALUE lines (read as data, never sourced)
#   runs/<id>/out.log     what the command printed, colours included
#   runs/<id>/samples.tsv elapsed ms, RSS of the tree in KB, number of processes (one line per second)
#   runs/<id>/docker.tsv  duration in ms and the docker subcommand of every call
#   runs.idx              id, started, command, instance, state, exit code, duration in ms (tab separated, append only)
#   active/<id>           the PID of the wrapper while the run is going (a missing PID means it was interrupted)
#   pending/<id>          an interrupted run nobody has reviewed ("command<TAB>instance"): while one exists no operation runs;
#                         `runs resolve <id>` clears it. Nothing says what an interrupted run left half done, so someone has to look
#   locks/mutation.lock   folder created with mkdir (atomic); pid inside
# DELTACTL_NO_RUNS=1 turns the whole thing off; DELTACTL_RUN_FOOTPRINT=0 skips the before/after look at the containers.

declare -gA RUN=()
RUNS_OWNER_PID="" RUNS_OWNER_RUN="" RUNS_OWNER_WHAT="" RUNS_FOOT="" RUNS_SAMPLER=""
RUNS_META_KEYS=(RUN_ID OP ARGS INSTANCE STATE STARTED_AT ENDED_AT DURATION_MS RC PID HOST USER VERSION
  CPU_MS DOCKER_CALLS DOCKER_MS DOCKER_SLOW PEAK_RSS_KB PEAK_PROCS OUT_LINES OUT_BYTES FOOT_BEFORE FOOT_AFTER RESOLVED_AT NOTE)

runs_dir() { printf '%s/.deltactl' "$INSTANCES_DIR"; }

# Operations that change something are recorded; queries, the menu and the wizards (which ask questions) are not.
runs_is_mutation() { # command [args...]
  local c="$1"
  shift
  case "$c" in
    deploy | rollback | load | init | adopt | stop | down) return 0 ;;
    service) case "${1:-}" in add | remove | set) return 0 ;; esac; return 1 ;;
    secret) case "${1:-}" in add) return 0 ;; esac; return 1 ;;
    mongo) case " $* " in *" --apply "*) return 0 ;; esac; return 1 ;;
    access) case " $* " in *" --apply "* | *" --remove "*) return 0 ;; esac; return 1 ;;
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
  if [ "$c" = "mongo" ]; then printf '%s' "-"; return 0; fi   # (it is about the server, not an instance)
  if [ "$c" = "service" ] || [ "$c" = "secret" ]; then shift; fi   # (service <add|remove|set> <instance> ... and secret add <instance> ...)
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
  for k in "${RUNS_META_KEYS[@]}"; do
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

# Is another operation holding the lock right now? Only looks, takes nothing (runs_lock is the one that takes it): 0 with RUNS_OWNER_* telling who,
# 1 when there is no lock or its owner is gone. A lock with no PID yet (its owner is between creating it and writing it) counts as held.
runs_busy() {
  local d pid
  d="$(runs_dir)/locks/mutation.lock"
  [ -d "$d" ] || return 1
  pid="$(cat "$d/pid" 2> /dev/null || true)"
  if [ -n "$pid" ] && ! runs_pid_alive "$pid"; then return 1; fi
  RUNS_OWNER_PID="${pid:-?}"
  RUNS_OWNER_RUN="$(cat "$d/run" 2> /dev/null || true)"
  RUNS_OWNER_WHAT="$(cat "$d/what" 2> /dev/null || true)"
  return 0
}

runs_unlock() {
  local d
  d="$(runs_dir)/locks/mutation.lock"
  if [ "$(cat "$d/pid" 2> /dev/null || true)" = "$$" ]; then rm -rf "$d"; fi
}

# --- Recovery -----------------------------------------------------------------------------------------------------------

# A run whose wrapper is gone (killed, power loss) is still marked as running: it is closed as `interrupted`, never as a success, and
# it is left pending review (pending/<id>): until someone looks at what it did and says so, no new operation starts.
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
      mkdir -p "$(runs_dir)/pending" && printf '%s\t%s\n' "${RUN[OP]:-?}" "${RUN[INSTANCE]:--}" > "$(runs_dir)/pending/$id"
      warn "$(t runs.recovered "$id")"
    fi
    rm -f "$f"
  done
}

# The interrupted runs nobody has reviewed: how many (RUNS_PEND_N) and the first one (RUNS_PEND_ID, RUNS_PEND_WHAT = "command instance").
# Returns 0 when there is at least one.
RUNS_PEND_N=0 RUNS_PEND_ID="" RUNS_PEND_WHAT=""
runs_pending() {
  local f op="" ins=""
  RUNS_PEND_N=0 RUNS_PEND_ID="" RUNS_PEND_WHAT=""
  for f in "$(runs_dir)"/pending/*; do
    [ -f "$f" ] || continue
    RUNS_PEND_N=$((RUNS_PEND_N + 1))
    if [ -z "$RUNS_PEND_ID" ]; then
      RUNS_PEND_ID="${f##*/}"
      IFS=$'\t' read -r op ins 2> /dev/null < "$f" || true
      RUNS_PEND_WHAT="$op $ins"
    fi
  done
  [ "$RUNS_PEND_N" -gt 0 ]
}

# --- Measuring ----------------------------------------------------------------------------------------------------------

# "0m1.340s" as milliseconds.
runs_t2ms() { # text
  local t="$1" m s sec frac
  m="${t%%m*}"; s="${t#*m}"; s="${s%s}"
  sec="${s%.*}"; frac="${s#*.}000"
  printf '%d' $((10#${m:-0} * 60000 + 10#${sec:-0} * 1000 + 10#${frac:0:3}))
}

# CPU of everything the wrapper has waited for so far (user+system of its children, descendants included), in ms, into RUNS_CPU.
# `times` has to run in this very shell, not in a subshell: its figures are the shell's own.
RUNS_CPU=0
runs_cpu_now() { # scratch_file
  local l1 l2 u s
  times > "$1"
  { read -r l1; read -r l2; } < "$1"
  read -r u s <<< "$l2"
  RUNS_CPU=$(($(runs_t2ms "$u") + $(runs_t2ms "$s")))
}

# Inside the recorded child: every call to docker is timed and appended to docker.tsv. A shell function is the one place all of
# them go through (also the ones in subshells and pipelines, where a counter variable would be lost).
runs_child_init() {
  [ -n "${DELTACTL_RUN_DIR:-}" ] && [ -d "$DELTACTL_RUN_DIR" ] || return 0
  # shellcheck disable=SC2329  # called by every adapter that runs `docker`, not from here
  docker() {
    local t0 t1 rc=0 what="${1:-}" a
    if [ "$what" = "compose" ]; then   # `compose --env-file x up -d`: the verb is what tells calls apart
      for a in "${@:2}"; do
        case "$a" in up | down | pull | stop | start | restart | ps | config | logs | run | exec | rm | version | images | build) what="compose $a"; break ;; esac
      done
    else
      what="$what ${2:-}"
    fi
    host_now_us; t0="$HOST_NOW_US"
    command docker "$@" || rc=$?
    host_now_us; t1="$HOST_NOW_US"
    printf '%s\t%s\n' $(((t1 - t0) / 1000)) "$what" >> "$DELTACTL_RUN_DIR/docker.tsv" 2> /dev/null || true
    return "$rc"
  }
}

# Samples, once a second, the resident memory and the number of processes of the tree that hangs from the wrapper. Runs in the
# background until the wrapper ends or kills it. It must cost next to nothing, so it only walks the command's own tree: each
# process lists its children in /proc/<pid>/task/*/children and its resident pages are the 2nd number of /proc/<pid>/statm
# (a handful of small reads per sample, whatever else runs on the machine). Kernels without the `children` files fall back to
# reading every /proc/*/stat, which grows with the number of processes.
runs_sampler() { # root_pid dir
  local root="$1" dir="$2" me="$BASHPID" pagekb t0 now sum n fast=0 p k c i line pid st changed
  local -a queue=() f=()
  local -A par=() rs=() inside=()
  [ -d /proc/self ] || return 0
  pagekb=$(($(getconf PAGESIZE 2> /dev/null || echo 4096) / 1024))
  [ -r "/proc/$root/task/$root/children" ] && fast=1
  host_now_us; t0="$HOST_NOW_US"
  while kill -0 "$root" 2> /dev/null; do
    sum=0 n=0
    if [ "$fast" -eq 1 ]; then
      queue=("$root") i=0
      while [ "$i" -lt "${#queue[@]}" ]; do
        p="${queue[i]}"
        i=$((i + 1))
        for c in /proc/"$p"/task/*/children; do
          line=""
          read -r line 2> /dev/null < "$c" || true   # no trailing newline: read fails but still fills `line`
          for k in $line; do [ "$k" = "$me" ] || queue+=("$k"); done
        done
        [ "$p" != "$root" ] || continue   # the wrapper itself waits: its own memory is not the command's
        read -r _ k _ 2> /dev/null < "/proc/$p/statm" || continue   # (the 2> goes first: a file that vanished is reported by the redirection itself)
        sum=$((sum + k * pagekb)) n=$((n + 1))
      done
    else
      par=() rs=() inside=()
      for st in /proc/[0-9]*/stat; do
        read -r line < "$st" 2> /dev/null || continue
        pid="${st#/proc/}"; pid="${pid%/stat}"
        line="${line#*) }"
        # After the command name: state, ppid, ... the resident pages are the 22nd of these fields.
        read -ra f <<< "$line"
        par[$pid]="${f[1]:-0}" rs[$pid]=$((${f[21]:-0} * pagekb))
      done
      inside=([$root]=1) changed=1
      while [ "$changed" -eq 1 ]; do
        changed=0
        for pid in "${!par[@]}"; do
          [ -z "${inside[$pid]:-}" ] || continue
          if [ -n "${inside[${par[$pid]}]:-}" ] && [ "$pid" != "$me" ] && [ "${par[$pid]}" != "$me" ]; then inside[$pid]=1; changed=1; fi
        done
      done
      for pid in "${!inside[@]}"; do
        [ "$pid" != "$root" ] || continue
        sum=$((sum + ${rs[$pid]:-0})) n=$((n + 1))
      done
    fi
    host_now_us; now="$HOST_NOW_US"
    printf '%s\t%s\t%s\n' $(((now - t0) / 1000)) "$sum" "$n" >> "$dir/samples.tsv" 2> /dev/null || true
    sleep 1
  done
}

# The containers of an instance before or after an operation, into RUNS_FOOT: "running/total memory_bytes restarts". It is a look,
# not a measurement of the operation: two docker queries, skipped with DELTACTL_RUN_FOOTPRINT=0 or when there is no docker.
runs_footprint() { # instance
  local ids proj svc st hl img started nm pid rs run=0 tot=0 mem=0 rst=0
  RUNS_FOOT=""
  [ "$1" != "-" ] && [ "${DELTACTL_RUN_FOOTPRINT:-1}" != "0" ] && host_has docker || return 0
  ids="$(dk_instance_container_ids "$1" 2> /dev/null || true)"
  if [ -z "$ids" ]; then RUNS_FOOT="0/0 0 0"; return 0; fi
  # shellcheck disable=SC2086  # one argument per container id
  while IFS='|' read -r proj svc st hl img started nm pid rs; do
    tot=$((tot + 1))
    [[ "$rs" =~ ^[0-9]+$ ]] && rst=$((rst + rs))
    if [ "$st" = "running" ]; then
      run=$((run + 1))
      if host_cg_resolve "$pid" && host_cg_mem "$HOST_CG_MEM" "$HOST_CG_VER"; then mem=$((mem + CG_MEM_BYTES)); fi
    fi
  done < <(dk_container_rows $ids)
  RUNS_FOOT="$run/$tot $mem $rst"
}

# Summary of what the child did, from the files it left, into RUN.
runs_collect() { # dir
  local dir="$1" calls ms slow lines bytes peak procs
  if [ -s "$dir/docker.tsv" ]; then
    read -r calls ms slow < <(awk -F'\t' '{ n++; s += $1; if ($1 > m) { m = $1; c = $2 } } END { printf "%d %d %s|%s\n", n, s, m + 0, c }' "$dir/docker.tsv")
    RUN[DOCKER_CALLS]="$calls" RUN[DOCKER_MS]="$ms" RUN[DOCKER_SLOW]="$slow"
  else
    RUN[DOCKER_CALLS]=0 RUN[DOCKER_MS]=0 RUN[DOCKER_SLOW]=""
  fi
  if [ -s "$dir/samples.tsv" ]; then
    read -r peak procs < <(awk -F'\t' '$2 > m { m = $2; p = $3 } END { printf "%d %d\n", m + 0, p + 0 }' "$dir/samples.tsv")
    RUN[PEAK_RSS_KB]="$peak" RUN[PEAK_PROCS]="$procs"
  fi
  lines="$(wc -l < "$dir/out.log" 2> /dev/null | tr -d ' ')"
  bytes="$(wc -c < "$dir/out.log" 2> /dev/null | tr -d ' ')"
  RUN[OUT_LINES]="${lines:-0}" RUN[OUT_BYTES]="${bytes:-0}"
}

# --- The recorded execution ---------------------------------------------------------------------------------------------

# Runs the command inside a record and exits with its exit code. It never returns.
runs_exec() { # command args...
  local cmd="$1" state id dir log rc t0 t1 inst what c0 c1
  local -a envs=()
  shift
  state="$(runs_dir)"
  umask 077
  mkdir -p "$state/runs" "$state/active" 2> /dev/null || die "$(t runs.cannot_record "$state")"
  runs_recover
  if runs_pending; then die "$(t runs.blocked "$RUNS_PEND_ID" "$RUNS_PEND_WHAT" "$RUNS_PEND_N")"; fi
  what="$cmd $*"
  id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  if ! runs_lock "$id" "$what"; then
    die "$(t runs.busy "$RUNS_OWNER_WHAT" "$RUNS_OWNER_RUN" "$RUNS_OWNER_PID")"
  fi
  dir="$state/runs/$id"
  log="$dir/out.log"
  if ! { mkdir -p "$dir" 2> /dev/null && : > "$log"; }; then runs_unlock; die "$(t runs.cannot_record "$state")"; fi
  inst="$(runs_instance_of "$cmd" "$@")"
  host_now_us; t0="$HOST_NOW_US"
  RUN=()
  RUN[RUN_ID]="$id" RUN[OP]="$cmd" RUN[ARGS]="${*//$'\n'/ }" RUN[INSTANCE]="$inst" RUN[STATE]="running"
  RUN[STARTED_AT]="$(runs_now_iso)" RUN[ENDED_AT]="" RUN[DURATION_MS]="" RUN[RC]="" RUN[PID]="$$"
  RUN[HOST]="$(host_name)" RUN[USER]="${USER:-${LOGNAME:-}}" RUN[VERSION]="$DELTACTL_VERSION"
  # What the instance looks like before (only for operations that touch its containers).
  case "$cmd" in deploy | init | rollback | stop | down) runs_footprint "$inst"; RUN[FOOT_BEFORE]="$RUNS_FOOT" ;; esac
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
  runs_cpu_now "$dir/.times0"; c0="$RUNS_CPU"
  runs_sampler "$$" "$dir" &
  RUNS_SAMPLER=$!
  env "${envs[@]}" bash "$ROOT/deltactl" "$cmd" "$@" 2>&1 | tee -ia "$log"
  rc="${PIPESTATUS[0]}"
  # CPU is read before the sampler is stopped: a child that has not been waited for is not in the figures yet.
  runs_cpu_now "$dir/.times1"; c1="$RUNS_CPU"
  kill "$RUNS_SAMPLER" 2> /dev/null; wait "$RUNS_SAMPLER" 2> /dev/null
  rm -f "$dir/.times0" "$dir/.times1"
  set -e
  host_now_us; t1="$HOST_NOW_US"
  RUN[STATE]="$(runs_state_of "$rc")" RUN[RC]="$rc" RUN[ENDED_AT]="$(runs_now_iso)" RUN[DURATION_MS]="$(((t1 - t0) / 1000))"
  RUN[CPU_MS]="$((c1 - c0))"
  runs_collect "$dir"
  case "$cmd" in deploy | init | rollback | stop | down) runs_footprint "$inst"; RUN[FOOT_AFTER]="$RUNS_FOOT" ;; esac
  runs_meta_write "$dir" || true
  runs_idx_add || true
  rm -f "$state/active/$id"
  runs_unlock
  exit "$rc"
}

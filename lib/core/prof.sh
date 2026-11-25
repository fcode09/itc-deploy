#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2086  # the PROF_* variables are read by the panel; the stat fields are split on purpose
# Optional profile of the interactive panel: DELTACTL_PROF=1 ./deltactl. It answers "where does the CPU of the panel go?" with figures
# measured on the machine that has the problem, instead of guesses. It is off by default and then each hook costs one test.
#
#   prof_init            reads the environment; call it once before the loop (it turns the profile on only if bash has EPOCHREALTIME)
#   prof_b <name>        starts the clock of a phase       prof_e <name>   stops it and adds the time to that phase
#   prof_count <name>    counts an event with no duration (a process the panel started in the background)
#   prof_tick            writes the report when 30 s passed since the last one (the loop calls it every turn)
#   prof_dump            writes the report now (the panel does it when it leaves)
#
# The report is a small text file, DELTACTL_PROF_FILE or ${TMPDIR:-/tmp}/deltactl-prof-<pid>.txt, rewritten at each dump, never drawn
# on the screen. It gives the wall time of the run, the CPU of the panel itself and of the processes it waited for (the children:
# ps, ss, docker...), and for every phase the calls, the total, the average and the share of the wall time.

PROF_ON=0 PROF_T0=0 PROF_DUMP_AT=0 PROF_FILE="" PROF_HZ=100
declare -gA PROF_S=() PROF_N=() PROF_T=()

prof_init() {
  [ "${DELTACTL_PROF:-0}" = "1" ] && [ -n "${EPOCHREALTIME:-}" ] || return 0
  PROF_ON=1
  PROF_T0="${EPOCHREALTIME/[.,]/}"
  PROF_DUMP_AT="$SECONDS"
  PROF_FILE="${DELTACTL_PROF_FILE:-${TMPDIR:-/tmp}/deltactl-prof-$$.txt}"
  PROF_HZ="$(getconf CLK_TCK 2> /dev/null || echo 100)"
  [[ "$PROF_HZ" =~ ^[1-9][0-9]*$ ]] || PROF_HZ=100
}

prof_b() {
  [ "$PROF_ON" -eq 1 ] || return 0
  PROF_S[$1]="${EPOCHREALTIME/[.,]/}"
}

prof_e() {
  [ "$PROF_ON" -eq 1 ] || return 0
  local now="${EPOCHREALTIME/[.,]/}"
  PROF_N[$1]=$((${PROF_N[$1]:-0} + 1))
  PROF_T[$1]=$((${PROF_T[$1]:-0} + now - ${PROF_S[$1]:-$now}))
}

prof_count() {
  [ "$PROF_ON" -eq 1 ] || return 0
  PROF_N[$1]=$((${PROF_N[$1]:-0} + 1))
}

prof_tick() {
  [ "$PROF_ON" -eq 1 ] || return 0
  [ $((SECONDS - PROF_DUMP_AT)) -ge 30 ] || return 0
  prof_dump
}

# CPU ticks of this process and of the children it waited for, from /proc/<pid>/stat (the fields after the command name).
prof_cpu() { # sets PROF_SELF and PROF_KIDS in ticks
  local stat rest
  PROF_SELF=0 PROF_KIDS=0
  stat="$(< "/proc/$$/stat")" 2> /dev/null || return 0
  rest="${stat##*) }"
  set -- $rest
  PROF_SELF=$((${12:-0} + ${13:-0}))
  PROF_KIDS=$((${14:-0} + ${15:-0}))
}

prof_dump() {
  [ "$PROF_ON" -eq 1 ] || return 0
  local now="${EPOCHREALTIME/[.,]/}" wall k t n lines="" me kids
  wall=$((now - PROF_T0))
  [ "$wall" -gt 0 ] || wall=1
  prof_cpu
  # tenths of a percent of one core: (ticks / HZ) seconds of CPU over wall microseconds
  me=$((PROF_SELF * 1000000000 / PROF_HZ / wall))
  kids=$((PROF_KIDS * 1000000000 / PROF_HZ / wall))
  for k in "${!PROF_N[@]}"; do
    n="${PROF_N[$k]}" t="${PROF_T[$k]:-0}"
    if [ "$t" -gt 0 ]; then
      lines+="$t|$(printf '%-24s %8d calls %10d.%01d ms total %8d.%02d ms avg %5d.%01d%% of wall' "$k" "$n" \
        $((t / 1000)) $((t % 1000 / 100)) $((t / n / 1000)) $((t / n % 1000 / 10)) $((t * 1000 / wall / 10)) $((t * 1000 / wall % 10)))"$'\n'
    else
      lines+="0|$(printf '%-24s %8d calls' "$k" "$n")"$'\n'
    fi
  done
  {
    printf 'deltactl panel profile  pid=%s  view=%s  size=%sx%s  wall=%d s\n' "$$" "${DASH_VIEW:-?}" "${TUI_COLS:-?}" "${TUI_ROWS:-?}" $((wall / 1000000))
    printf 'cpu of the panel itself : %d.%01d%% of one core (%d ticks)\n' $((me / 10)) $((me % 10)) "$PROF_SELF"
    printf 'cpu of its children     : %d.%01d%% of one core (%d ticks: ps, ss, docker, the checks)\n' $((kids / 10)) $((kids % 10)) "$PROF_KIDS"
    printf '%s\n' "by phase, the biggest first (a phase can contain others):"
    printf '%s' "$lines" | sort -t'|' -k1,1nr | cut -d'|' -f2-
  } > "$PROF_FILE.tmp" 2> /dev/null && mv "$PROF_FILE.tmp" "$PROF_FILE" 2> /dev/null
  PROF_DUMP_AT="$SECONDS"
  return 0
}

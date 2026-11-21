#!/usr/bin/env bash
# shellcheck disable=SC2034  # the MT_* variables are read by the panel that draws them
# Live figures of the running services: memory, memory limit and CPU, plus a short history of each. It reads
# the kernel's cgroup files through the host adapter (only Bash builtins: no process is spawned per sample),
# so sampling every second costs almost nothing. Sourced by lib/bootstrap.sh; READ-ONLY.
#
# mt_sample takes one reading of every running container of ST_PID (filled by st_collect) and keeps, per
# "<instance>/<service>" key: MT_MEM (bytes), MT_LIM (bytes, 0 = no limit), MT_CPU (tenths of a percent of one
# core, empty until the second sample) and the last MT_HIST_LEN values of each as space-separated strings.

MT_HIST_LEN=120   # enough for a wide chart (one value per second)
declare -gA MT_MEM=() MT_LIM=() MT_CPU=() MT_HMEM=() MT_HCPU=()
declare -gA MT_CG_PID=() MT_CG_VER=() MT_CG_MEMDIR=() MT_CG_CPUDIR=() MT_PREV_CPU=() MT_PREV_T=()
declare -gA MT_HN=()   # how many values each history holds (see mt_push)
MT_LAST_US=0
MT_SAMPLES=0
MT_HOST_USED_KB="" MT_HOST_TOTAL_KB="" MT_HOST_PCT="" MT_HOST_LOAD="" MT_HOST_HIST=""

# Sampling interval in microseconds (DELTACTL_METRICS_INTERVAL, in seconds; 2 by default: the panel's charts, like btop's,
# are meant for 2 s steps, and every sample costs a rebuild of the screen). 120 samples are 4 minutes of history.
# MT_INTERVAL_S, when set, wins: the panel puts there the value it resolved (the variable, its options file or the default).
MT_INTERVAL_S=""
mt_interval_us() {
  local s="${MT_INTERVAL_S:-${DELTACTL_METRICS_INTERVAL:-2}}"
  [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" -gt 0 ] || s=2
  printf '%s' "$((s * 1000000))"
}

# Forgets every reading (used when the panel starts or the containers are reloaded).
mt_reset() {
  MT_MEM=() MT_LIM=() MT_CPU=() MT_HMEM=() MT_HCPU=()
  MT_CG_PID=() MT_CG_VER=() MT_CG_MEMDIR=() MT_CG_CPUDIR=() MT_PREV_CPU=() MT_PREV_T=() MT_HN=()
  MT_LAST_US=0 MT_SAMPLES=0 MT_HOST_HIST="" MT_INTERVAL_US=""
}

# Is it time for another sample? MT_INTERVAL_MULT stretches the interval (the panel sets 2 while the view on screen shows no figure of
# a service: only the header does, and it moves slowly).
MT_INTERVAL_US="" MT_INTERVAL_MULT=1
mt_due() {
  # The interval is read once: a `$(...)` here would be a process on every wake-up of the loop.
  [ -n "$MT_INTERVAL_US" ] || MT_INTERVAL_US="$(mt_interval_us)"
  host_now_us
  [ $((HOST_NOW_US - MT_LAST_US)) -ge $((MT_INTERVAL_US * MT_INTERVAL_MULT)) ]
}

# Appends a value to a history string (kept to MT_HIST_LEN values). Result in MT_H.
# With a counter key ($3) the number of values is remembered in MT_HN, so a push is a concatenation and, once the history is full,
# one cut at the front. Without it the values are counted every time (counting the spaces of a 120-value history costs ~1.5 ms,
# and a sample pushes two histories per container). An empty history always starts the count again.
MT_H=""
mt_push() { # history value [counter_key]
  local h="${1:+$1 }$2" ck="${3:-}" n spaces
  if [ -n "$ck" ] && [ -n "$1" ] && [ -n "${MT_HN[$ck]+x}" ]; then
    n=$((MT_HN[$ck] + 1))
    if [ "$n" -gt "$MT_HIST_LEN" ]; then h="${h#* }"; n=$((n - 1)); fi
    MT_HN[$ck]="$n" MT_H="$h"
    return 0
  fi
  spaces="${h//[^ ]/}"
  while [ "${#spaces}" -ge "$MT_HIST_LEN" ]; do
    h="${h#* }"
    spaces="${spaces#?}"
  done
  if [ -n "$ck" ]; then MT_HN[$ck]=$((${#spaces} + 1)); fi
  MT_H="$h"
}

# One reading of the host and of every running container.
mt_sample() {
  local key pid state now dt cur prev dcpu
  host_now_us
  now="$HOST_NOW_US"
  if host_mem_read && [ "${HOST_MEM_TOTAL_KB:-0}" -gt 0 ]; then
    MT_HOST_TOTAL_KB="$HOST_MEM_TOTAL_KB"
    MT_HOST_USED_KB=$((HOST_MEM_TOTAL_KB - HOST_MEM_AVAIL_KB))
    MT_HOST_PCT=$((MT_HOST_USED_KB * 100 / HOST_MEM_TOTAL_KB))
    mt_push "$MT_HOST_HIST" "$MT_HOST_PCT" host; MT_HOST_HIST="$MT_H"
  else
    MT_HOST_TOTAL_KB="" MT_HOST_USED_KB="" MT_HOST_PCT=""
  fi
  host_load_read && MT_HOST_LOAD="$HOST_LOAD1" || MT_HOST_LOAD=""

  for key in "${!MT_CG_PID[@]}"; do
    [ -n "${ST_STATE[$key]+x}" ] || mt_forget "$key"
  done
  for key in "${!ST_STATE[@]}"; do
    state="${ST_STATE[$key]}"
    pid="${ST_PID[$key]:-0}"
    if [ "$state" != "running" ] || [ "$pid" -le 0 ] 2>/dev/null; then
      mt_forget "$key"
      continue
    fi
    # The cgroup is resolved once per process id (a restarted container has a new one).
    if [ "${MT_CG_PID[$key]:-}" != "$pid" ]; then
      mt_forget "$key"
      host_cg_resolve "$pid" || continue
      MT_CG_PID[$key]="$pid" MT_CG_VER[$key]="$HOST_CG_VER"
      MT_CG_MEMDIR[$key]="$HOST_CG_MEM" MT_CG_CPUDIR[$key]="$HOST_CG_CPU"
    fi
    if host_cg_mem "${MT_CG_MEMDIR[$key]}" "${MT_CG_VER[$key]}"; then
      MT_MEM[$key]="$CG_MEM_BYTES" MT_LIM[$key]="$CG_MEM_LIMIT"
      mt_push "${MT_HMEM[$key]:-}" "$CG_MEM_BYTES" "mem/$key"; MT_HMEM[$key]="$MT_H"
    fi
    if host_cg_cpu "${MT_CG_CPUDIR[$key]}" "${MT_CG_VER[$key]}"; then
      cur="$CG_CPU_USEC"
      prev="${MT_PREV_CPU[$key]:-}"
      if [ -n "$prev" ] && [ "$cur" -ge "$prev" ]; then
        dt=$((now - MT_PREV_T[$key]))
        if [ "$dt" -gt 0 ]; then
          dcpu=$((cur - prev))
          MT_CPU[$key]=$((dcpu * 1000 / dt))
          mt_push "${MT_HCPU[$key]:-}" "${MT_CPU[$key]}" "cpu/$key"; MT_HCPU[$key]="$MT_H"
        fi
      fi
      MT_PREV_CPU[$key]="$cur" MT_PREV_T[$key]="$now"
    fi
  done
  MT_LAST_US="$now"
  MT_SAMPLES=$((MT_SAMPLES + 1))
}

mt_forget() { # key
  unset "MT_CG_PID[$1]" "MT_CG_VER[$1]" "MT_CG_MEMDIR[$1]" "MT_CG_CPUDIR[$1]" "MT_PREV_CPU[$1]" "MT_PREV_T[$1]" \
    "MT_MEM[$1]" "MT_LIM[$1]" "MT_CPU[$1]" "MT_HMEM[$1]" "MT_HCPU[$1]" "MT_HN[mem/$1]" "MT_HN[cpu/$1]"
}

# Totals of an instance over its services: MT_SUM_MEM, MT_SUM_LIM (bytes) and MT_SUM_CPU (tenths of a percent).
MT_SUM_MEM=0 MT_SUM_LIM=0 MT_SUM_CPU=0
mt_instance_sum() { # instance service...
  local inst="$1" svc key
  shift
  MT_SUM_MEM=0 MT_SUM_LIM=0 MT_SUM_CPU=0
  for svc in "$@"; do
    key="$inst/$svc"
    [ -z "${MT_MEM[$key]:-}" ] || MT_SUM_MEM=$((MT_SUM_MEM + MT_MEM[$key]))
    [ -z "${MT_LIM[$key]:-}" ] || MT_SUM_LIM=$((MT_SUM_LIM + MT_LIM[$key]))
    [ -z "${MT_CPU[$key]:-}" ] || MT_SUM_CPU=$((MT_SUM_CPU + MT_CPU[$key]))
  done
}

# Bytes in a short human form (512K, 82M, 1.2G) printed without forking.
MT_B=""
mt_bytes_v() { # bytes -> MT_B
  local b="$1" t
  [[ "$b" =~ ^[0-9]+$ ]] || { MT_B="-"; return 0; }
  if [ "$b" -ge 1073741824 ]; then
    t=$((b * 10 / 1073741824)); MT_B="$((t / 10)).$((t % 10))G"
  elif [ "$b" -ge 1048576 ]; then
    MT_B="$((b / 1048576))M"
  else
    MT_B="$((b / 1024))K"
  fi
}
mt_bytes() { mt_bytes_v "$1"; printf '%s' "$MT_B"; }

# Tenths of a percent as "12.3" ("-" when there is no reading yet).
MT_T=""
mt_tenths_v() { # tenths -> MT_T
  local t="$1"
  [[ "$t" =~ ^[0-9]+$ ]] || { MT_T="-"; return 0; }
  MT_T="$((t / 10)).$((t % 10))"
}
mt_tenths() { mt_tenths_v "$1"; printf '%s' "$MT_T"; }

# Sparkline of a history string, scaled to $2 (a value that fills the whole height; 0 = the history's own maximum).
# $3 is the number of cells (the last ones are kept). The result is empty for an empty history.
MT_S=""
mt_spark_v() { # history scale [cells] [floor] -> MT_S (floor: the smallest value that fills the height)
  local -a v
  local h="$1" scale="${2:-0}" cells="${3:-20}" floor="${4:-0}" x max=0 out="" i n idx
  MT_S=""
  [ -n "$h" ] || return 0
  v=($h)
  n="${#v[@]}"
  [ "$n" -le "$cells" ] || { v=("${v[@]:$((n - cells))}"); n="$cells"; }
  max="$scale"
  if [ "$max" -le 0 ]; then
    for x in "${v[@]}"; do [ "$x" -le "$max" ] || max="$x"; done
  fi
  [ "$max" -ge "$floor" ] || max="$floor"
  [ "$max" -gt 0 ] || max=1
  for ((i = 0; i < n; i++)); do
    x="${v[$i]}"
    [ "$x" -le "$max" ] || x="$max"
    idx=$((x * 7 / max))
    out+="${UI_SPARK[$idx]}"
  done
  MT_S="$out"
}
mt_spark() { mt_spark_v "$@"; printf '%s' "$MT_S"; }

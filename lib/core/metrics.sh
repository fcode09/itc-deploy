#!/usr/bin/env bash
# shellcheck disable=SC2034  # the MT_* variables are read by the panel that draws them
# Live figures of the running services: memory, memory limit and CPU, plus a short history of each. It reads
# the kernel's cgroup files through the host adapter (only Bash builtins: no process is spawned per sample),
# so sampling every second costs almost nothing. Sourced by lib/bootstrap.sh; READ-ONLY.
#
# mt_sample takes one reading of every running container of ST_PID (filled by st_collect) and keeps, per
# "<instance>/<service>" key: MT_MEM (bytes), MT_LIM (bytes, 0 = no limit), MT_CPU (tenths of a percent of one
# core, empty until the second sample) and the last MT_HIST_LEN values of each as space-separated strings.

MT_HIST_LEN=120   # the history of a service: enough for the trend of a table (one value per sample)
MT_HOST_HIST_LEN=240   # the history of the server as a whole (the Server view's charts: a wide screen shows 100+ cells of 2 samples each)
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

# --- The server as a whole (the Server screen) ---------------------------------------------------------------
# mt_host_sample reads the sources of lib/adapters/host.sh that the screen draws: CPU (total and per core), memory by kind, load average,
# temperature, network, disk I/O and the use of the disks. It runs inside mt_sample only when the panel sets MT_HOST_DETAIL=1 (the Server
# screen is on show), so the other views do not pay for it. Every source can be missing (WSL, a container): MT_SRC[<source>] is 1 when
# it answered at the last reading and 0 when it did not, and the screen says "not available" instead of leaving a hole.
# The histories are space-separated strings of the last MT_HOST_HIST_LEN readings: MT_HH_CPU (percent), MT_HH_LOAD (the load of one minute
# in hundredths), MT_HH_NETD and MT_HH_NETU (bytes per second), MT_HH_DIOR / MT_HH_DIOW (bytes per second), MT_HH_TEMP (degrees).
# More readings, cheap ones: the pressure of the kernel (MT_SRC[psi]) every sample, the sockets and the virtual memory counters every
# MT_SLOW_EVERY samples, the processes of each container (MT_PIDS). A source that is not there is marked 0 and is not asked again until
# mt_reset.
MT_HOST_DETAIL=0
declare -gA MT_SRC=()
declare -ga MT_CORE_PCT=()
MT_CPU_ALL="" MT_TEMP_EVERY=3 MT_SLOW_EVERY=5 MT_HH_CPU="" MT_HH_LOAD="" MT_HH_NETD="" MT_HH_NETU="" MT_HH_DIOR="" MT_HH_DIOW="" MT_HH_TEMP=""
declare -gA MT_PIDS=()   # processes in the cgroup of each container ("instance/service")
MT_NET_DOWN_MAX=0 MT_NET_UP_MAX=0 MT_NET_DOWN_TOTAL=0 MT_NET_UP_TOTAL=0 MT_NET_START_RX="" MT_NET_START_TX=""
MT_HOST_N=0 MT_DISK_AT=0

# Largest value of a history string into MT_MAXV (0 when empty).
MT_MAXV=0
mt_max_of() { # history
  local v
  MT_MAXV=0
  for v in $1; do [ "$v" -le "$MT_MAXV" ] || MT_MAXV="$v"; done
}

mt_host_sample() {

  MT_HOST_N=$((MT_HOST_N + 1))
  if host_cpu_read; then
    MT_SRC[cpu]=1
    if [ "$HOST_CPU_READY" -eq 1 ]; then
      MT_CORE_PCT=("${HOST_CPU_PCT[@]}")
      MT_CPU_ALL="${HOST_CPU_PCT[0]}"
      mt_push "$MT_HH_CPU" "$MT_CPU_ALL" hcpu "$MT_HOST_HIST_LEN"; MT_HH_CPU="$MT_H"
    fi
  else
    MT_SRC[cpu]=0 MT_CPU_ALL="" MT_CORE_PCT=()
  fi
  if host_mem_detail_read; then MT_SRC[mem]=1; else MT_SRC[mem]=0; fi
  if host_load_full_read; then
    MT_SRC[load]=1
    mt_hund "$HOST_LOAD1"; mt_push "$MT_HH_LOAD" "$MT_HU" hload "$MT_HOST_HIST_LEN"; MT_HH_LOAD="$MT_H"
  else
    MT_SRC[load]=0
  fi
  if host_uptime_read; then MT_SRC[uptime]=1; else MT_SRC[uptime]=0; fi
  if host_net_read; then
    MT_SRC[net]=1
    [ -n "$MT_NET_START_RX" ] || { MT_NET_START_RX="$HOST_NET_RX_TOTAL" MT_NET_START_TX="$HOST_NET_TX_TOTAL"; }
    MT_NET_DOWN_TOTAL=$((HOST_NET_RX_TOTAL - MT_NET_START_RX)) MT_NET_UP_TOTAL=$((HOST_NET_TX_TOTAL - MT_NET_START_TX))
    if [ -n "$HOST_NET_DOWN_BPS" ]; then
      mt_push "$MT_HH_NETD" "$HOST_NET_DOWN_BPS" hnetd "$MT_HOST_HIST_LEN"; MT_HH_NETD="$MT_H"; mt_max_of "$MT_HH_NETD"; MT_NET_DOWN_MAX="$MT_MAXV"
      mt_push "$MT_HH_NETU" "$HOST_NET_UP_BPS" hnetu "$MT_HOST_HIST_LEN"; MT_HH_NETU="$MT_H"; mt_max_of "$MT_HH_NETU"; MT_NET_UP_MAX="$MT_MAXV"
    fi
  else
    MT_SRC[net]=0
  fi
  if host_diskio_read; then
    MT_SRC[diskio]=1
    if [ -n "$HOST_DISKIO_READ_BPS" ]; then
      mt_push "$MT_HH_DIOR" "$HOST_DISKIO_READ_BPS" hdior "$MT_HOST_HIST_LEN"; MT_HH_DIOR="$MT_H"
      mt_push "$MT_HH_DIOW" "$HOST_DISKIO_WRITE_BPS" hdiow "$MT_HOST_HIST_LEN"; MT_HH_DIOW="$MT_H"
    fi
  else
    MT_SRC[diskio]=0
  fi
  # Temperatures move slowly and some sensors are slow to read: every MT_TEMP_EVERY samples (the first one always).
  if [ $(((MT_HOST_N - 1) % MT_TEMP_EVERY)) -eq 0 ]; then
    if host_temp_read; then
      MT_SRC[temp]=1
      mt_push "$MT_HH_TEMP" "$HOST_TEMP_CPU_C" htemp "$MT_HOST_HIST_LEN"; MT_HH_TEMP="$MT_H"
    else
      MT_SRC[temp]=0
    fi
  fi
  # The list of mounts almost never changes (every 30 samples); its use is cached by host_disk_usage_read (a `df`, at most every 30 s).
  if [ "$HOST_DISK_N" -eq 0 ] || [ $(((MT_HOST_N - 1) % 30)) -eq 0 ]; then host_disks_read || true; fi
  if host_disk_usage_read; then MT_SRC[disk]=1; else MT_SRC[disk]=0; fi
  # The pressure of the kernel (it is not there before Linux 4.20, or with PSI off: asked once, then never again).
  if [ "${MT_SRC[psi]:-1}" != 0 ]; then
    if host_pressure_read; then MT_SRC[psi]=1; else MT_SRC[psi]=0; fi
  fi
  # What moves slowly or costs more: every MT_SLOW_EVERY samples (the first one always).
  if [ $(((MT_HOST_N - 1) % MT_SLOW_EVERY)) -eq 0 ]; then
    if host_sockstat_read; then MT_SRC[sock]=1; else MT_SRC[sock]=0; fi
    if host_vmstat_read; then MT_SRC[vm]=1; else MT_SRC[vm]=0; fi
  fi
  return 0
}

# A decimal figure ("3.18", "0.5", "12") in hundredths into MT_HU (0 when it is not a number).
MT_HU=0
mt_hund() { # figure
  local v="$1" i f
  MT_HU=0
  [[ "$v" =~ ^[0-9]+([.][0-9]*)?$ ]] || return 0
  i="${v%%.*}"
  f=""; [ "$i" = "$v" ] || f="${v#*.}"
  f="${f}00"; f="${f:0:2}"
  MT_HU=$((10#$i * 100 + 10#$f))
}

# Forgets every reading (used when the panel starts or the containers are reloaded).
mt_reset() {
  MT_HH_CPU="" MT_HH_LOAD="" MT_HH_NETD="" MT_HH_NETU="" MT_HH_DIOR="" MT_HH_DIOW="" MT_HH_TEMP="" MT_HOST_N=0
  MT_SRC[psi]=1 MT_PIDS=()
  MT_NET_DOWN_MAX=0 MT_NET_UP_MAX=0 MT_NET_START_RX="" MT_NET_START_TX=""
  MT_MEM=() MT_LIM=() MT_CPU=() MT_HMEM=() MT_HCPU=()
  MT_CG_PID=() MT_CG_VER=() MT_CG_MEMDIR=() MT_CG_CPUDIR=() MT_PREV_CPU=() MT_PREV_T=() MT_HN=()
  # (MT_SAMPLES keeps counting: the panel keys its cached boxes on it, so it must never come back to a value it had)
  MT_LAST_US=0 MT_HOST_HIST="" MT_INTERVAL_US=""
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

# Appends a value to a history string (kept to MT_HIST_LEN values, or to $4 when given: the server's own histories are longer). Result in MT_H.
# With a counter key ($3) the number of values is remembered in MT_HN, so a push is a concatenation and, once the history is full,
# one cut at the front. Without it the values are counted every time (counting the spaces of a 120-value history costs ~1.5 ms,
# and a sample pushes two histories per container). An empty history always starts the count again.
MT_H=""
mt_push() { # history value [counter_key] [length]
  local h="${1:+$1 }$2" ck="${3:-}" lim="${4:-$MT_HIST_LEN}" n spaces
  if [ -n "$ck" ] && [ -n "$1" ] && [ -n "${MT_HN[$ck]+x}" ]; then
    n=$((MT_HN[$ck] + 1))
    if [ "$n" -gt "$lim" ]; then h="${h#* }"; n=$((n - 1)); fi
    MT_HN[$ck]="$n" MT_H="$h"
    return 0
  fi
  spaces="${h//[^ ]/}"
  while [ "${#spaces}" -ge "$lim" ]; do
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
    mt_push "$MT_HOST_HIST" "$MT_HOST_PCT" host "$MT_HOST_HIST_LEN"; MT_HOST_HIST="$MT_H"
  else
    MT_HOST_TOTAL_KB="" MT_HOST_USED_KB="" MT_HOST_PCT=""
  fi
  host_load_read && MT_HOST_LOAD="$HOST_LOAD1" || MT_HOST_LOAD=""
  [ "$MT_HOST_DETAIL" != 1 ] || mt_host_sample

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
    if [ "$MT_HOST_DETAIL" = 1 ] && [ $((MT_SAMPLES % MT_SLOW_EVERY)) -eq 0 ]; then
      if host_cg_pids "${MT_CG_MEMDIR[$key]}" "${MT_CG_VER[$key]}"; then MT_PIDS[$key]="$CG_PIDS"; else unset "MT_PIDS[$key]"; fi
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
    "MT_MEM[$1]" "MT_LIM[$1]" "MT_CPU[$1]" "MT_HMEM[$1]" "MT_HCPU[$1]" "MT_HN[mem/$1]" "MT_HN[cpu/$1]" "MT_PIDS[$1]"
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

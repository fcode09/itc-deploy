#!/usr/bin/env bash
# shellcheck disable=SC2034  # the HOST_* / CG_* results are read by lib/core/metrics.sh and the screens
# Host adapter: what the tool asks the operating system of the server (listening ports, file owners and
# modes, free disk). Commands call these functions instead of running ss/stat/df themselves.
# Sourced by lib/bootstrap.sh.

host_has() { command -v "$1" >/dev/null 2>&1; } # program

# Is something listening on TCP port $1 on this server? False when `ss` is not available.
host_port_in_use() { # port
  host_has ss && ss -ltn 2>/dev/null | grep -qE "[:.]$1[[:space:]]"
}

# Numeric owner of a file or directory; $2 is returned when it cannot be read.
host_owner_uid() { # path default
  stat -c %u "$1" 2>/dev/null || echo "$2"
}

# Octal permission mode of a file; $2 is returned when it cannot be read.
host_file_mode() { # path default
  stat -c %a "$1" 2>/dev/null || echo "$2"
}

# Filesystem type of a directory ("unknown" when it cannot be read). DELTACTL_FSTYPE overrides it (tests).
host_fs_type() { # dir
  printf '%s' "${DELTACTL_FSTYPE:-$(stat -f -c %T "$1" 2>/dev/null || echo unknown)}"
}

# Free space, in KB, of the filesystem that holds a path (empty when it cannot be read).
host_free_kb() { # path
  df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

# Numeric id of the user running the tool.
host_uid() { id -u; }

# --- Memory and load (Linux /proc; the files can be replaced for tests) ---------------------------------
# DELTACTL_MEMINFO and DELTACTL_LOADAVG point to alternative files. Every function prints nothing when the
# file is missing, so the callers simply leave the figure out on systems without /proc.

# Short host name (a fallback word when it cannot be read).
host_name() { hostname 2>/dev/null || true; }

# Total and available memory, in KB.
host_mem_total_kb() { awk '/^MemTotal:/ { print $2 }' "${DELTACTL_MEMINFO:-/proc/meminfo}" 2>/dev/null || true; }
host_mem_available_kb() { awk '/^MemAvailable:/ { print $2 }' "${DELTACTL_MEMINFO:-/proc/meminfo}" 2>/dev/null || true; }

# Load average of the last minute.
host_load1() { awk '{ print $1 }' "${DELTACTL_LOADAVG:-/proc/loadavg}" 2>/dev/null || true; }

# 8388608 -> 8.0 (kilobytes to gigabytes, one decimal)
host_kb_to_gb() { awk -v k="$1" 'BEGIN { printf "%.1f", k / 1048576 }'; }

# --- Live figures without spawning processes ------------------------------------------------------------
# The panel samples these every second, so they only use Bash builtins (read, printf, parameter expansion):
# no fork per reading. DELTACTL_PROC_ROOT / DELTACTL_CGROUP_ROOT point to alternative trees (tests).
# Every function returns 1 and leaves its result variables empty when the file is missing.

# Reads the first line of a file into REPLY without forking.
host_read1() { # file
  REPLY=""
  { IFS= read -r REPLY; } 2>/dev/null < "$1" || [ -n "$REPLY" ]
}

# Memory (total and available, in KB) of the host into HOST_MEM_TOTAL_KB / HOST_MEM_AVAIL_KB.
HOST_MEM_TOTAL_KB="" HOST_MEM_AVAIL_KB=""
host_mem_read() {
  local k v rest got=0
  HOST_MEM_TOTAL_KB="" HOST_MEM_AVAIL_KB=""
  [ -r "${DELTACTL_MEMINFO:-/proc/meminfo}" ] || return 1
  while read -r k v rest; do
    case "$k" in
      MemTotal:) HOST_MEM_TOTAL_KB="$v"; got=$((got + 1)) ;;
      MemAvailable:) HOST_MEM_AVAIL_KB="$v"; got=$((got + 1)) ;;
    esac
    [ "$got" -lt 2 ] || break
  done < "${DELTACTL_MEMINFO:-/proc/meminfo}"
  [ "$got" -eq 2 ]
}

# Load average of the last minute into HOST_LOAD1 (empty when unknown).
HOST_LOAD1=""
host_load_read() {
  HOST_LOAD1=""
  host_read1 "${DELTACTL_LOADAVG:-/proc/loadavg}" || return 1
  HOST_LOAD1="${REPLY%% *}"
}

# Resolves the cgroup of a process (a container's main pid) into HOST_CG_VER (1 or 2), HOST_CG_MEM and HOST_CG_CPU
# (the directories that hold its memory and CPU files).
HOST_CG_VER="" HOST_CG_MEM="" HOST_CG_CPU=""
host_cg_resolve() { # pid
  local pid="$1" root="${DELTACTL_CGROUP_ROOT:-/sys/fs/cgroup}" file n ctl path
  HOST_CG_VER="" HOST_CG_MEM="" HOST_CG_CPU=""
  [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 0 ] || return 1
  file="${DELTACTL_PROC_ROOT:-/proc}/$pid/cgroup"
  [ -r "$file" ] || return 1
  while IFS=: read -r n ctl path; do
    case ",$ctl," in
      *,memory,*) HOST_CG_VER=1; HOST_CG_MEM="$root/memory$path" ;;
      *,cpuacct,*) HOST_CG_CPU="$root/$ctl$path" ;;
      ,,) [ -n "$HOST_CG_VER" ] || { HOST_CG_VER=2; HOST_CG_MEM="$root$path"; HOST_CG_CPU="$root$path"; } ;;
    esac
  done < "$file"
  [ -n "$HOST_CG_VER" ] && [ -d "$HOST_CG_MEM" ]
}

# Memory in use and memory limit, in bytes, of a resolved cgroup, into CG_MEM_BYTES / CG_MEM_LIMIT (0 = no limit).
# The usage excludes the inactive file cache, as `docker stats` does.
CG_MEM_BYTES="" CG_MEM_LIMIT=""
host_cg_mem() { # dir version
  local dir="$1" ver="$2" cur lim inactive v key stat
  CG_MEM_BYTES="" CG_MEM_LIMIT=0
  if [ "$ver" = 2 ]; then
    host_read1 "$dir/memory.current" || return 1
    cur="$REPLY"; key="inactive_file"
    host_read1 "$dir/memory.max" && lim="$REPLY" || lim=max
  else
    host_read1 "$dir/memory.usage_in_bytes" || return 1
    cur="$REPLY"; key="total_inactive_file"
    host_read1 "$dir/memory.limit_in_bytes" && lim="$REPLY" || lim=max
  fi
  [[ "$cur" =~ ^[0-9]+$ ]] || return 1
  inactive=0
  if [ -r "$dir/memory.stat" ]; then
    # The whole file at once and the line cut out of it: `inactive_file` is some 20 lines down, and reading line by line to get there
    # cost about a millisecond per container and sample. `read -d ''` never forks (`$(< file)` does in a Bash older than 5.3).
    IFS= read -rd '' stat < "$dir/memory.stat" || true   # (it returns 1 at the end of the file, which is where it always stops)
    stat=$'\n'"$stat"$'\n'
    v="${stat#*$'\n'"$key "}"
    if [ "$v" != "$stat" ]; then inactive="${v%%$'\n'*}"; fi
  fi
  [[ "$inactive" =~ ^[0-9]+$ ]] || inactive=0
  [ "$inactive" -le "$cur" ] || inactive=0
  CG_MEM_BYTES=$((cur - inactive))
  # "max" (v2) or a huge number (v1) means no limit; anything above 1 PB is treated as none.
  if [[ "$lim" =~ ^[0-9]+$ ]] && [ "${#lim}" -lt 16 ]; then CG_MEM_LIMIT="$lim"; fi
  return 0
}

# Accumulated CPU time of a resolved cgroup, in microseconds, into CG_CPU_USEC.
CG_CPU_USEC=""
host_cg_cpu() { # dir version
  local dir="$1" ver="$2" k v
  CG_CPU_USEC=""
  if [ "$ver" = 2 ]; then
    [ -r "$dir/cpu.stat" ] || return 1
    while read -r k v; do
      if [ "$k" = "usage_usec" ]; then CG_CPU_USEC="$v"; break; fi
    done < "$dir/cpu.stat"
  else
    host_read1 "$dir/cpuacct.usage" || return 1
    [[ "$REPLY" =~ ^[0-9]+$ ]] && CG_CPU_USEC=$((REPLY / 1000))
  fi
  [[ "$CG_CPU_USEC" =~ ^[0-9]+$ ]]
}

# Current time in microseconds into HOST_NOW_US (the clock can be fixed with HOST_FAKE_NOW_US in tests).
HOST_NOW_US=""
host_now_us() {
  if [ -n "${HOST_FAKE_NOW_US:-}" ]; then HOST_NOW_US="$HOST_FAKE_NOW_US"; return 0; fi
  if [ -n "${EPOCHREALTIME:-}" ]; then
    HOST_NOW_US="${EPOCHREALTIME/[.,]/}"
  else
    HOST_NOW_US="$(date +%s%N 2>/dev/null)"
    HOST_NOW_US="$((${HOST_NOW_US:-0} / 1000))"
  fi
}

# --- Live figures of the whole server (the Server screen) -----------------------------------------------
# Same rules as above: only Bash builtins, no process per reading, every function returns 1 and leaves its results empty when its
# source does not exist (WSL, a container, a kernel without sensors), so the screen can say "not available" instead of failing.
# DELTACTL_PROC_ROOT and DELTACTL_SYS_ROOT point to alternative /proc and /sys trees (tests). The one exception to "no process" is the
# use of the disks: the kernel offers no file for it, so host_disk_usage_read runs a single `df` at most every HOST_DISK_TTL seconds.

# CPU: per-core load in percent between two readings of /proc/stat. HOST_CPU_N cores; HOST_CPU_PCT[0] is the whole CPU and
# HOST_CPU_PCT[1..N] each core. The first reading only stores the counters (it returns 0 with HOST_CPU_READY=0).
HOST_CPU_N=0 HOST_CPU_READY=0
declare -ga HOST_CPU_PCT=()
declare -gA HOST_CPU_PREV_TOTAL=() HOST_CPU_PREV_IDLE=()   # by name (cpu, cpu0, cpu2...): a core that is offline leaves a gap in /proc/stat
host_cpu_read() {
  local f="${DELTACTL_PROC_ROOT:-/proc}/stat" name u n s idle iow irq sirq steal rest total i dt di
  local -a names=() cur_t=() cur_i=()   # in the order of the file: the whole processor first, then each core that is there
  [ -r "$f" ] || { HOST_CPU_N=0 HOST_CPU_READY=0; HOST_CPU_PCT=(); return 1; }
  # (the cpu lines come first: the first line that is not one ends the loop, which spares reading the long "intr" line again)
  while read -r name u n s idle iow irq sirq steal rest; do
    case "$name" in
      cpu | cpu[0-9]*) ;;
      *) break ;;
    esac
    case "$u" in '' | *[!0-9]*) continue ;; esac
    total=$((u + n + s + idle + ${iow:-0} + ${irq:-0} + ${sirq:-0} + ${steal:-0}))
    names+=("$name") cur_t+=("$total") cur_i+=("$((idle + ${iow:-0}))")
  done < "$f"
  [ "${#names[@]}" -gt 0 ] || { HOST_CPU_N=0 HOST_CPU_READY=0; HOST_CPU_PCT=(); return 1; }
  HOST_CPU_N=$((${#names[@]} - 1))
  HOST_CPU_READY=0
  HOST_CPU_PCT=()
  if [ "${#HOST_CPU_PREV_TOTAL[@]}" -gt 0 ]; then
    HOST_CPU_READY=1
    for i in "${!names[@]}"; do
      if [ -z "${HOST_CPU_PREV_TOTAL[${names[i]}]+x}" ]; then HOST_CPU_PCT[i]=0; continue; fi   # a core that just appeared
      dt=$((cur_t[i] - HOST_CPU_PREV_TOTAL[${names[i]}])) di=$((cur_i[i] - HOST_CPU_PREV_IDLE[${names[i]}]))
      if [ "$dt" -gt 0 ] && [ "$di" -ge 0 ] && [ "$di" -le "$dt" ]; then
        HOST_CPU_PCT[i]=$((((dt - di) * 100 + dt / 2) / dt))
      else
        HOST_CPU_PCT[i]=0
      fi
    done
  fi
  HOST_CPU_PREV_TOTAL=() HOST_CPU_PREV_IDLE=()
  for i in "${!names[@]}"; do HOST_CPU_PREV_TOTAL[${names[i]}]="${cur_t[i]}" HOST_CPU_PREV_IDLE[${names[i]}]="${cur_i[i]}"; done
  return 0
}

# Load average (1, 5 and 15 minutes), running and total tasks.
HOST_LOAD5="" HOST_LOAD15="" HOST_TASKS_RUN="" HOST_TASKS_ALL=""
host_load_full_read() {
  local a b c tasks rest
  HOST_LOAD1="" HOST_LOAD5="" HOST_LOAD15="" HOST_TASKS_RUN="" HOST_TASKS_ALL=""
  [ -r "${DELTACTL_LOADAVG:-/proc/loadavg}" ] || return 1
  read -r a b c tasks rest < "${DELTACTL_LOADAVG:-/proc/loadavg}" || [ -n "$a" ] || return 1
  [[ "$a" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  HOST_LOAD1="$a" HOST_LOAD5="$b" HOST_LOAD15="$c"
  HOST_TASKS_RUN="${tasks%%/*}" HOST_TASKS_ALL="${tasks#*/}"
  return 0
}

# Seconds since the server booted (HOST_UPTIME_S) and the boot time as a Unix timestamp (HOST_BOOT_TS, from btime when it is there).
HOST_UPTIME_S="" HOST_BOOT_TS=""
host_uptime_read() {
  local up rest k v
  HOST_UPTIME_S=""
  [ -r "${DELTACTL_PROC_ROOT:-/proc}/uptime" ] || return 1
  read -r up rest < "${DELTACTL_PROC_ROOT:-/proc}/uptime" || [ -n "$up" ] || return 1
  case "$up" in '' | *[!0-9.]*) return 1 ;; esac
  HOST_UPTIME_S="${up%%.*}"
  # The boot time does not change: it is looked for in /proc/stat (far down, after the long "intr" line) only once.
  if [ -z "$HOST_BOOT_TS" ] && [ -r "${DELTACTL_PROC_ROOT:-/proc}/stat" ]; then
    while read -r k v rest; do
      if [ "$k" = "btime" ]; then HOST_BOOT_TS="$v"; break; fi
    done < "${DELTACTL_PROC_ROOT:-/proc}/stat"
  fi
  return 0
}

# Memory by kind, in KB: used (total - available), cached (page cache), buffers, free, available and swap. A figure that the kernel
# does not give stays empty.
HOST_MEMD_TOTAL="" HOST_MEMD_FREE="" HOST_MEMD_AVAIL="" HOST_MEMD_BUFFERS="" HOST_MEMD_CACHED="" HOST_MEMD_USED=""
HOST_MEMD_SWAP_TOTAL="" HOST_MEMD_SWAP_FREE="" HOST_MEMD_SWAP_USED=""
host_mem_detail_read() {
  local l v got=0 recl=0
  local -a lines
  HOST_MEMD_TOTAL="" HOST_MEMD_FREE="" HOST_MEMD_AVAIL="" HOST_MEMD_BUFFERS="" HOST_MEMD_CACHED="" HOST_MEMD_USED=""
  HOST_MEMD_SWAP_TOTAL="" HOST_MEMD_SWAP_FREE="" HOST_MEMD_SWAP_USED=""
  [ -r "${DELTACTL_MEMINFO:-/proc/meminfo}" ] || return 1
  # The file in one read and a `case` per line (a `read` per line, or looking each key up in the whole text, cost more than a millisecond);
  # it stops when it has the eight figures.
  mapfile -t lines < "${DELTACTL_MEMINFO:-/proc/meminfo}"
  for l in "${lines[@]}"; do
    case "$l" in
      MemTotal:* | MemFree:* | MemAvailable:* | Buffers:* | Cached:* | SReclaimable:* | SwapTotal:* | SwapFree:*) ;;
      *) continue ;;
    esac
    v="${l#*:}"; v="${v// /}"; v="${v%kB}"
    case "${l%%:*}" in
      MemTotal) HOST_MEMD_TOTAL="$v" ;;
      MemFree) HOST_MEMD_FREE="$v" ;;
      MemAvailable) HOST_MEMD_AVAIL="$v" ;;
      Buffers) HOST_MEMD_BUFFERS="$v" ;;
      Cached) HOST_MEMD_CACHED="$v" ;;
      SReclaimable) recl="$v" ;;
      SwapTotal) HOST_MEMD_SWAP_TOTAL="$v" ;;
      SwapFree) HOST_MEMD_SWAP_FREE="$v" ;;
    esac
    got=$((got + 1))
    [ "$got" -lt 8 ] || break
  done
  [[ "$HOST_MEMD_TOTAL" =~ ^[0-9]+$ ]] || return 1
  [[ "$HOST_MEMD_CACHED" =~ ^[0-9]+$ ]] && HOST_MEMD_CACHED=$((HOST_MEMD_CACHED + recl))
  if [[ "$HOST_MEMD_AVAIL" =~ ^[0-9]+$ ]]; then HOST_MEMD_USED=$((HOST_MEMD_TOTAL - HOST_MEMD_AVAIL)); fi
  if [[ "$HOST_MEMD_SWAP_TOTAL" =~ ^[0-9]+$ ]] && [[ "$HOST_MEMD_SWAP_FREE" =~ ^[0-9]+$ ]]; then
    HOST_MEMD_SWAP_USED=$((HOST_MEMD_SWAP_TOTAL - HOST_MEMD_SWAP_FREE))
  fi
  return 0
}

# Temperatures in degrees Celsius from the hwmon sensors (and, without them, the thermal zones). HOST_TEMP_N sensors with their
# HOST_TEMP_LABEL[i] ("coretemp Package id 0"), HOST_TEMP_C[i] and HOST_TEMP_CRIT[i] (empty when unknown). HOST_TEMP_CPU_C is the
# one of the processor (coretemp, k10temp, zenpower, cpu_thermal... or the hottest sensor when none is recognised); a sensor that
# cannot be read (permissions) is skipped.
HOST_TEMP_N=0 HOST_TEMP_CPU_C="" HOST_TEMP_MAX_C=""
declare -ga HOST_TEMP_LABEL=() HOST_TEMP_C=() HOST_TEMP_CRIT=()
declare -gA HOST_TEMP_META=()   # sensor file -> "chip|label|crit": they never change, so they are read once
host_temp_read() {
  local sys="${DELTACTL_SYS_ROOT:-/sys}" f d base nm lab val cr cpu_done=0 i meta
  HOST_TEMP_N=0 HOST_TEMP_CPU_C="" HOST_TEMP_MAX_C=""
  HOST_TEMP_LABEL=() HOST_TEMP_C=() HOST_TEMP_CRIT=()
  for f in "$sys"/class/hwmon/hwmon*/temp*_input; do
    [ -r "$f" ] || continue
    host_read1 "$f" || continue
    val="$REPLY"
    case "$val" in '' | *[!0-9-]*) continue ;; esac
    if [ -z "${HOST_TEMP_META[$f]+x}" ]; then
      d="${f%/*}" base="${f##*/}" base="${base%_input}"
      nm=""; host_read1 "$d/name" && nm="$REPLY"
      lab=""; host_read1 "$d/${base}_label" && lab="$REPLY"
      cr=""; host_read1 "$d/${base}_crit" && cr="$REPLY"
      case "$cr" in '' | *[!0-9]*) cr="" ;; *) cr=$((cr / 1000)) ;; esac
      HOST_TEMP_META[$f]="${nm:-${d##*/}}|$lab|$cr"
    fi
    meta="${HOST_TEMP_META[$f]}"
    nm="${meta%%|*}" lab="${meta#*|}" cr="${lab#*|}" lab="${lab%%|*}"
    i="$HOST_TEMP_N"
    HOST_TEMP_LABEL[i]="$nm${lab:+ $lab}" HOST_TEMP_C[i]=$((val / 1000)) HOST_TEMP_CRIT[i]="$cr"
    HOST_TEMP_N=$((i + 1))
    case "$nm" in
      coretemp | k10temp | zenpower | cpu_thermal | cpu-thermal | soc_thermal | thermal_zone)
        # "Package id 0" / "Tctl" / "Tdie" are the processor as a whole: they win over the cores
        if [ "$cpu_done" -eq 0 ] || [[ "$lab" == Package* || "$lab" == Tctl || "$lab" == Tdie ]]; then
          HOST_TEMP_CPU_C=$((val / 1000))
          [[ "$lab" == Package* || "$lab" == Tctl || "$lab" == Tdie ]] && cpu_done=2 || cpu_done=1
        fi
        ;;
    esac
  done
  if [ "$HOST_TEMP_N" -eq 0 ]; then
    for f in "$sys"/class/thermal/thermal_zone*/temp; do
      [ -r "$f" ] || continue
      host_read1 "$f" || continue
      val="$REPLY"
      case "$val" in '' | *[!0-9-]*) continue ;; esac
      d="${f%/*}"
      if [ -z "${HOST_TEMP_META[$f]+x}" ]; then
        nm=""; host_read1 "$d/type" && nm="$REPLY"
        HOST_TEMP_META[$f]="${nm:-${d##*/}}||"
      fi
      nm="${HOST_TEMP_META[$f]%%|*}"
      i="$HOST_TEMP_N"
      HOST_TEMP_LABEL[i]="$nm" HOST_TEMP_C[i]=$((val / 1000)) HOST_TEMP_CRIT[i]=""
      HOST_TEMP_N=$((i + 1))
      case "$nm" in x86_pkg_temp | cpu* | soc*) [ -n "$HOST_TEMP_CPU_C" ] || HOST_TEMP_CPU_C=$((val / 1000)) ;; esac
    done
  fi
  [ "$HOST_TEMP_N" -gt 0 ] || return 1
  for i in "${!HOST_TEMP_C[@]}"; do
    if [ -z "$HOST_TEMP_MAX_C" ] || [ "${HOST_TEMP_C[i]}" -gt "$HOST_TEMP_MAX_C" ]; then HOST_TEMP_MAX_C="${HOST_TEMP_C[i]}"; fi
  done
  [ -n "$HOST_TEMP_CPU_C" ] || HOST_TEMP_CPU_C="$HOST_TEMP_MAX_C"
  return 0
}

# Network: cumulative bytes per interface from /proc/net/dev, and the speed between two readings. The interfaces that are not
# the server's own (lo, the virtual ones of Docker and libvirt) are left out of HOST_NET_IFACES. HOST_NET_MAIN is the interface with
# the most traffic (DELTACTL_NET_IFACE forces one). HOST_NET_DOWN_BPS / HOST_NET_UP_BPS are bytes per second of the main one
# (empty until the second reading); HOST_NET_RX_TOTAL / HOST_NET_TX_TOTAL are its bytes since boot.
declare -gA HOST_NET_RX=() HOST_NET_TX=() HOST_NET_PREV_RX=() HOST_NET_PREV_TX=()
HOST_NET_IFACES="" HOST_NET_MAIN="" HOST_NET_DOWN_BPS="" HOST_NET_UP_BPS="" HOST_NET_RX_TOTAL="" HOST_NET_TX_TOTAL="" HOST_NET_PREV_US=""
host_net_read() {
  local f="${DELTACTL_PROC_ROOT:-/proc}/net/dev" line iface rx tx best="" bestv=-1 now dt tot
  local -a w
  HOST_NET_IFACES="" HOST_NET_MAIN="" HOST_NET_DOWN_BPS="" HOST_NET_UP_BPS="" HOST_NET_RX_TOTAL="" HOST_NET_TX_TOTAL=""
  [ -r "$f" ] || { HOST_NET_RX=() HOST_NET_TX=(); return 1; }
  HOST_NET_PREV_RX=() HOST_NET_PREV_TX=()
  for iface in "${!HOST_NET_RX[@]}"; do HOST_NET_PREV_RX[$iface]="${HOST_NET_RX[$iface]}" HOST_NET_PREV_TX[$iface]="${HOST_NET_TX[$iface]}"; done
  HOST_NET_RX=() HOST_NET_TX=()
  host_now_us; now="$HOST_NOW_US"
  while IFS= read -r line; do
    case "$line" in *:*) ;; *) continue ;; esac
    iface="${line%%:*}"; iface="${iface// /}"
    # shellcheck disable=SC2206  # word splitting on purpose: the figures are plain digits
    w=(${line#*:})
    rx="${w[0]:-}" tx="${w[8]:-}"
    case "$rx$tx" in '' | *[!0-9]*) continue ;; esac
    [ -n "$tx" ] || continue
    HOST_NET_RX[$iface]="$rx" HOST_NET_TX[$iface]="$tx"
    case "$iface" in lo | veth* | br-* | docker* | virbr* | cni* | flannel* | tun* | tap*) continue ;; esac
    HOST_NET_IFACES+="${HOST_NET_IFACES:+ }$iface"
    tot=$((rx + tx))
    if [ "$tot" -gt "$bestv" ]; then best="$iface" bestv="$tot"; fi
  done < "$f"
  [ "${#HOST_NET_RX[@]}" -gt 0 ] || return 1
  if [ -n "${DELTACTL_NET_IFACE:-}" ] && [ -n "${HOST_NET_RX[$DELTACTL_NET_IFACE]+x}" ]; then best="$DELTACTL_NET_IFACE"; fi
  HOST_NET_MAIN="$best"
  [ -n "$best" ] || return 1
  HOST_NET_RX_TOTAL="${HOST_NET_RX[$best]}" HOST_NET_TX_TOTAL="${HOST_NET_TX[$best]}"
  if [ -n "$HOST_NET_PREV_US" ] && [ -n "${HOST_NET_PREV_RX[$best]+x}" ]; then
    dt=$((now - HOST_NET_PREV_US))
    if [ "$dt" -gt 0 ]; then
      # (a counter that went back, after a reset or a wrap, is a speed of 0 for that reading)
      if [ "${HOST_NET_RX[$best]}" -ge "${HOST_NET_PREV_RX[$best]}" ]; then HOST_NET_DOWN_BPS=$(((HOST_NET_RX[$best] - HOST_NET_PREV_RX[$best]) * 1000000 / dt)); else HOST_NET_DOWN_BPS=0; fi
      if [ "${HOST_NET_TX[$best]}" -ge "${HOST_NET_PREV_TX[$best]}" ]; then HOST_NET_UP_BPS=$(((HOST_NET_TX[$best] - HOST_NET_PREV_TX[$best]) * 1000000 / dt)); else HOST_NET_UP_BPS=0; fi
    fi
  fi
  HOST_NET_PREV_US="$now"
  return 0
}

# Disk I/O: bytes per second read and written by the whole disks (sda, nvme0n1, vda, mmcblk0...; partitions, device-mapper, loop and
# ram devices are left out so nothing counts twice), from /proc/diskstats. Empty until the second reading.
HOST_DISKIO_READ_BPS="" HOST_DISKIO_WRITE_BPS="" HOST_DISKIO_PREV_R="" HOST_DISKIO_PREV_W="" HOST_DISKIO_PREV_US="" HOST_DISKIO_DEVICES=""
host_diskio_read() {
  local f="${DELTACTL_PROC_ROOT:-/proc}/diskstats" maj min name rd rm sr rt wr wm sw rest rb=0 wb=0 got=0 now dt devs=""
  HOST_DISKIO_READ_BPS="" HOST_DISKIO_WRITE_BPS="" HOST_DISKIO_DEVICES=""
  [ -r "$f" ] || return 1
  while read -r maj min name rd rm sr rt wr wm sw rest; do
    # whole disks only: sda (not sda1), nvme0n1 (not nvme0n1p1), vda, xvda, hda, mmcblk0 (not mmcblk0p1)
    case "$name" in
      sd[a-z] | sd[a-z][a-z] | vd[a-z] | vd[a-z][a-z] | xvd[a-z] | hd[a-z] | nvme[0-9]n[0-9] | nvme[0-9][0-9]n[0-9] | nvme[0-9]n[0-9][0-9] | mmcblk[0-9]) ;;
      *) continue ;;
    esac
    case "$sr$sw" in '' | *[!0-9]*) continue ;; esac
    rb=$((rb + sr)) wb=$((wb + sw)) got=$((got + 1)) devs+="${devs:+ }$name"
  done < "$f"
  [ "$got" -gt 0 ] || return 1
  HOST_DISKIO_DEVICES="$devs"
  host_now_us; now="$HOST_NOW_US"
  if [ -n "$HOST_DISKIO_PREV_US" ] && [ "$rb" -ge "${HOST_DISKIO_PREV_R:-0}" ] && [ "$wb" -ge "${HOST_DISKIO_PREV_W:-0}" ]; then
    dt=$((now - HOST_DISKIO_PREV_US))
    if [ "$dt" -gt 0 ]; then
      HOST_DISKIO_READ_BPS=$(((rb - HOST_DISKIO_PREV_R) * 512 * 1000000 / dt))
      HOST_DISKIO_WRITE_BPS=$(((wb - HOST_DISKIO_PREV_W) * 512 * 1000000 / dt))
    fi
  fi
  HOST_DISKIO_PREV_R="$rb" HOST_DISKIO_PREV_W="$wb" HOST_DISKIO_PREV_US="$now"
  return 0
}

# Mounted filesystems worth showing, from /proc/mounts without a process: one entry per device (a btrfs with many subvolumes counts
# once), real filesystems only, and never the paths of Docker, snap, /boot/efi, /run, /sys, /proc or /dev.
# HOST_DISK_N entries with HOST_DISK_MNT[i], HOST_DISK_DEV[i], HOST_DISK_FS[i].
HOST_DISK_N=0
declare -ga HOST_DISK_MNT=() HOST_DISK_DEV=() HOST_DISK_FS=()
host_disks_read() {
  local f="${DELTACTL_PROC_ROOT:-/proc}/mounts" dev mnt fs rest seen=" " i
  HOST_DISK_N=0 HOST_DISK_MNT=() HOST_DISK_DEV=() HOST_DISK_FS=()
  [ -r "$f" ] || return 1
  while read -r dev mnt fs rest; do
    case "$fs" in ext2 | ext3 | ext4 | xfs | btrfs | zfs | f2fs | jfs | reiserfs | ntfs | ntfs3 | fuseblk | exfat | nfs | nfs4 | cifs | overlay) ;; *) continue ;; esac
    [ "$fs" != overlay ] || [ "$mnt" = "/" ] || continue   # an overlay is only a disk when it is the root (a container)
    case "$mnt" in /var/lib/docker/* | /var/lib/containers/* | /snap/* | /var/snap/* | /run/* | /sys/* | /proc/* | /dev/* | /boot/efi*) continue ;; esac
    case "$seen" in *" $dev "*) continue ;; esac
    seen+="$dev "
    i="$HOST_DISK_N"
    HOST_DISK_MNT[i]="${mnt//\\040/ }" HOST_DISK_DEV[i]="$dev" HOST_DISK_FS[i]="$fs"
    HOST_DISK_N=$((i + 1))
  done < "$f"
  [ "$HOST_DISK_N" -gt 0 ]
}

# Use of those filesystems, in KB: HOST_DISK_TOTAL[i], HOST_DISK_USED[i], HOST_DISK_PCT[i]. The kernel gives no file for this, so it runs
# ONE `df` for all the mount points and keeps the answer for HOST_DISK_TTL seconds (30 by default), whatever the panel's rate of
# frames. Call host_disks_read first. DELTACTL_DF replaces the program (tests).
HOST_DISK_TTL=30 HOST_DISK_USAGE_AT=0 HOST_DISK_USAGE_N=-1 HOST_DF_TIMEOUT=3
declare -ga HOST_DISK_TOTAL=() HOST_DISK_USED=() HOST_DISK_PCT=()
host_disk_usage_read() {
  local now dev total used avail pct mnt i out="" line
  [ "$HOST_DISK_N" -gt 0 ] || return 1
  if [ -n "${HOST_FAKE_NOW_US:-}" ]; then now=$((HOST_FAKE_NOW_US / 1000000))
  elif [ -n "${EPOCHSECONDS:-}" ]; then now="$EPOCHSECONDS"            # (Bash 5.0 and later)
  else printf -v now '%(%s)T' -1; fi                                    # (Bash 4.x: a builtin too, no process)
  # Asked once per TTL for the same list of mounts, whether df answered or not: a df that fails (a hung network mount) is not retried on
  # every sample, which would freeze the panel for HOST_DF_TIMEOUT seconds over and over.
  if [ "$HOST_DISK_USAGE_N" = "$HOST_DISK_N" ] && [ $((now - HOST_DISK_USAGE_AT)) -lt "$HOST_DISK_TTL" ]; then
    [ "${#HOST_DISK_TOTAL[@]}" -gt 0 ]
    return
  fi
  HOST_DISK_USAGE_N="$HOST_DISK_N" HOST_DISK_USAGE_AT="$now"
  HOST_DISK_TOTAL=() HOST_DISK_USED=() HOST_DISK_PCT=()
  # (a network mount that hangs would hang df, and the panel with it: a limit when `timeout` exists, and a kill if it ignores the first signal)
  if host_has timeout; then
    out="$(timeout -k 1 "$HOST_DF_TIMEOUT" "${DELTACTL_DF:-df}" -Pk "${HOST_DISK_MNT[@]}" 2>/dev/null)" || [ -n "$out" ] || return 1
  else
    out="$("${DELTACTL_DF:-df}" -Pk "${HOST_DISK_MNT[@]}" 2>/dev/null)" || [ -n "$out" ] || return 1
  fi
  while read -r dev total used avail pct mnt; do
    [[ "$total" =~ ^[0-9]+$ ]] || continue
    [[ "$used" =~ ^[0-9]+$ ]] || used=0
    pct="${pct%\%}"
    if ! [[ "$pct" =~ ^[0-9]+$ ]]; then   # a filesystem with 0 blocks says "-": always a number, the panel formats it with %d
      if [ "$total" -gt 0 ]; then pct=$(((used * 100 + total / 2) / total)); else pct=0; fi
    fi
    for i in "${!HOST_DISK_MNT[@]}"; do
      [ "${HOST_DISK_MNT[i]}" = "$mnt" ] || continue
      HOST_DISK_TOTAL[i]="$total" HOST_DISK_USED[i]="$used" HOST_DISK_PCT[i]="$pct"
    done
  done <<< "$out"
  [ "${#HOST_DISK_TOTAL[@]}" -gt 0 ]
}

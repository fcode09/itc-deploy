#!/usr/bin/env bash
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

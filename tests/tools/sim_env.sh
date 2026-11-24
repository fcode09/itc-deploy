#!/usr/bin/env bash
# Simulated server for the panel tools (never the real Docker): a copy of the repository in a temporary folder, a `docker` shim on the
# PATH, N fake instances (two in three running) and fake cgroups. Source it:   source tests/tools/sim_env.sh; sim_build <dir> [N]
# It leaves SIM_REPO (the copy to run from) and exports the variables the panel reads (PATH, DELTACTL_PROC_ROOT, ...).

sim_build() { # dir [instances]
  local base="$1" n="${2:-12}" src p i s pid inst s2
  src="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  SIM_REPO="$base/repo" SIM_FIX="$base/fix"
  rm -rf "$base"
  mkdir -p "$SIM_REPO/instances" "$SIM_FIX/bin" "$base/xdg"
  for p in deltactl lib templates services compose.yaml tests; do cp -r "$src/$p" "$SIM_REPO/"; done
  : > "$SIM_REPO/instances/.gitkeep"
  cp "$src/tests/fake-docker.sh" "$SIM_FIX/bin/docker-fake"
  cat > "$SIM_FIX/bin/docker" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  ps) n=$(wc -l < "$FIX/containers.txt"); for ((i = 1; i <= n; i++)); do echo "c$i"; done ;;
  inspect) cat "$FIX/containers.txt" ;;
  stats) : ;;
  logs) echo "linea normal"; echo "ERROR de prueba"; case "$*" in *" -f "*) exec sleep 600 ;; esac ;;
  compose) case "$*" in *" logs"*) echo "linea normal" ;; *) exec bash "$FIX/bin/docker-fake" "$@" ;; esac ;;
  events) exec sleep 600 ;;
  *) exec bash "$FIX/bin/docker-fake" "$@" ;;
esac
SHIM
  printf '#!/bin/sh\nexit 0\n' > "$SIM_FIX/bin/ss"
  chmod +x "$SIM_FIX/bin/docker" "$SIM_FIX/bin/ss"
  : > "$SIM_FIX/containers.txt"; : > "$SIM_FIX/images.txt"; : > "$SIM_FIX/stats.txt"
  printf 'MemTotal:        8388608 kB\nMemAvailable:    3145728 kB\n' > "$SIM_FIX/meminfo"
  printf '0.82 0.50 0.40 1/200 1234\n' > "$SIM_FIX/loadavg"
  export FIX="$SIM_FIX" PATH="$SIM_FIX/bin:$PATH" HOME="$base" XDG_CONFIG_HOME="$base/xdg"
  export DELTACTL_CONFIG="$base/config" DELTACTL_LANG="${DELTACTL_LANG:-es}" DELTACTL_TEST_ISOLATED=1
  export DELTACTL_MEMINFO="$SIM_FIX/meminfo" DELTACTL_LOADAVG="$SIM_FIX/loadavg"
  export DELTACTL_PROC_ROOT="$SIM_FIX/proc" DELTACTL_CGROUP_ROOT="$SIM_FIX/cg"
  s2="$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%S.000000000Z)"
  (
    cd "$SIM_REPO" || exit 1
    # shellcheck source=tests/lib.sh
    source tests/lib.sh > /dev/null
    for i in $(seq 1 "$n"); do
      inst="$(printf 'sim-%02d' "$i")"
      bash ./deltactl new "$inst" > /dev/null 2>&1
      fill_instance "instances/$inst" 1.0 1.0
      printf 'SOURCE=init\nINITIALIZED_AT=2026-01-01T00:00:00Z\n' > "instances/$inst/.initialized"
      if [ $((i % 3)) -ne 2 ]; then
        for s in 0 1; do
          pid=$((3000 + i * 2 + s))
          printf '%s|s%s|running|healthy|img:1.0|%s|/s%s_%s|%s|0\n' "$inst" "$s" "$s2" "$s" "$inst" "$pid" >> "$SIM_FIX/containers.txt"
          mkdir -p "$SIM_FIX/proc/$pid" "$SIM_FIX/cg/scope-$pid"
          echo "0::/scope-$pid" > "$SIM_FIX/proc/$pid/cgroup"
          echo $((pid * 40000)) > "$SIM_FIX/cg/scope-$pid/memory.current"; echo max > "$SIM_FIX/cg/scope-$pid/memory.max"
          printf 'usage_usec %s\n' $((pid * 1000)) > "$SIM_FIX/cg/scope-$pid/cpu.stat"
        done
      fi
    done
  )
}

# A simulated host for the Server view (never the real one): a 4-core CPU, memory by kind, an interface, two disks, mounts, a CPU sensor
# and a `df`, written into the fake /proc and /sys that sim_build exports (DELTACTL_PROC_ROOT) plus DELTACTL_SYS_ROOT and DELTACTL_DF.
# sim_host <dir>   builds it, with counters at zero;   sim_host_tick <n>   moves the counters to step n of a wave (the busy part comes and
# goes), so a loop that calls it every few tenths of a second gives the graphs something to draw.
sim_host() { # dir
  local d="$1" p="$SIM_FIX/proc"
  mkdir -p "$p/net" "$d/sys/class/hwmon/hwmon0"
  printf 'MemTotal:       16777216 kB\nMemFree:         2097152 kB\nMemAvailable:    9437184 kB\nBuffers:          524288 kB\nCached:          5242880 kB\nSReclaimable:     262144 kB\nSwapTotal:       4194304 kB\nSwapFree:        3670016 kB\n' > "$SIM_FIX/meminfo"
  printf '0.82 0.50 0.40 1/200 1234\n' > "$SIM_FIX/loadavg"
  printf '12345.67 8000.00\n' > "$p/uptime"
  printf '/dev/sda2 / ext4 rw 0 0\n/dev/sdb1 /srv/data xfs rw 0 0\ntmpfs /run tmpfs rw 0 0\n' > "$p/mounts"
  printf 'coretemp\n' > "$d/sys/class/hwmon/hwmon0/name"
  printf '61000\n' > "$d/sys/class/hwmon/hwmon0/temp1_input"; printf 'Package id 0\n' > "$d/sys/class/hwmon/hwmon0/temp1_label"
  cat > "$d/df" <<'DF'
#!/bin/sh
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/sda2 214748364 184549376 30198988 86% /"
echo "/dev/sdb1 524288000 114819072 409468928 22% /srv/data"
DF
  chmod +x "$d/df"
  export DELTACTL_SYS_ROOT="$d/sys" DELTACTL_DF="$d/df" DELTACTL_NET_IFACE=enp3s0
  sim_host_tick 0
}

sim_host_tick() { # n
  local n="$1" p="$SIM_FIX/proc" busy idle i load rx tx lines="" tot_b=0 tot_i=0
  # A wave of busy time per core (each core a little out of step), as jiffies since boot.
  for i in 0 1 2 3; do
    load=$(((n * 7 + i * 23) % 60 + (n % 11) * 3 + 5))
    busy=$((n * load)); idle=$((n * (100 - load)))
    lines+="cpu$i $busy 0 0 $idle 0 0 0 0 0 0"$'\n'
    tot_b=$((tot_b + busy)); tot_i=$((tot_i + idle))
  done
  # (each file is written aside and renamed, so the panel never reads half of one)
  printf 'cpu  %s 0 0 %s 0 0 0 0 0 0\n%sbtime 1700000000\n' "$tot_b" "$tot_i" "$lines" > "$p/stat.new" && mv "$p/stat.new" "$p/stat"
  rx=$((n * (200000 + (n % 13) * 90000))); tx=$((n * (30000 + (n % 7) * 20000)))
  printf 'Inter-|   Receive                                                |  Transmit\n face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n    lo: 99999 10 0 0 0 0 0 0 99999 10 0 0 0 0 0 0\nenp3s0: %s 10 0 0 0 0 0 0 %s 10 0 0 0 0 0 0\n' "$rx" "$tx" > "$p/net/dev.new" && mv "$p/net/dev.new" "$p/net/dev"
  printf '   8       0 sda 100 0 %s 50 200 0 %s 80 0 10 130\n   8       1 sda1 90 0 1800 40 150 0 3000 70 0 10 110\n' $((n * 4000)) $((n * 9000)) > "$p/diskstats.new" && mv "$p/diskstats.new" "$p/diskstats"
}

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

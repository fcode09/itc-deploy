#!/usr/bin/env bash
# Times the panel's frame builders against the simulated server (never the real Docker): one frame per view at 80x24, 120x30 and 160x40
# (average of N, default 40). Used for the before/after numbers of the redesign. usage: tests/tools/bench_frames.sh [N] [theme]
set -u
N="${1:-40}" THEME="${2:-matrix}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/tools/sim_env.sh
source "$HERE/sim_env.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
sim_build "$TMP/sim" 12
cd "$SIM_REPO" || exit 1
ms() { # label n command...
  local label="$1" n="$2" i t0 t1
  shift 2
  t0="${EPOCHREALTIME/./}"
  for ((i = 0; i < n; i++)); do "$@" > /dev/null; done
  t1="${EPOCHREALTIME/./}"
  printf '%-36s %8.1f ms\n' "$label" "$(awk -v a="$t0" -v b="$t1" -v n="$n" 'BEGIN { printf "%.1f", (b - a) / n / 1000 }')"
}
for size in 80x24 120x30 160x40; do
  (
    export ROOT="$PWD" LANG=C.UTF-8 DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=always COLORTERM=truecolor \
      COLUMNS="${size%x*}" DELTACTL_TUI_ROWS="${size#*x}" DELTACTL_THEME="$THEME"
    # shellcheck source=/dev/null
    source lib/bootstrap.sh; source lib/cmd/dashboard.sh
    set +e
    tui_size; dash_init
    dash_refresh > /dev/null 2>&1; mt_sample; sleep 0.3; mt_sample; dash_host_build
    echo "== $size"
    for v in instances resources output runs procs console; do
      DASH_VIEW="$v"
      ms "dash_render $v (cached/hot)" "$N" dash_render
    done
    DASH_VIEW=instances
    # shellcheck disable=SC2329  # called through ms
    cold() { DASH_PC_SIG=(); dash_render; }
    ms "dash_render instances, cold" 10 cold
    ms "mt_sample" "$N" mt_sample
  )
done

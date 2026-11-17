#!/usr/bin/env bash
# Times the pieces of one panel cycle against the real Docker (read-only): frame, refresh, sample.
cd "${1:-/tmp/dctl-new}" || exit 1
export ROOT="$PWD" LANG=C.UTF-8 DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=always COLUMNS=110 DELTACTL_TUI_ROWS=30 DELTACTL_CONFIG=/tmp/none
source lib/bootstrap.sh
source lib/cmd/dashboard.sh
set +e
tui_size; dash_init
ms() { # label n command...   average milliseconds of n runs
  local label="$1" n="$2" i t0 t1
  shift 2
  t0="${EPOCHREALTIME/./}"
  for ((i = 0; i < n; i++)); do "$@" > /dev/null; done
  t1="${EPOCHREALTIME/./}"
  printf '%-34s %8.1f ms\n' "$label" "$(awk -v a="$t0" -v b="$t1" -v n="$n" 'BEGIN { printf "%.1f", (b - a) / n / 1000 }')"
}
ms "dash_refresh (docker queries)" 5 dash_refresh
mt_sample; sleep 1; mt_sample
ms "mt_sample (cgroup reads)" 50 mt_sample
dash_host_build
ms "dash_render instances view" 50 dash_render
DASH_VIEW=resources; ms "dash_render resources view" 50 dash_render
DASH_VIEW=output; ms "dash_render output view" 50 dash_render
DASH_VIEW=instances; DASH_MODE=cmd; DASH_BUF="status col"; ms "dash_render command line" 50 dash_render
DASH_MODE=normal
ms "dash_host_build" 50 dash_host_build
ms "dash_tabs_line" 100 dash_tabs_line
ms "dash_list_lines" 100 dash_list_lines 20
ms "dash_detail_box" 100 dash_detail_box colorado 66 18

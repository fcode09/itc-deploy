#!/usr/bin/env bash
cd "${1:-/tmp/dctl-new}" || exit 1
export ROOT="$PWD" LANG=C.UTF-8 DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=always COLUMNS=110 DELTACTL_TUI_ROWS=30 DELTACTL_CONFIG=/tmp/none
source lib/bootstrap.sh
source lib/cmd/dashboard.sh
set +e
tui_size; dash_init
ms() { # label n command...   average microseconds of n runs
  local label="$1" n="$2" i t0 t1
  shift 2
  t0="${EPOCHREALTIME/./}"
  for ((i = 0; i < n; i++)); do "$@" > /dev/null; done
  t1="${EPOCHREALTIME/./}"
  printf '%-34s %8d us\n' "$label" $(((t1 - t0) / n))
}
# docker calls made by one refresh
mkdir -p /tmp/bench-shim; printf '#!/bin/sh\necho "$1 $2 $3" >> /tmp/bench-shim/calls.log\nexec /usr/bin/docker "$@"\n' > /tmp/bench-shim/docker; chmod +x /tmp/bench-shim/docker
: > /tmp/bench-shim/calls.log
PATH="/tmp/bench-shim:$PATH" dash_refresh
echo "docker calls in ONE refresh: $(wc -l < /tmp/bench-shim/calls.log)"; sort /tmp/bench-shim/calls.log | uniq -c | sort -rn
echo "other forks candidates: ss=$(grep -c . /dev/null)"
dash_refresh >/dev/null; mt_sample; sleep 1; mt_sample; dash_host_build
H="10 20 30 40 50 60 70 80 90 100 110 120 130 140 150 160 170 180 190 200"
ms "dash_bar 17 12" 500 dash_bar 17 12
ms "mt_spark_v (20 values)" 500 mt_spark_v "$H" 0 14 100
ms "mt_bytes_v" 500 mt_bytes_v 104857600
ms "tui_vlen (colored 60 chars)" 500 tui_vlen "${C_RED}hello world this is a colored line of text${C_OFF} and more text after it ${C_GRN}x${C_OFF}"
ms "tui_fit (colored 60 chars)" 500 tui_fit "${C_RED}hello world this is a colored line of text${C_OFF} and more text after it ${C_GRN}x${C_OFF}" 50
ms "dt (cached)" 500 dt tui.lbl.mem
ms "dash_service_meter_lines" 200 dash_service_meter_lines colorado/s0
b=(one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen)
ms "tui_box 66x18 (16 lines)" 100 tui_box Title 66 18 b
ms "dash_detail_lines" 100 dash_detail_lines colorado
ms "dash_list_lines" 100 dash_list_lines 16
ms "dash_out_box (empty)" 100 dash_out_box 110 8 0 0
ms "tui_draw (test mode)" 100 tui_draw

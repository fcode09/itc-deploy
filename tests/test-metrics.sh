#!/usr/bin/env bash
# Tests of the live figures: the cgroup/proc readers of the host adapter and the sampler of lib/core/metrics.sh.
# They use fake /proc and /sys/fs/cgroup trees (DELTACTL_PROC_ROOT / DELTACTL_CGROUP_ROOT) and a fixed clock, so they
# need neither Docker nor a particular kernel. Run it through tests/run.sh.
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS

FIX="$(mktemp -d)"
export FIX
trap 'rm -rf "$FIX"' EXIT
export DELTACTL_PROC_ROOT="$FIX/proc" DELTACTL_CGROUP_ROOT="$FIX/cg"
export DELTACTL_MEMINFO="$FIX/meminfo" DELTACTL_LOADAVG="$FIX/loadavg"

# cgroup v2: pid 1234 in a docker scope, 100 MiB used of which 20 MiB inactive cache, limit 512 MiB.
mkdir -p "$FIX/proc/1234" "$FIX/cg/system.slice/docker-abc.scope"
echo "0::/system.slice/docker-abc.scope" > "$FIX/proc/1234/cgroup"
d="$FIX/cg/system.slice/docker-abc.scope"
echo 104857600 > "$d/memory.current"
printf 'anon 1\nfile 2\ninactive_file 20971520\nactive_file 5\n' > "$d/memory.stat"
echo 536870912 > "$d/memory.max"
printf 'usage_usec 5000000\nuser_usec 3\nsystem_usec 2\n' > "$d/cpu.stat"
# cgroup v2 without limit
mkdir -p "$FIX/proc/1235" "$FIX/cg/system.slice/docker-def.scope"
echo "0::/system.slice/docker-def.scope" > "$FIX/proc/1235/cgroup"
echo 2147483648 > "$FIX/cg/system.slice/docker-def.scope/memory.current"
echo max > "$FIX/cg/system.slice/docker-def.scope/memory.max"
printf 'usage_usec 100\n' > "$FIX/cg/system.slice/docker-def.scope/cpu.stat"
# cgroup v1 (and a hybrid line "0::" that must be ignored)
mkdir -p "$FIX/proc/2222" "$FIX/cg/memory/docker/xyz" "$FIX/cg/cpu,cpuacct/docker/xyz"
printf '4:memory:/docker/xyz\n3:cpu,cpuacct:/docker/xyz\n0::/system.slice/containerd.service\n' > "$FIX/proc/2222/cgroup"
echo 209715200 > "$FIX/cg/memory/docker/xyz/memory.usage_in_bytes"
echo 9223372036854771712 > "$FIX/cg/memory/docker/xyz/memory.limit_in_bytes"
printf 'cache 1\ntotal_inactive_file 52428800\n' > "$FIX/cg/memory/docker/xyz/memory.stat"
echo 7000000000 > "$FIX/cg/cpu,cpuacct/docker/xyz/cpuacct.usage"
printf 'MemTotal:        8388608 kB\nMemFree: 1 kB\nMemAvailable:    3145728 kB\n' > "$FIX/meminfo"
printf '0.82 0.50 0.40 1/200 1234\n' > "$FIX/loadavg"

lib() { ROOT="$PWD" bash -c 'source lib/bootstrap.sh; '"$1" 2>&1; }

section "1. the host adapter"
check "resolves a cgroup v2 process" '[ "$(lib "host_cg_resolve 1234; echo \$HOST_CG_VER \$HOST_CG_MEM")" = "2 $FIX/cg/system.slice/docker-abc.scope" ]'
check "resolves a cgroup v1 process through its memory line" '[ "$(lib "host_cg_resolve 2222; echo \$HOST_CG_VER \$HOST_CG_MEM \$HOST_CG_CPU")" = "1 $FIX/cg/memory/docker/xyz $FIX/cg/cpu,cpuacct/docker/xyz" ]'
check "an unknown pid does not resolve" '! lib "host_cg_resolve 99999"; [ "$(lib "host_cg_resolve 99999 || echo none")" = "none" ]'
check "a non numeric pid does not resolve" '[ "$(lib "host_cg_resolve abc || echo none")" = "none" ]'
check "v2 memory excludes the inactive cache and reads the limit" '[ "$(lib "host_cg_mem $FIX/cg/system.slice/docker-abc.scope 2; echo \$CG_MEM_BYTES \$CG_MEM_LIMIT")" = "83886080 536870912" ]'
check "v2 memory.max=max means no limit" '[ "$(lib "host_cg_mem $FIX/cg/system.slice/docker-def.scope 2; echo \$CG_MEM_BYTES \$CG_MEM_LIMIT")" = "2147483648 0" ]'
check "v1 memory uses total_inactive_file and treats the huge limit as none" '[ "$(lib "host_cg_mem $FIX/cg/memory/docker/xyz 1; echo \$CG_MEM_BYTES \$CG_MEM_LIMIT")" = "157286400 0" ]'
check "v2 CPU time is usage_usec" '[ "$(lib "host_cg_cpu $FIX/cg/system.slice/docker-abc.scope 2; echo \$CG_CPU_USEC")" = "5000000" ]'
check "v1 CPU time converts nanoseconds to microseconds" '[ "$(lib "host_cg_cpu $FIX/cg/cpu,cpuacct/docker/xyz 1; echo \$CG_CPU_USEC")" = "7000000" ]'
check "a missing file fails without printing" '[ -z "$(lib "host_cg_mem $FIX/nope 2")" ]'
check "host memory and load are read without awk" '[ "$(lib "host_mem_read; host_load_read; echo \$HOST_MEM_TOTAL_KB \$HOST_MEM_AVAIL_KB \$HOST_LOAD1")" = "8388608 3145728 0.82" ]'
check "the fixed clock wins" '[ "$(HOST_FAKE_NOW_US=42 lib "host_now_us; echo \$HOST_NOW_US")" = "42" ]'
check "the real clock is in microseconds" '[ "$(lib "host_now_us; echo \${#HOST_NOW_US}")" -ge 16 ]'

section "2. formatting"
check "bytes: kilobytes, megabytes and gigabytes" '[ "$(lib "mt_bytes 2048; mt_bytes 83886080; mt_bytes 1288490189")" = "2K80M1.2G" ]'
check "bytes: not a number" '[ "$(lib "mt_bytes x")" = "-" ]'
check "tenths of a percent" '[ "$(lib "mt_tenths 123; mt_tenths 5; mt_tenths x")" = "12.30.5-" ]'
check "sparkline scales to the maximum" '[ "$(lib "mt_spark \"0 5 10\" 0 3")" = "_-#" ]'
check "sparkline keeps only the last cells" '[ "$(lib "mt_spark \"0 0 10 10\" 0 2")" = "##" ]'
check "sparkline with a fixed scale" '[ "$(lib "mt_spark \"5 5\" 100 2")" = "__" ]'
check "sparkline of nothing is empty" '[ -z "$(lib "mt_spark \"\" 0")" ]'
check "the history keeps the configured number of values" '[ "$(lib "MT_HIST_LEN=3; h=\"\"; for i in 1 2 3 4 5; do mt_push \"\$h\" \$i; h=\"\$MT_H\"; done; echo \$h")" = "3 4 5" ]'

section "3. the sampler"
SAMPLER='
ST_STATE=([a/s0]=running [a/s1]=running [a/s2]=exited [a/s3]=running)
ST_PID=([a/s0]=1234 [a/s1]=2222 [a/s2]=0 [a/s3]=99999)
HOST_FAKE_NOW_US=1000000
mt_sample
'
check "the first sample has memory but no CPU yet" '[ "$(lib "$SAMPLER echo \${MT_MEM[a/s0]} \${MT_LIM[a/s0]} [\${MT_CPU[a/s0]:-}]")" = "83886080 536870912 []" ]'
check "a stopped container and an unresolvable pid get no reading" '[ "$(lib "$SAMPLER echo [\${MT_MEM[a/s2]:-}][\${MT_MEM[a/s3]:-}]")" = "[][]" ]'
check "the host figures are filled" '[ "$(lib "$SAMPLER echo \$MT_HOST_PCT \$MT_HOST_LOAD")" = "62 0.82" ]'
# 1 second later the container used 250000 more microseconds of CPU = 25.0 % of one core
check "the second sample computes the CPU percentage" '[ "$(lib "$SAMPLER echo 5250000 > /dev/null; printf \"usage_usec 5250000\n\" > $FIX/cg/system.slice/docker-abc.scope/cpu.stat; HOST_FAKE_NOW_US=2000000; mt_sample; echo \${MT_CPU[a/s0]}; printf \"usage_usec 5000000\n\" > $FIX/cg/system.slice/docker-abc.scope/cpu.stat")" = "250" ]'
check "the history grows with every sample" '[ "$(lib "$SAMPLER HOST_FAKE_NOW_US=2000000; mt_sample; read -ra h <<< \"\${MT_HMEM[a/s0]}\"; echo \${#h[@]}")" = "2" ]'
check "a container that disappears is forgotten" '[ "$(lib "$SAMPLER unset ST_STATE[a/s0]; HOST_FAKE_NOW_US=2000000; mt_sample; echo [\${MT_MEM[a/s0]:-}]")" = "[]" ]'
check "the instance totals add services" '[ "$(lib "$SAMPLER mt_instance_sum a s0 s1 s2; echo \$MT_SUM_MEM \$MT_SUM_LIM")" = "241172480 536870912" ]'
check "the sampler is due only after the interval" '[ "$(lib "$SAMPLER HOST_FAKE_NOW_US=1500000; mt_due && echo due || echo wait; HOST_FAKE_NOW_US=2000000; mt_due && echo due || echo wait")" = "$(printf "wait\ndue")" ]'
check "DELTACTL_METRICS_INTERVAL sets the interval" '[ "$(DELTACTL_METRICS_INTERVAL=5 lib "mt_interval_us")" = "5000000" ]'

finish

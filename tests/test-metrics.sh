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
mkdir -p "$FIX/cg/stat-a" "$FIX/cg/stat-b" "$FIX/cg/stat-c"
for d in a b c; do echo 104857600 > "$FIX/cg/stat-$d/memory.current"; echo max > "$FIX/cg/stat-$d/memory.max"; done
printf 'total_inactive_file 99999999\ninactive_file 7340032\nactive_file 5\n' > "$FIX/cg/stat-a/memory.stat"
printf 'anon 1\ntotal_inactive_file 52428800\n' > "$FIX/cg/stat-b/memory.stat"
printf 'inactive_file 1048576' > "$FIX/cg/stat-c/memory.stat"
check "memory.stat: the line is found by its exact name (not as the end of another one)" '[ "$(lib "host_cg_mem $FIX/cg/stat-a 2; echo \$CG_MEM_BYTES")" = "97517568" ]'
check "memory.stat: a name that only appears inside another one counts as absent" '[ "$(lib "host_cg_mem $FIX/cg/stat-b 2; echo \$CG_MEM_BYTES")" = "104857600" ]'
check "memory.stat: the first line and a file with no final newline are read too" '[ "$(lib "host_cg_mem $FIX/cg/stat-c 2; echo \$CG_MEM_BYTES")" = "103809024" ]'
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
check "with a counter key the history is cut the same way and the count is remembered" '[ "$(lib "MT_HIST_LEN=3; h=\"\"; for i in 1 2 3 4 5 6; do mt_push \"\$h\" \$i k; h=\"\$MT_H\"; done; echo \"\$h \${MT_HN[k]}\"")" = "4 5 6 3" ]'
check "an empty history starts the count again, even if a counter was left behind" '[ "$(lib "MT_HIST_LEN=3; MT_HN[k]=3; mt_push \"\" 9 k; echo \"\$MT_H \${MT_HN[k]}\"")" = "9 1" ]'
check "a history that already holds more than the limit is cut down to it on the first counted push" '[ "$(lib "MT_HIST_LEN=3; mt_push \"1 2 3 4 5\" 6 k; echo \"\$MT_H \${MT_HN[k]}\"")" = "4 5 6 3" ]'
check "forgetting a service forgets its counters, and a reset forgets all" '[ "$(lib "MT_HN[mem/a/s0]=5; MT_HN[cpu/a/s0]=5; mt_forget a/s0; echo \${#MT_HN[@]}; MT_HN[x]=1; mt_reset; echo \${#MT_HN[@]}")" = "0
0" ]'

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
check "the default sampling interval is 2 seconds" '[ "$(lib "mt_interval_us")" = "2000000" ]'
check "the sampler is due only after the interval" '[ "$(lib "DELTACTL_METRICS_INTERVAL=1; $SAMPLER HOST_FAKE_NOW_US=1500000; mt_due && echo due || echo wait; HOST_FAKE_NOW_US=2000000; mt_due && echo due || echo wait")" = "$(printf "wait\ndue")" ]'
check "DELTACTL_METRICS_INTERVAL sets the interval" '[ "$(DELTACTL_METRICS_INTERVAL=5 lib "mt_interval_us")" = "5000000" ]'

section "4. the server as a whole: CPU, load, uptime and memory by kind"
# /proc/stat read twice: the whole CPU +300 user +200 system +500 idle (50 %), cpu0 80 % and cpu1 20 %.
printf 'cpu  1000 0 1000 7000 0 0 0 0 0 0\ncpu0 500 0 500 3500 0 0 0 0 0 0\ncpu1 500 0 500 3500 0 0 0 0 0 0\nintr 1\nbtime 1700000000\n' > "$FIX/stat.A"
printf 'cpu  1300 0 1200 7500 0 0 0 0 0 0\ncpu0 750 0 650 3600 0 0 0 0 0 0\ncpu1 550 0 550 3900 0 0 0 0 0 0\nintr 2\nbtime 1700000000\n' > "$FIX/stat.B"
cpu2() { echo "cp $FIX/stat.A $FIX/proc/stat; host_cpu_read; r1=\$?; ready1=\$HOST_CPU_READY; cp $FIX/stat.B $FIX/proc/stat; host_cpu_read; $1"; }
check "the first CPU reading only stores the counters" '[ "$(lib "$(cpu2 "echo \$r1 \$ready1 \$HOST_CPU_READY")")" = "0 0 1" ]'
check "CPU: the whole processor and every core, in percent" '[ "$(lib "$(cpu2 "echo \$HOST_CPU_N \${HOST_CPU_PCT[*]}")")" = "2 50 80 20" ]'
check "CPU: iowait counts as idle" '[ "$(lib "printf \"cpu  0 0 0 100 0 0 0 0\n\" > $FIX/proc/stat; host_cpu_read; printf \"cpu  0 0 0 100 100 0 0 0\n\" > $FIX/proc/stat; host_cpu_read; echo \${HOST_CPU_PCT[0]}")" = "0" ]'
check "CPU: counters that did not move are 0 %, not a division by zero" '[ "$(lib "cp $FIX/stat.A $FIX/proc/stat; host_cpu_read; host_cpu_read; echo \${HOST_CPU_PCT[*]}")" = "0 0 0" ]'
check "CPU: with 12 cores cpu10 is the eleventh core" '[ "$(lib "(echo \"cpu  12 0 12 96 0 0 0 0\"; for i in 0 1 2 3 4 5 6 7 8 9 10 11; do printf \"cpu\$i 1 0 1 8 0 0 0 0\n\"; done) > $FIX/proc/stat; host_cpu_read; echo \$HOST_CPU_N")" = "12" ]'
check "CPU: a missing /proc/stat is a clean failure with no cores" '[ "$(DELTACTL_PROC_ROOT=$FIX/none lib "host_cpu_read || echo none \$HOST_CPU_N")" = "none 0" ]'
cp "$FIX/stat.A" "$FIX/proc/stat"
printf '0.82 0.50 0.40 3/200 1234\n' > "$FIX/loadavg"
check "load average: 1, 5 and 15 minutes and the tasks" '[ "$(lib "host_load_full_read; echo \$HOST_LOAD1 \$HOST_LOAD5 \$HOST_LOAD15 \$HOST_TASKS_RUN \$HOST_TASKS_ALL")" = "0.82 0.50 0.40 3 200" ]'
check "load average: a garbage file is a failure" '[ "$(printf "x y z\n" > $FIX/loadavg2; DELTACTL_LOADAVG=$FIX/loadavg2 lib "host_load_full_read || echo bad")" = "bad" ]'
check "load average: a missing file is a failure" '[ "$(DELTACTL_LOADAVG=$FIX/none lib "host_load_full_read || echo none")" = "none" ]'
printf '12345.67 9999.10\n' > "$FIX/proc/uptime"
check "uptime and boot time" '[ "$(lib "host_uptime_read; echo \$HOST_UPTIME_S \$HOST_BOOT_TS")" = "12345 1700000000" ]'
check "uptime: without /proc/stat there is still the uptime" '[ "$(lib "rm -f $FIX/proc/stat; host_uptime_read; echo \$HOST_UPTIME_S [\$HOST_BOOT_TS]"; cp $FIX/stat.A $FIX/proc/stat)" = "12345 []" ]'
printf 'MemTotal: 8388608 kB\nMemFree: 1000000 kB\nMemAvailable: 3145728 kB\nBuffers: 100 kB\nCached: 2000000 kB\nSReclaimable: 500 kB\nSwapTotal: 2097152 kB\nSwapFree: 2000000 kB\n' > "$FIX/meminfo2"
check "memory by kind: used, cached (with the reclaimable slab), buffers, free and swap" \
  '[ "$(DELTACTL_MEMINFO=$FIX/meminfo2 lib "host_mem_detail_read; echo \$HOST_MEMD_TOTAL \$HOST_MEMD_USED \$HOST_MEMD_CACHED \$HOST_MEMD_BUFFERS \$HOST_MEMD_FREE \$HOST_MEMD_AVAIL \$HOST_MEMD_SWAP_USED")" = "8388608 5242880 2000500 100 1000000 3145728 97152" ]'
check "memory by kind: a server without swap leaves it empty" '[ "$(DELTACTL_MEMINFO=$FIX/meminfo lib "host_mem_detail_read; echo [\$HOST_MEMD_SWAP_USED] \$HOST_MEMD_USED")" = "[] 5242880" ]'
check "memory by kind: a missing file is a failure" '[ "$(DELTACTL_MEMINFO=$FIX/none lib "host_mem_detail_read || echo none")" = "none" ]'

section "5. temperature (hwmon and thermal zones)"
export DELTACTL_SYS_ROOT="$FIX/sys"
mkdir -p "$FIX/sys/class/hwmon/hwmon0" "$FIX/sys/class/hwmon/hwmon1" "$FIX/sys/class/hwmon/hwmon2"
h="$FIX/sys/class/hwmon"
echo coretemp > "$h/hwmon0/name"
echo 42000 > "$h/hwmon0/temp2_input"; echo "Core 0" > "$h/hwmon0/temp2_label"
echo 45500 > "$h/hwmon0/temp1_input"; echo "Package id 0" > "$h/hwmon0/temp1_label"; echo 100000 > "$h/hwmon0/temp1_crit"
echo nvme > "$h/hwmon1/name"; echo 38000 > "$h/hwmon1/temp1_input"; echo Composite > "$h/hwmon1/temp1_label"
echo acpitz > "$h/hwmon2/name"; echo "N/A" > "$h/hwmon2/temp1_input"
check "hwmon: every readable sensor with its label" '[ "$(lib "host_temp_read; echo \$HOST_TEMP_N")" = "3" ]'
check "hwmon: the package temperature is the processor's, in whole degrees" '[ "$(lib "host_temp_read; echo \$HOST_TEMP_CPU_C \$HOST_TEMP_MAX_C")" = "45 45" ]'
check "hwmon: labels join the chip name and the sensor label" '[[ "$(lib "host_temp_read; printf \"%s|\" \"\${HOST_TEMP_LABEL[@]}\"")" == *"coretemp Package id 0|"* && "$(lib "host_temp_read; printf \"%s|\" \"\${HOST_TEMP_LABEL[@]}\"")" == *"nvme Composite|"* ]]'
check "hwmon: the critical temperature is read when there is one" '[ "$(lib "host_temp_read; for i in \${!HOST_TEMP_LABEL[@]}; do [ \"\${HOST_TEMP_LABEL[\$i]}\" = \"coretemp Package id 0\" ] && echo \${HOST_TEMP_CRIT[\$i]}; done")" = "100" ]'
check "hwmon: a sensor that does not hold a number is skipped" '! lib "host_temp_read; printf \"%s\n\" \"\${HOST_TEMP_LABEL[@]}\"" | grep -q acpitz'
rm -rf "$h"/hwmon0 "$h"/hwmon1 "$h"/hwmon2
mkdir -p "$h/hwmon0"; echo k10temp > "$h/hwmon0/name"; echo 61000 > "$h/hwmon0/temp1_input"; echo Tctl > "$h/hwmon0/temp1_label"; echo 50000 > "$h/hwmon0/temp3_input"
check "hwmon: an AMD Tctl is the processor" '[ "$(lib "host_temp_read; echo \$HOST_TEMP_CPU_C")" = "61" ]'
rm -rf "$h"
mkdir -p "$FIX/sys/class/thermal/thermal_zone0" "$FIX/sys/class/thermal/thermal_zone1"
echo x86_pkg_temp > "$FIX/sys/class/thermal/thermal_zone0/type"; echo 51000 > "$FIX/sys/class/thermal/thermal_zone0/temp"
echo acpitz > "$FIX/sys/class/thermal/thermal_zone1/type"; echo 30000 > "$FIX/sys/class/thermal/thermal_zone1/temp"
check "without hwmon the thermal zones are used" '[ "$(lib "host_temp_read; echo \$HOST_TEMP_N \$HOST_TEMP_CPU_C")" = "2 51" ]'
rm -rf "$FIX/sys/class"
check "no sensor at all (WSL, a container) is a clean failure" '[ "$(lib "host_temp_read || echo none \$HOST_TEMP_N [\$HOST_TEMP_CPU_C]")" = "none 0 []" ]'

section "6. network"
mkdir -p "$FIX/proc/net"
netdev() { # eth0_rx eth0_tx wlan_rx wlan_tx
  printf 'Inter-|   Receive                                                |  Transmit\n face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n    lo: 9999999 10 0 0 0 0 0 0 9999999 10 0 0 0 0 0 0\n  eth0: %s 10 0 0 0 0 0 0 %s 10 0 0 0 0 0 0\nwlan0:%s 10 0 0 0 0 0 0 %s 10 0 0 0 0 0 0\ndocker0: 88888888 1 0 0 0 0 0 0 88888888 1 0 0 0 0 0 0\nvethab12: 77777777 1 0 0 0 0 0 0 77777777 1 0 0 0 0 0 0\n' "$1" "$2" "$3" "$4" > "$FIX/proc/net/dev"
}
netdev 1000000 500000 1000 1000
check "net: the first reading has totals but no speed yet" '[ "$(lib "HOST_FAKE_NOW_US=1000000; host_net_read; echo \$? \$HOST_NET_MAIN \$HOST_NET_RX_TOTAL \$HOST_NET_TX_TOTAL [\$HOST_NET_DOWN_BPS]")" = "0 eth0 1000000 500000 []" ]'
check "net: lo and the virtual interfaces of Docker are left out" '[ "$(lib "host_net_read; echo \$HOST_NET_IFACES")" = "eth0 wlan0" ]'
check "net: the speed is bytes per second over the time between readings" \
  '[ "$(lib "HOST_FAKE_NOW_US=1000000; host_net_read; sed -i s/^.*eth0.*\$/\"  eth0: 3000000 10 0 0 0 0 0 0 1500000 10 0 0 0 0 0 0\"/ $FIX/proc/net/dev; HOST_FAKE_NOW_US=3000000; host_net_read; echo \$HOST_NET_DOWN_BPS \$HOST_NET_UP_BPS")" = "1000000 500000" ]'
netdev 1000000 500000 1000 1000
check "net: a counter that goes back (a reset) is a speed of 0, not negative" \
  '[ "$(lib "HOST_FAKE_NOW_US=1000000; host_net_read; sed -i s/^.*eth0.*\$/\"  eth0: 10 10 0 0 0 0 0 0 10 10 0 0 0 0 0 0\"/ $FIX/proc/net/dev; HOST_FAKE_NOW_US=2000000; host_net_read; echo \$HOST_NET_DOWN_BPS \$HOST_NET_UP_BPS")" = "0 0" ]'
netdev 1000000 500000 1000 1000
check "net: the line \"wlan0:1000\" (no space after the colon) is read" '[ "$(lib "host_net_read; echo \${HOST_NET_RX[wlan0]}")" = "1000" ]'
check "net: DELTACTL_NET_IFACE chooses the interface" '[ "$(DELTACTL_NET_IFACE=wlan0 lib "host_net_read; echo \$HOST_NET_MAIN \$HOST_NET_RX_TOTAL")" = "wlan0 1000" ]'
check "net: a missing /proc/net/dev is a clean failure" '[ "$(DELTACTL_PROC_ROOT=$FIX/none lib "host_net_read || echo none [\$HOST_NET_MAIN]")" = "none []" ]'

section "7. disks: I/O, mounts and use"
printf '   8       0 sda 100 0 2000 50 200 0 4000 80 0 10 130\n   8       1 sda1 90 0 1800 40 150 0 3000 70 0 10 110\n 259       0 nvme0n1 10 0 800 5 20 0 1600 8 0 3 13\n 259       1 nvme0n1p1 9 0 700 5 10 0 1000 8 0 3 13\n 253       0 dm-0 5 0 100 1 5 0 100 1 0 1 2\n   7       0 loop0 1 0 8 0 0 0 0 0 0 0 0\n' > "$FIX/proc/diskstats"
check "disk I/O: only the whole disks count (no partitions, dm or loop)" '[ "$(lib "host_diskio_read; echo \$HOST_DISKIO_DEVICES")" = "sda nvme0n1" ]'
check "disk I/O: bytes per second between two readings (a sector is 512 bytes)" \
  '[ "$(lib "HOST_FAKE_NOW_US=1000000; host_diskio_read; printf \"8 0 sda 100 0 4000 50 200 0 8000 80 0 10 130\n259 0 nvme0n1 10 0 800 5 20 0 1600 8 0 3 13\n\" > $FIX/proc/diskstats; HOST_FAKE_NOW_US=3000000; host_diskio_read; echo \$HOST_DISKIO_READ_BPS \$HOST_DISKIO_WRITE_BPS")" = "512000 1024000" ]'
printf '/dev/sda2 / ext4 rw 0 0\n/dev/sda1 /boot/efi vfat rw 0 0\ntmpfs /run tmpfs rw 0 0\n/dev/sdb1 /mnt/my\\040data xfs rw 0 0\noverlay /var/lib/docker/overlay2/x/merged overlay rw 0 0\n/dev/sda2 /var/lib/docker btrfs rw 0 0\n/dev/sda2 /home ext4 rw 0 0\n' > "$FIX/proc/mounts"
check "mounts: real filesystems only, once per device, without Docker's paths" '[ "$(lib "host_disks_read; echo \$HOST_DISK_N \${HOST_DISK_DEV[*]}")" = "2 /dev/sda2 /dev/sdb1" ]'
check "mounts: the escape of a space (\\040) in a path is undone" '[ "$(lib "host_disks_read; echo \"\${HOST_DISK_MNT[1]}\"")" = "/mnt/my data" ]'
check "mounts: a missing /proc/mounts is a clean failure" '[ "$(DELTACTL_PROC_ROOT=$FIX/none lib "host_disks_read || echo none \$HOST_DISK_N")" = "none 0" ]'
cat > "$FIX/fake-df" <<'EOF'
#!/bin/sh
echo x >> "$FIX/df.calls"
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/sda2 100000000 40000000 60000000 40% /"
echo "/dev/sdb1 2000000 1900000 100000 95% /mnt/my data"
EOF
chmod +x "$FIX/fake-df"
check "use of the disks: total, used and percent from one df" \
  'rm -f $FIX/df.calls; [ "$(DELTACTL_DF=$FIX/fake-df lib "host_disks_read; host_disk_usage_read; echo \${HOST_DISK_TOTAL[0]} \${HOST_DISK_USED[0]} \${HOST_DISK_PCT[0]} \${HOST_DISK_PCT[1]}")" = "100000000 40000000 40 95" ] && [ "$(wc -l < $FIX/df.calls)" = "1" ]'
check "use of the disks: df runs once per TTL, whatever the number of readings" \
  'rm -f $FIX/df.calls; DELTACTL_DF=$FIX/fake-df lib "HOST_FAKE_NOW_US=1000000000000; host_disks_read; for i in 1 2 3 4 5; do host_disk_usage_read; done; HOST_FAKE_NOW_US=1000031000000; host_disk_usage_read" >/dev/null; [ "$(wc -l < $FIX/df.calls)" = "2" ]'
check "use of the disks: without df it fails cleanly" '[ "$(DELTACTL_DF=$FIX/none lib "host_disks_read; host_disk_usage_read || echo none")" = "none" ]'

section "8. the server sampler"
# every source present, two samples one second apart
cat > "$FIX/sample2.sh" <<EOF
cp $FIX/stat.A $FIX/proc/stat
printf '  eth0: 1000000 10 0 0 0 0 0 0 500000 10 0 0 0 0 0 0\n' > $FIX/proc/net/dev
printf '8 0 sda 100 0 2000 50 200 0 4000 80 0 10 130\n' > $FIX/proc/diskstats
HOST_FAKE_NOW_US=1000000; MT_HOST_DETAIL=1; DELTACTL_DF=$FIX/fake-df
mt_host_sample
cp $FIX/stat.B $FIX/proc/stat
printf '  eth0: 3000000 10 0 0 0 0 0 0 1500000 10 0 0 0 0 0 0\n' > $FIX/proc/net/dev
printf '8 0 sda 100 0 4000 50 200 0 8000 80 0 10 130\n' > $FIX/proc/diskstats
HOST_FAKE_NOW_US=2000000
mt_host_sample
EOF
check "the sampler fills the CPU, per core and its history" '[ "$(lib "source $FIX/sample2.sh; echo \$MT_CPU_ALL \${MT_CORE_PCT[*]} \$MT_HH_CPU")" = "50 50 80 20 50" ]'
check "the sampler fills network speeds, their recent maximum and the session totals" \
  '[ "$(lib "source $FIX/sample2.sh; echo \$HOST_NET_DOWN_BPS \$MT_NET_DOWN_MAX \$MT_NET_UP_MAX \$MT_NET_DOWN_TOTAL \$MT_NET_UP_TOTAL")" = "2000000 2000000 1000000 2000000 1000000" ]'
check "the sampler fills disk I/O and the use of the disks" '[ "$(lib "source $FIX/sample2.sh; echo \$MT_HH_DIOR \$HOST_DISK_N \${HOST_DISK_PCT[0]}")" = "1024000 2 40" ]'
check "every source that answered is marked 1" '[ "$(lib "source $FIX/sample2.sh; echo \${MT_SRC[cpu]} \${MT_SRC[net]} \${MT_SRC[diskio]} \${MT_SRC[disk]} \${MT_SRC[load]} \${MT_SRC[uptime]}")" = "1 1 1 1 1 1" ]'
check "the histories hold MT_HIST_LEN values at most" '[ "$(lib "MT_HIST_LEN=3; source $FIX/sample2.sh; for i in 1 2 3 4 5; do HOST_FAKE_NOW_US=\$((3000000 + i * 1000000)); mt_host_sample; done; read -ra h <<< \"\$MT_HH_CPU\"; echo \${#h[@]}")" = "3" ]'
check "the recent maximum is the largest value of the window" '[ "$(lib "mt_max_of \"3 9 4 1\"; echo \$MT_MAXV; mt_max_of \"\"; echo \$MT_MAXV")" = "$(printf "9\n0")" ]'
check "with no sources at all (WSL, a container) the sampler does not fail and marks them 0" \
  '[ "$(DELTACTL_PROC_ROOT=$FIX/none DELTACTL_SYS_ROOT=$FIX/none DELTACTL_MEMINFO=$FIX/none DELTACTL_LOADAVG=$FIX/none lib "MT_HOST_DETAIL=1; HOST_FAKE_NOW_US=1000000; mt_host_sample; echo \$? \${MT_SRC[cpu]} \${MT_SRC[temp]} \${MT_SRC[net]} \${MT_SRC[diskio]} \${MT_SRC[disk]} \${MT_SRC[load]} \${MT_SRC[mem]} \${MT_SRC[uptime]}")" = "0 0 0 0 0 0 0 0 0" ]'
check "mt_sample reads the server only when MT_HOST_DETAIL=1" \
  '[ "$(lib "$SAMPLER echo [\${MT_SRC[cpu]:-}]")" = "[]" ] && [ "$(lib "MT_HOST_DETAIL=1; $SAMPLER echo \${MT_SRC[cpu]}")" = "1" ]'
check "mt_reset forgets the server histories" '[ "$(lib "source $FIX/sample2.sh; mt_reset; echo [\$MT_HH_CPU][\$MT_HH_NETD] \$MT_NET_DOWN_MAX")" = "[][] 0" ]'
check "temperature is sampled on the first sample and then every MT_TEMP_EVERY" \
  'mkdir -p $FIX/sys/class/hwmon/hwmon0; echo coretemp > $FIX/sys/class/hwmon/hwmon0/name; echo 45000 > $FIX/sys/class/hwmon/hwmon0/temp1_input; [ "$(lib "source $FIX/sample2.sh; read -ra h <<< \"\$MT_HH_TEMP\"; echo \${#h[@]} \${MT_SRC[temp]}")" = "1 1" ]; rm -rf $FIX/sys/class'

section "9. cost: no process per reading and a bounded time per source"
# The time is a coarse net (a regression that spawned a process per line would blow through it); the real figures at rest are in
# docs/panel-pendiente.md. Best of three batches, so one busy moment of the machine does not fail it.
fnbody() { sed -n "/^$1() {/,/^}/p" lib/adapters/host.sh; }
check "the readers of the server start no process (no \$( ), no pipes, no external program)" \
  'for f in host_cpu_read host_load_full_read host_uptime_read host_mem_detail_read host_temp_read host_net_read host_diskio_read host_disks_read; do ! fnbody $f | grep -vE "^\s*#" | grep -qE "\\$\\([^(]|\b(awk|sed|grep|cut|tr|cat|df|date)\b"; done'
# (the behaviour of the limit and of the cache is checked with a df that really hangs, in section 10)
check "the only process of the use of the disks is one df, behind its cache and its time limit" '[ "$(fnbody host_disk_usage_read | grep -cE "\\$\\([^(]")" = "2" ] && fnbody host_disk_usage_read | grep -q "timeout -k 1 \"\$HOST_DF_TIMEOUT\""'
bench() { # snippet -> best average microseconds per call over three batches of 200
  lib "$1
best=999999999
for b in 1 2 3; do s=\$EPOCHREALTIME; for i in \$(seq 200); do $2; done; e=\$EPOCHREALTIME; us=\$(( (\${e/./} - \${s/./}) / 200 )); [ \$us -ge \$best ] || best=\$us; done; echo \$best"
}
printf 'cpu  1000 0 1000 7000 0 0 0 0 0 0\ncpu0 500 0 500 3500 0 0 0 0 0 0\ncpu1 500 0 500 3500 0 0 0 0 0 0\n' > "$FIX/proc/stat"
netdev 1000000 500000 1000 1000
printf '8 0 sda 100 0 2000 50 200 0 4000 80 0 10 130\n259 0 nvme0n1 10 0 800 5 20 0 1600 8 0 3 13\n' > "$FIX/proc/diskstats"
mkdir -p "$FIX/sys/class/hwmon/hwmon0"; echo coretemp > "$FIX/sys/class/hwmon/hwmon0/name"; echo 45000 > "$FIX/sys/class/hwmon/hwmon0/temp1_input"
for src in "host_cpu_read" "host_net_read" "host_diskio_read" "host_temp_read" "host_load_full_read" "host_mem_detail_read" "host_uptime_read" "host_disks_read"; do
  check "$src: under 5 ms per reading even on a loaded machine" '[ "$(bench "" "'"$src"'")" -lt 5000 ]'
done
rm -rf "$FIX/sys/class"

section "10. robustness of the server readers (found by the independent review)"
# A core that is offline is missing from /proc/stat: cpu0, cpu2 and cpu3 here. cpu2 is the one that works at full speed.
printf 'cpu  0 0 0 300 0 0 0 0\ncpu0 0 0 0 100 0 0 0 0\ncpu2 0 0 0 100 0 0 0 0\ncpu3 0 0 0 100 0 0 0 0\n' > "$FIX/stat.off1"
printf 'cpu  100 0 0 500 0 0 0 0\ncpu0 0 0 0 200 0 0 0 0\ncpu2 100 0 0 100 0 0 0 0\ncpu3 0 0 0 200 0 0 0 0\n' > "$FIX/stat.off2"
check "CPU: with a core offline every percent belongs to its own core (cpu2 at 100 %, not shown as another one)" \
  '[ "$(lib "cp $FIX/stat.off1 $FIX/proc/stat; host_cpu_read; cp $FIX/stat.off2 $FIX/proc/stat; host_cpu_read; echo \$HOST_CPU_N \${HOST_CPU_PCT[1]} \${HOST_CPU_PCT[2]} \${HOST_CPU_PCT[3]}")" = "3 0 100 0" ]'
check "CPU: a core that comes back (hotplug) starts at 0, it does not take another core's counters" \
  '[ "$(lib "cp $FIX/stat.off1 $FIX/proc/stat; host_cpu_read; cp $FIX/stat.A $FIX/proc/stat; host_cpu_read; echo \$HOST_CPU_N \${#HOST_CPU_PCT[@]}")" = "2 3" ]'
# df that hangs (an NFS mount that does not answer): it is cut at HOST_DF_TIMEOUT and not asked again until the TTL has passed.
cat > "$FIX/fake-df-hang" <<'EOF'
#!/bin/sh
echo x >> "$FIX/df.calls"
sleep 4
EOF
chmod +x "$FIX/fake-df-hang"
check "use of the disks: a df that hangs is cut by the limit and fails" \
  'rm -f $FIX/df.calls; s=$SECONDS; r="$(DELTACTL_DF=$FIX/fake-df-hang lib "HOST_DF_TIMEOUT=1; host_disks_read; host_disk_usage_read || echo failed")"; [ "$r" = failed ] && [ $((SECONDS - s)) -le 3 ]'
check "use of the disks: after a failure df is not run again on every sample, only after the TTL" \
  'rm -f $FIX/df.calls; s=$SECONDS; DELTACTL_DF=$FIX/fake-df-hang lib "HOST_DF_TIMEOUT=1; HOST_FAKE_NOW_US=1000000000000; host_disks_read; for i in 1 2 3 4 5; do host_disk_usage_read || true; done; HOST_FAKE_NOW_US=1000031000000; host_disk_usage_read || true" > /dev/null; [ "$(wc -l < $FIX/df.calls)" = "2" ] && [ $((SECONDS - s)) -le 6 ]'
check "use of the disks: a failed df marks the disk source as unavailable in the sampler" \
  '[ "$(DELTACTL_DF=$FIX/fake-df-hang lib "HOST_DF_TIMEOUT=1; HOST_FAKE_NOW_US=1000000; MT_HOST_DETAIL=1; mt_host_sample; echo \${MT_SRC[disk]}")" = "0" ]'
check "use of the disks: without EPOCHSECONDS (Bash before 5.0) the figures are still refreshed after the TTL" \
  'rm -f $FIX/df.calls; DELTACTL_DF=$FIX/fake-df lib "unset EPOCHSECONDS; HOST_DISK_TTL=1; host_disks_read; host_disk_usage_read; host_disk_usage_read; sleep 1.2; host_disk_usage_read" > /dev/null; [ "$(wc -l < $FIX/df.calls)" = "2" ]'
# A filesystem with 0 blocks shows "-" as its capacity: the percent must still be a number (the panel formats it with printf %d).
cat > "$FIX/fake-df-dash" <<'EOF'
#!/bin/sh
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/sda2 100000000 40000000 60000000 40% /"
echo "/dev/sdb1 0 0 0 - /mnt/my data"
EOF
chmod +x "$FIX/fake-df-dash"
check "use of the disks: a capacity of - (0 blocks) is 0 %, a number, and nothing is written to stderr" \
  '[ "$(DELTACTL_DF=$FIX/fake-df-dash lib "host_disks_read; host_disk_usage_read; echo \${HOST_DISK_PCT[0]} \${HOST_DISK_PCT[1]}")" = "40 0" ]'

finish

#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the PR_*, MT_*, HOST_* and DASH_* tables are read by the panel that draws them
# Scenes of the Server view with fixed data: each one fills the tables the view reads (the requirements, the figures of the host, the
# containers) with deterministic values and draws the whole panel frame at the size of the environment (COLUMNS, DELTACTL_TUI_ROWS). They are
# the golden snapshots of tests/test-server.sh (tests/golden/server/) and the source of the PNG captures. Sourced, never executed: it needs
# lib/bootstrap.sh and lib/cmd/dashboard.sh already loaded, and the environment of the panel (DELTACTL_UI=rich, DELTACTL_TUI_KEYS=...).
#
#   server_scene <name>      name: ok | missing | open | zoom | na | loading | alert | ok-open | focus-containers | zoom-cpu | many-cores |
#                                  many-containers | wide

SERVER_SCENES=(ok missing open zoom na loading alert ok-open focus-containers zoom-cpu many-cores many-containers wide)

# A deterministic series of N samples between 0 and 100 (a wave with bursts), oldest first, into SS.
SS=""
srv_series() { # count seed
  local n="$1" seed="${2:-7}" i v out=""
  for ((i = 0; i < n; i++)); do
    v=$(((i * 37 + seed * 11 + (i % 7) * 9 + (i / 5) * 3) % 70))
    if [ $((i % 23)) -ge 18 ]; then v=$((v + 25)); fi
    out+="${out:+ }$v"
  done
  SS="$out"
}

# One requirement: id state summary [hint]
srv_pr() { # id state summary [hint]
  PR_STATUS[$1]="$2" PR_SUMMARY[$1]="$3"
  PR_RECORDS[$1]="$2$PR_FS$3$PR_FS${4:-}"
}

# Every requirement fine, as a server that is ready.
srv_prereqs_ok() {
  PR_STATUS=() PR_SUMMARY=() PR_RECORDS=()
  srv_pr docker ok "$(t doctor.docker_ok 27.0.0 amd64)"
  srv_pr daemon ok "$(t prereq.daemon_ok)"
  srv_pr compose ok "$(t doctor.compose_ok 2.30.0)"
  srv_pr disk ok "$(t doctor.disk_ok /var/lib/docker 171.1)"
  srv_pr ram ok "$(t doctor.mem_ok 11776 6022)"
  srv_pr mongo ok "$(t doctor.mongo_reach 127.0.0.1:27017)"
  srv_pr nofile ok "$(t doctor.nofile_ok 524288)"
  srv_pr ss ok "$(t doctor.tool_ok ss)"
  srv_pr openssl ok "$(t doctor.tool_ok openssl)"
  srv_pr gunzip ok "$(t doctor.tool_ok gunzip)"
  srv_pr proxy ok "$(t prereq.proxy_ok nginx)"
  srv_pr certbot ok "$(t doctor.tool_ok certbot)"
  srv_pr timesync ok "$(t prereq.time_ok)"
  srv_pr firewall ok "$(t prereq.fw_ok ufw)"
  srv_pr curl ok "$(t doctor.tool_ok curl)"
  PR_N_ERR=0 PR_N_WARN=0
}

# Two required ones that fail (little disk and a Mongo that does not answer), one that warns (ss is missing) and the recommended ones that
# are not there.
srv_prereqs_missing() {
  srv_prereqs_ok
  srv_pr disk err "$(t doctor.disk_low /var/lib/docker 1.9)" "$(t doctor.disk_low_hint)"
  srv_pr ss warn "$(t doctor.tool_missing.ss)" "$(t doctor.tool_missing_hint.ss)"
  srv_pr mongo err "$(t doctor.mongo_noresp 127.0.0.1:27017)" "$(t doctor.mongo_noresp_hint colorado/.env.s0)"
  srv_pr proxy info "$(t prereq.proxy_none)" "$(t prereq.proxy_none_hint)"
  srv_pr certbot info "$(t prereq.certbot_none)" "$(t prereq.certbot_none_hint)"
  srv_pr firewall info "$(t prereq.fw_none)" "$(t prereq.fw_none_hint)"
  PR_N_ERR=2 PR_N_WARN=1
}

# The figures of a busy 8-core server.
srv_host() {
  local i n
  MT_SRC=([cpu]=1 [mem]=1 [load]=1 [uptime]=1 [net]=1 [diskio]=1 [temp]=1 [disk]=1)
  MT_CORE_PCT=(37 22 64 8 61 17 90 5 33)
  MT_CPU_ALL=37
  srv_series 240 3; MT_HH_CPU="$SS"
  srv_series 240 8; MT_HOST_HIST="$SS"
  srv_series 240 13; MT_HH_LOAD=""; for n in $SS; do MT_HH_LOAD+="${MT_HH_LOAD:+ }$((100 + n * 3))"; done
  MT_SRC[psi]=1 MT_SRC[sock]=1 MT_SRC[vm]=1
  HOST_PSI_CPU=0.52 HOST_PSI_MEM=0.00 HOST_PSI_MEM_FULL=0.00 HOST_PSI_IO=1.37 HOST_PSI_IO_FULL=0.80
  HOST_SOCK_USED=412 HOST_SOCK_TCP=58 HOST_SOCK_TW=7 HOST_SOCK_ALLOC=71
  HOST_VM_SWAP_D=0 HOST_VM_OOM=0
  HOST_DISKIO_NAME=(sda sdb) HOST_DISKIO_DR=(7000000 340000) HOST_DISKIO_DW=(16000000 770000) HOST_DISKIO_BUSY=(34 3)
  HOST_NET_IFACES="enp3s0 wlan0"; HOST_NET_IF_DN=([enp3s0]=4194304 [wlan0]=0); HOST_NET_IF_UP=([enp3s0]=1441 [wlan0]=0)
  HOST_TEMP_CPU_C=61 HOST_LOAD1=3.18 HOST_LOAD5=2.64 HOST_LOAD15=1.97
  HOST_MEMD_TOTAL=12058624 HOST_MEMD_USED=5892096 HOST_MEMD_AVAIL=6166528 HOST_MEMD_FREE=1048576 HOST_MEMD_CACHED=4194304 HOST_MEMD_BUFFERS=262144
  HOST_MEMD_SWAP_TOTAL=4194304 HOST_MEMD_SWAP_FREE=3670016 HOST_MEMD_SWAP_USED=524288
  HOST_DISK_N=3
  HOST_DISK_MNT=(/ /srv/data /var/backups) HOST_DISK_DEV=(/dev/sda2 /dev/sdb1 /dev/sdc1) HOST_DISK_FS=(ext4 xfs ext4)
  HOST_DISK_TOTAL=(214748364 524288000 1048576000) HOST_DISK_USED=(184549376 114819072 262144000) HOST_DISK_PCT=(86 22 25)
  HOST_DISKIO_READ_BPS=7340032 HOST_DISKIO_WRITE_BPS=16777216
  HOST_NET_MAIN=enp3s0 HOST_NET_DOWN_BPS=4194304 HOST_NET_UP_BPS=1441
  srv_series 240 5; MT_HH_NETD=""; for n in $SS; do MT_HH_NETD+="${MT_HH_NETD:+ }$((n * 52000))"; done
  srv_series 240 9; MT_HH_NETU=""; for n in $SS; do MT_HH_NETU+="${MT_HH_NETU:+ }$((n * 9000))"; done
  srv_series 240 4; MT_HH_DIOR=""; for n in $SS; do MT_HH_DIOR+="${MT_HH_DIOR:+ }$((n * 90000))"; done
  srv_series 240 6; MT_HH_DIOW=""; for n in $SS; do MT_HH_DIOW+="${MT_HH_DIOW:+ }$((n * 240000))"; done
  MT_NET_DOWN_MAX=5120000 MT_NET_UP_MAX=630000
  HOST_UPTIME_S=8555
  # The containers of two instances.
  DASH_NAMES=(colorado piura)
  DASH_SVCS=([colorado]="s0 s1" [piura]="s0 s1")
  DSV_KIND=([colorado/s0]=ok [colorado/s1]=ok [piura/s0]=ok [piura/s1]=warn)
  DSV_TEXT=([colorado/s0]=healthy [colorado/s1]=healthy [piura/s0]=healthy [piura/s1]=unhealthy)
  DSV_UP=([colorado/s0]="2d 04h" [colorado/s1]="2d 04h" [piura/s0]="5h 12m" [piura/s1]="12m")
  DSV_PORT=([colorado/s0]=4100 [colorado/s1]=4101 [piura/s0]=4110 [piura/s1]=4111)
  ST_RESTARTS=([colorado/s0]=0 [colorado/s1]=0 [piura/s0]=0 [piura/s1]=3)
  MT_CPU=([colorado/s0]=37 [colorado/s1]=412 [piura/s0]=25 [piura/s1]=873)
  MT_PIDS=([colorado/s0]=24 [colorado/s1]=61 [piura/s0]=22 [piura/s1]=75)
  MT_MEM=([colorado/s0]=205520896 [colorado/s1]=1288490188 [piura/s0]=188743680 [piura/s1]=1932735283)
  MT_LIM=([colorado/s0]=536870912 [colorado/s1]=2147483648 [piura/s0]=536870912 [piura/s1]=2147483648)
  # shellcheck disable=SC2004  # MT_HCPU is an associative array: the key is a name, not arithmetic
  for i in colorado/s0 colorado/s1 piura/s0 piura/s1; do srv_series 40 "$((${#i} + 2))"; MT_HCPU[$i]="$SS"; done
}

# What `ps` and `ss` brought (the boxes of the tall screens): the busiest processes and the ports that listen, two of them the ports of the instances.
srv_ps_ss() {
  DASH_SRV_PS_STATE=ready DASH_SRV_SS_STATE=ready
  DASH_SRV_PS_RAW=$'  1412 mongodb   14.2  8.1 mongod
  2231 root      11.8  3.4 node
  2275 root       6.0  2.9 node
   880 root       1.2  0.4 dockerd
   611 root       0.4  0.1 containerd
   907 www-data   0.2  0.1 nginx
     1 root       0.0  0.0 systemd'
  DASH_SRV_SS_RAW=$'22|0.0.0.0|sshd
80|0.0.0.0|nginx
443|0.0.0.0|nginx
4100|0.0.0.0|docker-proxy
4101|0.0.0.0|docker-proxy
27017|127.0.0.1|mongod'
}

# 64 cores (a big server): the grid of the CPU box must say how many it leaves out and not cover the graph.
srv_many_cores() {
  local i
  MT_CORE_PCT=(37)
  for ((i = 0; i < 64; i++)); do MT_CORE_PCT+=($(((i * 29 + 7) % 100))); done
}

# 40 containers of 10 instances: the table scrolls, keeps the cursor in view and the box asks for the height it can have.
srv_many_containers() {
  local i s key n
  DASH_NAMES=() DASH_SVCS=() DSV_KIND=() DSV_TEXT=() DSV_CODES=() DSV_UP=() DSV_PORT=() ST_RESTARTS=() MT_MEM=() MT_LIM=() MT_CPU=() MT_HCPU=() MT_PIDS=()
  for ((i = 1; i <= 10; i++)); do
    printf -v n 'inst%02d' "$i"
    DASH_NAMES+=("$n")
    DASH_SVCS[$n]="s0 s1 s2 s3"
    for s in s0 s1 s2 s3; do
      key="$n/$s"
      DSV_KIND[$key]=ok DSV_TEXT[$key]=healthy DSV_UP[$key]="${i}d 01h" DSV_PORT[$key]=$((4000 + i * 10 + ${s#s})) ST_RESTARTS[$key]=0
      MT_MEM[$key]=$((100000000 + i * 7000000)) MT_LIM[$key]=536870912 MT_CPU[$key]=$(((i * 37 + ${s#s} * 11) % 300)) MT_PIDS[$key]=$((10 + i))
      srv_series 40 "$((i + ${s#s}))"; MT_HCPU[$key]="$SS"
    done
  done
  DSV_KIND[inst03/s1]=err DSV_TEXT[inst03/s1]=exited DSV_KIND[inst07/s2]=warn DSV_TEXT[inst07/s2]=unhealthy
  DSV_KIND[inst09/s3]=dim DSV_TEXT[inst09/s3]="not created" DSV_CODES[inst09/s3]="not-created"
}

# Nothing is readable: a container, or a server without /proc or /sys.
srv_host_na() {
  MT_SRC=([cpu]=0 [mem]=0 [load]=0 [uptime]=0 [net]=0 [diskio]=0 [temp]=0 [disk]=0)
  MT_CORE_PCT=() MT_CPU_ALL="" MT_HH_CPU="" MT_HOST_HIST="" HOST_DISK_N=0 HOST_NET_DOWN_BPS="" HOST_DISKIO_READ_BPS="" HOST_TEMP_CPU_C=""
  HOST_MEMD_TOTAL="" HOST_MEMD_USED=""
  DASH_NAMES=()
}

server_scene() { # name
  local name="$1"
  tui_size
  dash_init
  DASH_HOST=testhost
  DASH_DOCKER_VER=27.0.0
  MT_HOST_PCT=48 MT_HOST_TOTAL_KB=12058624 MT_HOST_USED_KB=5892096 MT_HOST_LOAD=3.18 MT_HOST_HIST=""
  PR_DISTRO_ID=debian PR_DISTRO_NAME="Debian GNU/Linux 12" PR_MANAGER=apt
  DASH_SRV_STATE=ready DASH_SRV_BUSY=0 DASH_SRV_SEL=0 DASH_SRV_OPEN=0 DASH_SRV_ZOOM=0 DASH_SRV_REQ=auto DASH_SRV_FOCUS=req DASH_SRV_PZ="" DASH_SRV_CSEL=0
  srv_host
  srv_ps_ss
  case "$name" in
    ok) srv_prereqs_ok ;;
    missing) srv_prereqs_missing; DASH_SRV_SEL=3 ;;   # the first one that fails: the disk
    open) srv_prereqs_missing; DASH_SRV_SEL=5; DASH_SRV_OPEN=1 ;;   # Mongo, open
    zoom) srv_prereqs_ok; DASH_SRV_ZOOM=1 ;;
    na) srv_prereqs_ok; srv_host_na ;;
    alert)
      # Everything required is fine, but the server is not: the disk is nearly full, little memory, the processor near its limit, a container fails.
      srv_prereqs_ok
      HOST_DISK_PCT=(96 22 91) HOST_MEMD_AVAIL=524288 HOST_MEMD_USED=11534336 HOST_TEMP_CPU_C=96 HOST_TEMP_CPU_CRIT=100
      DSV_KIND[colorado/s1]=err DSV_TEXT[colorado/s1]=exited
      ;;
    ok-open) srv_prereqs_ok; DASH_SRV_REQ=open; DASH_SRV_SEL=4 ;;   # the list opened by hand with everything fine
    focus-containers) srv_prereqs_ok; DASH_SRV_FOCUS=containers; DASH_SRV_CSEL=2 ;;
    zoom-cpu) srv_prereqs_ok; DASH_SRV_FOCUS=cpu; DASH_SRV_PZ=cpu ;;
    many-cores) srv_prereqs_ok; srv_many_cores ;;
    many-containers) srv_prereqs_ok; srv_many_containers; DASH_SRV_FOCUS=containers; DASH_SRV_CSEL=17 ;;
    wide) srv_prereqs_ok ;;   # the same as ok: meant for the big sizes (250x70)
    loading) PR_STATUS=() PR_SUMMARY=() PR_RECORDS=(); DASH_SRV_STATE=loading DASH_SRV_BUSY=1; srv_host_na ;;
    *) echo "unknown scene $name" >&2; return 1 ;;
  esac
  dash_srv_counts
  dash_host_build
  DASH_VIEW=server
  dash_render
}

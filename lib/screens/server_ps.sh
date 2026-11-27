#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2154  # the DASH_* variables are declared in lib/cmd/dashboard*.sh and lib/screens/server.sh and shared
# The boxes of the Server view that need a program (lib/screens/server.sh sources this file): the busiest processes (`ps`), the ports that
# are listening (`ss`, crossed with the ports of the instances, with the connections open on each) and the size of the folder of each instance
# (`du`, the instances box). Nothing else in the view starts a process. They run in the background
# (dash_async), only while their box is on screen (it needs a tall screen, or the zoom), at most every DELTACTL_PS_TTL / DELTACTL_SS_TTL seconds
# (5 and 15 by default, kept between 5 and 60) and cut by a time limit. A server without `ps` or `ss` says so in the box instead of failing.
# DELTACTL_PS and DELTACTL_SS replace the programs, only inside the tests.

DASH_SRV_PS_RAW="" DASH_SRV_PS_STATE=none DASH_SRV_PS_AT=-1000 DASH_SRV_PSEL=0 DASH_SRV_PTOP=0
DASH_SRV_SS_RAW="" DASH_SRV_SS_STATE=none DASH_SRV_SS_AT=-1000 DASH_SRV_TSEL=0 DASH_SRV_TTOP=0
DASH_SRV_PS_N=0 DASH_SRV_SS_N=0
DASH_SRV_DU_STATE=none DASH_SRV_DU_AT=-1000 DASH_SRV_DU_RAW=""
declare -gA DASH_SRV_DU=()   # instance -> kilobytes of its folder

# The refresh interval of a box into DASH_THR: the variable ($1) when it is a number from 5 to 60, else the default ($2).
dash_srv_ttl() { # variable default [min max]
  local v="${!1:-}"
  if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge "${3:-5}" ] && [ "$v" -le "${4:-60}" ]; then DASH_THR="$v"; else DASH_THR="$2"; fi
}

# Runs in the background: the busiest processes as "pid user cpu mem command" lines, or NA when `ps` is not there or says nothing.
dash_srv_ps_dump() {
  local ps=ps out=""
  if host_test_hook && [ -n "${DELTACTL_PS:-}" ]; then ps="$DELTACTL_PS"; fi
  if host_has timeout; then
    out="$(timeout -k 1 3 "$ps" -eo pid=,user=,pcpu=,pmem=,comm= --sort=-pcpu 2> /dev/null | head -n 40)" || true
  else
    out="$("$ps" -eo pid=,user=,pcpu=,pmem=,comm= --sort=-pcpu 2> /dev/null | head -n 40)" || true
  fi
  if [ -z "$out" ]; then echo NA; else printf '%s\n' "$out"; fi
}

# Runs in the background: the TCP ports that listen as "port|address|process" lines (once per port, in order), or NA.
dash_srv_ss_dump() {
  local ss=ss out="" est="" state rq sq loc peer rest port addr proc
  local -A conn=()
  if host_test_hook && [ -n "${DELTACTL_SS:-}" ]; then ss="$DELTACTL_SS"; fi
  if host_has timeout; then
    out="$(timeout -k 1 3 "$ss" -ltnp 2> /dev/null)" || true
  else
    out="$("$ss" -ltnp 2> /dev/null)" || true
  fi
  [ -n "$out" ] || { echo NA; return 0; }
  # (the connections open on each local port: a second, cheap call)
  if host_has timeout; then est="$(timeout -k 1 3 "$ss" -Htn state established 2> /dev/null)" || true; else est="$("$ss" -Htn state established 2> /dev/null)" || true; fi
  while read -r rq sq loc peer; do
    [[ "$rq" =~ ^[0-9]+$ ]] || continue
    port="${loc##*:}"
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    conn[$port]=$((${conn[$port]:-0} + 1))
  done <<< "$est"
  {
    while read -r state rq sq loc peer rest; do
      [ "$state" = LISTEN ] || continue
      port="${loc##*:}" addr="${loc%:*}" proc=""
      [[ "$port" =~ ^[0-9]+$ ]] || continue
      case "$rest" in *'users:(("'*) proc="${rest#*users:((\"}"; proc="${proc%%\"*}" ;; esac
      echo "$port|$addr|$proc|${conn[$port]:-0}"
    done <<< "$out"
  } | sort -t'|' -k1,1n -u
}

# Runs in the background: "instance|kilobytes" for the folder of each instance (`du` can take seconds on a big media folder: it is cut at 20 s).
# DELTACTL_DU replaces the program, only inside the tests.
dash_srv_du_dump() {
  local du=du d name kb="" _
  if host_test_hook && [ -n "${DELTACTL_DU:-}" ]; then du="$DELTACTL_DU"; fi
  for d in "$INSTANCES_DIR"/*/; do
    [ -d "$d" ] || continue
    name="${d%/}"; name="${name##*/}"
    kb=""
    if host_has timeout; then read -r kb _ < <(timeout -k 1 20 "$du" -sk "$d" 2> /dev/null) || true; else read -r kb _ < <("$du" -sk "$d" 2> /dev/null) || true; fi
    [[ "$kb" =~ ^[0-9]+$ ]] && echo "$name|$kb"
  done
  true
}

# Is the box named $1 on screen (as the last frame drew it)?
dash_srv_visible() { # name
  local v
  for v in ${DASH_SRV_VIS[@]+"${DASH_SRV_VIS[@]}"}; do [ "$v" != "$1" ] || return 0; done
  return 1
}

# Asks for the processes or the ports without waiting for them (the synchronous one in the test mode).
dash_srv_ps_request() {
  DASH_SRV_PS_AT="$SECONDS"
  if tui_test_mode; then dash_srv_ps_apply "$(dash_srv_ps_dump)"; return 0; fi
  dash_async srvps "" dash_srv_ps_dump || true
}
dash_srv_ss_request() {
  DASH_SRV_SS_AT="$SECONDS"
  if tui_test_mode; then dash_srv_ss_apply "$(dash_srv_ss_dump)"; return 0; fi
  dash_async srvss "" dash_srv_ss_dump || true
}
dash_srv_du_request() {
  DASH_SRV_DU_AT="$SECONDS"
  if tui_test_mode; then dash_srv_du_apply "$(dash_srv_du_dump)"; return 0; fi
  dash_async srvdu "" dash_srv_du_dump || true
}
dash_srv_du_apply() { # text
  local name kb
  DASH_SRV_DU=()
  while IFS='|' read -r name kb; do
    [[ "$kb" =~ ^[0-9]+$ ]] && DASH_SRV_DU[$name]="$kb"
  done <<< "$1"
  DASH_SRV_DU_STATE=ready DASH_SRV_DU_RAW="$1"
  DASH_DIRTY=1
}
dash_srv_ps_apply() { # text
  if [ "$1" = NA ] || [ -z "$1" ]; then DASH_SRV_PS_STATE=na DASH_SRV_PS_RAW=""; else DASH_SRV_PS_STATE=ready DASH_SRV_PS_RAW="$1"; fi
  DASH_DIRTY=1
}
dash_srv_ss_apply() { # text
  if [ "$1" = NA ] || [ -z "$1" ]; then DASH_SRV_SS_STATE=na DASH_SRV_SS_RAW=""; else DASH_SRV_SS_STATE=ready DASH_SRV_SS_RAW="$1"; fi
  DASH_DIRTY=1
}

# Called at every turn of the loop (scr_server_tick): takes what the background jobs brought and asks again when a box that is on screen is due.
dash_srv_ps_tick() {
  local ttl
  if dash_async_take srvps; then dash_srv_ps_apply "$DASH_AS_TEXT"; fi
  if dash_async_take srvss; then dash_srv_ss_apply "$DASH_AS_TEXT"; fi
  if dash_async_take srvdu; then dash_srv_du_apply "$DASH_AS_TEXT"; fi
  [ "$DASH_VIEW" = "server" ] && [ "$DASH_PAUSED" -eq 0 ] || return 0
  dash_dwelled || return 0   # (passing through the view starts no program)
  if dash_srv_visible procs; then
    dash_srv_ttl DELTACTL_PS_TTL 5; ttl="$DASH_THR"
    if [ $((SECONDS - DASH_SRV_PS_AT)) -ge "$ttl" ] && [ -z "${DASH_AS_PID[srvps]:-}" ]; then dash_srv_ps_request; fi
  fi
  if dash_srv_visible inst; then
    dash_srv_ttl DELTACTL_DU_TTL 300 60 3600; ttl="$DASH_THR"
    if [ $((SECONDS - DASH_SRV_DU_AT)) -ge "$ttl" ] && [ -z "${DASH_AS_PID[srvdu]:-}" ]; then dash_srv_du_request; fi
  fi
  if dash_srv_visible ports; then
    dash_srv_ttl DELTACTL_SS_TTL 15; ttl="$DASH_THR"
    if [ $((SECONDS - DASH_SRV_SS_AT)) -ge "$ttl" ] && [ -z "${DASH_AS_PID[srvss]:-}" ]; then dash_srv_ss_request; fi
  fi
}

# Where a process runs into DASH_ORIG: the "instance/service" of the container whose cgroup it is in, "-" for the server's own (the cgroups of
# the containers are the ones the sampler resolved: MT_CG_MEMDIR). Only a file read per row, no process.
DASH_ORIG=""
dash_srv_origin() { # pid
  local line root="${DELTACTL_CGROUP_ROOT:-/sys/fs/cgroup}" file="${DELTACTL_PROC_ROOT:-/proc}/$1/cgroup"
  DASH_ORIG="-"
  [ -r "$file" ] || return 0
  while IFS= read -r line; do
    case "$line" in *::*) line="${line#*::}"; [ -z "${DASH_ORIGIN[$line]:-}" ] || DASH_ORIG="${DASH_ORIGIN[$line]}"; return 0 ;; esac
  done < "$file"
}

# The busiest processes: pid, user, CPU and memory in percent, where it runs and the command; the cursor is on screen when the box has the focus.
declare -gA DASH_ORIGIN=()
dash_srv_procs() { # width height
  local w="$1" h="$2" cw=$(($1 - 4)) ch=$(($2 - 2)) mk pid usr cpu mem cmd sel=-1 n=0 uw=10 key dir org=0 root="${DELTACTL_CGROUP_ROOT:-/sys/fs/cgroup}"
  local -a cols=() rws=()
  DASH_ORIGIN=()
  if [ "$cw" -ge 70 ]; then
    org=1
    for key in "${!MT_CG_MEMDIR[@]}"; do dir="${MT_CG_MEMDIR[$key]}"; DASH_ORIGIN[${dir#"$root"}]="$key"; done
  fi
  DASH_SRV_L=()
  case "$DASH_SRV_PS_STATE" in
    na) dash_srv_note na; dash_srv_mbox procs "$w" "$h"; return 0 ;;
    ready) ;;
    *) dash_srv_note waiting; dash_srv_mbox procs "$w" "$h"; return 0 ;;
  esac
  while read -r pid usr cpu mem cmd; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    th_grad cpu "${cpu%%.*}"
    mk="  "; if [ "$DASH_SRV_FOCUS" = procs ] && [ "$n" -eq "$DASH_SRV_PSEL" ]; then mk="$UI_S_SEL "; fi
    if [ "$org" -eq 1 ]; then
      dash_srv_origin "$pid"
      [ "$DASH_ORIG" != "-" ] || { dt tui.srv.origin.host; DASH_ORIG="${TH[dim]:-}$DTV$TH_RESET"; }
      rws+=("$mk$pid$KIT_SEP$usr$KIT_SEP$TH_C$cpu$TH_RESET$KIT_SEP$mem$KIT_SEP$DASH_ORIG$KIT_SEP$cmd")
    else
      rws+=("$mk$pid$KIT_SEP$usr$KIT_SEP$TH_C$cpu$TH_RESET$KIT_SEP$mem$KIT_SEP$cmd")
    fi
    n=$((n + 1))
  done <<< "$DASH_SRV_PS_RAW"
  DASH_SRV_PS_N="$n"
  [ "$DASH_SRV_PSEL" -lt "$n" ] || DASH_SRV_PSEL=$((n - 1))
  [ "$DASH_SRV_PSEL" -ge 0 ] || DASH_SRV_PSEL=0
  if [ "$DASH_SRV_FOCUS" = "procs" ] && [ "$n" -gt 0 ]; then sel="$DASH_SRV_PSEL"; fi
  dt tui.srv.col.pid; cols+=("$DTV|9|r")
  dt tui.srv.col.user; cols+=("$DTV|$uw|l")
  dt tui.res.col.cpu; cols+=("$DTV|5|r")
  dt tui.res.col.mem; cols+=("$DTV|8|r")
  [ "$org" -eq 0 ] || { dt tui.srv.col.origin; cols+=("$DTV|16|l"); }
  dt tui.srv.col.cmd; cols+=("$DTV|*|l")
  dt tui.srv.na
  kit_table "$cw" "$ch" cols rws mag=cpu "sel=$sel" "top=$DASH_SRV_PTOP" "empty=$DTV"
  DASH_SRV_PTOP="$KTB_TOP"
  DASH_SRV_L=("${KTB_LINES[@]}")
  if [ "$sel" -lt 0 ]; then DASH_SRV_L=("${KTB_LINES[@]#"$TUI_SEL"}"); fi
  dash_srv_mbox procs "$w" "$h" "$n"
}

# The ports that listen, with the process that owns each one and, when it is the port of a service of an instance, which one.
dash_srv_ports() { # width height
  local w="$1" h="$2" cw=$(($1 - 4)) ch=$(($2 - 2)) mk port addr proc sel=-1 n=0 own key mine=0 aw=16
  local -a cols=() rws=()
  local -A owner=()
  DASH_SRV_L=()
  case "$DASH_SRV_SS_STATE" in
    na) dash_srv_note na; dash_srv_mbox ports "$w" "$h"; return 0 ;;
    ready) ;;
    *) dash_srv_note waiting; dash_srv_mbox ports "$w" "$h"; return 0 ;;
  esac
  for key in "${!DSV_PORT[@]}"; do
    [ -z "${DSV_PORT[$key]}" ] || owner[${DSV_PORT[$key]}]="$key"
  done
  while IFS='|' read -r port addr proc cn; do
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    [[ "$cn" =~ ^[0-9]+$ ]] || cn="-"
    own="${owner[$port]:-}"
    if [ -n "$own" ]; then own="${TH[accent]:-}$own$TH_RESET"; mine=$((mine + 1)); else own="-"; fi
    mk="  "; if [ "$DASH_SRV_FOCUS" = ports ] && [ "$n" -eq "$DASH_SRV_TSEL" ]; then mk="$UI_S_SEL "; fi
    if [ "$cn" != "-" ] && [ "$cn" -gt 0 ]; then cn="${TH[accent]:-}$cn$TH_RESET"; fi
    if [ "$cw" -ge 62 ]; then rws+=("$mk$port$KIT_SEP$addr$KIT_SEP${proc:--}$KIT_SEP$cn$KIT_SEP$own"); else rws+=("$mk$port$KIT_SEP$addr$KIT_SEP${proc:--}$KIT_SEP$own"); fi
    n=$((n + 1))
  done <<< "$DASH_SRV_SS_RAW"
  DASH_SRV_SS_N="$n"
  [ "$DASH_SRV_TSEL" -lt "$n" ] || DASH_SRV_TSEL=$((n - 1))
  [ "$DASH_SRV_TSEL" -ge 0 ] || DASH_SRV_TSEL=0
  if [ "$DASH_SRV_FOCUS" = "ports" ] && [ "$n" -gt 0 ]; then sel="$DASH_SRV_TSEL"; fi
  dt tui.srv.col.port; cols+=("$DTV|8|r")
  dt tui.srv.col.addr; cols+=("$DTV|$aw|l")
  dt tui.srv.col.proc; cols+=("$DTV|14|l")
  [ "$cw" -lt 62 ] || { dt tui.srv.col.conns; cols+=("$DTV|6|r"); }
  dt tui.srv.col.owner; cols+=("$DTV|*|l")
  dt tui.srv.na
  kit_table "$cw" "$ch" cols rws mag=cpu "sel=$sel" "top=$DASH_SRV_TTOP" "empty=$DTV"
  DASH_SRV_TTOP="$KTB_TOP"
  DASH_SRV_L=("${KTB_LINES[@]}")
  if [ "$sel" -lt 0 ]; then DASH_SRV_L=("${KTB_LINES[@]#"$TUI_SEL"}"); fi
  dash_srv_t tui.srv.ports.mine "$mine"
  dash_srv_mbox ports "$w" "$h" "$n" "$DASH_T"
}

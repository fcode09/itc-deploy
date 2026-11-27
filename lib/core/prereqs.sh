#!/usr/bin/env bash
# shellcheck disable=SC2034  # PR_* tables are read by doctor, the panel and the tests
# Server prerequisites: what the server needs for deltactl to work, as a catalog (lib/core/prereqs.data) plus one read-only check
# per requirement (prereq_check_<id>). ./deltactl doctor, `doctor --json` and the panel's Server screen all read this one source.
# NOTHING here writes, installs or starts anything: a check only reads (files, `docker info`, a TCP connection); the install
# commands are text to show, for the person to run. Sourced by lib/bootstrap.sh.

PR_IDS=()
declare -gA PR_LEVEL=() PR_SECTION=() PR_URL=() PR_CMD=()   # PR_CMD["<id>|<manager>"]
PR_OVR=()                                                    # exceptions by distribution: "<id>|<distros>|<command, or - for none>"
PR_MANAGERS=(apt dnf pacman apk)

# Reads the catalog. It starts no process: every field is split by `read`.
# A line @<id>|<distro>[,<distro>...]|<command> overrides the command of the package manager for those distributions (distro<N: only
# those older than major version N; "-" as the command = no command is known to work there). Same manager, different repository.
prereq_load() { # [file]
  local file="${1:-$ROOT/lib/core/prereqs.data}" id level section url c_apt c_dnf c_pacman c_apk
  PR_IDS=() PR_LEVEL=() PR_SECTION=() PR_URL=() PR_CMD=() PR_OVR=()
  [ -r "$file" ] || return 1
  while IFS='|' read -r id level section url c_apt c_dnf c_pacman c_apk || [ -n "$id" ]; do
    id="${id%$'\r'}"
    case "$id" in '' | '#'*) continue ;; esac
    case "$id" in @*) PR_OVR+=("${id#@}|$level|${section%$'\r'}"); continue ;; esac
    PR_IDS+=("$id")
    PR_LEVEL[$id]="$level" PR_SECTION[$id]="$section"
    [ "$url" = "-" ] || PR_URL[$id]="$url"
    [ "$c_apt" = "-" ] || PR_CMD["$id|apt"]="$c_apt"
    [ "$c_dnf" = "-" ] || PR_CMD["$id|dnf"]="$c_dnf"
    [ "$c_pacman" = "-" ] || PR_CMD["$id|pacman"]="$c_pacman"
    c_apk="${c_apk%$'\r'}"
    [ "$c_apk" = "-" ] || PR_CMD["$id|apk"]="$c_apk"
  done < "$file"
}
prereq_load

# --- Distribution -------------------------------------------------------------------------------------------
# PR_DISTRO_ID / PR_DISTRO_NAME from os-release (DELTACTL_OS_RELEASE replaces the path, for tests) and PR_MANAGER (apt, dnf, pacman,
# apk, or empty when it is not known). Read with `read`: no process.
PR_DISTRO_ID="" PR_DISTRO_NAME="" PR_MANAGER="" PR_DISTRO_MAJOR=""
prereq_distro() {
  local f="${DELTACTL_OS_RELEASE:-/etc/os-release}" k v id="" like="" name="" pretty="" ver="" tok
  PR_DISTRO_ID="" PR_DISTRO_NAME="" PR_MANAGER="" PR_DISTRO_MAJOR=""
  if [ -r "$f" ]; then
    while IFS='=' read -r k v || [ -n "$k" ]; do
      v="${v%$'\r'}"; v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"
      case "$k" in ID) id="$v" ;; ID_LIKE) like="$v" ;; NAME) name="$v" ;; PRETTY_NAME) pretty="$v" ;; VERSION_ID) ver="$v" ;; esac
    done < "$f"
  fi
  PR_DISTRO_ID="${id,,}"
  PR_DISTRO_MAJOR="${ver%%.*}"
  PR_DISTRO_NAME="${pretty:-$name}"
  for tok in $PR_DISTRO_ID ${like,,}; do
    case "$tok" in
      debian | ubuntu | linuxmint | raspbian | pop | kali | devuan) PR_MANAGER=apt ;;
      fedora | rhel | centos | rocky | almalinux | amzn | ol | nobara) PR_MANAGER=dnf ;;
      arch | manjaro | endeavouros | cachyos | artix | garuda) PR_MANAGER=pacman ;;
      alpine) PR_MANAGER=apk ;;
    esac
    [ -z "$PR_MANAGER" ] || break
  done
  if [ -z "$PR_MANAGER" ] && [ ! -r "$f" ]; then   # no os-release at all: whatever package manager is installed
    for tok in apt-get:apt dnf:dnf pacman:pacman apk:apk; do
      if host_has "${tok%%:*}"; then PR_MANAGER="${tok#*:}"; break; fi
    done
  fi
  return 0
}

# Install command of a requirement for this server's package manager, in PR_INSTALL (empty when there is none).
PR_INSTALL=""
prereq_install_r() { # id [manager]
  local m="${2:-$PR_MANAGER}" o oid od oc d lt
  PR_INSTALL=""
  [ -n "$m" ] || return 1
  if [ "$m" = "$PR_MANAGER" ] && [ -n "$PR_DISTRO_ID" ]; then   # an exception of this distribution wins over the manager's command
    for o in ${PR_OVR[@]+"${PR_OVR[@]}"}; do
      IFS='|' read -r oid od oc <<< "$o"
      [ "$oid" = "$1" ] || continue
      for d in ${od//,/ }; do
        lt=""
        case "$d" in *"<"*) lt="${d#*<}" d="${d%%<*}" ;; esac
        [ "$d" = "$PR_DISTRO_ID" ] || continue
        if [ -n "$lt" ]; then   # only the versions older than lt; an unknown version is not covered by the exception
          [[ "$PR_DISTRO_MAJOR" =~ ^[0-9]+$ ]] && [ "$PR_DISTRO_MAJOR" -lt "$lt" ] || continue
        fi
        [ "$oc" = "-" ] || PR_INSTALL="$oc"
        [ -n "$PR_INSTALL" ]
        return
      done
    done
  fi
  PR_INSTALL="${PR_CMD["$1|$m"]:-}"
  [ -n "$PR_INSTALL" ]
}

# --- Results of a check -----------------------------------------------------------------------------------
# A check reports with pr_res <state> <text> [hint...] (state: ok | warn | err | info; a silent result is not printed by doctor
# but still describes the requirement) or pr_na (does not apply because something it needs is missing).
PR_RES_ST=() PR_RES_MSG=() PR_RES_HINT=() PR_RES_QUIET=()
pr_res() { # state text [hint...]
  local st="$1" msg="$2" h d
  shift 2
  PR_RES_ST+=("$st") PR_RES_MSG+=("$msg") PR_RES_QUIET+=(0)
  h=""
  for d in "$@"; do [ -z "$d" ] || h+="${h:+$'\n'}$d"; done
  PR_RES_HINT+=("$h")
}
pr_quiet() { # state text
  PR_RES_ST+=("$1") PR_RES_MSG+=("$2") PR_RES_HINT+=("") PR_RES_QUIET+=(1)
}
pr_na() { PR_RES_ST+=(na) PR_RES_MSG+=("$(t prereq.na)") PR_RES_HINT+=("") PR_RES_QUIET+=(1); }

# Does the server have this program? (also looks in the sbin folders, which a normal user often has out of the PATH;
# DELTACTL_PR_SBIN replaces that list, for tests)
pr_has() { # program
  local d
  host_has "$1" && return 0
  for d in ${DELTACTL_PR_SBIN-/usr/sbin /sbin /usr/local/sbin}; do [ -x "$d/$1" ] && return 0; done
  return 1
}

# Forgets what a previous run learned (the daemon's answer).
prereq_reset() { PR_DAEMON=""; }

# Does the Docker daemon answer? Asked once per run.
PR_DAEMON=""
pr_daemon() {
  if [ -z "$PR_DAEMON" ]; then
    if dk_installed && dk_daemon_ok; then PR_DAEMON=1; else PR_DAEMON=0; fi
  fi
  [ "$PR_DAEMON" = 1 ]
}

# 512m -> 512, 2g -> 2048, 1.5g -> 1536 (megabytes)
dr_mem_mb() { # value
  awk -v v="$1" 'BEGIN {
    u = tolower(substr(v, length(v))); n = substr(v, 1, length(v) - 1) + 0
    if (u == "g") n *= 1024; else if (u == "k") n /= 1024; else if (u != "m") n = v / 1048576
    printf "%d", n }'
}

# Can a TCP connection be opened? (3 s limit, no external tools.) The host comes from a .env file or from Docker, so it is never put
# into code: it must look like a host name or an address and the port like a number, and both reach the shell as arguments.
dr_tcp() { # host port
  [[ "${1:-}" =~ ^[A-Za-z0-9._:-]+$ ]] && [[ "${2:-}" =~ ^[0-9]{1,5}$ ]] || return 1
  # shellcheck disable=SC2016  # the program is meant to expand its own arguments
  timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$1" "$2" > /dev/null 2>&1
}

# Host and port of a URI mongodb://[user:password@]host[:port][,host2...][/database][?options]  ->  "host port".
# mongodb+srv has no port to try (the name is a DNS record): the port is the word srv. A host with strange characters comes out with
# them replaced by "?", so it can be shown without sending escape sequences to the terminal.
dr_mongo_hostport() { # uri -> "host port"
  local u="${1#*://}" h p rest srv=""
  case "$1" in mongodb+srv://*) srv=1 ;; esac
  u="${u%%[/?]*}"   # only the authority: the options may hold an @ that is not a user
  u="${u##*@}"      # a password may hold an @: the host is after the last one
  u="${u%%,*}"      # a list of hosts: the first
  if [[ "$u" == \[* ]]; then   # [::1] or [::1]:27017
    h="${u%%]*}"
    h="${h#\[}"
    rest="${u#*]}"
    p="${rest#:}"
    [ "$rest" != "$p" ] || p=""
  else
    h="${u%%:*}"
    p=""
    [ "$h" = "$u" ] || p="${u#*:}"
  fi
  h="${h//[!A-Za-z0-9._:-]/\?}"
  if [ -n "$srv" ]; then p=srv; else [[ "$p" =~ ^[0-9]{1,5}$ ]] || p=27017; fi
  printf '%s %s' "$h" "$p"
}

dr_kb_to_gb() { awk -v k="$1" 'BEGIN { printf "%.1f", k / 1048576 }'; }

# --- The checks (read-only) ---------------------------------------------------------------------------------
prereq_check_docker() {
  if ! dk_installed; then
    pr_res err "$(t doctor.docker_missing)" "$(t doctor.docker_missing_hint)"
  elif pr_daemon; then
    pr_res ok "$(t doctor.docker_ok "$(dk_info ServerVersion)" "$(server_arch)")"
  else
    pr_quiet ok "$(t prereq.docker_installed)"   # (the daemon check explains why it does not answer)
  fi
}

prereq_check_daemon() {
  dk_installed || { pr_na; return 0; }
  if pr_daemon; then
    pr_quiet ok "$(t prereq.daemon_ok)"
  else
    pr_res err "$(t doctor.daemon_down)" "$(t doctor.daemon_down_hint1)" "$(t doctor.daemon_down_hint2)"
  fi
}

prereq_check_compose() {
  local cv
  pr_daemon || { pr_na; return 0; }
  cv="$(dk_compose_version)"
  if [ -z "$cv" ]; then
    pr_res err "$(t doctor.compose_missing)" "$(t doctor.compose_missing_hint)"
  elif [ "$(printf '%s\n%s\n' 2.20.0 "$cv" | sort -V | head -n1)" != "2.20.0" ]; then
    pr_res err "$(t doctor.compose_old "$cv")" "$(t doctor.compose_old_hint)"
  else
    pr_res ok "$(t doctor.compose_ok "$cv")"
  fi
}

prereq_check_disk() {
  local root free
  root="$(dk_info DockerRootDir)"
  [ -n "$root" ] && [ -d "$root" ] || root="$ROOT"
  free="$(host_free_kb "$root")"
  if [[ "${free:-}" =~ ^[0-9]+$ ]]; then
    if [ "$free" -lt 3145728 ]; then
      pr_res err "$(t doctor.disk_low "$root" "$(dr_kb_to_gb "$free")")" "$(t doctor.disk_low_hint)"
    elif [ "$free" -lt 10485760 ]; then
      pr_res warn "$(t doctor.disk_warn "$root" "$(dr_kb_to_gb "$free")")"
    else
      pr_res ok "$(t doctor.disk_ok "$root" "$(dr_kb_to_gb "$free")")"
    fi
  else
    pr_res info "$(t doctor.disk_unknown)"
  fi
}

# 0.4 -> 40, 1.5 -> 150, 2 -> 200 (hundredths of a core, so the sums stay integers)
dr_cpus_centi() { # value
  awk -v v="$1" 'BEGIN { printf "%d", v * 100 + 0.5 }'
}

# Cores of this server (DELTACTL_CPUINFO replaces /proc/cpuinfo, for tests); empty when it cannot be read.
dr_cpu_cores() {
  local n
  n="$(awk '/^processor[[:space:]]*:/ { n++ } END { if (n > 0) print n }' "${DELTACTL_CPUINFO:-/proc/cpuinfo}" 2> /dev/null || true)"
  printf '%s' "$n"
}

# The CPU ceilings (<SVC>_CPUS) of the active services of every instance against the cores of the server. Like the memory ones they
# are ceilings, not reservations; the point is to leave at least half a core for the system and Docker. Only values written in a
# .env.instance count (a service without one runs with the default of its compose file).
prereq_check_cpus() {
  local cores f name svc raw c sum=0 free
  cores="$(dr_cpu_cores)"
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    name="$(basename "$(dirname "$f")")"
    st_enabled "$name" 2> /dev/null || ST_ENABLED=()
    for svc in ${ST_ENABLED[@]+"${ST_ENABLED[@]}"}; do
      raw="$(get_var "$f" "${svc^^}_CPUS")"
      [[ "$raw" =~ ^[0-9]+(\.[0-9]{1,2})?$ ]] || continue
      c="$(dr_cpus_centi "$raw")"
      sum=$((sum + c))
    done
  done
  [[ "${cores:-}" =~ ^[0-9]+$ ]] || return 0
  [ "$sum" -gt 0 ] || return 0
  free=$((cores * 100 - sum))
  if [ "$free" -lt 50 ]; then
    pr_res warn "$(t doctor.cpu_over "$(awk -v s="$sum" 'BEGIN { printf "%.2f", s / 100 }')" "$cores")" "$(t doctor.cpu_over_hint)"
  else
    pr_res ok "$(t doctor.cpu_limits "$(awk -v s="$sum" 'BEGIN { printf "%.2f", s / 100 }')" "$cores")"
  fi
}

prereq_check_ram() {
  local total avail f name svc raw mb sum=0
  total="$(awk '/^MemTotal:/ { print $2 }' "${DELTACTL_MEMINFO:-/proc/meminfo}" 2> /dev/null || true)"
  avail="$(awk '/^MemAvailable:/ { print $2 }' "${DELTACTL_MEMINFO:-/proc/meminfo}" 2> /dev/null || true)"
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    name="$(basename "$(dirname "$f")")"
    st_enabled "$name" 2> /dev/null || ST_ENABLED=()
    for svc in ${ST_ENABLED[@]+"${ST_ENABLED[@]}"}; do
      raw="$(get_var "$f" "${svc^^}_MEM_LIMIT")"
      [ -n "$raw" ] || continue
      mb="$(dr_mem_mb "$raw")"
      sum=$((sum + mb))
    done
  done
  if [[ "${total:-}" =~ ^[0-9]+$ ]]; then
    pr_res ok "$(t doctor.mem_ok "$((total / 1024))" "$((${avail:-0} / 1024))")"
    if [ "$sum" -gt $((total / 1024)) ]; then
      pr_res warn "$(t doctor.mem_over "$sum")" "$(t doctor.mem_over_hint)"
    elif [ "$sum" -gt 0 ]; then
      pr_res ok "$(t doctor.mem_limits "$sum")"
    fi
  else
    pr_res info "$(t doctor.mem_unknown)"
  fi
  prereq_check_cpus
}

# MongoDB reachable from the host and, for host.docker.internal, from the containers (through Docker's gateway).
prereq_check_mongo() {
  local gw="" f var uri h p seen="" svc
  if pr_daemon; then gw="$(dk_network_gateway)"; gw="${gw//[!A-Za-z0-9._:-]/?}"; fi
  for svc in "${KNOWN_SERVICES[@]}"; do
    for f in "$INSTANCES_DIR"/*/.env."$svc"; do
      [ -f "$f" ] || continue
      for var in ${CAT_MONGO[$svc]:-}; do
        uri="$(get_var "$f" "$var")"
        [ -n "$uri" ] || continue
        read -r h p <<< "$(dr_mongo_hostport "$uri")"
        case " $seen " in *" $h:$p "*) continue ;; esac
        seen+=" $h:$p"
        if [ "$p" = srv ]; then
          pr_res info "$(t doctor.mongo_srv "$h")"   # a DNS name that resolves to the real servers: there is no port to try
        elif [ "$h" = "host.docker.internal" ]; then
          # That is how containers get there: to Docker's gateway, not to the server's 127.0.0.1.
          if [ -z "$gw" ]; then
            pr_res info "$(t doctor.mongo_gw_unknown "$h:$p")"
          elif dr_tcp "$gw" "$p"; then
            pr_res ok "$(t doctor.mongo_via_gw "$h:$p" "$gw")"
          else
            pr_res err "$(t doctor.mongo_gw_fail "$h:$p" "$gw" "$p")" "$(t doctor.mongo_gw_fail_hint "$gw")"
          fi
        elif dr_tcp "$h" "$p"; then
          pr_res ok "$(t doctor.mongo_reach "$h:$p")"
        else
          pr_res err "$(t doctor.mongo_noresp "$h:$p")" "$(t doctor.mongo_noresp_hint "$(basename "$(dirname "$f")")/$(basename "$f")")"
        fi
      done
    done
  done
  [ -n "$seen" ] || pr_res info "$(t doctor.mongo_none)"
}

prereq_check_nofile() {
  local pid lim
  pid="$(pgrep -x mongod 2> /dev/null | head -n1 || true)"
  if [ -n "$pid" ] && [ -r "/proc/$pid/limits" ]; then
    lim="$(awk '/^Max open files/ { print $4 }' "/proc/$pid/limits")"
    if [[ "$lim" =~ ^[0-9]+$ ]] && [ "$lim" -lt 64000 ]; then
      pr_res warn "$(t doctor.nofile_warn "$lim")" "$(t doctor.nofile_warn_hint)"
    elif [[ "$lim" =~ ^[0-9]+$ ]]; then
      pr_res ok "$(t doctor.nofile_ok "$lim")"
    else
      pr_res info "$(t doctor.nofile_unknown)" "$(t doctor.nofile_unknown_hint "$(topic_label troubleshooting)")"
    fi
  else
    pr_res info "$(t doctor.nofile_unknown)" "$(t doctor.nofile_unknown_hint "$(topic_label troubleshooting)")"
  fi
}

prereq_check_tool() { # program (ss | openssl | gunzip)
  if host_has "$1"; then
    pr_res ok "$(t doctor.tool_ok "$1")"
  else
    pr_res warn "$(t "doctor.tool_missing.$1")" "$(t "doctor.tool_missing_hint.$1")"
  fi
}
prereq_check_ss() { prereq_check_tool ss; }
prereq_check_openssl() { prereq_check_tool openssl; }
prereq_check_gunzip() { prereq_check_tool gunzip; }

# Recommended: nothing breaks without them, so a missing one is only information (it never counts as a warning or an error).
prereq_check_proxy() {
  local found=""
  pr_has nginx && found="nginx"
  pr_has caddy && found+="${found:+, }Caddy"
  if [ -n "$found" ]; then
    pr_res ok "$(t prereq.proxy_ok "$found")"
  else
    pr_res info "$(t prereq.proxy_none)" "$(t prereq.proxy_none_hint)"
  fi
}

prereq_check_certbot() {
  if pr_has certbot; then pr_res ok "$(t doctor.tool_ok certbot)"; else pr_res info "$(t prereq.certbot_none)" "$(t prereq.certbot_none_hint)"; fi
}

prereq_check_curl() {
  if host_has curl; then pr_res ok "$(t doctor.tool_ok curl)"; else pr_res info "$(t prereq.curl_none)" "$(t prereq.curl_none_hint)"; fi
}

prereq_check_timesync() {
  local v
  if host_has timedatectl; then
    v="$(timedatectl show -p NTPSynchronized --value 2> /dev/null || true)"
    case "$v" in
      yes) pr_res ok "$(t prereq.time_ok)" ;;
      no) pr_res info "$(t prereq.time_off)" "$(t prereq.time_off_hint)" ;;
      *) pr_res info "$(t prereq.time_unknown)" ;;
    esac
  else
    pr_res info "$(t prereq.time_unknown)"
  fi
}

prereq_check_firewall() {
  local f active=""
  if host_has systemctl; then
    for f in ufw firewalld nftables; do
      if systemctl is-active --quiet "$f" 2> /dev/null; then active="$f"; break; fi
    done
  else
    pr_res info "$(t prereq.fw_unknown)"
    return 0
  fi
  if [ -n "$active" ]; then
    pr_res ok "$(t prereq.fw_ok "$active")"
  else
    pr_res info "$(t prereq.fw_none)" "$(t prereq.fw_none_hint)"
  fi
}

# --- Running ------------------------------------------------------------------------------------------------
declare -gA PR_STATUS=() PR_SUMMARY=() PR_RECORDS=()   # worst state, first message and every result of each requirement
PR_RS=$'\x1e' PR_FS=$'\x1f'                            # separators of PR_RECORDS

# Runs the check of one requirement and leaves its results in PR_RES_* and its summary in PR_STATUS / PR_SUMMARY / PR_RECORDS.
prereq_run() { # id
  local id="$1" i worst=ok st rec="" first=""
  PR_RES_ST=() PR_RES_MSG=() PR_RES_HINT=() PR_RES_QUIET=()
  "prereq_check_$id"
  for i in "${!PR_RES_ST[@]}"; do
    st="${PR_RES_ST[$i]}"
    case "$st" in
      err) worst=err ;;
      warn) [ "$worst" = err ] || worst=warn ;;
      info) { [ "$worst" = err ] || [ "$worst" = warn ]; } || worst=info ;;
      na) [ "$worst" != ok ] || worst=na ;;
    esac
    [ -n "$first" ] || first="${PR_RES_MSG[$i]}"
    rec+="${rec:+$PR_RS}$st$PR_FS${PR_RES_MSG[$i]}$PR_FS${PR_RES_HINT[$i]//$'\n'/ / }"
  done
  PR_STATUS[$id]="$worst" PR_SUMMARY[$id]="$first" PR_RECORDS[$id]="$rec"
}

# Runs every requirement (or only those of one section) and counts: PR_N_ERR, PR_N_WARN.
PR_N_ERR=0 PR_N_WARN=0
prereq_run_all() { # [section]
  local id st
  prereq_reset
  DK_TIMEOUT="${PR_DOCKER_TIMEOUT:-10}"   # a docker that does not answer is a failed check, not a check that never ends
  PR_N_ERR=0 PR_N_WARN=0
  for id in "${PR_IDS[@]}"; do
    [ -z "${1:-}" ] || [ "${PR_SECTION[$id]}" = "$1" ] || continue
    prereq_run "$id"
    for st in "${PR_RES_ST[@]}"; do
      case "$st" in err) PR_N_ERR=$((PR_N_ERR + 1)) ;; warn) PR_N_WARN=$((PR_N_WARN + 1)) ;; esac
    done
  done
}

# Name and purpose of a requirement, in the UI language.
prereq_name() { t "prereq.name.$1"; }
prereq_why() { t "prereq.why.$1"; }

# JSON report of every requirement: the server (distribution and package manager), the totals and one object per requirement with
# what it is for and the command to install it (strings are escaped). prereq_run_all must have run.
prereq_json() {
  local id first=1 cmd url res rec r f st msg
  local -a recs
  printf '{"distro":{"id":"%s","name":"%s","manager":"%s"},' \
    "$(ui_json_escape "$PR_DISTRO_ID")" "$(ui_json_escape "$PR_DISTRO_NAME")" "$(ui_json_escape "$PR_MANAGER")"
  printf '"summary":{"errors":%s,"warnings":%s,"ok":%s},"prerequisites":[' "$PR_N_ERR" "$PR_N_WARN" \
    "$([ "$PR_N_ERR" -eq 0 ] && echo true || echo false)"
  for id in "${PR_IDS[@]}"; do
    cmd="" url=""
    if prereq_install_r "$id"; then cmd="$PR_INSTALL"; fi
    url="${PR_URL[$id]:-}"
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"id":"%s","name":"%s","level":"%s","status":"%s","summary":"%s","why":"%s","install":"%s","url":"%s","results":[' \
      "$id" "$(ui_json_escape "$(prereq_name "$id")")" "${PR_LEVEL[$id]}" "${PR_STATUS[$id]}" "$(ui_json_escape "${PR_SUMMARY[$id]}")" \
      "$(ui_json_escape "$(prereq_why "$id")")" "$(ui_json_escape "$cmd")" "$(ui_json_escape "$url")"
    rec="${PR_RECORDS[$id]}"
    r=0
    IFS="$PR_RS" read -ra recs <<< "$rec"
    for res in ${recs[@]+"${recs[@]}"}; do
      [ -n "$res" ] || continue
      IFS="$PR_FS" read -r st msg f <<< "$res"
      [ "$r" -eq 0 ] || printf ','
      r=1
      printf '{"status":"%s","message":"%s"}' "$st" "$(ui_json_escape "$msg")"
    done
    printf ']}'
  done
  printf ']}\n'
}

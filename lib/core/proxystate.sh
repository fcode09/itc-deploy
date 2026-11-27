#!/usr/bin/env bash
# shellcheck disable=SC2034  # PSTATE_* are read by lib/cmd/access.sh and lib/screens/ws/acceso.sh
# What state the nginx block of a service of an instance is in: not installed, installed but not enabled, out of date, waiting for a reload,
# serving. Read only: it needs no root and writes nothing. Sourced by lib/bootstrap.sh after lib/core/proxy.sh.
#
# For one service, in this order (the first that applies is the state):
#   none       there is no file for it in /etc/nginx (sites-available/<instance>-<service>, or conf.d/<instance>-<service>.conf)
#   disabled   the file is there but its link in sites-enabled/ is not (layout sites)
#   nocert     the block is HTTPS and the certificate of its name is not there (nginx would refuse to load it)
#   stale      the file is not what `access` would write now (the domain, a name, the port, the HTTPS answer or the template changed)
#   down       nginx is not running
#   reload     the file (or its link) is newer than the last time nginx loaded its configuration: a reload is missing
#   active     it is installed, enabled, up to date and loaded
#   installed  all of the above but it cannot be told whether nginx loaded it (no `ps`, or no pid)
#   unknown    there is nothing to compare with (no domain, no valid port) or the proxy is not nginx
#
# "Loaded" is deduced, not read: nginx does not say when it read each file. A reload starts new worker processes, so the newest start of the
# workers is the last time the configuration was loaded; a file or a link modified after that is not loaded yet (two seconds of margin: the
# workers start a moment after the file is written). The test hooks: DELTACTL_NGINX_ROOT (the folder of nginx) and DELTACTL_NGINX_LOADED_AT
# (an epoch, or `down` / `unknown`), as proxy.sh has them.

PSTATE="unknown" PSTATE_FILE="" PSTATE_MISSING=""
PROXY_LOADED_AT=""

# When nginx loaded its configuration for the last time, into PROXY_LOADED_AT (epoch seconds).
# Returns 0 when it is known, 1 when nginx is not running, 2 when it cannot be told.
proxy_loaded_at_r() {
  local pidf pid k up now newest=0 kids
  PROXY_LOADED_AT=""
  case "${DELTACTL_NGINX_LOADED_AT:-}" in
    down) return 1 ;;
    unknown) return 2 ;;
    '' | *[!0-9]*) ;;
    *) PROXY_LOADED_AT="$DELTACTL_NGINX_LOADED_AT"; return 0 ;;
  esac
  pid=""
  for pidf in "${DELTACTL_NGINX_PID_FILE:-}" /run/nginx.pid /var/run/nginx.pid; do
    [ -n "$pidf" ] && [ -r "$pidf" ] || continue
    read -r pid < "$pidf" 2> /dev/null || pid=""
    [[ "$pid" =~ ^[0-9]+$ ]] && break
    pid=""
  done
  if [ -z "$pid" ] && command -v pgrep > /dev/null 2>&1; then pid="$(pgrep -o -x nginx 2> /dev/null || true)"; fi
  [ -n "$pid" ] || { command -v pgrep > /dev/null 2>&1 && return 1; return 2; }
  [ -d "/proc/$pid" ] || return 1
  command -v ps > /dev/null 2>&1 || return 2
  printf -v now '%(%s)T' -1
  kids="$(pgrep -P "$pid" 2> /dev/null || true)"
  [ -n "$kids" ] || kids="$pid"
  for k in $kids; do
    up="$(ps -o etimes= -p "$k" 2> /dev/null | tr -d ' ')"
    [[ "$up" =~ ^[0-9]+$ ]] || continue
    [ $((now - up)) -le "$newest" ] || newest=$((now - up))
  done
  [ "$newest" -gt 0 ] || return 2
  PROXY_LOADED_AT="$newest"
  return 0
}

# The state of the block of one service into PSTATE (and the file in PSTATE_FILE, the hosts without a certificate in PSTATE_MISSING).
# The caller has set PROXY_WWW and PROXY_HOSTS as it does before proxy_render, because the block is rendered here to compare it.
proxy_block_state_r() { # instance service tls entry      (entry: <host>|<port>|<service>)
  local name="$1" svc="$2" tls="$3" e="$4" f l host cur mt lt newest rc
  PSTATE="unknown" PSTATE_FILE="" PSTATE_MISSING=""
  [ -n "$e" ] || return 0
  proxy_nginx_layout
  f="$(proxy_conf_file "$name" "$svc")"
  PSTATE_FILE="$f"
  [ -f "$f" ] || { PSTATE="none"; return 0; }
  if [ "$PROXY_LAYOUT" = sites ]; then
    l="$(proxy_conf_link "$name" "$svc")"
    [ -e "$l" ] || { PSTATE="disabled"; return 0; }
  fi
  host="${e%%|*}"
  if [ "$tls" -eq 1 ]; then
    proxy_certs_missing "$host" || { PSTATE="nocert"; PSTATE_MISSING="$PROXY_MISSING"; return 0; }
  fi
  if proxy_render nginx "$tls" "$e"; then
    IFS= read -r -d '' cur < "$f" || true   # (the whole file, line breaks included: it is compared byte for byte)
    [ "$cur" = "$PROXY_OUT" ] || { PSTATE="stale"; return 0; }
  else
    return 0
  fi
  rc=0
  proxy_loaded_at_r || rc=$?
  case "$rc" in
    1) PSTATE="down"; return 0 ;;
    2) PSTATE="installed"; return 0 ;;
  esac
  mt="$(stat -c %Y "$f" 2> /dev/null || echo 0)"
  newest="$mt"
  if [ "$PROXY_LAYOUT" = sites ]; then
    lt="$(stat -c %Y "$l" 2> /dev/null || echo 0)"
    [ "$lt" -le "$newest" ] || newest="$lt"
  fi
  if [ "$newest" -gt $((PROXY_LOADED_AT + 2)) ]; then PSTATE="reload"; else PSTATE="active"; fi
  return 0
}

# What to do about a state, as the command: into PSTATE_NEXT ("" when nothing). $1 instance, $2 service, $3 the host, $4 the missing hosts.
PSTATE_NEXT=""
proxy_state_next_r() { # state instance service host
  local su="sudo "
  [ "$(host_uid 2> /dev/null)" != 0 ] || su=""
  PSTATE_NEXT=""
  case "$1" in
    none | disabled | stale) PSTATE_NEXT="./deltactl access $2 --apply --service $3" ;;
    nocert) PSTATE_NEXT="${su}certbot certonly --nginx -d $4" ;;
    down) PSTATE_NEXT="${su}systemctl start nginx" ;;
    reload) PSTATE_NEXT="${su}nginx -t && ${su}systemctl reload nginx" ;;
  esac
}

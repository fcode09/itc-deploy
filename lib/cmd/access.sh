#!/usr/bin/env bash
# shellcheck disable=SC2034  # PROXY_HOSTS and PROXY_WWW are read by lib/core/proxy.sh
# ./deltactl access <instance> [--domain D] [--host sN=NAME]... [--www | --no-www] [--tls | --no-tls] [--proxy nginx|caddy] [--save]
# How an instance is reached from outside: the reverse-proxy block of each of its services (nginx or Caddy), made from the templates of
# templates/nginx/ (one per service: s0 and s1 have their own), with the name each service answers to and its port in .env.instance. Without
# --save it only shows the block; with --save it writes it inside the instance (instances/<name>/proxy/) and remembers the answers there
# (access.conf), and says what to run to put it where nginx reads it. It never writes under /etc and never reloads anything: those are
# the person's commands. The panel's Access tab (lib/screens/ws/acceso.sh) reads and writes the same files.

access_usage() { die "$(t access.usage)"; }

cmd_access() {
  local name="" dom="" flavor="" tls="" www="" save=0 a spec s h e host port label first=1
  local -a act=() hostspec=()
  while [ "$#" -gt 0 ]; do
    a="$1"
    case "$a" in
      --domain) [ "$#" -ge 2 ] || die "$(t new.opt_value "$a")"; dom="${2,,}"; shift 2 ;;
      --host) [ "$#" -ge 2 ] || die "$(t new.opt_value "$a")"; hostspec+=("$2"); shift 2 ;;
      --www) www=1; shift ;;
      --no-www) www=0; shift ;;
      --tls) tls=1; shift ;;
      --no-tls) tls=0; shift ;;
      --proxy) [ "$#" -ge 2 ] || die "$(t new.opt_value "$a")"; case "$2" in nginx | caddy) flavor="$2" ;; *) die "$(t access.proxy_opt "$2")" ;; esac; shift 2 ;;
      --save) save=1; shift ;;
      -*) die "$(t new.unknown_option "$a")" ;;
      *) [ -z "$name" ] || access_usage; name="$a"; shift ;;
    esac
  done
  [ -n "$name" ] || access_usage
  valid_instance_name "$name" && [ -d "$INSTANCES_DIR/$name" ] || die "$(t access.no_instance "$name")"
  svc_active_r "$name"
  act=("${SVC_ACTIVE[@]}")
  [ "${#act[@]}" -gt 0 ] || die "$(t access.no_services "$name")"

  # What the instance remembered, then what the options say over it.
  proxy_meta_load "$name"
  proxy_use_meta
  [ -n "$dom" ] || dom="$PROXY_M_DOMAIN"
  [ -n "$flavor" ] || flavor="${PROXY_M_FLAVOR:-nginx}"
  [ -n "$tls" ] || tls="$PROXY_M_TLS"
  [ -z "$www" ] || PROXY_WWW="$www"
  for spec in "${hostspec[@]}"; do
    s="${spec%%=*}" h="${spec#*=}"
    [[ "$spec" == *=* ]] || die "$(t access.bad_spec "$spec")"
    valid_service "$s" && [[ " ${act[*]} " == *" $s "* ]] || die "$(t access.bad_service "$s" "$name" "${act[*]}")"
    if [ -z "$h" ]; then unset "PROXY_HOSTS[$s]"; continue; fi
    proxy_host_ok "${h,,}" || die "$(t access.bad_host "$h")"
    PROXY_HOSTS[$s]="${h,,}"
  done
  [ -n "$dom" ] || die "$(t access.no_domain)"
  proxy_host_ok "$dom" || die "$(t new.domain_invalid "$dom")"

  proxy_instance_ports "$name" "${act[@]}"
  for s in "${act[@]}"; do proxy_port_ok "${PROXY_PORTS[$s]:-}" || die "$(t access.bad_port "$s" "$name")"; done
  proxy_domain_names "$dom" "${act[@]}" || die "$(t new.domain_invalid "$dom")"
  proxy_render "$flavor" "$tls" "${PROXY_ENTRIES[@]}" || die "$(t new.proxy_render "$flavor" "$PROXY_ERR")"

  info "$(t access.table_title "$name")"
  for e in "${PROXY_ENTRIES[@]}"; do
    host="${e%%|*}" port="${e#*|}" label="${port#*|}" port="${port%%|*}"
    proxy_names "$host"
    info "  $label  $PROXY_NAMES  ->  127.0.0.1:$port"
  done
  printf '\n%s' "$PROXY_OUT"

  if [ "$save" -eq 0 ]; then
    printf '\n'
    info "$(t access.hint_save "$name")"
    return 0
  fi
  local rc=0
  proxy_save "$name" "$flavor" || rc=$?
  [ "$rc" -eq 0 ] || die "$(t new.proxy_write "$flavor")"
  proxy_meta_save "$name" "$dom" "$flavor" "$tls" || die "$(t new.proxy_write "$flavor")"
  printf '\n'
  ok "$(t access.saved "$INSTANCES_DIR/$name/proxy/$(proxy_file "$flavor")")"
  info "$(t access.install_title)"
  if [ "$flavor" = nginx ]; then
    info "  sudo cp $INSTANCES_DIR/$name/proxy/nginx.conf /etc/nginx/conf.d/$name.conf"
    if [ "$tls" -eq 1 ]; then
      for e in "${PROXY_ENTRIES[@]}"; do
        host="${e%%|*}"; proxy_names "$host"
        [ "$first" -eq 1 ] && { info "  # $(t access.tls_first)"; first=0; }
        info "  sudo certbot certonly --nginx $PROXY_CERT_ARGS"
      done
    fi
    info "  sudo nginx -t && sudo systemctl reload nginx"
  else
    info "  # $(t access.caddy_where "$INSTANCES_DIR/$name/proxy/Caddyfile")"
    info "  sudo caddy reload --config /etc/caddy/Caddyfile"
  fi
}

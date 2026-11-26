#!/usr/bin/env bash
# shellcheck disable=SC2034  # PROXY_HOSTS and PROXY_WWW are read by lib/core/proxy.sh
# ./deltactl access <instance> [--domain D] [--host sN=NAME]... [--www | --no-www] [--tls | --no-tls] [--proxy nginx|caddy] [--save]
# How an instance is reached from outside: the reverse-proxy block of each of its services (nginx or Caddy), made from the templates of
# templates/nginx/ (one per service: s0 and s1 have their own), with the name each service answers to and its port in .env.instance. Without
# --save it only shows the block; with --save it writes it inside the instance (instances/<name>/proxy/) and remembers the answers there
# (access.conf), and says what to run to put it where nginx reads it. It never writes under /etc and never reloads anything: those are
# the person's commands. The panel's Access tab (lib/screens/ws/acceso.sh) reads and writes the same files.

access_usage() { die "$(t access.usage)"; }

# --apply: the block of each service asked for goes to /etc/nginx/conf.d (one file per service), nginx tests it and is reloaded; with a test that fails
# everything is put back as it was and nothing is reloaded. The certificates of HTTPS must be there already (the block of 443 would not load without).
# It asks first (--yes skips it) and needs root: it changes /etc and reloads a service.
access_apply() { # instance flavor tls svc...
  local name="$1" flavor="$2" tls="$3" e svc host rc=0 shown
  local -a entries=() hosts=()
  shift 3
  [ "$flavor" = nginx ] || die "$(t access.apply_caddy)"
  command -v nginx > /dev/null 2>&1 || die "$(t access.apply_no_nginx)"
  if [ "$(host_uid)" != 0 ] && [ "${DELTACTL_TEST_ISOLATED:-0}" != 1 ]; then die "$(t access.apply_need_root)"; fi
  for e in "${PROXY_ENTRIES[@]}"; do
    svc="${e##*|}"
    case " $* " in *" $svc "*) entries+=("$e"); hosts+=("${e%%|*}") ;; esac
  done
  if [ "$tls" -eq 1 ] && ! proxy_certs_missing "${hosts[@]}"; then
    warn "$(t access.apply_certs "$PROXY_MISSING")"
    for host in $PROXY_MISSING; do proxy_names "$host"; info "  certbot certonly --nginx $PROXY_CERT_ARGS"; done
    die "$(t access.apply_certs_hint "$name")"
  fi
  shown="$*"
  confirm "$(t access.apply_confirm "$name" "$shown")" || die "$(t err.cancelled)"
  proxy_apply_nginx "$name" "$tls" "${entries[@]}" || rc=$?
  case "$rc" in
    0) ;;
    1) printf '%s\n' "$PROXY_ERR" | head -5 >&2; die "$(t access.apply_test_failed)" ;;
    *) die "$(t access.apply_write_failed "$(proxy_conf_dir)")" ;;
  esac
  proxy_reload || die "$(t access.apply_reload_failed)"
  ok "$(t access.applied "${PROXY_APPLIED[*]}")"
  info "$(t access.apply_reloaded)"
}

# --remove: takes the files of those services out of nginx's folder (kept as <file>.deltactl-removed), tests, reloads; a test that fails puts them back.
access_remove() { # instance svc...
  local name="$1" rc=0
  shift
  command -v nginx > /dev/null 2>&1 || die "$(t access.apply_no_nginx)"
  if [ "$(host_uid)" != 0 ] && [ "${DELTACTL_TEST_ISOLATED:-0}" != 1 ]; then die "$(t access.apply_need_root)"; fi
  confirm "$(t access.remove_confirm "$name" "$*")" || die "$(t err.cancelled)"
  proxy_remove_nginx "$name" "$@" || rc=$?
  case "$rc" in
    0) ;;
    1) printf '%s\n' "$PROXY_ERR" | head -5 >&2; die "$(t access.apply_test_failed)" ;;
    3) info "$(t access.remove_none "$name")"; return 0 ;;
    *) die "$(t access.apply_write_failed "$(proxy_conf_dir)")" ;;
  esac
  proxy_reload || die "$(t access.apply_reload_failed)"
  ok "$(t access.removed "${PROXY_APPLIED[*]}")"
}

cmd_access() {
  local name="" dom="" flavor="" tls="" www="" save=0 a spec s h e host port label first=1 apply=0 remove=0 only=""
  local -a act=() hostspec=() sel=() hosts=()
  ASSUME_YES=0
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
      --apply) apply=1; shift ;;
      --remove) remove=1; shift ;;
      --service) [ "$#" -ge 2 ] || die "$(t new.opt_value "$a")"; only="$2"; shift 2 ;;
      --yes | -y) ASSUME_YES=1; shift ;;
      -*) die "$(t new.unknown_option "$a")" ;;
      *) [ -z "$name" ] || access_usage; name="$a"; shift ;;
    esac
  done
  [ -n "$name" ] || access_usage
  valid_instance_name "$name" && [ -d "$INSTANCES_DIR/$name" ] || die "$(t access.no_instance "$name")"
  svc_active_r "$name"
  act=("${SVC_ACTIVE[@]}")
  [ "${#act[@]}" -gt 0 ] || die "$(t access.no_services "$name")"
  if [ -n "$only" ]; then
    valid_service "$only" && [[ " ${act[*]} " == *" $only "* ]] || die "$(t access.bad_service "$only" "$name" "${act[*]}")"
    sel=("$only")
  else
    sel=("${act[@]}")
  fi
  [ "$apply" -eq 0 ] || [ "$remove" -eq 0 ] || access_usage
  if [ "$remove" -eq 1 ]; then access_remove "$name" "${sel[@]}"; return; fi

  # What the instance remembered, then what the options say over it.
  proxy_meta_load "$name"
  proxy_use_meta
  [ -n "$dom" ] || dom="$PROXY_M_DOMAIN"
  [ -n "$flavor" ] || flavor="${PROXY_M_FLAVOR:-nginx}"
  [ -n "$tls" ] || tls="$PROXY_M_TLS"
  # (checked before anything is saved: a refused --apply must not leave another proxy remembered)
  [ "$apply" -eq 0 ] || [ "$flavor" = nginx ] || die "$(t access.apply_caddy)"
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

  [ "$apply" -eq 0 ] || save=1   # (putting it in nginx saves it in the instance first)
  if [ "$save" -eq 0 ]; then
    printf '\n'
    info "$(t access.hint_save "$name")"
    return 0
  fi
  local rc=0 su="sudo "
  [ "$(host_uid)" != 0 ] || su=""   # (root needs no sudo: the commands are shown as they are typed)
  proxy_save "$name" "$flavor" || rc=$?
  [ "$rc" -eq 0 ] || die "$(t new.proxy_write "$flavor")"
  proxy_meta_save "$name" "$dom" "$flavor" "$tls" || die "$(t new.proxy_write "$flavor")"
  printf '\n'
  ok "$(t access.saved "$INSTANCES_DIR/$name/proxy/$(proxy_file "$flavor")")"
  if [ "$apply" -eq 1 ]; then access_apply "$name" "$flavor" "$tls" "${sel[@]}"; return; fi
  info "$(t access.install_title)"
  if [ "$flavor" = nginx ]; then
    info "  ${su}cp $INSTANCES_DIR/$name/proxy/nginx.conf /etc/nginx/conf.d/$name.conf"
    if [ "$tls" -eq 1 ]; then
      for e in "${PROXY_ENTRIES[@]}"; do
        host="${e%%|*}"; proxy_names "$host"
        [ "$first" -eq 1 ] && { info "  # $(t access.tls_first)"; first=0; }
        info "  ${su}certbot certonly --nginx $PROXY_CERT_ARGS"
      done
    fi
    info "  ${su}nginx -t && ${su}systemctl reload nginx"
  else
    info "  # $(t access.caddy_where "$INSTANCES_DIR/$name/proxy/Caddyfile")"
    info "  ${su}caddy reload --config /etc/caddy/Caddyfile"
  fi
}

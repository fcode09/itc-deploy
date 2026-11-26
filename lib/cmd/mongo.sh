#!/usr/bin/env bash
# ./deltactl mongo setup [--apply] [--yes]
# Makes the MongoDB of THIS server reachable from the containers (the doctor's "MongoDB alcanzable"). Containers get to the host through the gateway
# of Docker's bridge (host.docker.internal is that address), and a mongod that listens only on 127.0.0.1, or a firewall that closes the port, refuses
# them. Three things can be missing and each one is looked at, never assumed:
#   1. bindIp of mongod.conf has to include the gateway (it is read from Docker: it is 172.17.0.1 only by default),
#   2. mongod has to start AFTER Docker (the gateway address does not exist before dockerd creates the bridge): a systemd drop-in,
#   3. ufw (when it is active) has to let the containers' networks reach the port of Mongo, and only them.
# Without --apply it only SHOWS what would change (the diff of mongod.conf, the drop-in, the rule). With --apply it asks first (--yes skips it), needs
# root, keeps a copy of mongod.conf, restarts mongod and tests the connection from the outside again; a mongod.conf it does not recognise is not
# touched (it says which line to write). It never turns authentication on: that comes after the users exist (docs/panel.md).
# Files and commands can be redirected for the tests: DELTACTL_MONGOD_CONF, DELTACTL_SYSTEMD_DIR, and ufw / systemctl found in PATH.

MG_CONF="" MG_GW="" MG_PORT=27017 MG_SRC="" MG_BIND="" MG_NEWCONF="" MG_DROPIN="" MG_DROPIN_OK=0 MG_UFW_RULE="" MG_NEED=0

mongo_usage() { die "$(t mongo.usage)"; }

# The networks of the containers that the firewall rule opens: the 172.16.0.0/12 block of Docker when the gateway is in it (the bridge and the
# network of every instance), the /16 of the gateway otherwise (a pool that was changed by hand).
mongo_source_net() { # gateway
  local o1 o2
  IFS=. read -r o1 o2 _ <<< "$1"
  if [ "$o1" = 172 ] && [ "$o2" -ge 16 ] && [ "$o2" -le 31 ]; then MG_SRC="172.16.0.0/12"; else MG_SRC="$o1.$o2.0.0/16"; fi
}

# The value of bindIp in the text of mongod.conf, into MG_BIND ("" when the line is not there). Returns 1 when the file has no `net:` section to
# put it in (a format that is not the usual one).
mongo_read_bind() { # file
  local line in_net=0 found=0
  MG_BIND=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^net:[[:space:]]*$ ]]; then in_net=1 found=1; continue; fi
    if [ "$in_net" -eq 1 ] && [[ "$line" =~ ^[^[:space:]#] ]]; then in_net=0; fi
    if [ "$in_net" -eq 1 ] && [[ "$line" =~ ^[[:space:]]+bindIp:[[:space:]]*([^#]*[^#[:space:]]) ]]; then MG_BIND="${BASH_REMATCH[1]}"; fi
    if [ "$in_net" -eq 1 ] && [[ "$line" =~ ^[[:space:]]+bindIpAll:[[:space:]]*true ]]; then MG_BIND="0.0.0.0"; fi
    [[ "$line" =~ ^net: ]] && found=1
  done < "$1"
  [ "$found" -eq 1 ]
}

# Does the bindIp already let the gateway in?
mongo_bind_ok() { # value gateway
  case ",${1// /}," in *",0.0.0.0,"* | *",$2,"* | *",::,"*) return 0 ;; esac
  return 1
}

# Writes the new text of mongod.conf into MG_NEWCONF: bindIp with the gateway added (or the line put in the net: section when it is not there).
mongo_new_conf() { # file gateway
  local line in_net=0 done_line=0 out="" cur
  while IFS= read -r line || [ -n "$line" ]; do
    cur="${line%$'\r'}"
    if [ "$in_net" -eq 1 ] && [[ "$cur" =~ ^[^[:space:]#] ]]; then in_net=0; fi
    if [[ "$cur" =~ ^net:[[:space:]]*$ ]]; then
      in_net=1
      out+="$line"$'\n'
      if [ -z "$MG_BIND" ]; then out+="  bindIp: 127.0.0.1,$2"$'\n'; done_line=1; fi
      continue
    fi
    if [ "$in_net" -eq 1 ] && [ "$done_line" -eq 0 ] && [[ "$cur" =~ ^([[:space:]]+bindIp:[[:space:]]*)([^#]*[^#[:space:]])(.*)$ ]]; then
      out+="${BASH_REMATCH[1]}${BASH_REMATCH[2]},$2${BASH_REMATCH[3]}"$'\n'
      done_line=1
      continue
    fi
    out+="$line"$'\n'
  done < "$1"
  MG_NEWCONF="$out"
  [ "$done_line" -eq 1 ]
}

# What ufw says, in English whatever the language of the server (it translates "Status: active" and the words of its table).
mongo_ufw_status() { LC_ALL=C ufw status 2> /dev/null; }

# Is the rule of the firewall there already? (ufw writes "27017/tcp  ALLOW  172.16.0.0/12")
mongo_ufw_has() { # source port
  mongo_ufw_status | grep -E "^$2(/tcp)?[[:space:]]+ALLOW" | grep -qF "$1"
}

mongo_plan() { # gateway
  local gw="$1" cur tmp dir
  MG_NEED=0 MG_UFW_RULE="" MG_DROPIN="" MG_DROPIN_OK=0
  MG_CONF="${DELTACTL_MONGOD_CONF:-/etc/mongod.conf}"
  dir="${DELTACTL_SYSTEMD_DIR:-/etc/systemd/system}/mongod.service.d"
  mongo_source_net "$gw"

  info "$(t mongo.found_gw "$gw")"
  # 1. mongod.conf
  if [ ! -r "$MG_CONF" ]; then
    warn "$(t mongo.no_conf "$MG_CONF")"
  elif ! mongo_read_bind "$MG_CONF"; then
    warn "$(t mongo.conf_unknown "$MG_CONF" "$gw")"
  elif mongo_bind_ok "${MG_BIND:-127.0.0.1}" "$gw"; then
    ok "$(t mongo.bind_ok "${MG_BIND:-}")"
  elif ! mongo_new_conf "$MG_CONF" "$gw"; then
    warn "$(t mongo.conf_unknown "$MG_CONF" "$gw")"
  else
    cur="${MG_BIND:-127.0.0.1}"
    info "$(t mongo.bind_change "$MG_CONF" "$cur" "$cur,$gw")"
    MG_NEED=1
    tmp="$(mktemp)"; printf '%s' "$MG_NEWCONF" > "$tmp"
    diff -u "$MG_CONF" "$tmp" | sed '1,2d; s/^/    /' || true
    rm -f "$tmp"
  fi
  # 2. start after Docker: only when mongod listens on the gateway's address (0.0.0.0 does not depend on it) and systemd runs it
  if { [ "$MG_NEED" -eq 1 ] || mongo_bind_ok "${MG_BIND:-}" "$gw"; } && ! mongo_bind_ok "${MG_BIND:-}" 0.0.0.0; then
    if command -v systemctl > /dev/null 2>&1 || [ -n "${DELTACTL_SYSTEMD_DIR:-}" ]; then
      MG_DROPIN="$dir/deltactl-after-docker.conf"
      if [ -f "$MG_DROPIN" ]; then ok "$(t mongo.dropin_ok "$MG_DROPIN")"; MG_DROPIN_OK=1
      else info "$(t mongo.dropin_new "$MG_DROPIN")"; MG_NEED=1; fi
    fi
  fi
  # 3. the firewall
  if command -v ufw > /dev/null 2>&1 && [ -z "$(mongo_ufw_status)" ]; then
    info "$(t mongo.ufw_unknown)"   # (ufw answers only to root)
  elif command -v ufw > /dev/null 2>&1 && mongo_ufw_status | grep -qi "^Status: active"; then
    if mongo_ufw_has "$MG_SRC" "$MG_PORT"; then ok "$(t mongo.ufw_ok "$MG_SRC" "$MG_PORT")"
    else MG_UFW_RULE="ufw allow from $MG_SRC to any port $MG_PORT proto tcp"; info "$(t mongo.ufw_new "$MG_UFW_RULE")"; MG_NEED=1; fi
  else
    info "$(t mongo.ufw_none)"
  fi
}

mongo_apply() { # gateway
  local gw="$1" stamp
  if [ "$(id -u)" -ne 0 ] && [ "${DELTACTL_TEST_ISOLATED:-0}" != 1 ]; then die "$(t mongo.need_root)"; fi
  confirm "$(t mongo.confirm)" || die "$(t err.cancelled)"
  if [ -n "$MG_NEWCONF" ]; then
    stamp="$(date +%Y%m%d%H%M%S)"
    cp -p "$MG_CONF" "$MG_CONF.deltactl-$stamp.bak" || die "$(t mongo.write_failed "$MG_CONF")"
    printf '%s' "$MG_NEWCONF" > "$MG_CONF" || die "$(t mongo.write_failed "$MG_CONF")"
    mongo_read_bind "$MG_CONF" || true
    if ! mongo_bind_ok "$MG_BIND" "$gw"; then
      cp -p "$MG_CONF.deltactl-$stamp.bak" "$MG_CONF"
      die "$(t mongo.conf_check_failed "$MG_CONF")"
    fi
    ok "$(t mongo.conf_written "$MG_CONF" "$MG_CONF.deltactl-$stamp.bak")"
  fi
  if [ -n "$MG_DROPIN" ] && [ "$MG_DROPIN_OK" -eq 0 ]; then
    mkdir -p "$(dirname "$MG_DROPIN")" || die "$(t mongo.write_failed "$MG_DROPIN")"
    printf '[Unit]\nAfter=docker.service\nWants=docker.service\n' > "$MG_DROPIN" || die "$(t mongo.write_failed "$MG_DROPIN")"
    ok "$(t mongo.dropin_written "$MG_DROPIN")"
  fi
  if [ -n "$MG_UFW_RULE" ]; then
    # shellcheck disable=SC2086  # (the rule is a fixed list of words made here)
    ufw ${MG_UFW_RULE#ufw } > /dev/null 2>&1 || die "$(t mongo.ufw_failed "$MG_UFW_RULE")"
    ok "$(t mongo.ufw_added "$MG_SRC" "$MG_PORT")"
  fi
  if command -v systemctl > /dev/null 2>&1; then
    systemctl daemon-reload > /dev/null 2>&1 || true
    systemctl restart mongod > /dev/null 2>&1 || die "$(t mongo.restart_failed)"
    ok "$(t mongo.restarted)"
  fi
  if dr_tcp "$gw" "$MG_PORT"; then ok "$(t mongo.reach_ok "$gw" "$MG_PORT")"
  else warn "$(t mongo.reach_fail "$gw" "$MG_PORT")"; return 1; fi
}

cmd_mongo() {
  local sub="${1:-}" apply=0 a gw
  [ "$#" -eq 0 ] || shift
  [ "$sub" = setup ] || { [ -z "$sub" ] && mongo_usage; die "$(t mongo.unknown_sub "$sub")"; }
  ASSUME_YES=0
  for a in "$@"; do
    case "$a" in
      --apply) apply=1 ;;
      --yes | -y) ASSUME_YES=1 ;;
      *) die "$(t new.unknown_option "$a")" ;;
    esac
  done
  check_docker
  gw="$(dk_network_gateway)"; gw="${gw//[!0-9.]/}"
  [[ "$gw" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "$(t mongo.no_gw)"
  mongo_plan "$gw"
  if [ "$MG_NEED" -eq 0 ]; then ok "$(t mongo.nothing)"; info "$(t mongo.auth_note)"; return 0; fi
  if [ "$apply" -eq 0 ]; then info "$(t mongo.dry "$([ "$(host_uid)" = 0 ] || printf "sudo ")")"; info "$(t mongo.auth_note)"; return 0; fi
  mongo_apply "$gw"
  info "$(t mongo.auth_note)"
}

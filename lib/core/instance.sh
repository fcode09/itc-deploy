#!/usr/bin/env bash
# Rules about instances. Sourced by lib/bootstrap.sh.

valid_instance_name() { [[ "$1" =~ ^[a-z][a-z0-9-]{1,30}$ ]]; }

# Stops with a clear message unless $1 names an existing instance.
require_instance() {
  local name="${1:-}"
  [ -n "$name" ] || die "$(t err.instance_name_missing "${CMD:-$(t ph.command)}")"
  valid_instance_name "$name" \
    || die "$(t err.instance_name_invalid "$name")$(see new)"
  [ -f "$(instance_dir "$name")/.env.instance" ] \
    || die "$(t err.instance_not_found "$name")$(see new-instance)"
}

# Stops unless Docker and the compose plugin (v2.20 or newer, for `include`) are usable.
check_docker() {
  dk_installed || die "$(t err.docker_missing)"
  dk_daemon_ok || die "$(t err.docker_daemon)$(see troubleshooting)"
  dk_compose_ok || die "$(t err.compose_missing)$(see troubleshooting)"
  local v
  v="$(dk_compose_version)"
  if [ -n "$v" ] && [ "$(printf '%s\n%s\n' 2.20.0 "$v" | sort -V | head -n1)" != "2.20.0" ]; then
    die "$(t err.compose_old "$v")"
  fi
}

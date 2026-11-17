#!/usr/bin/env bash
# Rules about the host ports of the instances. Sourced by lib/bootstrap.sh.

# Next free S0 port: highest existing one + PORT_STEP (or BASE_PORT when there are no instances).
next_s0_port() {
  local max=$((BASE_PORT - PORT_STEP)) f p
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    p="$(get_var "$f" S0_PORT)"
    if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -gt "$max" ]; then max="$p"; fi
  done
  echo $((max + PORT_STEP))
}

# Name of the instance (other than $2) that already uses port $1, or empty.
port_owner() { # port excluded_instance
  local f n
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    n="$(basename "$(dirname "$f")")"
    [ "$n" = "${2:-}" ] && continue
    if [ "$(get_var "$f" S0_PORT)" = "$1" ] || [ "$(get_var "$f" S1_PORT)" = "$1" ]; then
      echo "$n"
      return 0
    fi
  done
}

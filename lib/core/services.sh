#!/usr/bin/env bash
# Rules about services and their images. Sourced by lib/bootstrap.sh.

# Default image name (without registry or tag) of each service.
default_repo() { # service
  case "$1" in
    s0) echo "auth-backend" ;;
    s1) echo "gueo-back-end" ;;
    *) return 1 ;;
  esac
}

# Image name of a service: <SN>_IMAGE from the instance's .env.instance, or the default.
# service_repo_r leaves it in SR without starting any process.
SR=""
service_repo_r() { # service [instance]
  local svc="$1" name="${2:-}" def
  SR=""
  case "$svc" in
    s0) def="auth-backend" ;;
    s1) def="gueo-back-end" ;;
    *) return 1 ;;
  esac
  GV=""
  [ -z "$name" ] || get_var_r "$INSTANCES_DIR/$name/.env.instance" "${svc^^}_IMAGE"
  SR="${GV:-$def}"
}
service_repo() { # service [instance]
  service_repo_r "$@" || return 1
  printf '%s' "$SR"
}

# Valid image name (no tag): lowercase letters, digits and separators . _ - ; / allowed for paths.
valid_image_name() { [[ "$1" =~ ^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*$ ]]; }

# Full image reference that Compose will use for a service of the instance.
service_image_ref() { # instance service
  dk_compose "$1" --profile "$2" config --images 2>/dev/null | head -n1
}

short_id() { local id="${1#sha256:}"; printf '%s' "${id:0:12}"; }

# Warns when an image is not of this server's architecture (it would not start).
warn_arch_mismatch() { # reference
  local img srv
  img="$(dk_image_arch "$1")"
  srv="$(server_arch)"
  if [ -n "$img" ] && [ -n "$srv" ] && [ "$img" != "$srv" ]; then
    warn "$(t warn.arch_mismatch "$1" "$img" "$srv")"
  fi
}

valid_service() { # service
  local s
  for s in "${KNOWN_SERVICES[@]}"; do [ "$s" = "$1" ] && return 0; done
  return 1
}

# Tag variable of a service: s1 -> S1_TAG
tag_var() { printf '%s_TAG' "${1^^}"; }

# Reads COMPOSE_PROFILES of the instance and leaves the active services in ENABLED.
ENABLED=()
load_enabled() { # instance
  ENABLED=()
  local raw part
  local -a parts
  raw="$(get_var "$(instance_dir "$1")/.env.instance" COMPOSE_PROFILES)"
  [ -n "$raw" ] || die "$(t err.profiles_empty)$(see services)"
  IFS=',' read -ra parts <<< "$raw"
  for part in "${parts[@]}"; do
    part="${part// /}"
    [ -n "$part" ] || continue
    valid_service "$part" \
      || die "$(t err.profiles_unknown "$part" "${KNOWN_SERVICES[*]}")$(see services)"
    ENABLED+=("$part")
  done
  [ "${#ENABLED[@]}" -gt 0 ] || die "$(t err.profiles_none)$(see services)"
}

# Leaves in SELECTED the services a command acts on: the given one, or all the active ones of the
# instance. A given service must be active in it.
SELECTED=()
select_services() { # instance [service]
  local name="$1" want="${2:-}" s found=0
  load_enabled "$name"
  if [ -z "$want" ]; then
    SELECTED=("${ENABLED[@]}")
    return 0
  fi
  valid_service "$want" || die "$(t err.service_unknown "$want" "${KNOWN_SERVICES[*]}")$(see services)"
  for s in "${ENABLED[@]}"; do [ "$s" = "$want" ] && found=1; done
  [ "$found" -eq 1 ] \
    || die "$(t err.service_inactive "$want" "$name" "$(IFS=,; echo "${ENABLED[*]}")")$(see services)"
  SELECTED=("$want")
}

#!/usr/bin/env bash
# shellcheck disable=SC2034  # SVC_* results are read by lib/cmd/service.sh, the panel and the tests
# The services of an INSTANCE: which ones it runs (COMPOSE_PROFILES of its .env.instance), and the operations that change that: add a service,
# remove one (its data stays) and change its version, port or memory limit. Sourced by lib/bootstrap.sh; the rules live here so the command
# (./deltactl service) and the panel (the Services tab) do the same thing.
#
# Nothing here starts a container: `add` leaves the instance ready to be filled in and deployed, `remove` only stops that service.
# Every file is written with set_var (atomic: a temporary file next to it and a rename), so a failure leaves the previous content.

SVC_MSG=""      # why an operation said no (a message key already resolved), for the caller to show

# The services the instance runs, in catalog order, into SVC_ACTIVE (it does not die: a broken COMPOSE_PROFILES is an empty list).
SVC_ACTIVE=()
svc_active_r() { # instance
  local raw part s
  SVC_ACTIVE=()
  get_var_r "$INSTANCES_DIR/$1/.env.instance" COMPOSE_PROFILES
  raw="${GV// /}"
  for s in "${KNOWN_SERVICES[@]}"; do
    for part in ${raw//,/ }; do [ "$part" != "$s" ] || { SVC_ACTIVE+=("$s"); break; }
  done; done
}

svc_is_active() { # instance service
  local s
  svc_active_r "$1"
  for s in "${SVC_ACTIVE[@]}"; do [ "$s" = "$2" ] && return 0; done
  return 1
}

# Writes COMPOSE_PROFILES from the services in the arguments, in catalog order.
svc_write_profiles() { # instance services...
  local name="$1" s w out=""
  shift
  for s in "${KNOWN_SERVICES[@]}"; do
    for w in "$@"; do [ "$w" != "$s" ] || { out+="${out:+,}$s"; break; }; done
  done
  set_var "$INSTANCES_DIR/$name/.env.instance" COMPOSE_PROFILES "$out"
}

# A port that is free for a new service of the instance: the instance's own block (its s0 port + the service's offset), moving on while another
# instance or another service of this one has it or something listens there. Result in SVC_PORT.
SVC_PORT=""
svc_free_port() { # instance service
  local name="$1" svc="$2" base p tries=0 other s taken
  get_var_r "$INSTANCES_DIR/$name/.env.instance" S0_PORT
  base="$GV"
  [[ "$base" =~ ^[0-9]+$ ]] || base="$(next_s0_port)"
  p=$((base + ${CAT_OFFSET[$svc]:-0}))
  while [ "$tries" -lt 60 ]; do
    taken=0
    other="$(port_owner "$p" "$name")"
    [ -z "$other" ] || taken=1
    for s in "${KNOWN_SERVICES[@]}"; do
      [ "$s" != "$svc" ] || continue
      get_var_r "$INSTANCES_DIR/$name/.env.instance" "${s^^}_PORT"
      [ "$GV" != "$p" ] || taken=1
    done
    if [ "$taken" -eq 0 ] && ! host_port_in_use "$p"; then SVC_PORT="$p"; return 0; fi
    p=$((p + 1)) tries=$((tries + 1))
  done
  return 1
}

# A port number the instance can use for a service: 1024-65535, not another instance's and not another service of this one.
# Returns 1 with the reason in SVC_MSG.
svc_port_ok() { # instance service port
  local name="$1" svc="$2" p="$3" owner s
  SVC_MSG=""
  if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "${#p}" -gt 5 ] || [ "$p" -lt 1024 ] || [ "$p" -gt 65535 ]; then SVC_MSG="$(t service.port_invalid "$p")"; return 1; fi
  owner="$(port_owner "$p" "$name")"
  if [ -n "$owner" ]; then SVC_MSG="$(t service.port_used "$p" "$owner")"; return 1; fi
  for s in "${KNOWN_SERVICES[@]}"; do
    [ "$s" != "$svc" ] || continue
    get_var_r "$INSTANCES_DIR/$name/.env.instance" "${s^^}_PORT"
    if [ "$GV" = "$p" ]; then SVC_MSG="$(t service.port_same "$p" "$s")"; return 1; fi
  done
  return 0
}

# The values a field of a service takes: tag (a Docker tag), image (the image name, no tag), port, memory (a number and m or g: 512m, 2g).
svc_value_ok() { # instance service field value
  SVC_MSG=""
  case "$3" in
    tag) [[ "$4" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || { SVC_MSG="$(t service.tag_invalid)"; return 1; } ;;
    image) valid_image_name "$4" || { SVC_MSG="$(t service.image_invalid "$4")"; return 1; } ;;
    port) svc_port_ok "$1" "$2" "$4" ;;
    memory) [[ "$4" =~ ^[1-9][0-9]{0,5}[mg]$ ]] || { SVC_MSG="$(t service.memory_invalid "$4")"; return 1; } ;;
    *) SVC_MSG="$(t service.field_unknown "$3")"; return 1 ;;
  esac
}

# The variable of .env.instance that holds a field of a service.
svc_field_var() { # service field
  case "$2" in
    tag) tag_var "$1" ;;
    image) printf '%s_IMAGE' "${1^^}" ;;
    port) printf '%s_PORT' "${1^^}" ;;
    memory) printf '%s_MEM_LIMIT' "${1^^}" ;;
  esac
}

# Changes the version, port or memory limit of an active service (the value is validated first).
svc_set() { # instance service field value
  local name="$1" svc="$2" field="$3" value="$4" f="$INSTANCES_DIR/$1/.env.instance"
  svc_value_ok "$name" "$svc" "$field" "$value" || return 1
  [ -w "$f" ] || { SVC_MSG="$(t service.not_writable "$f")"; return 1; }
  set_var "$f" "$(svc_field_var "$svc" "$field")" "$value" || { SVC_MSG="$(t service.not_writable "$f")"; return 1; }
}

# A value another file of the instance already has for a variable (the secrets that every service shares), into SVC_SHARED.
SVC_SHARED=""
svc_shared_value() { # instance variable except-service
  local s
  SVC_SHARED=""
  for s in "${KNOWN_SERVICES[@]}"; do
    [ "$s" != "$3" ] || continue
    [ -f "$INSTANCES_DIR/$1/.env.$s" ] || continue
    get_var_r "$INSTANCES_DIR/$1/.env.$s" "$2"
    if [ -n "$GV" ] && [[ "$GV" != *CAMBIAR* ]]; then SVC_SHARED="$GV"; return 0; fi
  done
  return 1
}

# Adds a service to an instance. Creates what it needs when it is missing and never overwrites what exists: .env.<sN> (from its template),
# its data folders, its port, and the service in COMPOSE_PROFILES. Options (by name): tag=<tag> port=<n> generate=1 (the secrets that the
# catalog says are generated, like `new --generate-secrets`; a shared one keeps the value the other services have).
# Returns 1 with the reason in SVC_MSG, having changed nothing.
svc_add() { # instance service [option=value ...]
  local name="$1" svc="$2" dir opt tag="" port="" gen=0 d item var kind val src
  shift 2
  dir="$(instance_dir "$name")"
  for opt in "$@"; do
    case "$opt" in
      tag=*) tag="${opt#tag=}" ;;
      port=*) port="${opt#port=}" ;;
      generate=1) gen=1 ;;
    esac
  done
  SVC_MSG=""
  valid_service "$svc" || { SVC_MSG="$(t err.service_unknown "$svc" "${KNOWN_SERVICES[*]}")"; return 1; }
  if svc_is_active "$name" "$svc"; then SVC_MSG="$(t service.already "$svc" "$name")"; return 1; fi
  [ -f "$ROOT/templates/${CAT_TEMPLATE[$svc]}" ] || { SVC_MSG="$(t service.no_template "$svc")"; return 1; }
  [ -w "$dir/.env.instance" ] || { SVC_MSG="$(t service.not_writable "$dir/.env.instance")"; return 1; }
  if [ -n "$tag" ]; then svc_value_ok "$name" "$svc" tag "$tag" || return 1; fi
  if [ -n "$port" ]; then
    svc_port_ok "$name" "$svc" "$port" || return 1
  else
    # the port the instance already has written for the service (a service that was removed and comes back) is kept when it is free
    get_var_r "$dir/.env.instance" "${svc^^}_PORT"
    port="$GV"
    if ! svc_port_ok "$name" "$svc" "$port" 2> /dev/null; then
      svc_free_port "$name" "$svc" || { SVC_MSG="$(t service.no_port)"; return 1; }
      port="$SVC_PORT"
    fi
  fi
  if [ "$gen" -eq 1 ] && ! command -v openssl > /dev/null 2>&1; then SVC_MSG="$(t new.err_generate_no_openssl)"; return 1; fi

  for d in ${CAT_DATA[$svc]:-}; do mkdir -p "$dir/data/$svc/$d"; done
  # `new` already makes a .env.<sN> for every service of the catalog (the template, still to fill in): it is used as it is. A missing one is made.
  if [ ! -f "$dir/.env.$svc" ]; then
    cp "$ROOT/templates/${CAT_TEMPLATE[$svc]}" "$dir/.env.$svc"
    chmod 600 "$dir/.env.$svc"
    sed -i "s/CAMBIAR_\\([a-z]\\+\\)_INSTANCIA/\\1_$name/g" "$dir/.env.$svc"
  fi
  # the address of the server is the one the other services have (only where it is still the template's)
  get_var_r "$dir/.env.$svc" IP_SERVER
  if [ -z "$GV" ] || [[ "$GV" == *CAMBIAR* ]]; then
    for src in "${KNOWN_SERVICES[@]}"; do
      [ "$src" != "$svc" ] && [ -f "$dir/.env.$src" ] || continue
      get_var_r "$dir/.env.$src" IP_SERVER
      if [ -n "$GV" ] && [[ "$GV" != *CAMBIAR* ]]; then set_var "$dir/.env.$svc" IP_SERVER "$GV"; break; fi
    done
  fi
  if [ "$gen" -eq 1 ]; then
    for item in ${CAT_SECRETS[$svc]:-}; do
      var="${item%%:*}" kind="${item#*:}"
      get_var_r "$dir/.env.$svc" "$var"
      { [ -z "$GV" ] || [[ "$GV" == *CAMBIAR* ]]; } || continue   # a value that is there is not replaced
      case "$kind" in
        shared) if svc_shared_value "$name" "$var" "$svc"; then val="$SVC_SHARED"; else val="$(openssl rand -hex 32)"; fi ;;
        hex32) val="$(openssl rand -hex 32)" ;;
        hex24) val="$(openssl rand -hex 24)" ;;
        b64-32) val="$(openssl rand -base64 32)" ;;
        *) continue ;;
      esac
      set_var "$dir/.env.$svc" "$var" "$val"
    done
  else
    # a secret that every service shares has to be the same one: it is copied, not left to be written by hand
    for item in ${CAT_SECRETS[$svc]:-}; do
      var="${item%%:*}" kind="${item#*:}"
      [ "$kind" = shared ] || continue
      get_var_r "$dir/.env.$svc" "$var"
      { [ -z "$GV" ] || [[ "$GV" == *CAMBIAR* ]]; } || continue   # a value that is there is not replaced
      if svc_shared_value "$name" "$var" "$svc"; then set_var "$dir/.env.$svc" "$var" "$SVC_SHARED"; fi
    done
  fi
  set_var "$dir/.env.instance" "${svc^^}_PORT" "$port"
  if [ -n "$tag" ]; then set_var "$dir/.env.instance" "$(tag_var "$svc")" "$tag"; fi
  svc_active_r "$name"
  svc_write_profiles "$name" "${SVC_ACTIVE[@]}" "$svc"
}

# The active services that say they use the one in the argument (the catalog's "soft dependencies"), into SVC_USERS.
SVC_USERS=()
svc_users_of() { # instance service
  local s d
  SVC_USERS=()
  svc_active_r "$1"
  for s in "${SVC_ACTIVE[@]}"; do
    [ "$s" != "$2" ] || continue
    for d in ${CAT_DEPENDS[$s]:-}; do [ "$d" != "$2" ] || { SVC_USERS+=("$s"); break; }; done
  done
}

# Takes a service out of COMPOSE_PROFILES. Its .env.<sN>, its data/ folder and its secrets stay: adding it again finds them as they were.
# The instance keeps at least one service. Returns 1 with the reason in SVC_MSG, having changed nothing.
svc_remove() { # instance service
  local name="$1" svc="$2" s
  local -a rest=()
  SVC_MSG=""
  valid_service "$svc" || { SVC_MSG="$(t err.service_unknown "$svc" "${KNOWN_SERVICES[*]}")"; return 1; }
  svc_is_active "$name" "$svc" || { SVC_MSG="$(t service.not_active "$svc" "$name")"; return 1; }
  for s in "${SVC_ACTIVE[@]}"; do [ "$s" = "$svc" ] || rest+=("$s"); done
  if [ "${#rest[@]}" -eq 0 ]; then SVC_MSG="$(t service.last "$svc" "$name")"; return 1; fi
  [ -w "$INSTANCES_DIR/$name/.env.instance" ] || { SVC_MSG="$(t service.not_writable "$INSTANCES_DIR/$name/.env.instance")"; return 1; }
  svc_write_profiles "$name" "${rest[@]}"
}

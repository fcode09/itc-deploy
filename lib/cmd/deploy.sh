#!/usr/bin/env bash
# ./deltactl deploy <instance> [service]: validates, pulls images and starts the instance
# (or only the given service).

PREFLIGHT_ERRORS=0

# Requires that every key exists, is not empty and does not keep the example value (CAMBIAR...).
# CAMBIAR is the placeholder written in the Spanish .env templates (templates/*.example).
check_required() { # file key...
  local file="$1" key val
  shift
  for key in "$@"; do
    val="$(get_var "$file" "$key")"
    if [ -z "$val" ]; then
      warn "$(t deploy.var_empty "$(basename "$file")" "$key")$(see "variable $key")"
      PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
    elif [[ "$val" == *CAMBIAR* ]]; then
      warn "$(t deploy.var_example "$(basename "$file")" "$key")$(see "variable $key")"
      PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
    fi
  done
}

# Validations of each service. A new service defines its preflight_<sN>.
# Required variables (single source of truth: the preflights use them and tests/test-help.sh compares them
# with the glossary of ./deltactl help variable). The tag and port variables of each service are added in preflight().
REQUIRED_INSTANCE=(INSTANCE COMPOSE_PROFILES)
REQUIRED_S0=(IP_SERVER JWT_SECRET MONGO_URI IP_INTERNAL_CONNECTION)
REQUIRED_S1=(IP_SERVER AUTH_URL JWT_SECRET FEDERATION_ENCRYPTION_KEY SERVERS_CONFIG
  MONGO_DELTA_DISPATCH_URI MONGO_AUTHSOFTWARE_URI MONGO_ROBIN_URI FCM_CERT KEEPER_FCM_CERT DEEPGRAM_API_KEY)

preflight_s0() { # instance_dir
  check_required "$1/.env.s0" "${REQUIRED_S0[@]}"
}

preflight_s1() { # instance_dir
  local dir="$1" f path listen s
  # If s0 runs in this instance, it needs to reach the TCP 5020 of s1 (in another container):
  # with TCP_LISTEN_HOST empty or on loopback, s1 only listens inside its own container.
  listen="$(get_var "$dir/.env.s1" TCP_LISTEN_HOST)"
  for s in "${ENABLED[@]}"; do
    if [ "$s" = "s0" ] && { [ -z "$listen" ] || [ "$listen" = "127.0.0.1" ] || [ "$listen" = "localhost" ]; }; then
      warn "$(t deploy.tcp_listen "${listen:-$(t deploy.empty_word)}")$(see network)"
    fi
  done
  check_required "$dir/.env.s1" "${REQUIRED_S1[@]}"
  # The Firebase JSON files referenced with /run/secrets/... must exist in secrets/.
  for f in FCM_CERT KEEPER_FCM_CERT; do
    path="$(get_var "$dir/.env.s1" "$f")"
    if [[ "$path" == /run/secrets/* ]] && [ ! -f "$dir/secrets/${path#/run/secrets/}" ]; then
      warn "$(t deploy.secret_missing "$f" "$path" "${path#/run/secrets/}")$(see secrets)"
      PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
    fi
  done
}

# Validates only the given services: a service that is not active in the instance is not required.
preflight() { # instance service...
  local name="$1" dir svc tag_name port_name img_name
  shift
  dir="$(instance_dir "$name")"
  PREFLIGHT_ERRORS=0

  check_required "$dir/.env.instance" "${REQUIRED_INSTANCE[@]}"
  if [ "$(get_var "$dir/.env.instance" INSTANCE)" != "$name" ]; then
    warn "$(t deploy.instance_mismatch "$name")"
    PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
  fi

  for svc in "$@"; do
    tag_name="$(tag_var "$svc")"
    port_name="${svc^^}_PORT"
    check_required "$dir/.env.instance" "$tag_name" "$port_name"
    # Custom image name (optional): without a tag and with a valid format.
    img_name="$(get_var "$dir/.env.instance" "${svc^^}_IMAGE")"
    if [ -n "$img_name" ]; then
      if [[ "$img_name" == *:* ]]; then
        warn "$(t deploy.image_colon "${svc^^}_IMAGE" "$img_name" "$tag_name")$(see local-images)"
        PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
      elif ! valid_image_name "$img_name"; then
        warn "$(t deploy.image_invalid "${svc^^}_IMAGE" "$img_name")$(see local-images)"
        PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
      fi
    fi
    if [ "$(get_var "$dir/.env.instance" "$tag_name")" = "latest" ]; then
      warn "$(t deploy.tag_latest "$tag_name")"
    fi
    [ -f "$dir/.env.$svc" ] || die "$(t deploy.env_missing "$dir/.env.$svc")"
    "preflight_$svc" "$dir"
  done

  # Permissions of data/: only a warning (the deploy may be done by another user).
  if [ -d "$dir/data" ] && [ "$(host_owner_uid "$dir/data" "$RUNTIME_UID")" != "$RUNTIME_UID" ]; then
    warn "$(t deploy.data_owner "$RUNTIME_UID" "$dir")"
  fi

  [ "$PREFLIGHT_ERRORS" -eq 0 ] || die "$(t deploy.preflight_problems "$PREFLIGHT_ERRORS" "$name")$(see new-instance)"
}

# With local images, checks that every image exists in this Docker before touching anything.
check_images() { # instance service...
  local name="$1" svc ref missing=0
  shift
  uses_local_images "$name" || return 0
  for svc in "$@"; do
    ref="$(service_image_ref "$name" "$svc")"
    if dk_image_exists "$ref"; then
      warn_arch_mismatch "$ref"
    else
      warn "$(t deploy.image_not_loaded "$ref" "$svc")"
      missing=$((missing + 1))
    fi
  done
  [ "$missing" -eq 0 ] \
    || die "$(t deploy.images_missing "$missing")$(see local-images)"
}

# With local images a tag can be rebuilt and point to another image: if the tag being deployed now
# points to a different ID than the deployed one, it only warns.
warn_changed_images() { # instance service...
  local name="$1" dir svc tag_name cur dep dep_id ref cur_id
  shift
  dir="$(instance_dir "$name")"
  uses_local_images "$name" || return 0
  for svc in "$@"; do
    tag_name="$(tag_var "$svc")"
    cur="$(get_var "$dir/.env.instance" "$tag_name")"
    dep="$(get_var "$dir/.deployed" "$tag_name")"
    dep_id="$(get_var "$dir/.deployed" "${svc^^}_IMAGE_ID")"
    if [ -n "$dep_id" ] && [ "$cur" = "$dep" ]; then
      ref="$(service_image_ref "$name" "$svc")"
      cur_id="$(dk_image_id "$ref")"
      if [ -n "$cur_id" ] && [ "$cur_id" != "$dep_id" ]; then
        warn "$(t deploy.tag_rebuilt "$svc" "$cur" "$(short_id "$cur_id")" "$(short_id "$dep_id")")$(see local-images)"
      fi
    fi
  done
}

# Saves as "previous" the deployed tags (and image ID) that are going to change (for the rollback).
record_previous() { # instance service...
  local name="$1" dir svc tag_name id_name cur dep
  shift
  dir="$(instance_dir "$name")"
  touch "$dir/.deployed" "$dir/.previous"
  for svc in "$@"; do
    tag_name="$(tag_var "$svc")"
    id_name="${svc^^}_IMAGE_ID"
    cur="$(get_var "$dir/.env.instance" "$tag_name")"
    dep="$(get_var "$dir/.deployed" "$tag_name")"
    if [ -n "$dep" ] && [ "$dep" != "$cur" ]; then
      set_var "$dir/.previous" "$tag_name" "$dep"
      set_var "$dir/.previous" "$id_name" "$(get_var "$dir/.deployed" "$id_name")"
    fi
  done
}

# Pulls and starts. explicit=0: everything active according to COMPOSE_PROFILES. explicit=1: only the given
# services; --profile replaces COMPOSE_PROFILES, so the others are not touched.
# It records the deployed tags only if everything ends up healthy.
deploy_up() { # explicit instance service...
  local explicit="$1" name="$2" dir svc
  shift 2
  dir="$(instance_dir "$name")"
  local -a pargs=() svcs=() upflags=()

  if [ "$explicit" = "1" ]; then
    svcs=("$@")
    for svc in "$@"; do pargs+=(--profile "$svc"); done
    # A single service: without dependencies, so nothing else is touched.
    [ "$#" -eq 1 ] && upflags+=(--no-deps)
  fi

  if uses_local_images "$name"; then
    info "$(t deploy.local_images)"
  else
    info "$(t deploy.pulling)"
    # deploy_up runs inside `|| die`, where errexit is off: the result has to be checked, or a failed pull would go on to `up`.
    local pull_rc=0
    dk_compose "$name" ${pargs[@]+"${pargs[@]}"} pull ${svcs[@]+"${svcs[@]}"} || pull_rc=$?
    if [ "$pull_rc" -ne 0 ]; then
      warn "$(t deploy.pull_failed "$pull_rc")"
      return 1
    fi
  fi

  info "$(t deploy.starting)"
  if ! dk_compose "$name" ${pargs[@]+"${pargs[@]}"} up -d ${upflags[@]+"${upflags[@]}"} \
      --wait --wait-timeout "${WAIT_TIMEOUT:-300}" ${svcs[@]+"${svcs[@]}"}; then
    warn "$(t deploy.not_healthy)"
    warn "$(t deploy.not_healthy_hint "$name")"
    return 1
  fi

  touch "$dir/.deployed"
  for svc in "$@"; do
    set_var "$dir/.deployed" "$(tag_var "$svc")" "$(get_var "$dir/.env.instance" "$(tag_var "$svc")")"
    set_var "$dir/.deployed" "${svc^^}_IMAGE_ID" "$(dk_image_id "$(service_image_ref "$name" "$svc")")"
  done
  dk_compose "$name" --profile '*' ps
}

cmd_deploy() {
  local name="${1:-}" only="${2:-}"
  require_instance "$name"
  select_services "$name" "$only"

  check_docker
  preflight "$name" "${SELECTED[@]}"

  info "$(t deploy.validating)"
  if [ -n "$only" ]; then
    dk_compose "$name" --profile "$only" config -q || die "$(t deploy.compose_invalid "$name")"
  else
    dk_compose "$name" config -q || die "$(t deploy.compose_invalid "$name")"
  fi

  check_images "$name" "${SELECTED[@]}"
  warn_changed_images "$name" "${SELECTED[@]}"
  if [ ! -f "$(marker_file "$name")" ] && [ "${DELTACTL_SUPPRESS_INIT_WARN:-0}" != "1" ]; then
    warn "$(t deploy.not_initialized "$name")$(see data)"
  fi
  record_previous "$name" "${SELECTED[@]}"

  if [ -n "$only" ]; then
    deploy_up 1 "$name" "${SELECTED[@]}" || die "$(t deploy.failed_service "$only" "$name")"
    ok "$(t deploy.service_done "$only" "$name")"
  else
    deploy_up 0 "$name" "${SELECTED[@]}" || die "$(t deploy.failed "$name")"
    ok "$(t deploy.done "$name" "${SELECTED[*]}")"
  fi
}

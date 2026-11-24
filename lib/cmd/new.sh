#!/usr/bin/env bash
# ./deltactl new <instance> [--services s0,s1] [--existing] [--wizard]: creates instances/<instance>/ from the templates.
# Without a name and in a terminal (or with --wizard) it opens a wizard that asks the essentials.
# The wizard's answers also exist as flags (--s0-image, --s1-image, --s0-tag, --s1-tag, --ip, --generate-secrets): the panel's
# form (lib/screens/wizard.sh) collects the answers itself and starts `new <name> ...` with them.

# REQUIRED_* and check_required come from deploy.sh
source "$ROOT/lib/cmd/deploy.sh"

W_S0IMG="" W_S1IMG="" W_S0TAG="" W_S1TAG="" W_IP="" W_GEN=0

# Asks with a default value. The result is in REPLY_VAL.
new_ask() { # question [default]
  local def="${2:-}" ans=""
  printf '  %s?%s %s%s%s ' "$C_CYN" "$C_OFF" "$1" "${def:+ [$def]}" ":" >&2
  IFS= read -r ans || true
  REPLY_VAL="${ans:-$def}"
}

# Yes/no question. Returns 0 if the answer is yes. $2 = y | n (the default; "s" is accepted as a synonym of y).
# The hint ([y/N] or [s/N]...) and the accepted letters (y, Y, s, S) are the same in every language.
new_ask_yn() { # question [y|n]
  local def="${2:-n}" ans="" hint
  case "$def" in y | s) def=y; hint="$(t prompt.hint_yes)" ;; *) def=n; hint="$(t prompt.hint_no)" ;; esac
  printf '  %s?%s %s [%s]: ' "$C_CYN" "$C_OFF" "$1" "$hint" >&2
  IFS= read -r ans || true
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[sSyY]$ ]]
}

# Wizard: fills name, services, existing and the W_* variables.
new_wizard() {
  local svc img tags
  ui_h1 "$(t new.wiz_title)"
  printf '  %s%s%s\n\n' "$C_GRY" "$(t new.wiz_hint)" "$C_OFF" >&2

  new_ask "$(t new.ask_name)"
  name="$REPLY_VAL"
  valid_instance_name "$name" \
    || die "$(t err.instance_name_invalid "$name")$(see new)"
  [ ! -e "$(instance_dir "$name")" ] || die "$(t new.err_exists "$name" "$(instance_dir "$name")")"

  new_ask "$(t new.ask_services)" "s0,s1"
  services="${REPLY_VAL// /}"

  if new_ask_yn "$(t new.ask_existing)" n; then
    existing=1
    printf '  %s%s%s\n' "$C_GRY" "$(t new.existing_note)" "$C_OFF" >&2
  fi

  local -a parts
  IFS=',' read -ra parts <<< "$services"
  for svc in "${parts[@]}"; do
    valid_service "$svc" || die "$(t new.err_wiz_service "$svc" "${KNOWN_SERVICES[*]}")$(see services)"
    new_ask "$(t new.ask_image "$svc")" "$(default_repo "$svc")"
    img="$REPLY_VAL"
    valid_image_name "$img" || die "$(t new.err_image_invalid "$img")$(see local-images)"
    tags="$(loaded_tags "$img" | tr '\n' ' ')"
    [ -z "$tags" ] || printf '  %s%s%s\n' "$C_GRY" "$(t new.loaded_tags "$img" "$tags")" "$C_OFF" >&2
    new_ask "$(t new.ask_tag "$svc")"
    case "$svc" in
      s0) W_S0IMG="$img"; W_S0TAG="$REPLY_VAL" ;;
      s1) W_S1IMG="$img"; W_S1TAG="$REPLY_VAL" ;;
    esac
  done

  new_ask "$(t new.ask_url)"
  W_IP="$REPLY_VAL"
  if [ "$existing" -eq 0 ]; then
    if command -v openssl >/dev/null 2>&1; then
      if new_ask_yn "$(t new.ask_generate)" y; then W_GEN=1; fi
    else
      printf '  %s%s%s\n' "$C_GRY" "$(t new.no_openssl)" "$C_OFF" >&2
    fi
  fi

  local pending data secrets
  pending="$(t new.pending_word)"
  if [ "$existing" -eq 1 ]; then data="$(t new.data_existing)"; else data="$(t new.data_new)"; fi
  if [ "$W_GEN" -eq 1 ]; then secrets="$(t new.secrets_generated)"; else secrets="$(t new.secrets_manual)"; fi
  printf '\n  %s%s%s\n' "$C_BLD" "$(t new.summary_title)" "$C_OFF" >&2
  printf '%s\n\n' "$(t new.summary "$name" "$services" "$data" "${W_S0TAG:-$pending}" "${W_S1TAG:-$pending}" "${W_IP:-$pending}" "$secrets")" >&2
  new_ask_yn "$(t new.ask_create)" y || die "$(t err.cancelled)"
}

# Applies to the newly created .env files what the wizard answered.
new_apply_wizard() { # instance existing
  local name="$1" existing="$2" dir f secret
  dir="$(instance_dir "$name")"
  [ -z "$W_S0IMG" ] || [ "$W_S0IMG" = "$(default_repo s0)" ] || set_var "$dir/.env.instance" S0_IMAGE "$W_S0IMG"
  [ -z "$W_S1IMG" ] || [ "$W_S1IMG" = "$(default_repo s1)" ] || set_var "$dir/.env.instance" S1_IMAGE "$W_S1IMG"
  [ -z "$W_S0TAG" ] || set_var "$dir/.env.instance" S0_TAG "$W_S0TAG"
  [ -z "$W_S1TAG" ] || set_var "$dir/.env.instance" S1_TAG "$W_S1TAG"
  if [ -n "$W_IP" ]; then
    for f in "$dir/.env.s0" "$dir/.env.s1"; do set_var "$f" IP_SERVER "$W_IP"; done
  fi
  # New municipality: databases named after the instance (for an existing one the user sets the URIs).
  # CAMBIAR_..._INSTANCIA is the placeholder written in the Spanish .env templates.
  if [ "$existing" -eq 0 ]; then
    sed -i "s/CAMBIAR_\\(authsoftware\\|deltadispatch\\|robin\\)_INSTANCIA/\\1_$name/g" "$dir/.env.s0" "$dir/.env.s1"
  fi
  if [ "$W_GEN" -eq 1 ]; then
    # The same JWT_SECRET in s0 and s1: it is safe inside one instance and avoids rejections between services.
    secret="$(openssl rand -hex 32)"
    for f in "$dir/.env.s0" "$dir/.env.s1"; do set_var "$f" JWT_SECRET "$secret"; done
    set_var "$dir/.env.s1" FEDERATION_ENCRYPTION_KEY "$(openssl rand -base64 32)"
    set_var "$dir/.env.s1" DELTA_UNIVERSITY_HANDOFF_SECRET "$(openssl rand -hex 32)"
    set_var "$dir/.env.s1" SHIFT_UPDATE_BASELINE_SECRET "$(openssl rand -hex 24)"
  fi
}

# Lists what is still missing before ./deltactl deploy, per file.
new_pending() { # instance
  local name="$1" dir svc key val miss path any=0
  local -a svcs=()
  dir="$(instance_dir "$name")"
  IFS=',' read -ra svcs <<< "$(get_var "$dir/.env.instance" COMPOSE_PROFILES)"

  miss=""
  for svc in "${svcs[@]}"; do
    for key in "$(tag_var "$svc")"; do
      val="$(get_var "$dir/.env.instance" "$key")"
      [ -n "$val" ] || miss+="$key, "
    done
  done
  new_pending_line ".env.instance" "$miss" && any=1

  for svc in "${svcs[@]}"; do
    miss=""
    local -n req="REQUIRED_${svc^^}"
    for key in "${req[@]}"; do
      val="$(get_var "$dir/.env.$svc" "$key")"
      if [ -z "$val" ] || [[ "$val" == *CAMBIAR* ]]; then miss+="$key, "; fi
    done
    unset -n req
    new_pending_line ".env.$svc" "$miss" && any=1
  done

  miss=""
  for svc in "${svcs[@]}"; do
    [ "$svc" = "s1" ] || continue
    for key in FCM_CERT KEEPER_FCM_CERT; do
      path="$(get_var "$dir/.env.s1" "$key")"
      if [[ "$path" == /run/secrets/* ]] && [ ! -f "$dir/secrets/${path#/run/secrets/}" ]; then
        miss+="${path#/run/secrets/}, "
      fi
    done
  done
  new_pending_line "secrets/" "$miss" && any=1
  [ "$any" -eq 1 ] || printf '  %s %s\n' "$(ui_sym ok)" "$(t new.nothing_pending "$name")"
}

new_pending_line() { # file "A, B, "
  [ -n "$2" ] || return 1
  printf '  %s %s%-16s%s %s\n' "$(ui_sym warn)" "$C_BLD" "$1" "$C_OFF" "${2%, }"
}

cmd_new() {
  local name="" services="" existing=0 wizard=0 a
  while [ "$#" -gt 0 ]; do
    a="$1"
    case "$a" in
      --services)
        [ "$#" -ge 2 ] || die "$(t new.opt_services)"
        services="$2"
        shift 2
        ;;
      --existing)
        existing=1
        shift
        ;;
      --wizard | -i)
        wizard=1
        shift
        ;;
      # What the wizard asks, as flags: the panel's form starts `new` with them, and scripts can too.
      --s0-image | --s1-image | --s0-tag | --s1-tag | --ip)
        [ "$#" -ge 2 ] || die "$(t new.opt_value "$a")"
        case "$a" in
          --s0-image) W_S0IMG="$2" ;;
          --s1-image) W_S1IMG="$2" ;;
          --s0-tag) W_S0TAG="$2" ;;
          --s1-tag) W_S1TAG="$2" ;;
          --ip) W_IP="$2" ;;
        esac
        shift 2
        ;;
      --generate-secrets)
        W_GEN=1
        shift
        ;;
      -*) die "$(t new.unknown_option "$a")" ;;
      *)
        [ -z "$name" ] || die "$(t new.extra_arg "$a")"
        name="$a"
        shift
        ;;
    esac
  done

  # Wizard: with --wizard, or without a name when there is an interactive terminal.
  if [ "$wizard" -eq 1 ] || { [ -z "$name" ] && [ -t 0 ] && [ -t 1 ]; }; then
    [ -z "$name" ] || die "$(t new.wizard_no_name)"
    new_wizard
  fi

  [ -n "$name" ] || die "$(t new.usage)"
  valid_instance_name "$name" \
    || die "$(t err.instance_name_invalid "$name")$(see new)"
  local img
  for img in "$W_S0IMG" "$W_S1IMG"; do
    [ -z "$img" ] || valid_image_name "$img" || die "$(t new.err_image_invalid "$img")$(see local-images)"
  done
  if [ "$W_GEN" -eq 1 ] && ! command -v openssl > /dev/null 2>&1; then die "$(t new.err_generate_no_openssl)"; fi

  if [ -n "$services" ]; then
    local part
    local -a parts
    IFS=',' read -ra parts <<< "$services"
    for part in "${parts[@]}"; do
      valid_service "${part// /}" \
        || die "$(t new.err_services_opt "$part" "${KNOWN_SERVICES[*]}")$(see services)"
    done
  fi

  local dir
  dir="$(instance_dir "$name")"
  [ ! -e "$dir" ] || die "$(t new.err_exists "$name" "$dir")"

  local s0_port s1_port owner
  s0_port="$(next_s0_port)"
  s1_port=$((s0_port + 1))
  for p in "$s0_port" "$s1_port"; do
    owner="$(port_owner "$p" "$name")"
    [ -z "$owner" ] || die "$(t new.port_used "$p" "$owner")$(see ports)"
    if host_port_in_use "$p"; then
      warn "$(t new.port_busy "$p")"
    fi
  done

  mkdir -p \
    "$dir/secrets" \
    "$dir/data/s0/media/user" "$dir/data/s0/media/loginSettings" \
    "$dir/data/s0/media/file" "$dir/data/s0/media/certificate-settings" \
    "$dir/data/s0/backups" \
    "$dir/data/s1/media" "$dir/data/s1/uploads" \
    "$dir/data/s1/fileIncidentsResolved" "$dir/data/s1/imageIncidentsResolved"

  cp "$ROOT/templates/.env.instance.example" "$dir/.env.instance"
  cp "$ROOT/templates/.env.s0.example" "$dir/.env.s0"
  cp "$ROOT/templates/.env.s1.example" "$dir/.env.s1"
  set_var "$dir/.env.instance" INSTANCE "$name"
  set_var "$dir/.env.instance" S0_PORT "$s0_port"
  set_var "$dir/.env.instance" S1_PORT "$s1_port"
  if [ -n "$services" ]; then
    set_var "$dir/.env.instance" COMPOSE_PROFILES "${services// /}"
  fi
  chmod 600 "$dir/.env.instance" "$dir/.env.s0" "$dir/.env.s1"
  chmod 700 "$dir/secrets"
  new_apply_wizard "$name" "$existing"

  # The containers run as uid 1000: data/ must belong to it so they can write.
  local me
  me="$(host_uid)"
  if [ "$me" = "0" ]; then
    chown -R "$RUNTIME_UID:$RUNTIME_UID" "$dir/data"
  elif [ "$me" != "$RUNTIME_UID" ]; then
    warn "$(t new.data_uid_1 "$me" "$RUNTIME_UID")"
    warn "$(t new.data_uid_2 "$RUNTIME_UID" "$RUNTIME_UID" "$dir")"
  fi

  if [ "$existing" -eq 1 ]; then
    write_marker "$name" existing
    info "$(t new.marked_existing)"
  fi
  ok "$(t new.created "$name" "$dir" "$s0_port" "$s1_port")"
  info ""
  info "$(t new.pending_title)"
  new_pending "$name"
  info ""
  info "$(t new.next_title)"
  info "$(t new.step1 "$dir")"
  info "$(t new.step2 "$dir")"
  info "$(t new.step3 "$dir")"
  info "$(t new.step4 "$name")"
  info "$(t new.step5 "$name")"
  info "$(t new.more "$(topic_label new-instance)")"
}

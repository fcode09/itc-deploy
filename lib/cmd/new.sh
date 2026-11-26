#!/usr/bin/env bash
# ./deltactl new <instance> [--services s0,s1] [--existing] [--wizard]: creates instances/<instance>/ from the templates.
# Without a name and in a terminal (or with --wizard) it opens a wizard that asks the essentials.
# The wizard's answers also exist as flags (--<sN>-image, --<sN>-tag for every service of the catalog, --ip, --generate-secrets): the panel's
# form (lib/screens/wizard.sh) collects the answers itself and starts `new <name> ...` with them.
# More answers, for the panel's wizard of steps (lib/screens/newinst.sh) and for scripts: --env-file F (variables of the files, from a file, so a secret
# is never in a command line), --secret-file SRC[:NAME] (a file for secrets/), --domain D with --proxy nginx|caddy|both and --tls (the reverse-proxy
# block, written inside the instance: lib/core/proxy.sh).

# REQUIRED_* and check_required come from deploy.sh
source "$ROOT/lib/cmd/deploy.sh"

declare -gA W_IMG=() W_TAG=()   # image name and tag the wizard (or the flags) chose, by service
W_IP="" W_GEN=0
W_DOMAIN="" W_PROXY="" W_TLS=0 W_WWW=0 W_HOSTS=()
W_ENVF=() W_ENVK=() W_ENVV=()   # --env-file: file word (instance | s0...), key and value of each line
W_SECSRC=() W_SECNAME=()        # --secret-file: the source path and the name in secrets/
declare -gA W_ENVPORT=()        # --env-file: the port it gives to a service (checked like the one that is proposed)

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
    W_IMG[$svc]="$img"
    W_TAG[$svc]="$REPLY_VAL"
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
  printf '%s\n\n' "$(t new.summary "$name" "$services" "$data" "${W_TAG[s0]:-$pending}" "${W_TAG[s1]:-$pending}" "${W_IP:-$pending}" "$secrets")" >&2
  new_ask_yn "$(t new.ask_create)" y || die "$(t err.cancelled)"
}

# `--sN-tag latest` asks for the MOST RECENT version of the image (lib/core/imagecat.sh: the newest by creation date among the stable version
# tags that this server can run), not for a tag called "latest", which moves and cannot be gone back to. It is resolved to the tag it names.
# Only for the services the instance has (the argument is the --services list; empty is all of them). `new` itself never needed Docker, so
# when Docker does not answer nothing is resolved: the tag stays "latest" with a warning, as it was asked. When Docker answers and there is no
# version to choose, it fails before anything is created.
new_resolve_latest() { # [services]
  local svc repo
  local -a want=() act=()
  if [ -n "$1" ]; then IFS=',' read -ra act <<< "${1// /}"; else act=("${KNOWN_SERVICES[@]}"); fi
  for svc in "${KNOWN_SERVICES[@]}"; do
    [ "${W_TAG[$svc]:-}" = latest ] || continue
    case " ${act[*]} " in *" $svc "*) ;; *) continue ;; esac
    want+=("$svc=${W_IMG[$svc]:-$(default_repo "$svc")}")
  done
  [ "${#want[@]}" -gt 0 ] || return 0
  if ! ic_load "${want[@]}"; then
    for svc in "${want[@]}"; do warn "$(t new.latest_nodocker "${svc%%=*}" "$(tag_var "${svc%%=*}")")"; done
    return 0
  fi
  for svc in "${want[@]}"; do
    repo="${svc#*=}" svc="${svc%%=*}"
    ic_latest "$svc" "$repo" || die "$(t new.latest_none "$svc" "$repo" "$IC_SERVER_ARCH")$(see local-images)"
    info "$(t new.latest_resolved "$svc" "$repo" "$IC_LATEST")"
    W_TAG[$svc]="$IC_LATEST"
  done
}

# Applies to the newly created .env files what the wizard answered.
new_apply_wizard() { # instance existing
  local name="$1" existing="$2" dir f svc secret item var kind
  local -a files=()
  dir="$(instance_dir "$name")"
  for svc in "${KNOWN_SERVICES[@]}"; do
    files+=("$dir/.env.$svc")
    [ -z "${W_IMG[$svc]:-}" ] || [ "${W_IMG[$svc]}" = "$(default_repo "$svc")" ] || set_var "$dir/.env.instance" "${svc^^}_IMAGE" "${W_IMG[$svc]}"
    [ -z "${W_TAG[$svc]:-}" ] || set_var "$dir/.env.instance" "$(tag_var "$svc")" "${W_TAG[$svc]}"
  done
  if [ -n "$W_IP" ]; then
    for f in "${files[@]}"; do set_var "$f" IP_SERVER "$W_IP"; done
  fi
  # New municipality: databases named after the instance (for an existing one the user sets the URIs).
  # CAMBIAR_<db>_INSTANCIA is the placeholder written in the Spanish .env templates.
  if [ "$existing" -eq 0 ]; then
    sed -i "s/CAMBIAR_\\([a-z]\\+\\)_INSTANCIA/\\1_$name/g" "${files[@]}"
  fi
  if [ "$W_GEN" -eq 1 ]; then
    # A "shared" secret (JWT_SECRET) has the same value in every service: it is safe inside one instance and avoids rejections
    # between services.
    secret="$(openssl rand -hex 32)"
    for svc in "${KNOWN_SERVICES[@]}"; do
      for item in ${CAT_SECRETS[$svc]:-}; do
        var="${item%%:*}" kind="${item#*:}"
        case "$kind" in
          shared) set_var "$dir/.env.$svc" "$var" "$secret" ;;
          hex32) set_var "$dir/.env.$svc" "$var" "$(openssl rand -hex 32)" ;;
          hex24) set_var "$dir/.env.$svc" "$var" "$(openssl rand -hex 24)" ;;
          b64-32) set_var "$dir/.env.$svc" "$var" "$(openssl rand -base64 32)" ;;
        esac
      done
    done
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
    for key in ${CAT_SECRET_FILES[$svc]:-}; do
      path="$(get_var "$dir/.env.$svc" "$key")"
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

# --env-file F: lines `<file>:<KEY>=<value>` (file: instance, s0, s1...; blank lines and # comments are skipped). Nothing of what is in the file is
# ever in a message: an error says the line number, not the line. It is read once, here; the file itself is the caller's (the panel deletes its own).
new_read_envfile() { # path
  local f="$1" line n=0 word key val
  [ -f "$f" ] && [ -r "$f" ] || die "$(t new.envfile_unreadable "$f")"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    [ -n "${line//[[:space:]]/}" ] || continue
    [[ "$line" != \#* ]] || continue
    [[ "$line" =~ ^([a-z0-9]+):([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || die "$(t new.envfile_line "$n")"
    word="${BASH_REMATCH[1]}" key="${BASH_REMATCH[2]}" val="${BASH_REMATCH[3]}"
    if [ "$word" != instance ] && ! valid_service "$word"; then die "$(t new.envfile_file "$n" "$word")"; fi
    W_ENVF+=("$word") W_ENVK+=("$key") W_ENVV+=("$val")
  done < "$f"
}

# The values of --env-file are checked BEFORE anything is created, with the rules of the variables (lib/core/envschema.sh): one that does not pass
# stops `new` with the name of the variable, never its value. A port it gives to a service is the one that is checked and written.
new_check_envfile() { # instance services-csv
  local i word key file act s
  local -a want=()
  [ "${#W_ENVF[@]}" -gt 0 ] || return 0
  if [ -n "$2" ]; then IFS=',' read -ra want <<< "${2// /}"; else want=("${KNOWN_SERVICES[@]}"); fi
  envschema_load
  for i in "${!W_ENVF[@]}"; do
    word="${W_ENVF[$i]}" key="${W_ENVK[$i]}"
    file="$(envschema_file_name "$word")" || die "$(t new.envfile_file "$((i + 1))" "$word")"
    if [ "$word" != instance ]; then
      act=0
      for s in "${want[@]}"; do [ "$s" != "$word" ] || act=1; done
      [ "$act" -eq 1 ] || die "$(t new.envfile_inactive "$word")"
    fi
    envschema_check_r "$file" "$key" "${W_ENVV[$i]}" "$1"
    if [ "$EV_RC" = 1 ]; then die "$(t new.envfile_invalid "$word" "$key")"; fi
    if [ "$word" = instance ] && [[ "$key" =~ ^S([0-9]+)_PORT$ ]]; then W_ENVPORT["s${BASH_REMATCH[1]}"]="${W_ENVV[$i]}"; fi
  done
}

# --secret-file SRC[:NAME]: a file for secrets/. NAME is what is after the last ":" when it is a name for a file; else the name of the source.
new_add_secretfile() { # spec
  local spec="$1" src name tail
  src="$spec" name="${spec##*/}"
  tail="${spec##*:}"
  if [[ "$spec" == *:* ]] && [[ "$tail" != */* ]] && [ -n "$tail" ]; then src="${spec%:*}" name="$tail"; fi
  sf_valid_name "$name" || die "$(t new.secret_name "$name")"
  W_SECSRC+=("$src") W_SECNAME+=("$name")
}

new_check_secretfiles() {
  local i src
  for i in "${!W_SECSRC[@]}"; do
    src="${W_SECSRC[$i]}"
    sf_check "$src" && continue
    case "$SF_WHY" in
      missing) die "$(t new.secret_missing "$src")" ;;
      notfile) die "$(t new.secret_notfile "$src")" ;;
      unreadable) die "$(t new.secret_unreadable "$src")" ;;
      empty) die "$(t new.secret_empty "$src")" ;;
      toobig) die "$(t new.secret_toobig "$src")" ;;
      *) die "$(t new.secret_notjson "$src")" ;;
    esac
  done
}

# The proxy block(s) of the domain, inside instances/<name>/proxy/. The ports are the ones the instance ended with.
new_write_proxy() { # instance services-csv
  local name="$1" dir s fl rc
  local -a act=() flavors=()
  dir="$(instance_dir "$name")"
  if [ -n "$2" ]; then IFS=',' read -ra act <<< "${2// /}"; else act=("${KNOWN_SERVICES[@]}"); fi
  PROXY_PORTS=()
  for s in "${act[@]}"; do
    # shellcheck disable=SC2034  # (read by proxy_domain_names, in lib/core/proxy.sh)
    PROXY_PORTS[$s]="$(get_var "$dir/.env.instance" "${s^^}_PORT")"
  done
  PROXY_HOSTS=() PROXY_WWW="$W_WWW"
  for s in "${W_HOSTS[@]}"; do
    [[ " ${act[*]} " == *" ${s%%=*} "* ]] || die "$(t access.bad_service "${s%%=*}" "$name" "${act[*]}")"
    PROXY_HOSTS[${s%%=*}]="${s#*=}"
  done
  proxy_domain_names "$W_DOMAIN" "${act[@]}" || die "$(t new.domain_invalid "$W_DOMAIN")"
  case "${W_PROXY:-both}" in both) flavors=(nginx caddy) ;; *) flavors=("$W_PROXY") ;; esac
  for fl in "${flavors[@]}"; do
    proxy_render "$fl" "$W_TLS" "${PROXY_ENTRIES[@]}" || die "$(t new.proxy_render "$fl" "$PROXY_ERR")"
    rc=0
    proxy_save "$name" "$fl" || rc=$?
    [ "$rc" -eq 0 ] || die "$(t new.proxy_write "$fl")"
    info "$(t new.proxy_written "proxy/$(proxy_file "$fl")" "$dir/proxy/$(proxy_file "$fl")")"
  done
  # A name of its own for a service or the www alias is not something the block can be read back from: it is remembered (access.conf).
  if [ "$W_WWW" -eq 1 ] || [ "${#W_HOSTS[@]}" -gt 0 ]; then
    proxy_meta_save "$name" "$W_DOMAIN" "${flavors[0]}" "$W_TLS" || die "$(t new.proxy_write "${flavors[0]}")"
  fi
}

# Writes what the answers say once the instance exists: the variables, the files of secrets/ and the proxy block.
new_apply_answers() { # instance services-csv
  local name="$1" dir i rc word file
  dir="$(instance_dir "$name")"
  # shellcheck disable=SC2034  # (read by envedit_backup, in lib/core/envedit.sh)
  ENVEDIT_NOBACKUP=1
  for i in "${!W_ENVF[@]}"; do
    word="${W_ENVF[$i]}"
    file="$(envschema_file_name "$word")"
    rc=0
    envedit_save "$name" "$file" "${W_ENVK[$i]}" "${W_ENVV[$i]}" || rc=$?
    [ "$rc" -eq 0 ] || die "$(t new.envfile_write "$word" "${W_ENVK[$i]}")"
  done
  for i in "${!W_SECSRC[@]}"; do
    sf_install "${W_SECSRC[$i]}" "$dir" "${W_SECNAME[$i]}" || die "$(t new.secret_copy "${W_SECNAME[$i]}")"
    info "$(t new.secret_copied "${W_SECNAME[$i]}")"
  done
  [ -z "$W_DOMAIN" ] || new_write_proxy "$name" "$2"
}

cmd_new() {
  local name="" services="" existing=0 wizard=0 a svc
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
      --s[0-9]*-image | --s[0-9]*-tag | --ip)
        [ "$#" -ge 2 ] || die "$(t new.opt_value "$a")"
        if [ "$a" = "--ip" ]; then
          W_IP="$2"
        else
          svc="${a#--}"; svc="${svc%-*}"
          valid_service "$svc" || die "$(t new.unknown_option "$a")"
          case "$a" in
            *-image) W_IMG[$svc]="$2" ;;
            *-tag) W_TAG[$svc]="$2" ;;
          esac
        fi
        shift 2
        ;;
      --generate-secrets)
        W_GEN=1
        shift
        ;;
      --env-file)
        [ "$#" -ge 2 ] || die "$(t new.opt_value "$a")"
        new_read_envfile "$2"
        shift 2
        ;;
      --secret-file)
        [ "$#" -ge 2 ] || die "$(t new.opt_value "$a")"
        new_add_secretfile "$2"
        shift 2
        ;;
      --domain)
        [ "$#" -ge 2 ] || die "$(t new.opt_value "$a")"
        W_DOMAIN="${2,,}"
        shift 2
        ;;
      --proxy)
        [ "$#" -ge 2 ] || die "$(t new.opt_value "$a")"
        case "$2" in nginx | caddy | both) W_PROXY="$2" ;; *) die "$(t new.proxy_opt "$2")" ;; esac
        shift 2
        ;;
      --tls)
        W_TLS=1
        shift
        ;;
      --www)
        W_WWW=1
        shift
        ;;
      --host)
        [ "$#" -ge 2 ] || die "$(t new.opt_value "$a")"
        [[ "$2" == *=* ]] || die "$(t access.bad_spec "$2")"
        valid_service "${2%%=*}" || die "$(t err.service_unknown "${2%%=*}" "${KNOWN_SERVICES[*]}")"
        proxy_host_ok "${2#*=}" || die "$(t access.bad_host "${2#*=}")"
        W_HOSTS+=("${2%%=*}=${2#*=}")
        shift 2
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
  for svc in "${KNOWN_SERVICES[@]}"; do
    img="${W_IMG[$svc]:-}"
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

  # What the extra answers say is checked before anything is created (a value, a file, a domain that is not valid stops here, with nothing left).
  if [ -n "$W_DOMAIN" ]; then proxy_host_ok "$W_DOMAIN" || die "$(t new.domain_invalid "$W_DOMAIN")"; fi
  if [ -z "$W_DOMAIN" ] && { [ -n "$W_PROXY" ] || [ "$W_TLS" -eq 1 ] || [ "$W_WWW" -eq 1 ] || [ "${#W_HOSTS[@]}" -gt 0 ]; }; then die "$(t new.proxy_needs_domain)"; fi
  new_check_secretfiles
  new_check_envfile "$name" "$services"

  local base_port p d owner
  local -A port_of=()
  base_port="$(next_s0_port)"
  for svc in "${KNOWN_SERVICES[@]}"; do
    p="${W_ENVPORT[$svc]:-$((base_port + ${CAT_OFFSET[$svc]}))}"
    port_of[$svc]="$p"
    owner="$(port_owner "$p" "$name")"
    [ -z "$owner" ] || die "$(t new.port_used "$p" "$owner")$(see ports)"
    if host_port_in_use "$p"; then
      warn "$(t new.port_busy "$p")"
    fi
  done

  new_resolve_latest "$services"   # (before anything is created: when there is no version to choose nothing is left behind)

  mkdir -p "$dir/secrets"
  for svc in "${KNOWN_SERVICES[@]}"; do
    for d in ${CAT_DATA[$svc]}; do mkdir -p "$dir/data/$svc/$d"; done
  done

  cp "$ROOT/templates/.env.instance.example" "$dir/.env.instance"
  set_var "$dir/.env.instance" INSTANCE "$name"
  for svc in "${KNOWN_SERVICES[@]}"; do
    cp "$ROOT/templates/${CAT_TEMPLATE[$svc]}" "$dir/.env.$svc"
    set_var "$dir/.env.instance" "${svc^^}_PORT" "${port_of[$svc]}"
    chmod 600 "$dir/.env.$svc"
  done
  if [ -n "$services" ]; then
    set_var "$dir/.env.instance" COMPOSE_PROFILES "${services// /}"
  fi
  chmod 600 "$dir/.env.instance"
  chmod 700 "$dir/secrets"
  new_apply_wizard "$name" "$existing"
  new_apply_answers "$name" "$services"

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
  ok "$(t new.created "$name" "$dir" "${port_of[s0]:-}" "${port_of[s1]:-}")"
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

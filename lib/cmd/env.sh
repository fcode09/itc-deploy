#!/usr/bin/env bash
# ./deltactl env <instance> list [file] [--reveal] [--json]
#                           get <[file:]VARIABLE> [--reveal]
#                           set <[file:]VARIABLE> [value] [--stdin] [--force]      (also VARIABLE=value)
#                           generate <[file:]VARIABLE> [--yes]
#                           pending
#                           sync [service] [--apply] [--json]
# The environment files of an instance: see them, validate what is written, change a value and generate a secret. The rules come from
# lib/core/envschema.sh (what each variable is) and lib/core/envedit.sh (how a file is read and written safely).
#
# A secret is never printed unless --reveal is given, and no operation here goes into the history of operations (runs): the value
# would be in its command line. `set VARIABLE --stdin` (or the hidden prompt of a secret) keeps it out of the shell history too.

TARGET_FILE=""
TARGET_KEY=""

# Resolves "[file:]KEY" for an instance into TARGET_FILE (.env.s0) and TARGET_KEY. Dies with a clear message when it cannot.
env_resolve() { # instance target [subcommand]
  local inst="$1" target="$2" w f key files=() line seen
  key="$target"
  if [[ "$target" == *:* ]]; then
    w="${target%%:*}"
    key="${target#*:}"
    f="$(envschema_file_name "$w")" || die "$(t env.file_unknown "$w" "instance ${KNOWN_SERVICES[*]}")"
    [ -f "$INSTANCES_DIR/$inst/$f" ] || die "$(t env.file_absent "$inst" "$f")"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "$(t env.key_invalid "$key")"
    TARGET_FILE="$f" TARGET_KEY="$key"
    return 0
  fi
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "$(t env.key_invalid "$key")"
  envedit_files_r "$inst"
  # The files of the instance whose schema has the key; else the ones that have it written even if the glossary does not know it.
  for f in "${ENVEDIT_FILES[@]}"; do
    [ -n "${ENV_KEY[$f|$key]+x}" ] && files+=("$f")
  done
  if [ "${#files[@]}" -eq 0 ]; then
    for f in "${ENVEDIT_FILES[@]}"; do
      seen=0
      while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" == "$key="* ]] && { seen=1; break; }
      done < "$INSTANCES_DIR/$inst/$f"
      [ "$seen" -eq 1 ] && files+=("$f")
    done
  fi
  [ "${#files[@]}" -gt 0 ] || die "$(t env.key_unknown "$key" "$inst")"
  if [ "${#files[@]}" -gt 1 ]; then
    local opts=""
    for f in "${files[@]}"; do opts+="$(envedit_word "$f"):$key "; done
    die "$(t env.key_ambiguous "$key" "${opts% }")"
  fi
  TARGET_FILE="${files[0]}" TARGET_KEY="$key"
}

# ---------- list ----------

env_state_label() { # state
  t "env.state.$1"
}

env_list() { # instance file-filter reveal json
  local inst="$1" only="$2" reveal="$3" json="$4" f id key shown label kind first=1 pend=() w nfiles=0 line k
  local -a extra=()
  envedit_files_r "$inst"
  if [ -n "$only" ]; then
    f="$(envschema_file_name "$only")" || die "$(t env.file_unknown "$only" "instance ${KNOWN_SERVICES[*]}")"
    [ -f "$INSTANCES_DIR/$inst/$f" ] || die "$(t env.file_absent "$inst" "$f")"
    only="$f"
  fi
  while IFS= read -r f; do pend+=("$f"); done < <(envedit_pending "$inst")

  if [ "$json" -eq 1 ]; then
    printf '{\n  "instance": "%s",\n  "pending": [' "$(ui_json_escape "$inst")"
    local pf=1
    for f in ${pend[@]+"${pend[@]}"}; do
      [ "$pf" -eq 1 ] || printf ', '
      pf=0
      printf '"%s"' "$(ui_json_escape "$f")"
    done
    printf '],\n  "variables": [\n'
  else
    ui_h1 "$(t env.list_title "$inst")"
    ui_table_cols 12 32 34
    ui_th "$(t env.list_file)" "$(t env.list_var)" "$(t env.list_value)" "$(t env.list_state)"
  fi

  for f in "${ENVEDIT_FILES[@]}"; do
    [ -z "$only" ] || [ "$only" = "$f" ] || continue
    nfiles=$((nfiles + 1))
    w="$(envedit_word "$f")"
    # The variables the glossary knows, in its order (the fixed ones are set by the compose: they are not shown), then whatever else
    # the file has.
    local -a keys=()
    for id in "${ENV_IDS[@]}"; do
      [ "${ENV_FILE[$id]}" = "$f" ] && [ "${ENV_TYPE[$id]}" != fixed ] && keys+=("${ENV_KEY[$id]}")
    done
    extra=()
    while IFS= read -r line || [ -n "$line" ]; do
      [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
      k="${BASH_REMATCH[1]}"
      [ -z "${ENV_KEY[$f|$k]+x}" ] || continue
      [[ " ${extra[*]:-} " == *" $k "* ]] || extra+=("$k")
    done < "$INSTANCES_DIR/$inst/$f"
    for key in ${keys[@]+"${keys[@]}"} ${extra[@]+"${extra[@]}"}; do
      id="$f|$key"
      if [ -z "${ENV_KEY[$id]+x}" ]; then
        get_var_r "$INSTANCES_DIR/$inst/$f" "$key"
        ED_VALUE="$GV" ED_STATE=extra
      else
        envedit_state_r "$inst" "$f" "$key"
      fi
      local secret=0
      ! envedit_is_secret "$f" "$key" || secret=1
      if [ "$reveal" -eq 1 ] || [ "$secret" != 1 ] || [ -z "$ED_VALUE" ]; then shown="$ED_VALUE"; else shown="$ENVEDIT_MASK"; fi
      if [ "$json" -eq 1 ]; then
        [ "$first" -eq 1 ] || printf ',\n'
        first=0
        printf '    {"file": "%s", "key": "%s", "value": "%s", "secret": %s, "state": "%s", "required": %s, "validator": "%s", "generator": "%s"}' \
          "$(ui_json_escape "$f")" "$key" "$(ui_json_escape "$shown")" "$([ "$secret" = 1 ] && echo true || echo false)" "$ED_STATE" \
          "$([ "${ENV_REQUIRED[$id]:-0}" = 1 ] && echo true || echo false)" "${ENV_VALIDATOR[$id]:-text}" "${ENV_GEN[$id]:-}"
      else
        case "$ED_STATE" in
          ok) kind=ok ;;
          warn) kind=warn ;;
          missing | invalid | example) kind=err ;;
          *) kind=dim ;;
        esac
        label="$(env_state_label "$ED_STATE")"
        if [ -z "$shown" ]; then
          if [ "$ED_STATE" = default ]; then shown="(${ENV_DEFAULT[$id]})"; else shown="-"; fi
        fi
        ui_tr "$w" "$key" "$shown" "$kind:$label"
      fi
    done
  done
  if [ "$json" -eq 1 ]; then
    printf '\n  ]\n}\n'
  else
    printf '\n'
    if [ "${#pend[@]}" -gt 0 ]; then warn "$(t env.pending_some "$inst" "${pend[*]}")"; fi
    info "$(t env.list_hint "$inst")"
  fi
}

# ---------- get ----------

env_get() { # instance target reveal
  local inst="$1" reveal="$3"
  env_resolve "$inst" "$2"
  local f="$TARGET_FILE" key="$TARGET_KEY" path
  path="$INSTANCES_DIR/$inst/$f"
  envschema_load
  get_var_r "$path" "$key"
  if [ -z "$GV" ]; then
    # present and empty is fine; absent is a failure that scripts can tell apart
    local present=0 line
    while IFS= read -r line || [ -n "$line" ]; do [[ "$line" == "$key="* ]] && present=1; done < "$path"
    if [ "$present" -eq 0 ]; then
      warn "$(t env.get_unset "$key" "$f")"
      return 1
    fi
    printf '\n'
    return 0
  fi
  if [ "$reveal" -ne 1 ] && envedit_is_secret "$f" "$key"; then
    printf '%s\n' "$ENVEDIT_MASK"
    info "$(t env.secret_hidden "$key" "$inst" "$(envedit_word "$f"):$key")" >&2
    return 0
  fi
  printf '%s\n' "$GV"
}

# ---------- set ----------

# A value written while an operation (a deploy, a rollback) is running may not be in what that operation starts: say so.
env_warn_busy() {
  if runs_busy; then warn "$(t env.busy "${RUNS_OWNER_WHAT:-?}")"; fi
  return 0
}

env_set() { # instance target value have_value stdin force
  local inst="$1" value="$3" have="$4" use_stdin="$5" force="$6" rc=0 secret shown typed=0
  env_resolve "$inst" "$2"
  local f="$TARGET_FILE" key="$TARGET_KEY"
  envschema_load
  if [ "$use_stdin" -eq 1 ]; then
    # All of the standard input, not its first line: a value with a line break (a PEM) is then refused, not cut in silence.
    IFS= read -r -d '' value || true
    value="${value%$'\n'}"
    value="${value%$'\r'}"
    have=1
  fi
  secret=0
  ! envedit_is_secret "$f" "$key" || secret=1
  if [ "$have" -eq 0 ]; then
    # Without a value: a secret is asked for hidden (nothing is left on the screen or in the history); anything else is a usage error.
    if [ -t 0 ] && [ "$secret" = 1 ]; then
      read -rs -p "$(t env.prompt_secret "$key")" value
      printf '\n'
      have=1 typed=1
    fi
  fi
  [ "$have" -eq 1 ] || die "$(t env.set_value_missing "$inst" "$key")"
  # A secret on the command line stays in `ps` and in the history of the shell.
  if [ "$secret" = 1 ] && [ "$use_stdin" -eq 0 ] && [ "$typed" -eq 0 ]; then warn "$(t env.argv_secret "$(envedit_word "$f"):$key")"; fi
  env_warn_busy
  envedit_save "$inst" "$f" "$key" "$value" "$force" || rc=$?
  case "$rc" in
    1) die "$(t env.refused "$key" "$EV_MSG")" ;;
    2) die "$(t env.write_failed "$f")" ;;
  esac
  # The message of a warning (or of a forced invalid value) never carries the value.
  if [ "$EV_RC" = 1 ]; then warn "$(t env.forced_invalid "$key" "$EV_MSG")"
  elif [ "$EV_RC" = 2 ]; then warn "$(t env.warn_value "$key" "$EV_MSG")"; fi
  if [ "$secret" = 1 ]; then ok "$(t env.saved_masked "$key" "$f")"; else shown="$value"; ok "$(t env.saved "$key=$shown" "$f")"; fi
  info "$(t env.apply_hint "$inst")"
}

# ---------- generate ----------

env_generate() { # instance target
  local inst="$1" kind f key cur rc=0 files msg where sf
  env_resolve "$inst" "$2"
  f="$TARGET_FILE" key="$TARGET_KEY"
  envschema_load
  kind="$(envschema_generator "$f" "$key")"
  [ -n "$kind" ] || die "$(t env.no_generator "$key")"
  command -v openssl > /dev/null 2>&1 || die "$(t env.openssl_missing)"
  get_var_r "$INSTANCES_DIR/$inst/$f" "$key"
  cur="$GV"
  where="$f"
  files="$f"
  if [ "$kind" = shared ]; then
    envedit_shared_files_r "$inst" "$key"
    files="${ENVEDIT_SHARED[*]}"
    # A shared secret is written in every file that has it: a value in ANY of them is replaced, not only the one that was named.
    for sf in "${ENVEDIT_SHARED[@]}"; do
      get_var_r "$INSTANCES_DIR/$inst/$sf" "$key"
      if [ -n "$GV" ]; then cur="$GV"; where="$sf"; break; fi
    done
  fi
  if [ -n "$cur" ]; then
    msg="$(t env.gen_replace "$key" "$where")"
    [ "$kind" != shared ] || msg+=" $(t env.gen_replace_shared "$files")"
    [ "$kind" != b64-32 ] || msg+=" $(t env.gen_replace_data)"
    warn "$msg"
    confirm "$(t env.gen_confirm "$key")" || { info "$(t env.gen_cancelled)"; return 0; }
  fi
  env_warn_busy
  envedit_generate "$inst" "$f" "$key" || rc=$?
  case "$rc" in
    1) die "$(t env.openssl_missing)" ;;
    2) die "$(t env.write_failed "$f")" ;;
  esac
  ok "$(t env.generated "$key" "${ENVEDIT_WRITTEN[*]}")"
  info "$(t env.apply_hint "$inst")"
}

# ---------- pending ----------

env_pending() { # instance
  local inst="$1" f pend=() unknown=()
  envedit_files_r "$inst"
  for f in "${ENVEDIT_FILES[@]}"; do
    envedit_deploy_state_r "$inst" "$f"
    case "$ED_DEPLOY" in
      pending) pend+=("$f") ;;
      unknown) unknown+=("$f") ;;
    esac
  done
  if [ "${#pend[@]}" -gt 0 ]; then
    info "$(t env.pending_some "$inst" "${pend[*]}")"
  elif [ "${#unknown[@]}" -gt 0 ]; then
    info "$(t env.pending_unknown "${unknown[*]}")"
  else
    info "$(t env.pending_none "$inst")"
  fi
}

# ---------- sync ----------

# The variables of the templates that the files of the instance do not have (and the ones the templates no longer know), and, with --apply,
# writing the new ones at the end of each file. It only adds: no value that is there changes and nothing is deleted.
env_sync() { # instance target apply json
  local inst="$1" target="$2" apply="$3" json="$4" f k row named="" total=0 first=1 req st left miss
  local -a files=() out=()
  if [ -n "$target" ]; then
    f="$(envschema_file_name "$target")" || die "$(t env.file_unknown "$target" "instance ${KNOWN_SERVICES[*]}")"
    [ -f "$INSTANCES_DIR/$inst/$f" ] || die "$(t env.file_absent "$inst" "$f")"
    files=("$f") named=named
  else
    envedit_files_r "$inst"
    files=("${ENVEDIT_FILES[@]}")
  fi
  [ "$json" -eq 0 ] || printf '{"instance": "%s", "files": [' "$inst"
  for f in "${files[@]}"; do
    if [ "$apply" -eq 1 ]; then
      envsync_apply "$inst" "$f" "$named" || die "$(t env.sync.write_failed "$f")"
      out=("${ENVSYNC_ADDED[@]}")
    else
      envsync_r "$inst" "$f" "$named" || continue
      out=("${ENVSYNC_NEW[@]}")
    fi
    if [ "$json" -eq 1 ]; then
      [ "$first" -eq 1 ] || printf ', '
      first=0
      printf '{"file": "%s", "new": [' "$f"
      row=""; for k in "${out[@]}"; do row+="${row:+, }\"$k\""; done; printf '%s], "obsolete": [' "$row"
      row=""; for k in ${ENVSYNC_OBSOLETE[@]+"${ENVSYNC_OBSOLETE[@]}"}; do row+="${row:+, }\"$k\""; done; printf '%s]}' "$row"
      total=$((total + ${#out[@]}))
      continue
    fi
    if [ "${#out[@]}" -gt 0 ]; then
      [ "$total" -gt 0 ] || { [ "$apply" -eq 1 ] || info "$(t env.sync.head "$inst")"; }
      total=$((total + ${#out[@]}))
      row=""
      for k in "${out[@]}"; do
        req=""
        [ "${ENV_REQUIRED[$f|$k]:-0}" != 1 ] || req=" ($(t env.sync.required))"
        row+="${row:+, }$k$req"
      done
      if [ "$apply" -eq 1 ]; then ok "$(t env.sync.applied "$f" "${#out[@]}" "$row")"; else info "  $(printf '%-14s' "$f") $(t env.sync.file_row "${#out[@]}" "$row")"; fi
    fi
    if [ "$apply" -eq 0 ] && [ "${#ENVSYNC_OBSOLETE[@]}" -gt 0 ]; then
      row=""; for k in "${ENVSYNC_OBSOLETE[@]}"; do row+="${row:+, }$k"; done
      info "  $(printf '%-14s' "$f") $(t env.sync.obsolete "$row")"
    fi
    if [ "$apply" -eq 1 ] && [ "${#out[@]}" -gt 0 ]; then
      miss=""
      for k in "${out[@]}"; do
        envedit_state_r "$inst" "$f" "$k"
        case "$ED_STATE" in missing | example) miss+="${miss:+, }$k" ;; esac
      done
      [ -z "$miss" ] || info "  $(t env.sync.todo "$miss" "$inst" "${f#.env.}")"
    fi
  done
  if [ "$json" -eq 1 ]; then printf '], "total": %s}\n' "$total"; return 0; fi
  if [ "$total" -eq 0 ]; then
    info "$(t env.sync.none "$inst")"
  elif [ "$apply" -eq 1 ]; then
    info "$(t env.sync.backup)"
    info "$(t env.sync.deploy_note "$inst")"
  else
    info ""
    info "$(t env.sync.hint "$inst")"
  fi
}


cmd_env() {
  local inst="${1:-}" sub="${2:-list}" a
  [ -n "$inst" ] || die "$(t env.usage)"
  shift
  [ "$#" -eq 0 ] || shift
  require_instance "$inst"
  envschema_load

  local reveal=0 json=0 use_stdin=0 force=0 have_value=0 value="" target="" dashdash=0 apply=0
  parse_yes "$@"   # --yes / -y: sets ASSUME_YES for confirm; the rest is in ARGS
  for a in ${ARGS[@]+"${ARGS[@]}"}; do
    if [ "$dashdash" -eq 1 ]; then
      if [ -z "$target" ]; then target="$a"; elif [ "$have_value" -eq 0 ]; then value="$a" have_value=1; else die "$(t env.extra_arg "$a")"; fi
      continue
    fi
    case "$a" in
      --) dashdash=1 ;;
      --reveal) reveal=1 ;;
      --json) json=1 ;;
      --stdin) use_stdin=1 ;;
      --force) force=1 ;;
      --apply) apply=1 ;;
      -*) die "$(t env.unknown_option "$a")" ;;
      *)
        if [ -z "$target" ]; then target="$a"
        elif [ "$have_value" -eq 0 ] && [ "$sub" = set ]; then value="$a" have_value=1
        else die "$(t env.extra_arg "$a")"; fi
        ;;
    esac
  done

  case "$sub" in
    list) env_list "$inst" "$target" "$reveal" "$json" ;;
    get | set | generate)
      [ -n "$target" ] || die "$(t env.key_missing "$inst" "$sub")"
      # KEY=value is the same as KEY value
      if [ "$sub" = set ] && [ "$have_value" -eq 0 ] && [[ "$target" == *=* ]]; then
        value="${target#*=}"
        target="${target%%=*}"
        have_value=1
      fi
      case "$sub" in
        get) env_get "$inst" "$target" "$reveal" ;;
        set) env_set "$inst" "$target" "$value" "$have_value" "$use_stdin" "$force" ;;
        generate) env_generate "$inst" "$target" ;;
      esac
      ;;
    pending) env_pending "$inst" ;;
    sync) env_sync "$inst" "$target" "$apply" "$json" ;;
    *) die "$(t env.unknown_sub "$sub")" ;;
  esac
}

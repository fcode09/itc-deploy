#!/usr/bin/env bash
# ./deltactl secret list|check <instance>     ./deltactl secret add <instance> <variable|file> <path> [--force]
# The files of instances/<name>/secrets/ that the services read (the Firebase JSON of the push notifications: FCM_CERT=/run/secrets/fcm.json).
# `list` shows which ones the instance needs and whether each one is there; `check` is the same and fails when one is missing or is not a JSON
# object; `add` takes a file of THIS machine (the person puts it on the server and gives the path) and puts it where the variable says, with
# mode 600. Nothing here prints what is inside a file. The panel's Variables editor (key `f`) runs `secret add`.

secret_usage() { die "$(t secret.usage)"; }

# Why a file is not valid, as a message (the key depends on the reason, so it goes through t_r: the scan of the keys in use skips it).
secret_err() { # reason path
  t_r "secret.err_$1" "$2"
  printf '%s' "$T_OUT"
}

# The instance named by the argument: it must be a valid name and exist.
secret_instance() { # name
  valid_instance_name "${1:-}" && [ -d "$INSTANCES_DIR/$1" ] || die "$(t secret.no_instance "${1:-}")"
}

# The table of what the instance needs. Returns 1 when something is missing or is not valid.
secret_table() { # instance
  local row s var name st word bad=0
  sf_needs_r "$1"
  if [ "${#SF_NEED[@]}" -eq 0 ]; then info "$(t secret.none "$1")"; return 0; fi
  info "$(t secret.title "$1")"
  for row in "${SF_NEED[@]}"; do
    IFS='|' read -r s var name <<< "$row"
    sf_state_r "$1" "$name" || true
    case "$SF_ST" in
      ok) st=ok word="$(t secret.state_ok)" ;;
      invalid) st=err word="$(secret_err "$SF_WHY" "secrets/$name")"; bad=1 ;;
      *) st=warn word="$(t secret.state_missing)"; bad=1 ;;
    esac
    printf '  %s %-18s %-4s %-20s %s\n' "$(ui_sym "$st")" "$name" "$s" "$var" "$word"
  done
  [ "$bad" -eq 0 ]
}

secret_list() { # instance
  [ "$#" -eq 1 ] || secret_usage
  secret_instance "$1"
  secret_table "$1" || info "$(t secret.how_add "$1")"
  return 0
}

secret_check() { # instance
  [ "$#" -eq 1 ] || secret_usage
  secret_instance "$1"
  if secret_table "$1"; then return 0; fi
  info "$(t secret.how_add "$1")"
  return 1
}

secret_add() { # instance target path [--force]
  local name="" target="" src="" force=0 a row s var file found="" dir list=""
  while [ "$#" -gt 0 ]; do
    a="$1"
    case "$a" in
      --force) force=1 ;;
      -*) die "$(t new.unknown_option "$a")" ;;
      *)
        if [ -z "$name" ]; then name="$a"; elif [ -z "$target" ]; then target="$a"; elif [ -z "$src" ]; then src="$a"; else secret_usage; fi
        ;;
    esac
    shift
  done
  [ -n "$name" ] && [ -n "$target" ] && [ -n "$src" ] || secret_usage
  secret_instance "$name"
  dir="$INSTANCES_DIR/$name"
  # What the instance needs: the target is the variable (FCM_CERT) or the name of the file (fcm.json); anything else is a typo, and it is said.
  sf_needs_r "$name"
  [ "${#SF_NEED[@]}" -gt 0 ] || die "$(t secret.none "$name")"
  for row in "${SF_NEED[@]}"; do
    IFS='|' read -r s var file <<< "$row"
    list+="${list:+, }$var ($file)"
    if [ "$target" = "$var" ] || [ "$target" = "$file" ]; then found="$file"; break; fi
  done
  [ -n "$found" ] || die "$(t secret.unknown_target "$target" "$name" "$list")"
  sf_expand "$src"
  src="$SF_PATH"
  sf_check "$src" || die "$(secret_err "$SF_WHY" "$src")"
  if [ -e "$dir/secrets/$found" ]; then
    if [ "$src" -ef "$dir/secrets/$found" ]; then die "$(t secret.same "$found")"; fi
    [ "$force" -eq 1 ] || die "$(t secret.exists "$found")"
  fi
  [ -d "$dir/secrets" ] || mkdir -m 700 -p "$dir/secrets" || die "$(t secret.copy_failed "$found")"
  sf_install "$src" "$dir" "$found" || die "$(t secret.copy_failed "$found")"
  ok "$(t secret.added "$found" "$name")"
  info "$(t secret.next_deploy "$name")"
}

cmd_secret() {
  local sub="${1:-}"
  [ "$#" -eq 0 ] || shift
  case "$sub" in
    list) secret_list "$@" ;;
    check) secret_check "$@" ;;
    add) secret_add "$@" ;;
    "") secret_usage ;;
    *) die "$(t secret.unknown_sub "$sub")" ;;
  esac
}

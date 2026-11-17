#!/usr/bin/env bash
# ./deltactl init <instance> [--yes]: seeds the initial data of a NEW instance, only once.
# ./deltactl adopt <instance>: marks as initialized an instance that ALREADY has data (it seeds nothing).
#
# The seeds are DESTRUCTIVE: they drop collections, and the s0 seed tells s1, over TCP, to empty its users
# table. That is why init refuses to run if there is a marker or data already, and has no --force.
#
# Sequence (verified with real containers):
#   1. seed of s1 (catalogs)               2. start s1 and wait for healthy (it must be UP for the s0 seed)
#   3. seed of s0: populating_data_s0 (empties the users of s1 and sends them again), create_root_user,
#      url_systems                          4. start s0
# The seeds always exit with code 0 even when they fail: their log is read.

# cmd_deploy comes from deploy.sh
source "$ROOT/lib/cmd/deploy.sh"

MIN_STEPS_S1=30
MIN_STEPS_S0=17
SEED_OUT=""
SEED_LOG=""

# Counts the documents of a collection with a one-off container (uses the image's own mongoose).
count_docs() { # instance service uri_variable collection
  local name="$1" svc="$2" uri_var="$3" coll="$4" dir ref out
  dir="$(instance_dir "$name")"
  ref="$(service_image_ref "$name" "$svc")"
  out="$(dk_run_once "$dir/.env.$svc" "$ref" -- node -e '
    const m = require("mongoose");
    (async () => {
      const uri = process.env[process.argv[1]], coll = process.argv[2];
      await m.connect(uri, { serverSelectionTimeoutMS: 8000 });
      console.log("COUNT=" + await m.connection.db.collection(coll).countDocuments());
      await m.disconnect();
    })().catch((e) => { console.log("ERR=" + e.message); process.exit(2); });
  ' "$uri_var" "$coll" 2>&1)" || true
  if [[ "$out" =~ COUNT=([0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf 'ERR'
    warn "$(t init.count_failed "$svc" "$uri_var" "$(printf '%s' "$out" | grep -a 'ERR=' | head -1)")"
  fi
}

# Runs a command of an image's CLI in a one-off container. It leaves the log in SEED_OUT/SEED_LOG.
run_seed() { # instance service network|- command...
  local name="$1" svc="$2" net="$3" dir ref
  shift 3
  dir="$(instance_dir "$name")"
  ref="$(service_image_ref "$name" "$svc")"
  local -a extra=()
  [ "$net" = "-" ] || extra+=(--network "$net")
  [ "$svc" != "s1" ] || extra+=(-v "$dir/secrets:/run/secrets:ro")
  mkdir -p "$dir/init-logs"
  SEED_LOG="$dir/init-logs/$(date -u +%Y%m%dT%H%M%SZ)-$svc-$1.log"
  SEED_OUT="$(dk_run_once "$dir/.env.$svc" "$ref" ${extra[@]+"${extra[@]}"} -- node dist/cli.js "$@" 2>&1)" || true
  printf '%s\n' "$SEED_OUT" > "$SEED_LOG"
  chmod 600 "$SEED_LOG"
}

# The phrases below are what the seeds themselves print (they are English, typo included).
seed_steps() { printf '%s\n' "$SEED_OUT" | grep -acE 'populated|has been created|initial data' || true; }
seed_errors() { printf '%s\n' "$SEED_OUT" | grep -ac 'Ocurred an error' || true; }

fail_incomplete() { # step reason
  warn "$(t init.incomplete "$1" "$2")"
  warn "$(t init.full_log "$SEED_LOG")"
  die "$(t init.not_marked)"
}

# Verifies a seed: without 'Ocurred an error', with at least N steps and, if asked, with a given phrase.
check_seed() { # step minimum_steps [required_phrase]
  local step="$1" min="$2" must="${3:-}" errs steps
  errs="$(seed_errors)"
  steps="$(seed_steps)"
  [ "$errs" -eq 0 ] || fail_incomplete "$step" "$(t init.err_in_log "$errs")"
  [ "$steps" -ge "$min" ] || fail_incomplete "$step" "$(t init.few_steps "$steps" "$min")"
  if [ -n "$must" ] && ! printf '%s\n' "$SEED_OUT" | grep -aq "$must"; then
    fail_incomplete "$step" "$(t init.missing_phrase "$must")"
  fi
  info "$(t init.step_ok "$step" "$steps")"
}

cmd_init() {
  parse_yes "$@"
  local name="${ARGS[0]:-}"
  require_instance "$name"
  local dir s have0=0 have1=0
  dir="$(instance_dir "$name")"
  # The internal deploys of init must not warn that the instance "is not initialized".
  export DELTACTL_SUPPRESS_INIT_WARN=1

  select_services "$name"
  for s in "${ENABLED[@]}"; do
    [ "$s" != "s0" ] || have0=1
    [ "$s" != "s1" ] || have1=1
  done
  [ "$have0" -eq 1 ] && [ "$have1" -eq 1 ] \
    || die "$(t init.needs_both "$name")$(see services)"

  if [ -f "$(marker_file "$name")" ]; then
    die "$(t init.already "$name" "$(get_var "$(marker_file "$name")" SOURCE)" "$(get_var "$(marker_file "$name")" INITIALIZED_AT)")"
  fi

  check_docker
  preflight "$name" s0 s1
  check_images "$name" s0 s1

  info "$(t init.checking_empty)"
  local n_auth n_gue
  n_auth="$(count_docs "$name" s0 MONGO_URI usuarios)"
  n_gue="$(count_docs "$name" s1 MONGO_DELTA_DISPATCH_URI users)"
  [ "$n_auth" != "ERR" ] && [ "$n_gue" != "ERR" ] || die "$(t init.mongo_unreachable)$(see troubleshooting)"
  if [ "$n_auth" -gt 0 ] || [ "$n_gue" -gt 0 ]; then
    die "$(t init.has_data "$name" "$n_auth" "$n_gue")$(see existing-instance)"
  fi

  info "$(t init.will_seed "$name")"
  confirm "$(t prompt.continue)" || die "$(t err.cancelled)"

  info "$(t init.step1)"
  run_seed "$name" s1 - populating_data_s1
  check_seed "populating_data_s1" "$MIN_STEPS_S1"

  info "$(t init.step2)"
  cmd_deploy "$name" s1

  info "$(t init.step3)"
  run_seed "$name" s0 "${name}_net" populating_data_s0
  if printf '%s\n' "$SEED_OUT" | grep -aq 'GUEP SERVER IS DOWN'; then
    fail_incomplete "populating_data_s0" "$(t init.s0_unreachable)"
  fi
  check_seed "populating_data_s0" "$MIN_STEPS_S0"
  run_seed "$name" s0 "${name}_net" create_root_user
  check_seed "create_root_user" 0 "Root user created"
  run_seed "$name" s0 "${name}_net" url_systems "$(get_var "$dir/.env.s0" IP_SERVER)"
  check_seed "url_systems" 0 "Url of server has created successfully"

  info "$(t init.step4)"
  cmd_deploy "$name" s0

  local a_after g_after
  a_after="$(count_docs "$name" s0 MONGO_URI usuarios)"
  g_after="$(count_docs "$name" s1 MONGO_DELTA_DISPATCH_URI users)"
  [ "$g_after" != "ERR" ] && [ "$g_after" -gt 0 ] \
    || warn "$(t init.gue_no_users "$g_after")$(see network)"

  write_marker "$name" init
  ok "$(t init.done "$name" "$a_after" "$g_after" "$dir")"
  warn "$(t init.fixed_passwords)"
}

cmd_adopt() {
  local name="${1:-}"
  require_instance "$name"
  if [ -f "$(marker_file "$name")" ]; then
    die "$(t adopt.already "$name" "$(get_var "$(marker_file "$name")" SOURCE)")"
  fi
  write_marker "$name" existing
  ok "$(t adopt.done "$name")"
}

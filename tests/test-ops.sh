#!/usr/bin/env bash
# Operation results: a failed step must never end as a success (deploy pull/up, init seeds and verification, atomic state files).
# Uses the simulated `docker` (tests/fake-docker.sh), which can be told to fail per command; it never starts anything.
# Run it from the root of the isolated copy (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS

FIX="$(mktemp -d)"
export FIX
cleanup() { rm -rf "$FIX" instances/op-*; }
trap cleanup EXIT
rm -rf instances/op-*
mkdir -p "$FIX/bin"
: > "$FIX/images.txt"; : > "$FIX/calls.log"
cp tests/fake-docker.sh "$FIX/bin/docker"
chmod +x "$FIX/bin/docker"
export PATH="$FIX/bin:$PATH"

image() { printf '%s|%s|%s\n' "$1" "$2" "${3:-amd64}" >> "$FIX/images.txt"; }
calls() { cat "$FIX/calls.log"; }
reset_fix() { : > "$FIX/calls.log"; rm -f "$FIX"/fail_* "$FIX"/seed_* "$FIX"/count_* "$FIX/no_users_after" "$FIX/mongo_fail"; }
newinst() { # name [registry]
  bash ./deltactl new "$1" >/dev/null 2>&1
  fill_instance "instances/$1" 1.0 2.0
  NEXTP=$((${NEXTP:-29100} + 10))
  sed -i -e "s/^S0_PORT=.*/S0_PORT=$NEXTP/" -e "s/^S1_PORT=.*/S1_PORT=$((NEXTP + 1))/" -e "s/^ROBIN_PORT=.*/ROBIN_PORT=$((NEXTP + 2))/" "instances/$1/.env.instance"
  [ -z "${2:-}" ] || sed -i "s/^REGISTRY=.*/REGISTRY=$2/" "instances/$1/.env.instance"
}
marker_source() { grep -E '^SOURCE=' "instances/$1/.initialized" 2>/dev/null | cut -d= -f2; }

image backend-s0:1.0 sha256:aaaa1111 amd64; image backend-s1:2.0 sha256:bbbb2222 amd64

section "1. deploy: a failed pull stops the deployment"
newinst op-reg reg.test
reset_fix
out="$(bash ./deltactl deploy op-reg 2>&1)"; rc=$?
check "baseline: pull, then up, then it is registered as deployed" 'calls | grep -n "COMPOSE" | grep -q "COMPOSE pull" && calls | grep -q "COMPOSE up" && [ "$(grep -E "^S0_TAG=" instances/op-reg/.deployed | cut -d= -f2)" = "1.0" ] && [ "$rc" -eq 0 ]'
rm -f instances/op-reg/.deployed
reset_fix; echo 23 > "$FIX/fail_pull"
out="$(bash ./deltactl deploy op-reg 2>&1)"; rc=$?
check "pull=23 makes the deploy fail" '[ "$rc" -ne 0 ]'
check "pull=23 never calls up" '! calls | grep -q "COMPOSE up"'
deployed_tag() { grep -E '^S0_TAG=' "instances/$1/.deployed" 2>/dev/null | cut -d= -f2; }   # record_previous leaves an empty .deployed
check "pull=23 is not recorded as a deployment" '[ -z "$(deployed_tag op-reg)" ]'
check "the error mentions the real exit code" 'echo "$out" | grep -q "23"'
reset_fix; echo 1 > "$FIX/fail_up"
bash ./deltactl deploy op-reg >/dev/null 2>&1; rc=$?
check "up failing is not recorded either" '[ "$rc" -ne 0 ] && [ -z "$(deployed_tag op-reg)" ]'

section "2. deploy never seeds"
newinst op-exist
bash ./deltactl adopt op-exist >/dev/null 2>&1
reset_fix
bash ./deltactl deploy op-exist >/dev/null 2>&1; rc=$?
check "deploy of an adopted instance succeeds" '[ "$rc" -eq 0 ]'
check "deploy does not run any seed" '! calls | grep -q "dist/cli.js"'

section "3. init: happy path"
newinst op-init
reset_fix
out="$(bash ./deltactl init op-init --yes 2>&1)"; rc=$?
check "init succeeds with a verified result" '[ "$rc" -eq 0 ] && [ "$(marker_source op-init)" = "init" ]'
check "the four seeds run in order" '[ "$(calls | grep -o "dist/cli.js [a-z_0-9]*" | awk "{ print \$2 }" | tr "\n" " ")" = "populating_data_s1 populating_data_s0 create_root_user url_systems " ]'
check "init is refused once it is done" 'bash ./deltactl init op-init --yes 2>&1 | grep -q "ya está inicializada"'

section "4. init: failed seeds are never accepted"
newinst op-s1
reset_fix; echo 23 > "$FIX/seed_rc_populating_data_s1"
out="$(bash ./deltactl init op-s1 --yes 2>&1)"; rc=$?
check "seed exit code 23 fails even with every success marker printed" '[ "$rc" -ne 0 ]'
check "the exit code is reported" 'echo "$out" | grep -q "23"'
check "nothing is started after the failed seed" '! calls | grep -q "COMPOSE up"'
check "the instance stays protected as incomplete" '[ "$(marker_source op-s1)" = "init-incomplete" ]'
newinst op-sem
reset_fix; printf 'Ocurred an error: boom\nOcurred an error: again\n' > "$FIX/seed_out_populating_data_s1"
out="$(bash ./deltactl init op-sem --yes 2>&1)"; rc=$?
check "exit 0 with an error in the log still fails" '[ "$rc" -ne 0 ] && [ "$(marker_source op-sem)" = "init-incomplete" ]'
newinst op-few
reset_fix; echo "one step populated" > "$FIX/seed_out_populating_data_s1"
bash ./deltactl init op-few --yes >/dev/null 2>&1; rc=$?
check "too few steps still fails" '[ "$rc" -ne 0 ] && [ "$(marker_source op-few)" = "init-incomplete" ]'

section "5. init: the final verification is mandatory"
newinst op-nou
reset_fix; : > "$FIX/no_users_after"
out="$(bash ./deltactl init op-nou --yes 2>&1)"; rc=$?
check "no users after the seeds is a failure, not a warning" '[ "$rc" -ne 0 ]'
check "it is protected as incomplete, never as initialized" '[ "$(marker_source op-nou)" = "init-incomplete" ]'

section "6. init: an incomplete init is never repeated"
reset_fix
out="$(bash ./deltactl init op-s1 --yes 2>&1)"; rc=$?
check "init refuses to run again over an incomplete one" '[ "$rc" -ne 0 ] && echo "$out" | grep -qi "incompleta"'
check "no seed ran on the refused attempt" '! calls | grep -q "dist/cli.js"'
check "adopt does not overwrite the incomplete marker" 'bash ./deltactl adopt op-s1 >/dev/null 2>&1; [ "$(marker_source op-s1)" = "init-incomplete" ]'
check "check reports the data state" 'bash ./deltactl check op-s1 2>&1 | grep -q "init-incomplete"'

section "7. set_var is atomic"
f="$FIX/state.env"
printf 'A=1\nB=2\n' > "$f"; chmod 640 "$f"
sv() { ROOT="$PWD" bash -c 'source lib/bootstrap.sh; set_var "$@"' _ "$@"; }
check "it updates an existing key and appends a new one" 'sv "$f" A 9 && sv "$f" C 3 && [ "$(cat "$f")" = "$(printf "A=9\nB=2\nC=3")" ]'
check "it keeps the file mode" '[ "$(stat -c %a "$f")" = "640" ]'
check "it leaves no temporary file behind" '[ "$(ls "$FIX" | grep -c "state.env\.")" -eq 0 ]'
mkdir -p "$FIX/failbin"; printf '#!/bin/sh\nexit 1\n' > "$FIX/failbin/awk"; chmod +x "$FIX/failbin/awk"
before="$(cat "$f")"
check "a failure while building the new content leaves the old file untouched" '! PATH="$FIX/failbin:$PATH" sv "$f" A 0 && [ "$(cat "$f")" = "$before" ]'

finish

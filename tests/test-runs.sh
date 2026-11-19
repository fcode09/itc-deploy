#!/usr/bin/env bash
# Recorded runs (lib/core/runs.sh) and ./deltactl runs: every operation that changes something leaves its metadata and its output,
# one operation at a time, an interrupted run is never a success, and the history can be read back.
# Uses the simulated `docker` (tests/fake-docker.sh); it never starts anything. Run it from the root of the isolated copy.
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS DELTACTL_NO_RUNS DELTACTL_RUN_ID

FIX="$(mktemp -d)"
export FIX
SLEEPER=""
cleanup() { [ -z "$SLEEPER" ] || kill "$SLEEPER" 2>/dev/null; rm -rf "$FIX" instances/rn-* instances/.deltactl; }
trap cleanup EXIT
rm -rf instances/rn-* instances/.deltactl
mkdir -p "$FIX/bin"
: > "$FIX/images.txt"; : > "$FIX/calls.log"
cp tests/fake-docker.sh "$FIX/bin/docker"
chmod +x "$FIX/bin/docker"
export PATH="$FIX/bin:$PATH"

image() { printf '%s|%s|%s\n' "$1" "$2" "${3:-amd64}" >> "$FIX/images.txt"; }
newinst() { # name [registry]
  bash ./deltactl new "$1" >/dev/null 2>&1
  fill_instance "instances/$1" 1.0 2.0
  NEXTP=$((${NEXTP:-30100} + 10))
  sed -i -e "s/^S0_PORT=.*/S0_PORT=$NEXTP/" -e "s/^S1_PORT=.*/S1_PORT=$((NEXTP + 1))/" "instances/$1/.env.instance"
  [ -z "${2:-}" ] || sed -i "s/^REGISTRY=.*/REGISTRY=$2/" "instances/$1/.env.instance"
}
STATE=instances/.deltactl
runs_n() { ls "$STATE/runs" 2>/dev/null | wc -l | tr -d ' '; }
last_run() { ls "$STATE/runs" | tail -n 1; }
mv_() { grep -E "^$2=" "$STATE/runs/$1/meta" | cut -d= -f2-; }   # value of a meta key of a run

image auth-backend:1.0 sha256:aaaa1111 amd64; image gueo-back-end:2.0 sha256:bbbb2222 amd64

section "1. a successful operation is recorded"
newinst rn-ok
check "creating an instance is an operation too" '[ "$(mv_ "$(last_run)" OP)" = "new" ] && [ "$(mv_ "$(last_run)" INSTANCE)" = "rn-ok" ] && [ "$(mv_ "$(last_run)" STATE)" = "succeeded" ]'
rm -rf "$STATE"   # from here on the history only holds the deploys of this section
out="$(bash ./deltactl deploy rn-ok 2>&1)"; rc=$?
id="$(last_run)"
check "the operation still works and prints as usual" '[ "$rc" -eq 0 ] && echo "$out" | grep -q "rn-ok"'
check "it leaves exactly one run" '[ "$(runs_n)" = "1" ]'
check "the metadata says what it was and how it ended" '[ "$(mv_ "$id" OP)" = "deploy" ] && [ "$(mv_ "$id" INSTANCE)" = "rn-ok" ] && [ "$(mv_ "$id" STATE)" = "succeeded" ] && [ "$(mv_ "$id" RC)" = "0" ]'
check "it has start, end and a duration" '[ -n "$(mv_ "$id" STARTED_AT)" ] && [ -n "$(mv_ "$id" ENDED_AT)" ] && [[ "$(mv_ "$id" DURATION_MS)" =~ ^[0-9]+$ ]]'
check "the log has what the command printed" 'grep -q "rn-ok" "$STATE/runs/$id/out.log"'
check "the index has one line with its seven fields" '[ "$(awk -F"\t" "NF == 7" "$STATE/runs.idx" | wc -l | tr -d " ")" = "1" ]'
check "the folder is private (700) and the log too (600)" '[ "$(stat -c %a "$STATE/runs/$id")" = "700" ] && [ "$(stat -c %a "$STATE/runs/$id/out.log")" = "600" ]'
check "the lock and the active marker are gone when it ends" '[ ! -d "$STATE/locks/mutation.lock" ] && [ -z "$(ls "$STATE/active" 2>/dev/null)" ]'
bash ./deltactl deploy rn-ok > /dev/null 2>&1
check "every run gets its own id" '[ "$(runs_n)" = "2" ] && [ "$(ls "$STATE/runs" | sort -u | wc -l | tr -d " ")" = "2" ]'

section "2. failures are recorded with their real code"
newinst rn-pull reg.test
reset_fix() { : > "$FIX/calls.log"; rm -f "$FIX"/fail_* "$FIX"/seed_* "$FIX"/count_* "$FIX/no_users_after"; }
reset_fix; echo 23 > "$FIX/fail_pull"
out="$(bash ./deltactl deploy rn-pull 2>&1)"; rc=$?
id="$(last_run)"
check "a failed pull is a failed run" '[ "$rc" -ne 0 ] && [ "$(mv_ "$id" STATE)" = "failed" ]'
check "the exit code of the run is the one the command returned" '[ "$(mv_ "$id" RC)" = "$rc" ]'
check "its log keeps the reason" 'grep -q "23" "$STATE/runs/$id/out.log"'
out="$(bash ./deltactl deploy rn-nope 2>/dev/null)"; rc=$?
check "the error of an operation on a missing instance is a failed run too" '[ "$rc" -ne 0 ] && [ "$(mv_ "$(last_run)" STATE)" = "failed" ]'
check "errors and messages come out together on standard output" 'echo "$out" | grep -qi "rn-nope"'
reset_fix

section "3. what is not recorded"
n="$(runs_n)"
bash ./deltactl status > /dev/null 2>&1; bash ./deltactl check rn-ok > /dev/null 2>&1; bash ./deltactl list > /dev/null 2>&1; bash ./deltactl help > /dev/null 2>&1; bash ./deltactl images > /dev/null 2>&1
check "queries leave no run" '[ "$(runs_n)" = "$n" ]'
DELTACTL_NO_RUNS=1 bash ./deltactl deploy rn-ok > /dev/null 2>&1
check "DELTACTL_NO_RUNS=1 turns the record off" '[ "$(runs_n)" = "$n" ]'
mut() { ROOT="$PWD" INSTANCES_DIR="$PWD/instances" bash -c 'source lib/bootstrap.sh; source lib/core/runs.sh; runs_is_mutation "$@" && echo yes || echo no' _ "$@"; }
check "deploy, init, rollback, load, stop, down and adopt are operations" '[ "$(for c in deploy init rollback load stop down adopt; do mut $c x; done | sort -u)" = "yes" ]'
check "new with a name is an operation, the wizard is not" '[ "$(mut new x)" = "yes" ] && [ "$(mut new)" = "no" ] && [ "$(mut new --wizard)" = "no" ] && [ "$(mut new x --wizard)" = "no" ]'
check "status, check, list, images, logs, menu, runs and help are not" '[ "$(for c in status check list images logs menu runs help doctor; do mut $c x; done | sort -u)" = "no" ]'

section "4. one operation at a time"
n="$(runs_n)"
mkdir -p "$STATE/locks/mutation.lock"
bash -c 'exec -a deltactl-fake sleep 60' &
SLEEPER=$!
printf '%s\n' "$SLEEPER" > "$STATE/locks/mutation.lock/pid"; echo "20260101T000000Z-9" > "$STATE/locks/mutation.lock/run"; echo "deploy rn-ok" > "$STATE/locks/mutation.lock/what"
out="$(bash ./deltactl deploy rn-ok 2>&1)"; rc=$?
check "a second operation is refused while another one is alive" '[ "$rc" -ne 0 ] && echo "$out" | grep -q "otra operación está en curso"'
check "the message says which operation and which run" 'echo "$out" | grep -q "deploy rn-ok" && echo "$out" | grep -q "20260101T000000Z-9"'
check "the refused operation leaves no run and does not touch the lock" '[ "$(runs_n)" = "$n" ] && [ -d "$STATE/locks/mutation.lock" ]'
kill "$SLEEPER" 2>/dev/null; SLEEPER=""
sleep 0.3
out="$(bash ./deltactl deploy rn-ok 2>&1)"; rc=$?
check "a lock whose owner is gone is taken over" '[ "$rc" -eq 0 ] && [ "$(runs_n)" = "$((n + 1))" ] && [ ! -d "$STATE/locks/mutation.lock" ]'
mkdir -p "$STATE/locks/mutation.lock"; echo 999999 > "$STATE/locks/mutation.lock/pid"
bash ./deltactl deploy rn-ok > /dev/null 2>&1; rc=$?
check "a lock with a PID that does not exist is stale too" '[ "$rc" -eq 0 ]'

section "5. an interrupted run is never a success"
mkdir -p "$STATE/runs/20260101T000000Z-1" "$STATE/active"
printf 'RUN_ID=20260101T000000Z-1\nOP=deploy\nARGS=deploy rn-ok\nINSTANCE=rn-ok\nSTATE=running\nSTARTED_AT=2026-01-01T00:00:00Z\nENDED_AT=\nDURATION_MS=\nRC=\nPID=999999\nHOST=h\nUSER=u\nVERSION=0\n' > "$STATE/runs/20260101T000000Z-1/meta"
echo 999999 > "$STATE/active/20260101T000000Z-1"
out="$(bash ./deltactl deploy rn-ok 2>&1)"
check "the next operation says it closed the dead run" 'echo "$out" | grep -q "20260101T000000Z-1" && echo "$out" | grep -q "interrumpida"'
check "its state is interrupted, with an end time and no exit code" '[ "$(mv_ 20260101T000000Z-1 STATE)" = "interrupted" ] && [ -n "$(mv_ 20260101T000000Z-1 ENDED_AT)" ] && [ "$(mv_ 20260101T000000Z-1 RC)" = "-" ]'
check "it is in the index as interrupted and its marker is gone" 'grep -q "20260101T000000Z-1.*interrupted" "$STATE/runs.idx" && [ ! -e "$STATE/active/20260101T000000Z-1" ]'

section "6. reading the history"
out="$(bash ./deltactl runs list 2>&1)"; rc=$?
check "runs list shows the runs, newest first, with their state" '[ "$rc" -eq 0 ] && echo "$out" | grep -q "deploy" && echo "$out" | grep -q "correcta" && echo "$out" | grep -q "fallida"'
check "and the interrupted one" 'echo "$out" | grep -q "interrumpida"'
check "--instance keeps only that instance" '! bash ./deltactl runs list --instance rn-pull 2>&1 | grep -q "rn-ok" && bash ./deltactl runs list --instance rn-pull 2>&1 | grep -q "rn-pull"'
check "-n limits the rows" '[ "$(bash ./deltactl runs list -n 1 2>&1 | grep -c "deploy")" = "1" ]'
check "--json is a JSON array with the fields of a run" 'j="$(bash ./deltactl runs list --json)"; echo "$j" | head -1 | grep -q "^\[" && echo "$j" | grep -q "\"state\":\"succeeded\"" && echo "$j" | grep -q "\"exit_code\":0" && echo "$j" | grep -q "\"duration_ms\":[0-9]" && echo "$j" | tail -1 | grep -q "^\]"'
check "--json has no colours and no banner" '! bash ./deltactl runs list --json | grep -q "$(printf "\033")"'
out="$(bash ./deltactl runs show last 2>&1)"; rc=$?
check "runs show last describes the newest run" '[ "$rc" -eq 0 ] && echo "$out" | grep -q "Ejecución" && echo "$out" | grep -q "rn-ok" && echo "$out" | grep -q "código de salida"'
id="$(ls "$STATE/runs" | grep -v "^20260101" | head -n 1)"
check "the start of an id is enough" 'bash ./deltactl runs show "${id:0:14}" 2>&1 | grep -q "Ejecución" || true; bash ./deltactl runs show "$id" 2>&1 | grep -q "$id"'
check "an unknown run is an error" '! bash ./deltactl runs show nope-nope >/dev/null 2>&1 && bash ./deltactl runs show nope-nope 2>&1 | grep -q "no existe la ejecución"'
check "a prefix that matches several runs is refused" 'bash ./deltactl runs show 20 2>&1 | grep -q "varias ejecuciones"'
check "runs logs prints the whole output of the run" 'bash ./deltactl runs logs "$id" | grep -q "rn-ok"'
check "--tail limits the lines" '[ "$(bash ./deltactl runs logs "$id" --tail 2 | wc -l | tr -d " ")" -le 2 ]'
check "into a pipe the log is plain text" '! bash ./deltactl runs logs "$id" | grep -q "$(printf "\033")"'
check "an unknown subcommand shows the usage" '! bash ./deltactl runs frobnicate >/dev/null 2>&1 && bash ./deltactl runs frobnicate 2>&1 | grep -q "uso: ./deltactl runs"'
rm -rf "$STATE"
check "with no history it says so" 'bash ./deltactl runs list 2>&1 | grep -q "Aún no hay ejecuciones"'
check "runs itself is not recorded" '[ ! -d "$STATE/runs" ] || [ "$(runs_n)" = "0" ]'

section "7. init is one run"
newinst rn-init
rm -rf "$STATE"
bash ./deltactl init rn-init --yes > /dev/null 2>&1; rc=$?
check "init (which deploys twice inside) is a single run" '[ "$rc" -eq 0 ] && [ "$(runs_n)" = "1" ] && [ "$(mv_ "$(last_run)" OP)" = "init" ]'

section "8. what a run consumed"
newinst rn-cons
rm -rf "$STATE"
printf 'rn-cons|auth-backend|running|none|auth-backend:1.0|2026-11-19T20:00:00Z|/rn-cons-a-1|0|0\nrn-cons|gueo-back-end|running|healthy|gueo-back-end:2.0|2026-11-19T20:00:00Z|/rn-cons-g-1|0|3\nother|x|running|none|x:1|2026-11-19T20:00:00Z|/o-1|0|9\n' > "$FIX/containers.txt"
bash ./deltactl deploy rn-cons > /dev/null 2>&1
id="$(last_run)"
check "CPU is measured in milliseconds" '[[ "$(mv_ "$id" CPU_MS)" =~ ^[0-9]+$ ]]'
check "the docker calls are counted and their time added up" '[ "$(mv_ "$id" DOCKER_CALLS)" -ge 1 ] && [[ "$(mv_ "$id" DOCKER_MS)" =~ ^[0-9]+$ ]] && [ "$(wc -l < "$STATE/runs/$id/docker.tsv" | tr -d " ")" = "$(mv_ "$id" DOCKER_CALLS)" ]'
check "compose calls are told apart by their verb" 'grep -q "compose up" "$STATE/runs/$id/docker.tsv" && ! grep -q "compose --env-file" "$STATE/runs/$id/docker.tsv"'
check "the slowest call is kept with its name" '[[ "$(mv_ "$id" DOCKER_SLOW)" =~ ^[0-9]+\|docker\ |^[0-9]+\|compose\ |^[0-9]+\|[a-z]+ ]]'
check "the size of the output is the size of the log" '[ "$(mv_ "$id" OUT_BYTES)" = "$(wc -c < "$STATE/runs/$id/out.log" | tr -d " ")" ] && [ "$(mv_ "$id" OUT_LINES)" -ge 1 ]'
check "peak memory and processes are sampled while it runs" '[ "$(mv_ "$id" PEAK_RSS_KB)" -gt 0 ] && [ "$(mv_ "$id" PEAK_PROCS)" -ge 1 ] && [ -s "$STATE/runs/$id/samples.tsv" ]'
check "the instance is looked at before and after (only its own containers)" '[[ "$(mv_ "$id" FOOT_BEFORE)" =~ ^2/2\ [0-9]+\ 3$ ]] && [[ "$(mv_ "$id" FOOT_AFTER)" =~ ^2/2\ [0-9]+\ 3$ ]]'
check "the scratch files of the measurement are gone" '[ ! -e "$STATE/runs/$id/.times0" ] && [ ! -e "$STATE/runs/$id/.times1" ]'
check "the files of a run stay private" '[ "$(stat -c %a "$STATE/runs/$id/docker.tsv")" = "600" ] && [ "$(stat -c %a "$STATE/runs/$id/samples.tsv")" = "600" ]'
check "the sampler is not left running (it is a fork of the wrapper: same command line)" '! pgrep -f "deltactl deploy rn-cons" >/dev/null 2>&1'
DELTACTL_RUN_FOOTPRINT=0 bash ./deltactl deploy rn-cons > /dev/null 2>&1
id2="$(last_run)"
check "DELTACTL_RUN_FOOTPRINT=0 skips the look at the containers" '[ -z "$(mv_ "$id2" FOOT_BEFORE)" ] && [ -z "$(mv_ "$id2" FOOT_AFTER)" ] && [[ "$(mv_ "$id2" CPU_MS)" =~ ^[0-9]+$ ]]'
bash ./deltactl stop rn-cons > /dev/null 2>&1
check "stop looks at the containers too" '[ -n "$(mv_ "$(last_run)" FOOT_BEFORE)" ]'
bash ./deltactl deploy rn-nope > /dev/null 2>&1
check "a failed run is measured as well" '[ "$(mv_ "$(last_run)" STATE)" = "failed" ] && [[ "$(mv_ "$(last_run)" CPU_MS)" =~ ^[0-9]+$ ]]'
bash ./deltactl deploy rn-cons > /dev/null 2>&1
out="$(bash ./deltactl runs show last 2>&1)"
check "runs show has the consumption" 'echo "$out" | grep -q "Consumo de la operación" && echo "$out" | grep -q "CPU " && echo "$out" | grep -q "llamadas" && echo "$out" | grep -q "memoria pico" && echo "$out" | grep -q "salida "'
check "and the containers before and after" 'echo "$out" | grep -q "Contenedores de rn-cons" && echo "$out" | grep -q "2 de 2 en marcha"'
check "and the comparison with the previous successful run" 'echo "$out" | grep -q "Frente al deploy anterior con éxito de rn-cons" && echo "$out" | grep -qE "duración +[0-9.]+ (ms|s) .* \([+-][0-9]+%\)"'
check "the comparison is the last thing, after the output" '[ "$(echo "$out" | grep -n "Salida (últimas" | cut -d: -f1)" -lt "$(echo "$out" | grep -n "Frente al" | cut -d: -f1)" ]'
out="$(DELTACTL_LANG=en bash ./deltactl runs show last 2>&1)"
check "it is translated" 'echo "$out" | grep -q "Consumption of the operation" && echo "$out" | grep -q "of one core" && echo "$out" | grep -q "Against the previous successful deploy"'
mkdir -p "$STATE/runs/20260101T000000Z-1"
printf 'RUN_ID=20260101T000000Z-1\nOP=deploy\nARGS=old\nINSTANCE=old\nSTATE=succeeded\nSTARTED_AT=2026-01-01T00:00:00Z\nENDED_AT=2026-01-01T00:00:03Z\nDURATION_MS=3000\nRC=0\n' > "$STATE/runs/20260101T000000Z-1/meta"
out="$(bash ./deltactl runs show 20260101T000000Z-1 2>&1)"; rc=$?
check "a run recorded before the measurements shows no consumption (and does not fail)" '[ "$rc" -eq 0 ] && ! echo "$out" | grep -q "Consumo de la operación" && echo "$out" | grep -q "duración"'
out="$(bash ./deltactl runs stats 2>&1)"; rc=$?
check "runs stats gives one row per kind of operation" '[ "$rc" -eq 0 ] && echo "$out" | grep -q "DURACIÓN MEDIA" && echo "$out" | grep -qE "^deploy +[0-9]+ +[0-9]+ +[0-9]+" && echo "$out" | grep -q "MEM PICO"'
check "stats counts the failed ones" 'echo "$out" | grep -E "^deploy" | awk "{ exit !(\$4 >= 1) }"'
check "stats can be narrowed to an instance" 'bash ./deltactl runs stats --instance rn-cons 2>&1 | grep -q "^deploy" && ! bash ./deltactl runs stats --instance rn-cons 2>&1 | grep -q "^new"'
check "stats with a bad option shows the usage" '! bash ./deltactl runs stats --nope >/dev/null 2>&1 && ! bash ./deltactl runs stats -n 0 >/dev/null 2>&1'
rm -f "$FIX/containers.txt"

finish

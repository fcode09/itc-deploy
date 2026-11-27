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
  sed -i -e "s/^S0_PORT=.*/S0_PORT=$NEXTP/" -e "s/^S1_PORT=.*/S1_PORT=$((NEXTP + 1))/" -e "s/^ROBIN_PORT=.*/ROBIN_PORT=$((NEXTP + 2))/" "instances/$1/.env.instance"
  [ -z "${2:-}" ] || sed -i "s/^REGISTRY=.*/REGISTRY=$2/" "instances/$1/.env.instance"
}
STATE=instances/.deltactl
runs_n() { ls "$STATE/runs" 2>/dev/null | wc -l | tr -d ' '; }
last_run() { ls "$STATE/runs" | tail -n 1; }
mv_() { grep -E "^$2=" "$STATE/runs/$1/meta" | cut -d= -f2-; }   # value of a meta key of a run

image backend-s0:1.0 sha256:aaaa1111 amd64; image backend-s1:2.0 sha256:bbbb2222 amd64

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
out="$(bash ./deltactl deploy rn-ok 2>&1)"; rc=$?
check "the next operation says it closed the dead run" 'echo "$out" | grep -q "20260101T000000Z-1" && echo "$out" | grep -q "interrumpida"'
check "its state is interrupted, with an end time and no exit code" '[ "$(mv_ 20260101T000000Z-1 STATE)" = "interrupted" ] && [ -n "$(mv_ 20260101T000000Z-1 ENDED_AT)" ] && [ "$(mv_ 20260101T000000Z-1 RC)" = "-" ]'
check "it is in the index as interrupted and its marker is gone" 'grep -q "20260101T000000Z-1.*interrupted" "$STATE/runs.idx" && [ ! -e "$STATE/active/20260101T000000Z-1" ]'

section "5b. an interrupted run blocks new operations until someone reviews it"
IR=20260101T000000Z-1
check "the operation that found the dead run is refused, and says how to go on" '[ "$rc" -ne 0 ] && echo "$out" | grep -q "nadie la ha revisado" && echo "$out" | grep -q "runs resolve $IR"'
check "the run is left pending review" '[ -f "$STATE/pending/$IR" ] && grep -q "^deploy" "$STATE/pending/$IR"'
n="$(runs_n)"; c0="$(wc -l < "$FIX/calls.log")"
out="$(bash ./deltactl deploy rn-ok 2>&1)"; rc=$?
check "the next operation is refused as well, with no run recorded and no call to docker" '[ "$rc" -ne 0 ] && echo "$out" | grep -q "nadie la ha revisado" && [ "$(runs_n)" = "$n" ] && [ "$(wc -l < "$FIX/calls.log")" = "$c0" ]'
check "any other operation is refused too, whatever the instance" '! bash ./deltactl deploy rn-pull >/dev/null 2>&1'
out="$(bash ./deltactl runs list 2>&1)"
check "runs list marks it and says that nothing runs meanwhile" 'echo "$out" | grep -q "sin revisar" && echo "$out" | grep -q "no se ejecuta ninguna operación"'
check "--json says so too" 'bash ./deltactl runs list --json | grep -q "\"pending_review\":true" && bash ./deltactl runs list --json | grep -q "\"pending_review\":false"'
out="$(bash ./deltactl runs show $IR 2>&1)"
check "runs show says it is pending, and that stopping does not undo what Docker already did" 'echo "$out" | grep -q "pendiente: ./deltactl runs resolve $IR" && echo "$out" | grep -q "no deshace lo que ya había cambiado en Docker"'
check "resolve needs an id" '! bash ./deltactl runs resolve >/dev/null 2>&1 && bash ./deltactl runs resolve 2>&1 | grep -q "uso: ./deltactl runs resolve"'
check "a run that is not pending cannot be resolved" 'id="$(ls "$STATE/runs" | grep -v "^20260101" | head -n 1)"; ! bash ./deltactl runs resolve "$id" >/dev/null 2>&1 && bash ./deltactl runs resolve "$id" 2>&1 | grep -q "no está pendiente"'
check "an unknown run is refused, and none of those mistakes resolved anything" '! bash ./deltactl runs resolve nope-nope >/dev/null 2>&1 && [ -f "$STATE/pending/$IR" ]'
out="$(bash ./deltactl runs resolve $IR --note "revisado a mano: sin cambios" 2>&1)"; rc=$?
check "resolve marks it as reviewed and removes the pending mark" '[ "$rc" -eq 0 ] && echo "$out" | grep -q "marcada como revisada" && [ ! -e "$STATE/pending/$IR" ]'
check "the review stays in its record: when, and the note" '[ -n "$(mv_ $IR RESOLVED_AT)" ] && [ "$(mv_ $IR NOTE)" = "revisado a mano: sin cambios" ]'
check "it is still an interrupted run: reviewing it does not make it a success" '[ "$(mv_ $IR STATE)" = "interrupted" ] && bash ./deltactl runs show $IR 2>&1 | grep -q "interrumpida" && bash ./deltactl runs show $IR 2>&1 | grep -q "revisada el" && bash ./deltactl runs show $IR 2>&1 | grep -q "revisado a mano"'
out="$(bash ./deltactl deploy rn-ok 2>&1)"; rc=$?
check "once reviewed, operations run again" '[ "$rc" -eq 0 ] && [ "$(runs_n)" = "$((n + 1))" ]'
check "resolve --all with nothing pending says so and is not an error" 'bash ./deltactl runs resolve --all 2>&1 | grep -q "No hay ejecuciones interrumpidas" && bash ./deltactl runs resolve --all >/dev/null 2>&1'
# two pending at once, one without a record of its own
mkdir -p "$STATE/pending"
printf 'deploy\trn-ok\n' > "$STATE/pending/20260102T000000Z-7"; printf 'stop\trn-ok\n' > "$STATE/pending/20260102T000000Z-8"
out="$(bash ./deltactl deploy rn-ok 2>&1)"; rc=$?
check "with several pending the message counts them" '[ "$rc" -ne 0 ] && echo "$out" | grep -q "2 pendiente"'
check "--all reviews every one, and then operations run" 'bash ./deltactl runs resolve --all >/dev/null 2>&1 && [ -z "$(ls "$STATE/pending" 2>/dev/null)" ] && bash ./deltactl deploy rn-ok >/dev/null 2>&1'

section "5c. a real operation that is killed is never a success"
newinst rn-kill
bash ./deltactl runs resolve --all > /dev/null 2>&1
reset_fix; echo 30 > "$FIX/slow_up"
setsid bash ./deltactl deploy rn-kill > "$FIX/kill.out" 2>&1 &
KPID=$!
for i in $(seq 1 50); do ls "$STATE/active"/* > /dev/null 2>&1 && grep -q "COMPOSE up" "$FIX/calls.log" && break; sleep 0.2; done
KID="$(last_run)"
check "while it runs it is a run in progress with its marker" '[ "$(mv_ "$KID" STATE)" = "running" ] && [ -f "$STATE/active/$KID" ]'
kill -9 -- "-$KPID" 2>/dev/null; wait "$KPID" 2>/dev/null
rm -f "$FIX/slow_up"
check "killing it leaves a record that still says running: nothing could write the end" '[ "$(mv_ "$KID" STATE)" = "running" ] && [ -z "$(mv_ "$KID" ENDED_AT)" ]'
out="$(bash ./deltactl deploy rn-kill 2>&1)"; rc=$?
check "the next operation closes it as interrupted (never succeeded), with no exit code, and refuses to go on" '[ "$(mv_ "$KID" STATE)" = "interrupted" ] && [ "$(mv_ "$KID" RC)" = "-" ] && [ "$rc" -ne 0 ] && [ -f "$STATE/pending/$KID" ]'
check "it is in the index only as interrupted" '[ "$(grep -c "^$KID" "$STATE/runs.idx")" = "1" ] && grep "^$KID" "$STATE/runs.idx" | grep -q "interrupted" && ! grep "^$KID" "$STATE/runs.idx" | grep -q "succeeded"'
check "the killed deploy did not finish: no call to docker after the kill" '[ "$(grep -c "COMPOSE up" "$FIX/calls.log")" = "1" ]'
bash ./deltactl runs resolve "$KID" --note "kill -9 de prueba" > /dev/null 2>&1
check "after reviewing it, the same deploy runs and succeeds as a new run" 'bash ./deltactl deploy rn-kill > /dev/null 2>&1 && [ "$(mv_ "$(last_run)" STATE)" = "succeeded" ] && [ "$(mv_ "$KID" STATE)" = "interrupted" ]'

section "6. reading the history"
out="$(bash ./deltactl runs list 2>&1)"; rc=$?
check "runs list shows the runs, newest first, with their state" '[ "$rc" -eq 0 ] && echo "$out" | grep -q "deploy" && echo "$out" | grep -q "correcta" && echo "$out" | grep -q "fallida"'
check "and the interrupted one" 'echo "$out" | grep -q "interrumpida"'
check "--instance keeps only that instance" '! bash ./deltactl runs list --instance rn-pull 2>&1 | grep -q "rn-ok" && bash ./deltactl runs list --instance rn-pull 2>&1 | grep -q "rn-pull"'
check "-n limits the rows" '[ "$(bash ./deltactl runs list -n 1 2>&1 | grep -c "deploy")" = "1" ]'
check "--json is a JSON array with the fields of a run" 'j="$(bash ./deltactl runs list --json)"; echo "$j" | head -1 | grep -q "^\[" && echo "$j" | grep -q "\"state\":\"succeeded\"" && echo "$j" | grep -q "\"exit_code\":0" && echo "$j" | grep -q "\"duration_ms\":[0-9]" && echo "$j" | tail -1 | grep -q "^\]"'
check "--json has no colours and no banner" '! bash ./deltactl runs list --json | grep -q "$(printf "\033")"'
out="$(bash ./deltactl runs show last 2>&1)"; rc=$?
check "runs show last describes the newest run" '[ "$rc" -eq 0 ] && echo "$out" | grep -q "Ejecución" && echo "$out" | grep -q "rn-kill" && echo "$out" | grep -q "código de salida"'
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

section "7b. an init killed in the middle of a seed is never seeded again by itself"
# The seeds drop collections: nothing may run them again on its own, not the next operation, not reviewing the run, not init.
newinst rn-ikill
reset_fix; echo 30 > "$FIX/seed_slow_populating_data_s0"
setsid bash ./deltactl init rn-ikill --yes > "$FIX/ikill.out" 2>&1 &
KPID=$!
for i in $(seq 1 50); do grep -q "dist/cli.js populating_data_s0" "$FIX/calls.log" && break; sleep 0.2; done
KID="$(last_run)"
seeds() { grep -c "dist/cli.js" "$FIX/calls.log"; }
check "it was killed in the second seed, after the first one ran" '[ "$(mv_ "$KID" OP)" = "init" ] && [ "$(seeds)" = "2" ]'
kill -9 -- "-$KPID" 2>/dev/null; wait "$KPID" 2>/dev/null
rm -f "$FIX/seed_slow_populating_data_s0"
check "the instance stays protected as incomplete" '[ "$(grep -E "^SOURCE=" instances/rn-ikill/.initialized | cut -d= -f2)" = "init-incomplete" ]'
out="$(bash ./deltactl deploy rn-ikill 2>&1)"; rc=$?
check "the next operation closes the run as interrupted and refuses to go on, without seeding" '[ "$(mv_ "$KID" STATE)" = "interrupted" ] && [ "$rc" -ne 0 ] && [ "$(seeds)" = "2" ]'
bash ./deltactl runs resolve "$KID" --note "init matado de prueba" > /dev/null 2>&1
check "reviewing the run does not seed either" '[ ! -e "$STATE/pending/$KID" ] && [ "$(seeds)" = "2" ]'
out="$(bash ./deltactl init rn-ikill --yes 2>&1)"; rc=$?
check "init refuses to run over it, and says it was left incomplete" '[ "$rc" -ne 0 ] && echo "$out" | grep -qi "incompleta" && [ "$(seeds)" = "2" ]'
bash ./deltactl deploy rn-ikill > /dev/null 2>&1
check "a deploy after it still never seeds" '[ "$(seeds)" = "2" ]'

section "8. what a run consumed"
newinst rn-cons
rm -rf "$STATE"
printf 'rn-cons|backend-s0|running|none|backend-s0:1.0|2026-11-19T20:00:00Z|/rn-cons-a-1|0|0\nrn-cons|backend-s1|running|healthy|backend-s1:2.0|2026-11-19T20:00:00Z|/rn-cons-g-1|0|3\nother|x|running|none|x:1|2026-11-19T20:00:00Z|/o-1|0|9\n' > "$FIX/containers.txt"
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

section "8. runs prune"
rm -rf "$STATE"; mkdir -p "$STATE/runs" "$STATE/active" "$STATE/pending"
# mkprune <id> [kilobytes of output] [state]
mkprune() {
  local d="$STATE/runs/$1"
  mkdir -p "$d"
  printf 'RUN_ID=%s\nOP=deploy\nARGS=x\nINSTANCE=pr-a\nSTATE=%s\nSTARTED_AT=2025-01-01T00:00:00Z\nRC=0\nDURATION_MS=1000\n' "$1" "${3:-succeeded}" > "$d/meta"
  head -c $((${2:-1} * 1024)) /dev/zero | tr '\0' x > "$d/out.log"
  printf '%s\t2025-01-01T00:00:00Z\tdeploy\tpr-a\t%s\t0\t1000\n' "$1" "${3:-succeeded}" >> "$STATE/runs.idx"
}
now_id() { date -u -d "$1" +%Y%m%dT%H%M%SZ; }
OLD1=20250101T000000Z-1; OLDP=20250102T000000Z-2; OLDA=20250103T000000Z-3; OLD4=20250104T000000Z-4
R1="$(now_id '3 hours ago')-11"; R2="$(now_id '2 hours ago')-12"; R3="$(now_id '1 hour ago')-13"
mkprune $OLD1; mkprune $OLDP 1 interrupted; mkprune $OLDA 1 running; mkprune $OLD4
mkprune $R1 600; mkprune $R2 600; mkprune $R3 600
printf 'deploy\tpr-a\n' > "$STATE/pending/$OLDP"; echo 999999 > "$STATE/active/$OLDA"
lines0="$(wc -l < "$STATE/runs.idx")"
out="$(bash ./deltactl runs prune --dry-run 2>&1)"; rc=$?
check "--dry-run lists what would go (the old ones) and says so" '[ "$rc" -eq 0 ] && echo "$out" | grep -q "Se borrarían 2 de 7" && echo "$out" | grep -q "$OLD1" && echo "$out" | grep -q "$OLD4" && echo "$out" | grep -q "más de 30 días"'
check "...without listing what it keeps" '! echo "$out" | grep -q "$OLDP" && ! echo "$out" | grep -q "$OLDA" && ! echo "$out" | grep -q "$R1"'
check "--dry-run deletes nothing and leaves the index alone" '[ "$(ls "$STATE/runs" | wc -l | tr -d " ")" = "7" ] && [ "$(wc -l < "$STATE/runs.idx")" = "$lines0" ]'
out="$(bash ./deltactl runs prune 2>&1)"; rc=$?
check "prune deletes the runs past the age limit" '[ "$rc" -eq 0 ] && echo "$out" | grep -q "Borradas 2 de 7" && [ ! -e "$STATE/runs/$OLD1" ] && [ ! -e "$STATE/runs/$OLD4" ]'
check "it keeps the recent ones, the one in progress and the unreviewed one, however old they are" '[ -d "$STATE/runs/$R1" ] && [ -d "$STATE/runs/$R3" ] && [ -d "$STATE/runs/$OLDP" ] && [ -d "$STATE/runs/$OLDA" ] && [ -f "$STATE/pending/$OLDP" ] && [ -f "$STATE/active/$OLDA" ]'
check "the index loses the deleted runs and nothing else" '! grep -q "$OLD1" "$STATE/runs.idx" && ! grep -q "$OLD4" "$STATE/runs.idx" && [ "$(wc -l < "$STATE/runs.idx")" = "$((lines0 - 2))" ] && grep -q "$R2" "$STATE/runs.idx" && grep -q "$OLDP" "$STATE/runs.idx"'
check "the history still reads after pruning" 'bash ./deltactl runs list 2>&1 | grep -q "$R3" && bash ./deltactl runs stats >/dev/null 2>&1'
out="$(bash ./deltactl runs prune 2>&1)"
check "with nothing past the limits it says so" 'echo "$out" | grep -q "No hay nada que borrar" && echo "$out" | grep -q "30 días y 1024 MB"'
out="$(bash ./deltactl runs prune --dry-run --max-mb 1 2>&1)"
check "the size limit keeps the newest runs that fit and drops the older ones, with their size" 'echo "$out" | grep -q "Se borrarían 2 de 5" && echo "$out" | grep -q "$R1" && echo "$out" | grep -q "$R2" && ! echo "$out" | grep -q "$R3" && echo "$out" | grep -qE "6[0-9]{2} KB" && echo "$out" | grep -q "pasa de 1 MB"'
bash ./deltactl runs prune --max-mb 1 > /dev/null 2>&1
check "and prune does it" '[ ! -e "$STATE/runs/$R1" ] && [ ! -e "$STATE/runs/$R2" ] && [ -d "$STATE/runs/$R3" ] && [ -d "$STATE/runs/$OLDP" ]'
check "bad options show the usage" '! bash ./deltactl runs prune --days abc >/dev/null 2>&1 && ! bash ./deltactl runs prune --max-mb >/dev/null 2>&1 && bash ./deltactl runs prune --days abc 2>&1 | grep -q "uso: ./deltactl runs prune" && ! bash ./deltactl runs prune --nope >/dev/null 2>&1'
# While an operation is running it does not delete (a dry run is only a look and is allowed).
mkprune 20250105T000000Z-5
mkdir -p "$STATE/locks/mutation.lock"
bash -c 'exec -a deltactl-fake sleep 60' &
SLEEPER=$!
printf '%s\n' "$SLEEPER" > "$STATE/locks/mutation.lock/pid"; echo "20260101T000000Z-9" > "$STATE/locks/mutation.lock/run"; echo "deploy pr-a" > "$STATE/locks/mutation.lock/what"
out="$(bash ./deltactl runs prune 2>&1)"; rc=$?
check "prune is refused while an operation runs, and deletes nothing" '[ "$rc" -ne 0 ] && echo "$out" | grep -q "hay una operación en curso" && [ -d "$STATE/runs/20250105T000000Z-5" ]'
check "a dry run is allowed then" 'bash ./deltactl runs prune --dry-run 2>&1 | grep -q "20250105T000000Z-5"'
kill "$SLEEPER" 2>/dev/null; SLEEPER=""
sleep 0.3
bash ./deltactl runs prune > /dev/null 2>&1
check "once it ends, prune works and leaves no lock behind" '[ ! -e "$STATE/runs/20250105T000000Z-5" ] && [ ! -d "$STATE/locks/mutation.lock" ]'
check "nothing in the code prunes by itself: only the runs command calls it" '! grep -rn "runs_prune" lib | grep -v "^lib/cmd/runs.sh"'
rm -rf "$STATE"

finish

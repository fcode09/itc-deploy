#!/usr/bin/env bash
# Tests of `./deltactl secret` (lib/cmd/secret.sh) and of the helpers under it (lib/core/secretfile.sh: sf_needs_r, sf_state_r, sf_expand): which files
# of secrets/ an instance needs (the variables that point to /run/secrets/...), whether each one is there, and loading one by giving its path on
# this machine: it is checked first (a JSON object), copied with mode 600, never printed, refused when it would replace another one without --force.
# Run it from the root of the isolated copy (tests/run.sh). No real Docker.
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS

FIX="$(mktemp -d)"
export FIX
cleanup() { chmod -R u+rwx instances/sc-* 2> /dev/null; rm -rf "$FIX" instances/sc-*; }
trap cleanup EXIT
rm -rf instances/sc-*
mkdir -p "$FIX/bin" "$FIX/home/up"
: > "$FIX/images.txt"; : > "$FIX/calls.log"
cp tests/fake-docker.sh "$FIX/bin/docker"
chmod +x "$FIX/bin/docker"
export PATH="$FIX/bin:$PATH"

D() { bash ./deltactl "$@"; }
run() { ROOT="$PWD" bash -c "source lib/bootstrap.sh; $1"; }
mode() { stat -c %a "$1"; }

# A service account that is a JSON object (with a marker that must never be printed), and things that are not one.
printf '{"type":"service_account","project_id":"p","private_key":"-----BEGIN PRIVATE KEY-----MARKER-ZZ"}\n' > "$FIX/home/up/fcm.json"
printf '{"type":"service_account","project_id":"q"}\n' > "$FIX/home/up/other.json"
printf 'not json at all\n' > "$FIX/home/up/text.json"
: > "$FIX/home/up/empty.json"

D new sc-a --generate-secrets > /dev/null 2>&1
D new sc-b --services s0 --generate-secrets > /dev/null 2>&1
rm -f instances/sc-a/secrets/fcm.json instances/sc-a/secrets/keeper-fcm.json

section "1. what an instance needs"
check "the files are the ones the variables point to: s1 has FCM_CERT and KEEPER_FCM_CERT" '[ "$(run "sf_needs_r sc-a; printf \"%s \" \"\${SF_NEED[@]}\"")" = "s1|FCM_CERT|fcm.json s1|KEEPER_FCM_CERT|keeper-fcm.json " ]'
check "an instance without the service that reads a file needs none" '[ "$(run "sf_needs_r sc-b; echo \${#SF_NEED[@]}")" = 0 ] && D secret list sc-b | grep -q "no necesita archivos"'
check "a variable that no longer points to /run/secrets/ is not a file to load" '
  cp instances/sc-a/.env.s1 "$FIX/s1.bak"; sed -i "s#^FCM_CERT=.*#FCM_CERT=#" instances/sc-a/.env.s1
  [ "$(run "sf_needs_r sc-a; printf \"%s \" \"\${SF_NEED[@]}\"")" = "s1|KEEPER_FCM_CERT|keeper-fcm.json " ]; rc=$?; cp "$FIX/s1.bak" instances/sc-a/.env.s1; exit $rc'
check "the state of a file: missing, ok, or invalid with the reason" '
  [ "$(run "sf_state_r sc-a fcm.json; echo \$SF_ST")" = missing ] &&
  cp "$FIX/home/up/fcm.json" instances/sc-a/secrets/fcm.json && [ "$(run "sf_state_r sc-a fcm.json; echo \$SF_ST")" = ok ] &&
  : > instances/sc-a/secrets/fcm.json && [ "$(run "sf_state_r sc-a fcm.json; echo \$SF_ST \$SF_WHY")" = "invalid empty" ]; rc=$?; rm -f instances/sc-a/secrets/fcm.json; exit $rc'
check "a name that is not valid for a file there is never loaded: it is missing" '[ "$(run "sf_state_r sc-a ../evil; echo \$SF_ST")" = missing ]'
check "~ is the home folder in a typed path" '[ "$(HOME=/h run "sf_expand ~/x.json; echo \$SF_PATH")" = /h/x.json ] && [ "$(run "sf_expand /a/~/b; echo \$SF_PATH")" = /a/~/b ]'

section "2. list and check"
out="$(D secret list sc-a 2>&1)"
check "list names each file, its service and its variable, and says it is missing" 'echo "$out" | grep -q "fcm.json .*s1 .*FCM_CERT" && echo "$out" | grep -q "keeper-fcm.json .*s1 .*KEEPER_FCM_CERT" && [ "$(echo "$out" | grep -c "falta")" -ge 2 ]'
check "list says how to load one" 'echo "$out" | grep -q "./deltactl secret add sc-a"'
check "list never fails (it is information)" 'D secret list sc-a > /dev/null 2>&1'
check "check fails while one is missing" '! D secret check sc-a > /dev/null 2>&1'
check "an instance that does not exist, or a bad name, is refused" '! D secret list nope-x > /dev/null 2>&1 && ! D secret list "../x" > /dev/null 2>&1 && D secret list nope-x 2>&1 | grep -q "no existe"'
check "without arguments, or with an unknown sub-command, it shows the usage" 'D secret 2>&1 | grep -q "uso: ./deltactl secret" && D secret frob sc-a 2>&1 | grep -q "no existe. Usa: list, check o add"'

section "3. add: the file is checked, copied with mode 600 and never printed"
out="$(D secret add sc-a FCM_CERT "$FIX/home/up/fcm.json" 2>&1)"; rc=$?
check "by the name of the variable" '[ "$rc" -eq 0 ] && cmp -s "$FIX/home/up/fcm.json" instances/sc-a/secrets/fcm.json'
check "with mode 600" '[ "$(mode instances/sc-a/secrets/fcm.json)" = 600 ]'
check "it says what it did and what comes next, and nothing of what is inside" 'echo "$out" | grep -q "secrets/fcm.json cargado en .sc-a. (permisos 600)" && echo "$out" | grep -q "deploy sc-a" && ! echo "$out" | grep -q "MARKER-ZZ\|BEGIN PRIVATE KEY"'
check "by the name of the file" 'D secret add sc-a keeper-fcm.json "$FIX/home/up/other.json" > /dev/null 2>&1 && cmp -s "$FIX/home/up/other.json" instances/sc-a/secrets/keeper-fcm.json'
check "with both there, check passes and list says they are loaded" 'D secret check sc-a > /dev/null 2>&1 && [ "$(D secret list sc-a | grep -c "cargado")" -eq 2 ] && ! D secret list sc-a | grep -q "falta"'
check "a ~ in the path is the home folder" 'rm -f instances/sc-a/secrets/fcm.json; HOME="$FIX/home" D secret add sc-a FCM_CERT "~/up/fcm.json" > /dev/null 2>&1 && cmp -s "$FIX/home/up/fcm.json" instances/sc-a/secrets/fcm.json'

section "4. add: what it refuses, and leaves as it was"
before="$(cksum < instances/sc-a/secrets/fcm.json)"
check "a second one over the first is refused without --force" '! D secret add sc-a FCM_CERT "$FIX/home/up/other.json" > /dev/null 2>&1 && [ "$(cksum < instances/sc-a/secrets/fcm.json)" = "'"$before"'" ] && D secret add sc-a FCM_CERT "$FIX/home/up/other.json" 2>&1 | grep -q "usa --force"'
check "--force replaces it, and the mode stays 600" 'D secret add sc-a FCM_CERT "$FIX/home/up/other.json" --force > /dev/null 2>&1 && cmp -s "$FIX/home/up/other.json" instances/sc-a/secrets/fcm.json && [ "$(mode instances/sc-a/secrets/fcm.json)" = 600 ]'
check "the file that is already there as the source is said, not truncated" 'before="$(cksum < instances/sc-a/secrets/fcm.json)"; ! D secret add sc-a FCM_CERT instances/sc-a/secrets/fcm.json --force > /dev/null 2>&1 && [ "$(cksum < instances/sc-a/secrets/fcm.json)" = "$before" ]'
check "what is not a JSON object, is empty, or does not exist writes nothing and says why" '
  rm -f instances/sc-a/secrets/fcm.json
  for f in text empty nope; do ! D secret add sc-a FCM_CERT "$FIX/home/up/$f.json" > /dev/null 2>&1 || exit 1; [ ! -e instances/sc-a/secrets/fcm.json ] || exit 1; done
  D secret add sc-a FCM_CERT "$FIX/home/up/text.json" 2>&1 | grep -q "no es un objeto JSON" && ! D secret add sc-a FCM_CERT "$FIX/home/up/text.json" 2>&1 | grep -q "not json at all" &&
  D secret add sc-a FCM_CERT "$FIX/home/up/empty.json" 2>&1 | grep -q "está vacío" && D secret add sc-a FCM_CERT "$FIX/home/up/nope.json" 2>&1 | grep -q "no existe"'
check "a target that the instance does not need is said, with what it needs" '! D secret add sc-a OTHER_CERT "$FIX/home/up/fcm.json" > /dev/null 2>&1 && D secret add sc-a OTHER_CERT "$FIX/home/up/fcm.json" 2>&1 | grep -q "FCM_CERT (fcm.json), KEEPER_FCM_CERT (keeper-fcm.json)"'
check "an instance with no files to load says so" '! D secret add sc-b FCM_CERT "$FIX/home/up/fcm.json" > /dev/null 2>&1 && D secret add sc-b FCM_CERT "$FIX/home/up/fcm.json" 2>&1 | grep -q "no necesita archivos" && [ ! -e instances/sc-b/secrets/fcm.json ]'
check "an unknown option or too many arguments is refused" '! D secret add sc-a FCM_CERT "$FIX/home/up/fcm.json" --nope > /dev/null 2>&1 && ! D secret add sc-a FCM_CERT "$FIX/home/up/fcm.json" extra > /dev/null 2>&1 && ! D secret add sc-a FCM_CERT > /dev/null 2>&1'
check "an invalid file in secrets/ makes check fail and says why (without its content)" '
  printf "garbage\n" > instances/sc-a/secrets/fcm.json; ! D secret check sc-a > /dev/null 2>&1 && D secret check sc-a 2>&1 | grep -q "no es un objeto JSON" && ! D secret check sc-a 2>&1 | grep -q garbage'

section "5. it is a command of the tool"
check "it is recorded as an operation when it adds, and not when it only reads" '[ "$(run "source lib/core/runs.sh; runs_is_mutation secret add sc-a X /p && echo y")" = y ] && [ -z "$(run "source lib/core/runs.sh; runs_is_mutation secret list sc-a && echo y")" ] && [ -z "$(run "source lib/core/runs.sh; runs_is_mutation secret check sc-a && echo y")" ]'
check "the instance of the record is the one after the sub-command" '[ "$(run "source lib/core/runs.sh; runs_instance_of secret add sc-a FCM_CERT /p")" = sc-a ]'
check "it has its help page in both languages" 'D help secret 2>&1 | grep -q "secret · los archivos de secrets/" && DELTACTL_LANG=en D help secret 2>&1 | grep -q "secret · the files of"'
check "the completion knows it and its option" 'D completion bash | grep -q "secret)" && D completion bash | grep -q "list check add"'

section "6. the containers run as uid 1000: a file that root copies has to belong to it"
mkdir -p "$FIX/rootbin"
printf '#!/bin/sh
if [ "$1" = "-u" ]; then echo 0; else exec /usr/bin/id "$@"; fi
' > "$FIX/rootbin/id"
printf '#!/bin/sh
echo "chown $*" >> "$FIX/chown.log"
' > "$FIX/rootbin/chown"
chmod +x "$FIX/rootbin/id" "$FIX/rootbin/chown"
check "as root the file goes to the user of the containers (a file of root with mode 600 is EACCES for them), with mode 600; as anyone else it is left alone" '
  : > "$FIX/chown.log"; rm -f instances/sc-a/secrets/fcm.json
  PATH="$FIX/rootbin:$PATH" D secret add sc-a FCM_CERT "$FIX/home/up/fcm.json" > /dev/null 2>&1 && grep -q "chown 1000:1000 .*instances/sc-a/secrets/fcm.json" "$FIX/chown.log" && [ "$(mode instances/sc-a/secrets/fcm.json)" = 600 ] || exit 1
  : > "$FIX/chown.log"; D secret add sc-a FCM_CERT "$FIX/home/up/fcm.json" --force > /dev/null 2>&1 && [ ! -s "$FIX/chown.log" ]'

finish

#!/usr/bin/env bash
# The Mongo user of an instance (one per instance, with readWrite on its databases only): how the new-instance wizard puts it in the Mongo URIs
# (lib/screens/newinst/data.sh: the user, the optional password that is generated when left empty, the URL encoding, authSource=admin) and how
# `init` creates it from what the URIs say (lib/cmd/init.sh: init_mongo_user) before reading or seeding anything: with an admin account
# (DELTACTL_MONGO_ADMIN_URI, an environment variable: never in a command line) or showing the script for whoever has it. Simulated Docker only.
# Run it from the root of the isolated copy (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS DELTACTL_MONGO_ADMIN_URI

FIX="$(mktemp -d)"
export FIX
trap 'rm -rf "$FIX" instances/mu-*' EXIT
rm -rf instances/mu-*
mkdir -p "$FIX/bin"
: > "$FIX/images.txt"; : > "$FIX/calls.log"
cp tests/fake-docker.sh "$FIX/bin/docker"
chmod +x "$FIX/bin/docker"
export PATH="$FIX/bin:$PATH"
printf 'backend-s0:1.0|sha256:aaaa1111|amd64\nbackend-s1:2.0|sha256:bbbb2222|amd64\n' > "$FIX/images.txt"

D() { bash ./deltactl "$@"; }
# A command in the library with the wizard's step of the data and the code of init loaded (the name is what the wizard would know).
lib() { ROOT="$PWD" DASH_NZ_NAME="${NZ_NAME:-ana}" bash -c "source lib/bootstrap.sh; source lib/screens/newinst/data.sh; source lib/cmd/init.sh; set +e; $1" 2>&1; }

section "1. the URIs the wizard builds"
check "a text goes into a URI percent-encoded (@ : / ? # and the like), and what is plain stays" '[ "$(lib "dash_nzm_enc \"p@ss:w/rd#?x-y_z.~\"; echo \$DASH_NZM_ENC")" = "p%40ss%3Aw%2Frd%23%3Fx-y_z.~" ]'
check "the URI carries the user, the password (encoded) and authSource=admin" '[ "$(lib "DASH_NZM_USER=ana DASH_NZM_PASS=\"p@ss\"; dash_nzm_compose mongodb://host.docker.internal:27017/authsoftware_x; echo \$DASH_NZM_URI")" = "mongodb://ana:p%40ss@host.docker.internal:27017/authsoftware_x?authSource=admin" ]'
check "a URI that has options gets it as one more" '[ "$(lib "DASH_NZM_USER=ana DASH_NZM_PASS=x; dash_nzm_compose \"mongodb://h:27017/d?retryWrites=true\"; echo \$DASH_NZM_URI")" = "mongodb://ana:x@h:27017/d?retryWrites=true&authSource=admin" ]'
check "with no user typed it is the name of the instance" '[ "$(lib "DASH_NZM_PASS=x; dash_nzm_compose mongodb://h/d; echo \$DASH_NZM_URI")" = "mongodb://ana:x@h/d?authSource=admin" ] && [ "$(NZ_NAME=colorado lib "DASH_NZM_PASS=x; dash_nzm_compose mongodb://h/d; echo \$DASH_NZM_URI")" = "mongodb://colorado:x@h/d?authSource=admin" ]'
check "with no password typed one is generated (48 hex characters), the same in every URI" '
  o="$(lib "dash_nzm_compose mongodb://h/a; a=\$DASH_NZM_URI; dash_nzm_compose mongodb://h/b; echo \$a; echo \$DASH_NZM_URI")"
  p1="$(echo "$o" | sed -n 1p | sed "s#^mongodb://ana:\([0-9a-f]*\)@.*#\1#")"; p2="$(echo "$o" | sed -n 2p | sed "s#^mongodb://ana:\([0-9a-f]*\)@.*#\1#")"
  [ "${#p1}" -eq 48 ] && [ "$p1" = "$p2" ]'
check "what is not a mongodb:// URI, or already has credentials, is left alone" '[ "$(lib "dash_nzm_compose http://x; echo \$?")" = 1 ] && [ "$(lib "dash_nzm_compose mongodb://u:p@h/d; echo \$?")" = 1 ]'
check "a name of user that is not valid is refused (letters, digits, dot, hyphen, underscore)" '[ "$(lib "dash_nzm_user_ok ana-1.x_y && echo y; dash_nzm_user_ok \"a b\" || echo n; dash_nzm_user_ok \"a:b\" || echo n" | tr "\n" " ")" = "y n n " ]'

section "2. reading the credentials back"
check "the user and the password are decoded, and the database is the path" '[ "$(lib "mu_parse \"mongodb://ana:p%40ss%3Aw%2Frd@h:27017/db_x?authSource=admin\"; echo \"\$MU_USER|\$MU_PASS|\$MU_DB\"")" = "ana|p@ss:w/rd|db_x" ]'
check "what the wizard encodes, init decodes: every character comes back" '
  pw="a@b:c/d?e#f g%h+i&j=k\l\"m"
  o="$(ROOT="$PWD" DASH_NZ_NAME=u bash -c "source lib/bootstrap.sh; source lib/screens/newinst/data.sh; source lib/cmd/init.sh; DASH_NZM_PASS=\"\$1\"; dash_nzm_compose mongodb://h/d; mu_parse \"\$DASH_NZM_URI\"; printf %s \"\$MU_PASS\"" _ "$pw")"
  [ "$o" = "$pw" ]'
check "a password with an @ that is not encoded is still the password (the host is after the last one)" '[ "$(lib "mu_parse \"mongodb://a:p@ss@h/db\"; echo \"\$MU_USER|\$MU_PASS|\$MU_DB\"")" = "a|p@ss|db" ]'
check "a URI with no user and password gives nothing (there is no user to create)" '[ "$(lib "mu_parse mongodb://h:27017/db; echo \$?")" = 1 ] && [ "$(lib "mu_parse mongodb://ana@h/db; echo \$?")" = 1 ] && [ "$(lib "mu_parse mongodb://ana:p@h; echo \$?")" = 1 ]'

section "3. init creates the user before it reads anything"
PW='Pw@1:x'
printf 's0:MONGO_URI=mongodb://mu-a:Pw%%401%%3Ax@host.docker.internal:27017/authsoftware_mu-a?authSource=admin
s1:MONGO_DELTA_DISPATCH_URI=mongodb://mu-a:Pw%%401%%3Ax@host.docker.internal:27017/deltadispatch_mu-a?authSource=admin
s1:MONGO_AUTHSOFTWARE_URI=mongodb://mu-a:Pw%%401%%3Ax@host.docker.internal:27017/authsoftware_mu-a?authSource=admin
s1:MONGO_ROBIN_URI=mongodb://mu-a:Pw%%401%%3Ax@host.docker.internal:27017/robin_mu-a?authSource=admin
' > "$FIX/mu.env"
D new mu-a --generate-secrets --env-file "$FIX/mu.env" > "$FIX/new-a.log" 2>&1
D new mu-b --generate-secrets > /dev/null 2>&1
check "the credentials are in the files of the instance (the way the wizard sends them)" 'grep -q "^MONGO_URI=mongodb://mu-a:Pw%401%3Ax@host.docker.internal:27017/authsoftware_mu-a?authSource=admin$" instances/mu-a/.env.s0 && grep -q "^MONGO_ROBIN_URI=mongodb://mu-a:" instances/mu-a/.env.s1'
iu() { : > "$FIX/calls.log"; lib "select_services $1; init_mongo_user $1"; }
out="$(iu mu-a)"
check "with no admin account it tries once without one (a Mongo with no authentication lets a user be created) and the user is created" 'echo "$out" | grep -q "usuario de Mongo .mu-a. creado (readWrite en: authsoftware_mu-a deltadispatch_mu-a robin_mu-a)" && [ "$(grep -c "^run " "$FIX/calls.log")" -eq 1 ]'
check "…with nothing secret in the command line of docker (the URI goes as an environment variable too)" 'c="$(grep "^run " "$FIX/calls.log")"; echo "$c" | grep -q -- "-e DELTACTL_MONGO_ADMIN_URI -e MU_USER -e MU_PASS -e MU_DBS" && ! echo "$c" | grep -q "Pw@1\|Pw%401\|mongodb://host.docker.internal:27017/admin"'
touch "$FIX/mongouser_fail"
out="$(iu mu-a)"
check "when Mongo asks for authentication it says so and shows the script: the user, the three databases once each, and asks for the password (it is not printed)" 'echo "$out" | grep -q "sin cuenta de administración" && echo "$out" | grep -q "db.createUser({ user: \"mu-a\", pwd: passwordPrompt()" && [ "$(echo "$out" | grep -o "role: \"readWrite\", db: \"[a-z0-9_-]*\"" | sort | tr "\n" " ")" = "role: \"readWrite\", db: \"authsoftware_mu-a\" role: \"readWrite\", db: \"deltadispatch_mu-a\" role: \"readWrite\", db: \"robin_mu-a\" " ] && ! echo "$out" | grep -q "Pw@1"'
rm -f "$FIX/mongouser_fail"
out="$(DELTACTL_MONGO_ADMIN_URI='mongodb://root:AdminSecret9@db.itc.pe:27017/admin' iu mu-a)"
check "with an admin account the user is created, and it says for which databases" 'echo "$out" | grep -q "usuario de Mongo .mu-a. creado (readWrite en: authsoftware_mu-a deltadispatch_mu-a robin_mu-a)"'
check "no secret is in the command line of docker: the admin URI and the password go as environment variables (-e NAME)" 'c="$(grep "^run " "$FIX/calls.log")"; echo "$c" | grep -q -- "-e DELTACTL_MONGO_ADMIN_URI -e MU_USER -e MU_PASS -e MU_DBS" && ! echo "$c" | grep -q "AdminSecret9\|Pw@1\|Pw%401"'
touch "$FIX/mongouser_exists"
out="$(DELTACTL_MONGO_ADMIN_URI='mongodb://root:x@db.itc.pe:27017/admin' iu mu-a)"
check "a user that exists is left alone and it says so" 'echo "$out" | grep -q "ya existe: no se toca"'
rm -f "$FIX/mongouser_exists"; touch "$FIX/mongouser_fail"
out="$(DELTACTL_MONGO_ADMIN_URI='mongodb://root:x@db.itc.pe:27017/admin' iu mu-a; echo "rc=$?")"
check "when Mongo refuses, init stops there with the reason (before any seed)" 'echo "$out" | grep -q "no se pudo crear el usuario de Mongo .mu-a.: ERR=auth de prueba"'
rm -f "$FIX/mongouser_fail"
out="$(DELTACTL_MONGO_ADMIN_URI='not-a-uri' iu mu-a)"
check "an admin value that is not a Mongo URI is refused" 'echo "$out" | grep -q "DELTACTL_MONGO_ADMIN_URI debe ser una URI de Mongo"'
out="$(iu mu-b)"
check "an instance whose URIs carry no credentials has no user to create: nothing is shown, nothing runs" '[ -z "$out" ] && ! grep -q "^run " "$FIX/calls.log"'
sed -i 's#^MONGO_ROBIN_URI=mongodb://mu-a:Pw%401%3Ax@#MONGO_ROBIN_URI=mongodb://mu-a:Other@#' instances/mu-a/.env.s1
out="$(iu mu-a)"
check "two different passwords for the same user in the URIs is an error that says which user" 'echo "$out" | grep -q "dos contraseñas distintas para el usuario .mu-a."'

finish

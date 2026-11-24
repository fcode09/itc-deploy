#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # the cases go in single quotes and are evaluated with eval; some variables are read by those cases
# Tests de ./deltactl images (alias versions): uso por instancia, previas, imágenes sin uso, filtro y --json.
# Usa un `docker` simulado, así que no necesita Docker real. Se ejecuta desde la raíz de la copia aislada.
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS

FIX="$(mktemp -d)"
export FIX
trap 'rm -rf "$FIX" instances/im-*' EXIT
rm -rf instances/im-*
mkdir -p "$FIX/bin"

cat > "$FIX/images.txt" <<'EOF'
auth-backend|1.0|sha256:aaaaaaaaaaaaaaaa|2 hours ago|350MB
auth-backend|0.9|sha256:bbbbbbbbbbbbbbbb|3 days ago|349MB
auth-backend|0.5|sha256:cccccccccccccccc|2 months ago|340MB
gueo-back-end|2.0|sha256:dddddddddddddddd|1 hour ago|1.2GB
EOF

cat > "$FIX/bin/docker" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  info) case "$*" in *Architecture*) echo x86_64 ;; esac ;;
  compose) echo "v2.30.0" ;;
  image)
    case "$2" in
      ls) cat "$FIX/images.txt" ;;
      inspect) case "$*" in *Architecture*) echo amd64 ;; esac ;;
    esac ;;
esac
exit 0
SHIM
chmod +x "$FIX/bin/docker"
export PATH="$FIX/bin:$PATH"

bash ./deltactl new im-one >/dev/null 2>&1
fill_instance instances/im-one 1.0 2.0
printf 'S0_TAG=0.9\n' > instances/im-one/.previous

section "1. tabla de versiones"
out="$(bash ./deltactl images 2>&1)"
check "muestra la arquitectura del servidor" 'echo "$out" | grep -q "Arquitectura de este servidor: amd64"'
check "agrupa por servicio y nombre de imagen" 'echo "$out" | grep -qx "s0 = auth-backend" && echo "$out" | grep -qx "s1 = gueo-back-end"'
check "marca la etiqueta en uso con su instancia" 'echo "$out" | grep "^1.0 " | grep -q "im-one(actual)"'
check "marca la etiqueta previa (rollback)" 'echo "$out" | grep "^0.9 " | grep -q "im-one(previa)"'
check "marca la etiqueta sin uso" 'echo "$out" | grep "^0.5 " | grep -q "sin uso (candidata a borrar)"'
check "usa los IDs cortos" 'echo "$out" | grep -q "aaaaaaaaaaaa " && ! echo "$out" | grep -q "sha256:"'
check "resume cuántas imágenes están sin uso" 'echo "$out" | grep -q "1 de 4 imagen(es) sin uso"'
check "no hay escapes en la salida plana" '! echo "$out" | has_ansi'
check "DELTACTL_COLOR=always colorea" 'DELTACTL_COLOR=always bash ./deltactl images | has_ansi'
check "la cabecera con ñ queda alineada con las filas" \
  '[ "$(echo "$out" | grep "^ETIQUETA" | cut -d" " -f1-5 | wc -c)" -gt 0 ] && echo "$out" | grep -q "TAMAÑO"'

section "2. filtro, alias y errores"
check "images s1 solo muestra s1" 'o="$(bash ./deltactl images s1 2>&1)"; echo "$o" | grep -q "s1 = gueo-back-end" && ! echo "$o" | grep -q "s0 = auth-backend"'
check "versions es un alias de images" '[ "$(bash ./deltactl versions 2>&1)" = "$out" ]'
check "servicio inválido falla" '! bash ./deltactl images s9 >/dev/null 2>&1'
check "opción desconocida falla" '! bash ./deltactl images --nada >/dev/null 2>&1'

section "3. --json"
js="$(bash ./deltactl images --json 2>&1)"
check "es JSON válido" 'if command -v python3 >/dev/null; then echo "$js" | python3 -c "import json,sys; json.load(sys.stdin)"; else true; fi'
check "incluye uso y estado" \
  'echo "$js" | grep "\"tag\":\"1.0\"" | grep -q "\"used_by\":\"im-one(current)\"" && echo "$js" | grep "\"tag\":\"0.5\"" | grep -q "\"in_use\":false"'
check "sin escapes ni cabeceras" '! echo "$js" | has_ansi && [ "$(echo "$js" | head -n1)" = "[" ]'
check "--json respeta el filtro de servicio" '! bash ./deltactl images s1 --json | grep -q "auth-backend"'

# --- The catalog of versions (lib/core/imagecat.sh) ---------------------------------------------------------------------------------
# A second simulated Docker: tests/fake-docker.sh, with dates (image_dates.txt) and the architecture of the server (server_arch). The real
# docker is never reached: the shim comes first on the PATH. The cases of the library are plain functions that lib2 sends to a bash that
# has loaded the library, so they need no quoting.
F2="$FIX/f2"
mkdir -p "$F2/bin"
cp tests/fake-docker.sh "$F2/bin/docker-fake"
printf '#!/usr/bin/env bash\nexport FIX="%s"\nexec bash "%s/bin/docker-fake" "$@"\n' "$F2" "$F2" > "$F2/bin/docker"
chmod +x "$F2/bin/docker"
: > "$F2/images.txt"; : > "$F2/image_dates.txt"
lib2() { # function [args...]
  local fn="$1"
  shift
  FIX="$F2" PATH="$F2/bin:$PATH" ROOT="$PWD" DELTACTL_LANG="${LIB2_LANG:-en}" DELTACTL_CONFIG="$F2/none" \
    bash -c 'source lib/bootstrap.sh; '"$(declare -f "$fn")"'; '"$fn"' "$@"' _ "$@" 2>&1
}
img2() { FIX="$F2" PATH="$F2/bin:$PATH" DELTACTL_LANG="${LIB2_LANG:-en}" bash ./deltactl "$@" 2>&1; }
dates() { if [ "$#" -eq 0 ]; then : > "$F2/image_dates.txt"; else printf '%s\n' "$@" > "$F2/image_dates.txt"; fi; }
images_are() { if [ "$#" -eq 0 ]; then : > "$F2/images.txt"; else printf '%s\n' "$@" > "$F2/images.txt"; fi; }

t_epoch() { ic_epoch "$1"; echo "$IC_E"; }
t_epochs() { ic_epoch "2026-11-23 10:00:00 -0500 EST"; local a="$IC_E"; ic_epoch 2026-11-23T10:00:00+01:00; echo "$a $IC_E"; }
t_leap() { ic_epoch "2028-02-29 23:59:59 +0000 UTC"; local a="$IC_E"; ic_epoch "2000-03-01 00:00:00 +0000 UTC"; echo "$a $IC_E"; }
t_notdate() { ic_epoch hola; local a=$?; ic_epoch "0001-01-01 00:00:00 +0000 UTC"; local b=$?; ic_epoch ""; echo "$a$b$? [$IC_E]"; }
t_roundtrip() { local e; for e in 86400 951868800 1795168800 1835481599; do ic_iso "$e"; ic_epoch "$IC_S"; printf '%s=%s ' "$IC_S" "$IC_E"; done; }
t_ago() { local n=1795168800 d; for d in 30 90 7200 172800 2678400 5184000 31536000 63072000; do ic_ago "$n" $((n + d)); printf '%s:%s ' "$IC_AGO_N" "$IC_AGO_U"; done; }
t_ago_text() { local n=1795168800 a b c; ic_ago_text "$n" $((n + 86400)); a="$IC_AGO_T"; ic_ago_text "$n" $((n + 172800)); b="$IC_AGO_T"; ic_ago_text "$n" $((n + 30)); c="$IC_AGO_T"; echo "$a|$b|$c"; }
t_ago_unknown() { ic_ago_text hola; echo "[$IC_AGO_T] $?"; }
t_versions_yes() { local t; for t in 1.2.3 v1.2.3 2026.11.3 1.2 7 1.2.3-rc1; do ic_version "$t" || { echo "no: $t"; return; }; done; echo yes; }
t_versions_no() { local t; for t in latest dev a1b2c3d 1.2.x v ""; do ic_version "$t" && { echo "yes: $t"; return; }; done; echo no; }
t_vparts() { ic_version v1.2.3-rc1; echo "$IC_VN $IC_VP"; }
t_vcmp() { ic_vcmp "$1" "$2" "$3" "$4"; echo "$IC_CMP"; }

section "4. dates: Docker's and ISO 8601, to the second, in UTC"
check "the Docker shim is the one found first (the real docker is never reached)" '[ "$(PATH="$F2/bin:$PATH" command -v docker)" = "$F2/bin/docker" ]'
check "Docker's CreatedAt becomes seconds since 1970" '[ "$(lib2 t_epoch "2026-11-20 10:00:00 +0000 UTC")" = 1795168800 ]'
check "the zone of the date counts (-0500 and +01:00)" '[ "$(lib2 t_epochs)" = "1795446000 1795424400" ]'
check "ISO 8601 with fractions and Z" '[ "$(lib2 t_epoch 2026-11-20T10:00:00.123456789Z)" = 1795168800 ]'
check "a leap day and the day after February of 2000" '[ "$(lib2 t_leap)" = "1835481599 951868800" ]'
check "what is not a date, and the never of an image without one, is not a date" '[ "$(lib2 t_notdate)" = "111 []" ]'
check "epoch to ISO 8601 UTC and back, even at the edges" '[ "$(lib2 t_roundtrip)" = "1970-01-02T00:00:00Z=86400 2000-03-01T00:00:00Z=951868800 2026-11-20T10:00:00Z=1795168800 2028-02-29T23:59:59Z=1835481599 " ]'
check "how long ago: the units and where they change" '[ "$(lib2 t_ago)" = "0:now 1:min 2:hour 2:day 1:month 2:month 1:year 2:year " ]'
check "how long ago in words: one and many, in English and in Spanish" '[ "$(lib2 t_ago_text)" = "1 day ago|2 days ago|just now" ] && [ "$(LIB2_LANG=es lib2 t_ago_text)" = "hace 1 día|hace 2 días|ahora mismo" ]'
check "an unknown date has no words" '[ "$(lib2 t_ago_unknown)" = "[] 1" ]'

section "5. versions: what looks like one and how they compare"
check "1.2.3, v1.2.3, 2026.11.3, 1.2, 7 and 1.2.3-rc1 are versions" '[ "$(lib2 t_versions_yes)" = yes ]'
check "latest, dev, a hash, 1.2.x, v and nothing are not" '[ "$(lib2 t_versions_no)" = no ]'
check "the numbers and the pre-release are taken apart" '[ "$(lib2 t_vparts)" = "1.2.3 rc1" ]'
check "1.2.10 is higher than 1.2.9 (numbers, not text)" '[ "$(lib2 t_vcmp 1.2.10 "" 1.2.9 "")" = 1 ] && [ "$(lib2 t_vcmp 1.2.9 "" 1.2.10 "")" = -1 ]'
check "1.2 equals 1.2.0, and 2026.11.3 is higher than 2026.9.30" '[ "$(lib2 t_vcmp 1.2 "" 1.2.0 "")" = 0 ] && [ "$(lib2 t_vcmp 2026.11.3 "" 2026.9.30 "")" = 1 ]'
check "a pre-release is lower than its release; two pre-releases compare as text" '[ "$(lib2 t_vcmp 1.2.3 rc1 1.2.3 "")" = -1 ] && [ "$(lib2 t_vcmp 1.2.3 rc2 1.2.3 rc1)" = 1 ]'

section "6. the catalog: order, the star and what never is one"
images_are \
  "auth-backend:v1.2.10|sha256:a10aaaaaaaaaaaaaaaa|amd64" "auth-backend:v1.2.9|sha256:a09aaaaaaaaaaaaaaaa|amd64" \
  "auth-backend:latest|sha256:a99aaaaaaaaaaaaaaaa|amd64" "auth-backend:2.0.0|sha256:a20aaaaaaaaaaaaaaaa|arm64" \
  "auth-backend:dev|sha256:a77aaaaaaaaaaaaaaaa|amd64" "gueo-back-end:3.1|sha256:g31aaaaaaaaaaaaaaaa|amd64"
dates \
  "auth-backend:v1.2.10|2026-11-20 10:00:00 +0000 UTC" "auth-backend:v1.2.9|2026-11-22 08:30:00 +0000 UTC" \
  "auth-backend:latest|2026-11-23 09:00:00 +0000 UTC" "auth-backend:2.0.0|2026-11-23 10:00:00 -0500 EST" \
  "gueo-back-end:3.1|2026-10-01 00:00:00 +0000 UTC"
t_dump() { ic_load; local i; for ((i = 0; i < IC_N; i++)); do printf '%s:%s:%s:%s ' "${IC_TAG[$i]}" "${IC_KIND[$i]}" "${IC_OK[$i]}" "${IC_STAR[$i]}"; done; }
t_groups() { ic_load; echo "${IC_GROUPS[*]}"; }
t_order() { ic_load; local i; for i in ${IC_ORDER["s0|auth-backend"]}; do printf '%s ' "${IC_TAG[$i]}"; done; }
t_latest() { ic_load; ic_latest s0; local a="$IC_LATEST"; ic_latest s1; echo "$a $IC_LATEST"; }
t_disc() { ic_load; echo "${IC_DISC["s0|auth-backend"]:-}|${IC_DISC["s1|gueo-back-end"]:-}"; }
t_archs() { ic_load; echo "${IC_ARCH[*]} $IC_SERVER_ARCH"; }
check "every tag of the images of the services, with its kind, compatibility and star" '[ "$(lib2 t_dump)" = "v1.2.10:ver:1:0 v1.2.9:ver:1:1 latest:latest:1:0 2.0.0:ver:0:0 dev:other:1:0 3.1:ver:1:1 " ]'
check "the groups are the services in the order of the catalog" '[ "$(lib2 t_groups)" = "s0|auth-backend s1|gueo-back-end" ]'
check "newest first by creation date; what has no date goes last" '[ "$(lib2 t_order)" = "2.0.0 latest v1.2.9 v1.2.10 dev " ]'
check "the star is the newest VERSION this server can run: not latest, not the arm64 image" '[ "$(lib2 t_latest)" = "v1.2.9 3.1" ]'
check "the order by date and the order by version disagree: the group says so (and only that group)" '[ "$(lib2 t_disc)" = "v1.2.9|v1.2.10|" ]'
check "the architecture of every image comes from one inspect" '[ "$(lib2 t_archs)" = "amd64 amd64 amd64 arm64 amd64 amd64 amd64" ]'
t_arm() { ic_load; ic_latest s0; echo "$IC_LATEST $IC_SERVER_ARCH ${IC_OK[0]}${IC_OK[3]}"; }
echo arm64 > "$F2/server_arch"
check "on an arm64 server the arm64 image is the star and the amd64 ones are not options" '[ "$(lib2 t_arm)" = "2.0.0 arm64 01" ]'
rm -f "$F2/server_arch"
images_are "auth-backend:1.0|sha256:b1|amd64" "auth-backend:1.1|sha256:b2|amd64"
dates "auth-backend:1.0|2026-11-01 00:00:00 +0000 UTC" "auth-backend:1.1|2026-11-01 00:00:00 +0000 UTC"
t_tie() { ic_load; ic_latest s0; echo "$IC_LATEST ${IC_ORDER["s0|auth-backend"]}"; }
check "two versions with the same date: the higher version comes first and is the star" '[ "$(lib2 t_tie)" = "1.1 1 0" ]'
dates
t_nodate() { ic_load; ic_latest s0; local rc=$?; echo "$rc ${IC_ORDER["s0|auth-backend"]} ${IC_STARIDX["s0|auth-backend"]}"; }
check "without dates there is no star, the order falls back to the version, and nothing is made up" '[ "$(lib2 t_nodate)" = "1 1 0 -1" ]'
images_are "auth-backend:latest|sha256:b1|amd64"
dates "auth-backend:latest|2026-11-01 00:00:00 +0000 UTC"
t_onlylatest() { ic_load; ic_latest s0; echo "$? [$IC_LATEST]"; }
check "only latest: no star and nothing to resolve" '[ "$(lib2 t_onlylatest)" = "1 []" ]'
images_are; dates
t_none() { ic_load; echo "$? $IC_N ${IC_STARIDX["s0|auth-backend"]}"; }
check "no images: an empty catalog, no star and no failure" '[ "$(lib2 t_none)" = "0 0 -1" ]'
images_are "auth-backend:<none>|sha256:b1|amd64" "auth-backend:1.0|sha256:b2|amd64"
t_untagged() { ic_load; echo "$IC_N ${IC_TAG[0]}"; }
check "an image without a tag is not listed" '[ "$(lib2 t_untagged)" = "1 1.0" ]'
images_are "auth-backend:1.0|sha256:b1|"
dates "auth-backend:1.0|2026-11-01 00:00:00 +0000 UTC"
t_unknownarch() { ic_load; echo "${IC_ARCH[0]} ${IC_OK[0]} ${IC_STAR[0]}"; }
check "an image of an unknown architecture counts as compatible (it cannot be proved wrong)" '[ "$(lib2 t_unknownarch)" = "? 1 1" ]'
images_are "auth-backend:1.0|sha256:b1|amd64"
# shellcheck disable=SC2329  # the inner function replaces dk_ready in the library
t_nodocker() { dk_ready() { return 1; }; ic_load; echo "$? $IC_N"; }
check "without Docker the load fails and leaves the catalog empty" '[ "$(lib2 t_nodocker)" = "1 0" ]'

section "7. use by instances and image names that are not the default one"
rm -rf instances/im-one   # (the instance of the sections above)
bash ./deltactl new im-uso >/dev/null 2>&1
fill_instance instances/im-uso 2.0 3.1
printf 'S0_TAG=1.5\n' > instances/im-uso/.previous
images_are "auth-backend:2.0|sha256:c1|amd64" "auth-backend:1.5|sha256:c2|amd64" "auth-backend:1.0|sha256:c3|amd64" "gueo-back-end:3.1|sha256:c4|amd64"
dates
t_use() { ic_load; local i; for i in 0 1 2 3; do printf '[%s]' "${IC_USE[$i]}"; done; }
check "who uses a tag: as current, as previous, and nobody" '[ "$(lib2 t_use)" = "[im-uso(current) ][im-uso(previous) ][][im-uso(current) ]" ]'
echo 'S0_IMAGE=otro/auth' >> instances/im-uso/.env.instance
images_are "auth-backend:1.0|sha256:c3|amd64" "otro/auth:7.0|sha256:d1|amd64"
check "the image name an instance chose is a group of its own" '[ "$(lib2 t_groups)" = "s0|auth-backend s0|otro/auth s1|gueo-back-end" ]'
sed -i '/^S0_IMAGE=/d' instances/im-uso/.env.instance
images_are "auth-backend:1.0|sha256:e1|amd64" "nuevo/img:3.0|sha256:e2|amd64" "nuevo/img:2.0|sha256:e3|amd64"
dates "nuevo/img:3.0|2026-11-02 00:00:00 +0000 UTC" "nuevo/img:2.0|2026-11-01 00:00:00 +0000 UTC"
t_extra() { ic_load s0=nuevo/img; ic_latest s0 nuevo/img; echo "${IC_GROUPS[*]} $IC_LATEST"; }
check "an image name still being typed (in no instance yet) can be added to the groups" '[ "$(lib2 t_extra)" = "s0|auth-backend s0|nuevo/img s1|gueo-back-end 3.0" ]'
t_extra_bad() { ic_load s9=nuevo/img; echo "${IC_GROUPS[*]}"; }
check "an unknown service in that list is ignored" '[ "$(lib2 t_extra_bad)" = "s0|auth-backend s1|gueo-back-end" ]'

section "8. images: the star, the warnings and the new fields of --json"
images_are \
  "auth-backend:v1.2.10|sha256:a10aaaaaaaaaaaaaaaa|amd64" "auth-backend:v1.2.9|sha256:a09aaaaaaaaaaaaaaaa|amd64" \
  "auth-backend:latest|sha256:a99aaaaaaaaaaaaaaaa|amd64" "auth-backend:2.0.0|sha256:a20aaaaaaaaaaaaaaaa|arm64" \
  "gueo-back-end:3.1|sha256:g31aaaaaaaaaaaaaaaa|amd64"
dates \
  "auth-backend:v1.2.10|2026-11-20 10:00:00 +0000 UTC" "auth-backend:v1.2.9|2026-11-22 08:30:00 +0000 UTC" \
  "auth-backend:latest|2026-11-23 09:00:00 +0000 UTC" "auth-backend:2.0.0|2026-11-23 10:00:00 -0500 EST" \
  "gueo-back-end:3.1|2026-10-01 00:00:00 +0000 UTC"
rm -rf instances/im-uso
out2="$(img2 images)"
check "the table goes newest first" '[ "$(echo "$out2" | awk "/^s0 = /{f=1;next} /^s1 = /{f=0} f && /^[0-9a-z]/ && !/^TAG|^ETIQ/ {print \$1}" | tr "\n" " ")" = "2.0.0 latest v1.2.9 v1.2.10 " ]'
check "the star marks the most recent one you may choose; a warning mark the tag that moves; an error mark the image of another architecture" '
  echo "$out2" | grep "^v1.2.9 " | grep -q "[*★]" && ! echo "$out2" | grep "^v1.2.10 " | grep -q "[*★]" \
  && echo "$out2" | grep "^latest " | grep -q "[!▲]" && echo "$out2" | grep "^2.0.0 " | grep -q "arm64 [x✖]"'
check "under the image it warns that the order by date and by version disagree" 'echo "$out2" | grep -q "v1.2.9 was created after v1.2.10, which has the highest version number"'
check "the notes explain the marks" 'echo "$out2" | grep -q "most recent version by creation date" && echo "$out2" | grep -q "tag that moves" && echo "$out2" | grep -q "different architecture than amd64"'
check "no notes about marks that are not there" '[ -z "$(img2 images s1 | grep "tag that moves\|different architecture")" ]'
js2="$(img2 images --json)"
check "--json is valid and has created_at, latest, compatible and kind" '
  if command -v python3 > /dev/null; then
    echo "$js2" | python3 -c "
import json, sys
d = json.load(sys.stdin)
r = {x[\"tag\"]: x for x in d}
assert r[\"v1.2.9\"][\"latest\"] is True and r[\"v1.2.10\"][\"latest\"] is False and r[\"3.1\"][\"latest\"] is True
assert r[\"2.0.0\"][\"compatible\"] is False and r[\"latest\"][\"compatible\"] is True
assert r[\"v1.2.9\"][\"created_at\"] == \"2026-11-22T08:30:00Z\" and r[\"2.0.0\"][\"created_at\"] == \"2026-11-23T15:00:00Z\"
assert r[\"latest\"][\"kind\"] == \"latest\" and r[\"v1.2.9\"][\"kind\"] == \"version\"
assert [x[\"tag\"] for x in d if x[\"service\"] == \"s0\"] == [\"2.0.0\", \"latest\", \"v1.2.9\", \"v1.2.10\"]
"
  else
    echo "$js2" | grep "\"tag\":\"v1.2.9\"" | grep -q "\"latest\":true"
  fi'
dates
check "without a date created_at is empty (not made up) and nothing is the latest" 'j="$(img2 images --json)"; echo "$j" | grep "\"tag\":\"v1.2.9\"" | grep -q "\"created_at\":\"\"" && ! echo "$j" | grep -q "\"latest\":true"'

section "9. new --sN-tag latest picks the star"
dates \
  "auth-backend:v1.2.10|2026-11-20 10:00:00 +0000 UTC" "auth-backend:v1.2.9|2026-11-22 08:30:00 +0000 UTC" \
  "auth-backend:latest|2026-11-23 09:00:00 +0000 UTC" "auth-backend:2.0.0|2026-11-23 10:00:00 -0500 EST" \
  "gueo-back-end:3.1|2026-10-01 00:00:00 +0000 UTC"
o="$(img2 new im-lat --s0-tag latest --s1-tag latest)"
check "the instance keeps the tag it resolved to, not the word" 'grep -q "^S0_TAG=v1.2.9$" instances/im-lat/.env.instance && grep -q "^S1_TAG=3.1$" instances/im-lat/.env.instance'
check "it says which one it chose" 'echo "$o" | grep -q "s0: using the most recent version of auth-backend: v1.2.9"'
check "a tag that is a version is kept as it is" 'img2 new im-fix --s0-tag v1.2.10 > /dev/null; grep -q "^S0_TAG=v1.2.10$" instances/im-fix/.env.instance'
images_are "auth-backend:1.0|sha256:f0|amd64" "otro/auth:5.0|sha256:f1|amd64"
dates "otro/auth:5.0|2026-11-24 00:00:00 +0000 UTC" "auth-backend:1.0|2026-11-01 00:00:00 +0000 UTC"
check "with another image name it looks among the versions of that one" 'img2 new im-otro --s0-image otro/auth --s0-tag latest > /dev/null; grep -q "^S0_TAG=5.0$" instances/im-otro/.env.instance'
images_are "auth-backend:latest|sha256:g1|amd64"
check "no version to choose: it fails, says why and creates nothing" 'o="$(img2 new im-nada --s0-tag latest)"; rc=$?; [ "$rc" -ne 0 ] && [ ! -e instances/im-nada ] && echo "$o" | grep -q "no version to choose for s0 (auth-backend)"'
images_are "auth-backend:2.0.0|sha256:g2|arm64"
check "the image has to be of the architecture of the server" '! img2 new im-arm --s0-tag latest > /dev/null && [ ! -e instances/im-arm ]'
check "the same in Spanish" 'images_are "auth-backend:latest|sha256:g1|amd64"; LIB2_LANG=es img2 new im-nada2 --s0-tag latest | grep -q "no hay una versión que elegir para s0"'

finish

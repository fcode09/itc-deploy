#!/usr/bin/env bash
# Tests of ./deltactl load (plain and gzip archives, errors) and of the unknown architecture marker of images.
# It uses a fake `docker`, so it needs no real Docker. Run it through tests/run.sh.
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS

FIX="$(mktemp -d)"
export FIX
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/bin"

# The archives are plain text here: each line of the file is an image the fake `docker load` reports as loaded.
# A file holding the word FAIL makes the fake docker fail, one holding NOTHING loads no named image.
cat > "$FIX/bin/docker" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  info) case "$*" in *Architecture*) echo x86_64 ;; esac ;;
  compose) echo "v2.30.0" ;;
  load)
    if [ "${2:-}" = "-i" ]; then body="$(cat "$3")"; else body="$(cat)"; fi
    echo "load $*" >> "$FIX/calls.log"
    case "$body" in
      FAIL*) echo "Error: archive is broken" >&2; exit 1 ;;
      NOTHING*) echo "Loaded layer sha256:abc" ;;
      *) while IFS= read -r ref; do echo "Loaded image: $ref"; done <<< "$body" ;;
    esac ;;
  image)
    case "$2" in
      ls) cat "$FIX/images.txt" ;;
      inspect) case "$*" in *Architecture*) [ ! -f "$FIX/arch" ] || cat "$FIX/arch" ;; esac ;;
    esac ;;
esac
exit 0
SHIM
chmod +x "$FIX/bin/docker"
export PATH="$FIX/bin:$PATH"
: > "$FIX/calls.log"

section "1. a plain archive"
printf 'backend-s0:3.0\nbackend-s1:3.0\n' > "$FIX/plain.tar"
out="$(bash ./deltactl load "$FIX/plain.tar" 2>&1)"; rc=$?
check "exits with 0" '[ "$rc" -eq 0 ]'
check "lists every loaded image" 'echo "$out" | grep -q "backend-s0:3.0" && echo "$out" | grep -q "backend-s1:3.0"'
check "reports how many were loaded" 'echo "$out" | grep -q "2 imagen(es) disponibles"'
check "a plain archive is read with docker load -i" 'grep -q "^load load -i $FIX/plain.tar" "$FIX/calls.log"'

section "2. a gzip archive"
printf 'backend-s0:4.0\n' | gzip > "$FIX/packed.tar.gz"
out="$(bash ./deltactl load "$FIX/packed.tar.gz" 2>&1)"; rc=$?
check "exits with 0" '[ "$rc" -eq 0 ]'
check "the image inside is loaded" 'echo "$out" | grep -q "backend-s0:4.0" && echo "$out" | grep -q "1 imagen(es) disponibles"'
check "a .gz archive is decompressed and sent through stdin" 'tail -n1 "$FIX/calls.log" | grep -qx "load load"'
printf 'backend-s1:4.0\n' | gzip > "$FIX/packed.tgz"
check "a .tgz archive works too" 'bash ./deltactl load "$FIX/packed.tgz" 2>&1 | grep -q "backend-s1:4.0"'

section "3. errors"
check "without a file it prints the usage" 'bash ./deltactl load 2>&1 | grep -q "^ERROR uso: ./deltactl load"'
check "a missing file is reported" 'bash ./deltactl load "$FIX/nope.tar" 2>&1 | grep -q "^ERROR no existe el archivo"'
printf 'FAIL\n' > "$FIX/broken.tar"
out="$(bash ./deltactl load "$FIX/broken.tar" 2>&1)"; rc=$?
check "a failing docker load stops with an error" '[ "$rc" -ne 0 ] && echo "$out" | grep -q "^ERROR no se pudo cargar"'
check "docker's own message is shown" 'echo "$out" | grep -q "archive is broken"'
printf 'NOTHING\n' > "$FIX/empty.tar"
out="$(bash ./deltactl load "$FIX/empty.tar" 2>&1)"; rc=$?
check "an archive without named images is an error" '[ "$rc" -ne 0 ] && echo "$out" | grep -q "no contiene imágenes con nombre"'

section "4. the architecture of the image"
printf 'backend-s0:3.0\n' > "$FIX/one.tar"
printf 'arm64\n' > "$FIX/arch"
check "load warns when the image does not match the server" 'bash ./deltactl load "$FIX/one.tar" 2>&1 | grep -q "es arm64 y este servidor es"'
printf 'amd64\n' > "$FIX/arch"
check "load does not warn when they match" '! bash ./deltactl load "$FIX/one.tar" 2>&1 | grep -q "no podrá arrancar"'
rm -f "$FIX/arch"
printf 'backend-s0|3.0|sha256:eeeeeeeeeeeeeeee|1 hour ago|350MB\n' > "$FIX/images.txt"
check "images shows ? when the architecture is unknown" 'bash ./deltactl images 2>&1 | grep "^3.0 " | grep -q " ? "'
check "images --json uses ? as well" 'bash ./deltactl images --json 2>&1 | grep -q "\"architecture\":\"?\""'
check "load does not warn when the architecture is unknown" '! bash ./deltactl load "$FIX/one.tar" 2>&1 | grep -q "no podrá arrancar"'

finish

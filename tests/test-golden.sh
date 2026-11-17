#!/usr/bin/env bash
# Golden snapshots of the Spanish (default) user interface.
#
# Purpose: the UI is being refactored (English code base + i18n catalogs). Until then every user-facing
# text is Spanish, so this suite records what each command prints today and later fails if a refactor
# changes a single character of the Spanish output.
#
# Usage (from the repo root):
#   tests/run.sh test-golden                     compare against tests/golden/es/
#   DELTACTL_GOLDEN=record tests/run.sh test-golden   re-record the snapshots (only when a change is intended)
#
# Runs inside the isolated copy made by tests/run.sh, with a simulated docker: nothing real is touched.
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh

# File ownership and host details differ on Windows shells (Git Bash), so snapshots are Linux-only.
if [ "$(uname -s)" != "Linux" ]; then
  echo "  SKIP golden snapshots are recorded and compared on Linux (WSL or a server), not on $(uname -s)"
  finish
  exit $?
fi

MODE="${DELTACTL_GOLDEN:-check}"
GOLDEN_DIR="${DELTACTL_GOLDEN_DIR:-tests/golden}/es"
LANG_UI="${DELTACTL_LANG:-es}"
[ "$LANG_UI" = "es" ] || GOLDEN_DIR="${DELTACTL_GOLDEN_DIR:-tests/golden}/$LANG_UI"
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS

FIX="$(mktemp -d)"
export FIX
trap 'rm -rf "$FIX" instances/gold-*' EXIT
rm -rf instances/gold-*
mkdir -p "$FIX/bin"
: > "$FIX/containers.txt"; : > "$FIX/images.txt"; : > "$FIX/stats.txt"

# --- Simulated docker ------------------------------------------------------------------------------
# ps / inspect / stats / logs come from the fixture files; everything else (info, image, compose,
# network, run) is delegated to tests/fake-docker.sh.
cp tests/fake-docker.sh "$FIX/bin/docker-fake"
cat > "$FIX/bin/docker" <<'SHIM'
#!/usr/bin/env bash
[ -f "$FIX/nodocker" ] && exit 1
case "$1" in
  ps) n=$(wc -l < "$FIX/containers.txt"); for ((i = 1; i <= n; i++)); do echo "c$i"; done ;;
  inspect) cat "$FIX/containers.txt" ;;
  stats) cat "$FIX/stats.txt" ;;
  logs) echo "Nest ERROR de prueba"; echo "linea normal" ;;
  *) exec bash "$FIX/bin/docker-fake" "$@" ;;
esac
SHIM
# `ss` reports no listening ports, so the port-in-use warning of `check` does not depend on the host.
printf '#!/bin/sh\nexit 0\n' > "$FIX/bin/ss"
chmod +x "$FIX/bin/docker" "$FIX/bin/ss"
export PATH="$FIX/bin:$PATH"

# --- Fixed host figures for the status header (memory and load) ------------------------------------------
printf 'MemTotal:        8388608 kB
MemFree:         1048576 kB
MemAvailable:    3145728 kB
' > "$FIX/meminfo"
printf '0.82 0.50 0.40 1/200 1234
' > "$FIX/loadavg"
export DELTACTL_MEMINFO="$FIX/meminfo" DELTACTL_LOADAVG="$FIX/loadavg"

# --- Fixtures --------------------------------------------------------------------------------------
started() { date -u -d "$1 ago" +%Y-%m-%dT%H:%M:%S.000000000Z; }
# container project service state health image ago
container() { printf '%s|%s|%s|%s|%s|%s|/%s_%s\n' "$1" "$2" "$3" "$4" "$5" "$(started "$6")" "$2" "$1" >> "$FIX/containers.txt"; }
image() { printf '%s|%s|amd64\n' "$1" "$2" >> "$FIX/images.txt"; }
deployed() { # instance service tag id
  local up="${2^^}"
  printf '%s_TAG=%s\n%s_IMAGE_ID=%s\n' "$up" "$3" "$up" "$4" >> "instances/$1/.deployed"
}
newinst() { # name s0tag s1tag [services]
  bash ./deltactl new "$1" ${4:+--services "$4"} >/dev/null 2>&1
  fill_instance "instances/$1" "$2" "$3"
}
seeded() { printf 'SOURCE=init\nINITIALIZED_AT=2026-01-01T00:00:00Z\n' > "instances/$1/.initialized"; }

# gold-ok: healthy and seeded.  gold-drift: s0 unhealthy, s1 runs another tag.  gold-new: never deployed.
newinst gold-ok 1.0 1.0; seeded gold-ok
newinst gold-drift 1.0 1.0; seeded gold-drift
newinst gold-new 1.0 1.0
image auth-backend:1.0 sha256:aaaaaaaaaaaa1111; image gueo-back-end:1.0 sha256:bbbbbbbbbbbb2222
image gueo-back-end:0.9 sha256:cccccccccccc3333
deployed gold-ok s0 1.0 sha256:aaaaaaaaaaaa1111; deployed gold-ok s1 1.0 sha256:bbbbbbbbbbbb2222
deployed gold-drift s0 1.0 sha256:aaaaaaaaaaaa1111; deployed gold-drift s1 0.9 sha256:cccccccccccc3333
container gold-ok s0 running healthy auth-backend:1.0 "2 days"
container gold-ok s1 running healthy gueo-back-end:1.0 "3 days"
container gold-drift s0 running unhealthy auth-backend:1.0 "5 hours"
container gold-drift s1 running healthy gueo-back-end:0.9 "5 hours"
printf 's0_gold-ok|82MiB / 512MiB|0.2%%\ns1_gold-ok|410MiB / 1GiB|1.5%%\n' > "$FIX/stats.txt"

# --- Normalization: remove everything that changes between runs or machines -------------------------
HOST_NAME="$(hostname 2>/dev/null || echo servidor)"
# Escapes a literal text for a sed pattern delimited by # (a hostname or path may hold . [ ] * ^ $ \ or #).
sed_lit() { printf '%s' "$1" | sed -e 's/[][\.*^$#/]/\\&/g'; }
normalize() {
  sed -e "s#$(sed_lit "$PWD")#<ROOT>#g" -e "s#$(sed_lit "$FIX")#<FIX>#g" -e "s#$(sed_lit "$HOST_NAME")#<HOST>#g" \
    -e 's#/tmp/tmp\.[A-Za-z0-9]*#<TMP>#g' \
    -e 's/"uptime_seconds":[0-9][0-9]*/"uptime_seconds":<N>/g' \
    -e 's/[0-9][0-9]*d[0-9][0-9]h/<UP>/g' -e 's/[0-9][0-9]*h[0-9][0-9]m/<UP>/g' \
    -e 's/[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9:]*Z*/<DATE>/g'
}
# snap <name> '<command>' [headings]
# The command runs through eval; stdout, stderr and the exit code are captured.
# Mode "headings" is for commands whose body depends on the host machine (disk, memory, installed tools):
# only the non-indented lines (section titles) are kept and the exit code is not compared.
snap() {
  local name="$1" cmd="$2" mode="${3:-}" raw rc out file
  file="$GOLDEN_DIR/$name.out"
  raw="$( ( eval "$cmd" ) 2>&1 )"
  rc=$?
  out="$(printf '%s\n' "$raw" | normalize)"
  if [ "$mode" = "headings" ]; then
    out="$(printf '%s\n' "$out" | grep -E '^[^[:space:]]' || true)"
    rc="any"
  fi
  out="$out"$'\n'"[exit=$rc]"
  if [ "$MODE" = "record" ]; then
    mkdir -p "$GOLDEN_DIR"
    printf '%s\n' "$out" > "$file"
    echo "  REC  $name"
    pass=$((pass + 1))
  elif [ ! -f "$file" ]; then
    echo "  FAIL $name (no snapshot: record it with DELTACTL_GOLDEN=record)"
    fail=$((fail + 1))
  elif diff -u "$file" <(printf '%s\n' "$out") > "$FIX/diff.txt" 2>&1; then
    echo "  PASS $name"
    pass=$((pass + 1))
  else
    echo "  FAIL $name"
    sed -n '1,25p' "$FIX/diff.txt" | sed 's/^/       /'
    fail=$((fail + 1))
  fi
}

PLAIN='LANG=C.UTF-8 DELTACTL_UI=plain DELTACTL_COLOR=never COLUMNS=100'
RICH='LANG=C.UTF-8 DELTACTL_UI=rich DELTACTL_COLOR=always COLUMNS=100'
NARROW='LANG=C.UTF-8 DELTACTL_UI=rich DELTACTL_COLOR=always COLUMNS=60'
ASCII='LANG=C.UTF-8 DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_ASCII=1 COLUMNS=100'
I="bash ./deltactl"

section "status and home"
snap status-plain "$PLAIN $I status"
snap status-rich "$RICH $I status"
snap status-narrow "$NARROW $I status"
snap status-ascii "$ASCII $I status"
snap status-stats "$PLAIN $I status --stats"
snap status-detail-ok "$PLAIN $I status gold-ok"
snap status-detail-drift "$RICH $I status gold-drift"
snap status-detail-new "$PLAIN $I status gold-new"
snap status-json "$PLAIN $I status --json"
snap status-strict "$PLAIN $I status --strict"
snap home-rich "$RICH $I"
snap home-plain "$PLAIN $I"

section "list, images, doctor, check"
snap list "$PLAIN $I list"
snap list-rich "$RICH $I list"
snap images "$PLAIN $I images"
snap images-rich "$RICH $I images"
snap doctor "$PLAIN $I doctor" headings
snap check-ok "$PLAIN $I check gold-ok"
snap check-drift "$PLAIN $I check gold-drift"
snap check-new "$RICH $I check gold-new"
snap check-missing "$PLAIN $I check no-existe"

section "errors and edge cases"
snap err-unknown-command "$PLAIN $I frobnicate"
snap err-deploy-no-args "$PLAIN $I deploy"
snap err-status-unknown "$PLAIN $I status no-existe"
snap err-new-bad-name "$PLAIN $I new Mala_Instancia"
snap err-new-existing "$PLAIN $I new gold-ok"
snap err-init-seeded "$PLAIN $I init gold-ok --yes"
snap err-rollback-none "$PLAIN $I rollback gold-new --yes"
snap err-menu-args "$PLAIN $I menu extra"
snap err-load-missing "$PLAIN $I load /no/existe.tar"

section "menu (scripted input)"
snap menu-exit "printf '0\n' | $RICH $I menu"
snap menu-help-option "printf '?4\n0\n' | $RICH $I menu"
snap menu-invalid-option "printf '99\n0\n' | $PLAIN $I menu"
snap menu-status "printf '1\n0\n0\n' | $PLAIN $I menu"

section "help: index, commands, guides, glossary"
snap help-index "$PLAIN $I help"
snap help-index-rich "$RICH $I help"
for c in new init adopt deploy rollback stop down load images versions list status ps logs check doctor menu completion help; do
  snap "help-cmd-$c" "$PLAIN $I help $c"
done
for t in nueva-instancia instancia-existente actualizar imagenes servicios red datos secretos archivos puertos solucion-problemas glosario; do
  snap "help-topic-$t" "$PLAIN $I help $t"
done
snap help-topic-rich "$RICH $I help nueva-instancia"
snap help-variables "$PLAIN $I help variable"
snap help-variable-one "$PLAIN $I help variable S0_TAG"
snap help-variable-unknown "$PLAIN $I help variable NO_EXISTE"
snap help-search "$PLAIN $I help buscar rollback"
snap help-search-none "$PLAIN $I help buscar zzzzzz"
snap help-flag "$PLAIN $I deploy --help"
snap help-unknown "$PLAIN $I help no-existe"

section "completion"
snap completion-bash "$PLAIN $I completion bash"

rm -f "$FIX/diff.txt"
[ "$MODE" != "record" ] || echo "Recorded in $GOLDEN_DIR"
finish

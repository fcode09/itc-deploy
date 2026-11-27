#!/usr/bin/env bash
# Tests de borrar versiones de imagen que nadie usa: `./deltactl images rm` y `images prune` (lib/cmd/images.sh), las reglas de qué se puede borrar
# (ic_removable, ic_prune_plan, el espacio que libera: lib/core/imagecat.sh) y las teclas d y D de la vista Imágenes. Nunca se borra la versión que
# una instancia usa (actual), la previa que guarda el rollback, ni la que usa un contenedor; `prune` conserva además la más reciente (★).
# Usa el docker simulado (tests/fake-docker.sh): nunca toca Docker. Se ejecuta desde la raíz de la copia aislada (tests/run.sh).
# shellcheck disable=SC2016  # los casos de check van entre comillas simples y se evalúan con eval
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8 LC_ALL=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS DELTACTL_TUI_KEYS DELTACTL_TUI_EVENTS DELTACTL_TUI_ROWS DELTACTL_THEME
unset DELTACTL_REFRESH DELTACTL_METRICS_INTERVAL DELTACTL_TUI_IDLE_AFTER DELTACTL_TUI_GATE DELTACTL_CLIP DELTACTL_PR_SHELL DELTACTL_GRAPH TUI_GRAPH

FIX="$(mktemp -d)"
export FIX
CFG="$FIX/config"
trap 'rm -rf "$FIX" instances/ir-*' EXIT
rm -rf instances/ir-*
mkdir -p "$FIX/bin"
: > "$FIX/containers.txt"; : > "$FIX/stats.txt"; : > "$FIX/calls.log"
cp tests/fake-docker.sh "$FIX/bin/docker-fake"
printf '#!/usr/bin/env bash\nexec bash "%s/bin/docker-fake" "$@"\n' "$FIX" > "$FIX/bin/docker"
printf '#!/bin/sh\nexit 0\n' > "$FIX/bin/ss"
chmod +x "$FIX/bin/docker" "$FIX/bin/ss"
export DELTACTL_MEMINFO="$FIX/meminfo" DELTACTL_LOADAVG="$FIX/loadavg" DELTACTL_PROC_ROOT="$FIX/proc" DELTACTL_CGROUP_ROOT="$FIX/cg" DELTACTL_NO_RUNS=1
printf 'MemTotal:        8388608 kB\nMemAvailable:    3145728 kB\n' > "$FIX/meminfo"
printf '0.82 0.50 0.40 1/200 1234\n' > "$FIX/loadavg"
export PATH="$FIX/bin:$PATH"
# shellcheck source=tests/tools/images_scenes.sh
source tests/tools/images_scenes.sh

# What the simulated docker has (images_fixture): s0 has 2.14.1 (the star), 2.14.0, 2.13.2, 3.0.0-rc1 (another architecture), latest; s1 has 2.9.0.
# ir-colorado runs s0 2.14.0; ir-lima runs the star 2.14.1 and keeps 2.13.2 for its rollback; both run s1 2.9.0. So the ones nobody uses are
# 3.0.0-rc1 and latest.
reset_docker() {
  images_fixture "$FIX"
  printf '%s\n' "backend-s0:3.0.0-rc1|500MB" "backend-s0:latest|492MB" > "$FIX/image_sizes.txt"
  : > "$FIX/containers.txt"; : > "$FIX/calls.log"; rm -f "$FIX/rmi_fail"
}
reset_docker
bash ./deltactl new ir-colorado --s0-tag 2.14.0 --s1-tag 2.9.0 > /dev/null 2>&1
bash ./deltactl new ir-lima --s0-tag 2.14.1 --s1-tag 2.9.0 > /dev/null 2>&1
printf 'S0_TAG=2.13.2\n' > instances/ir-lima/.previous

D() { bash ./deltactl "$@" 2>&1 </dev/null; }
rmis() { grep -c "^rmi " "$FIX/calls.log" 2> /dev/null || true; }
has_image() { grep -q "^$1|" "$FIX/images.txt"; }

section "1. prune --dry-run: what would go, and nothing does"
check "it lists the versions nobody uses with their size, and the space it frees" '
  o="$(D images prune --dry-run)"; echo "$o" | grep -q "Se borrarán 2 imagen" && echo "$o" | grep -qE "s0 +3.0.0-rc1 +500MB" && echo "$o" | grep -qE "s0 +latest +492MB" && echo "$o" | grep -q "Libera 992MB"'
check "it never lists what an instance runs (2.14.0), the one kept for a rollback (2.13.2), the star (2.14.1) or what s1 runs" '
  o="$(D images prune --dry-run)"; ! echo "$o" | grep -qE "2\.14\.0|2\.13\.2|2\.14\.1|2\.9\.0"'
check "a dry run asks nothing and removes nothing" '[ "$(rmis)" = 0 ] && has_image backend-s0:3.0.0-rc1 && has_image backend-s0:latest'
check "without --yes and without a terminal it refuses to remove (and removes nothing)" '
  ! D images prune > /dev/null && [ "$(rmis)" = 0 ] && D images prune | grep -q "se requiere confirmación"'
check "one service only: s1 has nothing to remove, and it says why" 'D images prune s1 | grep -q "No hay nada que borrar"'
check "--keep N leaves the N most recent of the ones left over" '
  o="$(D images prune --dry-run --keep 1)"; echo "$o" | grep -q "Se borrarán 1 imagen" && echo "$o" | grep -q "latest" && ! echo "$o" | grep -q "3.0.0-rc1"'

section "2. what is protected"
check "rm refuses the version an instance runs, saying who" '
  o="$(D images rm s0:2.14.0)"; echo "$o" | grep -q "s0:2.14.0: no se borra, una instancia la usa ahora (ir-colorado)"'
check "rm refuses the previous version of an instance (the rollback needs it)" '
  D images rm s0:2.13.2 | grep -q "s0:2.13.2: no se borra, es la versión anterior de ir-lima y la necesita el rollback"'
check "…also the star when an instance runs it, and what s1 runs" '
  D images rm s0:2.14.1 | grep -q "una instancia la usa ahora" && D images rm s1:2.9.0 | grep -q "una instancia la usa ahora"'
check "a refused rm fails and removes nothing" '! D images rm s0:2.14.0 > /dev/null && [ "$(rmis)" = 0 ] && has_image backend-s0:2.14.0'
check "a version a container uses is protected, though no instance names it" '
  printf "x|s0|running|healthy|backend-s0:latest|x|c|1|0\n" > "$FIX/containers.txt"
  o="$(D images prune --dry-run)"; echo "$o" | grep -q "Se borrarán 1 imagen" && ! echo "$o" | grep -q "latest" && D images rm s0:latest | grep -q "la usa un contenedor"; rc=$?; : > "$FIX/containers.txt"; [ "$rc" = 0 ]'
check "…even a stopped one" '
  printf "x|s0|exited|none|backend-s0:3.0.0-rc1|x|c|1|0\n" > "$FIX/containers.txt"
  ! D images prune --dry-run | grep -q "3.0.0-rc1"; rc=$?; : > "$FIX/containers.txt"; [ "$rc" = 0 ]'
check "an instance that changed its tag and was not deployed: the version it still runs is the container one, not the new tag" '
  printf "x|s0|running|healthy|backend-s0:2.13.2|x|c|1|0\n" > "$FIX/containers.txt"; D images rm s0:2.13.2 | grep -qE "no se borra"; rc=$?; : > "$FIX/containers.txt"; [ "$rc" = 0 ]'

section "3. removing"
check "rm of a version nobody uses asks, removes it with docker rmi (never forced) and says what was freed" '
  o="$(D images rm s0:3.0.0-rc1 --yes)"; echo "$o" | grep -q "borrada backend-s0:3.0.0-rc1" && echo "$o" | grep -q "Borradas 1, con error 0" && grep -qx "rmi backend-s0:3.0.0-rc1" "$FIX/calls.log" && ! grep -q "rmi -f\|--force" "$FIX/calls.log" && ! has_image backend-s0:3.0.0-rc1'
check "what is still protected is still there" 'has_image backend-s0:2.14.0 && has_image backend-s0:2.13.2 && has_image backend-s0:2.14.1 && has_image backend-s1:2.9.0'
reset_docker
check "prune --yes removes everything that is left over and nothing else" '
  D images prune --yes | grep -q "Borradas 2, con error 0" && ! has_image backend-s0:3.0.0-rc1 && ! has_image backend-s0:latest && has_image backend-s0:2.14.0 && has_image backend-s0:2.13.2 && has_image backend-s0:2.14.1'
reset_docker
check "when Docker refuses, the reason is shown, the exit is an error and the count says so" '
  touch "$FIX/rmi_fail"; o="$(D images rm s0:latest --yes)"; rc=$?; rm -f "$FIX/rmi_fail"; echo "$o" | grep -q "Docker no borró backend-s0:latest" && echo "$o" | grep -q "con error 1"'
reset_docker
check "docker itself refuses an image a container uses (the last safety net) even when deltactl was not told" '
  printf "x|s0|running|healthy|backend-s0:latest|x|c|1|0\n" > "$FIX/containers.txt"; ROOT="$PWD" bash -c "source lib/bootstrap.sh; dk_image_rm backend-s0:latest; echo \$?; echo \"\$DK_RM_ERR\"" | grep -q "conflict: unable to remove"; rc=$?; : > "$FIX/containers.txt"; [ "$rc" = 0 ]'
reset_docker
check "tags that share an image: only the name goes, no space is freed, and it says so" '
  echo "backend-s0:alias|sha256:a5aaaaaaaaaaaa|amd64" >> "$FIX/images.txt"
  o="$(D images rm s0:latest --yes)"; echo "$o" | grep -q "otra etiqueta apunta a la misma imagen" && echo "$o" | grep -q "Libera 0kB"'
reset_docker
check "the space counts an image once even when two of its tags go" '
  echo "backend-s0:alias|sha256:a5aaaaaaaaaaaa|amd64" >> "$FIX/images.txt"; printf "%s\n" "backend-s0:alias|492MB" >> "$FIX/image_sizes.txt"
  o="$(D images rm s0:latest s0:alias --yes)"; echo "$o" | grep -q "Libera 492MB"'
reset_docker

section "4. what the arguments say"
check "a target that is not <service>:<version> is refused" '! D images rm s0 > /dev/null && D images rm s0 | grep -q "no es <servicio>:<versión>"'
check "a service that does not exist is refused, with the list" 'D images rm nada:1 | grep -q "servicio"'
check "a version that is not loaded is refused, with where to look" 'D images rm s0:9.9.9 | grep -q "no hay una versión 9.9.9 de s0 cargada"'
check "rm with nothing to remove says its usage" 'D images rm | grep -q "uso: ./deltactl images rm"'
check "--keep needs a number" '! D images prune --keep x > /dev/null && D images prune --keep x | grep -q "pide un número"'
check "an unknown service or option is refused" '! D images prune s9 > /dev/null && ! D images prune --nada > /dev/null'
check "the operations that remove are recorded in the history, a dry run is not" '
  [ "$(ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/core/runs.sh; runs_is_mutation images rm s0:1; echo \$?")" = 0 ] \
  && [ "$(ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/core/runs.sh; runs_is_mutation images prune --yes; echo \$?")" = 0 ] \
  && [ "$(ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/core/runs.sh; runs_is_mutation images prune --dry-run; echo \$?")" = 1 ] \
  && [ "$(ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/core/runs.sh; runs_is_mutation images s0; echo \$?")" = 1 ]'
check "listing is still only listing: it removes nothing" '[ "$(rmis)" = 0 ] && D images | grep -q "3.0.0-rc1"'

section "5. the core: sizes and the space freed"
core() { ROOT="$PWD" bash -c 'source lib/bootstrap.sh; set +e; '"$1" 2>&1; }
check "sizes as Docker writes them become bytes" '[ "$(core "ic_size_bytes 492MB; echo \$IC_BYTES; ic_size_bytes 1.83GB; echo \$IC_BYTES; ic_size_bytes 12.3kB; echo \$IC_BYTES; ic_size_bytes 5B; echo \$IC_BYTES" | tr "\n" " ")" = "492000000 1830000000 12300 5 " ]'
check "bytes are written as Docker writes them" '[ "$(core "ic_fmt_bytes 969000000; echo \$IC_BYTES_H; ic_fmt_bytes 1830000000; echo \$IC_BYTES_H; ic_fmt_bytes 12300; echo \$IC_BYTES_H" | tr "\n" " ")" = "969MB 1.83GB 12kB " ]'
check "a size that cannot be read counts as nothing" '[ "$(core "ic_size_bytes nada; echo \$?")" = 1 ]'

section "6. the Images view: b removes the version under the cursor, B cleans up the service"
KEYS="$FIX/keys.txt"
panel() { printf '%s\n' "$@" > "$KEYS"; DELTACTL_NO_RUNS=1 DELTACTL_CONFIG="$CFG" DELTACTL_TUI_KEYS="$KEYS" DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_LANG="${LANGX:-es}" COLUMNS="${PANEL_COLS:-120}" DELTACTL_TUI_ROWS="${PANEL_ROWS:-34}" bash ./deltactl 2>&1; }
last_frame() { awk '/^=== frame /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }'; }
reset_docker
check "the keys of the view name b and B" 'panel 2 | last_frame | grep -q "b borrar · B limpiar"'
check "b on a version an instance runs does not ask: it says who runs it" '
  f="$(panel 2 b | last_frame)"; echo "$f" | grep -q "no se borra, una instancia la usa ahora" && [ "$(rmis)" = 0 ]'
check "b on one nobody uses asks first, with the keys inside, and says it touches no data" '
  f="$(panel 2 up b | last_frame)"; echo "$f" | grep -q "Borra la imagen s0:3.0.0-rc1 (500MB)" && echo "$f" | grep -q "toca datos ni instancias" && echo "$f" | grep -q "s si - n no\|s sí · n no" && [ "$(rmis)" = 0 ]'
check "n cancels: nothing is removed" 'panel 2 up b n > /dev/null; [ "$(rmis)" = 0 ] && has_image backend-s0:3.0.0-rc1'
check "s runs images rm for that version, and it is gone" '
  o="$(panel 2 up b s wait)"; echo "$o" | grep -q "Ejecutando: ./deltactl images rm s0:3.0.0-rc1 --yes" && ! has_image backend-s0:3.0.0-rc1 && has_image backend-s0:latest'
reset_docker
check "B says which versions it would clean up, the space, and what it keeps, before asking" '
  f="$(panel 2 B | last_frame)"; echo "$f" | grep -q "Borra 2 imagen(es) de s0 (3.0.0-rc1, latest)" && echo "$f" | grep -q "992MB" && echo "$f" | grep -q "Se conservan la más reciente" && [ "$(rmis)" = 0 ]'
check "B and s clean up the service and leave what is in use" '
  panel 2 B s wait > /dev/null; ! has_image backend-s0:3.0.0-rc1 && ! has_image backend-s0:latest && has_image backend-s0:2.14.0 && has_image backend-s0:2.13.2 && has_image backend-s0:2.14.1'
reset_docker
check "B on a service with nothing to clean up says so" '
  f="$(panel 2 end B | last_frame)"; echo "$f" | grep -q "No hay nada que limpiar en s1" && [ "$(rmis)" = 0 ]'
check "with a container using it, b refuses and B leaves it out" '
  printf "x|s0|running|healthy|backend-s0:latest|x|c|1|0\n" > "$FIX/containers.txt"
  f="$(panel 2 B | last_frame)"; : > "$FIX/containers.txt"; echo "$f" | grep -q "Borra 1 imagen(es) de s0 (3.0.0-rc1)"'

finish

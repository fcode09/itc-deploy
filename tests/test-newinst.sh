#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2046  # the cases go in single quotes and are evaluated with eval
# The new-instance wizard of the panel, version 2 (lib/screens/newinst.sh and lib/screens/newinst/*.sh) and what it stands on (lib/core/instname.sh):
# how it is registered and opened, the names that are free (folder, Docker project, Docker network), each of the four steps (name, services,
# versions, data) with its checks, the way around (Enter, Esc, PgUp/PgDn, digits, the click on the bar, Tab for the preview), the instance it creates,
# the golden snapshots of its scenes (tests/tools/newinst_scenes.sh) at 80x24, 120x30 and 160x40 and how it degrades. No real Docker: the simulated
# docker answers with the images of tests/tools/images_scenes.sh, and nothing is deployed.
# Snapshots: tests/golden/newinst/<scene>-<cols>x<rows>-<lang>.txt. DELTACTL_GOLDEN=record rewrites them (only when a change is intended).
# Run it from the root of the isolated copy (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8 LC_ALL=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS DELTACTL_TUI_KEYS DELTACTL_TUI_EVENTS DELTACTL_TUI_ROWS DELTACTL_THEME DELTACTL_WIZARD
unset DELTACTL_REFRESH DELTACTL_METRICS_INTERVAL DELTACTL_TUI_IDLE_AFTER DELTACTL_TUI_GATE DELTACTL_CLIP DELTACTL_PR_SHELL DELTACTL_GRAPH TUI_GRAPH

FIX="$(mktemp -d)"
export FIX
CFG="$FIX/config"
trap 'rm -rf "$FIX" instances/nz-*' EXIT
rm -rf instances/nz-*
mkdir -p "$FIX/bin" "$FIX/frames" "$FIX/nobin" "$FIX/tmp"
: > "$FIX/containers.txt"; : > "$FIX/stats.txt"; : > "$FIX/calls.log"
cp tests/fake-docker.sh "$FIX/bin/docker-fake"
printf '#!/usr/bin/env bash\nexec bash "%s/bin/docker-fake" "$@"\n' "$FIX" > "$FIX/bin/docker"
printf '#!/bin/sh\nexit 0\n' > "$FIX/bin/ss"
chmod +x "$FIX/bin/docker" "$FIX/bin/ss"
printf "#!/bin/sh\nexit 1\n" > "$FIX/nobin/docker"   # (a docker whose daemon does not answer: found first, so the real one never is)
cp "$FIX/bin/ss" "$FIX/nobin/ss"; chmod +x "$FIX/nobin/docker"
export DELTACTL_MEMINFO="$FIX/meminfo" DELTACTL_LOADAVG="$FIX/loadavg" DELTACTL_PROC_ROOT="$FIX/proc" DELTACTL_CGROUP_ROOT="$FIX/cg"
printf 'MemTotal:        8388608 kB\nMemAvailable:    3145728 kB\n' > "$FIX/meminfo"
printf '0.82 0.50 0.40 1/200 1234\n' > "$FIX/loadavg"
# shellcheck source=tests/tools/images_scenes.sh
source tests/tools/images_scenes.sh
# shellcheck source=tests/tools/newinst_scenes.sh
source tests/tools/newinst_scenes.sh
images_fixture "$FIX"
# The files that the secrets step looks for: ONLY this folder (inside the tests DELTACTL_SECRET_DIRS replaces the usual ones: the home folder of
# whoever runs the suite is never read), with one file that has the name of a service account and one that has not.
mkdir -p "$FIX/sf"
printf '{"type":"service_account","project_id":"muni"}\n' > "$FIX/sf/muni-firebase-adminsdk.json"
printf '{"x":1}\n' > "$FIX/sf/notes.json"
printf 'not json\n' > "$FIX/sf/broken-fcm.json"
export DELTACTL_SECRET_DIRS="$FIX/sf"

KEYS="$FIX/keys.txt"
# The panel with the keys given (one per line): UTF-8, no colours, 110 x 34, the wizard of steps (PANEL_COLS, PANEL_ROWS and LANGX change that).
panel() { printf '%s\n' "$@" > "$KEYS"; PATH="${PANEL_PATH:-$FIX/bin}:$PATH" TMPDIR="$FIX/tmp" DELTACTL_CLIP="${PANEL_CLIP:-}" DELTACTL_CONFIG="$CFG" DELTACTL_WIZARD="${WIZ-2}" DELTACTL_TUI_KEYS="$KEYS" DELTACTL_UI=rich DELTACTL_COLOR="${PANEL_COLOR:-never}" DELTACTL_ASCII="${PANEL_ASCII:-0}" DELTACTL_LANG="${LANGX:-es}" COLUMNS="${PANEL_COLS:-110}" DELTACTL_TUI_ROWS="${PANEL_ROWS:-34}" bash ./deltactl 2>&1; }
last_frame() { awk '/^=== frame /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }'; }
# The keys that type a text, one character per line.
typed() { local s="$1" i c; for ((i = 0; i < ${#s}; i++)); do c="${s:i:1}"; if [ "$c" = " " ]; then echo space; else echo "$c"; fi; done; }
# The library: the panel loaded, nothing drawn.
run_lib() { PATH="${LIBPATH:-$FIX/bin:$PATH}" ROOT="$PWD" DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_LANG="${LANGX:-es}" COLUMNS=110 DELTACTL_CONFIG="$CFG" bash -c 'source lib/bootstrap.sh; source lib/cmd/dashboard.sh; '"$1" 2>&1; }

section "1. it is a mode with steps, and it opens only when it is asked for"
check "it is a mode, registered after the old form, and its steps are eight, in order" '[ "$(run_lib "printf \"%s \" \${DASH_MODES[@]}")" = "menu confirm name cmd filter lfilter find wizard newinst palette help options srvask imguse imgload envedit " ] && [ "$(run_lib "printf \"%s \" \${DASH_NZ_STEPS[@]}")" = "name services versions data variables secrets access review " ]'
check "the engine and its steps define the contract" 'run_lib "for f in render key keys sig click tick; do declare -F scr_newinst_\$f >/dev/null || exit 1; done; for s in name services versions data variables secrets access review; do for h in render key enter state; do declare -F dash_nzs_\${s}_\$h >/dev/null || exit 1; done; done"'
check "every step has its name, its question and its key bar in both languages" 'for l in es en; do for s in name services versions data variables secrets access review; do for k in step help keys; do grep -q "MSG_$l\[\"tui.nz.$k.$s\"\]" lib/i18n/$l/newinst.sh || exit 1; done; done; done'
check "by default n opens the wizard of steps (the old form is not what opens)" 'out="$(PANEL_COLS=110 WIZ= panel n | last_frame)"; echo "$out" | grep -q "Paso 1 de 8" && ! echo "$out" | grep -q "Nombre de la instancia"'
check "with DELTACTL_WIZARD=1 the old form opens (the way back)" 'out="$(WIZ=1 panel n | last_frame)"; echo "$out" | grep -q "Nueva instancia" && echo "$out" | grep -q "Nombre de la instancia" && ! echo "$out" | grep -q "Paso 1 de"'
check "with TUI_WIZARD=1 in the config file the old form opens too, and with 2 the new one" 'printf "TUI_WIZARD=1\n" > "$CFG"; out="$(WIZ= panel n | last_frame)"; printf "TUI_WIZARD=2\n" > "$CFG"; out2="$(WIZ= panel n | last_frame)"; rm -f "$CFG"; echo "$out" | grep -q "Nombre de la instancia" && echo "$out2" | grep -q "Paso 1 de 8"'
check "the bar of steps, the form and the preview are on the first frame, with the name proposed" 'f="$(panel n | last_frame)"; echo "$f" | grep -q "Nombre .* Servicios .* Versiones .* Datos" && echo "$f" | grep -q "1 · Nombre" && echo "$f" | grep -q "vista previa" && echo "$f" | grep -q "instances/instancia-1/"'

section "2. a name is free when there is no folder, no Compose project and no network with it"
check "with nothing taken the name is free" '[ "$(run_lib "inst_docker_names; inst_name_clash nz-free && echo free")" = "free" ]'
mkdir -p instances/nz-folder
check "an instances folder takes the name" '[ "$(run_lib "inst_name_clash nz-folder || echo \$INST_CLASH")" = "folder" ]'
printf '%s\n' 'nz-proj|web|running|healthy|img|2026-01-01T00:00:00Z|/nz-proj-web-1|1|0' 'nz-proj|db|exited|none|img|2026-01-01T00:00:00Z|/nz-proj-db-1|0|0' > "$FIX/containers.txt"
printf '%s\n' 'bridge' 'nz-net_default' > "$FIX/networks.txt"
check "a Compose project with containers takes it (a project is counted once)" '[ "$(run_lib "inst_docker_names; inst_name_clash nz-proj || echo \$INST_CLASH; echo \$INST_PROJECTS")" = "project
|nz-proj|" ]'
check "a network <name>_… takes it" '[ "$(run_lib "inst_docker_names; inst_name_clash nz-net || echo \$INST_CLASH")" = "network" ]'
check "a name that only starts like a taken one is free" '[ "$(run_lib "inst_docker_names; inst_name_clash nz-pro && inst_name_clash nz-network && echo free")" = "free" ]'
check "without Docker only the folder counts (and it says it could not ask)" '[ "$(LIBPATH="$FIX/nobin:$PATH" run_lib "inst_docker_names || echo nodocker; inst_name_clash nz-proj && echo free")" = "nodocker
free" ]'
check "asking it at every key costs no process: the function runs no command substitution and never calls docker" '! sed -n "/^inst_name_clash()/,/^}/p" lib/core/instname.sh | grep -q "[$](\|docker\|\`"'
rm -rf instances/nz-folder

section "3. step 1, the name"
out="$(panel n | last_frame)"
check "the first free name is proposed, and it says it is available and where it will be created" 'echo "$out" | grep -q "Nombre .*instancia-1" && echo "$out" | grep -q "Disponible" && echo "$out" | grep -q "Se creará en instances/instancia-1" && echo "$out" | grep -q "Propuesto: la primera libre"'
check "a project, a network and a folder that are taken are skipped when proposing" 'mkdir -p instances/instancia-3; printf "%s\n" "instancia-1|web|running|none|img|2026-01-01T00:00:00Z|/c|1|0" > "$FIX/containers.txt"; printf "%s\n" "instancia-2_default" > "$FIX/networks.txt"; f="$(panel n | last_frame)"; rm -rf instances/instancia-3; : > "$FIX/containers.txt"; rm -f "$FIX/networks.txt"; echo "$f" | grep -q "instances/instancia-4/"'
check "the first key typed replaces the proposal; the preview follows what is typed" 'f="$(panel n $(typed nz-uno) | last_frame)"; echo "$f" | grep -q "instances/nz-uno/" && ! echo "$f" | grep -q "instancia-1" && echo "$f" | grep -q "./deltactl new nz-uno"'
check "digits typed in the name are text, not jumps to a step" 'f="$(panel n $(typed nz-2) | last_frame)"; echo "$f" | grep -q "Paso 1 de 8" && echo "$f" | grep -q "instances/nz-2/"'
check "Backspace on the proposal clears it" 'panel n backspace | last_frame | grep -q "Escribe un nombre"'
check "a name that is not valid says the rule and Enter stays on the step" 'f="$(panel n $(typed Nz) enter | last_frame)"; echo "$f" | grep -q "No es válido" && echo "$f" | grep -q "Paso 1 de 8"'
mkdir -p instances/nz-folder
check "a name that is a folder says so and does not let go on" 'f="$(panel n $(typed nz-folder) enter | last_frame)"; echo "$f" | grep -q "Ya existe la carpeta instances/nz-folder" && echo "$f" | grep -q "Paso 1 de 8"'
rm -rf instances/nz-folder
printf '%s\n' 'nz-proj|web|running|none|img|2026-01-01T00:00:00Z|/c|1|0' > "$FIX/containers.txt"
printf '%s\n' 'nz-net_default' > "$FIX/networks.txt"
check "a name that Docker has as a project says so, with the reason" 'f="$(panel n $(typed nz-proj) | last_frame)"; echo "$f" | grep -q "Docker ya tiene contenedores del proyecto nz-proj" && echo "$f" | grep -q "✖"'
check "a name that Docker has as a network says so" 'panel n $(typed nz-net) enter | last_frame | grep -q "Docker ya tiene una red nz-net_"'
check "it says the same in English" 'LANGX=en panel n $(typed nz-proj) | last_frame | grep -q "Docker already has containers of the project nz-proj"'
: > "$FIX/containers.txt"; rm -f "$FIX/networks.txt"
check "without Docker it warns that only the folder was checked" 'PANEL_PATH="$FIX/nobin" panel n | last_frame | grep -q "Docker no responde: solo se comprobó la carpeta"'

section "4. step 2, the services"
f="$(panel n enter | last_frame)"
check "it shows a card per service of the catalog: what it is, its port, its memory and what it uses" 'echo "$f" | grep -q "s0 · auth-backend" && echo "$f" | grep -q "s1 · gueo-back-end" && echo "$f" | grep -q "autenticación, usuarios" && echo "$f" | grep -q "puerto 41" && echo "$f" | grep -q "512m" && echo "$f" | grep -q "Usa: s0"'
check "both services are marked at the start, and the state of the step says so" 'echo "$f" | grep -q "\[x\] s0" && echo "$f" | grep -q "\[x\] s1" && echo "$f" | grep -q "Servicios   s0 s1"'
check "Space unmarks the one with the cursor and the preview follows; the service that uses it warns" 'g="$(panel n enter space | last_frame)"; echo "$g" | grep -q "\[ \] s0" && echo "$g" | grep -q "COMPOSE_PROFILES=s1" && echo "$g" | grep -q "s1 usa s0, que no está en la instancia" && echo "$g" | grep -q -- "--services s1"'
check "with none marked Enter does not go on and says why" 'g="$(panel n enter space down space enter | last_frame)"; echo "$g" | grep -q "Elige al menos un servicio" && echo "$g" | grep -q "Paso 2 de 8"'
check "a (all) marks them again" 'panel n enter space down space a | last_frame | grep -q "COMPOSE_PROFILES=s0,s1"'
check "a service that is taken out has no version to choose in the next step" 'g="$(panel n enter space enter | last_frame)"; echo "$g" | grep -q "s1 · gueo-back-end" && ! echo "$g" | grep -q "s0 · auth-backend"'

section "5. step 3, the versions"
f="$(panel n enter enter | last_frame)"
check "the table of the first service has the columns, and the most recent version carries the star" 'echo "$f" | grep -q "VERSIÓN .*CREADA .*TAMAÑO .*ARQ .*USO" && echo "$f" | grep -q "2.14.1 ★" && echo "$f" | grep -q "latest ▲" && echo "$f" | grep -q "escribir otra versión"'
check "the star is already chosen for both services: the preview has the tags and Enter alone takes them" 'echo "$f" | grep -q "S0_TAG=2.14.1" && echo "$f" | grep -q "S1_TAG=2.9.0" && echo "$f" | grep -q "Versiones   2.14.1 2.9.0" && echo "$f" | grep -q "s1 · gueo-back-end  2.9.0 ★"'
check "the image for another architecture is in the table, marked ✖" 'echo "$f" | grep -q "3.0.0-rc1 .*arm64 ✖"'
check "Down and Enter choose another version: the preview and the command have it, and the cursor goes to the next service" 'g="$(panel n enter enter down down enter | last_frame)"; echo "$g" | grep -q "S0_TAG=2.14.0" && echo "$g" | grep -q "s0 · auth-backend  2.14.0" && echo "$g" | grep -q "▸ s1 · gueo-back-end" && echo "$g" | grep -q -- "--s0-tag 2.14.0"'
check "the version of another architecture is not chosen: it says why and stays" 'g="$(panel n enter enter up enter | last_frame)"; echo "$g" | grep -q "imagen de arquitectura arm64; este servidor es amd64" && echo "$g" | grep -q "S0_TAG=2.14.1" && echo "$g" | grep -q "Paso 3 de 8"'
check "Enter on the second service chooses it and goes to the next step" 'panel n enter enter enter enter | last_frame | grep -q "Paso 4 de 8"'
check "write another version: a tag that is not loaded can be written now (it says it is not loaded)" 'g="$(panel n enter enter down down down down enter $(typed 2.15) | last_frame)"; echo "$g" | grep -q "aún no está cargada en este Docker" && echo "$g" | grep -q "2.15"'
check "...and Enter takes it and goes on to the next service" 'g="$(panel n enter enter down down down down enter $(typed 2.15) enter | last_frame)"; echo "$g" | grep -q "S0_TAG=2.15" && echo "$g" | grep -q "▸ s1 · gueo-back-end"'
check "a typed tag that is not valid is refused" 'g="$(panel n enter enter down down down down enter $(typed "a b") enter | last_frame)"; echo "$g" | grep -q "no es una etiqueta válida" && echo "$g" | grep -q "S0_TAG=2.14.1"'
check "Esc while typing drops what was typed and keeps the step" 'g="$(panel n enter enter down down down down enter $(typed 2.15) esc | last_frame)"; echo "$g" | grep -q "Paso 3 de 8" && echo "$g" | grep -q "S0_TAG=2.14.1"'
check "R reads Docker again: a version loaded meanwhile appears" 'printf "%s\n" "auth-backend:2.14.1|sha256:a1aaaaaaaaaaaa|amd64" "auth-backend:2.20.0|sha256:a9aaaaaaaaaaaa|amd64" "gueo-back-end:2.9.0|sha256:g1aaaaaaaaaaaa|amd64" > "$FIX/images.txt"; printf "%s\n" "auth-backend:2.14.1|2026-11-22 12:00:00 +0000 UTC" "auth-backend:2.20.0|2026-11-23 12:00:00 +0000 UTC" "gueo-back-end:2.9.0|2026-11-19 12:00:00 +0000 UTC" > "$FIX/image_dates.txt"; g="$(panel n enter enter R | last_frame)"; images_fixture "$FIX"; echo "$g" | grep -q "2.20.0 ★" && echo "$g" | grep -q "S0_TAG=2.20.0"'
check "without Docker the step says it cannot see the versions and lets a tag be written" 'g="$(PANEL_PATH="$FIX/nobin" panel n enter enter | last_frame)"; echo "$g" | grep -q "Docker no responde: no se ven las versiones cargadas" && echo "$g" | grep -q "escribir otra versión" && echo "$g" | grep -q "la de la plantilla"'

section "6. step 4, the data"
f="$(panel n enter enter enter enter | last_frame)"
check "new is proposed and says what it does, and the preview says the data are empty" 'echo "$f" | grep -q "(o) Nueva: empieza de cero" && echo "$f" | grep -q "init las siembra" && echo "$f" | grep -q "data/ vacía: init la siembra" && echo "$f" | grep -q "Datos       nueva" && echo "$f" | grep -q "Enter siguiente"'
check "choosing existing says what it cannot undo, marks the preview and takes out --generate-secrets" 'g="$(panel n enter enter enter enter down | last_frame)"; echo "$g" | grep -q "(o) Ya tiene datos" && echo "$g" | grep -q "init no podrá sembrarla" && echo "$g" | grep -q "Se marca como existente" && echo "$g" | grep -q "data/ ya existente: la de antes" && echo "$g" | grep -q -- "--existing" && ! echo "$g" | grep -q -- "--generate-secrets"'
check "Up goes back to new" 'panel n enter enter enter enter down up | last_frame | grep -q "(o) Nueva"'

section "7. the way around"
check "Esc goes back one step at a time, and Enter forward" 'panel n enter enter esc | last_frame | grep -q "Paso 2 de 8" && panel n enter enter esc esc | last_frame | grep -q "Paso 1 de 8"'
check "on the first step Esc with nothing chosen cancels at once, back on the instances" 'f="$(panel n esc | last_frame)"; echo "$f" | grep -q "Cancelado" && echo "$f" | grep -q "\[1 Instancias\]"'
check "...and with something chosen it asks once: a second Esc cancels, any other key keeps the wizard" 'a="$(panel n $(typed nz-x) esc | last_frame)"; b="$(panel n $(typed nz-x) esc esc | last_frame)"; c="$(panel n $(typed nz-x) esc $(typed y) | last_frame)"; echo "$a" | grep -q "Esc otra vez cancela" && echo "$b" | grep -q "Cancelado" && echo "$c" | grep -q "Paso 1 de 8" && ! echo "$c" | grep -q "Esc otra vez"'
check "the digits jump to a step already visited" 'panel n enter enter enter 2 | last_frame | grep -q "Paso 2 de 8" && panel n enter enter enter 1 | last_frame | grep -q "Paso 1 de 8"'
check "...but not to one that was not reached yet" 'panel n enter 4 | last_frame | grep -q "Paso 2 de 8"'
check "PgDn goes on like Enter (and the gate applies); PgUp goes back" 'panel n pgdn pgdn | last_frame | grep -q "Paso 3 de 8" && panel n pgdn pgdn pgup | last_frame | grep -q "Paso 2 de 8"'
check "the states of the steps already visited show in the bar and in the list" 'g="$(panel n enter enter | last_frame)"; echo "$g" | grep -q "● Nombre" && echo "$g" | grep -q "● Servicios" && echo "$g" | grep -q "◐ Versiones" && echo "$g" | grep -q "○ Datos"'
check "a click on a step already visited opens it; on one that is not, nothing" 'g="$(panel n enter enter mouse:0:8:4 | last_frame)"; echo "$g" | grep -q "Paso 1 de 8" && g="$(panel n mouse:0:100:4 | last_frame)"; echo "$g" | grep -q "Paso 1 de 8"'
check "Tab swaps the form and the preview on a narrow screen, and Tab again comes back" 'a="$(PANEL_COLS=80 PANEL_ROWS=24 panel n tab | last_frame)"; b="$(PANEL_COLS=80 PANEL_ROWS=24 panel n tab tab | last_frame)"; echo "$a" | grep -q "vista previa" && ! echo "$a" | grep -q "1 · Nombre" && echo "$b" | grep -q "1 · Nombre" && ! echo "$b" | grep -q "instances/instancia-1/"'

section "8. it creates the instance with the answers"
if command -v openssl > /dev/null 2>&1; then SECRETS=1; else SECRETS=0; fi
out="$(panel n $(typed nz-uno) enter enter down down enter enter enter s s enter enter enter wait)"
check "the command the panel runs carries the name, the services and the tags the wizard showed" '[ -f instances/nz-uno/.env.instance ] && echo "$out" | grep -q "Ejecutando: ./deltactl new nz-uno --services s0,s1 --s0-tag 2.14.0 --s1-tag 2.9.0"'
check "the answers are applied to the instance" 'grep -qx "S0_TAG=2.14.0" instances/nz-uno/.env.instance && grep -qx "S1_TAG=2.9.0" instances/nz-uno/.env.instance && grep -qx "COMPOSE_PROFILES=s0,s1" instances/nz-uno/.env.instance'
check "the instance it made is the one the command of the preview said (and the secrets are generated when openssl is there)" '[ "$SECRETS" -eq 0 ] || [ "$(grep -E "^JWT_SECRET=" instances/nz-uno/.env.s0 | cut -d= -f2- | wc -c)" -eq 65 ]'
rm -rf instances/nz-uno
out="$(panel n $(typed nz-dos) enter space enter enter enter s s enter enter enter wait)"
check "a service left out is not in the profiles of the instance, and the command did not ask for it" '[ -f instances/nz-dos/.env.instance ] && grep -qx "COMPOSE_PROFILES=s1" instances/nz-dos/.env.instance && echo "$out" | grep -q "Ejecutando: ./deltactl new nz-dos --services s1 " && ! grep -q "^S0_TAG=2" instances/nz-dos/.env.instance'
rm -rf instances/nz-dos
out="$(panel n $(typed nz-tres) enter enter enter enter down enter s s enter enter enter wait)"
check "an existing municipality is created marked as existing, and without generated secrets" '[ -f instances/nz-tres/.env.instance ] && echo "$out" | grep -q "Ejecutando: ./deltactl new nz-tres .*--existing" && ! echo "$out" | grep -q "Ejecutando: .*--generate-secrets" && [ -e instances/nz-tres/.initialized ] && ! grep -Eq "^JWT_SECRET=[0-9a-f]{64}$" instances/nz-tres/.env.s0'
rm -rf instances/nz-tres
check "cancelling half way leaves no folder" 'panel n $(typed nz-cuatro) enter enter esc esc esc esc >/dev/null; [ ! -e instances/nz-cuatro ]'
check "a name that stops being free while the steps go by is checked again at the end: nothing is created and the wizard goes back to the name" '[ "$(run_lib "tui_size; dash_init; dash_nz_open; for k in enter enter enter enter enter s s enter; do scr_newinst_key \$k; done; mkdir -p instances/instancia-1; scr_newinst_key enter; scr_newinst_key enter; rmdir instances/instancia-1; echo \"\$DASH_NZ_I \$DASH_MODE\"" | tail -1)" = "0 newinst" ] && [ ! -e instances/instancia-1 ]'

section "9. snapshots of the scenes (80x24, 120x30 and 160x40)"
GOLD_DIR="${DELTACTL_GOLDEN_DIR:-tests/golden}/newinst"
MODE="${DELTACTL_GOLDEN:-check}"
mkdir -p "$GOLD_DIR" 2> /dev/null || true
# scene <name> <cols> <rows> [lang] -> the frame as the panel draws it (the last one)
scene() {
  local name="$1" cols="$2" rows="$3" lang="${4:-es}"
  env ROOT="$PWD" PATH="$FIX/bin:$PATH" DELTACTL_LANG="$lang" DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never COLUMNS="$cols" DELTACTL_TUI_ROWS="$rows" \
    DELTACTL_CONFIG="$FIX/none" DELTACTL_THEME=matrix HOME="$FIX" XDG_CONFIG_HOME="$FIX/xdg" \
    bash -c 'source lib/bootstrap.sh; source lib/cmd/dashboard.sh; source tests/tools/images_scenes.sh; source tests/tools/newinst_scenes.sh; set +e; newinst_scene '"$name" 2>&1 \
    | awk '/^=== frame /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' | strip_ansi   # (the cursor of a field is a reverse-video escape even without colours)
}
printf '%s\n' 'nz-colorado|web|running|none|img|2026-01-01T00:00:00Z|/c|1|0' > "$FIX/containers.txt"
for sc in "${NEWINST_SCENES[@]}"; do
  for sz in 80x24 120x30 160x40; do
    g="$GOLD_DIR/$sc-$sz-es.txt"
    scene "$sc" "${sz%x*}" "${sz#*x}" es > "$FIX/frames/$sc-$sz-es.txt"
    if [ "$MODE" = record ]; then cp "$FIX/frames/$sc-$sz-es.txt" "$g"; echo "  REC  $sc @ $sz (es)"
    else check "scene $sc at $sz (es) equals its snapshot" '[ -f "$g" ] && cmp -s "$FIX/frames/$sc-$sz-es.txt" "$g"'; fi
  done
done
for sc in name versions data variables secretsfound accessdomain review reviewdeploy; do
  for sz in 80x24 120x30 160x40; do
    g="$GOLD_DIR/$sc-$sz-en.txt"
    scene "$sc" "${sz%x*}" "${sz#*x}" en > "$FIX/frames/$sc-$sz-en.txt"
    if [ "$MODE" = record ]; then cp "$FIX/frames/$sc-$sz-en.txt" "$g"; echo "  REC  $sc @ $sz (en)"
    else check "scene $sc at $sz (en) equals its snapshot" '[ -f "$g" ] && cmp -s "$FIX/frames/$sc-$sz-en.txt" "$g"'; fi
  done
done
: > "$FIX/containers.txt"

section "10. the shape of every frame, and how it degrades"
for sz in 60x14 80x24 100x20 120x30 160x40; do
  for sc in "${NEWINST_SCENES[@]}"; do scene "$sc" "${sz%x*}" "${sz#*x}" es > "$FIX/frames/$sc-$sz-es.txt"; done
done
check "no line is wider than the screen, in any scene and size" 'for f in "$FIX"/frames/*-es.txt; do sz="${f%-es.txt}"; sz="${sz##*-}"; c="${sz%x*}"; awk -v c="$c" "{ if (length(\$0) > c) bad = 1 } END { exit bad }" "$f" || { echo "$f"; exit 1; }; done'
check "a frame has exactly the rows of the screen" 'for f in "$FIX"/frames/*-es.txt; do sz="${f%-es.txt}"; sz="${sz##*-}"; r="${sz#*x}"; c="${sz%x*}"; [ "$c" -ge 60 ] && [ "$r" -ge 14 ] || continue; [ "$(grep -c "" "$f")" -eq "$((r + 1))" ] || { echo "$f $(grep -c "" "$f") $r"; exit 1; }; done'
check "at 120x30 the form and the preview are side by side; at 80x24 there is only the form (and the key to see the preview)" 'grep -q "COMPOSE_PROFILES" "$FIX/frames/name-120x30-es.txt" && ! grep -q "COMPOSE_PROFILES" "$FIX/frames/name-80x24-es.txt" && grep -q "Tab vista previa" "$FIX/frames/name-80x24-es.txt"'
check "the list of the states of the steps is at the right when there is room for it (160x40), not at 80x24" 'grep -q "pasos" "$FIX/frames/name-160x40-es.txt" && ! grep -q "pasos" "$FIX/frames/name-80x24-es.txt"'
check "at 60x14 the bar is two plain lines and the form still has its title" 'f="$FIX/frames/versions-60x14-es.txt"; grep -q "Versiones" "$f" && grep -q "3 · Versiones" "$f"'
check "the English scenes are in English" 'grep -q "Step 1 of 8" "$FIX/frames/name-120x30-en.txt" && grep -q "Which version of each service" "$FIX/frames/versions-120x30-en.txt" && grep -q "New: starts from scratch" "$FIX/frames/data-120x30-en.txt"'
check "in ASCII there is no Unicode in the frame (the steps, the table and the preview)" 'for k in "n" "n enter enter" "n enter enter enter enter"; do g="$(LANGX=en PANEL_ASCII=1 panel $k | last_frame | strip_ansi)"; echo "$g" | grep -q "Step [1-8] of 8" && ! echo "$g" | LC_ALL=C grep -q "[^[:print:]]" || exit 1; done'
check "with colours the frame carries them, and without them it has only the cursor of the field" 'a="$(PANEL_COLOR=always panel n enter | last_frame)"; b="$(panel n enter | last_frame | strip_ansi)"; [ "$(echo "$a" | grep -c "$(printf "\033")")" -gt 5 ] && ! echo "$b" | grep -q "$(printf "\033")"'

section "11. step 5, the variables: what the earlier steps know, what is generated, what the person changes"
# The wizard driven from the library up to the step of the variables (the keys of the first five steps), then what $1 says.
nzlib() { run_lib "tui_size; dash_init; DASH_WIZARD=2; dash_nz_open; DASH_NZ_PBUSY=(); for k in enter enter enter enter enter; do scr_newinst_key \$k; done; $1"; }
S5="n enter enter enter enter enter"
f="$(panel $S5 | last_frame)"
check "the editor is in the step: the files, how many required ones are left, the secrets are dots and say they were generated" 'echo "$f" | grep -q "Paso 5 de 8" && echo "$f" | grep -q "5 · Variables" && echo "$f" | grep -q "obligatorias por poner" && echo "$f" | grep -q "generados" && echo "$f" | grep -q "▾ .env.s0" && echo "$f" | grep -q "JWT_SECRET" && echo "$f" | grep -q "••••"'
check "no secret is ever on the screen (not even the generated ones: 64 hex digits)" '! echo "$f" | grep -Eq "[0-9a-f]{64}"'
check "the bar says what is left (▲ and the number), and the file is said to be made with the instance (no deploy mark yet)" 'echo "$f" | grep -q "se crea con la instancia" && PANEL_COLS=160 PANEL_ROWS=40 panel $S5 | last_frame | grep -q "Variables   faltan"'
check "the model has what the earlier steps decided (the name, the services, the port and the tag), and it is not a change" '[ "$(nzlib "dash_nzv_changed; printf \"%s|%s|%s|%s\" \"\${KEE_VAL[.env.instance|INSTANCE]}\" \"\${KEE_VAL[.env.instance|COMPOSE_PROFILES]}\" \"\${KEE_VAL[.env.instance|S0_TAG]}\" \"\${KEE_BASE[.env.instance|INSTANCE]}\"" | tail -1)" = "instancia-1|s0,s1|2.14.1|instancia-1" ]'
check "the unique secrets are generated here (64 hex digits, the same JWT in both services) and the command is not asked to generate them" '
  nzlib "echo \${KEE_VAL[.env.s0|JWT_SECRET]}-\${KEE_VAL[.env.s1|JWT_SECRET]}" | tail -1 | grep -Eq "^[0-9a-f]{64}-[0-9a-f]{64}$" && nzlib "echo \${KEE_VAL[.env.s0|JWT_SECRET]}-\${KEE_VAL[.env.s1|JWT_SECRET]}" | tail -1 | awk -F- "{ exit !(\$1 == \$2) }" && [ "$(nzlib "echo \$DASH_NZ_GENDONE" | tail -1)" = 1 ] && ! nzlib "dash_nz_argv x; printf \"%s \" \"\${DASH_NZ_ARGV[@]}\"" | tail -1 | grep -q -- "--generate-secrets"'
check "what the template says is the value the file will have: AUTH_URL is not missing, and the databases are named after the instance" '[ "$(nzlib "echo \${KEE_VAL[.env.s1|AUTH_URL]}" | tail -1)" = "http://s0:3200" ] && nzlib "echo \${KEE_VAL[.env.s0|MONGO_URI]}" | tail -1 | grep -q "authsoftware_instancia-1"'
check "the address of the server has no value (the template says CAMBIAR): it is the required one that is left" '[ "$(nzlib "echo \${KEE_VAL[.env.s0|IP_SERVER]:-empty}" | tail -1)" = empty ] && nzlib "echo \$KEE_N_TODO" | tail -1 | grep -q "^[1-9]"'
check "what changed is what the person put and what was generated, never what the earlier steps or the template give" '
  out="$(nzlib "dash_nzv_changed; printf \"%s\n\" \"\${DASH_NZV_CHANGED[@]}\"")"; echo "$out" | grep -q "JWT_SECRET" && ! echo "$out" | grep -q "S0_PORT\|S0_TAG\|INSTANCE\|COMPOSE_PROFILES\|AUTH_URL\|MONGO_URI"'
check "the secrets are in neither the preview nor the command nor the key bar: only a file they are written to when the instance is created" '
  nzlib "v=\${KEE_VAL[.env.s0|JWT_SECRET]}; dash_nz_preview 70; dash_nz_argv x; [[ \"\${DASH_NZ_P[*]} \${DASH_NZ_ARGV[*]}\" != *\"\$v\"* ]] && [[ \"\${DASH_NZ_ARGV[*]}\" == *\"--env-file\"* ]] && echo clean" | tail -1 | grep -q clean'
check "typing the address in one service puts it in the other (both ask for it)" 'g="$(panel $S5 down down enter h t t p : / / m . e x enter | last_frame)"; [ "$(echo "$g" | grep -c "IP_SERVER .*http://m.ex")" -eq 2 ]'
check "...and the count of what is left goes down" 'g="$(panel $S5 down down enter h t t p : / / m . e x enter | last_frame)"; echo "$g" | grep -q "2 puestos" && ! echo "$g" | grep -q "3 obligatorias por poner"'
check "Esc while a value is typed drops it and stays in the step; Esc afterwards goes back to the data" 'g="$(panel $S5 down down enter h t esc | last_frame)"; echo "$g" | grep -q "Paso 5 de 8" && [ "$(echo "$g" | grep -c "(vacía)")" -eq 2 ] && panel $S5 down down enter h t esc esc | last_frame | grep -q "Paso 4 de 8"'
check "digits typed in a value are text, not jumps to a step" 'g="$(panel $S5 down down enter 1 2 | last_frame)"; echo "$g" | grep -q "Paso 5 de 8"'
check "g on a value that is there asks first, and says it replaces it (Esc keeps it)" 'g="$(panel $S5 down down down g | last_frame)"; echo "$g" | grep -qi "genera\|reemplaz" && h="$(panel $S5 down down down g esc | last_frame)"; echo "$h" | grep -q "Paso 5 de 8"'
check "r shows a secret for a while: one row less of dots, and the others stay dots" 'a="$(panel $S5 down down down | last_frame | grep -c "••••")"; b="$(panel $S5 down down down r | last_frame | grep -c "••••")"; [ "$b" -eq "$((a - 1))" ]'
check "s with required ones empty says how many and goes on only the second time (▲)" 'a="$(panel $S5 s | last_frame)"; b="$(panel $S5 s s | last_frame)"; echo "$a" | grep -q "Faltan [0-9]* variables obligatorias" && echo "$a" | grep -q "Paso 5 de 8" && echo "$b" | grep -q "Paso 6 de 8"'
check "any other key in between takes back the second chance" 'panel $S5 s down s | last_frame | grep -q "Paso 5 de 8"'
check "with every required one filled, s goes on at once" 'g="$(panel $S5 down down enter h t t p : / / m . e x enter down down down down down down down down down down down down down down down down down down down enter h t t p : / / m . e x enter s | last_frame)"; echo "$g" | grep -q "Paso 5 de 8\|Paso 6 de 8"'
check "the ports and the versions edited here are the answers of the steps too (preview and command follow them)" '
  nzlib "kee_put .env.instance S0_PORT 4999; dash_nzv_syncback; dash_nz_preview 70; dash_nz_argv x; echo \${DASH_NZ_PORT[s0]}; printf \"%s\n\" \"\${DASH_NZ_P[@]}\" | grep -c S0_PORT=4999" | tail -2 | tr "\n" " " | grep -q "^4999 1 "'
check "an edit survives the model being built again (a service taken out and put back)" 'nzlib "kee_put .env.s0 IP_SERVER http://keep.me; dash_nzv_syncback; DASH_NZ_SEL[s1]=0; dash_nzv_ensure; DASH_NZ_SEL[s1]=1; dash_nzv_ensure; echo \${KEE_VAL[.env.s0|IP_SERVER]}" | tail -1 | grep -q "^http://keep.me$"'
check "for a municipality that already has data no secret is generated (it keeps its own) and the generated ones of before are dropped" '
  [ "$(nzlib "DASH_NZ_DATA=1; dash_nzv_ensure; echo \$DASH_NZ_GENDONE \${#KEE_VAL[.env.s0|JWT_SECRET]} \${DASH_NZV_GENN}" | tail -1)" = "0 0 0" ] && ! nzlib "DASH_NZ_DATA=1; dash_nzv_ensure; dash_nzv_changed; printf \"%s\n\" \"\${DASH_NZV_CHANGED[@]}\"" | grep -q JWT_SECRET'
check "the databases of a municipality that has data are not named after the instance: the URIs are the ones the person gives" '[ "$(nzlib "DASH_NZ_DATA=1; dash_nzv_ensure; echo \${KEE_VAL[.env.s0|MONGO_URI]:-empty}" | tail -1)" = empty ]'
check "the file of answers: mode 600, one line <file>:<KEY>=<value> for each change, the secret in it and nowhere else" '
  nzlib "dash_nzs_variables_prepare; f=\$DASH_NZ_ENVFILE; stat -c %a \$f; grep -c \"^s0:JWT_SECRET=[0-9a-f]\{64\}\$\" \$f; grep -c \"^s1:JWT_SECRET=\" \$f; grep -c \"S0_PORT\|INSTANCE=\" \$f; dash_nz_tmp_clean; [ ! -e \$f ] && echo gone" | tail -5 | tr "\n" " " | grep -q "^600 1 1 0 gone"'
check "the file of answers is in the private folder of the panel and is called in the command with its path, not its content" '
  out="$(panel $S5 s s enter enter | last_frame)"; ! echo "$out" | grep -Eq "[0-9a-f]{64}"'
check "a value that does not pass its rule stops the creation before the file is written, naming the variable and not the value" '
  [ "$(nzlib "KEE_VAL[.env.instance|S0_PORT]=abc-secret; dash_nzs_variables_prepare; echo \$? \$DASH_NZ_ERR; [ -z \"\$DASH_NZ_ENVFILE\" ] && echo nofile" | tail -2 | tr "\n" " " | grep -c "^1 .*S0_PORT.* nofile")" = 1 ] && ! nzlib "KEE_VAL[.env.instance|S0_PORT]=abc-secret; dash_nzs_variables_prepare; echo \$DASH_NZ_ERR" | grep -q "abc-secret"'
check "the files of answers are deleted when the command ends, when the wizard is cancelled and when the panel leaves" '
  nzlib "dash_nzs_variables_prepare; f=\$DASH_NZ_ENVFILE; dash_job_tick; [ ! -e \$f ] && echo ended" | tail -1 | grep -q ended && nzlib "dash_nzs_variables_prepare; f=\$DASH_NZ_ENVFILE; dash_nz_cancel; [ ! -e \$f ] && echo cancelled" | tail -1 | grep -q cancelled && nzlib "dash_nzs_variables_prepare; f=\$DASH_NZ_ENVFILE; dash_shutdown >/dev/null 2>&1; [ ! -e \$f ] && echo left" | tail -1 | grep -q left'
check "the wizard does not open over changes staged in the Variables view (they would be lost): it says so" '
  [ "$(run_lib "tui_size; dash_init; kee_init zz .env.instance; kee_put .env.instance INSTANCE other; DASH_ENV_INST=zz; DASH_WIZARD=2; dash_nz_open; echo \$DASH_MODE; echo \$DASH_MSG" | tail -2 | tr "\n" "|")" = "normal|Hay cambios sin guardar en la vista Variables (zz): guárdalos o descártalos antes de crear una instancia.|" ]'
check "when it opens and when it is cancelled the model of the editor is the Variables view again's to read: nothing of the wizard is left in it" '
  nzlib "dash_nz_cancel; echo \"\${KEE_INST:-none}|\${DASH_ENV_INST:-none}|\${#KEE_VAL[@]}\"" | tail -1 | grep -q "^none|none|0$"'
check "a secret that was shown is hidden by the tick of the screen when its time is up" 'nzlib "KEE_REVEAL_ID=.env.s0|JWT_SECRET; KEE_REVEAL_UNTIL=0; DASH_MODE=newinst; scr_newinst_tick; echo \"[\$KEE_REVEAL_ID]\"" | tail -1 | grep -q "^\[\]$"'
check "the step has its keys in English too, and the count says the same" 'LANGX=en panel $S5 | last_frame | grep -q "required to fill in .* generated"'

section "12. step 6, the files of secrets/"
S6="$S5 s s"
f="$(panel $S6 | last_frame)"
check "a row for each file the services read: its variable and the name it will have in secrets/, with no file yet (▲), and it says where it looked" 'echo "$f" | grep -q "Paso 6 de 8" && echo "$f" | grep -q "s1 FCM_CERT .*secrets/fcm.json" && echo "$f" | grep -q "s1 KEEPER_FCM_CERT .*secrets/keeper-fcm.json" && echo "$f" | grep -q "sin archivo" && echo "$f" | grep -q "Encontré 2 en tus carpetas"'
check "the step says which unique secrets are generated (names, never values)" 'echo "$f" | grep -q "Se generan 4 secretos únicos al crear" && echo "$f" | grep -q "JWT_SECRET" && ! echo "$f" | grep -Eq "[0-9a-f]{64}"'
check "b takes the first file found: it is not JSON, so it says so (without showing it) and the row stays without a file" 'g="$(panel $S6 b | last_frame)"; echo "$g" | grep -q "no es un objeto JSON" && echo "$g" | grep -q "sin archivo" && ! echo "$g" | grep -q "not json"'
check "a second b takes the next one: a service account, chosen, with its path shown under the row" 'panel $S6 b b | last_frame | grep -q "muni-firebase-adminsdk.json"'
check "...and the state of the step in the list says 1 of 2" 'PANEL_COLS=160 PANEL_ROWS=40 panel $S6 b b | last_frame | grep -q "Secretos    1 de 2"'
check "the content of the file is never on the screen" '! panel $S6 b b | last_frame | grep -q "service_account\|project_id"'
check "e types a path: a file that exists and is JSON is taken; Esc drops what was typed" 'p="$FIX/sf/muni-firebase-adminsdk.json"; g="$(panel $S6 e $(typed "$p") enter | last_frame)"; echo "$g" | grep -q "muni-firebase-adminsdk.json" && h="$(panel $S6 e $(typed "$p") esc | last_frame)"; echo "$h" | grep -q "sin archivo"'
check "a path that does not exist says so and stays in the field" 'g="$(panel $S6 e $(typed /nope/none.json) enter | last_frame)"; echo "$g" | grep -q "no existe" && echo "$g" | grep -q "Ruta"'
check "a folder and an empty file are refused, each with its reason; a file that is JSON (any JSON object) is taken" '
  mkdir -p "$FIX/sfd"; : > "$FIX/sf/empty.json"
  panel $S6 e $(typed "$FIX/sfd") enter | last_frame | grep -q "no es un archivo" && panel $S6 e $(typed "$FIX/sf/empty.json") enter | last_frame | grep -q "está vacío" && panel $S6 e $(typed "$FIX/sf/notes.json") enter | last_frame | grep -q "notes.json"; rc=$?; rm -f "$FIX/sf/empty.json"; exit $rc'
check "x takes the file off the row again" 'g="$(panel $S6 b b x | last_frame)"; echo "$g" | grep -q "sin archivo" && ! echo "$g" | grep -q "1 de 2"'
check "the command carries the file for the name the row says (--secret-file <path>:<name>), short in the preview" 'g="$(PANEL_COLS=150 PANEL_ROWS=40 panel $S6 b b enter | last_frame)"; echo "$g" | grep -q -- "--secret-file .*muni-firebase-adminsdk.json:fcm.json"'
check "without a file the step is a warning, not an error: Enter goes on (it can be copied later)" 'panel $S6 enter | last_frame | grep -q "Paso 7 de 8"'
check "a file that is chosen and then gone stops the creation at the last look, says why, and the row is empty again" '
  cp "$FIX/sf/muni-firebase-adminsdk.json" "$FIX/gone.json"; nzlib "dash_nzs_secrets_enter; dash_nzsec_set \"s1|FCM_CERT\" \"$FIX/gone.json\" && echo chosen; rm -f \"$FIX/gone.json\"; dash_nzs_secrets_prepare; echo \$? \$DASH_NZ_ERR; echo \"[\${DASH_NZS_SRC[s1|FCM_CERT]:-}]\"" | tail -3 | tr "\n" "|" | grep -q "^chosen|1 .*no existe.*|\[\]|$"'
check "with only the first service there is nothing to copy and it says so" 'g="$(panel n enter down space enter enter enter s s | last_frame)"; echo "$g" | grep -q "Paso 6 de 8" && echo "$g" | grep -q "Ningún servicio de esta instancia lee archivos de secrets/" && ! echo "$g" | grep -q "FCM_CERT"'
check "for a municipality with data it says no secret is generated" 'panel n enter enter enter enter down enter s s | last_frame | grep -q "Con datos existentes no se generan secretos"'
check "the same in English" 'LANGX=en panel $S6 b b | last_frame | grep -q "unique secrets are generated" && LANGX=en panel $S6 b | last_frame | grep -q "is not a JSON object"'
check "the key bar of the step says what the keys do" 'panel $S6 | last_frame | grep -q "e escribe la ruta · b busca · x quita"'

section "13. step 7, the access: the domain, the proxy, HTTPS, and the block as text"
S7="$S6 enter"
f="$(panel $S7 | last_frame)"
check "the domain is optional and says what happens without one (and that nothing is written in /etc)" 'echo "$f" | grep -q "Paso 7 de 8" && echo "$f" | grep -q "opcional" && echo "$f" | grep -q "Sin dominio no se genera ningún" && echo "$f" | grep -q "Nada se escribe" && ! echo "$f" | grep -q -- "--domain"'
check "the access step no longer creates: its footer says Enter goes on, and nothing is created by it" 'echo "$f" | grep -q "Enter siguiente" && ! echo "$f" | grep -q "Enter crear"'
check "a domain typed makes the block of nginx: a server for each service, to its port, with the name <service>.<domain>" 'g="$(PANEL_ROWS=70 panel $S7 $(typed muni.example.com) | last_frame)"; echo "$g" | grep -q "Bloque de nginx" && echo "$g" | grep -q "server_name auth-backend.muni.example.com;" && echo "$g" | grep -q "proxy_pass http://127.0.0.1:41" && echo "$g" | grep -q "server_name gueo-back-end.muni.example.com;"'
check "the command and the preview carry the domain and HTTPS, and the preview lists the files of proxy/" 'g="$(PANEL_COLS=130 PANEL_ROWS=40 panel $S7 $(typed muni.example.com) | last_frame)"; echo "$g" | grep -q -- "--domain muni.example.com --tls" && echo "$g" | grep -q "proxy/ nginx.conf Caddyfile"'
check "← and → go round nginx, Caddy and both: ← from both chooses Caddy (the block changes, the command says --proxy caddy), → from both chooses nginx" 'g="$(PANEL_ROWS=70 panel $S7 $(typed muni.example.com) down left | last_frame)"; echo "$g" | grep -q "Bloque de Caddy" && echo "$g" | grep -q "reverse_proxy 127.0.0.1" && echo "$g" | grep -q -- "--proxy caddy"; h="$(PANEL_ROWS=70 panel $S7 $(typed muni.example.com) down right | last_frame)"; echo "$h" | grep -q "Bloque de nginx"'
check "Space on HTTPS takes it off: no 443, no redirect, no --tls" 'g="$(PANEL_ROWS=70 panel $S7 $(typed muni.example.com) down down space | last_frame)"; ! echo "$g" | grep -q "listen 443" && ! echo "$g" | grep -q -- "--tls" && echo "$g" | grep -q "listen 80;"'
check "with HTTPS the block has the redirect and the paths of certbot (as text)" 'g="$(PANEL_ROWS=70 panel $S7 $(typed muni.example.com) | last_frame)"; echo "$g" | grep -q "return 301" && echo "$g" | grep -q "listen 443 ssl;"'
check "c copies the block that is shown (the clipboard hook of the tests) and says so" '
  rm -f "$FIX/clip"; g="$(PANEL_CLIP="cat > \"$FIX/clip\"" panel $S7 $(typed muni.example.com) down c | last_frame)"; grep -q "server_name auth-backend.muni.example.com;" "$FIX/clip" && grep -q "proxy_pass" "$FIX/clip" && echo "$g" | grep -q "Bloque copiado"'
check "c with no domain says there is nothing to copy" 'panel $S7 down c | last_frame | grep -q "Pon un dominio válido"'
check "a domain that is not valid says the rule, shows nothing of a block, and Enter stays in the step" 'g="$(panel $S7 $(typed "Muni_X") enter | last_frame)"; echo "$g" | grep -q "no es un nombre válido" && echo "$g" | grep -q "Paso 7 de 8" && ! echo "$g" | grep -q "server_name"'
check "the name is lowered before it is used (the command has it in lowercase)" 'g="$(PANEL_COLS=130 PANEL_ROWS=40 panel $S7 $(typed muni.example.com) | last_frame)"; echo "$g" | grep -q -- "--domain muni.example.com"'
check "the proxy that is on the server is the proposed one; with none, both" 'mkdir -p "$FIX/pb"; printf "#!/bin/sh\nexit 0\n" > "$FIX/pb/caddy"; chmod +x "$FIX/pb/caddy"; g="$(PANEL_PATH="$FIX/pb:$FIX/bin" PANEL_ROWS=70 panel $S7 $(typed muni.example.com) | last_frame)"; echo "$g" | grep -q "caddy was detected\|Se detectó caddy" && echo "$g" | grep -q "Bloque de Caddy"; echo "$f" | grep -q "No se detectó nginx ni Caddy"'
check "it is the same in English" 'LANGX=en panel $S7 $(typed muni.example.com) | last_frame | grep -q "block → instances/instancia-1/proxy/" && LANGX=en panel $S7 | last_frame | grep -q "Without a domain no proxy block is generated"'

section "14. the instance made with all the answers, from the keys, against the simulated docker"
rm -rf instances/nz-cinco "$FIX"/tmp/* "$FIX/clip"
keys5="n $(typed nz-cinco) enter enter enter enter enter down down enter $(typed http://muni.example.com) enter s s b b enter $(typed muni.example.com) enter enter wait"
out="$(panel $keys5)"
check "the command that ran has a file of answers as an option (the rest of the line is longer than the screen: what the other options did is checked in the files below)" '[ -f instances/nz-cinco/.env.instance ] && echo "$out" | grep -q "Ejecutando: ./deltactl new nz-cinco --services s0,s1" && echo "$out" | grep -q -- "--env-file "'
check "no secret is in what the panel printed (the command line, the console, the frames)" '! echo "$out" | grep -Eq "[0-9a-f]{64}"'
check "the address typed is in both services, and the secrets generated are in the files: 64 hex digits, the same JWT in both" 'grep -qx "IP_SERVER=http://muni.example.com" instances/nz-cinco/.env.s0 && grep -qx "IP_SERVER=http://muni.example.com" instances/nz-cinco/.env.s1 && a="$(grep "^JWT_SECRET=" instances/nz-cinco/.env.s0 | cut -d= -f2)" && [ "${#a}" -eq 64 ] && [ "$a" = "$(grep "^JWT_SECRET=" instances/nz-cinco/.env.s1 | cut -d= -f2)" ]'
check "the file chosen is in secrets/ with the name of its row and mode 600, byte for byte" '[ "$(stat -c %a instances/nz-cinco/secrets/fcm.json)" = 600 ] && cmp -s "$FIX/sf/muni-firebase-adminsdk.json" instances/nz-cinco/secrets/fcm.json'
check "the second row (no file chosen) was left alone: nothing in secrets/ for it (it was a warning, not an error)" '[ ! -e instances/nz-cinco/secrets/keeper-fcm.json ] && [ "$(ls -A instances/nz-cinco/secrets | wc -l)" -eq 1 ]'
check "the proxy files are in the instance (and the domain is in them), and nothing was written outside it" '[ -f instances/nz-cinco/proxy/nginx.conf ] && [ -f instances/nz-cinco/proxy/Caddyfile ] && grep -q "server_name auth-backend.muni.example.com;" instances/nz-cinco/proxy/nginx.conf && grep -q "listen 443 ssl;" instances/nz-cinco/proxy/nginx.conf && [ ! -e /etc/nginx/conf.d/nz-cinco.conf ]'
check "the file of answers did not stay anywhere (the private folder of the panel is empty)" '[ -z "$(ls -A "$FIX/tmp" | grep "^deltactl-answers")" ]'
check "no .bak was left in the new instance" '[ -z "$(ls -A instances/nz-cinco | grep "\.bak$")" ]'
rm -rf instances/nz-cinco
out="$(panel n $(typed nz-seis) enter enter enter enter enter s s enter enter enter wait)"
check "with nothing but the defaults the instance is the same as before: generated secrets, no proxy, no files of secrets/" '[ -f instances/nz-seis/.env.instance ] && ! echo "$out" | grep -q -- "--domain" && ! echo "$out" | grep -q -- "--secret-file" && [ ! -d instances/nz-seis/proxy ] && a="$(grep "^JWT_SECRET=" instances/nz-seis/.env.s0 | cut -d= -f2)" && [ "${#a}" -eq 64 ]'
rm -rf instances/nz-seis
check "cancelling in the new steps leaves no folder and no file of answers" 'panel $S6 esc esc esc esc esc esc >/dev/null; [ ! -e instances/instancia-1 ] && [ -z "$(ls -A "$FIX/tmp" | grep "^deltactl-answers")" ]'

section "15. step 8, the review: the only place where the instance is created"
S8="$S7 enter"
f="$(panel $S8 | last_frame)"
check "Enter in the access step goes on to the review and creates nothing" 'echo "$f" | grep -q "Paso 8 de 8" && echo "$f" | grep -q "8 · Revisión" && [ ! -e instances/instancia-1 ]'
check "the review has the readiness bar, an answer for each step and the three buttons" 'g="$(PANEL_ROWS=40 panel $S8 | last_frame)"; echo "$g" | grep -q "listos" && echo "$g" | grep -q "Variables" && echo "$g" | grep -q "\[ Crear \]" && echo "$g" | grep -q "\[ Crear y comprobar \]" && echo "$g" | grep -q "\[ Crear y desplegar \]"'
check "what still needs attention (the variables that are required and empty) is counted in the review" 'g="$(PANEL_ROWS=40 panel $S8 | last_frame)"; echo "$g" | grep -q "con aviso" || echo "$g" | grep -q "por corregir"'
check "the arrows choose the button and say what it does; Create is the proposed one" 'g="$(PANEL_ROWS=40 panel $S8 | last_frame)"; echo "$g" | grep -q "Crea instances/instancia-1. No arranca nada" && h="$(PANEL_ROWS=40 panel $S8 down | last_frame)"; echo "$h" | grep -q "corre ./deltactl check"'
check "the review is in English too" 'LANGX=en PANEL_ROWS=40 panel $S8 | last_frame | grep -q "Step 8 of 8" && LANGX=en PANEL_ROWS=40 panel $S8 | last_frame | grep -q "Create and deploy"'
check "Esc in the review goes back to the access step, and PgDn comes back to the review (and a digit jumps from it)" 'panel $S8 esc | last_frame | grep -q "Paso 7 de 8" && panel $S8 esc pgdn | last_frame | grep -q "Paso 8 de 8" && panel $S8 1 | last_frame | grep -q "Paso 1 de 8"'
out="$(panel n $(typed nz-rev) enter enter enter enter enter s s enter enter enter wait wait wait)"
check "Enter on Create makes the instance, and when the command ends the instance is the one in the Instances view" '[ -f instances/nz-rev/.env.instance ] && echo "$out" | grep -q "Ejecutando: ./deltactl new nz-rev " && echo "$out" | last_frame | grep -q "nz-rev"'
rm -rf instances/nz-rev
out="$(panel n $(typed nz-rev) enter enter enter enter enter s s enter enter down enter wait wait wait)"
check "Create and check creates the instance and then runs check on it" '[ -f instances/nz-rev/.env.instance ] && echo "$out" | grep -q "Ejecutando: ./deltactl new nz-rev " && echo "$out" | grep -q "Ejecutando: ./deltactl check nz-rev"'
rm -rf instances/nz-rev
out="$(panel n $(typed nz-rev) enter enter enter enter enter s s enter enter down down enter | last_frame)"
check "Create and deploy asks for a second Enter first: nothing is created and the screen says it starts containers" '[ ! -e instances/nz-rev ] && echo "$out" | grep -q "arranca contenedores" && echo "$out" | grep -q "Pulsa Enter"'
out="$(panel n $(typed nz-rev) enter enter enter enter enter s s enter enter down down enter up | last_frame)"
check "any other key puts the deploy back: the question is gone and nothing was created" '[ ! -e instances/nz-rev ] && ! echo "$out" | grep -q "Pulsa Enter"'
out="$(panel n $(typed nz-rev) enter enter enter enter enter s s enter enter down down enter enter wait wait wait)"
check "the second Enter creates and then deploys" '[ -f instances/nz-rev/.env.instance ] && echo "$out" | grep -q "Ejecutando: ./deltactl new nz-rev " && echo "$out" | grep -q "Ejecutando: ./deltactl deploy nz-rev"'
rm -rf instances/nz-rev
: > "$FIX/calls.log"   # (that deploy ran against the simulated docker: what it called is not what the last check of the suite is about)
check "a name that stops being free is found at the review: the step of the name opens, nothing is created" '[ "$(run_lib "tui_size; dash_init; dash_nz_open; for k in enter enter enter enter enter s s enter enter; do scr_newinst_key \$k; done; mkdir -p instances/instancia-1; scr_newinst_key enter; rmdir instances/instancia-1; echo \"\$DASH_NZ_I \$DASH_MODE\"" | tail -1)" = "0 newinst" ]'
check "when the command fails the wizard opens again with the answers and says what happened" '[ "$(run_lib "tui_size; dash_init; dash_nz_open; DASH_NZ_NAME=nz-fail; for k in enter enter enter enter enter s s enter enter; do scr_newinst_key \$k; done; DASH_NZ_AFTER_SEQ=7 DASH_NZ_AFTER_ACT=0 DASH_NZ_AFTER_NAME=nz-fail; DASH_MODE=normal; dash_nz_after 1 0; echo \"\$DASH_MODE \$DASH_NZ_I \$DASH_NZ_NAME\"; echo \"\$DASH_NZ_ERR\"" | tr "\n" "|")" = "newinst 7 nz-fail|No se pudo crear nz-fail (código 1): la vista Salida dice por qué. Tus respuestas siguen aquí: corrige y vuelve a crear.|" ]'
check "when the command ends well the wizard releases the answers, selects the instance and opens the view" '[ "$(run_lib "tui_size; dash_init; DASH_NAMES=(a nz-ok b); DASH_NZ_AFTER_SEQ=3 DASH_NZ_AFTER_ACT=0 DASH_NZ_AFTER_NAME=nz-ok; dash_nz_after 0 0; dash_nz_goto_inst; echo \"\$DASH_VIEW \$DASH_SEL [\$DASH_GOTO_INST]\"" | tail -1)" = "instances 1 []" ]'
check "a command that was cancelled counts as a failure (the wizard opens again)" '[ "$(run_lib "tui_size; dash_init; dash_nz_open; DASH_NZ_AFTER_SEQ=3 DASH_NZ_AFTER_ACT=1 DASH_NZ_AFTER_NAME=nz-x; DASH_MODE=normal; dash_nz_after 0 1; echo \"\$DASH_MODE\"" | tail -1)" = "newinst" ]'
rm -rf instances/nz-cli instances/nz-wiz
out="$(panel n $(typed nz-wiz) enter enter down down enter enter enter s s enter enter enter wait wait)"
PATH="$FIX/bin:$PATH" bash ./deltactl new nz-cli --services s0,s1 --s0-tag 2.14.0 --s1-tag 2.9.0 --generate-secrets > /dev/null 2>&1
check "the instance the wizard makes has the same files as the one new makes by hand with the same options" '[ -f instances/nz-wiz/.env.instance ] && [ -f instances/nz-cli/.env.instance ] && [ "$(ls -A instances/nz-wiz | sort | tr "\n" " ")" = "$(ls -A instances/nz-cli | sort | tr "\n" " ")" ]'
# (the ports are the first free ones when each is made: the second instance gets the next block, so they are left out)
diff <(sed "s/nz-wiz/NAME/g" instances/nz-wiz/.env.instance | grep -v "^#\|_PORT=" | sort) <(sed "s/nz-cli/NAME/g" instances/nz-cli/.env.instance | grep -v "^#\|_PORT=" | sort) > "$FIX/envdiff.txt"
check "...and the same variables in .env.instance (apart from the name and the ports)" '[ ! -s "$FIX/envdiff.txt" ]'
rm -rf instances/nz-cli instances/nz-wiz

section "16. no real Docker"
check "the simulated docker is the one found first, and nothing was deployed or run" '[ "$(PATH="$FIX/bin:$PATH" command -v docker)" = "$FIX/bin/docker" ] && ! grep -Eq "compose .*(up|down|stop)|^run " "$FIX/calls.log" 2> /dev/null'

finish

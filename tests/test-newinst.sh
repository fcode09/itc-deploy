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
mkdir -p "$FIX/bin" "$FIX/frames" "$FIX/nobin"
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

KEYS="$FIX/keys.txt"
# The panel with the keys given (one per line): UTF-8, no colours, 110 x 34, the wizard of steps (PANEL_COLS, PANEL_ROWS and LANGX change that).
panel() { printf '%s\n' "$@" > "$KEYS"; PATH="${PANEL_PATH:-$FIX/bin}:$PATH" DELTACTL_CONFIG="$CFG" DELTACTL_WIZARD="${WIZ-2}" DELTACTL_TUI_KEYS="$KEYS" DELTACTL_UI=rich DELTACTL_COLOR="${PANEL_COLOR:-never}" DELTACTL_ASCII="${PANEL_ASCII:-0}" DELTACTL_LANG="${LANGX:-es}" COLUMNS="${PANEL_COLS:-110}" DELTACTL_TUI_ROWS="${PANEL_ROWS:-34}" bash ./deltactl 2>&1; }
last_frame() { awk '/^=== frame /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }'; }
# The keys that type a text, one character per line.
typed() { local s="$1" i c; for ((i = 0; i < ${#s}; i++)); do c="${s:i:1}"; if [ "$c" = " " ]; then echo space; else echo "$c"; fi; done; }
# The library: the panel loaded, nothing drawn.
run_lib() { PATH="${LIBPATH:-$FIX/bin:$PATH}" ROOT="$PWD" DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_LANG="${LANGX:-es}" COLUMNS=110 DELTACTL_CONFIG="$CFG" bash -c 'source lib/bootstrap.sh; source lib/cmd/dashboard.sh; '"$1" 2>&1; }

section "1. it is a mode with steps, and it opens only when it is asked for"
check "it is a mode, registered after the old form, and its steps are four, in order" '[ "$(run_lib "printf \"%s \" \${DASH_MODES[@]}")" = "menu confirm name cmd filter lfilter find wizard newinst palette help options srvask imguse imgload envedit " ] && [ "$(run_lib "printf \"%s \" \${DASH_NZ_STEPS[@]}")" = "name services versions data " ]'
check "the engine and its steps define the contract" 'run_lib "for f in render key keys sig click; do declare -F scr_newinst_\$f >/dev/null || exit 1; done; for s in name services versions data; do for h in render key enter state; do declare -F dash_nzs_\${s}_\$h >/dev/null || exit 1; done; done"'
check "every step has its name, its question and its key bar in both languages" 'for l in es en; do for s in name services versions data; do for k in step help keys; do grep -q "MSG_$l\[\"tui.nz.$k.$s\"\]" lib/i18n/$l/newinst.sh || exit 1; done; done; done'
check "by default n opens the old form" 'out="$(PANEL_COLS=110 WIZ= panel n | last_frame)"; echo "$out" | grep -q "Nueva instancia" && echo "$out" | grep -q "Nombre de la instancia" && ! echo "$out" | grep -q "Paso 1 de"'
check "with DELTACTL_WIZARD=2 it opens the wizard of steps" 'panel n | last_frame | grep -q "Paso 1 de 4"'
check "with TUI_WIZARD=2 in the config file it opens too" 'printf "TUI_WIZARD=2\n" > "$CFG"; out="$(WIZ= panel n | last_frame)"; rm -f "$CFG"; echo "$out" | grep -q "Paso 1 de 4"'
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
check "digits typed in the name are text, not jumps to a step" 'f="$(panel n $(typed nz-2) | last_frame)"; echo "$f" | grep -q "Paso 1 de 4" && echo "$f" | grep -q "instances/nz-2/"'
check "Backspace on the proposal clears it" 'panel n backspace | last_frame | grep -q "Escribe un nombre"'
check "a name that is not valid says the rule and Enter stays on the step" 'f="$(panel n $(typed Nz) enter | last_frame)"; echo "$f" | grep -q "No es válido" && echo "$f" | grep -q "Paso 1 de 4"'
mkdir -p instances/nz-folder
check "a name that is a folder says so and does not let go on" 'f="$(panel n $(typed nz-folder) enter | last_frame)"; echo "$f" | grep -q "Ya existe la carpeta instances/nz-folder" && echo "$f" | grep -q "Paso 1 de 4"'
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
check "with none marked Enter does not go on and says why" 'g="$(panel n enter space down space enter | last_frame)"; echo "$g" | grep -q "Elige al menos un servicio" && echo "$g" | grep -q "Paso 2 de 4"'
check "a (all) marks them again" 'panel n enter space down space a | last_frame | grep -q "COMPOSE_PROFILES=s0,s1"'
check "a service that is taken out has no version to choose in the next step" 'g="$(panel n enter space enter | last_frame)"; echo "$g" | grep -q "s1 · gueo-back-end" && ! echo "$g" | grep -q "s0 · auth-backend"'

section "5. step 3, the versions"
f="$(panel n enter enter | last_frame)"
check "the table of the first service has the columns, and the most recent version carries the star" 'echo "$f" | grep -q "VERSIÓN .*CREADA .*TAMAÑO .*ARQ .*USO" && echo "$f" | grep -q "2.14.1 ★" && echo "$f" | grep -q "latest ▲" && echo "$f" | grep -q "escribir otra versión"'
check "the star is already chosen for both services: the preview has the tags and Enter alone takes them" 'echo "$f" | grep -q "S0_TAG=2.14.1" && echo "$f" | grep -q "S1_TAG=2.9.0" && echo "$f" | grep -q "Versiones   2.14.1 2.9.0" && echo "$f" | grep -q "s1 · gueo-back-end  2.9.0 ★"'
check "the image for another architecture is in the table, marked ✖" 'echo "$f" | grep -q "3.0.0-rc1 .*arm64 ✖"'
check "Down and Enter choose another version: the preview and the command have it, and the cursor goes to the next service" 'g="$(panel n enter enter down down enter | last_frame)"; echo "$g" | grep -q "S0_TAG=2.14.0" && echo "$g" | grep -q "s0 · auth-backend  2.14.0" && echo "$g" | grep -q "▸ s1 · gueo-back-end" && echo "$g" | grep -q -- "--s0-tag 2.14.0"'
check "the version of another architecture is not chosen: it says why and stays" 'g="$(panel n enter enter up enter | last_frame)"; echo "$g" | grep -q "imagen de arquitectura arm64; este servidor es amd64" && echo "$g" | grep -q "S0_TAG=2.14.1" && echo "$g" | grep -q "Paso 3 de 4"'
check "Enter on the second service chooses it and goes to the next step" 'panel n enter enter enter enter | last_frame | grep -q "Paso 4 de 4"'
check "write another version: a tag that is not loaded can be written now (it says it is not loaded)" 'g="$(panel n enter enter down down down down enter $(typed 2.15) | last_frame)"; echo "$g" | grep -q "aún no está cargada en este Docker" && echo "$g" | grep -q "2.15"'
check "...and Enter takes it and goes on to the next service" 'g="$(panel n enter enter down down down down enter $(typed 2.15) enter | last_frame)"; echo "$g" | grep -q "S0_TAG=2.15" && echo "$g" | grep -q "▸ s1 · gueo-back-end"'
check "a typed tag that is not valid is refused" 'g="$(panel n enter enter down down down down enter $(typed "a b") enter | last_frame)"; echo "$g" | grep -q "no es una etiqueta válida" && echo "$g" | grep -q "S0_TAG=2.14.1"'
check "Esc while typing drops what was typed and keeps the step" 'g="$(panel n enter enter down down down down enter $(typed 2.15) esc | last_frame)"; echo "$g" | grep -q "Paso 3 de 4" && echo "$g" | grep -q "S0_TAG=2.14.1"'
check "R reads Docker again: a version loaded meanwhile appears" 'printf "%s\n" "auth-backend:2.14.1|sha256:a1aaaaaaaaaaaa|amd64" "auth-backend:2.20.0|sha256:a9aaaaaaaaaaaa|amd64" "gueo-back-end:2.9.0|sha256:g1aaaaaaaaaaaa|amd64" > "$FIX/images.txt"; printf "%s\n" "auth-backend:2.14.1|2026-11-22 12:00:00 +0000 UTC" "auth-backend:2.20.0|2026-11-23 12:00:00 +0000 UTC" "gueo-back-end:2.9.0|2026-11-19 12:00:00 +0000 UTC" > "$FIX/image_dates.txt"; g="$(panel n enter enter R | last_frame)"; images_fixture "$FIX"; echo "$g" | grep -q "2.20.0 ★" && echo "$g" | grep -q "S0_TAG=2.20.0"'
check "without Docker the step says it cannot see the versions and lets a tag be written" 'g="$(PANEL_PATH="$FIX/nobin" panel n enter enter | last_frame)"; echo "$g" | grep -q "Docker no responde: no se ven las versiones cargadas" && echo "$g" | grep -q "escribir otra versión" && echo "$g" | grep -q "la de la plantilla"'

section "6. step 4, the data"
f="$(panel n enter enter enter enter | last_frame)"
check "new is proposed and says what it does, and the preview says the data are empty" 'echo "$f" | grep -q "(o) Nueva: empieza de cero" && echo "$f" | grep -q "init las siembra" && echo "$f" | grep -q "data/ vacía: init la siembra" && echo "$f" | grep -q "Datos       nueva" && echo "$f" | grep -q "Enter crear"'
check "choosing existing says what it cannot undo, marks the preview and takes out --generate-secrets" 'g="$(panel n enter enter enter enter down | last_frame)"; echo "$g" | grep -q "(o) Ya tiene datos" && echo "$g" | grep -q "init no podrá sembrarla" && echo "$g" | grep -q "Se marca como existente" && echo "$g" | grep -q "data/ ya existente: la de antes" && echo "$g" | grep -q -- "--existing" && ! echo "$g" | grep -q -- "--generate-secrets"'
check "Up goes back to new" 'panel n enter enter enter enter down up | last_frame | grep -q "(o) Nueva"'

section "7. the way around"
check "Esc goes back one step at a time, and Enter forward" 'panel n enter enter esc | last_frame | grep -q "Paso 2 de 4" && panel n enter enter esc esc | last_frame | grep -q "Paso 1 de 4"'
check "on the first step Esc with nothing chosen cancels at once, back on the instances" 'f="$(panel n esc | last_frame)"; echo "$f" | grep -q "Cancelado" && echo "$f" | grep -q "\[1 Instancias\]"'
check "...and with something chosen it asks once: a second Esc cancels, any other key keeps the wizard" 'a="$(panel n $(typed nz-x) esc | last_frame)"; b="$(panel n $(typed nz-x) esc esc | last_frame)"; c="$(panel n $(typed nz-x) esc $(typed y) | last_frame)"; echo "$a" | grep -q "Esc otra vez cancela" && echo "$b" | grep -q "Cancelado" && echo "$c" | grep -q "Paso 1 de 4" && ! echo "$c" | grep -q "Esc otra vez"'
check "the digits jump to a step already visited" 'panel n enter enter enter 2 | last_frame | grep -q "Paso 2 de 4" && panel n enter enter enter 1 | last_frame | grep -q "Paso 1 de 4"'
check "...but not to one that was not reached yet" 'panel n enter 4 | last_frame | grep -q "Paso 2 de 4"'
check "PgDn goes on like Enter (and the gate applies); PgUp goes back" 'panel n pgdn pgdn | last_frame | grep -q "Paso 3 de 4" && panel n pgdn pgdn pgup | last_frame | grep -q "Paso 2 de 4"'
check "the states of the steps already visited show in the bar and in the list" 'g="$(panel n enter enter | last_frame)"; echo "$g" | grep -q "● Nombre" && echo "$g" | grep -q "● Servicios" && echo "$g" | grep -q "◐ Versiones" && echo "$g" | grep -q "○ Datos"'
check "a click on a step already visited opens it; on one that is not, nothing" 'g="$(panel n enter enter mouse:0:20:4 | last_frame)"; echo "$g" | grep -q "Paso 1 de 4" && g="$(panel n mouse:0:100:4 | last_frame)"; echo "$g" | grep -q "Paso 1 de 4"'
check "Tab swaps the form and the preview on a narrow screen, and Tab again comes back" 'a="$(PANEL_COLS=80 PANEL_ROWS=24 panel n tab | last_frame)"; b="$(PANEL_COLS=80 PANEL_ROWS=24 panel n tab tab | last_frame)"; echo "$a" | grep -q "vista previa" && ! echo "$a" | grep -q "1 · Nombre" && echo "$b" | grep -q "1 · Nombre" && ! echo "$b" | grep -q "instances/instancia-1/"'

section "8. it creates the instance with the answers"
if command -v openssl > /dev/null 2>&1; then SECRETS=1; else SECRETS=0; fi
out="$(panel n $(typed nz-uno) enter enter down down enter enter enter wait)"
check "the command the panel runs carries the name, the services and the tags the wizard showed" '[ -f instances/nz-uno/.env.instance ] && echo "$out" | grep -q "Ejecutando: ./deltactl new nz-uno --services s0,s1 --s0-tag 2.14.0 --s1-tag 2.9.0"'
check "the answers are applied to the instance" 'grep -qx "S0_TAG=2.14.0" instances/nz-uno/.env.instance && grep -qx "S1_TAG=2.9.0" instances/nz-uno/.env.instance && grep -qx "COMPOSE_PROFILES=s0,s1" instances/nz-uno/.env.instance'
check "the instance it made is the one the command of the preview said (and the secrets are generated when openssl is there)" '[ "$SECRETS" -eq 0 ] || [ "$(grep -E "^JWT_SECRET=" instances/nz-uno/.env.s0 | cut -d= -f2- | wc -c)" -eq 65 ]'
rm -rf instances/nz-uno
out="$(panel n $(typed nz-dos) enter space enter enter enter wait)"
check "a service left out is not in the profiles of the instance, and the command did not ask for it" '[ -f instances/nz-dos/.env.instance ] && grep -qx "COMPOSE_PROFILES=s1" instances/nz-dos/.env.instance && echo "$out" | grep -q "Ejecutando: ./deltactl new nz-dos --services s1 " && ! grep -q "^S0_TAG=2" instances/nz-dos/.env.instance'
rm -rf instances/nz-dos
out="$(panel n $(typed nz-tres) enter enter enter enter down enter wait)"
check "an existing municipality is created marked as existing, and without generated secrets" '[ -f instances/nz-tres/.env.instance ] && echo "$out" | grep -q "Ejecutando: ./deltactl new nz-tres .*--existing" && ! echo "$out" | grep -q "Ejecutando: .*--generate-secrets" && [ -e instances/nz-tres/.initialized ] && ! grep -Eq "^JWT_SECRET=[0-9a-f]{64}$" instances/nz-tres/.env.s0'
rm -rf instances/nz-tres
check "cancelling half way leaves no folder" 'panel n $(typed nz-cuatro) enter enter esc esc esc esc >/dev/null; [ ! -e instances/nz-cuatro ]'
check "a name that stops being free while the steps go by is checked again at the end: nothing is created and the wizard goes back to the name" '[ "$(run_lib "tui_size; dash_init; dash_nz_open; for k in enter enter enter enter; do scr_newinst_key \$k; done; mkdir -p instances/instancia-1; scr_newinst_key enter; rmdir instances/instancia-1; echo \"\$DASH_NZ_I \$DASH_MODE\"" | tail -1)" = "0 newinst" ] && [ ! -e instances/instancia-1 ]'

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
for sc in name versions data; do
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
check "the English scenes are in English" 'grep -q "Step 1 of 4" "$FIX/frames/name-120x30-en.txt" && grep -q "Which version of each service" "$FIX/frames/versions-120x30-en.txt" && grep -q "New: starts from scratch" "$FIX/frames/data-120x30-en.txt"'
check "in ASCII there is no Unicode in the frame (the steps, the table and the preview)" 'for k in "n" "n enter enter" "n enter enter enter enter"; do g="$(LANGX=en PANEL_ASCII=1 panel $k | last_frame | strip_ansi)"; echo "$g" | grep -q "Step [1-4] of 4" && ! echo "$g" | LC_ALL=C grep -q "[^[:print:]]" || exit 1; done'
check "with colours the frame carries them, and without them it has only the cursor of the field" 'a="$(PANEL_COLOR=always panel n enter | last_frame)"; b="$(panel n enter | last_frame | strip_ansi)"; [ "$(echo "$a" | grep -c "$(printf "\033")")" -gt 5 ] && ! echo "$b" | grep -q "$(printf "\033")"'

section "11. no real Docker"
check "the simulated docker is the one found first, and nothing was deployed or run" '[ "$(PATH="$FIX/bin:$PATH" command -v docker)" = "$FIX/bin/docker" ] && ! grep -Eq "compose .*(up|down|stop)|^run " "$FIX/calls.log" 2> /dev/null'

finish

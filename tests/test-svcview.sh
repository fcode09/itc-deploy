#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # the cases go in single quotes and are evaluated with eval
# The Services tab of the workspace (lib/screens/ws/servicios.sh) and its prompt (lib/screens/svcask.sh): how they are registered and what they
# draw, and their keys end to end against a simulated Docker: add a service (after asking), remove one (typing its key; its data stays), change its
# version, port or memory (checked while typing), deploy it, stop it. Every change is the command `./deltactl service ...` (or the one of always)
# run in the background. No real Docker, nothing is deployed: the simulated docker only notes what it was asked. The snapshots of its scenes are
# in tests/test-workspace.sh. Run it from the root of the isolated copy (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8 LC_ALL=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS DELTACTL_TUI_KEYS DELTACTL_TUI_EVENTS DELTACTL_TUI_ROWS DELTACTL_THEME
unset DELTACTL_REFRESH DELTACTL_METRICS_INTERVAL DELTACTL_TUI_IDLE_AFTER DELTACTL_TUI_GATE DELTACTL_CLIP DELTACTL_PR_SHELL DELTACTL_GRAPH TUI_GRAPH

FIX="$(mktemp -d)"
export FIX
CFG="$FIX/config"
trap 'rm -rf "$FIX" instances/sw-*' EXIT
rm -rf instances/sw-*
mkdir -p "$FIX/bin"
: > "$FIX/calls.log"; : > "$FIX/containers.txt"; : > "$FIX/stats.txt"
cp tests/fake-docker.sh "$FIX/bin/docker-fake"
printf '#!/usr/bin/env bash\nexec bash "%s/bin/docker-fake" "$@"\n' "$FIX" > "$FIX/bin/docker"
printf '#!/bin/sh\nexit 0\n' > "$FIX/bin/ss"
chmod +x "$FIX/bin/docker" "$FIX/bin/ss"
export DELTACTL_MEMINFO="$FIX/meminfo" DELTACTL_LOADAVG="$FIX/loadavg" DELTACTL_PROC_ROOT="$FIX/proc" DELTACTL_CGROUP_ROOT="$FIX/cg"
printf 'MemTotal:        8388608 kB\nMemAvailable:    3145728 kB\n' > "$FIX/meminfo"
printf '0.82 0.50 0.40 1/200 1234\n' > "$FIX/loadavg"
printf 'auth-backend:2.14.1|sha256:aaaa1111|amd64\ngueo-back-end:2.9.0|sha256:bbbb2222|amd64\ngueo-back-end:2.10.0|sha256:bbbb2223|amd64\n' > "$FIX/images.txt"
printf '%s\n' "auth-backend:2.14.1|2026-11-22 12:00:00 +0000 UTC" "gueo-back-end:2.9.0|2026-11-19 12:00:00 +0000 UTC" "gueo-back-end:2.10.0|2026-11-23 12:00:00 +0000 UTC" > "$FIX/image_dates.txt"
touch "$FIX/log_all"

bash ./deltactl new sw-a --services s0,s1 --s0-tag 2.14.1 --s1-tag 2.9.0 --generate-secrets > /dev/null 2>&1
bash ./deltactl new sw-b --services s0 --s0-tag 2.14.1 --s1-tag 2.9.0 > /dev/null 2>&1
mkdir -p instances/sw-a/data/s1/media
echo dato > instances/sw-a/data/s1/media/x.txt

KEYS="$FIX/keys.txt"
# The panel with the keys given (one per line): UTF-8, no colours, 130 x 34 (the overview: the workspace has two tabs, the summary and Services).
panel() { printf '%s\n' "$@" > "$KEYS"; PATH="$FIX/bin:$PATH" DELTACTL_CONFIG="$CFG" DELTACTL_TUI_KEYS="$KEYS" DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_LANG="${LANGX:-es}" COLUMNS="${PANEL_COLS:-130}" DELTACTL_TUI_ROWS="${PANEL_ROWS:-34}" DELTACTL_THEME=matrix bash ./deltactl 2>&1; }
last_frame() { awk '/^=== frame /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }'; }
run_lib() { PATH="$FIX/bin:$PATH" ROOT="$PWD" DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_LANG="${LANGX:-es}" COLUMNS=110 DELTACTL_CONFIG="$CFG" bash -c 'source lib/bootstrap.sh; source lib/cmd/dashboard.sh; '"$1" 2>&1; }
val() { run_lib "get_var_r instances/$1/$2 $3; printf %s \"\$GV\"" | tail -1; }   # instance file variable
prof() { val "$1" .env.instance COMPOSE_PROFILES; }

section "1. the tab and its prompt are registered with one line each"
check "Servicios is the third tab of the workspace, with its file in lib/screens/ws" '[ "$(run_lib "echo \${DASH_WS_TABS[*]}")" = "resumen logs servicios acceso historial" ] && [ -f lib/screens/ws/servicios.sh ]'
check "the prompt is a mode and follows the contract" '[ "$(run_lib "printf \"%s \" \${DASH_MODES[@]}")" != "" ] && run_lib "for f in render key keys sig; do declare -F scr_svcask_\$f >/dev/null || exit 1; done; for f in box key sig texts avail; do declare -F ws_servicios_\$f >/dev/null || exit 1; done"'
check "the tab owns the keyboard: the focus goes to it when it is opened" '[ "$(run_lib "DASH_FOCUS=list; dash_ws_tab_go servicios; echo \$DASH_FOCUS")" = "tab" ] && [ "$(run_lib "DASH_FOCUS=list; dash_ws_tab_go logs; echo \$DASH_FOCUS")" = "logs" ]'
check "its texts exist in both languages" 'for k in $(grep -o "MSG_es\[\"tui\.svc\.[a-z_.]*\"\]" lib/i18n/es/svcview.sh | sed "s/MSG_es/MSG_en/"); do grep -qF "$k" lib/i18n/en/svcview.sh || { echo "falta $k"; exit 1; }; done'

section "2. what the tab draws"
check "> opens it: a row per service of the catalog, the active ones with version, port and memory" '
  f="$(panel ">" | last_frame)"; echo "$f" | grep -q "Resumen \[Servicios\]" && echo "$f" | grep -qE "s0 auth-backend .* 2.14.1 +:[0-9]+ +mem 512m" && echo "$f" | grep -qE "s1 gueo-back-end .* 2.9.0 +:[0-9]+ +mem 2g"'
check "the keys of the footer and of the last line are the tab’s" '
  f="$(panel ">" | last_frame)"; echo "$f" | grep -q "a añadir" && echo "$f" | tail -1 | grep -q "a añadir · X quitar · v versión · P puerto"'
check "the cursor is on the first service and down moves it" '
  panel ">" | last_frame | grep -q "▸ . s0" && panel ">" down | last_frame | grep -q "▸ . s1"'
check "an instance with one service shows the other as not active" '
  f="$(panel down ">" | last_frame)"; echo "$f" | grep -qE "s1 gueo-back-end +. sin activar"'
check "what is under the cursor says what the keys do" 'panel ">" | last_frame | grep -q "Cambia su versión (v)"'
check "in English" 'LANGX=en panel ">" | last_frame | grep -q "Summary \[Services\]" && LANGX=en panel ">" | last_frame | grep -q "Change its version (v)"'
check "Esc and the left arrow go back to the list (the summary is the tab of the services pane)" '
  panel ">" left | last_frame | grep -q "↑↓ instancia" && panel ">" esc | last_frame | grep -q "↑↓ instancia"'

section "3. add: it asks first, and then it is the command"
# the instance that gets the service already has its shared secret; the new service has none (its file is still the template)
sed -i 's/^JWT_SECRET=.*/JWT_SECRET=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/' instances/sw-b/.env.s0
sed -i 's/^JWT_SECRET=.*/JWT_SECRET=/' instances/sw-b/.env.s1
check "a on a service that is not active asks, saying what will be done; nothing changes yet" '
  f="$(panel down ">" down a | last_frame)"; echo "$f" | grep -q "Activa s1 (gueo-back-end) en .sw-b." && [ "$(prof sw-b)" = "s0" ]'
check "n cancels: nothing changes" 'panel down ">" down a n | last_frame | grep -q "Cancelado" && [ "$(prof sw-b)" = "s0" ]'
check "a on a service that is already active says so and asks nothing" 'panel ">" a | last_frame | grep -q "s0 ya está activo"'
check "y runs service add: the service is active, its file exists, with the most recent loaded version" '
  panel down ">" down a y wait > /dev/null; [ "$(prof sw-b)" = "s0,s1" ] && [ -f instances/sw-b/.env.s1 ] && [ "$(val sw-b .env.instance S1_TAG)" = "2.10.0" ]'
check "its own secrets were generated, and the shared one is the one the other service has" '
  [ -n "$(val sw-b .env.s1 FEDERATION_ENCRYPTION_KEY)" ] && [ "$(val sw-b .env.s1 JWT_SECRET)" = "$(val sw-b .env.s0 JWT_SECRET)" ]'

section "4. remove: it asks for the key, and the data stays"
check "X asks to type the key of the service, and says what is kept" '
  f="$(panel ">" down X | last_frame)"; echo "$f" | grep -q "Escribe la clave del servicio (s1)" && echo "$f" | grep -q "se conservan"'
check "a wrong text does not remove it, and the prompt stays open saying what is missing" '
  f="$(panel ">" down X s enter | last_frame)"; [ "$(prof sw-a)" = "s0,s1" ] && echo "$f" | grep -q "escribe s1 tal cual"'
check "Esc cancels: nothing changes" 'panel ">" down X esc | last_frame | grep -q "Cancelado" && [ "$(prof sw-a)" = "s0,s1" ]'
check "with the key typed, Enter removes it: it is out of COMPOSE_PROFILES and its container was stopped" '
  : > "$FIX/all_calls.log"; panel ">" down X s 1 enter wait > /dev/null; [ "$(prof sw-a)" = "s0" ] && grep -q "stop s1" "$FIX/all_calls.log"'
check "its variables, secrets and data are still there" '[ -f instances/sw-a/.env.s1 ] && [ "$(cat instances/sw-a/data/s1/media/x.txt)" = "dato" ]'
check "the only service of an instance cannot be removed: it says so" '
  f="$(panel ">" X | last_frame)"; [ "$(prof sw-a)" = "s0" ] && echo "$f" | grep -q "único servicio"'
check "X on a service that is not active says to activate it first" 'panel ">" down X | last_frame | grep -q "s1 no está activo"'

section "5. version, port and memory: checked while they are typed, and then the command"
check "m opens the prompt with the memory it has now and says it applies when deployed" '
  f="$(panel ">" m | last_frame)"; echo "$f" | grep -q "Límite de memoria de s0 en .sw-a. (ahora 512m)" && echo "$f" | grep -q "512m"'
check "a memory that is not valid says why, and Enter does not write it" '
  panel ">" m backspace backspace backspace backspace a b c enter > /dev/null; [ -z "$(val sw-a .env.instance S0_MEM_LIMIT)" ] || [ "$(val sw-a .env.instance S0_MEM_LIMIT)" != "abc" ]
  panel ">" m backspace backspace backspace backspace a b c | last_frame | grep -q "no es un límite de memoria válido"'
check "a valid one is written with service set" '
  panel ">" m backspace backspace backspace backspace 3 g enter wait > /dev/null; [ "$(val sw-a .env.instance S0_MEM_LIMIT)" = "3g" ]'
check "the same value as it has says nothing changes" 'panel ">" m enter | last_frame | grep -q "no se cambia nada"'
check "P: a port that is out of range is refused and not written" '
  before="$(val sw-a .env.instance S0_PORT)"; panel ">" P backspace backspace backspace backspace 8 0 enter > /dev/null; [ "$(val sw-a .env.instance S0_PORT)" = "$before" ]
  panel ">" P backspace backspace backspace backspace 8 0 | last_frame | grep -q "no es un puerto válido"'
check "P: a port that another instance uses is refused, naming the instance" '
  p="$(val sw-b .env.instance S0_PORT)"; keys=(">" P backspace backspace backspace backspace); for ((i = 0; i < ${#p}; i++)); do keys+=("${p:i:1}"); done
  panel "${keys[@]}" | last_frame | grep -q "sw-b"'
check "P: a free port is written" '
  panel ">" P backspace backspace backspace backspace 4 8 7 7 enter wait > /dev/null; [ "$(val sw-a .env.instance S0_PORT)" = "4877" ]'
check "v: the version prompt says the one it has, and what latest means" '
  f="$(panel ">" v | last_frame)"; echo "$f" | grep -q "Versión de s0 en .sw-a. (ahora 2.14.1)" && echo "$f" | grep -q "latest es"'
check "v: latest is resolved to the most recent loaded version, never written as the word" '
  panel ">" v backspace backspace backspace backspace backspace backspace l a t e s t enter wait > /dev/null; [ "$(val sw-a .env.instance S0_TAG)" = "2.14.1" ] && [ "$(val sw-a .env.instance S0_TAG)" != "latest" ]'
check "v: a version with odd characters is refused while it is typed" '
  panel ">" v backspace backspace backspace backspace backspace backspace "'"'"'" | last_frame | grep -q "solo admite letras"'

section "6. deploy, stop and the rest of what a service does"
fill_instance instances/sw-a 2.14.1 2.9.0   # (complete, so that a deploy passes its checks)
check "u asks before it deploys that one service, and y runs it" '
  panel ">" u | last_frame | grep -q "Despliega s0 en .sw-a." && : > "$FIX/all_calls.log" && panel ">" u y wait > /dev/null && grep -qE "up .*s0|--profile s0" "$FIX/all_calls.log"'
check "s asks before it stops that one service, and y runs it" '
  panel ">" s | last_frame | grep -q "Detiene s0 de .sw-a." && : > "$FIX/all_calls.log" && panel ">" s y wait > /dev/null && grep -q "stop s0" "$FIX/all_calls.log"'
check "R asks before it rolls the service back" 'panel ">" R | last_frame | grep -q "Vuelve s0 de .sw-a. a la versión"'
check "a key the tab does not know falls to the panel (z zooms, q quits)" 'panel ">" q | grep -q "=== frame" '
check ".env.instance has one line per variable after all of this (no duplicates), and its mode is 600" '
  [ -z "$(grep -o "^[A-Z0-9_]*=" instances/sw-a/.env.instance | sort | uniq -d)" ] && [ "$(stat -c %a instances/sw-a/.env.instance)" = "600" ]'

finish

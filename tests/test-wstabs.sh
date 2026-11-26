#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # the cases go in single quotes and are evaluated with eval
# The Variables and Data tabs of the workspace of an instance (lib/screens/ws/variables.sh and datos.sh): how they are registered, what they draw,
# and their keys end to end against a simulated Docker. Variables is the editor of the view Variables inside the workspace (the same model: what is
# staged is kept when the tab is left, and the instance in it does not change while there are changes); Data shows the state of the seeds, the
# marker, the folders of data/ and the seed records, and its two actions are the ones of always (init asks to type the name, adopt asks).
# No real Docker: the simulated docker only notes what it was asked. Run it from the root of the isolated copy (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8 LC_ALL=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS DELTACTL_TUI_KEYS DELTACTL_TUI_EVENTS DELTACTL_TUI_ROWS DELTACTL_THEME
unset DELTACTL_REFRESH DELTACTL_METRICS_INTERVAL DELTACTL_TUI_IDLE_AFTER DELTACTL_TUI_GATE DELTACTL_CLIP DELTACTL_PR_SHELL DELTACTL_GRAPH TUI_GRAPH

FIX="$(mktemp -d)"
export FIX
CFG="$FIX/config"
trap 'rm -rf "$FIX" instances/wt-*' EXIT
rm -rf instances/wt-*
mkdir -p "$FIX/bin"
: > "$FIX/calls.log"; : > "$FIX/containers.txt"; : > "$FIX/stats.txt"
cp tests/fake-docker.sh "$FIX/bin/docker-fake"
printf '#!/usr/bin/env bash\nexec bash "%s/bin/docker-fake" "$@"\n' "$FIX" > "$FIX/bin/docker"
printf '#!/bin/sh\nexit 0\n' > "$FIX/bin/ss"
chmod +x "$FIX/bin/docker" "$FIX/bin/ss"
export DELTACTL_MEMINFO="$FIX/meminfo" DELTACTL_LOADAVG="$FIX/loadavg" DELTACTL_PROC_ROOT="$FIX/proc" DELTACTL_CGROUP_ROOT="$FIX/cg"
printf 'MemTotal:        8388608 kB\nMemAvailable:    3145728 kB\n' > "$FIX/meminfo"
printf '0.82 0.50 0.40 1/200 1234\n' > "$FIX/loadavg"
printf 'backend-s0:2.14.1|sha256:aaaa1111|amd64\nbackend-s1:2.9.0|sha256:bbbb2222|amd64\n' > "$FIX/images.txt"

bash ./deltactl new wt-a --s0-tag 2.14.1 --s1-tag 2.9.0 > /dev/null 2>&1
bash ./deltactl new wt-b --s0-tag 2.14.1 --s1-tag 2.9.0 > /dev/null 2>&1
mkdir -p instances/wt-b/init-logs
: > instances/wt-b/init-logs/20261101T100000Z-s0-wt-b.log
: > instances/wt-b/init-logs/20261102T100000Z-s1-wt-b.log
printf 'SOURCE=init\nINITIALIZED_AT=2026-11-02T10:00:00Z\n' > instances/wt-b/.initialized

KEYS="$FIX/keys.txt"
VR=(">" ">" ">" ">")        # the keys that open Variables at 130 x 34 (Resumen, Acceso, Historial, Servicios, Variables)
DT=(">" ">" ">" ">" ">")    # ... and Datos
# The panel with the keys given (one per line): UTF-8, no colours, 130 x 34 (the overview: the tabs are Resumen, Servicios, Variables, Datos).
panel() { printf '%s\n' "$@" > "$KEYS"; PATH="$FIX/bin:$PATH" DELTACTL_CONFIG="$CFG" DELTACTL_TUI_KEYS="$KEYS" DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_LANG="${LANGX:-es}" COLUMNS="${PANEL_COLS:-130}" DELTACTL_TUI_ROWS="${PANEL_ROWS:-34}" DELTACTL_THEME=matrix bash ./deltactl 2>&1; }
last_frame() { awk '/^=== frame /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }'; }
run_lib() { PATH="$FIX/bin:$PATH" ROOT="$PWD" DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_LANG="${LANGX:-es}" COLUMNS=110 DELTACTL_CONFIG="$CFG" bash -c 'source lib/bootstrap.sh; source lib/cmd/dashboard.sh; '"$1" 2>&1; }

section "1. the two tabs are registered with one line each"
check "Variables and Datos are the last two tabs, each with its file" '[ "$(run_lib "echo \${DASH_WS_TABS[*]}")" = "resumen logs acceso historial servicios variables datos" ] && [ -f lib/screens/ws/variables.sh ] && [ -f lib/screens/ws/datos.sh ]'
check "they define their part of the contract" 'run_lib "for f in box avail key enter sig; do declare -F ws_variables_\$f >/dev/null || exit 1; done; for f in box avail key texts; do declare -F ws_datos_\$f >/dev/null || exit 1; done"'
check "opening Variables gives the editor the keyboard (the mode); Datos takes the keyboard itself" '
  [ "$(run_lib "dash_init; DASH_NAMES=(wt-a); DASH_SEL=0; DASH_FOCUS=list; dash_ws_tab_go variables; echo \$DASH_FOCUS \$DASH_MODE")" = "tab envedit" ] && [ "$(run_lib "dash_init; DASH_NAMES=(wt-a); DASH_SEL=0; DASH_FOCUS=list; dash_ws_tab_go datos; echo \$DASH_FOCUS \$DASH_MODE")" = "tab normal" ]'
check "the texts exist in both languages" 'for k in $(grep -o "MSG_es\[\"tui\.w[a-z.]*\"\]" lib/i18n/es/wsdata.sh | sed "s/MSG_es/MSG_en/"); do grep -qF "$k" lib/i18n/en/wsdata.sh || { echo "falta $k"; exit 1; }; done'

section "2. Datos: the state of the data, the marker, the folders and the seed records"
check "an instance that was not seeded says so, and that there is no marker" '
  f="$(panel "${DT[@]}" | last_frame)"; echo "$f" | grep -q "Variables \[Datos\]" && echo "$f" | grep -q "sin sembrar" && echo "$f" | grep -q "Marcador  no hay"'
check "it lists the folders of data/ of each service that runs, present or not" '
  f="$(panel "${DT[@]}" | last_frame)"; echo "$f" | grep -q "s0 .*media/user" && echo "$f" | grep -q "backups" && echo "$f" | grep -q "s1 .*uploads"'
check "an instance with its marker shows where it came from, and its seed records newest first" '
  f="$(panel down "${DT[@]}" | last_frame)"; echo "$f" | grep -q "SOURCE=init" && echo "$f" | grep -q "2026-11-02T10:00:00Z" && echo "$f" | grep -q "init-logs/) . 2" && echo "$f" | grep -n "20261102T100000Z" | head -1 | cut -d: -f1 | { read -r a; b="$(echo "$f" | grep -n "20261101T100000Z" | head -1 | cut -d: -f1)"; [ "$a" -lt "$b" ]; }'
check "the keys of the tab are in the last line" 'panel "${DT[@]}" | last_frame | tail -1 | grep -q "I sembrar · A adoptar"'
check "in English" 'LANGX=en panel "${DT[@]}" | last_frame | grep -q "Variables \[Data\]" && LANGX=en panel "${DT[@]}" | last_frame | tail -1 | grep -q "I seed · A adopt"'
check "I on an instance that was not seeded asks to type its name, as init does from the menu; nothing runs yet" '
  f="$(panel "${DT[@]}" I | last_frame)"; echo "$f" | grep -qi "wt-a" && echo "$f" | grep -q "Enter confirma" && [ ! -f instances/wt-a/.initialized ]'
check "I on an instance that already has its marker says so and asks nothing" 'panel down "${DT[@]}" I | last_frame | grep -q "wt-b. ya tiene su marcador"'
check "A asks first, saying what it does; n cancels and nothing is written" '
  panel "${DT[@]}" A | last_frame | grep -q "Marca .wt-a. como instancia que ya tenía datos" && panel "${DT[@]}" A n | last_frame | grep -q "Cancelado" && [ ! -f instances/wt-a/.initialized ]'
check "A and y adopts it: the marker is written as existing, and the tab then shows it" '
  panel "${DT[@]}" A y wait > /dev/null; [ -f instances/wt-a/.initialized ] && grep -q "^SOURCE=existing" instances/wt-a/.initialized &&
  panel "${DT[@]}" | last_frame | grep -q "SOURCE=existing"'
check "A on an instance that has its marker says so" 'panel down "${DT[@]}" A | last_frame | grep -q "ya tiene su marcador"'

section "3. Variables: the editor of the view inside the workspace"
check "> > opens the tab with the editor: the files of the instance and what is to fill in, with the keys of the editor in the last line" '
  f="$(panel "${VR[@]}" | last_frame)"; echo "$f" | grep -q "Servicios \[Variables\]" && echo "$f" | grep -q "IP_SERVER" && echo "$f" | tail -1 | grep -q "Enter pliega"'
check "it is the editor of that instance" 'panel "${VR[@]}" | last_frame | grep -q "wt-a"'
check "the keys of the editor win over the panel’s: d is the default of a variable, not the diagnosis" '
  panel "${VR[@]}" d | last_frame | tail -1 | grep -q "Enter pliega"'
check "the keys the editor does not use reach the panel: a digit changes the view" 'panel "${VR[@]}" 5 | last_frame | grep -q "\[5 Salida\]"'
check "Esc leaves the editor and goes back to the list of instances" 'panel "${VR[@]}" esc | last_frame | tail -1 | grep -q "↑↓ instancia"'
check "< and > change tab from inside the editor" '
  panel "${DT[@]}" | last_frame | grep -q "Variables \[Datos\]" && panel "${VR[@]}" "<" | last_frame | grep -q "\[Servicios\]"'
check "q leaves the panel as it does in the view (nothing was staged)" 'panel "${VR[@]}" q | grep -q "=== frame"'
check "choosing an instance while the editor holds changes of another one does not lose them: it says so" '
  run_lib "dash_init; dash_env_load wt-a; kee_dirty() { return 0; }; dash_ws_vars_sync wt-b; echo rc=\$? inst=\$DASH_ENV_INST" | tail -1 | grep -q "rc=1 inst=wt-a"'
check "with nothing staged it moves to the instance chosen" '
  run_lib "dash_init; dash_env_load wt-a; dash_ws_vars_sync wt-b; echo rc=\$? inst=\$DASH_ENV_INST" | tail -1 | grep -q "rc=0 inst=wt-b"'
check "the view Variables and the tab share the editor: what the view has loaded is what the tab shows" '
  run_lib "dash_init; dash_env_load wt-a; DASH_NAMES=(wt-a wt-b); DASH_SEL=0; dash_ws_vars_sync wt-a; echo rc=\$?" | tail -1 | grep -q "rc=0"'

section "4. looking at the tabs and walking through them writes nothing"
sum_files() { cat instances/wt-a/.env.instance instances/wt-a/.env.s0 instances/wt-a/.env.s1 | cksum; find instances/wt-a -maxdepth 1 | sort | cksum; }
sum_files > "$FIX/sum.before"
panel "${VR[@]}" down down ">" "<" "<" esc > /dev/null
check "the variables of the instance (and the list of its files) are exactly as they were: no change, no .bak, no temporary file" '[ "$(sum_files)" = "$(cat "$FIX/sum.before")" ] && ! ls instances/wt-a/.env.s0.* 2>/dev/null | grep -q .'

finish

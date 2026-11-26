#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2046  # the cases go in single quotes and are evaluated with eval
# The Instances view with its workspace (lib/screens/instances.sh, instances_ws.sh, ws/*.sh, lfilter.sh): the list at the left and, for the
# instance that is selected, a workspace at its right that shows its options without pressing anything (the lifecycle, the actions in its
# border, a card per service, and "Para desplegar": what is left before the instance is deployed). Covers how its tabs are registered and when
# the strip shows, that every service is a card or the list it always was, where each row of "Para desplegar" comes from and that Enter runs
# or leads to what resolves it, the filter and the order of the list, the keys (t, < and >, the focus ring), the mouse on the tabs and the rows,
# the golden snapshots of its scenes (tests/tools/ws_scenes.sh) at 80x24, 120x30 and 160x40, and the shape of every frame. No real Docker.
# Snapshots: tests/golden/workspace/<scene>-<cols>x<rows>-<lang>.txt. DELTACTL_GOLDEN=record rewrites them (only when a change is intended).
# Run it from the root of the isolated copy (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8 LC_ALL=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS DELTACTL_TUI_KEYS DELTACTL_TUI_EVENTS DELTACTL_TUI_ROWS DELTACTL_THEME DELTACTL_TUI_WSENV
unset DELTACTL_REFRESH DELTACTL_METRICS_INTERVAL DELTACTL_TUI_IDLE_AFTER DELTACTL_TUI_GATE DELTACTL_CLIP DELTACTL_PR_SHELL DELTACTL_GRAPH TUI_GRAPH

FIX="$(mktemp -d)"
export FIX
trap 'rm -rf "$FIX" instances/tw-*' EXIT
rm -rf instances/tw-*
mkdir -p "$FIX/bin" "$FIX/frames"
: > "$FIX/containers.txt"; : > "$FIX/images.txt"; : > "$FIX/stats.txt"; : > "$FIX/calls.log"
cp tests/fake-docker.sh "$FIX/bin/docker-fake"
cat > "$FIX/bin/docker" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  ps) n=$(wc -l < "$FIX/containers.txt"); for ((i = 1; i <= n; i++)); do echo "c$i"; done ;;
  inspect) cat "$FIX/containers.txt" ;;
  stats) cat "$FIX/stats.txt" ;;
  logs) echo "linea normal"; echo "ERROR de prueba" ;;
  compose) case "$*" in *" logs"*) echo "linea normal"; echo "ERROR de prueba" ;; *) exec bash "$FIX/bin/docker-fake" "$@" ;; esac ;;
  *) exec bash "$FIX/bin/docker-fake" "$@" ;;
esac
SHIM
printf '#!/bin/sh\nexit 0\n' > "$FIX/bin/ss"
chmod +x "$FIX/bin/docker" "$FIX/bin/ss"
export PATH="$FIX/bin:$PATH"
printf 'MemTotal:        8388608 kB\nMemAvailable:    3145728 kB\n' > "$FIX/meminfo"
printf '0.82 0.50 0.40 1/200 1234\n' > "$FIX/loadavg"
export DELTACTL_MEMINFO="$FIX/meminfo" DELTACTL_LOADAVG="$FIX/loadavg"
export DELTACTL_PROC_ROOT="$FIX/proc" DELTACTL_CGROUP_ROOT="$FIX/cg" DELTACTL_CONFIG="$FIX/none.cfg"
# shellcheck source=tests/tools/ws_scenes.sh
source tests/tools/ws_scenes.sh

started() { date -u -d "$1 ago" +%Y-%m-%dT%H:%M:%S.000000000Z; }
container() { printf '%s|%s|%s|%s|%s|%s|/%s_%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$(started "$6")" "$2" "$1" "${7:-0}" "${8:-0}" >> "$FIX/containers.txt"; }
cgroup() {
  mkdir -p "$FIX/proc/$1" "$FIX/cg/scope-$1"
  echo "0::/scope-$1" > "$FIX/proc/$1/cgroup"
  echo "$2" > "$FIX/cg/scope-$1/memory.current"; echo "$3" > "$FIX/cg/scope-$1/memory.max"
  printf 'usage_usec %s\n' "$4" > "$FIX/cg/scope-$1/cpu.stat"
}
image() { printf '%s|%s|amd64\n' "$1" "$2" >> "$FIX/images.txt"; }
deployed() { printf '%s_TAG=%s\n%s_IMAGE_ID=%s\n' "${2^^}" "$3" "${2^^}" "$4" >> "instances/$1/.deployed"; }
newinst() { bash ./deltactl new "$1" >/dev/null 2>&1; fill_instance "instances/$1" "$2" "$3"; }
seeded() { printf 'SOURCE=init\nINITIALIZED_AT=2026-01-01T00:00:00Z\n' > "instances/$1/.initialized"; }
# (fill_instance only puts something in the required values: the schema also wants a base64 of 32 bytes and 32 characters)
complete() { # instance
  sed -i -e 's#^FEDERATION_ENCRYPTION_KEY=.*#FEDERATION_ENCRYPTION_KEY=MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=#' \
    -e 's#^DELTA_UNIVERSITY_HANDOFF_SECRET=.*#DELTA_UNIVERSITY_HANDOFF_SECRET=0123456789abcdef0123456789abcdef#' "instances/$1/.env.s1"
  sed -i "s#^MONGO_URI=.*#MONGO_URI=mongodb://ana:pw@db.itc.pe:27017/auth#" "instances/$1/.env.s0"
}
newinst tw-a 1.0 1.0; seeded tw-a; complete tw-a
# (tw-a is the instance that runs well: it has its access saved, with a name of its own for s0, so that "nothing to resolve" is true of it)
mkdir -p instances/tw-a/proxy; printf 'DOMAIN=itc.pe\nFLAVOR=nginx\nTLS=0\nHOST_S0=backlion.itc.pe\n' > instances/tw-a/proxy/access.conf
newinst tw-b 1.0 1.0                                   # (not seeded, and its variables are still the template's: the files have things to fill in)
newinst tw-c 1.0 1.0; seeded tw-c; complete tw-c
image auth-backend:1.0 sha256:aaa; image gueo-back-end:1.0 sha256:bbb
deployed tw-a s0 1.0 sha256:aaa; deployed tw-a s1 1.0 sha256:bbb
container tw-a s0 running healthy auth-backend:1.0 "2 days" 1234 0
container tw-a s1 running healthy gueo-back-end:1.0 "2 days" 1235 3
container tw-c s0 running healthy auth-backend:1.0 "1 hour" 1236 0
container tw-c s1 exited none gueo-back-end:1.0 "1 hour" 0 0
cgroup 1234 104857600 536870912 5000000
cgroup 1235 629145600 2147483648 9000000
cgroup 1236 52428800 max 100

KEYS="$FIX/keys.txt"
# The panel with the keys given (one per line): ASCII, no colours, 100 x 30 (PANEL_COLS and PANEL_ROWS change that).
panel() { printf '%s\n' "$@" > "$KEYS"; DELTACTL_TUI_KEYS="$KEYS" DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_ASCII=1 COLUMNS="${PANEL_COLS:-100}" DELTACTL_TUI_ROWS="${PANEL_ROWS:-30}" bash ./deltactl 2>&1; }
frame_n() { awk -v n="$1" '/^=== frame /{ f = ($3 == n) } f'; }
last_frame() { awk '/^=== frame /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }'; }
run_lib() { ROOT="$PWD" DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_ASCII=1 COLUMNS=100 bash -c 'source lib/bootstrap.sh; source lib/cmd/dashboard.sh; set +e; '"$1" 2>&1; }

section "1. the tabs of the workspace are registered with one line each"
check "the workspace has the summary, the logs and the access as tabs" '[ "$(run_lib "echo \${DASH_WS_TABS[*]}")" = "resumen logs acceso historial servicios variables datos" ]'
check "each tab is a file of lib/screens/ws" '[ -f lib/screens/ws/resumen.sh ] && [ -f lib/screens/ws/logs.sh ] && [ -f lib/screens/ws/acceso.sh ]'
check "a tab registered with one line is a tab: a made-up one is drawn, its strip appears and its title is read" '[ "$(run_lib "ws_demo_box() { TUI_BOX=(\"demo\"); }; DASH_WS_TABS+=(demo); DASH_WS_TITLE[demo]=tui.ws.tab.logs; DASH_SVCS[x]=\"s0\"; COLUMNS=100; DELTACTL_TUI_ROWS=30; tui_size; dash_ws_visible x; echo \${DASH_WS_VIS[*]}")" = "resumen logs acceso historial servicios variables datos demo" ]'
check "the logs tab is hidden where the logs already sit under the summary (the overview)" '[ "$(run_lib "COLUMNS=160; DELTACTL_TUI_ROWS=40; tui_size; DASH_SVCS[x]=\"s0\"; dash_ws_visible x; echo \${DASH_WS_VIS[*]}")" = "resumen acceso historial servicios variables datos" ] && [ "$(run_lib "COLUMNS=100; DELTACTL_TUI_ROWS=30; tui_size; DASH_SVCS[x]=\"s0\"; dash_ws_visible x; echo \${DASH_WS_VIS[*]}")" = "resumen logs acceso historial servicios variables datos" ]'
check "an instance with no services has no logs tab" '[ "$(run_lib "COLUMNS=100; DELTACTL_TUI_ROWS=30; tui_size; DASH_SVCS[x]=\"\"; dash_ws_visible x; echo \${DASH_WS_VIS[*]}")" = "resumen servicios variables datos" ]'

section "2. selecting an instance shows its options, with nothing more pressed"
out="$(panel q)"
check "the border says who it is, how it is and what can be done to it" 'echo "$out" | frame_n 1 | grep -q "\[tw-a . 2/2\]" && echo "$out" | frame_n 1 | grep -q "\[. en marcha\]" && echo "$out" | frame_n 1 | grep -q "\[^u desplegar\]\|\[u desplegar\]" && echo "$out" | frame_n 1 | grep -q "\[Enter m.s\]"'
check "on a wide box the footer lists deploy, check, status and logs; on a narrow one the first and the last two stay" 'PANEL_COLS=160 PANEL_ROWS=40 panel q | frame_n 1 | grep -q "\[u desplegar\]-\[c comprobar\]-\[s estado\]-\[l logs\]" && echo "$out" | frame_n 1 | grep -q "\[u desplegar\]-.*\[Enter m.s\]"'
check "a strip of tabs names the summary and the logs (the logs are a tab on this size)" 'echo "$out" | frame_n 1 | grep -q "\[Resumen\] Logs"'
check "every service of the instance is in its workspace, with its image, state, uptime and port" 'echo "$out" | frame_n 1 | grep -q "s0 auth-backend:1.0  . healthy" && echo "$out" | frame_n 1 | grep -q "s1 gueo-back-end:1.0  . healthy" && echo "$out" | frame_n 1 | grep -q "activo 2d00h  \.  :4100"'
check "the totals and the data are under the services" 'echo "$out" | frame_n 1 | grep -q "Total  mem 7[0-9][0-9]M/2.5G  cpu 0.0%  datos: sembrados"'
check "an instance with nothing to resolve says so when there is room, and its list shows the instance as it was" 'PANEL_ROWS=50 panel q | frame_n 1 | grep -q "Todo al d.a"'
out="$(panel down q)"
check "selecting another instance shows its own workspace" 'echo "$out" | frame_n 2 | grep -q "\[tw-b . 0/2\]" && echo "$out" | frame_n 2 | grep -q "s0 auth-backend:1.0  . no creado"'
out="$(PANEL_COLS=160 PANEL_ROWS=40 panel q)"
check "on a wide screen each service is a card: its image, its state, its facts, and its memory and CPU as metric rows" 'echo "$out" | frame_n 1 | grep -q "\[s0\]-\[auth-backend:1.0\]-\[. healthy\]" && echo "$out" | frame_n 1 | grep -q "\[s1\]-\[gueo-back-end:1.0\]" && echo "$out" | frame_n 1 | grep -q "mem \.* 100M/512M" && echo "$out" | frame_n 1 | grep -q "mem \.* 600M/2.0G" && echo "$out" | frame_n 1 | grep -q "activo 2d00h  \.  :4100"'
check "a wide screen has no tab for the logs (they are under the summary): the strip has the summary and the access, and the logs are there" 'echo "$out" | frame_n 1 | grep -qE "\[Resumen\] +Acceso +Historial +Servicios" && ! echo "$out" | frame_n 1 | grep -q "Resumen.* Logs" && echo "$out" | frame_n 1 | grep -q "Logs . s0"'
check "a service that does not run has a card too, with no reading" 'PANEL_COLS=160 PANEL_ROWS=40 panel down q | frame_n 2 | grep -q "sin lectura"'
check "the restarts of a service are in its card" 'PANEL_COLS=200 PANEL_ROWS=40 panel q | frame_n 1 | grep -q "reinicios 3"'

section "3. what is left to deploy: where each row comes from, and what Enter does with it"
out="$(panel down q)"
check "what status suggests are rows: the hint is the text, what Enter does is at the right" 'echo "$out" | frame_n 2 | grep -q "Para desplegar . [0-9]" && echo "$out" | frame_n 2 | grep -q "Enter desplegar\|. desplegar"'
out="$(panel t q)"
check "with nothing to resolve t says so and keeps the focus where it was" 'echo "$out" | frame_n 2 | grep -q ">Instancias" && echo "$out" | frame_n 2 | grep -q "No hay nada que resolver"'
out="$(panel down t q)"
check "t gives the cursor to the rows: the border gets the focus and the last line shows their keys" 'echo "$out" | frame_n 3 | grep -q ">tw-b" && echo "$out" | frame_n 3 | grep -q "fila . Enter resolver"'
check "the row under the cursor is marked" 'echo "$out" | frame_n 3 | grep -q "| > ! tw-b no tiene datos iniciales"'
out="$(panel down t left q)"
check "left leaves the rows for the services, and Esc goes back to the list" 'echo "$out" | frame_n 4 | grep -q "servicio . Lt volver" && [ "$(panel down t esc q | frame_n 4 | grep -c ">Instancias")" -ge 1 ]'
: > "$FIX/calls.log"
out="$(panel down t down enter wait q)"
check "Enter on a row that is a command of ours runs it in the console of the panel" 'echo "$out" | grep -q "Ejecutando: ./deltactl deploy tw-b"'
out="$(panel down t enter q)"
check "the row that seeds the data asks for the name of the instance, as the actions menu does" 'echo "$out" | last_frame | grep -qi "escribe el nombre\|nombre de la instancia\|tw-b"  && echo "$out" | grep -qi "sembrar"'
out="$(DELTACTL_TUI_WSENV=1 panel down q)"
check "the variables of the files that are still to fill in are a row (read from the files)" 'echo "$out" | frame_n 2 | grep -q "Faltan variables por rellenar"'
out="$(DELTACTL_TUI_WSENV=1 panel down t down down enter q)"
check "Enter on that row goes to the Variables view, on that instance" 'echo "$out" | last_frame | grep -q "\[9 Variables\]" && echo "$out" | last_frame | grep -q "tw-b"'
check "an instance whose files are complete has no such row" '! DELTACTL_TUI_WSENV=1 panel q | frame_n 1 | grep -q "Faltan variables"'
check "the rows are built from what the panel knows, with no process (no fork in the builder)" '! sed -n "/^dash_todo_build()/,/^}/p" lib/screens/instances_ws.sh | grep -vE "^[[:space:]]*#" | grep -qE "\\$\\([^(]|\`"'
LAST_STARS='IC_N=2; IC_GROUPS=("s0|auth-backend"); IC_TAG=(1.0 2.0); IC_EPOCH=(1700000000 1710000000); IC_KIND=(ver ver); IC_VNUM=(1.0 2.0); IC_VPRE=("" ""); IC_USE=("tw-a(current) " ""); IC_ORDER=(["s0|auth-backend"]="1 0"); IC_STARIDX=(["s0|auth-backend"]=1); DASH_IMG_STATE=ready; DASH_SVCS[tw-a]="s0 s1";'
check "a version that is more recent than the one in use is a row that leads to the images" '[ "$(run_lib "$LAST_STARS dash_ws_stars tw-a; echo \"\$DASH_TODO_STAR\"")" = "s0|2.0|1.0" ]'
check "the star the instance already uses is not a row" '[ -z "$(run_lib "$LAST_STARS IC_USE=(\"\" \"tw-a(current) \"); dash_ws_stars tw-a; echo \"\$DASH_TODO_STAR\"")" ]'
check "without the catalog of Docker there are no rows about versions" '[ -z "$(run_lib "$LAST_STARS DASH_IMG_STATE=none; dash_ws_stars tw-a; echo \"\$DASH_TODO_STAR\"")" ]'
check "a running instance with no access saved has a row that says nobody reaches it by name, and Enter on it opens the Access tab" '[ "$(run_lib "HINTS=(); DASH_KIND[tw-b]=ok; DASH_SVCS[tw-b]=\"s0 s1\"; dash_todo_build tw-b; echo \"\${DASH_TODO_ACT[*]}|\${DASH_TODO[0]}\"")" = "tab:acceso|info|Sin dominio: nadie la alcanza por nombre|falta el bloque de nginx|configurar acceso" ] && [ "$(run_lib "HINTS=(); DASH_KIND[tw-b]=ok; DASH_SVCS[tw-b]=\"s0 s1\"; DASH_NAMES=(tw-b); DASH_SEL=0; DASH_TODO_SEL=0; dash_todo_run tw-b; echo \"\$DASH_WS_TAB \$DASH_FOCUS\"")" = "acceso tab" ]'
check "the row is not there when the access is saved, when the instance is not running well, or when it runs nothing" '[ -z "$(run_lib "HINTS=(); DASH_KIND[tw-a]=ok; DASH_SVCS[tw-a]=\"s0 s1\"; dash_todo_build tw-a; echo \"\${DASH_TODO_ACT[*]}\"")" ] && [ -z "$(run_lib "HINTS=(); DASH_KIND[tw-b]=warn; DASH_SVCS[tw-b]=\"s0 s1\"; dash_todo_build tw-b; echo \"\${DASH_TODO_ACT[*]}\"")" ] && [ -z "$(run_lib "HINTS=(); DASH_KIND[tw-b]=ok; DASH_SVCS[tw-b]=; dash_todo_build tw-b; echo \"\${DASH_TODO_ACT[*]}\"")" ]'
check "the card of a service shows the name it answers to: the one of its own, or <catalog name>.<domain>" 'f="$(PANEL_COLS=160 PANEL_ROWS=40 panel q | frame_n 1)"; echo "$f" | grep -q "backlion.itc.pe" && echo "$f" | grep -q "gueo-back-end.itc.pe"'
check "an instance with no access shows no name in its cards" '[ -z "$(run_lib "DASH_SVCS[tw-b]=\"s0\"; dash_ws_host tw-b s0; echo \$DASH_WS_H")" ] && [ "$(run_lib "DASH_SVCS[tw-a]=\"s0 s1\"; dash_ws_host tw-a s1; echo \$DASH_WS_H")" = "gueo-back-end.itc.pe" ]'
check "the rows about a version lead to the Images view" '[ "$(run_lib "$LAST_STARS DASH_VIEW=instances; DASH_NAMES=(tw-a); DASH_SEL=0; HINTS=(); dash_todo_build tw-a; echo \"\${DASH_TODO_ACT[*]}\"")" = "view:images" ]'
check "what the server lacks is a row while the instance does not run, leading to the Server view" '[ "$(run_lib "DASH_SRV_STATE=ready; DASH_SRV_BAD=1; DASH_SRV_BAD_NAMES=docker; DASH_KIND[tw-b]=err; HINTS=(); dash_todo_build tw-b; echo \"\${DASH_TODO_ACT[*]}\"")" = "view:server" ] && [ -z "$(run_lib "DASH_SRV_STATE=ready; DASH_SRV_BAD=1; DASH_KIND[tw-a]=ok; HINTS=(); dash_todo_build tw-a; echo \"\${DASH_TODO_ACT[*]}\"")" ]'
check "the files that changed since the last deploy are a row that leads to the Variables view" '[ "$(run_lib "HINTS=(); DASH_WS_ENVPEND[tw-a]=\"s0 instance\"; dash_todo_build tw-a; echo \"\${DASH_TODO_ACT[*]}|\${DASH_TODO[0]}\"")" = "view:env|pend|Variables cambiadas sin desplegar|s0, instance|ver variables" ]'
check "a command of status that is not ours (docker load) is a row that only informs" '[ "$(run_lib "HINTS=(\"docker pull tw-a|falta la imagen\"); dash_todo_build tw-a; echo \"\${DASH_TODO_ACT[0]}\"")" = "none" ]'
check "stopping an orphan asks first" '[ "$(run_lib "HINTS=(\"./deltactl stop tw-a s9|sobra\"); DASH_NAMES=(tw-a); DASH_SEL=0; dash_todo_run tw-a; echo \"\$DASH_MODE \${DASH_CONF_ARGV[*]}\"")" = "confirm stop tw-a s9" ]'
check "the cursor of the rows stays inside them when the rows get fewer" '[ "$(run_lib "HINTS=(\"./deltactl deploy tw-a|a\" \"./deltactl check tw-a|b\"); DASH_TODO_SEL=5; dash_todo_build tw-a; echo \$DASH_TODO_SEL")" = "1" ]'

section "4. the keys of the workspace"
out="$(panel '>' q)"
check "> opens the next tab: the logs, with the focus in them" 'echo "$out" | frame_n 2 | grep -q ">Logs" && echo "$out" | frame_n 2 | grep -q "Resumen \[Logs\]" && echo "$out" | frame_n 2 | tail -1 | grep -q "Espacio pausa"'
out="$(panel '>' '<' q)"
check "< goes back to the summary" 'echo "$out" | frame_n 3 | grep -q ">tw-a . 2/2\|>tw-a" && echo "$out" | frame_n 3 | grep -q "\[Resumen\] Logs"'
out="$(panel '<' q)"
check "< from the first tab wraps around to the last (the data)" 'echo "$out" | frame_n 2 | grep -q "\[Datos\]"'
check "on a wide screen > and < have no other tab to go to" '[ "$(PANEL_COLS=160 PANEL_ROWS=40 panel '"'"'>'"'"' q | frame_n 2 | grep -c ">Logs")" -eq 0 ]'
out="$(panel down '>' q)"
check "on the New button the tabs do nothing" '[ "$(panel up '"'"'>'"'"' q | frame_n 3 | grep -c ">Logs")" -eq 0 ]'
check "the focus ring is the list, the services, the rows (when there are some) and the logs" '[ "$(run_lib "DASH_NAMES=(tw-a); DASH_SVCS[tw-a]=\"s0 s1\"; DASH_SEL=0; HINTS=(\"./deltactl deploy tw-a|a\"); COLUMNS=160; DELTACTL_TUI_ROWS=40; tui_size; for i in 1 2 3 4; do dash_focus_cycle 1; printf \"%s \" \$DASH_FOCUS; done")" = "svc todo logs list " ]'
check "with no rows the ring skips them" '[ "$(run_lib "DASH_NAMES=(tw-a); DASH_SVCS[tw-a]=\"s0 s1\"; DASH_SEL=0; HINTS=(); COLUMNS=160; DELTACTL_TUI_ROWS=40; tui_size; for i in 1 2 3; do dash_focus_cycle 1; printf \"%s \" \$DASH_FOCUS; done")" = "svc logs list " ]'
check "selecting another instance gives the cursor of the rows back to the first" '[ "$(run_lib "DASH_NAMES=(tw-a tw-b); DASH_SEL=0; DASH_TODO_SEL=3; dash_select 1; echo \$DASH_TODO_SEL")" = "0" ]'
check "the cursor goes back to the services when the rows it was in are all resolved" '[ "$(run_lib "DASH_VIEW=instances; DASH_NAMES=(tw-a); DASH_SVCS[tw-a]=\"s0\"; DASH_SEL=0; HINTS=(); DASH_FOCUS=todo; dash_ws_tick; echo \$DASH_FOCUS")" = "svc" ] && [ "$(run_lib "DASH_VIEW=instances; DASH_NAMES=(tw-a); DASH_SVCS[tw-a]=\"s0\"; DASH_SEL=0; HINTS=(\"./deltactl deploy tw-a|a\"); DASH_FOCUS=todo; dash_ws_tick; echo \$DASH_FOCUS")" = "todo" ]'
check "the logs zoom works on every size now (the logs are a tab)" '[ "$(run_lib "DASH_NAMES=(tw-a); DASH_SVCS[tw-a]=\"s0\"; DASH_SEL=0; DASH_VIEW=instances; DASH_FOCUS=logs; dash_toggle_zoom; echo \$DASH_ZOOM")" = "1" ]'
out="$(panel z q)"
check "z still zooms the list" 'echo "$out" | frame_n 2 | grep -q ">Instancias" && ! echo "$out" | frame_n 2 | grep -qE -- "\+- >?Consola"'
out="$(panel tab z q)"
check "and the workspace: the whole body is its box" 'echo "$out" | frame_n 3 | grep -q ">tw-a . 2/2" && ! echo "$out" | frame_n 3 | grep -q "Nueva instancia" && ! echo "$out" | frame_n 3 | grep -qE -- "\+- >?Consola"'

section "5. the list: filter and order"
out="$(panel / t w - c enter q)"
check "/ filters the list by what is typed and Enter keeps the filter: the title says which, and only the instances that match are rows" 'echo "$out" | frame_n 7 | grep -q "Instancias . /tw-c" && echo "$out" | frame_n 7 | grep -q "tw-c  *1/2" && ! echo "$out" | frame_n 7 | grep -q "tw-b  *0/2" && ! echo "$out" | frame_n 7 | grep -q "tw-a  *2/2"'
check "the instance in the workspace is one the filter shows" 'echo "$out" | frame_n 7 | grep -q "\[tw-c . 1/2\]"'
out="$(panel / t w - c q)"
check "while it is typed the list narrows, its line is the last of the list's box and the keys line says how it ends" 'echo "$out" | frame_n 3 | grep -q "tw-a  *2/2" && ! echo "$out" | frame_n 6 | grep -q "tw-a  *2/2" && echo "$out" | frame_n 6 | grep -q "| / tw-c|" && echo "$out" | frame_n 6 | grep -q "Enter aplica el filtro"'
out="$(panel / t w - c esc q)"
check "Esc leaves the list as it was" '! echo "$out" | frame_n 7 | grep -q "/tw-c" && echo "$out" | frame_n 7 | grep -q "tw-b  *0/2" && echo "$out" | frame_n 7 | grep -q "tw-a  *2/2"'
out="$(panel / z z z enter q)"
check "a filter that matches nothing says so" 'echo "$out" | frame_n 6 | grep -q "ninguna instancia coincide"'
out="$(panel / t w - c enter / backspace backspace backspace backspace enter q)"
check "the line starts with the filter, and an empty line shows every instance again" 'echo "$out" | frame_n 13 | grep -q "tw-b  *0/2" && ! echo "$out" | frame_n 13 | grep -q "/tw-c"'
out="$(panel / t w - c enter down down q)"
check "the arrows walk only the instances the list shows (and the New button)" 'echo "$out" | frame_n 8 | grep -q "^| > + Nueva instancia" && echo "$out" | frame_n 9 | grep -q "^| > .. tw-c"'
out="$(panel S q)"
check "S sorts the list by state (what needs attention first) and the title says so" 'echo "$out" | frame_n 2 | grep -q "Instancias . por estado" && [ "$(echo "$out" | frame_n 2 | grep -n "tw-c  *1/2" | head -1 | cut -d: -f1)" -lt "$(echo "$out" | frame_n 2 | grep -n "tw-a  *2/2" | head -1 | cut -d: -f1)" ]'
out="$(panel S S q)"
check "and by memory (the one that uses the most first)" 'echo "$out" | frame_n 3 | grep -q "Instancias . por memoria" && [ "$(echo "$out" | frame_n 3 | grep -n "tw-a  *2/2" | head -1 | cut -d: -f1)" -lt "$(echo "$out" | frame_n 3 | grep -n "tw-c  *1/2" | head -1 | cut -d: -f1)" ]'
out="$(panel S S S q)"
check "a third S is back to the name" '! echo "$out" | frame_n 4 | grep -q "por memoria\|por estado"'
check "the filter ignores case" '[ "$(run_lib "DASH_NAMES=(Tw-A tw-b); DASH_LIST_FILTER=TW-a; dash_list_order; echo \${DASH_VIS[*]}")" = "0" ]'
check "the order by state is stable (the same state keeps the order by name)" '[ "$(run_lib "DASH_NAMES=(a b c d); DASH_KIND=([a]=ok [b]=err [c]=ok [d]=err); DASH_LIST_SORT=state; dash_list_order; echo \${DASH_VIS[*]}")" = "1 3 0 2" ]'
check "a click on a row of a sorted list selects the instance that is there" 'echo "$(panel S mouse:0:10:6 q | frame_n 3)" | grep -q "\[tw-c . 1/2\]"'

section "6. the mouse: the tabs and the rows of the workspace"
out="$(panel mouse:0:56:3 q)"
check "a click on the tab of the logs opens it, with the focus in it" 'echo "$out" | frame_n 2 | grep -q ">Logs" && echo "$out" | frame_n 2 | grep -q "Resumen \[Logs\]"'
out="$(panel mouse:0:56:3 mouse:0:48:3 q)"
check "a click on the summary tab brings the services back" 'echo "$out" | frame_n 3 | grep -q "\[Resumen\] Logs" && echo "$out" | frame_n 3 | grep -q ">tw-a"'
ROW="$(( $(panel down q | frame_n 2 | grep -n "tw-b no tiene datos" | head -1 | cut -d: -f1) - 1 ))"
out="$(panel down mouse:0:60:$ROW q)"
check "a click on a row of Para desplegar gives it the cursor" 'echo "$out" | frame_n 3 | grep -q "| > ! tw-b no tiene datos iniciales" && echo "$out" | frame_n 3 | grep -q ">tw-b"'
out="$(panel down mouse:0:60:$((ROW + 1)) mouse:0:60:$((ROW + 1)) wait q)"
check "and a second click on it resolves it: the second row deploys" 'echo "$out" | grep -q "Ejecutando: ./deltactl deploy tw-b"'
out="$(panel mouse:0:10:7 q)"
check "a click on the list still selects an instance" 'echo "$out" | frame_n 2 | grep -q "^| > .. tw-b"'
check "a click on the services (between the border and the rows) does not change what is selected" '[ "$(panel mouse:0:60:6 q | frame_n 2 | grep -c "^| > .. tw-a")" -eq 1 ]'

section "7. snapshots of the scenes (80x24, 120x30 and 160x40)"
GOLD_DIR="${DELTACTL_GOLDEN_DIR:-tests/golden}/workspace"
MODE="${DELTACTL_GOLDEN:-check}"
mkdir -p "$GOLD_DIR" 2> /dev/null || true
# scene <name> <cols> <rows> [lang] -> the frame as the panel draws it (the last one), without escape sequences
scene() {
  local name="$1" cols="$2" rows="$3" lang="${4:-es}"
  env ROOT="$PWD" PATH="$FIX/bin:$PATH" DELTACTL_LANG="$lang" DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never COLUMNS="$cols" DELTACTL_TUI_ROWS="$rows" \
    DELTACTL_CONFIG="$FIX/none" DELTACTL_THEME=matrix HOME="$FIX" XDG_CONFIG_HOME="$FIX/xdg" \
    bash -c 'source lib/bootstrap.sh; source lib/cmd/dashboard.sh; source tests/tools/ws_scenes.sh; set +e; ws_scene '"$name" 2>&1 \
    | awk '/^=== frame /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' | sed 's/\x1b\[[0-9;]*m//g'
}
for sc in "${WS_SCENES[@]}"; do
  for sz in 80x24 120x30 160x40; do
    g="$GOLD_DIR/$sc-$sz-es.txt"
    scene "$sc" "${sz%x*}" "${sz#*x}" es > "$FIX/frames/$sc-$sz-es.txt"
    if [ "$MODE" = record ]; then cp "$FIX/frames/$sc-$sz-es.txt" "$g"; echo "  REC  $sc @ $sz (es)"
    else check "scene $sc at $sz (es) equals its snapshot" '[ -f "$g" ] && cmp -s "$FIX/frames/$sc-$sz-es.txt" "$g"'; fi
  done
done
for sc in cards todofocus logs servicios asktag; do
  for sz in 80x24 120x30 160x40; do
    g="$GOLD_DIR/$sc-$sz-en.txt"
    scene "$sc" "${sz%x*}" "${sz#*x}" en > "$FIX/frames/$sc-$sz-en.txt"
    if [ "$MODE" = record ]; then cp "$FIX/frames/$sc-$sz-en.txt" "$g"; echo "  REC  $sc @ $sz (en)"
    else check "scene $sc at $sz (en) equals its snapshot" '[ -f "$g" ] && cmp -s "$FIX/frames/$sc-$sz-en.txt" "$g"'; fi
  done
done

section "8. the shape of every frame"
# (80x24, 120x30 and 160x40 are the frames of the snapshots above)
for sz in 60x14 100x20 100x30 140x34; do
  for sc in "${WS_SCENES[@]}"; do
    scene "$sc" "${sz%x*}" "${sz#*x}" es > "$FIX/frames/$sc-$sz-es.txt"
  done
done
check "no line is wider than the screen, in any scene and size" 'for f in "$FIX"/frames/*-es.txt; do sz="${f%-es.txt}"; sz="${sz##*-}"; c="${sz%x*}"; awk -v c="$c" "{ if (length(\$0) > c) bad = 1 } END { exit bad }" "$f" || { echo "$f"; exit 1; }; done'
check "a frame has exactly the rows of the screen" 'for f in "$FIX"/frames/*-es.txt; do sz="${f%-es.txt}"; sz="${sz##*-}"; r="${sz#*x}"; c="${sz%x*}"; [ "$c" -ge 60 ] && [ "$r" -ge 14 ] || continue; [ "$(grep -c "" "$f")" -eq "$((r + 1))" ] || { echo "$f $(grep -c "" "$f") $r"; exit 1; }; done'
check "every line of a body is as wide as the screen: the boxes close at the same column (a dialog is narrower by design)" 'for f in "$FIX"/frames/*-es.txt; do case "$f" in */ask*) continue ;; esac; sz="${f%-es.txt}"; sz="${sz##*-}"; c="${sz%x*}"; r="${sz#*x}"; [ "$c" -ge 80 ] || continue; awk -v c="$c" -v r="$r" "NR>=4 && NR<=r-1 { if (length(\$0) != c) { bad = 1; print FILENAME, NR, length(\$0) > \"/dev/stderr\" } } END { exit bad }" "$f" || exit 1; done'
check "the scenes show no secret and no raw escape sequence" '! grep -l "$(printf "\033")" "$FIX"/frames/*-es.txt | grep -q .'

section "9. the cache of the box: the summary is drawn again only when what it shows changes"
check "the box of the summary is kept while nothing it depends on changes" '[ "$(run_lib "COLUMNS=110; DELTACTL_TUI_ROWS=30; tui_size; dash_init; dash_refresh; dash_render >/dev/null; WS_CALLS=0; ws_resumen_box() { WS_CALLS=\$((WS_CALLS + 1)); TUI_BOX=(); }; DASH_MODE=cmd; DASH_BUF=x; dash_render >/dev/null; a=\$WS_CALLS; MT_SAMPLES=\$((MT_SAMPLES + 1)); dash_render >/dev/null; echo \$a-\$WS_CALLS")" = "0-1" ]'
check "the cursor of the rows is part of what the box depends on" '[ "$(run_lib "COLUMNS=110; DELTACTL_TUI_ROWS=30; tui_size; dash_init; dash_refresh; HINTS=(\"./deltactl deploy tw-a|a\" \"./deltactl check tw-a|b\"); dash_render >/dev/null; a=\$(dash_ws_sig tw-a; echo \$DASH_WS_SIG); DASH_TODO_SEL=1; b=\$(dash_ws_sig tw-a; echo \$DASH_WS_SIG); [ \"\$a\" != \"\$b\" ] && echo different")" = "different" ]'

finish

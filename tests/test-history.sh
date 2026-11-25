#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2046  # the cases go in single quotes and are evaluated with eval
# The History tab of the workspace of an instance (lib/screens/ws/historial.sh) and the way to another service inside the Logs tab ({ and }).
# Covers: that it is registered with one line, that it lists only the operations of the instance on screen (newest first) and says so when it has none,
# the detail of the selected run (state, command, when, how long and the summary of what it printed, or the end of the output when the command has
# no shape), the keys (up, down, Home, End, PgUp, PgDn, Enter opens the whole saved output in the viewer of the Runs view), that the selection follows
# the run and not the row, that what a file says is data (a run with escape sequences cannot move the cursor or change the screen), that the drawing
# starts no process and that the tab reads nothing while another one is on screen. The snapshots of its scenes are in tests/test-workspace.sh. No real Docker.
# Run it from the root of the isolated copy (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8 LC_ALL=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS DELTACTL_TUI_KEYS DELTACTL_TUI_EVENTS DELTACTL_TUI_ROWS DELTACTL_THEME DELTACTL_TUI_WSENV DELTACTL_TUI_WSACC
unset DELTACTL_REFRESH DELTACTL_METRICS_INTERVAL DELTACTL_TUI_IDLE_AFTER DELTACTL_TUI_GATE DELTACTL_CLIP DELTACTL_PR_SHELL DELTACTL_GRAPH TUI_GRAPH

FIX="$(mktemp -d)"
export FIX
trap 'rm -rf "$FIX" instances/th-* instances/.deltactl' EXIT
rm -rf instances/th-* instances/.deltactl
mkdir -p "$FIX/bin"
: > "$FIX/containers.txt"; : > "$FIX/images.txt"; : > "$FIX/stats.txt"
cp tests/fake-docker.sh "$FIX/bin/docker-fake"
cat > "$FIX/bin/docker" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  ps) n=$(wc -l < "$FIX/containers.txt"); for ((i = 1; i <= n; i++)); do echo "c$i"; done ;;
  inspect) cat "$FIX/containers.txt" ;;
  stats) cat "$FIX/stats.txt" ;;
  logs) echo "linea normal" ;;
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

newinst() { bash ./deltactl new "$1" > /dev/null 2>&1; }
newinst th-a; newinst th-b; newinst th-c; newinst th-d
STATE=instances/.deltactl
rm -rf "$STATE"      # (creating the instances left their own runs: the cases start from the ones made here)
mkdir -p "$STATE/runs"
# A run on disk, as the runs left it: its metadata, its output and its line of the index.
mkrun() { # id op args instance state rc started ms output-file [user]
  mkdir -p "$STATE/runs/$1"
  printf 'RUN_ID=%s\nOP=%s\nARGS=%s\nINSTANCE=%s\nSTATE=%s\nRC=%s\nSTARTED_AT=%s\nENDED_AT=%s\nDURATION_MS=%s\nUSER=%s\nHOST=testhost\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$7" "$8" "${10:-ana}" > "$STATE/runs/$1/meta"
  cp "$9" "$STATE/runs/$1/out.log"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$7" "$2" "$4" "$5" "$6" "$8" >> "$STATE/runs.idx"
}
printf 'Rolling back auth-backend to 2.13.0\nDone\n' > "$FIX/plain.txt"
mkrun 20261031T150000Z-3 rollback "th-a s0" th-a succeeded 0 2026-10-31T15:00:00Z 5300 "$FIX/plain.txt"
mkrun 20261101T090000Z-2 check th-a th-a failed 1 2026-11-01T09:00:00Z 2100 tests/golden/outsum/in/check-fail-es.txt
mkrun 20261101T095000Z-4 deploy th-b th-b succeeded 0 2026-11-01T09:50:00Z 30100 tests/golden/outsum/in/deploy-es.txt
mkrun 20261101T100000Z-1 deploy th-a th-a succeeded 0 2026-11-01T10:00:00Z 41200 tests/golden/outsum/in/deploy-es.txt
# A run whose files say things a terminal would obey: the user name and the output have escape sequences.
printf 'line with \033[2J\033[Hclear and \033[31mred\033[0m\nsecond line\n' > "$FIX/hostile.txt"
mkrun 20261102T080000Z-5 rollback "th-c s0" th-c succeeded 0 2026-11-02T08:00:00Z 900 "$FIX/hostile.txt" $'\033[31mevil'

KEYS="$FIX/keys.txt"
# The panel with the keys given (one per line): ASCII, no colours, 160 x 40. PANEL_COLS / PANEL_ROWS / LANGX change it.
panel() { printf '%s\n' "$@" > "$KEYS"; DELTACTL_TUI_KEYS="$KEYS" DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_ASCII=1 COLUMNS="${PANEL_COLS:-160}" DELTACTL_TUI_ROWS="${PANEL_ROWS:-40}" DELTACTL_LANG="${LANGX:-es}" bash ./deltactl 2>&1; }
last_frame() { awk '/^=== frame /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }'; }
frame_n() { awk -v n="$1" '/^=== frame /{ f = ($3 == n) } f'; }
run_lib() { ROOT="$PWD" DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_ASCII=1 COLUMNS=160 DELTACTL_TUI_ROWS=40 bash -c 'source lib/bootstrap.sh; source lib/cmd/dashboard.sh; set +e; '"$1" 2>&1; }

section "1. it is a tab, registered with one line"
check "the history tab is a file of lib/screens/ws with one line in instances_ws.sh, after the access" '[ -f lib/screens/ws/historial.sh ] && grep -q "^dash_ws_register historial " lib/screens/instances_ws.sh && [ "$(run_lib "echo \${DASH_WS_TABS[*]}")" = "resumen logs acceso historial servicios" ]'
check "an instance with no services has only the summary and the services (no access, no history)" '[ "$(run_lib "COLUMNS=100; DELTACTL_TUI_ROWS=30; tui_size; DASH_SVCS[x]=\"\"; dash_ws_visible x; echo \${DASH_WS_VIS[*]}")" = "resumen servicios" ]'
check "on a wide screen the tabs are the summary, the access, the history and the services (the logs are under the summary)" '[ "$(run_lib "tui_size; DASH_SVCS[x]=\"s0\"; dash_ws_visible x; echo \${DASH_WS_VIS[*]}")" = "resumen acceso historial servicios" ]'

section "2. what it lists: the operations of this instance, newest first"
out="$(panel '>' '>' q)"
check "the strip names it, the border says whose it is and how many operations it has" 'f="$(echo "$out" | frame_n 3)"; echo "$f" | grep -qE "Resumen +Acceso +\[Historial\]" && echo "$f" | grep -q "\[ >th-a \]-\[Historial\]" && echo "$f" | grep -q "3 operaciones"'
check "its three operations are listed, the newest first, with their state, when and how long" 'f="$(echo "$out" | frame_n 3)"; echo "$f" | grep -qE "> \* 11-01 10:00 deploy +41.2 s" && echo "$f" | grep -qE "x 11-01 09:00 check +2.1 s" && echo "$f" | grep -qE "\* 10-31 15:00 rollback +5.3 s" && [ "$(echo "$f" | grep -n "10:00 deploy\|09:00 check\|15:00 rollback" | cut -d: -f1 | tr "\n" " ")" != "" ]'
check "the operation of another instance is not in it (th-b deployed at 09:50)" '! echo "$out" | frame_n 3 | grep -q "09:50"'
check "the selected one has its detail under the list: its command, how it ended, when, how long and who" 'f="$(echo "$out" | frame_n 3)"; echo "$f" | grep -q "comando *./deltactl deploy th-a" && echo "$f" | grep -qE "estado *\* correcta . c.digo 0" && echo "$f" | grep -q "2026-11-01 10:00:00Z" && echo "$f" | grep -q "41.2 s" && echo "$f" | grep -q "ana@testhost"'
check "what it printed is the summary of the Output view (a deploy has a shape), not the raw text" 'f="$(echo "$out" | frame_n 3)"; echo "$f" | grep -q "Lo que imprimi. (resumen)" && echo "$f" | grep -q "Validando compose"'
check "the last line has the keys of the tab" 'echo "$out" | frame_n 3 | tail -2 | grep -q "operaci.n . Enter la salida entera . RePág/AvPág desplaza el detalle"'
check "an instance with no operations says so" 'panel ">" ">" esc down down down q | frame_n 7 | grep -q "no tiene operaciones registradas"'
check "in English: History, operations and its keys in English" 'f="$(LANGX=en panel ">" ">" q | frame_n 3)"; echo "$f" | grep -q "\[History\]" && echo "$f" | grep -q "3 operations" && echo "$f" | grep -q "operation . Enter the whole output"'

section "3. the keys"
check "down chooses the run before (a check that failed): its detail changes, and it is the summary of a check" 'f="$(panel ">" ">" down q | frame_n 4)"; echo "$f" | grep -q "comando *./deltactl check th-a" && echo "$f" | grep -qE "estado *x fallida . c.digo 1" && echo "$f" | grep -qE "^.*> x 11-01 09:00 check"'
check "the next one has no shape: the end of what it printed" 'f="$(panel ">" ">" down down q | frame_n 5)"; echo "$f" | grep -q "comando *./deltactl rollback th-a s0" && echo "$f" | grep -q "Salida (.ltimas 2 l.neas)" && echo "$f" | grep -q "Rolling back auth-backend"'
check "up from the first one stays on it; End goes to the oldest and Home to the newest" '[ "$(panel ">" ">" up q | frame_n 4 | grep -c "> \* 11-01 10:00 deploy")" -eq 1 ] && panel ">" ">" end q | frame_n 4 | grep -qE "> \* 10-31 15:00 rollback" && panel ">" ">" end home q | frame_n 5 | grep -qE "> \* 11-01 10:00 deploy"'
check "j and k do what down and up do" 'panel ">" ">" j q | frame_n 4 | grep -q "comando *./deltactl check th-a" && panel ">" ">" j k q | frame_n 5 | grep -q "comando *./deltactl deploy th-a"'
check "Enter opens the whole saved output in the viewer of the Runs view, on that run" 'f="$(panel ">" ">" enter q | last_frame)"; echo "$f" | grep -q "\[4 Ejecuciones\]" && echo "$f" | grep -q "Validando compose"'
check "and Esc there comes back from the viewer (the Runs view still shows the same run)" 'f="$(panel ">" ">" down enter esc q | last_frame)"; echo "$f" | grep -q "\[4 Ejecuciones\]" && echo "$f" | grep -q "check"'
check "PgDn scrolls the detail and PgUp brings it back, where the detail is longer than the box (100 x 30)" 'a="$(PANEL_COLS=100 PANEL_ROWS=30 panel ">" ">" ">" q | frame_n 4 | sed 1d | md5sum)"; b="$(PANEL_COLS=100 PANEL_ROWS=30 panel ">" ">" ">" pgdn q | frame_n 5 | sed 1d | md5sum)"; c="$(PANEL_COLS=100 PANEL_ROWS=30 panel ">" ">" ">" pgdn pgup q | frame_n 6 | sed 1d | md5sum)"; [ "$a" != "$b" ] && [ "$a" = "$c" ]'
check "Esc goes back to the list and right comes back into the tab" 'panel ">" ">" esc q | frame_n 4 | grep -q "Instancias" && panel ">" ">" esc right q | frame_n 5 | grep -q "\[ >th-a \]"'
check "z gives the tab the whole body" '! panel ">" ">" z q | frame_n 4 | grep -q "Nueva instancia" && panel ">" ">" z q | frame_n 4 | grep -q "3 operaciones"'

section "4. a state that changes is a frame that changes, and the selection follows the run"
check "every key that changes what is selected changes the frame" 'a="$(panel ">" ">" q | frame_n 3 | sed 1d | md5sum)"; for k in down end; do [ "$(panel ">" ">" $k q | frame_n 4 | sed 1d | md5sum)" != "$a" ] || { echo "$k"; exit 1; }; done'
check "a run that arrives at the top while another one is selected does not move the selection" '[ "$(run_lib "INSTANCES_DIR=instances; DASH_NAMES=(th-a); DASH_SEL=0; dash_runs_load; dash_his_filter th-a; dash_his_select 1; id=\$DASH_HIS_ID; mkdir -p instances/.deltactl/runs/20261103T000000Z-9; cp instances/.deltactl/runs/20261101T100000Z-1/meta instances/.deltactl/runs/20261103T000000Z-9/meta; printf \"20261103T000000Z-9\t2026-11-03T00:00:00Z\tdeploy\tth-a\tsucceeded\t0\t100\n\" >> instances/.deltactl/runs.idx; dash_runs_load; dash_his_filter th-a; echo \"\$id \$DASH_HIS_ID \$DASH_HIS_SEL \${#DASH_HIS_IDX[@]}\"")" = "20261101T090000Z-2 20261101T090000Z-2 2 4" ]'
rm -rf instances/.deltactl/runs/20261103T000000Z-9
sed -i '/20261103T000000Z-9/d' instances/.deltactl/runs.idx

section "5. what a file says is data"
out="$(panel '>' '>' esc down down q)"
check "the run of th-c, whose user and output carry escape sequences, is the one on screen" 'echo "$out" | frame_n 6 | grep -q "\[ >th-c \]\|th-c"'
check "what it says is there as text: the user and the line of its output, with the sequences gone" 'f="$(echo "$out" | frame_n 6)"; echo "$f" | grep -q "line with clear and .*red" && echo "$f" | grep -qE "qui.n +evil@testhost"'
check "and no sequence reaches the screen: no escape byte and no clearing of the screen (the clear-screen sequence is gone whole)" 'f="$(echo "$out" | frame_n 6)"; ! echo "$f" | grep -q "$(printf "\033")" && ! echo "$f" | grep -q "\[2J"'

section "6. the logs tab: the other service without leaving the pane ({ and })"
check "} chooses the log of the next service and { of the previous one (100 x 30: the logs are a tab)" 'PANEL_COLS=100 PANEL_ROWS=30 panel ">" q | frame_n 2 | grep -q "Logs . s0" && PANEL_COLS=100 PANEL_ROWS=30 panel ">" "}" q | frame_n 3 | grep -q "Logs . s1" && PANEL_COLS=100 PANEL_ROWS=30 panel ">" "}" "{" q | frame_n 4 | grep -q "Logs . s0"'
check "the key bar text of the logs pane has the keys, in both languages (at 100 columns the bar drops what does not fit)" '[ "$(run_lib "t tui.keys.logs 1 2")" != "" ] && run_lib "t tui.keys.logs 1 2" | grep -q "{ } servicio" && DELTACTL_LANG=en run_lib "t tui.keys.logs 1 2" | grep -q "{ } service"'
check "the service chosen stays chosen when the summary is back (the card of the second one is the one marked)" 'PANEL_COLS=100 PANEL_ROWS=30 panel ">" "}" "<" q | last_frame | grep -q "s1"'

section "7. cost: it reads nothing while another tab is on screen, and the drawing starts no process"
check "with the summary on screen the tick of the tab does not read the runs" '[ "$(run_lib "INSTANCES_DIR=instances; DASH_VIEW=instances; DASH_NAMES=(th-a); DASH_SEL=0; DASH_ON_NEW=0; DASH_SVCS[th-a]=\"s0\"; DASH_WS_TAB=resumen; ws_historial_tick; echo \"[\${#DASH_RUNS_LINES[@]}][\$DASH_HIS_AT]\"")" = "[0][-1000]" ]'
check "with the tab on screen it reads them, once, and again only after five seconds" '[ "$(run_lib "INSTANCES_DIR=instances; DASH_VIEW=instances; DASH_NAMES=(th-a); DASH_SEL=0; DASH_ON_NEW=0; DASH_SVCS[th-a]=\"s0\"; DASH_WS_TAB=historial; DASH_FOCUS=tab; ws_historial_tick; a=\$DASH_HIS_AT; n=\$DASH_HIS_N; ws_historial_tick; echo \"\$((a >= 0)) \$((n == DASH_HIS_N))\"")" = "1 1" ]'
body() { sed -n "/^$1() {/,/^}/p" lib/screens/ws/historial.sh | grep -vE "^[[:space:]]*#"; }
check "the list and the box of the tab start no process: no command substitution in them (the detail of a run, built once per selection, reads files as the Runs view does)" 'for f in dash_his_list ws_historial_box ws_historial_sig dash_his_select dash_his_filter; do body "$f" | grep -qE "\\$\\([^(]|\`" && { echo "$f"; exit 1; }; done; true'
check "it only reads the runs: nothing in the tab writes a file of them" '! grep -vE "^[[:space:]]*#" lib/screens/ws/historial.sh | grep -qE "> *\"?\\$(INSTANCES_DIR|STATE|dir)|rm |mv |tee |runs_meta_write|runs_idx_add|runs_unlock"'

finish

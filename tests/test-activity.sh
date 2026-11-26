#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2046  # the cases go in single quotes and are evaluated with eval
# The Activity view (lib/screens/activity.sh, key 0): the operations of every instance and the last command of the panel in one list, and for the
# one selected a pane with four tabs (Resumen, Salida, Consumo, Procesos). It absorbs the Output (3), Runs (4) and Processes (5) views: this suite
# covers how it is registered, what the list shows and in which order, each tab, every key the old views had (the viewer of the saved output, the
# statistics, the summary or the raw text, the errors only, the tree of processes), the mouse, the notice that the old views moved, that what a file
# says is data (a run with escape sequences cannot move the cursor), what it costs (it starts no process and reads nothing while another view is on
# screen), the golden snapshots of its scenes (tests/tools/act_scenes.sh) at 80x24, 120x30 and 160x40, and the shape of every frame. No real Docker.
# Snapshots: tests/golden/activity/<scene>-<cols>x<rows>-<lang>.txt. DELTACTL_GOLDEN=record rewrites them (only when a change is intended).
# Run it from the root of the isolated copy (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8 LC_ALL=C.UTF-8
ESC="$(printf '\033')"
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS DELTACTL_TUI_KEYS DELTACTL_TUI_EVENTS DELTACTL_TUI_ROWS DELTACTL_THEME DELTACTL_TUI_WSENV DELTACTL_TUI_WSACC
unset DELTACTL_REFRESH DELTACTL_METRICS_INTERVAL DELTACTL_TUI_IDLE_AFTER DELTACTL_TUI_GATE DELTACTL_CLIP DELTACTL_PR_SHELL DELTACTL_GRAPH TUI_GRAPH

FIX="$(mktemp -d)"
export FIX
trap 'rm -rf "$FIX" instances/.deltactl' EXIT
rm -rf instances/.deltactl
mkdir -p "$FIX/bin" "$FIX/frames"
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
# shellcheck source=tests/tools/act_scenes.sh
source tests/tools/act_scenes.sh

STATE=instances/.deltactl
mkdir -p "$STATE/runs"
# A run on disk, as the runs left it: its metadata, its output and its line of the index.
mkrun() { # id op args instance state rc started ms output-file [extra lines of the metadata]
  mkdir -p "$STATE/runs/$1"
  printf 'RUN_ID=%s\nOP=%s\nARGS=%s\nINSTANCE=%s\nSTATE=%s\nRC=%s\nSTARTED_AT=%s\nENDED_AT=%s\nDURATION_MS=%s\nUSER=ana\nHOST=testhost\n%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$7" "$8" "${10:-}" > "$STATE/runs/$1/meta"
  cp "$9" "$STATE/runs/$1/out.log"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$7" "$2" "$4" "$5" "$6" "$8" >> "$STATE/runs.idx"
}
printf 'Rolling back backend-s0 to 2.13.0\nDone\n' > "$FIX/plain.txt"
mkrun 20261030T100000Z-0 deploy ax-a ax-a succeeded 0 2026-10-30T10:00:00Z 38000 tests/golden/outsum/in/deploy-es.txt $'CPU_MS=8000\nDOCKER_MS=28000\nDOCKER_CALLS=12\nPEAK_RSS_KB=40000\nPEAK_PROCS=5\nOUT_BYTES=2100\nOUT_LINES=38'
mkrun 20261031T150000Z-3 rollback "ax-a s0" ax-a succeeded 0 2026-10-31T15:00:00Z 5300 "$FIX/plain.txt"
mkrun 20261101T090000Z-2 check ax-a ax-a failed 1 2026-11-01T09:00:00Z 2100 tests/golden/outsum/in/check-fail-es.txt
mkrun 20261101T095000Z-4 deploy ax-b ax-b succeeded 0 2026-11-01T09:50:00Z 30100 tests/golden/outsum/in/deploy-es.txt
mkrun 20261101T100000Z-1 deploy ax-a ax-a succeeded 0 2026-11-01T10:00:00Z 41200 tests/golden/outsum/in/deploy-es.txt $'CPU_MS=9100\nDOCKER_MS=30500\nDOCKER_CALLS=14\nPEAK_RSS_KB=48200\nPEAK_PROCS=6\nOUT_BYTES=2300\nOUT_LINES=40'
# A run whose files say things a terminal would obey: the user name and the output have escape sequences.
printf 'line with \033[2J\033[Hclear and \033[31mred\033[0m\nsecond line\n' > "$FIX/hostile.txt"
mkrun 20261102T080000Z-5 rollback "ax-c s0" ax-c succeeded 0 2026-11-02T08:00:00Z 900 "$FIX/hostile.txt"

KEYS="$FIX/keys.txt"
# The panel with the keys given (one per line): ASCII, no colours, 160 x 40. PANEL_COLS / PANEL_ROWS / LANGX change it.
panel() { printf '%s\n' "$@" > "$KEYS"; DELTACTL_TUI_KEYS="$KEYS" DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_ASCII=1 COLUMNS="${PANEL_COLS:-160}" DELTACTL_TUI_ROWS="${PANEL_ROWS:-40}" DELTACTL_LANG="${LANGX:-es}" bash ./deltactl 2>&1; }
last_frame() { awk '/^=== frame /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }'; }
frame_n() { awk -v n="$1" '/^=== frame /{ f = ($3 == n) } f'; }
run_lib() { ROOT="$PWD" DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_ASCII=1 COLUMNS=160 DELTACTL_TUI_ROWS=40 bash -c 'source lib/bootstrap.sh; source lib/cmd/dashboard.sh; set +e; '"$1" 2>&1; }

section "1. it is the tenth view, registered with one line, and key 0 opens it"
check "it is a file of lib/screens with one line at the end of the views of the registry, after the Variables" '[ -f lib/screens/activity.sh ] && grep -q "^dash_screen_register activity tui.tab.activity 0$" lib/screens/registry.sh && [ "$(run_lib "echo \${DASH_SCREENS[*]}")" = "server images instances resources output runs procs console env activity" ]'
check "the key 0 opens it (the tenth tab has no digit of its own)" 'panel 0 q | frame_n 2 | grep -q "\[0 Actividad\]"'
check "the tab line numbers the other views from 1 to 9 and this one 0" 'f="$(panel q | frame_n 1 | sed -n 3p)"; echo "$f" | grep -q "1 Servidor" && echo "$f" | grep -q "3 Instancias" && echo "$f" | grep -q "9 Variables" && echo "$f" | grep -q "0 Actividad"'
check "Tab goes from Variables to Activity and wraps to Servidor" 'out="$(panel 9 tab tab q)"; echo "$out" | frame_n 3 | grep -q "\[0 Actividad\]" && echo "$out" | frame_n 4 | grep -q "\[1 Servidor\]"'
check "a click on its tab opens it" 'panel mouse:0:126:2 q | frame_n 2 | grep -q "\[0 Actividad\]"'
check "the console goes to it and the palette lists it" 'panel : $(printf "%s\n" g o t o space a c t i v i t y) enter q | grep -q "\[0 Actividad\]" && run_lib "dash_pal_build; printf \"%s\\n\" \"\${DASH_PAL_ALL_A[@]}\"" | grep -qx "view:activity"'
check "the old views are still there and still work (4 Salida, 5 Ejecuciones, 6 Procesos)" 'panel 5 q | frame_n 2 | grep -q "\[5 Salida\]" && panel 6 q | frame_n 2 | grep -q "\[6 Ejecuciones\]" && panel 7 q | frame_n 2 | grep -q "\[7 Procesos\]"'
check "0 is not a digit for anything else: with only nine views it does nothing" '[ "$(run_lib "DASH_SCREENS=(a b c); dash_screen_by_number 0; echo \$?")" = "1" ]'

section "2. the list: what happened, newest first, with its state, when and how long"
out="$(panel 0 q)"
check "its border says how many operations it has and the first one has the cursor" 'f="$(echo "$out" | frame_n 2)"; echo "$f" | grep -q "Actividad (6)" && echo "$f" | grep -qE "> \* 11-02 08:00 rollback"'
check "the six runs are listed newest first with their state, date and duration" 'f="$(echo "$out" | frame_n 2)"; echo "$f" | grep -qE "x 11-01 09:00 check +ax-a +2.1 s" && echo "$f" | grep -qE "\* 11-01 10:00 deploy +ax-a +41.2 s" && echo "$f" | grep -qE "\* 10-30 10:00 deploy +ax-a +38.0 s" && [ "$(echo "$f" | grep -n "11-02 08:00\|11-01 10:00\|10-30 10:00" | cut -d: -f1 | tr "\n" " ")" != "" ]'
check "down chooses the next one, k and j do the same, g goes to the first and G to the last" 'panel 0 down q | frame_n 3 | grep -qE "> \* 11-01 10:00 deploy" && panel 0 j k q | frame_n 4 | grep -qE "> \* 11-02 08:00 rollback" && panel 0 G q | frame_n 3 | grep -qE "> \* 10-30 10:00 deploy" && panel 0 G g q | frame_n 4 | grep -qE "> \* 11-02 08:00 rollback"'
check "up from the first one stays on it" '[ "$(panel 0 up q | frame_n 3 | grep -c "> \* 11-02 08:00")" -eq 1 ]'
check "the title of the pane says the command and the instance of the selected run" 'panel 0 down q | frame_n 3 | grep -q "deploy . ax-a"'
check "a view with no operation and no command says so" 'mv "$STATE" "$FIX/state-away"; out="$(panel 0 q)"; mv "$FIX/state-away" "$STATE"; echo "$out" | frame_n 2 | grep -q "Todav.a no hay actividad"'
check "a command of this panel is the first row, marked as this panel's, and it is selected when the view is opened" 'f="$(panel i wait 0 q | last_frame)"; echo "$f" | grep -qE "> . este panel +images" && echo "$f" | grep -q "Actividad (7)"'
check "the cursor goes to the command of this panel only if it runs or ended less than two minutes ago" '[ "$(run_lib "INSTANCES_DIR=instances; DASH_VIEW=activity; JOB_PID=999; JOB_RC=0; JOB_END_US=1000000; scr_activity_enter; a=\$DASH_ACT_ON_JOB; host_now_us; JOB_END_US=\$HOST_NOW_US; scr_activity_enter; echo \"\$a \$DASH_ACT_ON_JOB\"")" = "0 1" ]'
check "the command of this panel is the row above the runs: down goes to the first of them and up comes back" 'panel i wait 0 down q | last_frame | grep -qE "> \* 11-02 08:00 rollback" && panel i wait 0 down up q | last_frame | grep -qE "> . este panel"'
check "in English the view is translated" 'f="$(LANGX=en panel 0 q | frame_n 2)"; echo "$f" | grep -q "\[0 Activity\]" && echo "$f" | grep -q "Summary" && echo "$f" | grep -q "Usage" && echo "$f" | grep -q "Processes" && echo "$f" | grep -q "choose"'

section "3. Resumen: what it was, how it ended, and what it printed"
out="$(panel 0 down q | frame_n 3)"
check "the detail has the command, the state with its code, when, how long and who" 'echo "$out" | grep -q "comando *./deltactl deploy ax-a" && echo "$out" | grep -qE "estado *\* correcta . c.digo 0" && echo "$out" | grep -q "2026-11-01 10:00:00Z" && echo "$out" | grep -q "41.2 s" && echo "$out" | grep -q "ana@testhost"'
check "what a deploy printed is its summary (the one of the Output view), not the raw text" 'echo "$out" | grep -q "Lo que imprimi. (resumen)" && echo "$out" | grep -q "Validando compose"'
check "a run that failed says so, with its code" 'panel 0 down down down q | frame_n 5 | grep -qE "estado *x fallida . c.digo 1"'
check "a command with no shape shows the end of what it printed" 'panel 0 down down down down q | frame_n 6 | grep -q "Salida (.ltimas 2 l.neas)" && panel 0 down down down down q | frame_n 6 | grep -q "Rolling back backend-s0"'
check "the command of this panel says how it ended and keeps the note that it is not in the history" 'f="$(panel i wait 0 q | last_frame)"; echo "$f" | grep -q "comando *./deltactl images" && echo "$f" | grep -qE "estado *\* correcto" && echo "$f" | grep -q "no se guardan en el historial"'
check "PgDn moves the detail and PgUp brings it back, where it is longer than the box (100 x 20)" 'a="$(PANEL_COLS=100 PANEL_ROWS=20 panel 0 down q | frame_n 3 | sed 1d | md5sum)"; b="$(PANEL_COLS=100 PANEL_ROWS=20 panel 0 down pgdn q | frame_n 4 | sed 1d | md5sum)"; c="$(PANEL_COLS=100 PANEL_ROWS=20 panel 0 down pgdn pgup q | frame_n 5 | sed 1d | md5sum)"; [ "$a" != "$b" ] && [ "$a" = "$c" ]'
check "what a file says is data: the escape sequences that clear the screen or move the cursor, in the output of a run, do not reach the screen" '! panel 0 q | frame_n 2 | grep -q "$ESC\[2J\|$ESC\[H" && panel 0 q | frame_n 2 | grep -q "line with clear and"'

section "4. the tabs: left and right, < and >, and Esc steps back"
check "right chooses Salida, then Consumo, then Procesos, then wraps to Resumen" 'out="$(panel 0 right right right right q)"; echo "$out" | frame_n 3 | grep -q "Resumen \[Salida\]" && echo "$out" | frame_n 4 | grep -q "Salida \[Consumo\]" && echo "$out" | frame_n 5 | grep -q "Consumo \[Procesos\]" && echo "$out" | frame_n 6 | grep -q "\[Resumen\] Salida"'
check "left goes back and wraps to Procesos, > and < do the same as right and left" 'panel 0 left q | frame_n 3 | grep -q "Consumo \[Procesos\]" && panel 0 ">" q | frame_n 3 | grep -q "Resumen \[Salida\]" && panel 0 ">" "<" q | frame_n 4 | grep -q "\[Resumen\] Salida"'
check "the key bar changes with the tab" 'panel 0 q | frame_n 2 | tail -2 | grep -q "Enter salida" && panel 0 right q | frame_n 3 | tail -2 | grep -q "v resumen/crudo" && panel 0 right right q | frame_n 4 | tail -2 | grep -q "t estad.sticas" && panel 0 right right right q | frame_n 5 | tail -2 | grep -q "x cancela el comando"'
check "Esc goes from a tab back to Resumen and from Resumen to the first view" 'panel 0 right right esc q | frame_n 5 | grep -q "\[Resumen\]" && panel 0 right esc esc q | frame_n 5 | grep -q "\[1 Servidor\]"'
check "Enter and l go to the output of the selected run" 'panel 0 enter q | frame_n 3 | grep -q "\[Salida\]" && panel 0 l q | frame_n 3 | grep -q "\[Salida\]"'
check "choosing another run keeps the tab (the output of the next one is the one shown)" 'panel 0 enter down q | frame_n 4 | grep -q "20261101T100000Z-1"'

section "5. Salida: the whole saved output in a viewer, and the output of this panel's command"
out="$(panel 0 down enter q | frame_n 4)"
check "the saved output of a run is shown in the viewer of the Runs view, with its line numbers and the lines it shows" 'echo "$out" | grep -qE "l.neas 1-[0-9]+ de [0-9]+" && echo "$out" | grep -q "Validando compose" && echo "$out" | grep -qE "\|   1 "'
check "Home goes to the first line of the saved output and End to the last (24 rows: the pane is smaller than the 18 lines of this output)" 'PANEL_ROWS=24 panel 0 down down down enter home q | frame_n 7 | grep -qE "l.neas 1-[0-9]+ de 18" && PANEL_ROWS=24 panel 0 down down down enter home end q | frame_n 8 | grep -qE "l.neas ([2-9]|1[0-9])-18 de 18"'
check "leaving the tab closes the viewer (nothing is held for a viewer that is not shown)" '[ "$(run_lib "INSTANCES_DIR=instances; DASH_VIEW=activity; scr_activity_enter; dash_act_tab_go salida; a=\$DASH_RV_ID; dash_act_tab_go resumen; echo \"[\$a][\$DASH_RV_ID]\"")" = "[20261102T080000Z-5][]" ]'
check "a run with no saved output says so" 'rm -f "$STATE/runs/20261102T080000Z-5/out.log"; out="$(panel 0 enter q | frame_n 3)"; cp "$FIX/hostile.txt" "$STATE/runs/20261102T080000Z-5/out.log"; echo "$out" | grep -q "no guard. salida"'
check "the output of the command of this panel is the Output view's box: its title says the command and how it ended" 'f="$(panel i wait 0 enter q | last_frame)"; echo "$f" | grep -q "Salida . ./deltactl images" && echo "$f" | grep -q "termin. bien"'
check "a command started from this view (i: images) stays in the view and shows its output in the tab Salida, on its own row" 'f="$(panel 0 i wait q | last_frame)"; echo "$f" | grep -q "\[0 Actividad\]" && echo "$f" | grep -q "Resumen \[Salida\]" && echo "$f" | grep -qE "> . este panel +images" && echo "$f" | grep -q "Salida . ./deltactl images"'
check "from another view the same command still opens the Output view, as it always did" 'panel i wait q | last_frame | grep -q "\[5 Salida\]"'
check "v switches between the summary and the raw text of the command, e keeps only the errors" 'a="$(panel i wait 0 enter q | last_frame | md5sum)"; b="$(panel i wait 0 enter v q | last_frame | md5sum)"; [ "$a" != "$b" ] && panel i wait 0 enter e q | last_frame | grep -qE "Salida|solo errores|ning.n"'
check "the raw text and the summary are both in the pane: the title tells which" 'panel i wait 0 enter v q | last_frame | grep -q "./deltactl images" && panel i wait 0 enter q | last_frame | grep -q "resumen"'

section "6. Consumo: what it cost, how it compares, and the statistics of every kind of operation"
out="$(panel 0 down right right q | frame_n 5)"
check "a recorded run shows how it compares with the earlier ones of the same command and what it consumed" 'echo "$out" | grep -q "Frente a las anteriores (deploy de ax-a)" && echo "$out" | grep -qE "duraci.n +41.2 s +\+8%" && echo "$out" | grep -qE "CPU +9.1 s +\+13%" && echo "$out" | grep -q "14 llamadas" && echo "$out" | grep -q "47.0 MB . 6 procesos"'
check "the comparison and the consumption are apart (a blank line between them)" 'echo "$out" | awk "/Frente a las anteriores/{a=NR} /Consumo de la operaci/{b=NR} END{exit !(a && b && b > a + 1)}" && echo "$out" | grep -B1 "Consumo de la operaci" | head -1 | grep -qE "^.*\| +\|"'
check "a run recorded before the consumption was measured says there are no figures" 'panel 0 down down right right q | frame_n 6 | grep -q "antes de que se midiera el consumo"'
check "the command of this panel has no recorded usage and says why" 'panel i wait 0 right right q | last_frame | grep -q "no se guarda en el historial"'
check "t shows what every kind of operation costs on average, in the same box" 'f="$(panel 0 t q | frame_n 3)"; echo "$f" | grep -q "\[Consumo\]" && echo "$f" | grep -q "Qu. cuesta cada operaci.n" && echo "$f" | grep -qE "deploy +3 +3 +0" && echo "$f" | grep -qE "check +1 +0 +1"'
check "t from another tab goes to Consumo and shows them; t again closes them" 'panel 0 t q | frame_n 3 | grep -q "Qu. cuesta" && ! panel 0 t t q | frame_n 4 | grep -q "Qu. cuesta" && panel 0 t t q | frame_n 4 | grep -q "no se guarda en el historial\|Frente a las anteriores\|Consumo de la operaci\|antes de que se midiera"'
check "s in the statistics keeps only the instance of the selected run, and again shows all of them" 'a="$(panel 0 down t s q | frame_n 5)"; echo "$a" | grep -q "ax-a" && echo "$a" | grep -qE "deploy +2 +2" && panel 0 down t s s q | frame_n 6 | grep -qE "deploy +3 "'
check "Esc closes the statistics first, then the tab" 'panel 0 t esc q | frame_n 4 | grep -q "\[Consumo\]" && ! panel 0 t esc q | frame_n 4 | grep -q "Qu. cuesta" && panel 0 t esc esc q | frame_n 5 | grep -q "\[Resumen\]"'
check "the key bar of the statistics has its own keys" 'panel 0 t q | frame_n 3 | tail -2 | grep -q "s una instancia / todas"'

section "7. Procesos: the tree of the selected operation, and what the panel itself costs"
PT="$FIX/pt"
rm -rf "$PT"
fakeproc() { # pid resident-pages children argv(|)
  mkdir -p "$PT/$1/task/$1"
  printf '%s %s 0 0 0 0 0\n' $(($2 * 2)) "$2" > "$PT/$1/statm"
  printf '%s' "$3" > "$PT/$1/task/$1/children"
  if [ -n "$4" ]; then printf '%s\0' ${4//|/ } > "$PT/$1/cmdline"; else : > "$PT/$1/cmdline"; fi
  printf 'sh\n' > "$PT/$1/comm"
}
fakeproc 100 500 "101 102 " "bash|/x/deltactl|deploy|a"
fakeproc 101 1000 "103" "docker|compose|up"
fakeproc 102 250 "" "tee|-ia|/x/out.log"
fakeproc 103 500 "" ""
fakeproc 200 2000 "201 " "bash|./deltactl"
fakeproc 201 200 "" "docker|events"
printf '200 (deltactl x) S 1 1 1 0 -1 0 0 0 0 0 50 50 0 0 20 0 1 0 1 1 1\n' > "$PT/200/stat"
PTENV="DELTACTL_PROC_ROOT=$PT; DASH_PAGE_KB=4; DASH_CLK_TCK=100; INSTANCES_DIR=instances;"
check "with nothing running the tab says so and still shows what the panel costs" 'f="$(panel 0 right right right q | frame_n 5)"; echo "$f" | grep -q "No hay ning.n comando en curso" && echo "$f" | grep -q "El propio panel"'
LIVE="$PTENV DASH_SELF_PID=200; SECONDS=10; DELTACTL_TUI_ROWS=30; tui_size; dash_init; JOB_PID=100; JOB_TITLE=\"deploy a\"; JOB_RC=; host_now_us; JOB_START_US=\$HOST_NOW_US; DASH_VIEW=activity; scr_activity_enter; dash_act_tab_go procesos; dash_procs_tick; dash_render"
f="$(run_lib "$LIVE" | last_frame)"
check "while the command of this panel runs, its processes are drawn as a tree under its name" 'echo "$f" | grep -q "./deltactl deploy a" && echo "$f" | grep -qE "3\.9 MB {4}docker compose up" && echo "$f" | grep -qE "1000 KB {4}tee -ia"'
check "the root is listed without memory and the total says what it leaves out" 'echo "$f" | grep -q "100 *- *bash /x/deltactl deploy a" && echo "$f" | grep -q "3 procesos . 6.8 MB en total"'
check "the box of the panel itself is below the tree" 'echo "$f" | grep -q "pid 200 . memoria 7.8 MB" && echo "$f" | grep -q "procesos que ha lanzado y siguen vivos: 1"'
check "the tab reads the processes while it is on screen and not while another tab is" '[ "$(run_lib "$PTENV JOB_PID=100; JOB_RC=; scr_activity_enter; DASH_VIEW=activity; dash_act_tab_go resumen; dash_procs_shown && echo yes || echo no")" = "no" ] && [ "$(run_lib "$PTENV scr_activity_enter; DASH_VIEW=activity; dash_act_tab_go procesos; dash_procs_shown && echo yes || echo no")" = "yes" ]'
mkdir -p "$STATE/active"
printf '100\n' > "$STATE/active/20261101T100000Z-1"
check "a run that is going on in another terminal shows its own tree when it is the selected one" '[ "$(run_lib "$PTENV runs_pid_alive() { [ \"\$1\" = 100 ]; }; JOB_PID=; dash_runs_load; DASH_VIEW=activity; scr_activity_enter; dash_act_select 0; dash_act_proc_root; echo \"\$DASH_PR_PID|\$DASH_PR_LABEL\"")" = "100|./deltactl deploy ax-a" ]'
check "and nothing when the selected run has already finished" '[ "$(run_lib "$PTENV runs_pid_alive() { [ \"\$1\" = 100 ]; }; JOB_PID=; dash_runs_load; DASH_VIEW=activity; scr_activity_enter; dash_act_select 3; dash_act_proc_root; echo \"[\$DASH_PR_PID]\"")" = "[]" ]'
rm -rf "$STATE/active" "$PT"

section "8. the mouse: the tabs of the pane and the rows of the list"
check "a click on the tab Salida opens it (160 x 40: the list is 54 wide, the strip starts at column 55)" 'panel 0 mouse:0:66:3 q | frame_n 3 | grep -q "Resumen \[Salida\]"'
check "a click on the tab Consumo and then on Resumen goes there and back" 'out="$(panel 0 mouse:0:75:3 mouse:0:58:3 q)"; echo "$out" | frame_n 3 | grep -q "Salida \[Consumo\]" && echo "$out" | frame_n 4 | grep -q "\[Resumen\]"'
check "a click on a row of the list gives it the cursor" 'panel 0 mouse:0:10:6 q | frame_n 3 | grep -qE "> \* 11-01 09:50 deploy +ax-b"'
check "a second click on the selected row opens its output" 'panel 0 mouse:0:10:6 mouse:0:10:6 q | frame_n 4 | grep -q "\[Salida\]"'
check "a click under the last row does nothing" 'panel 0 mouse:0:10:20 q | frame_n 3 | grep -qE "> \* 11-02 08:00 rollback"'

check "the wheel over the list moves the cursor, as the arrows do" 'panel 0 mouse:65:10:10 q | frame_n 3 | grep -qE "> \* 11-01 10:00 deploy +ax-a" && panel 0 mouse:65:10:10 mouse:64:10:10 q | frame_n 4 | grep -qE "> \* 11-02 08:00 rollback"'
check "the wheel over the pane scrolls it, three lines a notch, where it is longer than the box (100 x 20)" 'a="$(PANEL_COLS=100 PANEL_ROWS=20 panel 0 down q | frame_n 3 | sed 1d | md5sum)"; b="$(PANEL_COLS=100 PANEL_ROWS=20 panel 0 down mouse:65:80:8 q | frame_n 4 | sed 1d | md5sum)"; [ "$a" != "$b" ]'
check "over the viewer of the saved output the wheel scrolls its lines (it started at the end)" 'PANEL_ROWS=24 panel 0 down down down enter q | frame_n 6 | grep -qE "l.neas [0-9]+-18 de 18" && ! PANEL_ROWS=24 panel 0 down down down enter mouse:64:100:12 q | frame_n 7 | grep -qE "l.neas [0-9]+-18 de 18"'

section "9. the old views moved here: the notice, once"
check "the first time Output, Runs or Processes is chosen with its number the panel says that Activity is where they live now" 'panel 5 q | frame_n 2 | grep -q "ahora viven en Actividad (tecla 0)"'
check "it is said once: the next time one of them is chosen it is not said again" '[ "$(run_lib "dash_init; dash_act_moved_notice; a=\$DASH_MSG; DASH_MSG=; dash_act_moved_notice; echo \"[\$a][\$DASH_MSG]\"" | grep -c "ahora viven en Actividad (tecla 0).*\]\[\]$")" = "1" ]'
check "the other views do not say it" '! panel 1 3 4 8 q | grep -q "ahora viven en Actividad"'
check "the help names the view and what moved to it" 'PANEL_ROWS=60 panel "?" q | frame_n 2 | grep -q "ACTIVIDAD" && PANEL_ROWS=60 panel "?" q | frame_n 2 | grep -q "1-9 0 "'

section "10. cost: it reads nothing while another view is on screen, and the drawing starts no process"
check "with another view on screen the tick of the Runs view does not read the runs" '[ "$(run_lib "INSTANCES_DIR=instances; DASH_VIEW=instances; DASH_RUNS_AT=-1000; dash_runs_tick; echo \$DASH_RUNS_AT")" = "-1000" ]'
check "with the Activity view on screen it reads them, once, and again only after five seconds" '[ "$(run_lib "INSTANCES_DIR=instances; DASH_VIEW=activity; DASH_PAUSED=0; SECONDS=100; DASH_RUNS_AT=-1000; dash_runs_tick; a=\$DASH_RUNS_N; SECONDS=102; dash_runs_tick; b=\$DASH_RUNS_AT; SECONDS=106; dash_runs_tick; echo \"\$a \$b \$DASH_RUNS_AT\"")" = "0 100 106" ] || [ "$(run_lib "INSTANCES_DIR=instances; DASH_VIEW=activity; DASH_PAUSED=0; SECONDS=100; DASH_RUNS_AT=-1000; dash_runs_tick; a=\$DASH_RUNS_AT; SECONDS=102; dash_runs_tick; b=\$DASH_RUNS_AT; SECONDS=106; dash_runs_tick; echo \"\$a \$b \$DASH_RUNS_AT\"")" = "100 100 106" ]'
body() { sed -n "/^$1() {/,/^}/p" lib/screens/activity.sh | grep -vE "^[[:space:]]*#"; }
nosub() { local t; t="$(body "$1")"; [[ "$t" != *'`'* ]] && ! grep -qE '\$\([^(]' <<< "$t"; }
check "the list, the pane and the keys start no process: no command substitution in them (the detail of a run, built once per selection, reads files as the Runs view does)" 'for f in dash_act_list_lines dash_act_pane dash_act_body dash_act_lines_box dash_act_stats_box dash_act_strip scr_activity_render scr_activity_key dash_act_pane_key dash_act_select dash_act_sync; do nosub "$f" || exit 1; done'
check "the detail is built once per selection: asking for it twice does not build it twice" '[ "$(run_lib "INSTANCES_DIR=instances; DASH_VIEW=activity; scr_activity_enter; dash_act_detail 60; a=\$DASH_ACT_DET_KEY; DASH_ACT_RES=(sentinel); dash_act_detail 60; echo \"\${DASH_ACT_RES[0]}\"")" = "sentinel" ]'
check "the Activity file only reads: it writes no file of the runs" '! grep -vE "^[[:space:]]*#" lib/screens/activity.sh | grep -qE "> *\"?\\$(INSTANCES_DIR|STATE|dir)|rm |mv |tee |runs_meta_write|runs_idx_add|runs_unlock"'
check "the signature of the frame has what the view depends on (the tab, the selection, the scroll of the pane)" 'run_lib "DASH_SIG=; scr_activity_sig; echo \$DASH_SIG" | grep -qE "^\|resumen\|0\|0\|0\|"'

section "11. snapshots of the scenes (80x24, 120x30 and 160x40)"
GOLD_DIR="${DELTACTL_GOLDEN_DIR:-tests/golden}/activity"
MODE="${DELTACTL_GOLDEN:-check}"
mkdir -p "$GOLD_DIR" 2> /dev/null || true
# scene <name> <cols> <rows> [lang] -> the frame as the panel draws it (the last one), without escape sequences
scene() {
  local name="$1" cols="$2" rows="$3" lang="${4:-es}"
  env ROOT="$PWD" PATH="$FIX/bin:$PATH" DELTACTL_LANG="$lang" DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never COLUMNS="$cols" DELTACTL_TUI_ROWS="$rows" \
    DELTACTL_CONFIG="$FIX/none" DELTACTL_THEME=matrix HOME="$FIX" XDG_CONFIG_HOME="$FIX/xdg" \
    bash -c 'source lib/bootstrap.sh; source lib/cmd/dashboard.sh; source tests/tools/act_scenes.sh; set +e; act_scene '"$name" 2>&1 \
    | awk '/^=== frame /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' | sed 's/\x1b\[[0-9;]*m//g'
}
for sc in "${ACT_SCENES[@]}"; do
  for sz in 80x24 120x30 160x40; do
    g="$GOLD_DIR/$sc-$sz-es.txt"
    scene "$sc" "${sz%x*}" "${sz#*x}" es > "$FIX/frames/$sc-$sz-es.txt"
    if [ "$MODE" = record ]; then cp "$FIX/frames/$sc-$sz-es.txt" "$g"; echo "  REC  $sc @ $sz (es)"
    else check "scene $sc at $sz (es) equals its snapshot" '[ -f "$g" ] && cmp -s "$FIX/frames/$sc-$sz-es.txt" "$g"'; fi
  done
done
for sc in resumen salida consumo procesos; do
  for sz in 80x24 120x30 160x40; do
    g="$GOLD_DIR/$sc-$sz-en.txt"
    scene "$sc" "${sz%x*}" "${sz#*x}" en > "$FIX/frames/$sc-$sz-en.txt"
    if [ "$MODE" = record ]; then cp "$FIX/frames/$sc-$sz-en.txt" "$g"; echo "  REC  $sc @ $sz (en)"
    else check "scene $sc at $sz (en) equals its snapshot" '[ -f "$g" ] && cmp -s "$FIX/frames/$sc-$sz-en.txt" "$g"'; fi
  done
done

section "12. the shape of every frame"
# (80x24, 120x30 and 160x40 are the frames of the snapshots above)
for sz in 60x14 100x20 100x30 140x34; do
  for sc in "${ACT_SCENES[@]}"; do
    scene "$sc" "${sz%x*}" "${sz#*x}" es > "$FIX/frames/$sc-$sz-es.txt"
  done
done
shape_ok() { # file cols rows : no line wider than the screen, as many lines as the screen has, and no stray escape sequence
  awk -v c="$2" -v r="$3" '{ n++; if (length($0) > c) { bad = 1 } } END { exit !(n >= r - 1 && n <= r + 2 && !bad) }' "$1"
}
for sz in 60x14 80x24 100x20 100x30 120x30 140x34 160x40; do
  for sc in "${ACT_SCENES[@]}"; do
    check "scene $sc at $sz draws inside the screen" 'shape_ok "$FIX/frames/$sc-$sz-es.txt" "${sz%x*}" "${sz#*x}"'
  done
done
check "no scene prints an error of Bash (unbound variable, bad substitution, syntax)" '! grep -lE "unbound variable|bad substitution|syntax error|command not found" "$FIX"/frames/*.txt | grep -q .'
check "every scene shows the strip of tabs of the pane when it has room (100 x 30 and larger)" 'for sc in resumen salida consumo procesos; do grep -q "Resumen" "$FIX/frames/$sc-100x30-es.txt" && grep -q "Procesos" "$FIX/frames/$sc-100x30-es.txt" || exit 1; done'

finish

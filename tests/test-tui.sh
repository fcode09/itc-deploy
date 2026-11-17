#!/usr/bin/env bash
# Tests of the interactive panel (lib/cmd/dashboard*.sh) and its terminal layer (lib/ui/tui.sh).
# The panel runs in test mode: DELTACTL_TUI_KEYS points to a file with one key name per line and every frame is
# printed as plain text, so no real terminal is needed. Docker is simulated, and so are /proc and the cgroup files
# (DELTACTL_PROC_ROOT / DELTACTL_CGROUP_ROOT). Runs from the root of the isolated copy (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS DELTACTL_TUI_KEYS DELTACTL_TUI_EVENTS DELTACTL_TUI_ROWS

FIX="$(mktemp -d)"
export FIX
trap 'rm -rf "$FIX" instances/tui-*' EXIT
rm -rf instances/tui-*
mkdir -p "$FIX/bin"
: > "$FIX/containers.txt"; : > "$FIX/images.txt"; : > "$FIX/stats.txt"

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
export DELTACTL_PROC_ROOT="$FIX/proc" DELTACTL_CGROUP_ROOT="$FIX/cg"

# Runs the panel with the keys given as arguments (one per line) and optional stdin. ASCII, no colors, 100 x 30.
KEYS="$FIX/keys.txt"
panel() { # key...  (stdin: answers to the confirmation prompts)
  printf '%s\n' "$@" > "$KEYS"
  DELTACTL_TUI_KEYS="$KEYS" DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_ASCII=1 COLUMNS=100 DELTACTL_TUI_ROWS=30 bash ./deltactl 2>&1
}
# The keys that type a text, one character per line.
typed() {
  local s="$1" i c
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    if [ "$c" = " " ]; then echo space; else echo "$c"; fi
  done
}
frames() { grep -c '^=== frame'; }
# The text of frame N of an output.
frame_n() { awk -v n="$1" '/^=== frame /{ f = ($3 == n) } f'; }
last_frame() { awk '/^=== frame /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }'; }

section "1. no instances"
out="$(panel q)"
check "the panel opens and shows the empty state" 'echo "$out" | grep -q "^=== frame 1 ===" && echo "$out" | grep -q "sin instancias; n crea una"'
check "the tab line shows the three views with the first one active" 'echo "$out" | grep -q "\[1 Instancias\]  2 Recursos   3 Salida"'
check "the keys of the view are in the last line" 'echo "$out" | grep -q "Up/Dn instancia . Lt/Rt servicio . Enter acciones . u desplegar"'
check "no line is wider than the screen" '! echo "$out" | awk "length(\$0) > 100 { found = 1 } END { exit !found }"'

started() { date -u -d "$1 ago" +%Y-%m-%dT%H:%M:%S.000000000Z; }
# container <instance> <service> <state> <health> <image> <age> [pid] [restarts]
container() { printf '%s|%s|%s|%s|%s|%s|/%s_%s|%s|%s\n' "$2" "$1" "$3" "$4" "$5" "$(started "$6")" "$2" "$1" "${7:-0}" "${8:-0}" >> "$FIX/containers.txt"; }
# The label "com.docker.compose.project" comes first in the real inspect output: here the first field is the project.
container() { printf '%s|%s|%s|%s|%s|%s|/%s_%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$(started "$6")" "$2" "$1" "${7:-0}" "${8:-0}" >> "$FIX/containers.txt"; }
# cgroup <pid> <memory bytes> <limit bytes|max> <cpu usec>
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
newinst tui-a 1.0 1.0; seeded tui-a
newinst tui-b 1.0 1.0
newinst tui-c 1.0 1.0; seeded tui-c
image auth-backend:1.0 sha256:aaa; image gueo-back-end:1.0 sha256:bbb
deployed tui-a s0 1.0 sha256:aaa; deployed tui-a s1 1.0 sha256:bbb
container tui-a s0 running healthy auth-backend:1.0 "2 days" 1234 0
container tui-a s1 running healthy gueo-back-end:1.0 "2 days" 1235 3
container tui-c s0 running healthy auth-backend:1.0 "1 hour" 1236 0
container tui-c s1 exited none gueo-back-end:1.0 "1 hour" 0 0
cgroup 1234 104857600 536870912 5000000
cgroup 1235 629145600 2147483648 9000000
cgroup 1236 52428800 max 100

section "2. the instances view"
out="$(panel q)"
check "the host line shows the memory bar, the load and Docker" 'echo "$out" | grep -q "Memoria \[####\.\.\] 5.0/8.0 GB 62%" && echo "$out" | grep -q "Carga 0.82" && echo "$out" | grep -q "Docker 27.0.0"'
check "the host line shows what the containers use" 'echo "$out" | grep -q "contenedores 7[0-9][0-9]M"'
check "every instance is a row with its n/m" 'echo "$out" | grep -q "tui-a  *2/2" && echo "$out" | grep -q "tui-b  *0/2" && echo "$out" | grep -q "tui-c  *1/2"'
check "a row shows the memory its services use" 'echo "$out" | grep "tui-a  *2/2" | grep -q "7[0-9][0-9]M" && echo "$out" | grep "tui-c  *1/2" | grep -q " 50M"'
check "the first row is selected" 'echo "$out" | grep -q "^| > . tui-a"'
check "the detail shows each service with its image, state, uptime and port" 'echo "$out" | grep -q "s0 auth-backend:1.0  . healthy" && echo "$out" | grep -q "s1 gueo-back-end:1.0  . healthy" && echo "$out" | grep -q "activo 2d00h  \.  :4100" && echo "$out" | grep -q "activo 2d00h  \.  :4101"'
check "the detail shows memory used, limit and percentage" 'echo "$out" | grep -q "mem  \[##\.*\] 100M/512M  19%" && echo "$out" | grep -q "mem  \[###\.*\] 600M/2.0G  29%"'
check "the CPU has no figure until the second sample" 'echo "$out" | grep -q "cpu  sin lectura aún"'
check "restarts are shown only when there are some" '[ "$(echo "$out" | grep -c "reinicios 3")" -eq 1 ] && ! echo "$out" | grep "activo 2d00h . :4100" | grep -q "reinicios"'
check "the totals add the services and show the data state" 'echo "$out" | grep -q "Total  mem 7[0-9][0-9]M/2.5G  cpu 0.0%  datos: sembrados"'
check "the output pane says nothing has run yet" 'echo "$out" | grep -q "Aún no has ejecutado nada"'

section "3. moving around"
out="$(panel down q)"
check "down selects the next instance and its detail" 'echo "$out" | frame_n 2 | grep -q "^| > . tui-b" && echo "$out" | frame_n 2 | grep -q "tui-b . 0/2"'
check "an instance that does not run shows its services as not created" 'echo "$out" | frame_n 2 | grep -q "s0 auth-backend:1.0  . no creado"'
out="$(panel up q)"
check "up from the first row wraps to the last" 'echo "$out" | frame_n 2 | grep -q "^| > . tui-c"'
out="$(panel j j k q)"
check "j and k work like the arrows" 'echo "$out" | frame_n 4 | grep -q "^| > . tui-b"'
out="$(panel right q)"
check "right moves the marker to the next service" 'echo "$out" | frame_n 2 | grep -q "|| > s1 gueo" && ! echo "$out" | frame_n 2 | grep -q "|| > s0 auth"'
out="$(panel right right q)"
check "the service marker wraps" 'echo "$out" | frame_n 3 | grep -q "|| > s0 auth"'
out="$(panel 2 q)"
check "2 opens the resources view" 'echo "$out" | frame_n 2 | grep -q "\[2 Recursos\]"'
out="$(panel tab q)"
check "Tab goes to the next view" 'echo "$out" | frame_n 2 | grep -q "\[2 Recursos\]"'
out="$(panel tab tab tab q)"
check "Tab wraps around the views" 'echo "$out" | frame_n 4 | grep -q "\[1 Instancias\]"'

section "4. the resources view"
out="$(panel 2 q)"
check "it lists every service of every instance with its state" 'echo "$out" | frame_n 2 | grep -q "tui-a  *s0  *healthy" && echo "$out" | frame_n 2 | grep -q "tui-a  *s1  *healthy" && echo "$out" | frame_n 2 | grep -q "tui-c  *s1  *detenido"'
check "it shows the memory with a bar, the figures and the restarts" 'echo "$out" | frame_n 2 | grep "tui-a  *s1" | grep -q "\[##\.*\] 600M/2.0G 29%" && echo "$out" | frame_n 2 | grep "tui-a  *s1" | grep -q " 3 "'
check "it shows the memory of the server and what the containers take" 'echo "$out" | frame_n 2 | grep -q "Servidor" && echo "$out" | frame_n 2 | grep -q "contenedores 7[0-9][0-9]M  ([0-9]*% de la RAM)"'
check "a stopped service has no figures" 'echo "$out" | frame_n 2 | grep "tui-c  *s1" | grep -q " - "'
check "the default order is by name" 'echo "$out" | frame_n 2 | grep -n "tui-a  *s0\|tui-a  *s1\|tui-c  *s0" | head -1 | grep -q "tui-a  *s0"'
out="$(panel 2 s q)"
check "s sorts by memory, the biggest first" 'echo "$out" | frame_n 3 | grep -q "orden: memoria" && echo "$out" | frame_n 3 | grep -n "tui-a  *s1\|tui-a  *s0" | head -1 | grep -q "tui-a  *s1"'
out="$(panel 2 s s q)"
check "s again sorts by CPU and a third time by name" 'echo "$out" | frame_n 4 | grep -q "orden: cpu" && out="$(panel 2 s s s q)" && echo "$out" | frame_n 5 | grep -q "orden: nombre"'
out="$(panel 2 down enter q)"
check "Enter jumps to the instance and service of the row" 'echo "$out" | frame_n 4 | grep -q "\[1 Instancias\]" && echo "$out" | frame_n 4 | grep -q "^| > . tui-a" && echo "$out" | frame_n 4 | grep -q "|| > s1 gueo"'
out="$(panel 2 down down down down enter q)"
check "the row of another instance selects that instance" 'echo "$out" | frame_n 7 | grep -q "^| > . tui-c"'

section "5. commands run inside the panel"
out="$(panel : $(typed "status tui-a") enter wait q)"
check "the typed command starts in the background and the panel says so" 'echo "$out" | grep -q "Ejecutando: ./deltactl status tui-a"'
check "its output goes to the Output view" 'echo "$out" | last_frame | grep -q "\[3 Salida\]" && echo "$out" | last_frame | grep -q "Salida . ./deltactl status tui-a"'
check "the output shows what the command printed" 'echo "$out" | last_frame | grep -q "tui-a"'
check "the tab line shows how the command ended" 'echo "$out" | last_frame | grep -q ". ./deltactl status tui-a terminó bien"'
out="$(panel : $(typed "frobnicate") enter wait q)"
check "a command that fails shows its error code" 'echo "$out" | last_frame | grep -q "terminó con error"'
check "and says so in the status line" 'echo "$out" | last_frame | grep -q "terminó con error"'
out="$(panel : $(typed "./deltactl status tui-a") enter wait q)"
check "a leading ./deltactl is accepted" 'echo "$out" | last_frame | grep -q "Salida . ./deltactl status tui-a"'
out="$(panel : esc q)"
check "Esc cancels the command line" 'echo "$out" | frame_n 3 | grep -q "Cancelado"'
out="$(panel : $(typed "sta") tab)"
check "Tab completes a command and adds a space" 'echo "$out" | last_frame | grep -q "\./deltactl :status $"'
out="$(panel : $(typed "st") tab)"
check "Tab completes the common prefix when there are several" 'echo "$out" | last_frame | grep -q "\./deltactl :st$"'
out="$(panel : $(typed "status tui-") tab)"
check "Tab completes an instance name to the common prefix" 'echo "$out" | last_frame | grep -q "\./deltactl :status tui-$"'
out="$(panel : $(typed "status tui-b") tab)"
check "Tab completes a whole instance name" 'echo "$out" | last_frame | grep -q "\./deltactl :status tui-b "'
out="$(panel : $(typed "status tui-a") enter wait : up)"
check "Up recalls the previous command" 'echo "$out" | last_frame | grep -q "\./deltactl :status tui-a$"'
out="$(panel x q)"
check "x with nothing running says so" 'echo "$out" | frame_n 2 | grep -q "No hay ningún comando en ejecución"'
out="$(panel : $(typed "status tui-a") enter : $(typed "status tui-b") enter wait q)"
check "a second command while one runs is refused or runs after it, never both" 'echo "$out" | grep -q "Hay un comando en ejecución\|Ejecutando: ./deltactl status tui-b"'
out="$(panel 3 q)"
check "the Output view without a command shows the empty message" 'echo "$out" | frame_n 2 | grep -q "Aún no has ejecutado nada"'

section "6. the actions of an instance"
out="$(panel enter q q)"
check "Enter opens the actions with the instance and its n/m" 'echo "$out" | frame_n 2 | grep -q "Acciones de tui-a (2/2)"'
check "the actions name the selected service" 'echo "$out" | frame_n 2 | grep -q "Desplegar solo s0" && echo "$out" | frame_n 2 | grep -q "Logs en vivo de s0" && echo "$out" | frame_n 2 | grep -q "Detener s0"'
check "the other actions are listed" 'echo "$out" | frame_n 2 | grep -q "Ver el estado detallado" && echo "$out" | frame_n 2 | grep -q "Volver a la versión anterior" && echo "$out" | frame_n 2 | grep -q "Bajar la instancia"'
check "a seeded instance does not offer to seed" '! echo "$out" | frame_n 2 | grep -q "Sembrar datos iniciales"'
out="$(panel right enter q q)"
check "the actions follow the selected service" 'echo "$out" | frame_n 3 | grep -q "Desplegar solo s1"'
out="$(panel down enter q q)"
check "an unseeded instance offers to seed" 'echo "$out" | frame_n 3 | grep -q "Acciones de tui-b (0/2)" && echo "$out" | frame_n 3 | grep -q "Sembrar datos iniciales"'
out="$(panel enter enter wait q)"
check "the first action runs status and shows its output" 'echo "$out" | last_frame | grep -q "Salida . ./deltactl status tui-a"'
out="$(panel enter down enter wait q)"
check "the second action runs check and stays in the view" 'echo "$out" | grep -q "Ejecutando: ./deltactl check tui-a" && echo "$out" | last_frame | grep -q "\[1 Instancias\]"'
check "its output is in the pane at the bottom of the view" 'echo "$out" | last_frame | grep -q "Salida . ./deltactl check tui-a"'
out="$(panel enter down down down enter q)"
check "deploy only one service passes the service" 'echo "$out" | grep -q "Ejecutando: ./deltactl deploy tui-a s0"'
out="$(panel enter esc q)"
check "Esc goes back from the actions to the view" 'echo "$out" | frame_n 3 | grep -q "\[1 Instancias\]" && ! echo "$out" | frame_n 3 | grep -q "Acciones de"'

section "7. confirmations"
out="$(panel enter down down down down enter n q)"
check "rollback asks for confirmation and does nothing on n" 'echo "$out" | grep -q "Vuelve a la versión anterior de todos los servicios" && echo "$out" | grep -q "Continuar" && ! echo "$out" | grep -q "Ejecutando: ./deltactl rollback"'
check "the confirmation shows the keys" 'echo "$out" | grep -q "s si - n no (Enter = no)"'
out="$(panel enter down down down down enter y wait q)"
check "rollback runs after confirming with s or y" 'echo "$out" | grep -q "Ejecutando: ./deltactl rollback tui-a --yes"'
out="$(panel enter down down down down down down down enter enter q)"
check "Enter on a confirmation means no" '! echo "$out" | grep -q "Ejecutando: ./deltactl stop"'
out="$(panel enter down down down down down down down enter s wait q)"
check "stop asks and then stops the selected service" 'echo "$out" | grep -q "Ejecutando: ./deltactl stop tui-a s0"'
out="$(panel enter down down down down down down down down enter n q)"
check "down asks for confirmation too" 'echo "$out" | grep -q "Detiene y elimina los contenedores" && ! echo "$out" | grep -q "Ejecutando: ./deltactl down"'
out="$(panel down enter down down down down down down down down down enter $(typed otro) enter q)"
check "init asks to type the instance name and does nothing if it differs" 'echo "$out" | grep -q "Escribe el nombre de la instancia (tui-b)" && echo "$out" | grep -q "El nombre no coincide" && ! echo "$out" | grep -q "Ejecutando: ./deltactl init"'
out="$(panel down enter down down down down down down down down down enter $(typed tui-b) enter wait q)"
check "init runs when the name matches" 'echo "$out" | grep -q "Ejecutando: ./deltactl init tui-b --yes"'

section "8. help, language, pause and refresh"
out="$(panel '?' x q)"
check "? shows the keys over the whole body" 'echo "$out" | frame_n 2 | grep -q "Teclas" && echo "$out" | frame_n 2 | grep -q "q o Esc salir" && echo "$out" | frame_n 2 | grep -q "Pulsa cualquier tecla para volver"'
check "any key closes the help" 'echo "$out" | frame_n 3 | grep -q "\[1 Instancias\]" && ! echo "$out" | frame_n 3 | grep -q "Pulsa cualquier tecla"'
export DELTACTL_CONFIG="$FIX/config"
out="$(panel L q)"
check "L switches to English in the next frame" 'echo "$out" | frame_n 2 | grep -q "\[1 Instances\]  2 Resources   3 Output" && echo "$out" | frame_n 2 | grep -q "Language: English"'
check "L remembers the language in the config file" 'grep -q "^UI_LANG=en$" "$FIX/config"'
out="$(panel L L q)"
check "L twice goes back to Spanish" 'echo "$out" | frame_n 3 | grep -q "\[1 Instancias\]" && grep -q "^UI_LANG=es$" "$FIX/config"'
out="$(panel L 2 q)"
check "the resources view is translated" 'echo "$out" | frame_n 3 | grep -q "INSTANCE  *SVC  *STATE  *MEMORY"'
unset DELTACTL_CONFIG
out="$(panel p q)"
check "p pauses the live updates and says so" 'echo "$out" | frame_n 2 | grep -q "EN PAUSA" && echo "$out" | frame_n 2 | grep -q "Actualización en vivo en pausa"'
out="$(panel p p q)"
check "p again resumes" '! echo "$out" | frame_n 3 | grep -q "EN PAUSA"'
out="$(panel r q)"
check "r refreshes now and says so" 'echo "$out" | frame_n 2 | grep -q "Actualizado"'
out="$(panel timeout timeout q)"
check "an idle tick shows the error counts once and then repaints nothing" '[ "$(echo "$out" | frames)" -eq 2 ] && echo "$out" | frame_n 2 | grep -q "errores (10 min): s0 1 . s1 1"'
check "a key that does nothing repaints once" 'out="$(panel y q)"; [ "$(echo "$out" | frames)" -eq 2 ]'
out="$(panel esc)"
check "Esc in the instances view quits" 'echo "$out" | grep -q "^=== frame 1 ==="'
out="$(panel 2 esc q)"
check "Esc in another view goes back to the instances" 'echo "$out" | frame_n 3 | grep -q "\[1 Instancias\]"'

section "9. the output view"
seq_cmd=$(typed "logs tui-a s0")
out="$(panel : $seq_cmd enter wait 3 q)"
check "the output keeps every line" 'echo "$out" | last_frame | grep -q "linea normal" && echo "$out" | last_frame | grep -q "ERROR de prueba"'
out="$(panel : $seq_cmd enter wait 3 e q)"
check "e keeps only the lines with errors" 'echo "$out" | last_frame | grep -q "ERROR de prueba" && ! echo "$out" | last_frame | grep -q "linea normal" && echo "$out" | last_frame | grep -q "solo errores\|errors only\|Salida"'
out="$(panel : $(typed "help variables") enter wait 3 up q)"
check "up scrolls the output and says so" 'echo "$out" | last_frame | grep -q "desplazado -"'
out="$(panel : $seq_cmd enter wait 3 up down q)"
check "down goes back to the end" '! echo "$out" | last_frame | grep -q "desplazado"'
out="$(panel : $seq_cmd enter wait 3 pgup home end q)"
check "PgUp, Home and End do not break the view" 'echo "$out" | last_frame | grep -q "linea normal"'
out="$(panel l wait q)"
check "l follows the logs of the selected service in the Output view" 'echo "$out" | grep -q "Ejecutando: ./deltactl logs tui-a s0 -f" && echo "$out" | last_frame | grep -q "\[3 Salida\]"'

section "10. Docker events and rendering details"
run_lib() { ROOT="$PWD" DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_ASCII=1 COLUMNS=100 bash -c 'source lib/bootstrap.sh; source lib/cmd/dashboard.sh; '"$1" 2>&1; }
printf 'start\ndie\n' > "$FIX/events.txt"
check "pending events are read without waiting" '[ "$(run_lib "exec 8< $FIX/events.txt; DASH_EV_FD=8; dash_events_drain && echo got || echo none")" = "got" ]'
check "when the stream ends the panel falls back to polling" '[ "$(run_lib "exec 8< $FIX/events.txt; DASH_EV_FD=8; dash_events_drain; dash_events_drain; echo [\$DASH_EV_FD]")" = "[]" ]'
check "without a stream there are no events" '[ "$(run_lib "dash_events_drain && echo got || echo none")" = "none" ]'
check "an event makes the next idle tick refresh the state" '[ "$(run_lib "dash_refresh; DASH_REFRESH_AT=\$SECONDS; exec 8< $FIX/events.txt; DASH_EV_FD=8; DASH_IDLE=1; MT_LAST_US=\$(date +%s)000000; dash_tick; echo \$DASH_EV_PENDING-\$DASH_REFRESH_AT")" != "" ]'
check "a finished command forces a refresh" '[ "$(run_lib "dash_refresh; job_start t true; for i in 1 2 3 4 5 6 7 8 9 10; do job_poll; job_running || break; sleep 0.1; done; dash_job_tick; echo \$DASH_FORCE_REFRESH")" = "1" ]'
# A frame built with a known CPU reading
CPU_SCRIPT='tui_size; dash_init; dash_refresh; mt_sample; MT_CPU[tui-a/s0]=123; MT_HCPU[tui-a/s0]="10 50 123"; MT_CPU[tui-a/s1]=2005; dash_host_build; dash_render'
check "the CPU is shown with one decimal and a trend" 'run_lib "$CPU_SCRIPT" | grep -q "cpu  \[#\.*\] 12.3%  [_.:=+*#-]*"'
check "a CPU above 100% fills the bar and keeps the figure" 'run_lib "$CPU_SCRIPT" | grep -q "cpu  \[#*\] 200.5%"'
check "the Resources view shows the CPU of each service" 'run_lib "$CPU_SCRIPT; DASH_VIEW=resources; dash_render" | last_frame | grep "tui-a  *s0" | grep -q "12.3%"'
check "a narrow screen still draws every view without overflow" 'for c in 40 60 80; do for v in instances resources output; do run_lib "COLUMNS=$c; tui_size; $CPU_SCRIPT; DASH_VIEW=$v; dash_render" | while IFS= read -r l; do [ "${#l}" -le "$c" ] || echo "WIDE:$c:$v"; done; done; done | grep -q WIDE && exit 1; exit 0'
check "a small screen still draws every view" 'for r in 14 20; do for v in instances resources output; do run_lib "DELTACTL_TUI_ROWS=$r; tui_size; $CPU_SCRIPT; DASH_VIEW=$v; dash_render" | last_frame | grep -q "q salir" || exit 1; done; done'
check "a terminal that is too small says so instead of drawing broken boxes" 'run_lib "DELTACTL_TUI_ROWS=10; tui_size; $CPU_SCRIPT; dash_render" | last_frame | grep -q "demasiado pequeña" && run_lib "COLUMNS=50; tui_size; $CPU_SCRIPT; dash_render" | last_frame | grep -q "demasiado pequeña"'
check "the frame never has more lines than the screen" '[ "$(run_lib "$CPU_SCRIPT" | last_frame | wc -l)" -le 31 ]'

section "10b. work in the background"
ASYNC='dash_init; tui_size; DASH_SEL=0; '
check "the state producer prints declare lines and the consumer loads them" '[ "$(run_lib "$ASYNC dash_state_dump > $FIX/dump.txt; DASH_NAMES=(); DASH_NM=(); dash_state_apply \"\$(cat $FIX/dump.txt)\"; echo \${#DASH_NAMES[@]} \${DASH_NM[tui-a]} \${DASH_NM[tui-c]}")" = "3 2/2 1/2" ]'
check "an asynchronous refresh ends with the same state as a synchronous one" '[ "$(run_lib "$ASYNC dash_async state \"\" dash_state_dump; for i in \$(seq 1 50); do dash_async_take state && break; sleep 0.1; done; dash_state_apply \"\$DASH_AS_TEXT\"; echo \${DASH_NM[tui-a]} \${DSV_KIND[tui-a/s0]} \${ST_PID[tui-a/s0]}")" = "2/2 ok 1234" ]'
check "a slot runs one thing at a time" '[ "$(run_lib "$ASYNC dash_async x a sleep 1; dash_async x b sleep 1 && echo started || echo busy; dash_async_stop")" = "busy" ]'
check "a producer that fails leaves no result and frees the slot" '[ "$(run_lib "$ASYNC dash_async x a false; for i in \$(seq 1 30); do dash_async_take x && break; sleep 0.1; done; echo [\${DASH_AS_PID[x]}]")" = "[]" ]'
check "the loop starts the refresh without waiting and applies it later" '[ "$(run_lib "$ASYNC DELTACTL_TUI_KEYS=; unset DELTACTL_TUI_KEYS; DASH_REFRESH_WANT=1; dash_async_tick; started=\${DASH_AS_PID[state]:+yes}; for i in \$(seq 1 50); do dash_async_tick && break; sleep 0.1; done; echo \$started \${DASH_NM[tui-a]}")" = "yes 2/2" ]'
check "the error counts are collected and applied per instance" '[ "$(run_lib "$ASYNC dash_refresh; dash_errors_apply tui-a \"\$(dash_errors_collect tui-a)\"; echo \${DASH_ERRS[tui-a/s0]} \${DASH_ERRS[tui-a/s1]} \${DASH_ERRS_AT[tui-a]:+set}")" = "1 1 set" ]'
check "typing in the command line reuses the body of the frame" '[ "$(run_lib "$ASYNC dash_refresh; DASH_MODE=cmd; DASH_BUF=x; dash_render >/dev/null; s=\$DASH_BODY_SIG; DASH_BUF=xy; dash_render > /dev/null; [ \"\$s\" = \"\$DASH_BODY_SIG\" ] && echo same || echo rebuilt")" = "same" ]'
check "the body is reused when nothing that it shows changed" '[ "$(run_lib "$ASYNC dash_refresh; dash_render >/dev/null; DASH_BUF=x; DASH_MSG=hello; s=\$DASH_BODY_SIG; dash_render > /dev/null; [ \"\$s\" = \"\$DASH_BODY_SIG\" ] && echo same || echo rebuilt")" = "same" ]'

section "11. without a terminal the panel is not used"
check "tui_interactive is false in a pipe and true in test mode" '! ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/ui/tui.sh; tui_interactive" < /dev/null && DELTACTL_TUI_KEYS=/dev/null ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/ui/tui.sh; tui_interactive"'
check "the menu keeps the numbered menu when it is not a terminal" 'printf "0\n" | DELTACTL_UI=plain bash ./deltactl menu 2>&1 | grep -q "1) Ver estado"'
check "menu --classic forces the numbered menu even in the panel test mode" 'printf "0\n" > "$FIX/k0"; printf "0\n" | DELTACTL_TUI_KEYS="$FIX/k0" DELTACTL_UI=plain bash ./deltactl menu --classic 2>&1 | grep -q "1) Ver estado"'
check "menu in the panel test mode opens the panel" 'printf "q\n" > "$FIX/kq"; DELTACTL_TUI_KEYS="$FIX/kq" DELTACTL_UI=rich bash ./deltactl menu 2>&1 | grep -q "^=== frame 1 ==="'
check "menu still rejects other arguments" 'DELTACTL_LANG=es bash ./deltactl menu extra 2>&1 | grep -q "^ERROR menu no recibe argumentos"'
check "the static home screen is used when the terminal is not interactive" 'DELTACTL_UI=rich DELTACTL_COLOR=never bash ./deltactl 2>&1 < /dev/null | grep -q "^Estado de las instancias"'

section "12. terminal layer"
tk() { # bytes -> TUI_KEY (reads from stdin as a terminal would deliver them)
  ROOT="$PWD" bash -c 'source lib/bootstrap.sh; source lib/ui/tui.sh; tui_key; printf "%s" "$TUI_KEY"'
}
check "tui_key reads the arrow keys" '[ "$(printf "\033[A" | tk)" = "up" ] && [ "$(printf "\033[B" | tk)" = "down" ] && [ "$(printf "\033[C" | tk)" = "right" ] && [ "$(printf "\033[D" | tk)" = "left" ]'
check "tui_key reads the application-mode arrows too" '[ "$(printf "\033OA" | tk)" = "up" ] && [ "$(printf "\033OB" | tk)" = "down" ]'
check "tui_key reads Home, End, PageUp, PageDown and Delete" '[ "$(printf "\033[H" | tk)" = "home" ] && [ "$(printf "\033[F" | tk)" = "end" ] && [ "$(printf "\033[5~" | tk)" = "pgup" ] && [ "$(printf "\033[6~" | tk)" = "pgdn" ] && [ "$(printf "\033[3~" | tk)" = "delete" ] && [ "$(printf "\033[1~" | tk)" = "home" ] && [ "$(printf "\033[4~" | tk)" = "end" ]'
check "tui_key does not take an unknown sequence for Escape" '[ "$(printf "\033[15~" | tk)" = "other" ] && [ "$(printf "\033[1;5C" | tk)" = "other" ] && [ "$(printf "\033OP" | tk)" = "other" ]'
check "tui_key reads Enter, Tab, Backspace and Escape" '[ "$(printf "\n" | tk)" = "enter" ] && [ "$(printf "\t" | tk)" = "tab" ] && [ "$(printf "\177" | tk)" = "backspace" ] && [ "$(printf "\033" | tk)" = "esc" ]'
check "tui_key returns the typed character" '[ "$(printf "j" | tk)" = "j" ] && [ "$(printf "L" | tk)" = "L" ] && [ "$(printf "?" | tk)" = "?" ] && [ "$(printf ":" | tk)" = ":" ]'
check "tui_key reports the end of input as eof" '[ "$(tk < /dev/null)" = "eof" ]'
check "tui_key times out" '[ "$( (sleep 2) | ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/ui/tui.sh; tui_key 0.2; printf \"%s\" \"\$TUI_KEY\"")" = "timeout" ]'
tl() { ROOT="$PWD" DELTACTL_UI=rich DELTACTL_COLOR=always bash -c 'source lib/bootstrap.sh; source lib/ui/tui.sh; '"$1"; }
check "tui_vlen ignores the color sequences" '[ "$(tl "tui_vlen \"\${C_RED}hello\${C_OFF} \${C_GRN}world\${C_OFF}\"; echo \$TUI_VL")" = "11" ]'
check "tui_clip cuts to the width and keeps the colors consistent" '[ "$(tl "tui_clip \"\${C_RED}hello\${C_OFF} \${C_GRN}world\${C_OFF}\" 8; tui_vlen \"\$TUI_OUT\"; echo \$TUI_VL")" = "8" ]'
check "tui_clip leaves a short text alone" '[ "$(tl "tui_clip abc 8; echo \"[\$TUI_OUT]\"")" = "[abc]" ]'
check "tui_fit pads and cuts to the exact width" '[ "$(tl "tui_fit ab 5; echo \"[\$TUI_OUT]\"; tui_fit abcdefgh 5; echo \"[\$TUI_OUT]\"")" = "$(printf "[ab   ]\n[abcde]")" ]'
check "tui_box makes every line exactly as wide as asked" '[ "$(tl "b=(one \"two \${C_YEL}yellow\${C_OFF}\" \"a line that is far too long to fit\"); tui_box Title 20 6 b; for l in \"\${TUI_BOX[@]}\"; do tui_vlen \"\$l\"; printf \"%s \" \$TUI_VL; done")" = "20 20 20 20 20 20 " ]'
check "tui_box has the title in the top border and as many lines as asked" '[ "$(DELTACTL_ASCII=1 tl "b=(x); tui_box Title 20 5 b; echo \${#TUI_BOX[@]}; tui_vlen \"\${TUI_BOX[0]}\"; echo \"\${TUI_BOX[0]}\"" | head -1)" = "5" ]'
draw_script() { # TUI_FORCE after the first draw is 0: only changed lines are written
  tl 'TUI_ROWS=10; TUI_COLS=40; TUI_FRAME=(one two three); tui_draw >/dev/null; TUI_FRAME=(one TWO three); tui_draw' | od -An -c | tr -d ' \n'
}
check "tui_draw repaints only the lines that changed" 'out="$(draw_script)"; echo "$out" | grep -q "033\[2;1HTWO" && ! echo "$out" | grep -q "one" && ! echo "$out" | grep -q "three"'
check "tui_draw clears the screen on the first frame and after a resize" 'out="$(tl "TUI_ROWS=10; TUI_FRAME=(one); tui_draw" | od -An -c | tr -d " \n")"; echo "$out" | grep -q "033\[2J"'
check "tui_draw clears lines that disappeared" 'out="$(tl "TUI_ROWS=10; TUI_FRAME=(one two three); tui_draw >/dev/null; TUI_FRAME=(one); tui_draw" | od -An -c | tr -d " \n")"; echo "$out" | grep -q "033\[2;1H033\[K" && echo "$out" | grep -q "033\[3;1H033\[K"'
check "tui_draw puts the cursor in the command line when asked" 'out="$(tl "TUI_ROWS=10; TUI_FRAME=(one); TUI_CURSOR=\"5;7\"; tui_draw" | od -An -c | tr -d " \n")"; echo "$out" | grep -q "033\[5;7H033\[?25h"'
check "tui_enter and tui_leave switch the alternate screen once each" 'out="$(ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/ui/tui.sh; tui_enter; tui_enter; tui_leave; tui_leave" | od -An -c | tr -d " \n")"; [ "$(echo "$out" | grep -o "033\[?1049h" | wc -l)" -eq 1 ] && [ "$(echo "$out" | grep -o "033\[?1049l" | wc -l)" -eq 1 ]'
check "tui_enter stops line wrapping and tui_leave restores it" 'out="$(ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/ui/tui.sh; tui_enter; tui_leave" | od -An -c | tr -d " \n")"; echo "$out" | grep -q "033\[?7l" && echo "$out" | grep -q "033\[?7h"'
check "the test mode takes the size from DELTACTL_TUI_ROWS and COLUMNS" '[ "$(DELTACTL_TUI_KEYS=/dev/null DELTACTL_TUI_ROWS=33 COLUMNS=120 ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/ui/tui.sh; tui_size; echo \$TUI_ROWS x \$TUI_COLS")" = "33 x 120" ]'

finish

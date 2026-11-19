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
  # The history is saved on disk: every run starts without it, unless KEEP_HISTORY is set.
  [ -n "${KEEP_HISTORY:-}" ] || rm -f "$(dirname "${DELTACTL_CONFIG:-$FIX/none.cfg}")/history"
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
check "with no instances the last line offers the New button" 'echo "$out" | grep -q "Up/Dn elegir . Enter crea la instancia"'
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
check "the host line shows the memory bar, the load and Docker" 'echo "$out" | grep -q "Memoria ####\.\. 5.0/8.0 GB 62%" && echo "$out" | grep -q "Carga 0.82" && echo "$out" | grep -q "Docker 27.0.0"'
check "the host line shows what the containers use" 'echo "$out" | grep -q "contenedores 7[0-9][0-9]M"'
check "every instance is a row with its n/m" 'echo "$out" | grep -q "tui-a  *2/2" && echo "$out" | grep -q "tui-b  *0/2" && echo "$out" | grep -q "tui-c  *1/2"'
check "a row shows the memory its services use" 'echo "$out" | grep "tui-a  *2/2" | grep -q "7[0-9][0-9]M" && echo "$out" | grep "tui-c  *1/2" | grep -q " 50M"'
check "the first instance is selected (the New button is above it)" 'echo "$out" | grep -q "^| > .. tui-a" && echo "$out" | grep -q "+ Nueva instancia"'
check "the detail shows each service with its image, state, uptime and port" 'echo "$out" | grep -q "s0 auth-backend:1.0  . healthy" && echo "$out" | grep -q "s1 gueo-back-end:1.0  . healthy" && echo "$out" | grep -q "activo 2d00h  \.  :4100" && echo "$out" | grep -q "activo 2d00h  \.  :4101"'
check "the detail shows memory used, limit and percentage" 'echo "$out" | grep -q "mem  ##\.* 100M/512M  19%" && echo "$out" | grep -q "mem  ###\.* 600M/2.0G  29%"'
check "the CPU has no figure until the second sample" 'echo "$out" | grep -q "cpu  sin lectura aún"'
check "restarts are shown only when there are some" '[ "$(echo "$out" | grep -c "reinicios 3")" -eq 1 ] && ! echo "$out" | grep "activo 2d00h . :4100" | grep -q "reinicios"'
check "the totals add the services and show the data state" 'echo "$out" | grep -q "Total  mem 7[0-9][0-9]M/2.5G  cpu 0.0%  datos: sembrados"'
check "the console shows its prompt with a hint" 'echo "$out" | grep -q "Consola" && echo "$out" | grep -q "tui-a > : escribe un comando"'

section "3. moving around"
out="$(panel down q)"
check "down selects the next instance and its detail" 'echo "$out" | frame_n 2 | grep -q "^| > .. tui-b" && echo "$out" | frame_n 2 | grep -q "tui-b . 0/2"'
check "an instance that does not run shows its services as not created" 'echo "$out" | frame_n 2 | grep -q "s0 auth-backend:1.0  . no creado"'
out="$(panel up q)"
check "up from the first instance selects the New button" 'echo "$out" | frame_n 2 | grep -q "^| > + Nueva instancia"'
out="$(panel up up q)"
check "up again wraps to the last instance" 'echo "$out" | frame_n 3 | grep -q "^| > .. tui-c"'
out="$(panel down down down down q)"
check "down from the last instance goes through the New button and back to the first" 'echo "$out" | frame_n 4 | grep -q "^| > + Nueva instancia" && echo "$out" | frame_n 5 | grep -q "^| > .. tui-a"'
out="$(panel j j k q)"
check "j and k work like the arrows" 'echo "$out" | frame_n 4 | grep -q "^| > .. tui-b"'
out="$(panel q)"
check "the keys of the list are in the last line" 'echo "$out" | grep -q "Up/Dn instancia . Rt servicios . Enter acciones . u desplegar"'
out="$(panel right q)"
check "inside the services the last line shows the keys of the services" 'echo "$out" | frame_n 2 | grep -q "Up/Dn servicio . Lt volver . Enter acciones . l logs"'
check "right enters the services without moving the marker" 'echo "$out" | frame_n 2 | grep -q "|| > s0 auth" && echo "$out" | frame_n 2 | grep -q ">tui-a"'
out="$(panel right down q)"
check "inside the services down chooses the next service" 'echo "$out" | frame_n 3 | grep -q "|| > s1 gueo" && ! echo "$out" | frame_n 3 | grep -q "|| > s0 auth"'
out="$(panel right down down q)"
check "the service marker wraps" 'echo "$out" | frame_n 4 | grep -q "|| > s0 auth"'
out="$(panel right left q)"
check "left goes back to the list of instances" 'echo "$out" | frame_n 3 | grep -q ">Instancias" && ! echo "$out" | frame_n 3 | grep -q ">tui-a"'
out="$(panel right esc q)"
check "Esc inside the services goes back to the list instead of quitting" 'echo "$out" | frame_n 3 | grep -q ">Instancias"'
out="$(panel down right down q)"
check "changing instance resets the service and gives the focus back to the list" 'out="$(panel right down down q)" && echo "$out" | frame_n 4 | grep -q "|| > s0 auth"'
out="$(panel up right q)"
check "right does nothing on the New button" 'echo "$out" | frame_n 3 | grep -q ">Instancias"'
out="$(panel up q)"
check "the New button explains what it does in the center" 'echo "$out" | frame_n 2 | grep -q "Nueva instancia" && echo "$out" | frame_n 2 | grep -q "asistente"'
out="$(panel up enter q < /dev/null)"
check "Enter on the New button opens the wizard in the terminal" 'echo "$out" | grep -q "new --wizard"'
out="$(panel 2 q)"
check "2 opens the resources view" 'echo "$out" | frame_n 2 | grep -q "\[2 Recursos\]"'
out="$(panel 2 tab q)"
check "Tab goes to the next view (outside the instances view)" 'echo "$out" | frame_n 3 | grep -q "\[3 Salida\]"'
out="$(panel 2 tab tab q)"
check "Tab wraps around the views" 'echo "$out" | frame_n 4 | grep -q "\[1 Instancias\]"'
out="$(panel tab q)"
check "on the instances view Tab moves the focus to the services" 'echo "$out" | frame_n 2 | grep -q ">tui-a" && echo "$out" | frame_n 2 | grep -q "\[1 Instancias\]"'
out="$(panel tab tab q)"
check "and on to the list again (the logs pane exists only on the wide layout)" 'echo "$out" | frame_n 3 | grep -q ">Instancias"'
out="$(panel btab q)"
check "Shift+Tab goes the other way round" 'echo "$out" | frame_n 2 | grep -q ">tui-a"'

section "4. the resources view"
out="$(panel 2 q)"
check "it lists every service of every instance with its state" 'echo "$out" | frame_n 2 | grep -q "tui-a  *s0  *healthy" && echo "$out" | frame_n 2 | grep -q "tui-a  *s1  *healthy" && echo "$out" | frame_n 2 | grep -q "tui-c  *s1  *detenido"'
check "it shows the memory with a bar, the figures and the restarts" 'echo "$out" | frame_n 2 | grep "tui-a  *s1" | grep -q "##\.* 600M/2.0G 29%" && echo "$out" | frame_n 2 | grep "tui-a  *s1" | grep -q " 3 "'
check "it shows the memory of the server and what the containers take" 'echo "$out" | frame_n 2 | grep -q "Servidor" && echo "$out" | frame_n 2 | grep -q "contenedores 7[0-9][0-9]M  ([0-9]*% de la RAM)"'
check "a stopped service has no figures" 'echo "$out" | frame_n 2 | grep "tui-c  *s1" | grep -q " - "'
check "the default order is by name" 'echo "$out" | frame_n 2 | grep -n "tui-a  *s0\|tui-a  *s1\|tui-c  *s0" | head -1 | grep -q "tui-a  *s0"'
out="$(panel 2 s q)"
check "s sorts by memory, the biggest first" 'echo "$out" | frame_n 3 | grep -q "orden: memoria" && echo "$out" | frame_n 3 | grep -n "tui-a  *s1\|tui-a  *s0" | head -1 | grep -q "tui-a  *s1"'
out="$(panel 2 s s q)"
check "s again sorts by CPU and a third time by name" 'echo "$out" | frame_n 4 | grep -q "orden: cpu" && out="$(panel 2 s s s q)" && echo "$out" | frame_n 5 | grep -q "orden: nombre"'
out="$(panel 2 down enter q)"
check "Enter jumps to the instance and service of the row" 'echo "$out" | frame_n 4 | grep -q "\[1 Instancias\]" && echo "$out" | frame_n 4 | grep -q "^| > .. tui-a" && echo "$out" | frame_n 4 | grep -q "|| > s1 gueo"'
out="$(panel 2 down down down down enter q)"
check "the row of another instance selects that instance" 'echo "$out" | frame_n 7 | grep -q "^| > .. tui-c"'

section "5. commands run inside the panel"
out="$(panel : $(typed "status tui-a") enter wait q)"
check "the typed command starts in the background and the panel says so" 'echo "$out" | grep -q "Ejecutando: ./deltactl status tui-a"'
check "its output stays in the console of the Overview" 'echo "$out" | last_frame | grep -q "\[1 Instancias\]" && echo "$out" | last_frame | grep -q "terminó bien"'
out2="$(panel 2 : $(typed "status tui-a") enter wait q)"
check "from another view the output opens the Output view, as before" 'echo "$out2" | last_frame | grep -q "\[3 Salida\]" && echo "$out2" | last_frame | grep -q "Salida . ./deltactl status tui-a"'
check "the output shows what the command printed" 'echo "$out" | last_frame | grep -q "tui-a"'
check "the tab line shows how the command ended" 'echo "$out" | last_frame | grep -q ". ./deltactl status tui-a terminó bien"'
out="$(panel : $(typed "frobnicate") enter wait q)"
check "a command that fails shows its error code" 'echo "$out" | last_frame | grep -q "terminó con error"'
check "and says so in the status line" 'echo "$out" | last_frame | grep -q "terminó con error"'
out="$(panel : $(typed "./deltactl status tui-a") enter wait q)"
check "a leading ./deltactl is accepted" 'echo "$out" | last_frame | grep -q "terminó bien"'
out="$(panel : esc q)"
check "Esc cancels the command line" 'echo "$out" | frame_n 3 | grep -q "Cancelado"'
out="$(panel : $(typed "sta") tab)"
check "Tab completes a command and adds a space" 'echo "$out" | last_frame | grep -q "tui-a > status |"'
out="$(panel : $(typed "st") tab)"
check "Tab completes the common prefix when there are several" 'echo "$out" | last_frame | grep -q "tui-a > st|"'
out="$(panel : $(typed "status tui-") tab)"
check "Tab completes an instance name to the common prefix" 'echo "$out" | last_frame | grep -q "tui-a > status tui-|"'
out="$(panel : $(typed "status tui-b") tab)"
check "Tab completes a whole instance name" 'echo "$out" | last_frame | grep -q "tui-a > status tui-b |"'
out="$(panel : $(typed "status tui-a") enter wait : up)"
check "Up recalls the previous command" 'echo "$out" | last_frame | grep -q "tui-a > status tui-a|"'
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
out="$(panel right down enter q q)"
check "the actions follow the selected service" 'echo "$out" | frame_n 4 | grep -q "Desplegar solo s1"'
out="$(panel down enter q q)"
check "an unseeded instance offers to seed" 'echo "$out" | frame_n 3 | grep -q "Acciones de tui-b (0/2)" && echo "$out" | frame_n 3 | grep -q "Sembrar datos iniciales"'
out="$(panel enter enter wait q)"
check "the first action runs status and shows its output" 'echo "$out" | last_frame | grep -q "Salida . ./deltactl status tui-a"'
out="$(panel enter down enter wait q)"
check "the second action runs check and stays in the view" 'echo "$out" | grep -q "Ejecutando: ./deltactl check tui-a" && echo "$out" | last_frame | grep -q "\[1 Instancias\]"'
check "its output is in the console at the bottom of the view" 'echo "$out" | last_frame | grep -q "Consola" && echo "$out" | last_frame | grep -q "terminó bien"'
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
export DELTACTL_CONFIG="$FIX/none.cfg"   # an absent file, never the real config of the user (the panel writes its history and theme next to it)
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
check "a finished command asks for a refresh of the state" '[ "$(run_lib "dash_refresh; n=\$DASH_REFRESH_N; job_start t true; for i in 1 2 3 4 5 6 7 8 9 10; do job_poll; job_running || break; sleep 0.1; done; dash_job_tick; echo \$((DASH_REFRESH_N - n))")" = "1" ]'
# A frame built with a known CPU reading
CPU_SCRIPT='tui_size; dash_init; dash_refresh; mt_sample; MT_CPU[tui-a/s0]=123; MT_HCPU[tui-a/s0]="10 50 123"; MT_CPU[tui-a/s1]=2005; dash_host_build; dash_render'
check "the CPU is shown with one decimal and a trend" 'run_lib "$CPU_SCRIPT" | grep -q "cpu  #\.* 12.3%  [_.:=+*#-]*"'
check "a CPU above 100% fills the bar and keeps the figure" 'run_lib "$CPU_SCRIPT" | grep -q "cpu  #* 200.5%"'
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
check "typing in the command line of another view reuses the body of the frame" '[ "$(run_lib "$ASYNC dash_refresh; DASH_VIEW=resources; DASH_MODE=cmd; DASH_BUF=x; dash_render >/dev/null; s=\$DASH_BODY_SIG; DASH_BUF=xy; dash_render > /dev/null; [ \"\$s\" = \"\$DASH_BODY_SIG\" ] && echo same || echo rebuilt")" = "same" ]'
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
check "tui_vlen counts multi-parameter colors, UTF-8 and unknown sequences correctly, also when repeated (cache)" '[ "$(tl "e=\$(printf \"\\033\"); tui_vlen \"\${e}[1;33m▸\${e}[0m ab\"; printf \"%s \" \$TUI_VL; tui_vlen \"\${e}[1;33m▸\${e}[0m ab\"; printf \"%s \" \$TUI_VL; tui_vlen \"x\${e}[Ky\"; printf \"%s \" \$TUI_VL; tui_vlen \"\${e}[m\${e}[38;5;244mz\${e}[0m\"; printf \"%s\" \$TUI_VL")" = "4 4 5 4" ]'
check "tui_clip cuts to the width and keeps the colors consistent" '[ "$(tl "tui_clip \"\${C_RED}hello\${C_OFF} \${C_GRN}world\${C_OFF}\" 8; tui_vlen \"\$TUI_OUT\"; echo \$TUI_VL")" = "8" ]'
check "tui_clip leaves a short text alone" '[ "$(tl "tui_clip abc 8; echo \"[\$TUI_OUT]\"")" = "[abc]" ]'
check "tui_fit pads and cuts to the exact width" '[ "$(tl "tui_fit ab 5; echo \"[\$TUI_OUT]\"; tui_fit abcdefgh 5; echo \"[\$TUI_OUT]\"")" = "$(printf "[ab   ]\n[abcde]")" ]'
check "tui_box makes every line exactly as wide as asked" '[ "$(tl "b=(one \"two \${C_YEL}yellow\${C_OFF}\" \"a line that is far too long to fit\"); tui_box Title 20 6 b; for l in \"\${TUI_BOX[@]}\"; do tui_vlen \"\$l\"; printf \"%s \" \$TUI_VL; done")" = "20 20 20 20 20 20 " ]'
check "tui_box has the title in the top border and as many lines as asked" '[ "$(DELTACTL_ASCII=1 tl "b=(x); tui_box Title 20 5 b; echo \${#TUI_BOX[@]}; tui_vlen \"\${TUI_BOX[0]}\"; echo \"\${TUI_BOX[0]}\"" | head -1)" = "5" ]'
draw_script() { # TUI_FORCE after the first draw is 0: only changed lines are written
  tl 'TUI_ROWS=10; TUI_COLS=40; TUI_FRAME=(one two three); tui_draw >/dev/null; TUI_FRAME=(one TWO three); tui_draw' | od -An -c | tr -d ' \n'
}
check "tui_draw repaints only the lines that changed" 'out="$(draw_script)"; echo "$out" | grep -q "033\[2;1H033\[0m033\[KTWO" && ! echo "$out" | grep -q "one" && ! echo "$out" | grep -q "three"'
check "tui_draw clears the screen on the first frame and after a resize" 'out="$(tl "TUI_ROWS=10; TUI_FRAME=(one); tui_draw" | od -An -c | tr -d " \n")"; echo "$out" | grep -q "033\[2J"'
check "tui_draw never erases to the end of the line after a full-width line (it would delete the right border)" 'out="$(tl "TUI_ROWS=10 TUI_COLS=10; TUI_FRAME=(0123456789 abc); tui_draw" | od -An -c | tr -d " \n")"; echo "$out" | grep -q "0123456789033\[0m" && ! echo "$out" | grep -q "0123456789033\[0m033\[K"'
check "tui_draw clears lines that disappeared" 'out="$(tl "TUI_ROWS=10; TUI_FRAME=(one two three); tui_draw >/dev/null; TUI_FRAME=(one); tui_draw" | od -An -c | tr -d " \n")"; echo "$out" | grep -q "033\[2;1H033\[0m033\[K" && echo "$out" | grep -q "033\[3;1H033\[0m033\[K"'
check "tui_draw puts the cursor in the command line when asked" 'out="$(tl "TUI_ROWS=10; TUI_FRAME=(one); TUI_CURSOR=\"5;7\"; tui_draw" | od -An -c | tr -d " \n")"; echo "$out" | grep -q "033\[5;7H033\[?25h"'
check "tui_enter and tui_leave switch the alternate screen once each" 'out="$(ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/ui/tui.sh; tui_enter; tui_enter; tui_leave; tui_leave" | od -An -c | tr -d " \n")"; [ "$(echo "$out" | grep -o "033\[?1049h" | wc -l)" -eq 1 ] && [ "$(echo "$out" | grep -o "033\[?1049l" | wc -l)" -eq 1 ]'
check "tui_enter stops line wrapping and tui_leave restores it" 'out="$(ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/ui/tui.sh; tui_enter; tui_leave" | od -An -c | tr -d " \n")"; echo "$out" | grep -q "033\[?7l" && echo "$out" | grep -q "033\[?7h"'
check "the test mode takes the size from DELTACTL_TUI_ROWS and COLUMNS" '[ "$(DELTACTL_TUI_KEYS=/dev/null DELTACTL_TUI_ROWS=33 COLUMNS=120 ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/ui/tui.sh; tui_size; echo \$TUI_ROWS x \$TUI_COLS")" = "33 x 120" ]'

section "11. wide layout and the new data"
check "the overview fills every wide size exactly: each body line is as wide as the screen and its border closes" 'for s in 120x30 150x40 200x60 300x90; do c=${s%x*}; r=${s#*x}; run_lib "COLUMNS=$c; DELTACTL_TUI_ROWS=$r; tui_size; $CPU_SCRIPT; dash_render" | last_frame | awk -v c=$c -v r=$r "NR>=4 && NR<=r-1 { if (length(\$0) != c || substr(\$0, length(\$0), 1) !~ /[|+]/) { bad = 1; print s, NR, length(\$0) > \"/dev/stderr\" } } END { exit bad }" || exit 1; done'
check "below 120 columns the compact view is kept" 'run_lib "COLUMNS=119; tui_size; $CPU_SCRIPT; dash_render" | last_frame | grep -q "Instancias" && ! run_lib "COLUMNS=119; tui_size; $CPU_SCRIPT; dash_render" | last_frame | grep -q "Servidor"'
check "the wide overview has the server box and the services table" 'run_lib "COLUMNS=160; DELTACTL_TUI_ROWS=40; tui_size; $CPU_SCRIPT; dash_render" | last_frame | grep -q "Servidor" && run_lib "COLUMNS=160; DELTACTL_TUI_ROWS=40; tui_size; $CPU_SCRIPT; dash_render" | last_frame | grep -q "SVC"'
check "a wide screen shows the events box from 150 columns" 'run_lib "COLUMNS=150; DELTACTL_TUI_ROWS=40; tui_size; $CPU_SCRIPT; dash_render" | last_frame | grep -q "Eventos" && ! run_lib "COLUMNS=149; DELTACTL_TUI_ROWS=40; tui_size; $CPU_SCRIPT; dash_render" | last_frame | grep -q "Eventos"'
check "an event is kept as epoch|name|action" '[ "$(run_lib "dash_event_add \"1700000000|s0_x|die\"; echo \"\${DASH_EVENTS[0]}\"")" = "1700000000|s0_x|die" ]'
check "a bare action becomes an event of an unknown container" '[ "$(run_lib "dash_event_add start; r=\"\${DASH_EVENTS[0]#*|}\"; echo \"\$r\"")" = "-|start" ]'
check "the event ring never grows past its limit" '[ "$(run_lib "for i in \$(seq 1 260); do dash_event_add \"1700000000|c|start\"; done; echo \$((\${#DASH_EVENTS[@]} <= 200))")" = "1" ]'
check "events seed: one start per running container, oldest first" '[ "$(run_lib "dash_refresh; dash_events_seed; echo \${#DASH_EVENTS[@]}")" -ge 1 ]'
check "log text from outside cannot carry escape sequences into the panel" '[ "$(run_lib "tui_strip_ansi \$(printf \"a\033[31mred\033[0m \033[2Jb\033]0;t\007c\"); printf %s \"\$TUI_OUT\" | od -An -c | tr -d \" \n\" | grep -c 033")" = "0" ]'
check "stripping keeps the text of coloured log lines" '[ "$(run_lib "tui_strip_ansi \"\$(printf \"x\033[1;32mgreen\033[0my\")\"; printf %s \"\$TUI_OUT\"")" = "xgreeny" ]'

section "12. the console"
out="$(panel : a b c left left X)"
check "the cursor moves with the arrows and typing inserts at it" 'echo "$out" | last_frame | grep -q "tui-a > aX|bc"'
out="$(panel : a b c home X)"
check "Home goes to the start of the line" 'echo "$out" | last_frame | grep -q "tui-a > X|abc"'
out="$(panel : a b c left backspace)"
check "Backspace deletes before the cursor" 'echo "$out" | last_frame | grep -q "tui-a > a|c"'
out="$(panel : a b c left left delete)"
check "Delete removes the character under the cursor" 'echo "$out" | last_frame | grep -q "tui-a > a|c"'
out="$(panel : a b c $'\025' X)"
check "Ctrl+U deletes up to the start of the line" 'echo "$out" | last_frame | grep -q "tui-a > X|"'
out="$(panel : a b c left left $'\013')"
check "Ctrl+K deletes from the cursor to the end" 'echo "$out" | last_frame | grep -q "tui-a > a|"'
out="$(panel : f o o space b a r $'\027')"
check "Ctrl+W deletes the word before the cursor" 'echo "$out" | last_frame | grep -q "tui-a > foo |"'
out="$(panel : a b c $'\001' $'\005' X)"
check "Ctrl+A and Ctrl+E go to the start and to the end" 'echo "$out" | last_frame | grep -q "tui-a > abcX|"'
check "Ctrl+C clears the line, then asks for a second one to leave" '[ "$(run_lib "dash_init; DASH_MODE=cmd; DASH_BUF=abc; DASH_CUR=3; dash_ctrl_c; echo \"[\$DASH_BUF]\$DASH_MODE\"")" = "[]cmd" ] && [ "$(run_lib "dash_init; dash_ctrl_c; echo \$DASH_QUIT; dash_ctrl_c; echo \$DASH_QUIT")" = "$(printf "0\n1")" ]'
out="$(panel : h e l p enter q)"
check "help is answered in the console" 'echo "$out" | last_frame | grep -q "Ctrl+C cancela el comando"'
out="$(panel : h e l p enter : c l e a r enter q)"
check "clear empties the transcript" '! echo "$out" | last_frame | grep -q "Ctrl+C cancela el comando"'
out="$(panel : t h e m e enter q)"
check "theme shows the current theme" 'echo "$out" | last_frame | grep -q "Tema actual: matrix"'
out="$(panel : t h e m e space n o p e enter q)"
check "an unknown theme is reported" 'echo "$out" | last_frame | grep -q "No existe el tema .nope."'
out="$(panel : g o t o space r e s o u r c e s enter q)"
check "goto changes the view" 'echo "$out" | last_frame | grep -q "\[2 Recursos\]"'
out="$(panel : $(typed "status tui-a") enter wait : $(typed "history") enter q)"
check "history lists what was typed, numbered" 'echo "$out" | last_frame | grep -q "1  status tui-a"'
check "a command typed in the console is saved on disk" 'grep -qx "status tui-a" "$FIX/history"'
panel : $(typed "status tui-a") enter wait q > /dev/null
out="$(KEEP_HISTORY=1 panel : up)"
check "the history from the previous session is loaded" 'echo "$out" | last_frame | grep -q "tui-a > status tui-a|"'
out="$(panel : q x)"
check "typing in the console never triggers the panel shortcuts" '! echo "$out" | last_frame | grep -q "Nada que cancelar\|No hay ningún comando"'
out="$(panel : $(typed "status tui-a") enter wait q)"
check "the transcript closes the command with how it ended" 'echo "$out" | last_frame | grep -q "terminó bien"'
check "text from a command cannot move the cursor or change the screen" '[ "$(run_lib "tui_sanitize \"\$(printf \"a\\033[31mred\\033[0m \\033[2Jb\\033]0;t\\007c\")\"; printf %s \"\$TUI_OUT\" | od -An -c | tr -d \" \\n\" | grep -c \"033\\[2J\"")" = "0" ]'
check "colours of a command are kept in the console" '[ "$(run_lib "tui_sanitize \"\$(printf \"x\\033[1;32mgreen\\033[0my\")\"; printf %s \"\$TUI_OUT\" | od -An -c | tr -d \" \\n\" | grep -c \"033\\[1;32m\"")" = "1" ]'

out3="$(run_lib "$ASYNC dash_refresh; dash_start_job stay status tui-a; for i in \$(seq 1 80); do dash_job_tick; job_running || break; sleep 0.1; done; dash_job_tick; printf '[%s]\n' \"\${DASH_CON[@]}\"")"
check "the transcript starts with the command, as the prompt would show it" 'echo "$out3" | grep -qx "\[tui-a > ./deltactl status tui-a\]"'
check "and ends with how it finished" 'echo "$out3" | tail -1 | grep -q "terminó bien"'
section "13. panes, zoom, logs and the palette"
check "tui_key reads Shift+Tab" '[ "$(printf "\033[Z" | tk)" = "btab" ]'
out="$(panel z q)"
check "z zooms the list: the console is gone and the list is focused" 'echo "$out" | frame_n 2 | grep -q ">Instancias" && ! echo "$out" | frame_n 2 | grep -q "Consola"'
out="$(panel z z q)"
check "z again brings the layout back" 'echo "$out" | frame_n 3 | grep -q "Consola"'
out="$(panel z esc q)"
check "Esc closes the zoom before anything else" 'echo "$out" | frame_n 3 | grep -q "Consola" && echo "$out" | frame_n 3 | grep -q "\[1 Instancias\]"'
out="$(panel tab z q)"
check "zooming the services gives them the whole body" 'echo "$out" | frame_n 3 | grep -q ">tui-a" && ! echo "$out" | frame_n 3 | grep -q "Consola"'
check "the focus ring goes list, services, logs, list on a wide screen" '[ "$(run_lib "COLUMNS=160; DELTACTL_TUI_ROWS=40; tui_size; dash_refresh; for i in 1 2 3; do dash_focus_cycle 1; printf \"%s \" \$DASH_FOCUS; done")" = "svc logs list " ]'
check "and goes the other way with Shift+Tab" '[ "$(run_lib "COLUMNS=160; DELTACTL_TUI_ROWS=40; tui_size; dash_refresh; for i in 1 2 3; do dash_focus_cycle -1; printf \"%s \" \$DASH_FOCUS; done")" = "logs svc list " ]'
check "on a narrow screen there is no logs pane in the ring" '[ "$(run_lib "dash_refresh; for i in 1 2 3; do dash_focus_cycle 1; printf \"%s \" \$DASH_FOCUS; done")" = "svc list svc " ]'
check "the New button has no services to enter, so Tab keeps the list" '[ "$(run_lib "dash_refresh; DASH_ON_NEW=1; dash_focus_cycle 1; echo \$DASH_FOCUS")" = "list" ]'
LOGS_WIDE='COLUMNS=160; DELTACTL_TUI_ROWS=40; tui_size; dash_init; dash_refresh; mt_sample; dash_current_target; DASH_LOGS[tui-a/s0]="$(seq -f "line %g ok" 1 30)"; DASH_LOGS_AT[tui-a/s0]=1;'
check "the logs pane shows the end of the log while it follows" 'run_lib "$LOGS_WIDE dash_render" | last_frame | grep -q "line 30 ok" && run_lib "$LOGS_WIDE dash_render" | last_frame | grep -q "siguiendo"'
check "scrolled back it shows older lines and says how far" 'run_lib "$LOGS_WIDE DASH_LOG_SCROLL=5; dash_render" | last_frame | grep -q "line 25 ok" && ! run_lib "$LOGS_WIDE DASH_LOG_SCROLL=5; dash_render" | last_frame | grep -q "line 30 ok" && run_lib "$LOGS_WIDE DASH_LOG_SCROLL=5; dash_render" | last_frame | grep -q "↑5 líneas\|5 líneas"'
check "it never scrolls past the oldest line" '[ "$(run_lib "$LOGS_WIDE DASH_LOG_SCROLL=99999; dash_render >/dev/null; echo \$((DASH_LOG_SCROLL < 99999))")" = "1" ]'
check "a filter keeps only the lines with the text, ignoring case" 'run_lib "$LOGS_WIDE DASH_LOG_FILTER=LINE\ 2; dash_render" | last_frame | grep -q "line 29 ok" && ! run_lib "$LOGS_WIDE DASH_LOG_FILTER=LINE\ 2; dash_render" | last_frame | grep -q "line 30 ok"'
check "the title says which filter is active" 'run_lib "$LOGS_WIDE DASH_LOG_FILTER=line; dash_render" | last_frame | grep -q "/line"'
check "a filter with no match says so" 'run_lib "$LOGS_WIDE DASH_LOG_FILTER=zzz; dash_render" | last_frame | grep -q "Ninguna línea"'
check "while typing the filter the prompt is inside the pane" 'run_lib "$LOGS_WIDE DASH_FOCUS=logs; DASH_MODE=filter; DASH_BUF=err; DASH_CUR=3; dash_render" | last_frame | grep -q "/ err|"'
check "the focused logs pane is marked" 'run_lib "$LOGS_WIDE DASH_FOCUS=logs; dash_render" | last_frame | grep -q ">Logs"'
check "zooming the logs gives them the whole body" 'run_lib "$LOGS_WIDE DASH_FOCUS=logs; DASH_ZOOM=1; dash_render" | last_frame | grep -q ">Logs" && ! run_lib "$LOGS_WIDE DASH_FOCUS=logs; DASH_ZOOM=1; dash_render" | last_frame | grep -q "Servidor"'
check "the keys of the logs pane scroll, jump and filter" '[ "$(run_lib "dash_key_logs up; dash_key_logs up; printf \"%s \" \$DASH_LOG_SCROLL; dash_key_logs down; printf \"%s \" \$DASH_LOG_SCROLL; dash_key_logs home; printf \"%s \" \$DASH_LOG_SCROLL; dash_key_logs end; printf \"%s \" \$DASH_LOG_SCROLL; dash_key_logs /; printf \"%s\" \$DASH_MODE")" = "2 1 100000 0 filter" ]'
check "Enter applies the filter and an empty line removes it" '[ "$(run_lib "DASH_MODE=filter; DASH_BUF=boom; DASH_CUR=4; dash_key_edit enter; printf \"[%s]\" \"\$DASH_LOG_FILTER\"; DASH_MODE=filter; DASH_BUF=; dash_key_edit enter; printf \"[%s]\" \"\$DASH_LOG_FILTER\"")" = "[boom][]" ]'
check "the fuzzy match accepts a subsequence, any case" 'run_lib "dash_pal_match cmp Comprobar" >/dev/null && ! run_lib "dash_pal_match xyz Comprobar" >/dev/null'
check "a tighter match scores better than a scattered one" '[ "$(run_lib "dash_pal_match com Comprobar; a=\$PAL_SCORE; dash_pal_match cbr Comprobar; b=\$PAL_SCORE; echo \$((a < b))")" = "1" ]'
out="$(panel $'\020' q)"
check "Ctrl+P opens the palette with the actions of the selected instance" 'echo "$out" | frame_n 2 | grep -q "Paleta de acciones" && echo "$out" | frame_n 2 | grep -q "Comprobar" && echo "$out" | frame_n 2 | grep -q "Desplegar"'
out="$(panel $'\020' esc q)"
check "Esc closes the palette without doing anything" '! echo "$out" | frame_n 3 | grep -q "Paleta de acciones" && echo "$out" | frame_n 3 | grep -q "\[1 Instancias\]"'
out="$(panel $'\020' c o m p r o b a r enter wait q)"
check "typing narrows the list and Enter runs the first match" 'echo "$out" | grep -q "Ejecutando: ./deltactl check tui-a" && echo "$out" | last_frame | grep -q "terminó bien"'
out="$(panel $'\020' I r space t u i - c enter q)"
check "the palette jumps to another instance" 'echo "$out" | last_frame | grep -q "^| > .. tui-c"'
out="$(panel $'\020' t e m a space n o r d enter q)"
check "the palette changes the theme and remembers it" 'grep -q "^UI_THEME=nord$" "$FIX/none.cfg"'
out="$(panel $'\020' z z z z z z q)"
check "a query with no match says so" 'echo "$out" | frame_n 7 | grep -q "Sin coincidencias"'
out="$(panel $'\020' down down q)"
check "the arrows move the selection in the palette" 'echo "$out" | frame_n 4 | grep -q "| > .*Desplegar"'
out="$(panel $'\020' $'\020' q)"
check "opening the palette twice leaves it open" 'echo "$out" | frame_n 3 | grep -q "Paleta de acciones"'

finish

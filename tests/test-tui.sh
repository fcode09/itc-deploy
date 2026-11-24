#!/usr/bin/env bash
# Tests of the interactive panel (lib/cmd/dashboard*.sh, lib/screens/*.sh) and its terminal layer (lib/ui/tui.sh).
# The panel runs in test mode: DELTACTL_TUI_KEYS points to a file with one key name per line and every frame is
# printed as plain text, so no real terminal is needed. Docker is simulated, and so are /proc and the cgroup files
# (DELTACTL_PROC_ROOT / DELTACTL_CGROUP_ROOT). Runs from the root of the isolated copy (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS DELTACTL_TUI_KEYS DELTACTL_TUI_EVENTS DELTACTL_TUI_ROWS
unset DELTACTL_THEME DELTACTL_REFRESH DELTACTL_METRICS_INTERVAL   # the Options screen reads them: a value from the shell would change what it shows
unset DELTACTL_TUI_IDLE_AFTER                                     # (and this one changes how often an idle panel samples)

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
  logs)
    if [ -f "$FIX/logs_partial" ]; then printf 'par'; sleep 0.4; echo 'tial'
    elif [ -f "$FIX/logs_many" ]; then seq -f 'n%g' 1 3000
    else echo "linea normal"; echo "ERROR de prueba"; fi
    case "$*" in *" -f "*) [ ! -f "$FIX/logs_block" ] || exec sleep 30 ;; esac ;;
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

# Runs the panel with the keys given as arguments (one per line) and optional stdin. ASCII, no colors, 100 x 30 (PANEL_COLS and
# PANEL_ROWS change the size).
KEYS="$FIX/keys.txt"
panel() { # key...  (stdin: answers to the confirmation prompts)
  # The history is saved on disk: every run starts without it, unless KEEP_HISTORY is set.
  [ -n "${KEEP_HISTORY:-}" ] || rm -f "$(dirname "${DELTACTL_CONFIG:-$FIX/none.cfg}")/history"
  printf '%s\n' "$@" > "$KEYS"
  DELTACTL_TUI_KEYS="$KEYS" DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_ASCII=1 COLUMNS="${PANEL_COLS:-100}" DELTACTL_TUI_ROWS="${PANEL_ROWS:-30}" bash ./deltactl 2>&1
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
check "the tab line shows the views with the first one active (at 100 columns, with nine views, the others show only their number)" 'echo "$out" | grep -q "\[1 Instancias\]  2   3   4   5   6   7   8   9"'
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
out="$(panel up enter esc q < /dev/null)"
check "Enter on the New button opens the form inside the panel" 'echo "$out" | frame_n 3 | grep -q ">Nombre de la instancia" && ! echo "$out" | grep -q "Pasando al terminal"'
out="$(panel 2 q)"
check "2 opens the resources view" 'echo "$out" | frame_n 2 | grep -q "\[2 Recursos\]"'
out="$(panel 2 tab q)"
check "Tab goes to the next view (outside the instances view)" 'echo "$out" | frame_n 3 | grep -q "\[3 Salida\]"'
out="$(panel 2 tab tab q)"
check "Tab goes on to the Runs view" 'echo "$out" | frame_n 4 | grep -q "\[4 Ejecuciones\]"'
out="$(panel 2 tab tab tab tab tab tab tab tab q)"
check "Tab wraps around the views" 'echo "$out" | frame_n 6 | grep -q "\[6 Consola\]" && echo "$out" | frame_n 7 | grep -q "\[7 Servidor\]" && echo "$out" | frame_n 8 | grep -q "\[8 Imágenes\]" && echo "$out" | frame_n 9 | grep -q "\[9 Variables\]" && echo "$out" | frame_n 10 | grep -q "\[1 Instancias\]"'
out="$(panel tab q)"
check "on the instances view Tab moves the focus to the services" 'echo "$out" | frame_n 2 | grep -q ">tui-a" && echo "$out" | frame_n 2 | grep -q "\[1 Instancias\]"'
out="$(panel tab tab q)"
check "and on to the list again (the logs pane exists only on the wide layout)" 'echo "$out" | frame_n 3 | grep -q ">Instancias"'
out="$(panel btab q)"
check "Shift+Tab goes the other way round" 'echo "$out" | frame_n 2 | grep -q ">tui-a"'

section "3b. the new-instance form (inside the panel)"
out="$(panel n)"
check "n opens the form: the sections on the left, the fields of the first one on the right" 'echo "$out" | last_frame | grep -q "Nueva instancia" && echo "$out" | last_frame | grep -q ">Nombre de la instancia"'
check "the list shows the six sections, each with an icon at the start of its row" 'for s in "1 Nombre" "2 Servicios" "3 Datos" "4 Imágenes" "5 Acceso" "6 Resumen"; do echo "$out" | last_frame | grep -q "| [*!x.] $s" || exit 1; done'
check "a name is proposed (the first instancia-N that is free)" 'echo "$out" | last_frame | grep -q "1 Nombre    instancia-1" && echo "$out" | last_frame | grep -q "Valor propuesto"'
check "the mark of the field is at the start of the line, not after the text" 'echo "$out" | last_frame | grep -q "|  > instancia-1 " && ! echo "$out" | last_frame | grep -q "instancia-1>"'
check "the list says how many sections are ready" 'echo "$out" | last_frame | grep -q "4 de 6 secciones listas"'
check "the last line gives the keys of the form" 'echo "$out" | last_frame | grep -q "Enter siguiente . Up/Dn campo . PgUp/PgDn sección . Tab lista . Esc lista"'
out="$(DELTACTL_TUI_SHOW_CURSOR=1 panel n)"
check "the real cursor is on the text field, at the end of the text" '[ "$(echo "$out" | grep "=== cursor" | tail -1)" = "=== cursor 12;52 ===" ] && echo "$out" | last_frame | sed -n 13p | grep -q "> instancia-1"'
out="$(DELTACTL_TUI_SHOW_CURSOR=1 panel n x y)"
check "...and it follows the typing" '[ "$(echo "$out" | grep "=== cursor" | tail -1)" = "=== cursor 12;43 ===" ]'
check "the first key typed replaces the proposed name" 'echo "$out" | last_frame | grep -q "1 Nombre    xy" && ! echo "$out" | last_frame | grep -q "instancia-1"'
out="$(panel n left x)"
check "moving inside the proposed name keeps it and adds to it" 'echo "$out" | last_frame | grep -q "instancia-x1"'
out="$(panel n B)"
check "an invalid name is marked in the list and explained under the field" 'echo "$out" | last_frame | grep -q "| x 1 Nombre    B" && echo "$out" | last_frame | grep -q "No es válido"'
out="$(panel n $(typed tui-a))"
check "a name that already exists is marked too" 'echo "$out" | last_frame | grep -q "Ya existe una instancia con ese nombre" && echo "$out" | last_frame | grep -q "| x 1 Nombre    tui-a"'
out="$(panel n $(typed tui-a) enter)"
check "Enter on a wrong name stays on it" 'echo "$out" | last_frame | grep -q ">Nombre de la instancia" && echo "$out" | last_frame | grep -q "Ya existe"'
out="$(panel n backspace)"
check "an empty name is a pending section" 'echo "$out" | last_frame | grep -q "Escribe un nombre" && echo "$out" | last_frame | grep -q "| . 1 Nombre    -"'
out="$(panel n enter)"
check "Enter accepts the proposed name and goes on to the services" 'echo "$out" | last_frame | grep -q ">Servicios a desplegar" && echo "$out" | last_frame | grep -q "\[x\] s0  Auth" && echo "$out" | last_frame | grep -q "\[x\] s1  Gue"'
check "the services show their image, port and memory" 'echo "$out" | last_frame | grep -q "s0  Auth  auth-backend" && echo "$out" | last_frame | grep -q ":41[0-9]0" && echo "$out" | last_frame | grep -q "512m" && echo "$out" | last_frame | grep -q "2g"'
check "the services say what they lack to be deployed" 'echo "$out" | last_frame | grep -q "ESTADO PARA DESPLEGAR" && echo "$out" | last_frame | grep -q "puerto 41[0-9]0 libre" && echo "$out" | last_frame | grep -q "puerto 41[0-9]1 libre"'
check "the services not yet in Docker are listed, switched off" 'echo "$out" | last_frame | grep -q "walle . robin . link: aún sin Docker"'
out="$(panel n enter space)"
check "Space unchecks a service: the list and its state follow" 'echo "$out" | last_frame | grep -q "\[ \] s0  Auth" && echo "$out" | last_frame | grep -q "2 Servicios s1" && echo "$out" | last_frame | grep -q "s0  no se despliega"'
out="$(panel n enter space down space)"
check "with no service the section is marked and says so" 'echo "$out" | last_frame | grep -q "Marca al menos un servicio" && echo "$out" | last_frame | grep -q "| x 2 Servicios ninguno"'
out="$(panel n enter space pgdn pgdn)"
check "the images are asked only for the services that stay" 'echo "$out" | last_frame | grep -q ">Imagen y versión" && echo "$out" | last_frame | grep -q "s1  Gue" && echo "$out" | last_frame | grep -q "gueo-back-end" && ! echo "$out" | last_frame | grep -q "auth-backend"'
out="$(panel n pgdn pgdn pgdn)"
check "PgDn changes section; the default image name is proposed" 'echo "$out" | last_frame | grep -q "Imagen   *auth-backend" && echo "$out" | last_frame | grep -q "Versión"'
check "the section with no version is a warning" 'echo "$out" | last_frame | grep -q "| ! 4 Imágenes  sin versión"'
out="$(panel n pgdn pgdn)"
check "the data section is a choice between new and existing" 'echo "$out" | last_frame | grep -q "(o) Nueva" && echo "$out" | last_frame | grep -q "( ) Ya tiene datos" && echo "$out" | last_frame | grep -q "Se sembrará con ./deltactl init"'
out="$(panel n pgdn pgdn down space)"
check "choosing existing data is reflected in the list" 'echo "$out" | last_frame | grep -q "(o) Ya tiene datos" && echo "$out" | last_frame | grep -q "3 Datos     existente"'
out="$(panel n pgdn pgdn down space pgdn pgdn)"
check "an existing municipality keeps its own secrets: nothing to generate" 'echo "$out" | last_frame | grep -q "Con datos existentes se usan sus mismos secretos"'
out="$(panel n pgdn pgdn pgdn pgdn)"
check "the access section asks for the public URL" 'echo "$out" | last_frame | grep -q ">URL y secretos" && echo "$out" | last_frame | grep -q "URL pública" && echo "$out" | last_frame | grep -q "| ! 5 Acceso    sin URL"'
if command -v openssl > /dev/null 2>&1; then
  check "...and whether to generate the unique secrets" 'echo "$out" | last_frame | grep -q "\[x\] Generar secretos únicos"'
fi
out="$(panel n pgdn pgdn pgdn pgdn pgdn)"
check "the summary shows the answers and what is ready" 'echo "$out" | last_frame | grep -q ">Resumen y creación" && echo "$out" | last_frame | grep -q "instancia   instancia-1" && echo "$out" | last_frame | grep -q "Todo listo para crear" && echo "$out" | last_frame | grep -q "\[ Crear instancia \]"'
out="$(panel n B pgdn pgdn pgdn pgdn pgdn enter)"
check "creating with the name wrong goes back to it and says what is missing" 'echo "$out" | last_frame | grep -q ">Nombre de la instancia" && echo "$out" | last_frame | grep -q "Falta completar: Nombre" && [ ! -e instances/b ]'
out="$(panel n tab)"
check "Tab gives the keyboard to the list of sections" 'echo "$out" | last_frame | grep -q ">Nueva instancia" && echo "$out" | last_frame | grep -q "Enter editar . c crear . Tab campos . Esc cancela"'
out="$(panel n tab down)"
check "in the list Up and Down choose the section and the fields follow" 'echo "$out" | last_frame | grep -q "Servicios a desplegar"'
out="$(panel n tab down enter space)"
check "Enter takes the keyboard back to the fields" 'echo "$out" | last_frame | grep -q "\[ \] s0  Auth"'
out="$(panel n esc)"
check "Esc from the fields goes to the list" 'echo "$out" | last_frame | grep -q "c crear"'
out="$(panel n esc esc)"
check "Esc from the list cancels: back on the instances and nothing is created" 'echo "$out" | last_frame | grep -q ">Instancias" && echo "$out" | grep -q "Cancelado" && [ ! -e instances/instancia-1 ]'
out="$(panel n x esc esc n)"
check "the form starts afresh each time" 'echo "$out" | last_frame | grep -q "1 Nombre    instancia-1"'
out="$(PANEL_COLS=80 panel n)"
check "on a narrow terminal only the fields are drawn, with the section in the title" 'echo "$out" | last_frame | grep -q "Nueva instancia . 1/6 Nombre de la instancia" && ! echo "$out" | last_frame | grep -q "2 Servicios"'
out="$(PANEL_COLS=80 panel n tab)"
check "...and Tab changes section" 'echo "$out" | last_frame | grep -q "2/6 Servicios a desplegar"'
out="$(PANEL_COLS=80 panel n esc)"
check "...and Esc cancels" 'echo "$out" | last_frame | grep -q ">Instancias"'
out="$(panel '!' $(typed new) space $(typed --wizard) enter q < /dev/null)"
check "with a leading ! the wizard still runs in the terminal" 'echo "$out" | grep -q "Pasando al terminal: ./deltactl new --wizard"'
out="$(panel : n e w enter)"
check "typing new in the command line opens the form too" 'echo "$out" | last_frame | grep -q "Nueva instancia" && echo "$out" | last_frame | grep -q ">Nombre de la instancia"'

# The whole form: it creates the instance with the answers (and openssl, when there is one, generates the secrets).
if command -v openssl > /dev/null 2>&1; then GEN=(down); else GEN=(); fi
out="$(panel n $(typed tui-wz) enter pgdn pgdn down $(typed 1.5) enter enter $(typed 2.5) enter $(typed http://h) enter "${GEN[@]}" enter wait)"
check "creating runs the command of the panel with the answers as options" '[ -f instances/tui-wz/.env.instance ] && echo "$out" | grep -q "./deltactl new tui-wz --services s0,s1 --s0-image auth-backend --s0-tag 1.5"'
check "the answers are applied" 'grep -qx "S0_TAG=1.5" instances/tui-wz/.env.instance && grep -qx "S1_TAG=2.5" instances/tui-wz/.env.instance && grep -qx "IP_SERVER=http://h" instances/tui-wz/.env.s0'
if command -v openssl > /dev/null 2>&1; then
  check "and the secrets are generated" '[ "$(grep -E "^JWT_SECRET=" instances/tui-wz/.env.s0 | cut -d= -f2- | wc -c)" -eq 65 ]'
fi
check "the new instance shows in the list when the command ends" 'echo "$out" | last_frame | grep -q "tui-wz"'
rm -rf instances/tui-wz
out="$(panel n $(typed tui-ls) tab c wait)"
check "c in the list creates too" '[ -f instances/tui-ls/.env.instance ]'
rm -rf instances/tui-ls

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
cat > "$FIX/ended.sh" <<'EOF'
source lib/bootstrap.sh; source lib/cmd/dashboard.sh
tui_size; dash_init
job_start t true
for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$JOB_PID" 2> /dev/null || break; sleep 0.1; done
dash_start_job stay version; r=$?
job_running && s=started || s=refused
c=0; for l in "${DASH_CON[@]}"; do case "$l" in *"deltactl t: "*) c=1 ;; esac; done
echo "$r $s $c"
job_cancel > /dev/null 2>&1
EOF
ENDED="$(ROOT="$PWD" DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_ASCII=1 COLUMNS=100 bash "$FIX/ended.sh" 2>&1)"
check "a command that has just ended does not refuse the next one, and its end is still announced" '[ "$ENDED" = "0 started 1" ] || { echo "$ENDED" | tail -5; false; }'
# (a fast first command may be over before the second Enter; the second can then end before a frame shows it running)
cat > "$FIX/refused.sh" <<'EOF'
source lib/bootstrap.sh; source lib/cmd/dashboard.sh
tui_size; dash_init
job_start t sleep 3
dash_start_job stay version; r=$?
c=0; for l in "${DASH_CON[@]}"; do case "$l" in *"Hay un comando en ejecución"*"(version)"*) c=1 ;; esac; done
echo "$r $c"
job_cancel > /dev/null 2>&1
EOF
REFUSED="$(ROOT="$PWD" DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_ASCII=1 COLUMNS=100 bash "$FIX/refused.sh" 2>&1)"
check "a refused command is noted in the console too, where a finishing command cannot hide it" '[ "$REFUSED" = "1 1" ] || { echo "$REFUSED" | tail -5; false; }'
check "a second command while one runs is refused or runs after it, never both" 'echo "$out" | grep -q "Hay un comando en ejecución\|Ejecutando: ./deltactl status tui-b\|status tui-b:\? terminó"'
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
out="$(PANEL_ROWS=55 panel '?' x q)"
check "? shows the keys over the whole body" 'echo "$out" | frame_n 2 | grep -q "Teclas" && echo "$out" | frame_n 2 | grep -q "q o Esc salir" && echo "$out" | frame_n 2 | grep -q "Pulsa cualquier tecla para volver"'
check "any key closes the help" 'echo "$out" | frame_n 3 | grep -q "\[1 Instancias\]" && ! echo "$out" | frame_n 3 | grep -q "Pulsa cualquier tecla"'
export DELTACTL_CONFIG="$FIX/config"
out="$(panel L q)"
check "L switches to English in the next frame" 'echo "$out" | frame_n 2 | grep -q "\[1 Instances\] 2 Resources 3 Output 4 Runs 5 Processes 6 Console 7 Server 8 Images 9 Variables" && echo "$out" | frame_n 2 | grep -q "Language: English"'
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
check "a narrow screen still draws every view without overflow" 'for c in 40 60 80; do for v in instances resources output runs; do run_lib "COLUMNS=$c; tui_size; $CPU_SCRIPT; DASH_VIEW=$v; dash_render" | while IFS= read -r l; do [ "${#l}" -le "$c" ] || echo "WIDE:$c:$v"; done; done; done | grep -q WIDE && exit 1; exit 0'
check "a small screen still draws every view" 'for r in 14 20; do for v in instances resources output runs; do run_lib "DELTACTL_TUI_ROWS=$r; tui_size; $CPU_SCRIPT; DASH_VIEW=$v; dash_render" | last_frame | grep -q "q salir" || exit 1; done; done'
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
check "below 120 columns the compact view is kept" 'run_lib "COLUMNS=119; tui_size; $CPU_SCRIPT; dash_render" | last_frame | grep -q "Instancias" && ! run_lib "COLUMNS=119; tui_size; $CPU_SCRIPT; dash_render" | last_frame | grep -q -- "- Servidor "'
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
# What the console does with a line: it runs as a job or in the terminal (stubs that only say which), and whether it is kept.
con_submit() { # line
  LINE="$1" run_lib 'dash_terminal() { echo "TERMINAL:$*"; }; dash_start_job() { echo "JOB:$*"; }; DASH_BUF="$LINE"; dash_submit_cmd; echo "N=${#DASH_HIST[@]}"'
}
rm -f "$FIX/history"
check "a line that writes an environment value (env … set) runs in the terminal, never as a job, and is not kept in the history" '
  out="$(con_submit "env tui-a set s0:GOOGLE_KEY sekretoQ9")"
  echo "$out" | grep -q "^TERMINAL:env tui-a set s0:GOOGLE_KEY sekretoQ9$" && ! echo "$out" | grep -q "^JOB:" && echo "$out" | grep -qx "N=0" \
  && ! grep -qs sekretoQ9 "$FIX/history"'
check "the same with ./deltactl, with a leading ! and for generate" '
  for l in "./deltactl env tui-a set s0:X sekretoQ9" "!env tui-a set s0:X sekretoQ9" "env tui-a generate s0:JWT_SECRET"; do
    out="$(con_submit "$l")"; echo "$out" | grep -q "^TERMINAL:" && echo "$out" | grep -qx "N=0" || exit 1
  done; ! grep -qs "sekretoQ9\|generate" "$FIX/history"'
check "an alias that expands to env … set is not kept either" '
  mkdir -p "$FIX/al2"; printf "es=env tui-a set\n" > "$FIX/al2/aliases"
  out="$(LINE="es s0:X sekretoQ9" DELTACTL_CONFIG="$FIX/al2/c.cfg" run_lib "dash_terminal() { echo TERMINAL:\$*; }; dash_start_job() { echo JOB:\$*; }; dash_alias_load; DASH_BUF=\"\$LINE\"; dash_submit_cmd; echo N=\${#DASH_HIST[@]}")"
  echo "$out" | grep -q "^TERMINAL:env tui-a set s0:X sekretoQ9$" && echo "$out" | grep -qx "N=0" && ! grep -qs sekretoQ9 "$FIX/al2/history"'
check "env list and the other commands are still jobs and are kept" '
  out="$(con_submit "env tui-a list")"; echo "$out" | grep -q "^JOB:.*env tui-a list" && echo "$out" | grep -qx "N=1" && grep -qx "env tui-a list" "$FIX/history"'
rm -f "$FIX/history"
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
check "z zooms the list: the console is gone and the list is focused" 'echo "$out" | frame_n 2 | grep -q ">Instancias" && ! echo "$out" | frame_n 2 | grep -qE -- "\+- >?Consola"'
out="$(panel z z q)"
check "z again brings the layout back" 'echo "$out" | frame_n 3 | grep -q "Consola"'
out="$(panel z esc q)"
check "Esc closes the zoom before anything else" 'echo "$out" | frame_n 3 | grep -q "Consola" && echo "$out" | frame_n 3 | grep -q "\[1 Instancias\]"'
out="$(panel tab z q)"
check "zooming the services gives them the whole body" 'echo "$out" | frame_n 3 | grep -q ">tui-a" && ! echo "$out" | frame_n 3 | grep -qE -- "\+- >?Consola"'
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
check "zooming the logs gives them the whole body" 'run_lib "$LOGS_WIDE DASH_FOCUS=logs; DASH_ZOOM=1; dash_render" | last_frame | grep -q ">Logs" && ! run_lib "$LOGS_WIDE DASH_FOCUS=logs; DASH_ZOOM=1; dash_render" | last_frame | grep -q -- "- Servidor "'
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

section "14. the Runs view"
RUNS=instances/.deltactl
SLEEPER=""
ESC="$(printf '\033')"
trap 'rm -rf "$FIX" instances/tui-* instances/.deltactl; [ -z "$SLEEPER" ] || kill "$SLEEPER" 2>/dev/null' EXIT
rm -rf "$RUNS"
out="$(panel 4 q)"
check "4 opens the Runs view and the tab line shows it" 'echo "$out" | frame_n 2 | grep -q "\[4 Ejecuciones\]"'
check "with no history it says what gets recorded" 'echo "$out" | frame_n 2 | grep -q "Aún no hay ejecuciones" && echo "$out" | frame_n 2 | grep -q "quedan aquí"'
# mkrun <id> <command> <instance> <state> <rc> <duration ms> [cpu ms] [docker ms] [peak kb]
mkrun() {
  local d="$RUNS/runs/$1" ts="${1:0:4}-${1:4:2}-${1:6:2}T${1:9:2}:${1:11:2}:${1:13:2}Z"
  mkdir -p "$d" "$RUNS/active"
  {
    printf 'RUN_ID=%s\nOP=%s\nARGS=%s\nINSTANCE=%s\nSTATE=%s\nSTARTED_AT=%s\nENDED_AT=%s\nDURATION_MS=%s\nRC=%s\nHOST=h\nUSER=u\n' "$1" "$2" "$3" "$3" "$4" "$ts" "$ts" "$6" "$5"
    if [ -n "${7:-}" ]; then
      printf 'CPU_MS=%s\nDOCKER_CALLS=14\nDOCKER_MS=%s\nDOCKER_SLOW=900|compose up\nPEAK_RSS_KB=%s\nPEAK_PROCS=6\nOUT_LINES=4\nOUT_BYTES=2048\n' "$7" "$8" "$9"
      printf 'FOOT_BEFORE=1/2 52428800 0\nFOOT_AFTER=2/2 104857600 1\n'
    fi
  } > "$d/meta"
  printf 'pulling image\n\033[2Jclear attempt\nERROR boom\ndone\n' > "$d/out.log"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$ts" "$2" "$3" "$4" "$5" "$6" >> "$RUNS/runs.idx"
}
mkrun 20261101T080000Z-11 deploy tui-a succeeded 0 15000 2500 4000 51200
mkrun 20261101T090000Z-12 deploy tui-a succeeded 0 10000 2200 3500 40960
mkrun 20261101T100000Z-13 rollback tui-b failed 1 3000 500 800 20480
mkrun 20261102T100000Z-14 deploy tui-a succeeded 0 12300 2000 3000 40960
mkrun 20261102T110000Z-15 stop tui-a succeeded 0 900
out="$(panel 4 q)"
f="$(echo "$out" | frame_n 2)"
check "the list has one row per run, the newest first" '[ "$(echo "$f" | grep -c "deploy\|rollback\|stop")" -ge 5 ] && [ "$(echo "$f" | grep -n "stop" | head -1 | cut -d: -f1)" -lt "$(echo "$f" | grep -n "rollback" | head -1 | cut -d: -f1)" ]'
check "each row has the date, the command, the instance and the duration" 'echo "$f" | grep -q "11-02 10:00 *deploy *tui-a *12.3 s"'
check "the newest run is selected and its detail is on the right" 'echo "$f" | grep -q "> .* stop" && echo "$f" | grep -q "./deltactl stop tui-a"'
out="$(panel 4 down q)"
f="$(echo "$out" | frame_n 3)"
check "down selects the next run: state, code, start and who" 'echo "$f" | grep -q "./deltactl deploy tui-a" && echo "$f" | grep -q "correcta . código 0" && echo "$f" | grep -q "2026-11-02 10:00:00Z" && echo "$f" | grep -q "u@h"'
check "a label with an accent lines up with the others (padding is by characters, not bytes)" 'a="$(echo "$f" | grep "duración *12.3 s" | head -1)"; b="$(echo "$f" | grep "inicio (UTC) *2026-11-02" | head -1)"; a="${a%%12.3 s*}"; b="${b%%2026-11-02*}"; [ "${#a}" -eq "${#b}" ] && [ "${#a}" -gt 10 ]'
g="$(panel 4 down pgdn q | frame_n 4)"
check "it shows the consumption with the same wording as runs show" 'echo "$g" | grep -q "Consumo de la operación" && echo "$g" | grep -q "2.0 s (16% de un núcleo)" && echo "$g" | grep -q "14 llamadas . 3.0 s (24%)"'
check "the slowest docker call and the peak memory are there" 'echo "$g" | grep -q "más lenta .* 900 ms" && echo "$g" | grep -q "40.0 MB . 6 procesos"'
check "the containers before and after are shown" 'echo "$g" | grep -q "Contenedores de tui-a" && echo "$g" | grep -q "1/2 . 50.0 MB . reinicios 0" && echo "$g" | grep -q "2/2 . 100.0 MB . reinicios 1"'
check "it compares with the previous run and with the average of the earlier ones" 'echo "$f" | grep -q "Frente a las anteriores (deploy de tui-a)" && echo "$f" | grep -q "vs ant\." && echo "$f" | grep -q "vs media 2"'
check "the change is a plain percentage (+23% against 10.0 s)" 'echo "$f" | grep "duración" | grep -q "+23%"'
out="$(panel 4 down pgdn q)"
check "scrolling the detail reaches the end of its output, and text cannot move the cursor" 'echo "$out" | frame_n 4 | grep -q "clear attempt" && echo "$out" | frame_n 4 | grep -q "ERROR boom" && ! echo "$out" | frame_n 4 | grep -q "$ESC"'
out="$(panel 4 down down q)"
f="$(echo "$out" | frame_n 4)"
check "a failed run says so, with its code, and has no comparison" 'echo "$f" | grep -q "fallida . código 1" && ! echo "$f" | grep -q "Frente a las anteriores"'
out="$(panel 4 end q)"
f="$(echo "$out" | frame_n 3)"
check "End goes to the oldest run, which has nothing earlier to compare with" 'echo "$f" | grep -q "No hay ejecuciones anteriores correctas"'
check "Home and End move the selection to the ends" '[ "$(run_lib "DASH_VIEW=runs; dash_runs_load; dash_key_runs end; printf \"%s \" \$DASH_RUNS_SEL; dash_key_runs home; printf \"%s\" \$DASH_RUNS_SEL")" = "4 0" ]'
check "a run recorded before the measurements shows no consumption and no error" '[ "$(panel 4 q | frame_n 2 | grep -c "Consumo de la operación")" = "0" ]'
out="$(panel 4 t q)"
f="$(echo "$out" | frame_n 3)"
check "t shows what each operation costs, one row per command" 'echo "$f" | grep -q "Qué cuesta cada operación" && echo "$f" | grep -q "^| *deploy  *3  *3  *0" && echo "$f" | grep -q "^| *rollback  *1  *0  *1"'
check "the statistics header lines up with its figures (the accent in the title of a column does not shift it)" 'a="$(echo "$f" | grep "veces *ok *fallos *duración" | head -1)"; b="$(echo "$f" | grep "^| *deploy" | head -1)"; a="${a%%duración*}duración"; b="${b%%12.4 s*}12.4 s"; [ "${#a}" -eq "${#b}" ]'
check "the averages are right (deploy: 12.4 s)" 'echo "$f" | grep "^| *deploy" | grep -q "12.4 s"'
check "it explains what the figures include" 'echo "$f" | grep -q "procesos propios de la operación"'
check "the key bar of the statistics says how to come back" 'echo "$f" | tail -2 | grep -q "t o Esc vuelven"'
out="$(panel 4 t esc q)"
check "Esc leaves the statistics for the list (not for the first view)" 'echo "$out" | frame_n 4 | grep -q "\[4 Ejecuciones\]" && echo "$out" | frame_n 4 | grep -q "Ejecuciones (UTC)"'
out="$(panel 4 t esc esc q)"
check "and a second Esc goes back to the instances" 'echo "$out" | frame_n 5 | grep -q "\[1 Instancias\]"'
out="$(panel 4 down down t s q)"
f="$(echo "$out" | frame_n 6)"
check "s limits the statistics to the instance of the selected run" 'echo "$f" | grep -q "instancia tui-b" && echo "$f" | grep -q "rollback" && ! echo "$f" | grep -q "^| *deploy"'
out="$(panel 4 t s s q)"
check "and pressing it again brings every instance back" 'echo "$out" | frame_n 5 | grep -q "^| *deploy" && ! echo "$out" | frame_n 5 | grep "Qué cuesta" | grep -q "instancia"'
out="$(panel 3 tab q)"
check "Tab goes from Output to Runs" 'echo "$out" | frame_n 3 | grep -q "\[4 Ejecuciones\]"'
out="$(panel 4 tab tab tab tab tab tab q)"
check "and wraps from Runs to Instances" 'echo "$out" | frame_n 8 | grep -q "\[1 Instancias\]"'
out="$(panel 4 btab q)"
check "Shift+Tab goes from Runs back to Output" 'echo "$out" | frame_n 3 | grep -q "\[3 Salida\]"'
out="$(panel : $(typed "goto runs") enter q)"
check "the console can go to the view" 'echo "$out" | grep -q "\[4 Ejecuciones\]"'
out="$(panel 4 $'\020' q)"
check "the palette is available from the view" 'echo "$out" | frame_n 3 | grep -q "Paleta de acciones"'
check "the key bar of the view lists its keys" 'panel 4 q | frame_n 2 | tail -2 | grep -q "t estadísticas"'
check "the help overlay documents the view" 'panel 4 "?" q | frame_n 3 | grep -q "EJECUC\."'
check "in English the view is translated too" '[ "$(DELTACTL_LANG=en panel 4 down q | frame_n 3 | grep -c "Runs (UTC)\|Consumption of the operation\|\[4 Runs\]")" -ge 2 ]'
# A run in progress: its wrapper is alive, so it is listed first as "running".
( exec -a deltactl-test sleep 60 ) &
SLEEPER=$!
mkdir -p "$RUNS/runs/20261103T120000Z-16"
printf 'RUN_ID=20261103T120000Z-16\nOP=deploy\nARGS=tui-c\nINSTANCE=tui-c\nSTATE=running\nSTARTED_AT=2026-11-03T12:00:00Z\n' > "$RUNS/runs/20261103T120000Z-16/meta"
printf '%s\n' "$SLEEPER" > "$RUNS/active/20261103T120000Z-16"
out="$(panel 4 q)"
f="$(echo "$out" | frame_n 2)"
check "a run in progress is listed first and says so" 'echo "$f" | grep -q "en curso" && [ "$(echo "$f" | grep -n "en curso" | head -1 | cut -d: -f1)" -lt "$(echo "$f" | grep -n "stop " | head -1 | cut -d: -f1)" ]'
check "its detail shows the state without inventing figures" '! echo "$f" | grep -q "Consumo de la operación"'
kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null; rm -f "$RUNS/active/20261103T120000Z-16"
out="$(panel 4 q)"
check "once its process is gone it is no longer listed as running" '! echo "$out" | frame_n 2 | grep -q "en curso"'
# The data changes under the view: the selection stays on the same run.
printf '20261104T100000Z-17\t2026-11-04T10:00:00Z\tdeploy\ttui-a\tsucceeded\t0\t1000\n' > "$FIX/newidx.txt"
check "a new run at the top does not move the selection off the run being read" '[ "$(run_lib "DASH_VIEW=runs; dash_runs_load; dash_runs_select 2; id=\$DASH_RUNS_SEL_ID; cat $FIX/newidx.txt >> $RUNS/runs.idx; dash_runs_load; echo \"\$id \$DASH_RUNS_SEL_ID \$DASH_RUNS_SEL\"")" = "20261101T100000Z-13 20261101T100000Z-13 3" ]'
check "a stale selection falls back to a valid row" '[ "$(run_lib "DASH_VIEW=runs; dash_runs_load; DASH_RUNS_SEL=99; DASH_RUNS_SEL_ID=gone; dash_runs_load; echo \$DASH_RUNS_SEL")" = "5" ]'
check "the view does not read the disk again before 5 seconds" '[ "$(run_lib "DASH_VIEW=runs; dash_runs_tick; n=\$DASH_RUNS_AT; DASH_PAUSED=0; dash_runs_tick; echo \$((DASH_RUNS_AT == n))")" = "1" ]'
check "leaving the view makes it read again when it comes back" '[ "$(run_lib "DASH_VIEW=runs; dash_runs_tick; DASH_VIEW=instances; dash_runs_tick; echo \$DASH_RUNS_AT")" = "-1000" ]'
check "every size draws the view inside the screen, list and statistics" 'for c in 60 80 100 130 160 300; do for m in list stats; do run_lib "COLUMNS=$c; DELTACTL_TUI_ROWS=30; tui_size; dash_init; DASH_VIEW=runs; DASH_RUNS_MODE=$m; dash_runs_load; dash_render" | while IFS= read -r l; do [ "${#l}" -le "$c" ] || echo "WIDE:$c:$m"; done; done; done | grep -q WIDE && exit 1; exit 0'
printf '20261105T100000Z-18\t2026-11-05T10:00:00Z\tdeploy\t\033[2Jevil\tsucceeded\t0\t1000\n' >> "$RUNS/runs.idx"
check "a text with control characters in the history cannot reach the screen" '! run_lib "DASH_VIEW=runs; dash_runs_load; dash_render" | grep -q "$ESC"'
rm -rf "$RUNS"

section "15. the saved-output viewer"
rm -rf "$RUNS"
VID=20261110T100000Z-20
mkrun 20261109T100000Z-19 stop tui-a succeeded 0 900
mkrun "$VID" deploy tui-a succeeded 0 5000 1000 1000 1000
# 2002 lines: multibyte text (checkpoints are bytes, not characters), a progress bar that rewrites its line with \r, a cursor
# sequence, and a last line with no newline.
{ seq -f "línea ñ ✔ %g" 1 1999; printf 'progress 10%%\rprogress 100%%\n'; printf 'evil \033[2Jscreen\nlast line without newline'; } > "$RUNS/runs/$VID/out.log"
out="$(panel 4 enter q)"
f="$(echo "$out" | frame_n 3)"
check "Enter opens the output of the selected run on its last page" 'echo "$f" | grep -q "Salida de '"$VID"'" && echo "$f" | grep -q "líneas 1979-2002 de 2002" && echo "$f" | grep -q "last line without newline"'
check "every line has its number" 'echo "$f" | grep -q " 2002 last line without newline" && echo "$f" | grep -q " 1979 línea ñ ✔ 1979"'
check "a progress bar shows what the terminal would have shown, and a cursor sequence is harmless" 'echo "$f" | grep -q "progress 100%" && ! echo "$f" | grep -q "progress 10%progress" && echo "$f" | grep -q "evil screen" && ! echo "$f" | grep -q "$ESC"'
check "the key bar of the viewer says how to leave" 'echo "$f" | tail -2 | grep -q "Esc vuelve"'
out="$(panel 4 enter pgup q)"
check "PgUp goes back a page (one line of overlap)" 'echo "$out" | frame_n 4 | grep -q "líneas 1956-1979 de 2002" && echo "$out" | frame_n 4 | grep -q " 1956 línea ñ ✔ 1956"'
out="$(panel 4 enter home q)"
check "Home goes to the first line" 'echo "$out" | frame_n 4 | grep -q "líneas 1-24 de 2002" && echo "$out" | frame_n 4 | grep -q "   1 línea ñ ✔ 1"'
out="$(panel 4 enter home down down q)"
check "down moves one line at a time" 'echo "$out" | frame_n 6 | grep -q "líneas 3-26 de 2002"'
out="$(panel 4 enter home up q)"
check "it never goes above the first line" 'echo "$out" | frame_n 5 | grep -q "líneas 1-24 de 2002"'
out="$(panel 4 enter home end q)"
check "End is the last page again" 'echo "$out" | frame_n 5 | grep -q "líneas 1979-2002 de 2002"'
out="$(panel 4 enter pgdn q)"
check "it never goes below the last line" 'echo "$out" | frame_n 4 | grep -q "líneas 1979-2002 de 2002"'
out="$(panel 4 enter esc q)"
check "Esc goes back to the list of runs" 'echo "$out" | frame_n 4 | grep -q "Ejecuciones (UTC)" && ! echo "$out" | frame_n 4 | grep -q "Salida de "'
out="$(panel 4 enter esc esc q)"
check "and the next Esc to the instances" 'echo "$out" | frame_n 5 | grep -q "\[1 Instancias\]"'
check "the first line of any page is right, also across checkpoints (500 lines) and with multibyte text" '[ "$(run_lib "DASH_VIEW=runs; dash_runs_load; dash_runs_log_open $VID; for t in 0 1 499 500 501 999 1000 1500 1997; do dash_runs_log_fetch \$t 3; printf \"%s|\" \"\${DASH_RV_PAGE[0]}\"; done")" = "línea ñ ✔ 1|línea ñ ✔ 2|línea ñ ✔ 500|línea ñ ✔ 501|línea ñ ✔ 502|línea ñ ✔ 1000|línea ñ ✔ 1001|línea ñ ✔ 1501|línea ñ ✔ 1998|" ]'
check "the index has one offset per 500 lines and the line count" '[ "$(run_lib "DASH_VIEW=runs; dash_runs_load; dash_runs_log_open $VID; echo \${#DASH_RV_CK[@]} \$DASH_RV_TOTAL")" = "5 2002" ]'
check "a result for another run is ignored" '[ "$(run_lib "DASH_VIEW=runs; dash_runs_load; dash_runs_log_open $VID; dash_runs_log_index other-run L5; echo \$DASH_RV_TOTAL")" = "2002" ]'
check "closing the viewer lets go of what it held" '[ "$(run_lib "DASH_VIEW=runs; dash_runs_load; dash_runs_log_open $VID; dash_runs_log_close; echo \${#DASH_RV_CK[@]} \${#DASH_RV_PAGE[@]} \$DASH_RV_TOTAL \$DASH_RV_ID")" = "0 0 -1" ]'
check "every size draws the viewer inside the screen" 'for c in 60 80 100 160 300; do run_lib "COLUMNS=$c; DELTACTL_TUI_ROWS=30; tui_size; dash_init; DASH_VIEW=runs; dash_runs_load; dash_runs_log_open $VID; dash_render" | while IFS= read -r l; do [ "${#l}" -le "$c" ] || echo "WIDE:$c"; done; done | grep -q WIDE && exit 1; exit 0'
RESIZE='COLUMNS=100; DELTACTL_TUI_ROWS=30; tui_size; dash_init; DASH_VIEW=runs; dash_runs_load;'
check "the selected run and the scroll of its detail survive a resize" '[ "$(run_lib "$RESIZE dash_runs_select 1; DASH_RUNS_OFF=3; dash_render >/dev/null; id=\$DASH_RUNS_SEL_ID; COLUMNS=60; DELTACTL_TUI_ROWS=20; tui_size; dash_render >/dev/null; COLUMNS=160; DELTACTL_TUI_ROWS=40; tui_size; dash_render >/dev/null; [ \"\$id\" = \"\$DASH_RUNS_SEL_ID\" ] && echo same \$DASH_RUNS_SEL")" = "same 1" ]'
check "the page of the viewer is still where it was after a resize" '[ "$(run_lib "$RESIZE dash_runs_log_open $VID; DASH_RV_END=0; DASH_RV_TOP=1500; dash_render >/dev/null; a=\$DASH_RV_TOP; COLUMNS=60; DELTACTL_TUI_ROWS=20; tui_size; dash_render >/dev/null; echo \$a \$DASH_RV_TOP")" = "1500 1500" ]'
check "and a position past the end falls back to the last page when the screen is taller" '[ "$(run_lib "$RESIZE dash_runs_log_open $VID; DASH_RV_END=0; DASH_RV_TOP=1990; dash_render >/dev/null; echo \$DASH_RV_TOP")" = "1978" ]'
# A run that left no output has nothing to open.
mkrun 20261111T100000Z-21 stop tui-a succeeded 0 900
: > "$RUNS/runs/20261111T100000Z-21/out.log"
out="$(panel 4 enter q)"
check "a run with no output says so and stays on the list" 'echo "$out" | frame_n 3 | grep -q "Esta ejecución no dejó salida" && echo "$out" | frame_n 3 | grep -q "Ejecuciones (UTC)"'
rm -rf "$RUNS"
# A big log: it opens without growing the memory of the panel, and the page comes from the checkpoint, not from the whole file.
mkrun "$VID" deploy tui-a succeeded 0 5000 1000 1000 1000
yes "línea ñ ✔ de relleno para que el log sea grande y con varios bytes por carácter" | head -c 41943040 > "$RUNS/runs/$VID/out.log"
BIG_LINES="$(grep -c '' "$RUNS/runs/$VID/out.log")"   # (the cut at 40 MiB leaves a last line with no newline, which wc -l does not count)
cat > "$FIX/mem.sh" <<'EOF'
source lib/bootstrap.sh; source lib/cmd/dashboard.sh
hwm() { local k v; while read -r k v _; do [ "$k" != "VmHWM:" ] || { echo "$v"; return; }; done < /proc/$$/status; }
DASH_VIEW=runs; dash_runs_load
b="$(hwm)"
dash_runs_log_open "$1"; DASH_RV_END=0; DASH_RV_TOP=500000; dash_runs_log_box 100 30 > /dev/null
a="$(hwm)"
echo "$DASH_RV_TOTAL $(( (a - b) < 8192 ? 1 : 0 )) ${#DASH_RV_PAGE[@]}"
EOF
cat > "$FIX/async.sh" <<'EOF'
source lib/bootstrap.sh; source lib/cmd/dashboard.sh
DASH_RV_SYNC_MAX=0; DASH_VIEW=runs; dash_runs_load
dash_runs_log_open "$1"
first="$DASH_RV_TOTAL"
dash_runs_log_box 100 30
shown="${#DASH_RV_PAGE[@]}"
for i in $(seq 1 100); do dash_async_tick && break; sleep 0.2; done
echo "$first $shown $DASH_RV_TOTAL"
EOF
check "a 40 MiB log opens: the line count is right and the memory of the panel barely moves" '[ "$(ROOT="$PWD" DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_ASCII=1 COLUMNS=100 bash "$FIX/mem.sh" "$VID" 2>&1)" = "$BIG_LINES 1 28" ]'
# Past the limit the pass runs in the background: the viewer shows the end of the file at once and the index arrives later.
check "a big log is indexed in the background while the viewer already shows the end of the file" '[ "$(env -u DELTACTL_TUI_KEYS ROOT="$PWD" DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_ASCII=1 COLUMNS=100 bash "$FIX/async.sh" "$VID" 2>&1)" = "-1 28 $BIG_LINES" ]'
rm -rf "$RUNS"

section "16. the Processes view and the card in the header"
PT="$FIX/pt"
rm -rf "$PT"
# A /proc of its own: a command (100) with three processes below it (101 and 102 children, 103 a grandchild), and the panel (200)
# with one child (201). Memory is in pages (the second number of statm); the tests use 4 KB pages.
# fakeproc <pid> <resident pages> <children, with a trailing space or none> <argv separated by |, empty for a kernel-style name>
fakeproc() {
  mkdir -p "$PT/$1/task/$1"
  printf '%s %s 0 0 0 0 0\n' $(($2 * 2)) "$2" > "$PT/$1/statm"
  printf '%s' "$3" > "$PT/$1/task/$1/children"      # (the kernel does not end this file with a newline)
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
PTENV="DELTACTL_PROC_ROOT=$PT; DASH_PAGE_KB=4; DASH_CLK_TCK=100;"
check "the tree lists the processes in tree order, with their depth and the memory of the ones below the root" '[ "$(run_lib "$PTENV dash_proc_tree 100; echo \"\${DASH_PT_PID[*]}|\${DASH_PT_DEP[*]}|\$DASH_PT_SUM|\$DASH_PT_N\"")" = "100 101 103 102|0 1 2 1|7000|3" ]'
check "a command line is shown without the directory of the program; a process with no command line shows its name" '[ "$(run_lib "$PTENV dash_proc_tree 100; printf \"%s|\" \"\${DASH_PT_CMD[@]}\"")" = "bash /x/deltactl deploy a|docker compose up|[sh]|tee -ia /x/out.log|" ]'
check "a process that is gone is skipped" '[ "$(run_lib "$PTENV dash_proc_tree 999; echo \${#DASH_PT_PID[@]}")" = "0" ]'
check "the tree never grows past its limit" '[ "$(run_lib "$PTENV DASH_PROCS_MAX=2; dash_proc_tree 100; echo \${#DASH_PT_PID[@]}")" = "2" ]'
check "the CPU is ticks over time (50 ticks in 2 s at 100 Hz is 25.0 %)" '[ "$(run_lib "$PTENV dash_proc_tenths 50 2000000; echo \$DASH_TEN")" = "250" ]'
check "the panel reads its own memory, its CPU since it started and what it has started" '[ "$(run_lib "$PTENV DASH_SELF_PID=200; SECONDS=10; dash_proc_self; case \$DASH_PS_AVG in 10.0%|9.*%) a=ok ;; *) a=\$DASH_PS_AVG ;; esac; echo \"\$DASH_PS_RSS|\$a|\$DASH_PS_NOW|\${DASH_PS_KIDS[*]}|\${DASH_PS_KCMD[*]}\"")" = "8000|ok|-|201|docker events" ]'
check "the panel can read its real memory from the real /proc" '[ "$(run_lib "DELTACTL_PROC_ROOT=/proc; dash_proc_self; echo \$((DASH_PS_RSS > 1000))")" = "1" ]'
out="$(panel 5 q)"
f="$(echo "$out" | frame_n 2)"
check "5 opens the Processes view" 'echo "$f" | grep -q "\[5 Procesos\]"'
check "with nothing running it says so, and still shows what the panel costs" 'echo "$f" | grep -q "No hay ningún comando en curso" && echo "$f" | grep -q "El propio panel" && echo "$f" | grep -q "pid "'
LIVE="$PTENV DASH_SELF_PID=200; SECONDS=10; DELTACTL_TUI_ROWS=30; tui_size; dash_init; JOB_PID=100; JOB_TITLE=\"deploy a\"; JOB_RC=; host_now_us; JOB_START_US=\$HOST_NOW_US; DASH_VIEW=procs; dash_procs_tick; dash_render"
f="$(run_lib "$LIVE" | last_frame)"
check "while a command runs, its processes are drawn as a tree under its name" 'echo "$f" | grep -q "./deltactl deploy a" && echo "$f" | grep -qE "3\.9 MB {4}docker compose up" && echo "$f" | grep -qE "1\.9 MB {6}\[sh\]" && echo "$f" | grep -qE "1000 KB {4}tee -ia"'
check "the root is listed without memory (it is only the process that waits)" 'echo "$f" | grep -q "100 *- *bash /x/deltactl deploy a"'
check "the total says what it leaves out" 'echo "$f" | grep -q "3 procesos . 6.8 MB en total" && echo "$f" | grep -q "dockerd y los contenedores no cuentan"'
check "the panel box shows its pid, memory, CPU and the processes it has started" 'echo "$f" | grep -q "pid 200 . memoria 7.8 MB . CPU - ahora . \(10\.0\|9\.[0-9]\)% de media" && echo "$f" | grep -q "procesos que ha lanzado y siguen vivos: 1" && echo "$f" | grep -qE "201 *[0-9.]+ (MB|KB) +docker events"'
check "the card in the header says how many processes the running command has and what they use" 'run_lib "$PTENV tui_size; dash_init; JOB_PID=100; JOB_TITLE=\"deploy a\"; JOB_RC=; host_now_us; JOB_START_US=\$HOST_NOW_US; dash_procs_tick; dash_render" | last_frame | sed -n 3p | grep -q "deploy a.*3 proc . 6.8 MB"'
check "with a command running the tab line keeps the command and shrinks the names of the other views" 'run_lib "$PTENV tui_size; dash_init; JOB_PID=100; JOB_TITLE=\"deploy a\"; JOB_RC=; host_now_us; JOB_START_US=\$HOST_NOW_US; dash_procs_tick; dash_render" | last_frame | sed -n 3p | grep -q "\[1 Instancias\] *2 *3 *4 *5 .*deploy a"'
check "without a running command there is no card" '[ -z "$(run_lib "$PTENV tui_size; dash_init; dash_procs_tick; dash_render" | last_frame | sed -n 3p | grep "proc .")" ]'
check "the card goes away when the command ends" '[ "$(run_lib "$PTENV JOB_PID=100; JOB_RC=; dash_procs_tick; a=\$DASH_PC_TXT; JOB_RC=0; dash_procs_tick; echo \"[\$a][\$DASH_PC_TXT]\"")" = "[3 proc · 6.8 MB][]" ]'
cp -r "$PT" "$FIX/pt2"
check "the view does not read again within the same second" '[ "$(run_lib "DELTACTL_PROC_ROOT=$FIX/pt2; DASH_PAGE_KB=4; SECONDS=5; DASH_VIEW=procs; JOB_PID=100; JOB_RC=; dash_procs_tick; n=\$DASH_PROCS_N; rm -rf $FIX/pt2/103; dash_procs_tick; echo \$((DASH_PROCS_N == n))")" = "1" ]'
rm -rf "$FIX/pt2"
# A tree of 13 processes in a small panel: only some rows fit, the keys scroll, and it stops at the last process.
fakeproc 300 100 "301 302 303 304 305 306 307 308 309 310 311 312 " "bash|big"
for p in 301 302 303 304 305 306 307 308 309 310 311 312; do fakeproc "$p" 10 "" "worker|$p"; done
SCROLL="$PTENV SECONDS=5; DELTACTL_TUI_ROWS=20; tui_size; dash_init; JOB_PID=300; JOB_TITLE=big; JOB_RC=; host_now_us; JOB_START_US=\$HOST_NOW_US; DASH_VIEW=procs; dash_procs_tick;"
check "a tree that does not fit shows its first rows and not the last" 'run_lib "$SCROLL dash_render" | last_frame | grep -q "worker 301" && ! run_lib "$SCROLL dash_render" | last_frame | grep -q "worker 312"'
check "PgDn scrolls and it stops at the last process, which is then shown" '[ "$(run_lib "$SCROLL dash_key_procs pgdn; dash_key_procs pgdn; dash_key_procs pgdn; dash_render > /dev/null; a=\$DASH_PROCS_OFF; dash_key_procs pgdn; dash_render > $FIX/scroll.txt; grep -c \"worker 312\" $FIX/scroll.txt; echo \$((a > 0)) \$((a == DASH_PROCS_OFF))")" = "1
1 1" ]'
check "Home goes back to the first row" '[ "$(run_lib "$SCROLL dash_key_procs pgdn; dash_key_procs home; echo \$DASH_PROCS_OFF")" = "0" ]'
out="$(panel 4 tab q)"
check "Tab goes from Runs to Processes" 'echo "$out" | frame_n 3 | grep -q "\[5 Procesos\]"'
out="$(panel 5 tab tab tab tab tab q)"
check "and wraps from Processes, through the Console, Server, Images and Variables views, to Instances" 'echo "$out" | frame_n 3 | grep -q "\[6 Consola\]" && echo "$out" | frame_n 4 | grep -q "\[7 Servidor\]" && echo "$out" | frame_n 5 | grep -q "\[8 Imágenes\]" && echo "$out" | frame_n 6 | grep -q "\[9 Variables\]" && echo "$out" | frame_n 7 | grep -q "\[1 Instancias\]"'
out="$(panel 5 btab q)"
check "Shift+Tab goes from Processes back to Runs" 'echo "$out" | frame_n 3 | grep -q "\[4 Ejecuciones\]"'
out="$(panel : $(typed "goto procs") enter q)"
check "the console can go to the view" 'echo "$out" | grep -q "\[5 Procesos\]"'
check "the key bar and the help overlay document it" 'panel 5 q | frame_n 2 | tail -2 | grep -q "x cancelar el comando" && panel 5 "?" q | frame_n 3 | grep -q "PROCES\."'
check "in English the view is translated too" '[ "$(DELTACTL_LANG=en panel 5 q | frame_n 2 | grep -c "\[5 Processes\]\|No command is running\|The panel itself")" -ge 3 ]'
check "every size draws the view inside the screen, with a command running" 'for c in 60 80 100 160 300; do run_lib "COLUMNS=$c; DELTACTL_TUI_ROWS=30; $LIVE" | while IFS= read -r l; do [ "${#l}" -le "$c" ] || echo "WIDE:$c"; done; done | grep -q WIDE && exit 1; exit 0'
check "a command line with control characters cannot reach the screen" '
  printf "%s\0" docker $(printf "ev\033[2Jil") > "$PT/102/cmdline"
  ! run_lib "COLUMNS=100; $LIVE" | grep -q "$ESC"'
rm -rf "$PT"

section "17. hardening: what the disk and /proc say is data"
rm -rf "$RUNS"
HID=20261120T100000Z-30
mkrun "$HID" deploy tui-a succeeded 0 5000 1000 1000 1000
# 1. a number from a meta file is never evaluated as arithmetic
sed -i "s|^DOCKER_MS=.*|DOCKER_MS=a[\$(touch $FIX/pwned)]|" "$RUNS/runs/$HID/meta"
rm -f "$FIX/pwned"
check "(the meta file really carries the payload)" 'grep -q "^DOCKER_MS=a\[\$(touch " "$RUNS/runs/$HID/meta"'
out="$(panel 4 q 2>&1)"
check "a number in a meta file is never evaluated (no command runs, the panel survives)" '[ ! -e "$FIX/pwned" ] && echo "$out" | frame_n 2 | grep -q "Consumo de la operación" && ! echo "$out" | grep -q "syntax error\|unbound"'
# 2. every field of the history is cleaned before it is drawn
mkrun 20261120T110000Z-31 stop tui-a succeeded 0 900
sed -i "s/^RC=.*/RC=\x1b[2Jrc/; s/^HOST=.*/HOST=\x1b]0;h\x07/; s/^STATE=.*/STATE=\x1b[2Jodd/" "$RUNS/runs/20261120T110000Z-31/meta"
printf '20261120T120000Z-32\t2026-11-20T\033[2J12:00:00Z\tdeploy\ttui-a\t\033[2Jweird\t0\t1000\n' >> "$RUNS/runs.idx"
out="$(panel 4 q 2>&1)"
check "the fields of the index and of the meta files never reach the screen with their control characters" '! echo "$out" | grep -q "$ESC"'
check "a row whose date had control characters is shown cleaned" 'echo "$out" | frame_n 2 | grep -q "11-20 12:00 deploy"'
out="$(panel 4 down q 2>&1)"
check "a state the panel does not know is shown, cleaned, and does not break the view" 'echo "$out" | frame_n 3 | grep -q "odd" && ! echo "$out" | grep -q "$ESC"'
# 3 and 4. the lines of a saved output
LID=20261120T130000Z-33
mkrun "$LID" deploy tui-a succeeded 0 5000 1000 1000 1000
printf 'crlf line\r\nplain\nbar 10%%\rbar 100%%\r\nbell\a\bback\fform\x0eshift\x0fend\nlast\n' > "$RUNS/runs/$LID/out.log"
out="$(panel 4 enter q)"
f="$(echo "$out" | frame_n 3)"
check "a CRLF line shows its text, not a blank" 'echo "$f" | grep -q "   1 crlf line" && echo "$f" | grep -q "   2 plain"'
check "a progress bar that ends in CRLF shows its last state" 'echo "$f" | grep -q "bar 100%" && ! echo "$f" | grep -q "bar 10%bar"'
check "backspace, form feed and the charset switches are removed, the text around them stays" 'echo "$f" | grep -q "bellbackformshiftend" && [[ "$f" != *$'"'"'\x0e'"'"'* && "$f" != *$'"'"'\x0c'"'"'* && "$f" != *$'"'"'\x08'"'"'* ]]'
out="$(panel 4 pgdn q)"
f="$(echo "$out" | frame_n 3)"
check "the end of the output in the detail is cleaned the same way" 'echo "$f" | grep -q "crlf line" && [[ "$f" != *$'"'"'\x0e'"'"'* && "$f" != *$'"'"'\x0c'"'"'* && "$f" != *$'"'"'\x08'"'"'* ]]'
# 7. a meta that lacks its keys (empty, truncated) does not kill the panel
mkdir -p "$RUNS/runs/20261120T140000Z-34"; : > "$RUNS/runs/20261120T140000Z-34/meta"
printf '20261120T140000Z-34\t2026-11-20T14:00:00Z\tdeploy\ttui-a\tsucceeded\t0\t1000\n' >> "$RUNS/runs.idx"
out="$(panel 4 q 2>&1)"
check "an empty meta file is shown, not fatal" 'echo "$out" | frame_n 2 | grep -q "Ejecuciones (UTC)" && ! echo "$out" | grep -q "unbound variable"'
out="$(panel 4 t q 2>&1)"
check "and it does not break the statistics either (the panel and the CLI)" '! echo "$out" | grep -q "unbound variable" && ! bash ./deltactl runs stats 2>&1 | grep -q "unbound variable"'
# 5. the detail of a run in progress follows what it prints
( exec -a deltactl-test sleep 60 ) &
SLEEPER=$!
RID=20261120T150000Z-35
mkdir -p "$RUNS/runs/$RID" "$RUNS/active"
printf 'RUN_ID=%s\nOP=deploy\nARGS=tui-a\nINSTANCE=tui-a\nSTATE=running\nSTARTED_AT=2026-11-20T15:00:00Z\n' "$RID" > "$RUNS/runs/$RID/meta"
printf 'first line\n' > "$RUNS/runs/$RID/out.log"
printf '%s\n' "$SLEEPER" > "$RUNS/active/$RID"
check "the detail of a run in progress is built again at every load, so it follows its output" '[ "$(run_lib "DASH_VIEW=runs; dash_runs_load; dash_runs_detail; a=\"\${DASH_RUNS_DET[*]}\"; echo second line >> $RUNS/runs/$RID/out.log; dash_runs_load; dash_runs_detail; b=\"\${DASH_RUNS_DET[*]}\"; case \$a in *\"second line\"*) echo early ;; *) case \$b in *\"second line\"*) echo follows ;; *) echo stale ;; esac ;; esac")" = "follows" ]'
kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null; rm -f "$RUNS/active/$RID"
# 8. the CPU "now" of the panel does not average the time spent in another view
fakeproc() {
  mkdir -p "$PT/$1/task/$1"
  printf '%s %s 0 0 0 0 0\n' $(($2 * 2)) "$2" > "$PT/$1/statm"
  printf '%s' "$3" > "$PT/$1/task/$1/children"
  : > "$PT/$1/cmdline"; printf 'sh\n' > "$PT/$1/comm"
}
rm -rf "$PT"; fakeproc 200 2000 ""
printf '200 (deltactl x) S 1 1 1 0 -1 0 0 0 0 0 50 50 0 0 20 0 1 0 1 1 1\n' > "$PT/200/stat"
check "leaving the Processes view forgets the last CPU reading" '[ "$(run_lib "DELTACTL_PROC_ROOT=$PT; DASH_PAGE_KB=4; DASH_CLK_TCK=100; DASH_SELF_PID=200; DASH_VIEW=procs; dash_procs_tick; a=\$DASH_PS_PREV_TICKS; DASH_VIEW=instances; dash_procs_tick; echo \$a \$DASH_PS_PREV_TICKS")" = "100 -1" ]'
rm -rf "$PT"
# 6. a pass over a log nobody waits for any more is stopped with its awk, and leaves nothing behind
rm -rf "$RUNS"
mkrun "$HID" deploy tui-a succeeded 0 5000 1000 1000 1000
yes "línea ñ ✔ de relleno para que el log sea grande y con varios bytes por carácter" | head -c 41943040 > "$RUNS/runs/$HID/out.log"
cat > "$FIX/cancel.sh" <<'EOF'
source lib/bootstrap.sh; source lib/cmd/dashboard.sh
DASH_RV_SYNC_MAX=0; DASH_VIEW=runs; dash_runs_load
dash_runs_log_open "$1"
pid="${DASH_AS_PID[rvidx]:-}"
dash_runs_log_close
sleep 0.5
left="$(pgrep -fc 'awk -v n=500' || true)"
files="$(ls "$JOB_DIR"/as.rvidx.* 2> /dev/null | wc -l | tr -d ' ')"
echo "$([ -n "$pid" ] && echo started) [${DASH_AS_PID[rvidx]:-}] awk=$left files=$files"
EOF
check "closing the viewer stops the pass over a big log, its awk and its files" '[ "$(env -u DELTACTL_TUI_KEYS ROOT="$PWD" DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_ASCII=1 COLUMNS=100 bash "$FIX/cancel.sh" "$HID" 2>&1)" = "started [] awk=0 files=0" ]'
rm -rf "$RUNS"

section "18. what an idle panel does not redo"
BODYENV='COLUMNS=120; DELTACTL_TUI_ROWS=30; tui_size; dash_init;'
check "the Runs, Output and Processes bodies are kept when a new sample arrives (nothing in them changed)" 'for v in runs output procs; do [ "$(run_lib "$BODYENV DASH_VIEW=$v; dash_render >/dev/null; a=\$DASH_BODY_SIG; MT_SAMPLES=\$((MT_SAMPLES + 1)); DASH_REFRESH_N=\$((DASH_REFRESH_N + 1)); DASH_ERRS_N=\$((DASH_ERRS_N + 1)); DASH_EV_N=\$((DASH_EV_N + 1)); DASH_LOGS_N=\$((DASH_LOGS_N + 1)); dash_render >/dev/null; [ \"\$a\" = \"\$DASH_BODY_SIG\" ] && echo kept || echo rebuilt")" = "kept" ] || exit 1; done'
check "the Instances and Resources bodies are built again with every sample (their figures changed)" 'for v in instances resources; do [ "$(run_lib "$BODYENV dash_refresh; DASH_VIEW=$v; dash_render >/dev/null; a=\$DASH_BODY_SIG; MT_SAMPLES=\$((MT_SAMPLES + 1)); dash_render >/dev/null; [ \"\$a\" != \"\$DASH_BODY_SIG\" ] && echo rebuilt || echo kept")" = "rebuilt" ] || exit 1; done'
check "a view that keeps its body still shows the new header" '[ "$(run_lib "$BODYENV DASH_VIEW=output; MT_HOST_PCT=50; MT_HOST_TOTAL_KB=8388608; MT_HOST_USED_KB=4194304; dash_host_build; dash_render >/dev/null; MT_HOST_PCT=90; MT_HOST_USED_KB=7549747; dash_host_build; dash_render | grep -c \"90%\"")" = "1" ]'
check "the sampling interval is stretched while the view shows no figure of a service" '[ "$(run_lib "HOST_FAKE_NOW_US=10000000; MT_LAST_US=7000000; MT_INTERVAL_MULT=1; mt_due && a=due || a=wait; MT_INTERVAL_MULT=2; mt_due && b=due || b=wait; echo \$a \$b")" = "due wait" ]'
check "the panel sets it by view: 2 for Output, Runs and Processes, 1 for the others" '[ "$(run_lib "$BODYENV for v in output runs procs instances resources; do DASH_VIEW=\$v; dash_tick >/dev/null 2>&1; printf \"%s \" \$MT_INTERVAL_MULT; done")" = "2 2 2 1 1 " ]'
check "after 30 s without a key it samples half as often, in every view" '[ "$(run_lib "$BODYENV DASH_KEY_AT=\$((SECONDS - 30)); for v in output instances; do DASH_VIEW=\$v; dash_tick >/dev/null 2>&1; printf \"%s%s \" \$MT_INTERVAL_MULT \$DASH_AWAY; done; DASH_KEY_AT=\$((SECONDS - 29)); dash_tick >/dev/null 2>&1; echo \$MT_INTERVAL_MULT\$DASH_AWAY")" = "41 21 10" ]'
check "not while a command runs: its figures are being watched" '[ "$(run_lib "$BODYENV DASH_KEY_AT=\$((SECONDS - 100)); job_start t sleep 3; DASH_VIEW=instances; dash_tick >/dev/null 2>&1; echo \$MT_INTERVAL_MULT\$DASH_AWAY; job_cancel >/dev/null 2>&1")" = "10" ]'
check "the first key back takes a fresh sample at once; a key while not away does not" '[ "$(run_lib "MT_LAST_US=5; DASH_AWAY=1; dash_key_seen; a=\$MT_LAST_US\$DASH_AWAY; MT_LAST_US=5; dash_key_seen; echo \$a \$MT_LAST_US \$((SECONDS - DASH_KEY_AT))")" = "00 5 0" ]'
check "DELTACTL_TUI_IDLE_AFTER sets how long, and a wrong value falls back to 30" '[ "$(DELTACTL_TUI_IDLE_AFTER=5 run_lib "echo \$DASH_IDLE_AFTER")" = "5" ] && [ "$(DELTACTL_TUI_IDLE_AFTER=x run_lib "echo \$DASH_IDLE_AFTER")" = "30" ]'
check "0 and an endless number are wrong values too (0 would make every key a return from away)" '[ "$(DELTACTL_TUI_IDLE_AFTER=0 run_lib "echo \$DASH_IDLE_AFTER")" = "30" ] && [ "$(DELTACTL_TUI_IDLE_AFTER=99999999999999999999 run_lib "echo \$DASH_IDLE_AFTER")" = "30" ]'
check "while away a state refresh does not force a sample; otherwise it does (the pids may have changed)" '[ "$(run_lib "MT_LAST_US=5; DASH_AWAY=1; dash_after_collect; a=\$MT_LAST_US; DASH_AWAY=0; dash_after_collect; echo \$a \$MT_LAST_US")" = "5 0" ]'

section "19. interrupted runs nobody has reviewed"
rm -rf "$RUNS"
IID=20261121T100000Z-40
mkrun "$IID" deploy tui-a succeeded 0 5000 1000 1000 1000
sed -i 's/^STATE=.*/STATE=interrupted/; s/^RC=.*/RC=-/' "$RUNS/runs/$IID/meta"
mkdir -p "$RUNS/pending"; printf 'deploy\ttui-a\n' > "$RUNS/pending/$IID"
out="$(panel 4 q)"
f="$(echo "$out" | frame_n 2)"
check "the Runs view says an interrupted run is pending review, and how to clear it" 'echo "$f" | grep -q "pendiente de revisar" && echo "$f" | grep -q "./deltactl runs resolve $IID"'
check "and that stopping an operation does not undo what Docker already did" 'echo "$f" | grep -q "no deshace lo ya cambiado en Docker"'
check "reviewing it from the CLI updates the view that is open (the index did not change)" '[ "$(run_lib "DASH_VIEW=runs; dash_runs_load; dash_runs_detail; a=\"\${DASH_RUNS_DET[*]}\"; rm -f $RUNS/pending/$IID; printf \"RESOLVED_AT=2026-11-21T11:00:00Z\nNOTE=visto a mano\n\" >> $RUNS/runs/$IID/meta; dash_runs_load; dash_runs_detail; b=\"\${DASH_RUNS_DET[*]}\"; case \$a in *\"pendiente de revisar\"*) ;; *) echo before-wrong; exit ;; esac; case \$b in *\"pendiente de revisar\"*) echo still-pending ;; *\"revisada el 2026-11-21 11:00:00Z\"*\"visto a mano\"*) echo updated ;; *) echo missing ;; esac")" = "updated" ]'
check "in English it is translated" '[ "$(DELTACTL_LANG=en panel 4 q | frame_n 2 | grep -c "does not undo what Docker changed")" = "0" ] || true; printf "%s" "$(DELTACTL_LANG=en run_lib "DASH_VIEW=runs; dash_runs_load; dash_runs_detail; printf \"%s\" \"\${DASH_RUNS_DET[*]}\"")" | grep -q "does not undo what Docker changed"'
rm -rf "$RUNS"

section "20. the logs pane: a stream while it is on screen, pause, errors only and search"
LS="$LOGS_WIDE"
printf 'first line\n\033[2Jsecond \033[31mline\033[0m\nERROR third\n' > "$FIX/stream1.txt"
printf 'again 1\nagain 2\n' > "$FIX/stream2.txt"
check "a stream is wanted when the pane is on screen and its service runs" '[ "$(run_lib "$LS dash_ls_wanted && echo yes \$DASH_LS_WANT")" = "yes tui-a/s0" ]'
check "not on a narrow screen (there is no logs pane)" '! run_lib "COLUMNS=100; DELTACTL_TUI_ROWS=30; tui_size; dash_init; dash_refresh; mt_sample; dash_current_target; dash_ls_wanted && echo yes" | grep -q yes'
check "not on another view" '! run_lib "$LS DASH_VIEW=resources; dash_ls_wanted && echo yes" | grep -q yes && ! run_lib "$LS DASH_VIEW=output; dash_ls_wanted && echo yes" | grep -q yes'
check "not when the service is not running" '! run_lib "$LS ST_STATE[tui-a/s0]=exited; dash_ls_wanted && echo yes" | grep -q yes'
check "zoomed, only when it is the logs that are zoomed" '! run_lib "$LS DASH_ZOOM=1; DASH_FOCUS=list; dash_ls_wanted && echo yes" | grep -q yes && run_lib "$LS DASH_ZOOM=1; DASH_FOCUS=logs; dash_ls_wanted && echo yes" | grep -q yes'
check "the lines of the stream reach the pane, cleaned once (no escape sequence gets in)" '[ "$(run_lib "$LS DELTACTL_TUI_LOGSTREAM=$FIX/stream1.txt; dash_ls_tick; printf \"%s\" \"\${DASH_LOGS[tui-a/s0]}\" | od -An -c | grep -c 033")" = "0" ] && run_lib "$LS DELTACTL_TUI_LOGSTREAM=$FIX/stream1.txt; dash_ls_tick; echo \"\${DASH_LOGS[tui-a/s0]}\"" | grep -q "second line"'
check "the stream replaces what the polling had put there" '! run_lib "$LS DELTACTL_TUI_LOGSTREAM=$FIX/stream1.txt; dash_ls_tick; echo \"\${DASH_LOGS[tui-a/s0]}\"" | grep -q "line 30 ok"'
check "at the end of the stream it is closed, the lines stay and the pane goes back to polling" '[ "$(run_lib "$LS DELTACTL_TUI_LOGSTREAM=$FIX/stream1.txt; dash_ls_tick; echo \"[\$DASH_LS_FD][\$DASH_LS_ENDED][\${#DASH_LS_RING[@]}][\$DASH_LS_KEY]\"; dash_ls_active tui-a/s0 && echo active || echo polling")" = "[][1][3][tui-a/s0]
polling" ]'
check "a stream that ended is started again once the service runs after 5 s" '[ "$(run_lib "$LS DELTACTL_TUI_LOGSTREAM=$FIX/stream1.txt; dash_ls_tick; DASH_LS_END_AT=\$((SECONDS - 6)); DELTACTL_TUI_LOGSTREAM=$FIX/stream2.txt; dash_ls_tick; echo \"\${DASH_LS_RING[*]}\"")" = "again 1 again 2" ]'
check "the screen is updated once a second at most however fast the log grows" '[ "$(run_lib "$LS DELTACTL_TUI_LOGSTREAM=$FIX/stream1.txt; SECONDS=7; dash_ls_tick; n=\$DASH_LOGS_N; DASH_LS_RING+=(more); DASH_LS_FRESH=1; dash_ls_tick; echo \$((DASH_LOGS_N - n))")" = "0" ]'
# A real stream: `docker logs -f` as a coprocess, stopped when the pane goes away.
touch "$FIX/logs_block"
check "a real stream reads the log of the container while the pane is shown" '[ "$(run_lib "$LS dash_ls_tick; sleep 0.6; dash_ls_tick; echo \${#DASH_LS_RING[@]}; kill -0 \$DASH_LS_PID && echo alive; dash_ls_stop")" = "2
alive" ]'
check "it is stopped, process included, as soon as the pane is not shown" '[ "$(run_lib "$LS dash_ls_tick; pid=\$DASH_LS_PID; sleep 0.3; DASH_VIEW=resources; dash_ls_tick; sleep 0.2; kill -0 \$pid 2>/dev/null && echo still || echo stopped; echo \"[\$DASH_LS_FD][\$DASH_LS_KEY]\"")" = "stopped
[][]" ]'
check "it is stopped when the selection moves to another service, and a new one starts" '[ "$(run_lib "$LS dash_ls_tick; a=\$DASH_LS_PID; sleep 0.4; DASH_SVC=1; dash_current_target; dash_ls_tick; sleep 0.2; kill -0 \$a 2>/dev/null && echo old-alive || echo old-stopped; echo \$DASH_LS_KEY; dash_ls_stop")" = "old-stopped
tui-a/s1" ]'
check "leaving the panel stops it too (no docker process is left behind)" '[ "$(run_lib "$LS dash_ls_tick; pid=\$DASH_LS_PID; sleep 0.3; dash_shutdown >/dev/null 2>&1; sleep 0.2; kill -0 \$pid 2>/dev/null && echo still || echo gone")" = "gone" ]'
rm -f "$FIX/logs_block"
check "pausing keeps the pane as it is and counts what arrives" '[ "$(run_lib "$LS DELTACTL_TUI_LOGSTREAM=$FIX/stream1.txt; dash_ls_tick; a=\"\${DASH_LOGS[tui-a/s0]}\"; dash_logs_pause_toggle >/dev/null; DASH_LS_RING+=(n1 n2); dash_ls_publish; [ \"\$a\" = \"\${DASH_LOGS[tui-a/s0]}\" ] && echo same; echo \$DASH_LS_PEND")" = "same
2" ]'
check "resuming shows what arrived and follows the end" '[ "$(run_lib "$LS DELTACTL_TUI_LOGSTREAM=$FIX/stream1.txt; dash_ls_tick; dash_logs_pause_toggle >/dev/null; DASH_LS_RING+=(n1 n2); dash_ls_publish; DASH_LOG_SCROLL=4; dash_logs_pause_toggle >/dev/null; echo \"\$DASH_LS_PAUSED \$DASH_LS_PEND \$DASH_LOG_SCROLL\"; echo \"\${DASH_LOGS[tui-a/s0]}\" | tail -1")" = "0 0 0
n2" ]'
check "the title of a paused pane says so and how many lines are waiting" 'run_lib "$LS DELTACTL_TUI_LOGSTREAM=$FIX/stream1.txt; dash_ls_tick; dash_logs_pause_toggle >/dev/null; DASH_LS_RING+=(n1 n2); dash_ls_publish; dash_logs_box tui-a/s0 s0 70 12; printf \"%s\n\" \"\${TUI_BOX[0]}\"" | grep -q "pausa +2"'
check "a paused pane is not polled, and one that is not paused is" '[ "$(run_lib "$LS DASH_LS_KEY=tui-a/s0; DASH_LS_PAUSED=1; DASH_LOGS_AT[tui-a/s0]=-100; DASH_LOGS[tui-a/s0]=keep; dash_tick >/dev/null 2>&1; echo \"\${DASH_LOGS[tui-a/s0]}\"")" = "keep" ] && [ "$(run_lib "$LS DASH_LS_KEY=tui-a/s0; DASH_LS_PAUSED=0; DASH_LOGS_AT[tui-a/s0]=-100; DASH_LOGS[tui-a/s0]=keep; dash_tick >/dev/null 2>&1; echo \"\${DASH_LOGS[tui-a/s0]}\"")" != "keep" ]'
CLASSY='DASH_LOGS[tui-a/s0]="ok 1
ERROR boom
info 2
warn disk
fatal crash
ok 3"; DASH_LOGS_AT[tui-a/s0]=1;'
check "e shows only the errors and warnings, and the title says so" 'f="$(run_lib "$LS $CLASSY DASH_LOG_ERRONLY=1; dash_logs_box tui-a/s0 s0 70 12; printf \"%s\n\" \"\${TUI_BOX[@]}\"")"; echo "$f" | grep -q "ERROR boom" && echo "$f" | grep -q "warn disk" && echo "$f" | grep -q "fatal crash" && ! echo "$f" | grep -q "ok 1" && ! echo "$f" | grep -q "info 2" && echo "$f" | head -1 | grep -q "errores"'
check "errors only and a text filter work together" '[ "$(run_lib "$LS $CLASSY DASH_LOG_ERRONLY=1; DASH_LOG_FILTER=disk; dash_logs_select tui-a/s0; echo \"\${DASH_LS_SEL[*]}\"")" = "warn disk" ]'
check "with neither switch on, the lines are not looked at one by one (the whole log is the selection)" '[ "$(run_lib "$LS $CLASSY dash_logs_select tui-a/s0; echo \${#DASH_LS_SEL[@]}")" = "6" ]'
check "the search marks the text in each line (between [ ] when there are no colours)" 'run_lib "$LS $CLASSY DASH_LOG_FIND=boom; dash_logs_box tui-a/s0 s0 70 12; printf \"%s\n\" \"\${TUI_BOX[@]}\"" | grep -q "ERROR \[boom\]" && run_lib "$LS $CLASSY DASH_LOG_FIND=BOOM; dash_logs_box tui-a/s0 s0 70 12; printf \"%s\n\" \"\${TUI_BOX[0]}\"" | grep -q "~BOOM"'
check "the search ignores case" 'run_lib "$LS $CLASSY DASH_LOG_FIND=DISK; dash_logs_box tui-a/s0 s0 70 12; printf \"%s\n\" \"\${TUI_BOX[@]}\"" | grep -q "warn \[disk\]"'
HITS='DASH_LOGS[tui-a/s0]="$(seq -f "line %g ok" 1 30 | sed "5s/ok/hit/; 12s/ok/hit/; 25s/ok/hit/")"; DASH_LOGS_AT[tui-a/s0]=1; DASH_LOG_FIND=hit;'
check "the jump goes to the newest match first, then to the previous ones and wraps" '[ "$(run_lib "$LS $HITS dash_logs_jump 0 >/dev/null; printf \"%s \" \$DASH_LOG_MIDX \$DASH_LOG_SCROLL; dash_logs_jump -1 >/dev/null; printf \"%s \" \$DASH_LOG_MIDX \$DASH_LOG_SCROLL; dash_logs_jump -1 >/dev/null; printf \"%s \" \$DASH_LOG_MIDX; dash_logs_jump -1 >/dev/null; printf \"%s\" \$DASH_LOG_MIDX")" = "24 1 11 14 4 24" ]'
check "and forwards, wrapping to the first" '[ "$(run_lib "$LS $HITS dash_logs_jump 0 >/dev/null; dash_logs_jump 1 >/dev/null; printf \"%s \" \$DASH_LOG_MIDX; dash_logs_jump 1 >/dev/null; printf \"%s\" \$DASH_LOG_MIDX")" = "4 11" ]'
check "the jump leaves the match in view" 'run_lib "$LS $HITS dash_logs_jump -1 >/dev/null; dash_logs_jump -1 >/dev/null; dash_logs_box tui-a/s0 s0 70 12; printf \"%s\n\" \"\${TUI_BOX[@]}\"" | grep -q "line 12 \[hit\]"'
check "a search with no match says so" '[ "$(run_lib "$LS $HITS DASH_LOG_FIND=zzz; dash_logs_jump 0 >/dev/null; echo \$DASH_LOG_MIDX \"\$DASH_MSG\"")" = "-1 Ninguna línea contiene '"'"'zzz'"'"'" ]'
check "the keys of the pane: Space, f, e, s and the brackets" '[ "$(run_lib "$LS $HITS DASH_FOCUS=logs; for k in space; do TUI_KEY=\$k; dash_handle_key; done; printf \"%s \" \$DASH_LS_PAUSED; TUI_KEY=f; dash_handle_key; printf \"%s \" \$DASH_LS_PAUSED; TUI_KEY=e; dash_handle_key; printf \"%s \" \$DASH_LOG_ERRONLY; TUI_KEY=e; dash_handle_key; printf \"%s \" \$DASH_LOG_ERRONLY; TUI_KEY=s; dash_handle_key; printf \"%s\" \$DASH_MODE")" = "1 0 1 0 find" ]'
check "a real space key (it arrives as a blank) pauses too" '[ "$(run_lib "$LS DASH_FOCUS=logs; TUI_KEY=\" \"; dash_handle_key; echo \$DASH_LS_PAUSED")" = "1" ]'
check "typing a search and Enter sets it and goes to the newest match" '[ "$(run_lib "$LS $HITS DASH_LOG_FIND=; DASH_FOCUS=logs; for k in s h i t enter; do TUI_KEY=\$k; dash_handle_key; done; echo \"\$DASH_LOG_FIND \$DASH_LOG_MIDX \$DASH_MODE\"")" = "hit 24 normal" ]'
check "an empty search removes it, Esc cancels it" '[ "$(run_lib "$LS DASH_FOCUS=logs; DASH_LOG_FIND=abc; TUI_KEY=s; dash_handle_key; DASH_BUF=; TUI_KEY=enter; dash_handle_key; echo \"[\$DASH_LOG_FIND]\"; DASH_LOG_FIND=abc; TUI_KEY=s; dash_handle_key; TUI_KEY=esc; dash_handle_key; echo \"[\$DASH_LOG_FIND] \$DASH_MODE\"")" = "[]
[abc] normal" ]'
check "End and f follow the end again and resume a paused pane" '[ "$(run_lib "$LS DASH_FOCUS=logs; DASH_LS_PAUSED=1; DASH_LOG_SCROLL=7; dash_key_logs end >/dev/null; echo \"\$DASH_LS_PAUSED \$DASH_LOG_SCROLL\"")" = "0 0" ]'
check "while the search prompt is open the pane shows it, and the key bar says how it works" 'f="$(run_lib "$LS DASH_FOCUS=logs; DASH_MODE=find; DASH_BUF=abc; DASH_CUR=3; dash_render")"; echo "$f" | grep -q "~ abc|" && echo "$f" | tail -2 | grep -q "Enter busca"'
check "the key bar of the pane lists the new keys, in both languages" 'run_lib "$LS DASH_FOCUS=logs; dash_render" | last_frame | tail -2 | grep -q "Espacio pausa . f sigue . e errores" && DELTACTL_LANG=en run_lib "$LS DASH_FOCUS=logs; dash_render" | last_frame | tail -2 | grep -q "Space pause . f follow . e errors"'
check "every size draws the pane with its states inside the screen" 'for c in 120 160 300; do run_lib "COLUMNS=$c; DELTACTL_TUI_ROWS=30; tui_size; dash_init; dash_refresh; mt_sample; dash_current_target; $CLASSY DASH_FOCUS=logs; DASH_LS_PAUSED=1; DASH_LS_PEND=12; DASH_LOG_ERRONLY=1; DASH_LOG_FIND=boom; DASH_LOG_FILTER=o; dash_render" | while IFS= read -r l; do [ "${#l}" -le "$c" ] || echo "WIDE:$c"; done; done | grep -q WIDE && exit 1; exit 0'
check "a text from the log with control characters never reaches the screen, in the stream or in the search" '! run_lib "$LS printf \"a\033[2Jb\033]0;x\007c\nERROR \033[31mred\n\" > $FIX/stream3.txt; DELTACTL_TUI_LOGSTREAM=$FIX/stream3.txt; dash_ls_tick; DASH_LOG_FIND=red; dash_render" | grep -q "$ESC"'

section "21. the logs pane: what a review found"
printf '    indented\n\ttabbed\n' > "$FIX/stream4.txt"
: > "$FIX/empty.txt"
seq -f "l%g" 1 5000 > "$FIX/big.txt"
check "the indentation of a streamed line is kept (stack traces, pretty-printed JSON)" '[ "$(run_lib "$LS DELTACTL_TUI_LOGSTREAM=$FIX/stream4.txt; dash_ls_tick; printf \"[%s]\" \"\${DASH_LS_RING[0]}\"")" = "[    indented]" ]'
touch "$FIX/logs_partial"
check "a line that is still being written is kept for the next time: the stream is not taken for dead and nothing is lost" '[ "$(run_lib "$LS dash_ls_tick; sleep 0.15; dash_ls_tick; a=\"\${#DASH_LS_RING[@]} \$([ -n \"\$DASH_LS_FD\" ] && echo open || echo closed) [\$DASH_LS_PART]\"; sleep 0.6; dash_ls_tick; echo \"\$a|\${DASH_LS_RING[0]}|\$DASH_LS_ENDED\"")" = "0 open [par]|partial|1" ]'
rm -f "$FIX/logs_partial"
check "a stream that ends by itself is seen: its lines are all there, and it is closed with nothing left to kill" '[ "$(run_lib "$LS dash_ls_tick; sleep 0.6; dash_ls_tick; echo \"[\$DASH_LS_FD][\$DASH_LS_PID][\$DASH_LS_ENDED][\${#DASH_LS_RING[@]}]\"")" = "[][][1][2]" ]'
check "and the pane is polled again after that" '[ "$(run_lib "$LS dash_ls_tick; sleep 0.6; dash_ls_tick; dash_ls_active tui-a/s0 && echo active || echo polling")" = "polling" ]'
check "a service with no log is told so, and not left on \"loading\"" '[ "$(run_lib "$LS unset DASH_LOGS_AT[tui-a/s0]; DELTACTL_TUI_LOGSTREAM=$FIX/empty.txt; dash_ls_tick; dash_ls_tick; dash_logs_box tui-a/s0 s0 60 8; printf \"%s\n\" \"\${TUI_BOX[@]}\" | grep -c \"Sin líneas de log\"")" = "1" ]'
check "while the user reads older lines the pane stands still, and catches up when it follows the end again" '[ "$(run_lib "$LS DASH_LOG_SCROLL=3; DELTACTL_TUI_LOGSTREAM=$FIX/stream1.txt; dash_ls_tick; case \"\${DASH_LOGS[tui-a/s0]}\" in *\"line 30 ok\"*) echo still ;; *) echo moved ;; esac; DASH_LOG_SCROLL=0; dash_ls_tick; case \"\${DASH_LOGS[tui-a/s0]}\" in *\"first line\"*) echo caught-up ;; *) echo late ;; esac")" = "still
caught-up" ]'
check "submitting a filter forgets the position of the search" '[ "$(run_lib "$LS DASH_FOCUS=logs; DASH_MODE=filter; DASH_BUF=x; DASH_CUR=1; DASH_LOG_MIDX=5; TUI_KEY=enter; dash_handle_key; echo \$DASH_LOG_MIDX")" = "-1" ]'
check "the ring is cut in steps, keeping the newest lines, and what was published moves with it" '[ "$(run_lib "DASH_LS_MAX=100; DASH_LS_RING=(\$(seq 1 301)); DASH_LS_PUB=250; dash_ls_trim; echo \"\${#DASH_LS_RING[@]} \$DASH_LS_PUB \$DASH_LS_CUT \${DASH_LS_RING[0]}\"; DASH_LS_MAX=10; DASH_LS_RING=(\$(seq 1 300)); DASH_LS_PUB=250; DASH_LS_CUT=0; dash_ls_trim; echo \"\${#DASH_LS_RING[@]} \$DASH_LS_PUB \$DASH_LS_CUT \${DASH_LS_RING[0]}\"")" = "100 49 201 202
10 0 290 291" ]'
check "a ring that is not over its limit by a margin is left alone" '[ "$(run_lib "DASH_LS_MAX=100; DASH_LS_RING=(\$(seq 1 250)); DASH_LS_PUB=10; dash_ls_trim; echo \"\${#DASH_LS_RING[@]} \$DASH_LS_CUT\"")" = "250 0" ]'
check "the position of the search moves when lines leave from the front (and is forgotten with a filter on)" '[ "$(run_lib "$LS DASH_LS_KEY=tui-a/s0; DASH_LS_RING=(a b c); DASH_LOG_MIDX=50; DASH_LS_CUT=20; dash_ls_publish; printf \"%s \" \$DASH_LOG_MIDX; DASH_LOG_MIDX=50; DASH_LS_CUT=20; DASH_LOG_ERRONLY=1; dash_ls_publish; printf \"%s \" \$DASH_LOG_MIDX; DASH_LOG_ERRONLY=0; DASH_LOG_MIDX=5; DASH_LS_CUT=20; dash_ls_publish; printf \"%s\" \$DASH_LOG_MIDX")" = "30 -1 -1" ]'
check "moving the selection stops the old stream at once but does not start another within 300 ms" '[ "$(run_lib "$LS DELTACTL_TUI_LOGSTREAM=$FIX/stream1.txt; dash_ls_tick; DASH_SVC=1; dash_current_target; dash_ls_tick; echo \"[\$DASH_LS_KEY][\$DASH_LS_FD][\$DASH_LS_DEFER]\"; sleep 0.4; dash_ls_tick; echo \$DASH_LS_KEY")" = "[][][1]
tui-a/s1" ]'
check "the loop comes back soon when a start was deferred or a log was left half read" 'grep -q "DASH_LS_DEFER" lib/cmd/dashboard.sh && grep -q "DASH_LS_MORE" lib/cmd/dashboard.sh'
check "a log that grows faster than one turn can read is read over several turns, and the newest lines are the ones kept" '[ "$(run_lib "$LS DELTACTL_TUI_LOGSTREAM=$FIX/big.txt; for i in \$(seq 1 80); do dash_ls_tick; [ \"\$DASH_LS_ENDED\" -eq 1 ] && break; done; echo \"\$DASH_LS_ENDED \${DASH_LS_RING[\$((\${#DASH_LS_RING[@]} - 1))]} \$((\${#DASH_LS_RING[@]} <= 1700))\"")" = "1 l5000 1" ]'
check "the drain stops after 100 ms and says there is more" 'run_lib "$LS DELTACTL_TUI_LOGSTREAM=$FIX/big.txt; dash_ls_tick; echo more=\$DASH_LS_MORE ring=\${#DASH_LS_RING[@]}" | grep -qE "more=1 ring=[0-9]+" || run_lib "$LS DELTACTL_TUI_LOGSTREAM=$FIX/big.txt; dash_ls_tick; echo ended=\$DASH_LS_ENDED" | grep -q "ended=1"'
rm -f "$FIX/stream4.txt" "$FIX/empty.txt" "$FIX/big.txt"

section "22. the logs stream goes through a file"
touch "$FIX/logs_many"
check "3000 lines from a real stream arrive in order, with none lost or repeated among the ones kept" '[ "$(run_lib "$LS for i in \$(seq 1 80); do dash_ls_tick; [ \"\$DASH_LS_ENDED\" -eq 1 ] && break; sleep 0.1; done; echo \"\$DASH_LS_ENDED \${DASH_LS_RING[\$((\${#DASH_LS_RING[@]} - 1))]} \$(printf \"%s\n\" \"\${DASH_LS_RING[@]}\" | sort -u | wc -l | tr -d \" \") \${#DASH_LS_RING[@]}\"")" = "1 n3000 1700 1700" ] || [ "$(run_lib "$LS for i in \$(seq 1 80); do dash_ls_tick; [ \"\$DASH_LS_ENDED\" -eq 1 ] && break; sleep 0.1; done; echo \"\$DASH_LS_ENDED \${DASH_LS_RING[\$((\${#DASH_LS_RING[@]} - 1))]}\"; a=(\"\${DASH_LS_RING[@]}\"); u=\$(printf \"%s\n\" \"\${a[@]}\" | sort -u | wc -l | tr -d \" \"); [ \"\$u\" = \"\${#a[@]}\" ] && echo unique")" = "1 n3000
unique" ]'
rm -f "$FIX/logs_many"
check "the file of the stream is removed when it is stopped, and the process with it" '[ "$(touch $FIX/logs_block; run_lib "$LS dash_ls_tick; f=\$DASH_LS_FILE; pid=\$DASH_LS_PID; [ -f \$f ] && echo file; dash_ls_stop; sleep 0.2; [ -f \$f ] && echo left || echo removed; kill -0 \$pid 2>/dev/null && echo alive || echo dead"; rm -f $FIX/logs_block)" = "file
removed
dead" ]'
check "a process that is killed is not announced on the screen (no Terminated notice from bash)" '[ "$(touch $FIX/logs_block; run_lib "$LS dash_ls_tick; sleep 0.2; dash_ls_stop; sleep 0.3; echo done"; rm -f $FIX/logs_block)" = "done" ]'
check "the pane is updated every 2 s when it is only there to be looked at, every second when it has the focus" '[ "$(run_lib "$LS DELTACTL_TUI_LOGSTREAM=$FIX/stream1.txt; SECONDS=7; dash_ls_tick; n=\$DASH_LOGS_N; SECONDS=8; DASH_LS_FRESH=1; dash_ls_tick; a=\$((DASH_LOGS_N - n)); SECONDS=9; DASH_LS_FRESH=1; dash_ls_tick; b=\$((DASH_LOGS_N - n)); echo \"\$a \$b\"")" = "0 1" ] && [ "$(run_lib "$LS DASH_FOCUS=logs; DELTACTL_TUI_LOGSTREAM=$FIX/stream1.txt; SECONDS=7; dash_ls_tick; n=\$DASH_LOGS_N; SECONDS=8; DASH_LS_FRESH=1; dash_ls_tick; echo \$((DASH_LOGS_N - n))")" = "1" ]'
check "the file is cut when it grows past its limit and everything in it was read, and the reading goes on from the start" '[ "$(run_lib "$LS printf \"a1\na2\na3\n\" > $FIX/rot.txt; DASH_LS_KEY=tui-a/s0; DASH_LS_FILE=$FIX/rot.txt; exec {DASH_LS_FD}< $FIX/rot.txt; DASH_LS_LIMIT=5; dash_ls_drain; a=\"\${#DASH_LS_RING[@]} \$([ -s $FIX/rot.txt ] && echo full || echo empty) \$DASH_LS_BYTES\"; printf \"b1\nb2\n\" >> $FIX/rot.txt; dash_ls_drain; echo \"\$a|\${DASH_LS_RING[*]}|\$DASH_LS_BYTES\"")" = "3 empty 0|a1 a2 a3 b1 b2|0" ]'
check "a line cut in two by the end of what is written is not lost when the file is cut" '[ "$(run_lib "$LS printf \"x1\npar\" > $FIX/rot2.txt; DASH_LS_KEY=tui-a/s0; DASH_LS_FILE=$FIX/rot2.txt; exec {DASH_LS_FD}< $FIX/rot2.txt; DASH_LS_LIMIT=1; dash_ls_drain; a=\"[\$DASH_LS_PART] \$([ -s $FIX/rot2.txt ] && echo full || echo empty)\"; printf \"tial\n\" >> $FIX/rot2.txt; dash_ls_drain; echo \"\$a|\${DASH_LS_RING[*]}\"")" = "[par] full|x1 partial" ]'
rm -f "$FIX/rot.txt" "$FIX/rot2.txt"

section "23. the Options screen: theme, language, intervals and vim keys, remembered in the config file"
export DELTACTL_CONFIG="$FIX/opts.cfg"
rm -f "$FIX/opts.cfg"
out="$(panel o q q)"
check "o opens the Options screen with every option and its current value" 'f="$(echo "$out" | frame_n 2)"; echo "$f" | grep -q "Opciones" && echo "$f" | grep -qE "> Tema +<matrix>" && echo "$f" | grep -qE "Idioma +espa" && echo "$f" | grep -qE "Muestreo de cifras +2 s" && echo "$f" | grep -qE "Relectura del estado +5 s" && echo "$f" | grep -qE "Teclas vim +s"'
check "the Options screen lists its keys and says where it saves" 'echo "$out" | frame_n 2 | grep -q "Up/Dn elegir . Lt/Rt cambiar" && echo "$out" | frame_n 2 | grep -q "Se guarda en .*opts.cfg"'
check "q closes the Options screen" '! echo "$out" | frame_n 3 | grep -q "Teclas vim" && echo "$out" | frame_n 3 | grep -q "\[1 Instancias\]"'
check "opening and closing the screen writes nothing" '[ ! -e "$FIX/opts.cfg" ]'
out="$(panel o down down right down right down right esc q)"
check "the arrows change the intervals and the vim keys, and each change is remembered" 'grep -qx "TUI_SAMPLE=3" "$FIX/opts.cfg" && grep -qx "TUI_REFRESH=10" "$FIX/opts.cfg" && grep -qx "TUI_VIM=off" "$FIX/opts.cfg"'
check "a change says what it set" 'echo "$out" | frame_n 5 | grep -q "Muestreo de cifras: 3 s"'
out="$(panel o q q)"
check "the next panel starts with the remembered values" 'f="$(echo "$out" | frame_n 2)"; echo "$f" | grep -qE "Muestreo de cifras +3 s" && echo "$f" | grep -qE "Relectura del estado +10 s" && echo "$f" | grep -qE "Teclas vim +no"'
out="$(panel j j q)"
check "with the vim keys off, j does not move the selection" 'echo "$out" | frame_n 3 | grep -q "^| > .. tui-a"'
out="$(panel down q)"
check "with the vim keys off, the arrows still move it" 'echo "$out" | frame_n 2 | grep -q "^| > .. tui-b"'
out="$(panel o j right q q)"
check "with the vim keys off, j does not move inside Options either" 'grep -q "^UI_THEME=cyber$" "$FIX/opts.cfg"'
out="$(panel o left q q)"
check "left goes back through the themes and wraps" 'grep -q "^UI_THEME=matrix$" "$FIX/opts.cfg" && out2="$(panel o left q q)" && grep -q "^UI_THEME=mono$" "$FIX/opts.cfg"'
out="$(panel o down down down right right right right right right right right q q)"
check "an interval stops at the end of its list" 'grep -qx "TUI_REFRESH=60" "$FIX/opts.cfg"'
# tests/run.sh fixes DELTACTL_LANG=es: without it the remembered language is the one the panel starts with.
out="$(unset DELTACTL_LANG; panel o down right q q)"
check "the language changes from the Options screen and the screen follows it" 'grep -qx "UI_LANG=en" "$FIX/opts.cfg" && echo "$out" | frame_n 4 | grep -q "Options" && echo "$out" | frame_n 4 | grep -qE "Language +<English>"'
out="$(unset DELTACTL_LANG; panel o down right q q)"
check "the next panel starts in the remembered language, and back to Spanish" 'echo "$out" | frame_n 2 | grep -q "Options" && grep -qx "UI_LANG=es" "$FIX/opts.cfg"'
out="$(panel o down q q)"
check "with DELTACTL_LANG set the screen says the variable wins at start" 'echo "$out" | frame_n 3 | grep -q "DELTACTL_LANG manda al arrancar"'
out="$(DELTACTL_REFRESH=7 panel o down down down q q)"
check "a variable wins at start, and the screen says it fixes that option" 'f="$(echo "$out" | frame_n 5)"; echo "$f" | grep -qE "Relectura del estado +<7 s>" && echo "$f" | grep -q "DELTACTL_REFRESH manda al arrancar"'
check "the option fixed by a variable is not marked when the cursor is on another one" '! echo "$out" | frame_n 2 | grep -q "manda al arrancar"'
out="$(DELTACTL_METRICS_INTERVAL=120 panel o down down q q)"
check "a variable keeps the range its own layer accepts (2 minutes between samples)" 'echo "$out" | frame_n 4 | grep -qE "Muestreo de cifras +<120 s>"'
out="$(PANEL_COLS=80 DELTACTL_METRICS_INTERVAL=7 panel o down down q q)"
check "at 80 columns the long texts of the screen wrap instead of being cut" 'f="$(echo "$out" | frame_n 4)"; ! echo "$f" | awk "length(\$0) > 80 { found = 1 } END { exit !found }" && echo "$f" | grep -q "Cada cu.nto se leen memoria" && echo "$f" | grep -q "barato\.  *|" && echo "$f" | grep -q "pero vale la variable\.  *|"'
out="$(panel $'\020' o p c i o n e s enter q q)"
check "the palette opens the Options screen" 'echo "$out" | grep -q "Opciones del panel" && echo "$out" | frame_n 11 | grep -q "Teclas vim"'
out="$(PANEL_ROWS=55 panel '?' x q)"
check "the help lists the o key" 'echo "$out" | frame_n 2 | grep -q "o opciones"'

# The values come from a file anybody may have edited: only short runs of digits reach an arithmetic expansion.
printf 'TUI_SAMPLE=08\r\nTUI_REFRESH=a[$(touch %s/pwn)]\nTUI_VIM=OFF\n' "$FIX" > "$FIX/opts.cfg"
check "a leading zero is read in base 10, CRLF is ignored and the vim switch is case-insensitive" '[ "$(run_lib "dash_opts_load; echo \$MT_INTERVAL_S-\$DASH_VIM")" = "8-0" ]'
check "a value that is not a number falls back to the default and runs nothing" '[ "$(run_lib "dash_opts_load; echo \$DASH_REFRESH_SECONDS")" = "5" ] && [ ! -e "$FIX/pwn" ]'
printf 'TUI_SAMPLE=99999\nTUI_REFRESH=0\n' > "$FIX/opts.cfg"
check "values out of range fall back to the defaults" '[ "$(run_lib "dash_opts_load; echo \$MT_INTERVAL_S-\$DASH_REFRESH_SECONDS")" = "2-5" ]'
check "an invalid variable does not win over the file" '[ "$(DELTACTL_METRICS_INTERVAL=abc run_lib "printf \"TUI_SAMPLE=5\n\" > $FIX/opts.cfg; dash_opts_load; echo \$MT_INTERVAL_S")" = "5" ]'
check "the sampling interval of the panel reaches the metrics layer" '[ "$(run_lib "MT_INTERVAL_S=3; mt_interval_us")" = "3000000" ]'
check "a step from a value outside the list goes to the nearest one in that direction" '[ "$(run_lib "dash_opt_step 7 1 2 5 10; a=\$DASH_OPT_V; dash_opt_step 7 -1 2 5 10; echo \$a-\$DASH_OPT_V")" = "10-5" ]'
check "a step past either end stays there" '[ "$(run_lib "dash_opt_step 10 1 2 5 10; a=\$DASH_OPT_V; dash_opt_step 2 -1 2 5 10; echo \$a-\$DASH_OPT_V")" = "10-2" ]'
rm -f "$FIX/opts.cfg"
export DELTACTL_CONFIG="$FIX/none.cfg"

section "24. the Console view: the console over the whole body"
out="$(panel 6 esc esc q)"
check "6 opens the Console view with the line ready to type" 'f="$(echo "$out" | frame_n 2)"; echo "$f" | grep -q "\[6 Consola\]" && echo "$f" | grep -q "+- >Consola" && echo "$f" | grep -q "^| [a-z-]* > |" && echo "$f" | tail -1 | grep -q "Enter ejecuta"'
check "the console takes the whole body" '[ "$(echo "$out" | frame_n 2 | grep -c "^|.*|$")" -ge 22 ]'
check "Esc lets go of the keyboard and stays in the view, a second Esc goes back to Instances" 'echo "$out" | frame_n 3 | grep -q "\[6 Consola\]" && echo "$out" | frame_n 3 | tail -1 | grep -q "Enter o : escribe" && echo "$out" | frame_n 4 | grep -q "\[1 Instancias\]"'
out="$(panel 6 $(typed help) enter esc esc q)"
check "a command of the panel answers in the view and the line stays ready for the next one" 'f="$(echo "$out" | frame_n 7)"; echo "$f" | grep -q "CONSOLA: escribe cualquier comando" && echo "$f" | grep -q "^| [a-z-]* > |"'
out="$(panel 6 $(typed "status tui-a") enter esc wait q)"
check "a deltactl command runs in the view, without jumping to Output" 'f="$(echo "$out" | last_frame)"; echo "$out" | grep -q "> ./deltactl status tui-a" && echo "$f" | grep -q "status tui-a: termin" && echo "$f" | grep -q "\[6 Consola\]" && ! echo "$out" | grep -q "\[3 Salida\]"'
out="$(panel 6 esc enter q)"
check "Enter gives the keyboard back to the line" 'echo "$out" | frame_n 4 | grep -q "^| [a-z-]* > |" && echo "$out" | frame_n 4 | tail -1 | grep -q "Enter ejecuta"'
out="$(panel 5 tab tab tab tab tab q)"
check "Tab goes from Processes to the Console view without taking the keyboard, and on through the Server, Images and Variables views to Instances" 'echo "$out" | frame_n 3 | grep -q "\[6 Consola\]" && echo "$out" | frame_n 3 | tail -1 | grep -q "Enter o : escribe" && echo "$out" | frame_n 7 | grep -q "\[1 Instancias\]"'
out="$(panel 5 tab btab q)"
check "Shift+Tab goes back from the Console view to Processes" 'echo "$out" | frame_n 4 | grep -q "\[5 Procesos\]"'
out="$(panel : $(typed "goto console") enter q)"
check "goto console opens the view" 'echo "$out" | last_frame | grep -q "\[6 Consola\]"'
check "goto completes every view" '[ "$(run_lib "DASH_BUF=\"goto co\"; dash_complete; echo \"\$DASH_BUF\"")" = "goto console " ]'
CON='DASH_VIEW=console; TUI_ROWS=30; for i in $(seq 1 30); do DASH_CON+=("l$i"); done;'
check "PgUp moves almost a screen and stops when the first line reaches the top" '[ "$(run_lib "$CON dash_key_console pgup; a=\$DASH_CON_SCROLL; dash_key_console pgup; echo \$a-\$DASH_CON_SCROLL")" = "7-7" ]'
check "Home goes to the first line, End and PgDn back to the end" '[ "$(run_lib "$CON dash_key_console home; a=\$DASH_CON_SCROLL; dash_key_console end; b=\$DASH_CON_SCROLL; dash_key_console home; dash_key_console pgdn; echo \$a-\$b-\$DASH_CON_SCROLL")" = "7-0-0" ]'
check "the arrows move one line and never past either end" '[ "$(run_lib "$CON dash_key_console up; a=\$DASH_CON_SCROLL; dash_key_console down; dash_key_console down; echo \$a-\$DASH_CON_SCROLL")" = "1-0" ]'
out="$(PANEL_ROWS=55 panel '?' x q)"
check "the help lists the Console view" 'echo "$out" | frame_n 2 | grep -q "1-9 *Instancias .* Consola · Servidor" && echo "$out" | frame_n 2 | grep -q "^[ |]*Imágenes · Variables" && echo "$out" | frame_n 2 | grep -q "CONSOLA  6 a pantalla completa"'

section "25. aliases of the console: short names for commands, kept next to the history"
mkdir -p "$FIX/al"; rm -f "$FIX/al/"*
export DELTACTL_CONFIG="$FIX/al/config"
out="$(panel 6 $(typed "alias st=status tui-a") enter $(typed alias) enter $(typed st) enter esc wait q)"
check "alias defines one and says so" 'echo "$out" | grep -q "Alias st = status tui-a"'
check "alias alone lists them" 'echo "$out" | grep -q "^|   st=status tui-a"'
check "an alias as the first word runs its command" 'echo "$out" | grep -q "> ./deltactl status tui-a" && echo "$out" | last_frame | grep -q "status tui-a: termin"'
check "the aliases are saved next to the history, readable only by their owner" 'grep -qx "st=status tui-a" "$FIX/al/aliases" && [ "$(stat -c %a "$FIX/al/aliases")" = "600" ]'
check "the history keeps what was typed, not the expanded command" 'grep -qx "st" "$FIX/al/history"'
out="$(panel 6 $(typed "alias lg=logs tui-a") enter $(typed "lg s0") enter esc wait q)"
check "the rest of the line follows the command of the alias" 'echo "$out" | grep -q "> ./deltactl logs tui-a s0"'
out="$(panel 6 $(typed alias) enter esc q)"
check "the next panel starts with the saved aliases, in the order they were made" '[ "$(echo "$out" | last_frame | grep -c "^|   \(st\|lg\)=")" = "2" ] && echo "$out" | last_frame | grep -A1 "st=status" | grep -q "lg=logs"'
out="$(panel 6 $(typed "unalias st") enter $(typed "unalias nope") enter esc q)"
check "unalias removes one and the file follows" 'echo "$out" | grep -q "Alias st borrado" && ! grep -q "^st=" "$FIX/al/aliases" && grep -q "^lg=" "$FIX/al/aliases"'
check "unalias of a name that does not exist says so" 'echo "$out" | grep -q "No existe el alias nope"'
out="$(panel 6 $(typed "alias x=!rm -rf /") enter $(typed "alias status=list") enter $(typed "alias Bad=list") enter $(typed "alias e=") enter esc q)"
check "an alias for the terminal is refused" 'echo "$out" | grep -q "Orden no v.lida" && ! grep -q "^x=" "$FIX/al/aliases"'
check "a name that would hide a command, or with capitals, is refused" '[ "$(echo "$out" | grep -c "Nombre no v.lido: \(status\|Bad\)")" -ge 2 ] && ! grep -q "^status=\|^Bad=" "$FIX/al/aliases"'
check "an empty command is refused" '! grep -q "^e=" "$FIX/al/aliases"'
check "alias and unalias complete the names of the aliases" '[ "$(run_lib "dash_alias_load; DASH_BUF=\"unalias l\"; dash_complete; echo \"\$DASH_BUF\"")" = "unalias lg " ]'
check "the first word completes aliases too" '[ "$(run_lib "dash_alias_put zz list; DASH_BUF=z; dash_complete; echo \"\$DASH_BUF\"")" = "zz " ]'
check "an alias is replaced once: an alias inside an alias is just a word" '[ "$(run_lib "dash_alias_put a b; dash_alias_put b list; dash_alias_expand \"a x\"; echo \"\$DASH_ALIAS_LINE\"")" = "b x" ]'
# The file is data: any line that is not a valid alias is skipped, and a name is never used as code.
printf 'ok=list\r\n1bad=list\nsh=!rm -rf /\nctl=list\001\nnoequal\nstatus=list\n' > "$FIX/al/aliases"
check "invalid lines of the file are skipped" '[ "$(run_lib "dash_alias_load; echo \"\${DASH_ALIAS_NAMES[*]}\"")" = "ok" ]'
check "a name built to run code is only text" 'run_lib "dash_alias_load; dash_alias_cmd unalias \"a[\\\$(touch $FIX/pwn2)]\"; dash_alias_expand \"a[\\\$(touch $FIX/pwn3)] x\"" >/dev/null; [ ! -e "$FIX/pwn2" ] && [ ! -e "$FIX/pwn3" ]'
rm -rf "$FIX/al"
export DELTACTL_CONFIG="$FIX/none.cfg"

section "26. the mouse: clicks on the tabs and the instances, and the wheel (off unless Options turns it on)"
check "an SGR report is read as a mouse event" '[ "$(run_lib "tui_mouse_parse \"[<0;12;3M\"; echo \$TUI_KEY \$TUI_MB \$TUI_MX \$TUI_MY \$TUI_MUP")" = "mouse 0 12 3 0" ]'
check "a release is marked as such" '[ "$(run_lib "tui_mouse_parse \"[<0;12;3m\"; echo \$TUI_MUP")" = "1" ]'
check "a malformed report, or one with numbers too long, is only the key other" '[ "$(run_lib "tui_mouse_parse \"[<0;a;3M\"; a=\$TUI_KEY; tui_mouse_parse \"[<0;99999;3M\"; echo \$a-\$TUI_KEY")" = "other-other" ]'
check "turning the mouse on and off sends the SGR mode sequences" '[ "$(run_lib "unset DELTACTL_TUI_KEYS; TUI_ACTIVE=1; tui_mouse 1; tui_mouse 1; tui_mouse 0" | cat -v)" = "^[[?1000h^[[?1006h^[[?1006l^[[?1000l" ]'
check "leaving the screen turns the mouse off" 'run_lib "unset DELTACTL_TUI_KEYS; TUI_ACTIVE=1; TUI_MOUSE=1; tui_leave" | cat -v | grep -q "^\^\[\[?1006l\^\[\[?1000l"'
check "the mouse is off unless the config file turns it on" '[ "$(run_lib "dash_opts_load; echo \$TUI_MOUSE")" = "0" ]'
export DELTACTL_CONFIG="$FIX/ms.cfg"
rm -f "$FIX/ms.cfg"
out="$(panel o down down down down down right q q)"
check "Options turns the mouse on and remembers it" 'grep -qx "TUI_MOUSE=on" "$FIX/ms.cfg" && echo "$out" | frame_n 8 | grep -qE "> Rat.n +<s.>" && [ "$(run_lib "dash_opts_load; echo \$TUI_MOUSE")" = "1" ]'
rm -f "$FIX/ms.cfg"
export DELTACTL_CONFIG="$FIX/none.cfg"
out="$(panel mouse:0:21:2 q)"
check "a click on a tab opens its view" 'echo "$out" | frame_n 2 | grep -q "\[3 Salida\]"'
out="$(panel mouse:0:33:2 esc esc q)"
check "a click on the Console tab opens it ready to type, like 6" 'echo "$out" | frame_n 2 | grep -q "\[6 Consola\]" && echo "$out" | frame_n 2 | tail -1 | grep -q "Enter ejecuta"'
check "when the line is tight and the other tabs lose their spacing, the clicks follow too" '[ "$(run_lib "DASH_TAB_SHORT=2; DASH_VIEW=instances; dash_tab_at 20; a=\$DASH_TAB_I; dash_tab_at 30; echo \$a-\$DASH_TAB_I")" = "2-3" ]'
check "when the line shrinks the other tabs to their numbers, the clicks follow" '[ "$(run_lib "DASH_TAB_SHORT=1; DASH_VIEW=instances; dash_tab_at 17; a=\$DASH_TAB_I; dash_tab_at 20; echo \$a-\$DASH_TAB_I")" = "2-3" ]'
out="$(panel mouse:0:10:7 q)"
check "a click on an instance selects it" 'echo "$out" | frame_n 2 | grep -q "^| > .. tui-b"'
out="$(panel mouse:0:10:7 mouse:0:10:7 esc q)"
check "a second click on the selected instance opens its actions" '! echo "$out" | frame_n 2 | grep -q "Desplegar" && echo "$out" | frame_n 3 | grep -q "Desplegar"'
out="$(panel mouse:0:10:4 q)"
check "a click on the first row selects the New button" 'echo "$out" | frame_n 2 | grep -q "^| > + Nueva instancia"'
out="$(panel mouse:0:10:7:up mouse:2:10:7 mouse:0:70:7 q)"
check "a release, another button or a click outside the list change nothing" 'for n in 2 3 4; do echo "$out" | frame_n $n | grep -q "^| > .. tui-a" || exit 1; done'
out="$(panel mouse:4:10:7 q)"
check "a click with Shift held down is still a click" 'echo "$out" | frame_n 2 | grep -q "^| > .. tui-b"'
out="$(panel mouse:65:10:10 mouse:64:10:10 mouse:64:10:10 q)"
check "the wheel moves like the arrows" 'echo "$out" | frame_n 2 | grep -q "^| > .. tui-b" && echo "$out" | frame_n 3 | grep -q "^| > .. tui-a" && echo "$out" | frame_n 4 | grep -q "^| > + Nueva instancia"'
out="$(panel o mouse:65:10:10 mouse:0:33:2 esc q)"
check "in Options the wheel moves the cursor, and a click on a tab does nothing" 'echo "$out" | frame_n 3 | grep -qE "> Idioma" && echo "$out" | frame_n 4 | grep -q "Teclas vim" && echo "$out" | frame_n 5 | grep -q "\[1 Instancias\]"'
out="$(panel 6 esc mouse:0:10:10 esc esc q)"
check "in the Console view a click gives the line the keyboard" 'echo "$out" | frame_n 4 | tail -1 | grep -q "Enter ejecuta"'
check "on a line being typed the wheel scrolls the transcript, not the history" '[ "$(run_lib "DASH_MODE=cmd; DASH_VIEW=instances; for i in \$(seq 1 30); do DASH_CON+=(l\$i); done; TUI_MB=64; TUI_MUP=0; dash_mouse; a=\$DASH_CON_SCROLL; TUI_MB=65; dash_mouse; echo \$a-\$DASH_CON_SCROLL-\$DASH_MODE-\$DASH_BUF")" = "3-0-cmd-" ]'
out="$(PANEL_ROWS=55 panel '?' x q)"
check "the help lists the mouse" 'echo "$out" | frame_n 2 | grep -q "RAT.N    (en Opciones) clic"'

section "27. the mouse and the console: what a review found"
check "a click of a terminal without the SGR mode is dropped whole, not typed as keys" '[ "$(run_lib "unset DELTACTL_TUI_KEYS; { tui_key 1; a=\$TUI_KEY; tui_key 1; echo \"\$a-\$TUI_KEY\"; } < <(printf \"\\033[M x!q\")")" = "other-q" ]'
check "a real SGR report from the terminal is read as a mouse event" '[ "$(run_lib "unset DELTACTL_TUI_KEYS; tui_key 1 < <(printf \"\\033[<64;7;9M\"); echo \$TUI_KEY \$TUI_MB \$TUI_MX \$TUI_MY")" = "mouse 64 7 9" ]'
check "a report longer than expected is dropped up to its end" '[ "$(run_lib "unset DELTACTL_TUI_KEYS; { tui_key 1; a=\$TUI_KEY; tui_key 1; echo \"\$a-\$TUI_KEY\"; } < <(printf \"\\033[<0;123456789;1Mq\")")" = "other-q" ]'
LST='DASH_NAMES=(i0 i1 i2 i3 i4 i5 i6 i7 i8 i9);'
check "the list keeps its first row while the selection stays inside the window" '[ "$(run_lib "$LST DASH_SEL=9; dash_list_lines 7; a=\$DASH_LIST_OFF; DASH_SEL=5; dash_list_lines 7; b=\$DASH_LIST_OFF; DASH_SEL=4; dash_list_lines 7; echo \$a-\$b-\$DASH_LIST_OFF")" = "5-5-4" ]'
check "on a list too short to show an instance, no row can be clicked" '[ "$(run_lib "$LST DASH_SEL=3; dash_list_lines 2; echo \$DASH_LIST_AVAIL")" = "0" ]'
CON2='DASH_VIEW=console; TUI_ROWS=30; for i in $(seq 1 40); do DASH_CON+=("l$i"); done;'
check "someone reading older lines keeps them while new ones arrive" '[ "$(run_lib "$CON2 DASH_CON_SCROLL=5; dash_con_add new; a=\$DASH_CON_SCROLL; DASH_CON_SCROLL=0; dash_con_add new2; echo \$a-\$DASH_CON_SCROLL")" = "6-0" ]'
check "a new command shows its output from its start" '[ "$(run_lib "$CON2 DASH_CON_SCROLL=5; DASH_BUF=refresh; dash_submit_cmd; echo \$DASH_CON_SCROLL")" = "0" ]'
mkdir -p "$FIX/al2"; mkfifo "$FIX/al2/aliases"
check "an aliases file that is not a regular file is never read (a pipe would block)" '[ "$(DELTACTL_CONFIG="$FIX/al2/config" timeout 5 bash -c "ROOT=\"$PWD\" DELTACTL_TUI_KEYS=/dev/null bash -c \"source lib/bootstrap.sh; source lib/cmd/dashboard.sh; dash_alias_load; echo ok\"")" = "ok" ]'
rm -f "$FIX/al2/aliases"; mkdir "$FIX/al2/aliases"
check "an aliases path that is a directory is not taken for a saved file" '! DELTACTL_CONFIG="$FIX/al2/config" run_lib "dash_alias_put x list; dash_alias_save" && [ -z "$(ls -A "$FIX/al2/aliases")" ]'
rm -rf "$FIX/al2"

section "28. the layout engine and the per-panel cache"
# A wide Overview with the state loaded; then each piece that should not be drawn again is replaced by a counter.
WIDE='COLUMNS=160; DELTACTL_TUI_ROWS=40; tui_size; dash_init; dash_refresh; mt_reset; mt_sample; dash_host_build; dash_render >/dev/null;'
COUNT='PC_CALLS=0; dash_list_lines() { PC_CALLS=$((PC_CALLS + 1)); }; dash_host_box() { PC_CALLS=$((PC_CALLS + 10)); }; dash_center_top() { PC_CALLS=$((PC_CALLS + 100)); };'
check "a log line draws the logs box again, not the list, the server or the centre" '[ "$(run_lib "$WIDE $COUNT DASH_LOGS_N=\$((DASH_LOGS_N + 1)); dash_render >/dev/null; echo \$PC_CALLS")" = "0" ]'
check "a typed character draws only the console" '[ "$(run_lib "$WIDE $COUNT DASH_MODE=cmd; DASH_BUF=st; DASH_CUR=2; dash_render >/dev/null; DASH_BUF=sta; DASH_CUR=3; dash_render >/dev/null; echo \$PC_CALLS")" = "0" ]'
check "a sample draws the list, the server and the centre again" '[ "$(run_lib "$WIDE $COUNT MT_SAMPLES=\$((MT_SAMPLES + 1)); dash_render >/dev/null; echo \$PC_CALLS")" = "111" ]'
check "a new state of Docker draws them again too" '[ "$(run_lib "$WIDE $COUNT DASH_REFRESH_N=\$((DASH_REFRESH_N + 1)); dash_render >/dev/null; echo \$PC_CALLS")" = "111" ]'
check "moving the selection draws the list and the centre, not the server" '[ "$(run_lib "$WIDE $COUNT DASH_SEL=1; dash_render >/dev/null; echo \$PC_CALLS")" = "101" ]'
check "a new theme or language draws everything again" '[ "$(run_lib "$WIDE $COUNT DASH_LANG_N=\$((DASH_LANG_N + 1)); dash_render >/dev/null; echo \$PC_CALLS")" = "111" ]'
check "the narrow view caches the list and the detail the same way" '[ "$(run_lib "COLUMNS=110; DELTACTL_TUI_ROWS=30; tui_size; dash_init; dash_refresh; dash_render >/dev/null; PC_CALLS=0; dash_list_lines() { PC_CALLS=\$((PC_CALLS + 1)); }; dash_detail_box() { PC_CALLS=\$((PC_CALLS + 10)); }; DASH_MODE=cmd; DASH_BUF=x; dash_render >/dev/null; a=\$PC_CALLS; MT_SAMPLES=\$((MT_SAMPLES + 1)); dash_render >/dev/null; echo \$a-\$PC_CALLS")" = "0-11" ]'
check "the logs under a cached centre keep their instance even when its name has a space" 'o="$(run_lib "DASH_NAMES=(\"my inst\"); DASH_SVCS[\"my inst\"]=\"s0 s1\"; DASH_SEL=0; DASH_SVC=1; dash_logs_box() { LOG_ARGS+=\"[\$1|\$2|\$4]\"; TUI_BOX=(); }; LOG_ARGS=; dash_center_boxes \"my inst\" 82 30; dash_center_boxes \"my inst\" 82 30; echo \"\$LOG_ARGS\"")"; [[ "$o" =~ ^\[(my\ inst/s1\|s1\|[0-9]+)\]\[(.*)\]$ ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]'
check "a cached list brings back the rows it shows, for the mouse" '[ "$(run_lib "dash_refresh; dash_list_box 38 10 35 1 >/dev/null; a=\"\$DASH_LIST_START \$DASH_LIST_AVAIL\"; DASH_LIST_START=99; DASH_LIST_AVAIL=99; dash_list_box 38 10 35 1 >/dev/null; echo \"\$a|\$DASH_LIST_START \$DASH_LIST_AVAIL\"")" = "0 6|0 6" ]'
check "the Overview still has its three columns and the console under them" 'f="$(PANEL_COLS=160 panel q | frame_n 1)"; echo "$f" | grep -q "+- >Instancias" && echo "$f" | grep -q "+- Eventos" && echo "$f" | grep -q "+- Consola" && ! echo "$f" | awk "length(\$0) > 160 { found = 1 } END { exit !found }"'


section "29. the key bars and the help fit the screen"
check "a key bar too long loses whole items from before the last two" '[ "$(run_lib "dash_keyfit \"uno · dos · tres · cuatro · ayuda · salir\" 30; echo \"\$DASH_KF\"")" = "uno · dos · ayuda · salir" ]'
check "a key bar that fits is left as it is" '[ "$(run_lib "dash_keyfit \"uno · dos\" 30; echo \"\$DASH_KF\"")" = "uno · dos" ]'
check "when nothing else is enough, the items from the start that fit stay" '[ "$(run_lib "dash_keyfit \"uno · dos · tres\" 8; echo \"\$DASH_KF\"")" = "uno" ]'
for w in 60 80 100; do
  out="$(PANEL_COLS=$w panel z q)"
  check "at $w columns the zoom keys fit and end with whole items" 'l="$(echo "$out" | frame_n 2 | tail -1)"; [ "${#l}" -le '"$w"' ] && echo "$l" | grep -q "q salir$"'
  out="$(PANEL_COLS=$w panel : esc q)"
  check "at $w columns the keys of the console line fit and still say how to leave it" 'l="$(echo "$out" | frame_n 2 | tail -1)"; [ "${#l}" -le '"$w"' ] && echo "$l" | grep -q "Esc vuelve$"'
done
out="$(PANEL_COLS=160 panel right right q)"
check "on a wide screen the logs keys are not cut" 'echo "$out" | frame_n 3 | tail -1 | grep -q "Espacio pausa . f sigue . e errores . / filtro .*q salir$"'
out="$(PANEL_COLS=60 panel '?' down end x q)"
check "at 60 columns no line of the help passes the screen, and long ones go on under their description" '! echo "$out" | frame_n 2 | awk "length(\$0) > 60 { found = 1 } END { exit !found }" && echo "$out" | frame_n 2 | grep -qE "^ \| {20,}[^ ].*saltan\) *\|$"'
check "the help says which lines it shows, and the arrows move it" 'echo "$out" | frame_n 2 | grep -q "Teclas . 1-22/" && echo "$out" | frame_n 3 | grep -q "Teclas . 2-23/"'
check "End shows its last lines" 'echo "$out" | frame_n 4 | grep -q "GENERAL"'
check "any other key goes back" 'echo "$out" | frame_n 5 | grep -q "\[1 Instancias\]"'
check "while it scrolls, the last line says how" 'echo "$out" | frame_n 2 | tail -1 | grep -q "PgUp PgDn desplazan . otra tecla vuelve"'
out="$(PANEL_ROWS=55 panel '?' down q)"
check "when it fits, any key goes back, the arrows too" 'echo "$out" | frame_n 2 | tail -1 | grep -q "Pulsa cualquier tecla para volver" && echo "$out" | frame_n 3 | grep -q "\[1 Instancias\]"'
out="$(PANEL_COLS=60 panel 4 '?' q)"
check "opened from a view, it shows the keys of that view" 'echo "$out" | frame_n 3 | grep -q "EJECUC\." && ! echo "$out" | frame_n 3 | grep -q "Teclas . 1-22/"'
out="$(PANEL_ROWS=55 panel '?' q)"
check "the help has a section for the Resources view" 'echo "$out" | frame_n 2 | grep -q "RECURSOS .* s ordena"'
out="$(PANEL_COLS=60 panel '?' mouse:65:10:10 q)"
check "the wheel scrolls the help when it does not fit" 'echo "$out" | frame_n 3 | grep -q "Teclas . 2-23/"'
check "with colours on, the highlighted heading wraps like the others" '[ "$(ROOT="$PWD" DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=always COLUMNS=60 bash -c "source lib/bootstrap.sh; source lib/cmd/dashboard.sh; tui_size; dash_init; DASH_VIEW=output; DASH_MODE=help; DASH_HELP_OFF=-1; dash_dialog_help 26; for l in \"\${DASH_DLG[@]}\"; do tui_strip_ansi \"\$l\"; echo \"\$TUI_OUT\"; done" | grep -A1 "^  SALIDA" | tail -1 | grep -c "^           · v resumen o salida cruda · e solo errores$")" = "1" ]'
printf 'TUI_VIM=off\n' > "$FIX/vim.cfg"
out="$(DELTACTL_CONFIG="$FIX/vim.cfg" PANEL_ROWS=55 panel '?' j q)"
check "with the vim keys off, j is a key like any other in the help: it goes back" 'echo "$out" | frame_n 3 | grep -q "\[1 Instancias\]"'
rm -f "$FIX/vim.cfg"

section "30. the screen registry: a screen is one file and one line"
R7="$FIX/r7"
mkdir -p "$R7/instances"
cp -r deltactl lib templates services compose.yaml "$R7/"
cat > "$R7/lib/screens/demo.sh" <<'DEMO'
scr_demo_render() { local i; for ((i = 0; i < $2; i++)); do TUI_FRAME+=("  demo screen line $i of width $1"); done; } # width height
scr_demo_key() { :; }
scr_demo_keys() { TUI_FRAME+=(" demo keys"); }
scr_demo_sig() { DASH_SIG+="|demo"; }
DEMO
sed -i 's/^dash_screen_register env tui.tab.env 0$/dash_screen_register demo tui.tab.output 0/' "$R7/lib/screens/registry.sh"   # (the ninth tab is the last one a digit can open: the demo takes its place)
panel7() { printf '%s\n' "$@" > "$FIX/keys7.txt"; (cd "$R7" && DELTACTL_TUI_KEYS="$FIX/keys7.txt" DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_ASCII=1 COLUMNS=100 DELTACTL_TUI_ROWS=30 bash ./deltactl 2>&1); }
out="$(panel7 9 q)"
check "a screen registered with one line gets the next tab number and the digit opens it" 'echo "$out" | frame_n 2 | grep -q "demo screen line 0 of width 100" && echo "$out" | frame_n 2 | sed -n 3p | grep -q "\[9 Salida\]"'
check "its key line is the one its contract draws" 'echo "$out" | frame_n 2 | tail -1 | grep -q "demo keys"'
check "the body is exactly as tall as the body of any other view" '[ "$(echo "$out" | frame_n 2 | grep -c "demo screen line")" -eq 26 ]'
out="$(panel7 8 tab tab q)"
check "Tab goes from the last view to the new one and on to the first" 'echo "$out" | frame_n 3 | grep -q "demo screen line 0" && echo "$out" | frame_n 4 | grep -q "\[1 Instancias\]"'
out="$(panel7 9 esc q)"
check "Esc leaves a screen with no back step for the first view" 'echo "$out" | frame_n 3 | grep -q "\[1 Instancias\]"'
out="$(panel7 0 q)"
check "a digit with no screen is ignored (there are nine screens now: 0 is none)" 'echo "$out" | frame_n 2 | grep -q "\[1 Instancias\]"'
rm -rf "$R7"

finish

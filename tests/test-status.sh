#!/usr/bin/env bash
# Tests de ./deltactl status: panel, detalle, --json, --strict y detección de desajustes.
# Usa un `docker` simulado y determinista (contenedores, imágenes y estadísticas de mentira), así que no
# necesita Docker real. Se ejecuta desde la raíz de la copia aislada (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS

FIX="$(mktemp -d)"
export FIX
trap 'rm -rf "$FIX" instances/st-*' EXIT
rm -rf instances/st-*
mkdir -p "$FIX/bin"
: > "$FIX/containers.txt"; : > "$FIX/images.txt"; : > "$FIX/stats.txt"

# docker simulado: solo los subcomandos que usa status.
cat > "$FIX/bin/docker" <<'SHIM'
#!/usr/bin/env bash
[ -f "$FIX/nodocker" ] && exit 1
case "$1" in
  info) exit 0 ;;
  ps) n=$(wc -l < "$FIX/containers.txt"); for ((i = 1; i <= n; i++)); do echo "c$i"; done ;;
  inspect) cat "$FIX/containers.txt" ;;
  stats) cat "$FIX/stats.txt" ;;
  logs) echo "Nest ERROR de prueba"; echo "linea normal" ;;
  image)
    ref="${*: -1}"
    line="$(grep -F "$ref|" "$FIX/images.txt" | head -n1)"
    [ -n "$line" ] || exit 1
    case "$*" in *"{{.Id}}"*) echo "${line#*|}" ;; esac
    ;;
  *) exit 0 ;;
esac
SHIM
chmod +x "$FIX/bin/docker"
export PATH="$FIX/bin:$PATH"

started() { date -u -d "$1 ago" +%Y-%m-%dT%H:%M:%S.000000000Z; }
# container proj svc state health image ago
container() { printf '%s|%s|%s|%s|%s|%s|/%s_%s\n' "$1" "$2" "$3" "$4" "$5" "$(started "$6")" "$2" "$1" >> "$FIX/containers.txt"; }
image() { printf '%s|%s\n' "$1" "$2" >> "$FIX/images.txt"; }
deployed() { # instancia svc tag id
  local up="${2^^}"
  printf '%s_TAG=%s\n%s_IMAGE_ID=%s\n' "$up" "$3" "$up" "$4" >> "instances/$1/.deployed"
}
newinst() { # nombre s0tag s1tag [servicios]
  bash ./deltactl new "$1" ${4:+--services "$4"} >/dev/null 2>&1
  fill_instance "instances/$1" "$2" "$3"
  : > "instances/$1/.initialized"
  printf 'SOURCE=init\nINITIALIZED_AT=2026-01-01T00:00:00Z\n' > "instances/$1/.initialized"
}
status() { bash ./deltactl status "$@" 2>&1; }

section "1. instancia sana"
newinst st-ok 1.0 1.0
image auth-backend:1.0 sha256:aaa; image gueo-back-end:1.0 sha256:bbb
deployed st-ok s0 1.0 sha256:aaa; deployed st-ok s1 1.0 sha256:bbb
container st-ok s0 running healthy auth-backend:1.0 "2 hours"
container st-ok s1 running healthy gueo-back-end:1.0 "3 days"
out="$(status)"
check "muestra la instancia con sus dos servicios" 'echo "$out" | grep -v "^  Instancias:" | grep -c "st-ok" | grep -qx 2'
check "ambos servicios healthy" '[ "$(echo "$out" | grep "st-ok" | grep -c healthy)" -eq 2 ]'
check "uptime en horas y en días" 'echo "$out" | grep -q "2h0[0-9]m" && echo "$out" | grep -q "3d00h"'
check "pie: todo en orden" 'echo "$out" | grep -q "todo en orden"'
check "sin avisos no hay siguientes pasos" '! echo "$out" | grep -q "Siguientes pasos"'
check "--strict devuelve 0 si todo está bien" 'bash ./deltactl status --strict >/dev/null 2>&1'
check "la salida plana no lleva escapes" '! echo "$out" | has_ansi'

section "2. etiqueta configurada distinta de la que corre"
newinst st-drift 1.0 2.0
image auth-backend:1.0 sha256:a1; image gueo-back-end:2.0 sha256:b2; image gueo-back-end:1.0 sha256:b1
deployed st-drift s0 1.0 sha256:a1; deployed st-drift s1 1.0 sha256:b1
container st-drift s0 running healthy auth-backend:1.0 "1 hour"
container st-drift s1 running healthy gueo-back-end:1.0 "1 hour"
out="$(status)"
check "detecta el desajuste de s1" 'echo "$out" | grep -q "configurada 2.0 pero corre 1.0"'
check "sugiere desplegar solo ese servicio" 'echo "$out" | grep -q "./deltactl deploy st-drift s1"'
check "el pie cuenta los avisos" 'echo "$out" | grep -q "con avisos"'
bash ./deltactl status --strict >/dev/null 2>&1; rc=$?
check "--strict devuelve exactamente 2 si hay avisos" '[ "$rc" -eq 2 ]'

section "3. imagen reconstruida con la misma etiqueta"
newinst st-rebuilt 3.0 3.0
image auth-backend:3.0 sha256:NEW; image gueo-back-end:3.0 sha256:g3
deployed st-rebuilt s0 3.0 sha256:OLD; deployed st-rebuilt s1 3.0 sha256:g3
container st-rebuilt s0 running healthy auth-backend:3.0 "1 hour"
container st-rebuilt s1 running healthy gueo-back-end:3.0 "1 hour"
out="$(status st-rebuilt)"
check "avisa que la etiqueta apunta a otra imagen" 'echo "$out" | grep -q "apunta a otra imagen"'
check "solo s0 queda marcado" '! echo "$out" | grep -A3 "Servicio s1" | grep -q "otra imagen"'

section "4. imagen que falta en este servidor"
newinst st-noimg 9.9 9.9
out="$(status)"
check "avisa de la imagen faltante" 'echo "$out" | grep -q "falta la imagen auth-backend:9.9"'
check "sugiere ./deltactl load" 'echo "$out" | grep -q "./deltactl load"'
check "sin contenedor se muestra como no creado" 'echo "$out" | grep "st-noimg" | grep -q "no creado"'

section "5. estados de salud y contenedores detenidos"
newinst st-health 4.0 4.0
image auth-backend:4.0 sha256:h0; image gueo-back-end:4.0 sha256:h1
deployed st-health s0 4.0 sha256:h0; deployed st-health s1 4.0 sha256:h1
container st-health s0 running unhealthy auth-backend:4.0 "10 minutes"
container st-health s1 exited none gueo-back-end:4.0 "10 minutes"
out="$(status st-health)"
check "s0 unhealthy" 'echo "$out" | grep -q "unhealthy"'
check "s1 detenido" 'echo "$out" | grep -q "detenido"'
check "sugiere ver los logs de s0" 'echo "$out" | grep -q "./deltactl logs st-health s0"'
check "sugiere levantar s1" 'echo "$out" | grep -q "./deltactl deploy st-health s1"'

section "6. servicio que corre fuera de COMPOSE_PROFILES"
newinst st-orph 5.0 5.0 s0
image auth-backend:5.0 sha256:o0
deployed st-orph s0 5.0 sha256:o0
container st-orph s0 running healthy auth-backend:5.0 "1 hour"
container st-orph s1 running healthy gueo-back-end:5.0 "1 hour"
out="$(status)"
check "detecta el servicio fuera de perfil" 'echo "$out" | grep -q "fuera de perfil"'
check "sugiere detenerlo" 'echo "$out" | grep -q "./deltactl stop st-orph s1"'

section "7. puerto repetido entre instancias"
newinst st-pa 6.0 6.0 s0
newinst st-pb 6.0 6.0 s0
sed -i 's/^S0_PORT=.*/S0_PORT=4999/' instances/st-pa/.env.instance instances/st-pb/.env.instance
out="$(status)"
check "marca el puerto repetido" 'echo "$out" | grep -q "puerto 4999 repetido"'

section "8. datos sin sembrar"
newinst st-nodata 7.0 7.0 s1
rm -f instances/st-nodata/.initialized
out="$(status)"
check "marca la instancia sin sembrar" 'echo "$out" | grep "st-nodata" | grep -q "sin sembrar"'
check "sugiere init y adopt" 'echo "$out" | grep -q "./deltactl init st-nodata" && echo "$out" | grep -q "adopt st-nodata"'

section "9. detalle de una instancia (con estadísticas)"
printf 's0_st-ok|82MiB / 512MiB|0.2%%\n' > "$FIX/stats.txt"
out="$(status st-ok)"
check "el detalle muestra servicio, versión y puerto" \
  'echo "$out" | grep -q "Servicio s0" && echo "$out" | grep -q "configurada 1.0 · corriendo 1.0" && echo "$out" | grep -q "http://127.0.0.1:"'
check "el detalle muestra memoria y CPU" 'echo "$out" | grep -q "memoria 82MiB/512MiB"'
check "el detalle cuenta las líneas de error" 'echo "$out" | grep -q "errores 10m.*1 línea"'
check "instancia inexistente da error claro" 'status zz-no | grep -q "no existe"'

section "10. --json"
js="$(bash ./deltactl status --json 2>/dev/null)"
check "empieza y termina como una lista" '[ "$(echo "$js" | head -n1)" = "[" ] && [ "$(echo "$js" | tail -n1)" = "]" ]'
check "es JSON válido" 'if command -v python3 >/dev/null; then echo "$js" | python3 -c "import json,sys; json.load(sys.stdin)"; else true; fi'
check "incluye las claves esperadas" \
  'echo "$js" | grep -q "\"instance\":\"st-drift\"" && echo "$js" | grep -q "\"issues\":\[\"tag-drift\"\]"'
check "--json no imprime banner ni símbolos" '! echo "$js" | has_ansi'

section "11. sin Docker"
touch "$FIX/nodocker"
out="$(status)"
check "avisa que no hay docker y sigue mostrando la configuración" \
  'echo "$out" | grep -q "docker no está disponible" && echo "$out" | grep -q "st-ok"'
rm -f "$FIX/nodocker"

section "12. pantalla de inicio (./deltactl sin argumentos)"
check "en un pipe muestra la ayuda" 'bash ./deltactl 2>&1 | grep -qx "Uso"'
home="$(DELTACTL_UI=rich DELTACTL_COLOR=never COLUMNS=100 bash ./deltactl 2>&1)"
check "en una terminal muestra banner y estado" 'echo "$home" | grep -q "██╗" && echo "$home" | grep -q "Estado de las instancias"'
check "la pantalla de inicio apunta a la ayuda" 'echo "$home" | grep -q "./deltactl help"'


section "10. header: memory, load and the n/m of every instance"
printf 'MemTotal:        8388608 kB\nMemFree:         1048576 kB\nMemAvailable:    3145728 kB\n' > "$FIX/meminfo"
printf '0.82 0.50 0.40 1/200 1234\n' > "$FIX/loadavg"
printf 'MemTotal:        8388608 kB\n' > "$FIX/meminfo-no-available"
newinst st-hd 1.0 1.0
image auth-backend:1.0 sha256:aaa; image gueo-back-end:1.0 sha256:bbb
deployed st-hd s0 1.0 sha256:aaa; deployed st-hd s1 1.0 sha256:bbb
container st-hd s0 running healthy auth-backend:1.0 "1 hour"
container st-hd s1 exited none gueo-back-end:1.0 "1 hour"
hdr() { DELTACTL_MEMINFO="$FIX/meminfo" DELTACTL_LOADAVG="$FIX/loadavg" bash ./deltactl "$@" 2>&1; }
out="$(hdr status)"
check "the header shows the memory with its bar, the figures and the percentage" 'echo "$out" | grep -qE "Memoria \[######\.\.\.\.\] 5\.0/8\.0 GB 62%"'
check "the header shows the load of the last minute" 'echo "$out" | grep -q "Carga 0.82"'
check "the header shows n/m per instance: one of two services OK" 'echo "$out" | grep "^  Instancias:" | grep -q "st-hd 1/2"'
check "an instance with every service OK shows m/m" 'echo "$out" | grep "^  Instancias:" | grep -q "st-ok 2/2"'
check "the header comes before the table title" 'echo "$out" | grep -n "Memoria" | head -1 | cut -d: -f1 | { read a; b="$(echo "$out" | grep -n "^Estado de las instancias" | head -1 | cut -d: -f1)"; [ "$a" -lt "$b" ]; }'
check "the header is also on the home screen" 'DELTACTL_MEMINFO="$FIX/meminfo" DELTACTL_LOADAVG="$FIX/loadavg" DELTACTL_UI=rich bash ./deltactl 2>&1 | grep -q "Instancias:"'
check "no header in the JSON output" '! hdr status --json | grep -q "Memoria"'
check "no header in the detail view of an instance" '! hdr status st-hd | grep -q "^  Instancias:"'
check "memory is left out when the system does not report MemAvailable" '! DELTACTL_MEMINFO="$FIX/meminfo-no-available" DELTACTL_LOADAVG="$FIX/loadavg" bash ./deltactl status 2>&1 | grep -q "Memoria"'
check "the English header uses English labels" 'o="$(DELTACTL_LANG=en DELTACTL_MEMINFO="$FIX/meminfo" DELTACTL_LOADAVG="$FIX/loadavg" bash ./deltactl status 2>&1)"; echo "$o" | grep -q "Memory \[" && echo "$o" | grep -q "Load 0.82" && echo "$o" | grep -q "^  Instances:"'
check "the --strict exit code does not depend on the header" 'hdr status --strict >/dev/null; [ "$?" -eq 2 ]'
bar() { DELTACTL_UI=${2:-plain} DELTACTL_COLOR=${3:-never} DELTACTL_ASCII=1 ROOT="$PWD" bash -c 'source lib/bootstrap.sh; ui_bar "$@"' _ "$1" ${4:-10}; }
check "ui_bar draws the filled share (ASCII)" '[ "$(bar 62)" = "[######....]" ] && [ "$(bar 0 plain never 4)" = "[....]" ] && [ "$(bar 100 plain never 4)" = "[####]" ]'
check "ui_bar clamps above 100 and tolerates a non-number" '[ "$(bar 150 plain never 4)" = "[####]" ] && [ "$(bar abc plain never 4)" = "[....]" ]'
check "ui_bar is green, yellow and red by threshold" 'g="$(printf "[32m")"; y="$(printf "[33m")"; r="$(printf "[31m")"; bar 10 rich always | grep -qF "$g" && bar 75 rich always | grep -qF "$y" && bar 90 rich always | grep -qF "$r"'
host() { DELTACTL_MEMINFO="$FIX/meminfo" DELTACTL_LOADAVG="$FIX/loadavg" ROOT="$PWD" bash -c 'source lib/bootstrap.sh; "$@"' _ "$@"; }
check "the host adapter reads memory, load and converts to GB" '[ "$(host host_mem_total_kb)" = "8388608" ] && [ "$(host host_mem_available_kb)" = "3145728" ] && [ "$(host host_load1)" = "0.82" ] && [ "$(host host_kb_to_gb 8388608)" = "8.0" ]'
check "the host adapter prints nothing when the files are missing" '[ -z "$(DELTACTL_MEMINFO=/nonexistent DELTACTL_LOADAVG=/nonexistent ROOT="$PWD" bash -c "source lib/bootstrap.sh; host_mem_total_kb; host_load1")" ]'

finish

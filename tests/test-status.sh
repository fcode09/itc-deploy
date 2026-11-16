#!/usr/bin/env bash
# Tests de ./itc status: panel, detalle, --json, --strict y detección de desajustes.
# Usa un `docker` simulado y determinista (contenedores, imágenes y estadísticas de mentira), así que no
# necesita Docker real. Se ejecuta desde la raíz de la copia aislada (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR ITC_COLOR ITC_UI ITC_ASCII COLUMNS

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
  bash ./itc new "$1" ${4:+--services "$4"} >/dev/null 2>&1
  fill_instance "instances/$1" "$2" "$3"
  : > "instances/$1/.initialized"
  printf 'SOURCE=init\nINITIALIZED_AT=2026-01-01T00:00:00Z\n' > "instances/$1/.initialized"
}
status() { bash ./itc status "$@" 2>&1; }

section "1. instancia sana"
newinst st-ok 1.0 1.0
image auth-backend:1.0 sha256:aaa; image gueo-back-end:1.0 sha256:bbb
deployed st-ok s0 1.0 sha256:aaa; deployed st-ok s1 1.0 sha256:bbb
container st-ok s0 running healthy auth-backend:1.0 "2 hours"
container st-ok s1 running healthy gueo-back-end:1.0 "3 days"
out="$(status)"
check "muestra la instancia con sus dos servicios" 'echo "$out" | grep -c "st-ok" | grep -qx 2'
check "ambos servicios healthy" '[ "$(echo "$out" | grep "st-ok" | grep -c healthy)" -eq 2 ]'
check "uptime en horas y en días" 'echo "$out" | grep -q "2h0[0-9]m" && echo "$out" | grep -q "3d00h"'
check "pie: todo en orden" 'echo "$out" | grep -q "todo en orden"'
check "sin avisos no hay siguientes pasos" '! echo "$out" | grep -q "Siguientes pasos"'
check "--strict devuelve 0 si todo está bien" 'bash ./itc status --strict >/dev/null 2>&1'
check "la salida plana no lleva escapes" '! echo "$out" | has_ansi'

section "2. etiqueta configurada distinta de la que corre"
newinst st-drift 1.0 2.0
image auth-backend:1.0 sha256:a1; image gueo-back-end:2.0 sha256:b2; image gueo-back-end:1.0 sha256:b1
deployed st-drift s0 1.0 sha256:a1; deployed st-drift s1 1.0 sha256:b1
container st-drift s0 running healthy auth-backend:1.0 "1 hour"
container st-drift s1 running healthy gueo-back-end:1.0 "1 hour"
out="$(status)"
check "detecta el desajuste de s1" 'echo "$out" | grep -q "configurada 2.0 pero corre 1.0"'
check "sugiere desplegar solo ese servicio" 'echo "$out" | grep -q "./itc deploy st-drift s1"'
check "el pie cuenta los avisos" 'echo "$out" | grep -q "con avisos"'
bash ./itc status --strict >/dev/null 2>&1; rc=$?
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
check "sugiere ./itc load" 'echo "$out" | grep -q "./itc load"'
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
check "sugiere ver los logs de s0" 'echo "$out" | grep -q "./itc logs st-health s0"'
check "sugiere levantar s1" 'echo "$out" | grep -q "./itc deploy st-health s1"'

section "6. servicio que corre fuera de COMPOSE_PROFILES"
newinst st-orph 5.0 5.0 s0
image auth-backend:5.0 sha256:o0
deployed st-orph s0 5.0 sha256:o0
container st-orph s0 running healthy auth-backend:5.0 "1 hour"
container st-orph s1 running healthy gueo-back-end:5.0 "1 hour"
out="$(status)"
check "detecta el servicio fuera de perfil" 'echo "$out" | grep -q "fuera de perfil"'
check "sugiere detenerlo" 'echo "$out" | grep -q "./itc stop st-orph s1"'

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
check "sugiere init y adopt" 'echo "$out" | grep -q "./itc init st-nodata" && echo "$out" | grep -q "adopt st-nodata"'

section "9. detalle de una instancia (con estadísticas)"
printf 's0_st-ok|82MiB / 512MiB|0.2%%\n' > "$FIX/stats.txt"
out="$(status st-ok)"
check "el detalle muestra servicio, versión y puerto" \
  'echo "$out" | grep -q "Servicio s0" && echo "$out" | grep -q "configurada 1.0 · corriendo 1.0" && echo "$out" | grep -q "http://127.0.0.1:"'
check "el detalle muestra memoria y CPU" 'echo "$out" | grep -q "memoria 82MiB/512MiB"'
check "el detalle cuenta las líneas de error" 'echo "$out" | grep -q "errores 10m.*1 línea"'
check "instancia inexistente da error claro" 'status zz-no | grep -q "no existe"'

section "10. --json"
js="$(bash ./itc status --json 2>/dev/null)"
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

section "12. pantalla de inicio (./itc sin argumentos)"
check "en un pipe muestra la ayuda" 'bash ./itc 2>&1 | grep -qx "Uso"'
home="$(ITC_UI=rich ITC_COLOR=never COLUMNS=100 bash ./itc 2>&1)"
check "en una terminal muestra banner y estado" 'echo "$home" | grep -q "██╗" && echo "$home" | grep -q "Estado de las instancias"'
check "la pantalla de inicio apunta a la ayuda" 'echo "$home" | grep -q "./itc help"'

finish

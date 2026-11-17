#!/usr/bin/env bash
# Tests de ./itc check, ./itc doctor y el asistente de ./itc new --wizard.
# Usa un `docker` simulado y determinista (imágenes, compose y pruebas de Mongo de mentira): no necesita Docker
# real y NUNCA levanta nada. Se ejecuta desde la raíz de la copia aislada (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR ITC_COLOR ITC_UI ITC_ASCII COLUMNS

FIX="$(mktemp -d)"
export FIX
LISTENER=""
cleanup() { [ -z "$LISTENER" ] || kill "$LISTENER" 2>/dev/null; rm -rf "$FIX" instances/gd-* instances/wz-*; }
trap cleanup EXIT
rm -rf instances/gd-* instances/wz-*
mkdir -p "$FIX/bin"
: > "$FIX/images.txt"; : > "$FIX/calls.log"

cp tests/fake-docker.sh "$FIX/bin/docker"
chmod +x "$FIX/bin/docker"
export PATH="$FIX/bin:$PATH"

image() { printf '%s|%s|%s\n' "$1" "$2" "${3:-amd64}" >> "$FIX/images.txt"; }
newinst() { # nombre s0tag s1tag [servicios]
  bash ./itc new "$1" ${4:+--services "$4"} >/dev/null 2>&1
  fill_instance "instances/$1" "$2" "$3"
  # Puertos altos y únicos por instancia: los de 4100 en adelante pueden estar ocupados de verdad en esta máquina.
  NEXTP=$((${NEXTP:-28100} + 10))
  sed -i -e "s/^S0_PORT=.*/S0_PORT=$NEXTP/" -e "s/^S1_PORT=.*/S1_PORT=$((NEXTP + 1))/" "instances/$1/.env.instance"
}
calls() { cat "$FIX/calls.log"; }

section "1. check: instancia lista"
image auth-backend:1.0 sha256:aaaa1111 amd64; image gueo-back-end:2.0 sha256:bbbb2222 amd64
newinst gd-ok 1.0 2.0
out="$(bash ./itc check gd-ok 2>&1)"; rc=$?
check "informa que está lista para desplegar" 'echo "$out" | grep -q "Todo en orden: listo para desplegar"'
check "termina con código 0" '[ "$rc" -eq 0 ]'
check "valida configuración, compose, imágenes, puertos y datos" \
  'echo "$out" | grep -q "Configuración completa" && echo "$out" | grep -q "compose de la instancia es válido" && echo "$out" | grep -q "imagen auth-backend:1.0 cargada" && echo "$out" | grep -q "puerto .* libre" && echo "$out" | grep -q "Datos:"'
check "sugiere el siguiente paso" 'echo "$out" | grep -q "./itc deploy gd-ok"'
check "no prueba Mongo si no se pide" 'echo "$out" | grep -q "no probadas" && ! calls | grep -q "^run "'
check "es solo lectura: no levanta nada" '! calls | grep -q "COMPOSE up"'
check "sin color no hay escapes" '! echo "$out" | has_ansi'

section "2. check: problemas"
bash ./itc new gd-bad >/dev/null 2>&1
out="$(bash ./itc check gd-bad 2>&1)"; rc=$?
check "configuración incompleta con detalle" 'echo "$out" | grep -q "Configuración incompleta" && echo "$out" | grep -q "JWT_SECRET está vacía"'
check "apunta al glosario de la variable" 'echo "$out" | grep -q "./itc help variable JWT_SECRET"'
check "con errores termina con código 1" '[ "$rc" -eq 1 ]'
check "resume cuántos errores hay" 'echo "$out" | grep -qE "[0-9]+ error\(es\)"'
newinst gd-noimg 7.7 7.7
out="$(bash ./itc check gd-noimg 2>&1)"; rc=$?
check "imagen que falta: error con la solución" 'echo "$out" | grep -q "falta la imagen auth-backend:7.7" && echo "$out" | grep -q "./itc load"'
check "el error de imagen devuelve 1" '[ "$rc" -eq 1 ]'
image auth-backend:8.0 sha256:cccc3333 arm64; image gueo-back-end:8.0 sha256:dddd4444 amd64
newinst gd-arch 8.0 8.0
out="$(bash ./itc check gd-arch 2>&1)"
check "arquitectura distinta de la del servidor" 'echo "$out" | grep -q "es arm64 y este servidor es amd64"'
newinst gd-p1 1.0 2.0 s0
newinst gd-p2 1.0 2.0 s0
sed -i 's/^S0_PORT=.*/S0_PORT=4888/; s/^S1_PORT=.*/S1_PORT=4889/' instances/gd-p1/.env.instance
sed -i 's/^S0_PORT=.*/S0_PORT=4888/; s/^S1_PORT=.*/S1_PORT=4890/' instances/gd-p2/.env.instance
check "puerto repetido entre instancias" 'bash ./itc check gd-p2 2>&1 | grep -q "el puerto 4888 ya lo usa la instancia"'
newinst gd-rb 1.0 2.0
printf 'S0_TAG=1.0\nS0_IMAGE_ID=sha256:otra\n' > instances/gd-rb/.deployed
check "etiqueta que apunta a otra imagen: aviso" 'bash ./itc check gd-rb 2>&1 | grep -q "apunta a otra imagen que la desplegada"'
touch "$FIX/compose_invalid"
check "compose inválido" 'bash ./itc check gd-ok 2>&1 | grep -q "El compose no es válido"'
rm -f "$FIX/compose_invalid"

section "3. check: opciones"
check "un servicio concreto solo revisa ese servicio" \
  'o="$(bash ./itc check gd-ok s1 2>&1)"; echo "$o" | grep -q "s1: imagen gueo-back-end:2.0" && ! echo "$o" | grep -q "s0: imagen"'
out="$(bash ./itc check gd-ok --mongo 2>&1)"
check "--mongo prueba las 4 bases de la instancia" '[ "$(echo "$out" | grep -c "responde (base")" -eq 4 ]'
touch "$FIX/mongo_fail"
check "--mongo falla con un error claro y código 1" \
  'o="$(bash ./itc check gd-ok --mongo 2>&1)"; rc=$?; echo "$o" | grep -q "no responde" && [ "$rc" -eq 1 ]'
rm -f "$FIX/mongo_fail"
check "instancia inexistente" 'bash ./itc check zz-no 2>&1 | grep -q "no existe"'
check "opción desconocida" 'bash ./itc check gd-ok --nada 2>&1 | grep -q "opción desconocida"'
check "servicio inactivo en la instancia" 'bash ./itc check gd-p1 s1 2>&1 | grep -q "no está activo"'

section "4. doctor"
if command -v python3 >/dev/null 2>&1; then
  PORT=$((20000 + RANDOM % 20000))
  python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 &
  LISTENER=$!
  sleep 1
else
  PORT=""
fi
newinst gd-doc 1.0 2.0
sed -i "s#^MONGO_URI=.*#MONGO_URI=mongodb://127.0.0.1:${PORT:-1}/x#" instances/gd-doc/.env.s0
out="$(bash ./itc doctor 2>&1)"; rc=$?
check "muestra todas las secciones" \
  'for s in Docker Recursos MongoDB Instancias Herramientas; do echo "$out" | grep -qx "$s" || exit 1; done'
check "detecta Docker y Compose" 'echo "$out" | grep -q "Docker 27.0.0" && echo "$out" | grep -q "Docker Compose 2.30.0"'
check "informa de disco y memoria" 'echo "$out" | grep -q "Disco libre" && echo "$out" | grep -q "Memoria:"'
check "sin escapes en modo plano" '! echo "$out" | has_ansi'
if [ -n "$PORT" ]; then
  check "una URI de Mongo accesible se marca como alcanzable" 'echo "$out" | grep -q "127.0.0.1:$PORT alcanzable"'
  check "host.docker.internal se prueba contra la puerta de enlace" \
    'sed -i "s#^MONGO_DELTA_DISPATCH_URI=.*#MONGO_DELTA_DISPATCH_URI=mongodb://host.docker.internal:$PORT/y#" instances/gd-doc/.env.s1; bash ./itc doctor 2>&1 | grep -q "host.docker.internal:$PORT alcanzable desde los contenedores (por 127.0.0.1)"'
fi
sed -i "s#^MONGO_URI=.*#MONGO_URI=mongodb://127.0.0.1:1/x#" instances/gd-doc/.env.s0
out="$(bash ./itc doctor 2>&1)"; rc=$?
check "una URI inalcanzable es un error con la solución" 'echo "$out" | grep -q "127.0.0.1:1 no responde por TCP"'
check "con errores termina con código 1" '[ "$rc" -eq 1 ]'
chmod 644 instances/gd-doc/.env.s0
check "avisa de secretos legibles por otros usuarios" 'bash ./itc doctor 2>&1 | grep -q "gd-doc: archivos con secretos legibles.*\.env\.s0"'
check "en un sistema sin permisos Unix (WSL sobre Windows) no avisa y lo explica"   'o="$(ITC_FSTYPE=9p bash ./itc doctor 2>&1)"; ! echo "$o" | grep -q "legibles por otros usuarios" && echo "$o" | grep -q "no maneja permisos Unix"'
chmod 600 instances/gd-doc/.env.s0
sed -i 's/^S1_MEM_LIMIT=.*/S1_MEM_LIMIT=999999g/' instances/gd-doc/.env.instance
check "avisa si los límites de memoria superan la RAM" 'bash ./itc doctor 2>&1 | grep -q "límites de memoria de las instancias suman"'
check "doctor no acepta argumentos" 'bash ./itc doctor x 2>&1 | grep -q "no recibe argumentos"'
check "es solo lectura: no levanta nada" '! calls | grep -q "COMPOSE up"'
[ -z "$LISTENER" ] || { kill "$LISTENER" 2>/dev/null; LISTENER=""; }
rm -rf instances/gd-*

section "5. asistente: new --wizard"
image auth-backend:1.5 sha256:eeee5555 amd64; image gueo-back-end:2.5 sha256:ffff6666 amd64
answers_new() { printf '%s\n' "wz-test" "s0,s1" "n" "auth-backend" "1.5" "gueo-back-end" "2.5" "http://10.0.0.5" "s" "s"; }
out="$(answers_new | bash ./itc new --wizard 2>&1)"; rc=$?
d=instances/wz-test
check "crea la instancia" '[ "$rc" -eq 0 ] && [ -f $d/.env.instance ]'
check "muestra las etiquetas ya cargadas" 'echo "$out" | grep -q "Etiquetas cargadas de auth-backend:.* 1.5"'
check "aplica las etiquetas" 'grep -qx "S0_TAG=1.5" $d/.env.instance && grep -qx "S1_TAG=2.5" $d/.env.instance'
check "aplica la URL pública a los dos servicios" 'grep -qx "IP_SERVER=http://10.0.0.5" $d/.env.s0 && grep -qx "IP_SERVER=http://10.0.0.5" $d/.env.s1'
check "nombra las bases con la instancia" \
  'grep -q "authsoftware_wz-test" $d/.env.s0 && grep -q "deltadispatch_wz-test" $d/.env.s1 && grep -q "robin_wz-test" $d/.env.s1 && ! grep -q "CAMBIAR" $d/.env.s0'
jwt0="$(get_var_t() { grep -E "^$2=" "$1" | cut -d= -f2-; }; get_var_t $d/.env.s0 JWT_SECRET)"
jwt1="$(grep -E '^JWT_SECRET=' $d/.env.s1 | cut -d= -f2-)"
check "genera un JWT_SECRET de 64 caracteres, igual en s0 y s1" '[ "${#jwt0}" -eq 64 ] && [ "$jwt0" = "$jwt1" ]'
check "genera la clave de federación en base64 de 32 bytes" \
  '[ "$(grep -E "^FEDERATION_ENCRYPTION_KEY=" $d/.env.s1 | cut -d= -f2- | base64 -d 2>/dev/null | wc -c)" -eq 32 ]'
check "genera el secreto de handoff de al menos 32 caracteres" \
  '[ "$(grep -E "^DELTA_UNIVERSITY_HANDOFF_SECRET=" $d/.env.s1 | cut -d= -f2- | tr -d "\n" | wc -c)" -ge 32 ]'
check "no imprime los secretos generados" '! echo "$out" | grep -qF "$jwt0"'
check "los .env quedan con permisos 600" '[ "$(stat -c %a $d/.env.s0)" = "600" ] && [ "$(stat -c %a $d/.env.s1)" = "600" ]'
check "no es una instancia existente: sin marcador" '[ ! -f $d/.initialized ]'
check "lista lo que falta: DEEPGRAM y los JSON de Firebase" \
  'echo "$out" | grep -q "Pendiente de completar" && echo "$out" | grep "\.env\.s1" | grep -q "DEEPGRAM_API_KEY" && echo "$out" | grep "secrets/" | grep -q "fcm.json"'
check "lo ya completado no aparece como pendiente" '! echo "$out" | grep "\.env\.s0" | grep -q "JWT_SECRET"'
check "indica ./itc check como paso siguiente" 'echo "$out" | grep -q "./itc check wz-test"'
rm -rf instances/wz-test

section "6. asistente: casos especiales"
out="$(printf '%s\n' "wz-ex" "s0,s1" "s" "s0" "" "s1" "" "http://h" "s" | bash ./itc new --wizard 2>&1)"
d=instances/wz-ex
check "una municipalidad existente queda marcada" 'grep -qx "SOURCE=existing" $d/.initialized'
check "en una existente no se generan secretos ni se renombran las bases" \
  '[ -z "$(grep -E "^JWT_SECRET=" $d/.env.s0 | cut -d= -f2-)" ] && grep -q "CAMBIAR_authsoftware_INSTANCIA" $d/.env.s0'
check "usa el nombre de imagen indicado" 'grep -qx "S0_IMAGE=s0" $d/.env.instance && grep -qx "S1_IMAGE=s1" $d/.env.instance'
rm -rf instances/wz-ex
out="$(printf '%s\n' "wz-no" "s1" "n" "gueo-back-end" "" "" "n" "s" | bash ./itc new --wizard 2>&1)"
check "sin generar secretos: JWT_SECRET queda vacío" '[ -z "$(grep -E "^JWT_SECRET=" instances/wz-no/.env.s1 | cut -d= -f2-)" ]'
check "solo con s1 no pregunta por s0 ni lo pide pendiente" \
  '! echo "$out" | grep -q "imagen de s0" && ! echo "$out" | grep -q "^  .* \.env\.s0 "'
rm -rf instances/wz-no
check "nombre inválido en el asistente falla con ayuda" \
  'printf "%s\n" "Mal_Nombre" | bash ./itc new --wizard 2>&1 | grep -q "(ayuda: ./itc help new)"'
check "cancelar al confirmar no crea nada" \
  'printf "%s\n" "wz-cancel" "s0,s1" "n" "" "" "" "" "" "n" "n" | bash ./itc new --wizard >/dev/null 2>&1; [ ! -e instances/wz-cancel ]'
check "un servicio desconocido en el asistente falla" \
  'printf "%s\n" "wz-bad" "s0,s9" "n" | bash ./itc new --wizard 2>&1 | grep -q "servicio desconocido"'
check "el asistente no admite nombre en la línea de comandos" 'bash ./itc new --wizard foo 2>&1 | grep -q "no se indica el nombre"'
check "sin nombre y sin terminal sigue dando el uso" 'bash ./itc new </dev/null 2>&1 | grep -q "uso: ./itc new"'

section "7. new clásico: lista de pendientes"
out="$(bash ./itc new wz-classic 2>&1)"
check "new sigue creando la instancia y muestra los pendientes" \
  'echo "$out" | grep -q "creada en" && echo "$out" | grep -q "Pendiente de completar" && echo "$out" | grep "\.env\.instance" | grep -q "S0_TAG, S1_TAG"'
check "los pendientes incluyen las variables obligatorias vacías" 'echo "$out" | grep "\.env\.s0" | grep -q "JWT_SECRET"'
check "conserva los siguientes pasos y apunta a la ayuda" 'echo "$out" | grep -q "Siguientes pasos" && echo "$out" | grep -q "./itc help variable"'
rm -rf instances/wz-classic

finish

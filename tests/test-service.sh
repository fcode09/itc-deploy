#!/usr/bin/env bash
# Tests de los servicios de una instancia (lib/core/svcmgmt.sh y `./deltactl service`): añadir, quitar (los datos se conservan), cambiar versión,
# puerto y memoria, sin tocar el resto de .env.instance. Usa el docker simulado (tests/fake-docker.sh): nunca toca Docker.
# Se ejecuta desde la raíz de la copia aislada (tests/run.sh): aquí se añade un servicio "walle" que solo existe en el catálogo de esa copia.
# shellcheck disable=SC2016  # los casos de check van entre comillas simples y se evalúan con eval
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS

FIX="$(mktemp -d)"
export FIX
# The copy of the tree is shared by every suite of a run: what this one changes of the catalog and the templates is put back when it ends.
cp lib/core/catalog.data "$FIX.catalog.data"
cp templates/.env.instance.example "$FIX.env.instance.example"
cleanup() {
  cp "$FIX.catalog.data" lib/core/catalog.data
  cp "$FIX.env.instance.example" templates/.env.instance.example
  rm -rf "$FIX" "$FIX.catalog.data" "$FIX.env.instance.example" templates/.env.walle.example instances/sv-*
}
trap cleanup EXIT
rm -rf instances/sv-*
mkdir -p "$FIX/bin"
: > "$FIX/images.txt"; : > "$FIX/calls.log"
cp tests/fake-docker.sh "$FIX/bin/docker"
chmod +x "$FIX/bin/docker"
export PATH="$FIX/bin:$PATH"
printf 'backend-s0:1.0|sha256:aaaa1111|amd64\nbackend-s1:2.0|sha256:bbbb2222|amd64\nbackend-s1:2.1|sha256:bbbb2223|amd64\n' > "$FIX/images.txt"
printf '%s\n' "backend-s0:1.0|2026-11-20 12:00:00 +0000 UTC" "backend-s1:2.0|2026-11-20 12:00:00 +0000 UTC" "backend-s1:2.1|2026-11-23 12:00:00 +0000 UTC" > "$FIX/image_dates.txt"

D() { DELTACTL_NO_RUNS=1 bash ./deltactl "$@"; }
run() { ROOT="$PWD" bash -c "source lib/bootstrap.sh; $1"; }
val() { run "get_var_r instances/$1/$2 $3; printf %s \"\$GV\""; }   # instancia archivo variable
mode() { stat -c %a "$1"; }
prof() { val "$1" .env.instance COMPOSE_PROFILES; }

# Un servicio que solo existe en el catálogo (como en test-catalog): una línea y su plantilla.
printf 'walle|walle-backend|walle|3700|3|.env.walle.example|IP_SERVER||s0|1g|media logs||TOKEN_SECRET:hex32 JWT_SECRET:shared\n' >> lib/core/catalog.data
printf 'IP_SERVER=CAMBIAR\nTOKEN_SECRET=CAMBIAR\nJWT_SECRET=CAMBIAR\nMONGO_X=mongodb://h/CAMBIAR_walle_INSTANCIA\n' > templates/.env.walle.example
printf 'WALLE_TAG=\nWALLE_PORT=\n' >> templates/.env.instance.example

D new sv-a --services s0 --generate-secrets > /dev/null 2>&1
D new sv-b --services s0,s1 --generate-secrets > /dev/null 2>&1
sed -i 's/^IP_SERVER=.*/IP_SERVER=10.1.2.3/' instances/sv-a/.env.s0
cp instances/sv-a/.env.instance "$FIX/a.instance.before"

section "1. list: lo que corre la instancia y lo que no"
check "list dice cuáles servicios están activos y cuáles no" '
  out="$(D service list sv-a)"; echo "$out" | grep -q "^  s0 .*activo" && echo "$out" | grep -q "^  s1 .*sin activar" && echo "$out" | grep -q "^  walle .*sin activar"'
check "list no entra en el historial de operaciones (no cambia nada)" '! run "source lib/core/runs.sh; runs_is_mutation service list sv-a"'
check "add, remove y set sí son operaciones registradas, con su instancia" '
  run "source lib/core/runs.sh; runs_is_mutation service add sv-a s1 --yes" && run "source lib/core/runs.sh; runs_is_mutation service remove sv-a s1" && run "source lib/core/runs.sh; runs_is_mutation service set sv-a s1 port 4500" &&
  [ "$(run "source lib/core/runs.sh; runs_instance_of service add sv-a s1 --tag 2.0")" = "sv-a" ]'

section "2. add: crea lo que falta y no toca el resto"
check "añadir s1 a una instancia que solo tenía s0 lo activa y dice el puerto" '
  out="$(D service add sv-a s1 --tag 2.0 2>&1)"; echo "$out" | grep -q "s1 (backend-s1) activado en .sv-a." && [ "$(prof sv-a)" = "s0,s1" ]'
check "su .env.s1 sale de la plantilla con modo 600" '[ -f instances/sv-a/.env.s1 ] && [ "$(mode instances/sv-a/.env.s1)" = "600" ]'
check "el nombre de la instancia entra en el marcador de sus bases de datos" '! grep -q "CAMBIAR_[a-z]*_INSTANCIA" instances/sv-a/.env.s1'
check "crea sus carpetas de data/" 'for d in media uploads fileIncidentsResolved imageIncidentsResolved; do [ -d "instances/sv-a/data/s1/$d" ] || exit 1; done'
check "la dirección del servidor (IP_SERVER) es la que ya tenían los otros servicios" '[ "$(val sv-a .env.s1 IP_SERVER)" = "10.1.2.3" ]'
check "JWT_SECRET, que comparten los servicios, es el mismo que el de s0" '
  [ -n "$(val sv-a .env.s0 JWT_SECRET)" ] && [ "$(val sv-a .env.s1 JWT_SECRET)" = "$(val sv-a .env.s0 JWT_SECRET)" ]'
check "la versión pedida queda en S1_TAG y el puerto en S1_PORT" '[ "$(val sv-a .env.instance S1_TAG)" = "2.0" ] && [[ "$(val sv-a .env.instance S1_PORT)" =~ ^[0-9]+$ ]]'
check ".env.instance cambia solo en COMPOSE_PROFILES, S1_TAG y S1_PORT" '
  diff <(grep -v "^COMPOSE_PROFILES=\|^S1_TAG=\|^S1_PORT=" "$FIX/a.instance.before") <(grep -v "^COMPOSE_PROFILES=\|^S1_TAG=\|^S1_PORT=" instances/sv-a/.env.instance) > /dev/null'
check "los archivos de s0 no cambian" '[ "$(val sv-a .env.s0 IP_SERVER)" = "10.1.2.3" ]'
check "el puerto elegido no choca con otro servicio de la instancia ni con otra instancia" '
  p1="$(val sv-a .env.instance S1_PORT)"; [ "$p1" != "$(val sv-a .env.instance S0_PORT)" ] && [ "$p1" != "$(val sv-b .env.instance S0_PORT)" ] && [ "$p1" != "$(val sv-b .env.instance S1_PORT)" ]'
check "cuenta lo que falta completar y el comando que sigue" '
  D service remove sv-a s1 --yes > /dev/null 2>&1; out="$(D service add sv-a s1 2>&1)"; echo "$out" | grep -q "env sv-a list s1" && echo "$out" | grep -q "deploy sv-a s1"'
check "añadir un servicio que ya está activo da error y no cambia nada" '
  before="$(cat instances/sv-a/.env.instance)"; ! D service add sv-a s1 > /dev/null 2>&1 && [ "$(cat instances/sv-a/.env.instance)" = "$before" ]'
check "un servicio que no existe da error" '! D service add sv-a s9 > /dev/null 2>&1'
check "con --port usa ese puerto" '
  D service remove sv-a s1 --yes > /dev/null 2>&1; D service add sv-a s1 --port 4777 > /dev/null 2>&1 && [ "$(val sv-a .env.instance S1_PORT)" = "4777" ]'
check "un puerto que usa otra instancia se rechaza y no se activa" '
  D service remove sv-a s1 --yes > /dev/null 2>&1; p="$(val sv-b .env.instance S0_PORT)"
  out="$(D service add sv-a s1 --port "$p" 2>&1)"; rc=$?; [ "$rc" -ne 0 ] && echo "$out" | grep -q "sv-b" && [ "$(prof sv-a)" = "s0" ]'
check "un puerto fuera de rango se rechaza" '! D service add sv-a s1 --port 80 > /dev/null 2>&1 && ! D service add sv-a s1 --port abc > /dev/null 2>&1 && [ "$(prof sv-a)" = "s0" ]'
check "una versión con caracteres raros se rechaza" '! D service add sv-a s1 --tag "1;rm" > /dev/null 2>&1 && [ "$(prof sv-a)" = "s0" ]'
check "--generate-secrets genera los secretos propios del servicio" '
  rm -f instances/sv-a/.env.s1; D service add sv-a s1 --generate-secrets > /dev/null 2>&1; v="$(val sv-a .env.s1 FEDERATION_ENCRYPTION_KEY)"; [ -n "$v" ] && [[ "$v" != *CAMBIAR* ]]'
check "un secreto compartido se copia del que ya hay, no se inventa otro" '[ "$(val sv-a .env.s1 JWT_SECRET)" = "$(val sv-a .env.s0 JWT_SECRET)" ]'

section "3. remove: se quita el servicio y se conservan sus datos"
D service set sv-a s1 memory 3g > /dev/null 2>&1
echo "dato" > instances/sv-a/data/s1/media/archivo.txt
printf 'MARCA=conservada\n' >> instances/sv-a/.env.s1
touch "$FIX/log_all"; : > "$FIX/all_calls.log"
check "sin --yes y sin terminal no borra nada: pide confirmación" '! D service remove sv-a s1 < /dev/null > /dev/null 2>&1 && [ "$(prof sv-a)" = "s0,s1" ]'
check "con --yes lo quita de COMPOSE_PROFILES" 'D service remove sv-a s1 --yes > /dev/null 2>&1 && [ "$(prof sv-a)" = "s0" ]'
check "detiene su contenedor (solo ese servicio)" 'grep -q "stop s1" "$FIX/all_calls.log" && ! grep -q "stop s0" "$FIX/all_calls.log"'
check "conserva su .env.s1, sus secretos y sus datos" '
  [ "$(val sv-a .env.s1 MARCA)" = "conservada" ] && [ "$(cat instances/sv-a/data/s1/media/archivo.txt)" = "dato" ]'
check "dice dónde quedaron sus datos" 'D service add sv-a s1 > /dev/null 2>&1; out="$(D service remove sv-a s1 --yes 2>&1)"; echo "$out" | grep -q "data/s1" && echo "$out" | grep -q "quitado"'
check "al volver a activarlo encuentra sus variables y sus datos como estaban" '
  D service add sv-a s1 > /dev/null 2>&1; [ "$(val sv-a .env.s1 MARCA)" = "conservada" ] && [ "$(cat instances/sv-a/data/s1/media/archivo.txt)" = "dato" ] && [ "$(prof sv-a)" = "s0,s1" ]'
check "al volver conserva el puerto y el límite de memoria que tenía" '[ "$(val sv-a .env.instance S1_MEM_LIMIT)" = "3g" ]'
check "quitar el único servicio se rechaza" '
  D service remove sv-a s1 --yes > /dev/null 2>&1; out="$(D service remove sv-a s0 --yes 2>&1)"; rc=$?; [ "$rc" -ne 0 ] && echo "$out" | grep -q "al menos uno" && [ "$(prof sv-a)" = "s0" ]'
check "quitar un servicio que no está activo da error" '! D service remove sv-a s1 --yes > /dev/null 2>&1'
check "avisa de quién usa al servicio que se quita (dependencia del catálogo)" '
  D service add sv-a s1 > /dev/null 2>&1; out="$(D service remove sv-a s0 --yes 2>&1)"; echo "$out" | grep -q "s1 usa a s0"; D service add sv-a s0 > /dev/null 2>&1; [ "$(prof sv-a)" = "s0,s1" ]'
check "el orden de COMPOSE_PROFILES sigue el del catálogo aunque se añadan al revés" '
  D service remove sv-a s0 --yes > /dev/null 2>&1; D service add sv-a s0 > /dev/null 2>&1; [ "$(prof sv-a)" = "s0,s1" ]'

section "4. set: versión, puerto y memoria, validados antes de escribir"
check "cambia la versión" 'D service set sv-a s1 tag 2.1 > /dev/null 2>&1 && [ "$(val sv-a .env.instance S1_TAG)" = "2.1" ]'
check "cambia el puerto" 'D service set sv-a s1 port 4888 > /dev/null 2>&1 && [ "$(val sv-a .env.instance S1_PORT)" = "4888" ]'
check "cambia el límite de memoria" 'D service set sv-a s1 memory 4g > /dev/null 2>&1 && [ "$(val sv-a .env.instance S1_MEM_LIMIT)" = "4g" ]'
check "latest se resuelve a la versión más reciente cargada (por fecha), nunca queda la palabra latest" '
  D service set sv-a s1 tag 2.0 > /dev/null 2>&1 && [ "$(val sv-a .env.instance S1_TAG)" = "2.0" ] && D service set sv-a s1 tag latest > /dev/null 2>&1; v="$(val sv-a .env.instance S1_TAG)"; [ "$v" = "2.1" ] && [ "$v" != "latest" ]'
check "un puerto que usa otro servicio de la instancia se rechaza" '
  p="$(val sv-a .env.instance S0_PORT)"; before="$(val sv-a .env.instance S1_PORT)"; ! D service set sv-a s1 port "$p" > /dev/null 2>&1 && [ "$(val sv-a .env.instance S1_PORT)" = "$before" ]'
check "un puerto que usa otra instancia se rechaza" '! D service set sv-a s1 port "$(val sv-b .env.instance S0_PORT)" > /dev/null 2>&1'
check "una memoria inválida se rechaza y no escribe" '! D service set sv-a s1 memory abc > /dev/null 2>&1 && ! D service set sv-a s1 memory "1;x" > /dev/null 2>&1 && [ "$(val sv-a .env.instance S1_MEM_LIMIT)" = "4g" ]'
check "un campo que no existe se rechaza" '! D service set sv-a s1 nombre x > /dev/null 2>&1'
check "un servicio que no está activo no se puede cambiar" '! D service set sv-a walle port 4999 > /dev/null 2>&1'
check "COMPOSE_PROFILES no se toca al cambiar un valor" '[ "$(prof sv-a)" = "s0,s1" ]'

section "5. un servicio que solo existe en el catálogo"
check "se puede añadir walle sin tocar el código" '
  out="$(D service add sv-a walle --tag 9.1 --generate-secrets 2>&1)"; echo "$out" | grep -q "walle (walle-backend)" && [ "$(prof sv-a)" = "s0,s1,walle" ] && [ -f instances/sv-a/.env.walle ]'
check "sus carpetas, su puerto con el desplazamiento del catálogo y su versión quedan escritos" '
  [ -d instances/sv-a/data/walle/media ] && [ -d instances/sv-a/data/walle/logs ] && [ "$(val sv-a .env.instance WALLE_TAG)" = "9.1" ] && [[ "$(val sv-a .env.instance WALLE_PORT)" =~ ^[0-9]+$ ]]'
check "su secreto propio se genera y JWT_SECRET es el compartido" '
  [ -n "$(val sv-a .env.walle TOKEN_SECRET)" ] && [ "$(val sv-a .env.walle JWT_SECRET)" = "$(val sv-a .env.s0 JWT_SECRET)" ]'
check "se puede quitar y los otros siguen intactos" 'D service remove sv-a walle --yes > /dev/null 2>&1 && [ "$(prof sv-a)" = "s0,s1" ]'
check "activar con --tag latest un servicio sin imagen cargada lo activa igual y avisa; no escribe la palabra latest (así lo pide la tecla a del panel)" '
  out="$(D service add sv-a walle --tag latest 2>&1)"; rc=$?; [ "$rc" -eq 0 ] && echo "$out" | grep -q "se activa sin versión" && [ "$(prof sv-a)" = "s0,s1,walle" ] && [ "$(val sv-a .env.instance WALLE_TAG)" != "latest" ] && D service remove sv-a walle --yes > /dev/null 2>&1'
check "service set image cambia el nombre de la imagen (sin etiqueta) y rechaza uno inválido" '
  D service set sv-a s1 image mi-gue > /dev/null 2>&1 && [ "$(val sv-a .env.instance S1_IMAGE)" = "mi-gue" ] && ! D service set sv-a s1 image "mi-gue:1.0" > /dev/null 2>&1 && D service set sv-a s1 image backend-s1 > /dev/null 2>&1'

section "6. .env.instance no se corrompe y las instancias existentes siguen igual"
check "después de todo, .env.instance sigue teniendo una línea por variable (sin duplicados)" '
  [ -z "$(grep -o "^[A-Z0-9_]*=" instances/sv-a/.env.instance | sort | uniq -d)" ]'
check "el modo de .env.instance sigue en 600" '[ "$(mode instances/sv-a/.env.instance)" = "600" ]'
check "no queda ningún archivo temporal de set_var" '[ -z "$(ls instances/sv-a/.env.instance.* instances/sv-a/.env.s1.* 2>/dev/null)" ]'
check "la otra instancia no cambió" '[ "$(prof sv-b)" = "s0,s1" ]'
check "check de la instancia reconoce los servicios activos" 'D check sv-a 2>&1 | grep -q "s1"'

section "7. ayuda, completado y mensajes"
check "hay página de ayuda en los dos idiomas" '[ -f lib/help/cmd-service.txt ] && [ -f lib/help/en/cmd-service.txt ]'
check "help service sale en español y en inglés" 'D help service 2>&1 | grep -q "servicios de una instancia" && DELTACTL_LANG=en D help service 2>&1 | grep -q "services of an instance"'
check "el completado ofrece los subcomandos y sus opciones" '
  c="$(D completion bash)"; echo "$c" | grep -q "list add remove set" && echo "$c" | grep -q -- "--generate-secrets"'
check "sin subcomando dice cómo se usa" 'out="$(D service 2>&1)"; echo "$out" | grep -q "uso:"'
check "un subcomando que no existe lo dice" 'out="$(D service borrar sv-a 2>&1)"; echo "$out" | grep -q "no existe"'
check "los mensajes salen en inglés con DELTACTL_LANG=en" 'DELTACTL_LANG=en D service list sv-a 2>&1 | grep -q "Services of .sv-a."'
check "las claves de mensajes existen en los dos idiomas" '
  for k in $(grep -o "MSG_es\[\"service\.[a-z_]*\"\]" lib/i18n/es/service.sh | sed "s/MSG_es/MSG_en/"); do grep -qF "$k" lib/i18n/en/service.sh || { echo "falta $k"; exit 1; }; done'

finish

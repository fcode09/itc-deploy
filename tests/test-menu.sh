#!/usr/bin/env bash
# Tests de ./deltactl menu: navegación, ayuda con "?", cada acción con su comando equivalente, confirmaciones de las
# operaciones destructivas y el flujo "Actualizar a una versión nueva". Las respuestas se envían por la entrada
# estándar y se usa el docker simulado (tests/fake-docker.sh): nada se levanta de verdad.
# Se ejecuta desde la raíz de la copia aislada (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS

FIX="$(mktemp -d)"
export FIX
trap 'rm -rf "$FIX" instances/mn-*' EXIT
rm -rf instances/mn-*
mkdir -p "$FIX/bin"
: > "$FIX/images.txt"; : > "$FIX/calls.log"
cp tests/fake-docker.sh "$FIX/bin/docker"
chmod +x "$FIX/bin/docker"
export PATH="$FIX/bin:$PATH"

image() { printf '%s|%s|%s\n' "$1" "$2" "${3:-amd64}" >> "$FIX/images.txt"; }
calls() { cat "$FIX/calls.log"; }
clearcalls() { : > "$FIX/calls.log"; }
newinst() { # nombre s0tag s1tag
  bash ./deltactl new "$1" >/dev/null 2>&1
  fill_instance "instances/$1" "$2" "$3"
  NEXTP=$((${NEXTP:-29100} + 10))
  sed -i -e "s/^S0_PORT=.*/S0_PORT=$NEXTP/" -e "s/^S1_PORT=.*/S1_PORT=$((NEXTP + 1))/" "instances/$1/.env.instance"
}
# Ejecuta el menú con las respuestas dadas (una por argumento); stdout y stderr juntos.
menu() { printf '%s\n' "$@" | bash ./deltactl menu 2>&1; }

section "1. navegación básica"
out="$(menu 0)"; rc=$?
check "muestra el menú con todas las opciones" \
  'for o in "Ver estado" "Crear una instancia" "Comprobar una instancia" "Desplegar" "Actualizar a una versión nueva" "Volver a la versión anterior" "Sembrar datos iniciales" "Ver logs" "Detener un servicio" "Bajar una instancia" "Versiones de imágenes" "Cargar imágenes" "Diagnóstico del servidor" "Ayuda" "Salir"; do echo "$out" | grep -q "$o" || exit 1; done'
check "0 sale con código 0" '[ "$rc" -eq 0 ]'
check "q también sale" 'menu q | grep -q "Menú"'
check "sin entrada (EOF) termina limpiamente" 'bash ./deltactl menu </dev/null >/dev/null 2>&1'
check "una opción inválida avisa y vuelve al menú" 'menu 99 0 | grep -q "opción no válida: .99."'
check "una línea vacía no rompe nada" 'menu "" 0 | grep -c "Menú" | grep -qx 2'
check "el menú no acepta argumentos" 'bash ./deltactl menu x 2>&1 | grep -q "no recibe argumentos"'
check "la salida en un pipe no lleva escapes" '! menu 0 | has_ansi'
check "?4 muestra la ayuda de Desplegar" 'menu ?4 0 | grep -q "levantar o actualizar una instancia"'
check "?14 muestra la ayuda de la ayuda y ?x avisa" 'menu ?14 0 | grep -q "cómo usar la ayuda" && menu ?x 0 | grep -q "no hay ayuda para"'
check "? sola no rompe el menú" 'menu "?" 0 | grep -q "no hay ayuda"'
check "todas las opciones del 1 al 14 tienen ayuda" \
  'for i in $(seq 1 14); do o="$(menu "?$i" 0)"; echo "$o" | grep -q "no hay ayuda" && { echo "    sin ayuda: ?$i"; exit 1; }; echo "$o" | grep -q "Relacionado" || { echo "    página vacía: ?$i"; exit 1; }; done'

section "2. sin instancias"
check "avisa que no hay instancias y sugiere crearlas" 'menu 4 0 | grep -q "no hay instancias todavía: crea una con la opción 2"'

image backend-s0:1.0 sha256:aaaa1111; image backend-s1:2.0 sha256:bbbb2222
image backend-s1:1.5 sha256:cccc3333; image backend-s1:3.0 sha256:dddd4444
newinst mn-one 1.0 2.0
newinst mn-two 1.0 2.0

section "3. selección de instancia y servicio"
out="$(menu 4 1 1 0)"
check "lista las instancias numeradas con sus servicios" 'echo "$out" | grep -q "1) mn-one" && echo "$out" | grep -q "2) mn-two" && echo "$out" | grep -q "(s0,s1)"'
check "lista los servicios con su imagen y la opción todos" 'echo "$out" | grep -q "1) s0 (backend-s0)" && echo "$out" | grep -q "0) todos"'
check "se puede elegir la instancia por nombre" 'clearcalls; o="$(menu 4 mn-two 0 0)"; echo "$o" | grep -q "./deltactl deploy mn-two$" && calls | grep -q "COMPOSE up"'
check "una instancia inválida avisa y vuelve al menú" 'menu 4 zzz 0 | grep -q "instancia no válida: .zzz."'
check "un servicio inválido avisa y vuelve al menú" 'menu 4 1 s9 0 | grep -q "servicio no válido: .s9."'

section "4. acciones: muestran el comando equivalente y lo ejecutan"
clearcalls; out="$(menu 4 1 2 0)"
check "desplegar un servicio: comando equivalente" 'echo "$out" | grep -q "./deltactl deploy mn-one s1"'
check "desplegar ejecuta el despliegue" 'calls | grep -q "COMPOSE up"'
clearcalls; out="$(menu 4 2 0 0)"
check "desplegar todos: sin servicio en el comando" 'echo "$out" | grep -q "./deltactl deploy mn-two$"'
out="$(menu 1 0 0)"
check "ver estado de todas las instancias" 'echo "$out" | grep -q "./deltactl status" && echo "$out" | grep -q "Estado de las instancias" && echo "$out" | grep -q "mn-one"'
out="$(menu 1 1 0)"
check "ver estado de una instancia" 'echo "$out" | grep -q "./deltactl status mn-one" && echo "$out" | grep -q "Instancia mn-one"'
out="$(menu 3 1 n 0)"
check "comprobar una instancia" 'echo "$out" | grep -q "./deltactl check mn-one" && echo "$out" | grep -q "listo para desplegar"'
clearcalls; out="$(menu 3 1 s 0)"
check "comprobar con las bases de datos" 'echo "$out" | grep -q "./deltactl check mn-one --mongo" && echo "$out" | grep -q "responde (base"'
clearcalls; out="$(menu 8 1 2 n 0)"
check "ver logs de un servicio" 'echo "$out" | grep -q "./deltactl logs mn-one s1$" && calls | grep -q "COMPOSE logs"'
out="$(menu 8 1 0 s 0)"
check "logs en vivo añade -f" 'echo "$out" | grep -q "./deltactl logs mn-one -f"'
clearcalls; out="$(menu 9 1 1 0)"
check "detener un servicio" 'echo "$out" | grep -q "./deltactl stop mn-one s0" && calls | grep -q "COMPOSE stop"'
out="$(menu 11 0)"
check "versiones de imágenes" 'echo "$out" | grep -q "./deltactl images" && echo "$out" | grep -q "backend-s0"'
out="$(menu 13 0)"
check "diagnóstico del servidor" 'echo "$out" | grep -q "./deltactl doctor" && echo "$out" | grep -q "Diagnóstico del servidor"'
out="$(menu 14 "" 0)"
check "ayuda desde el menú (índice)" 'echo "$out" | grep -q "./deltactl help" && echo "$out" | grep -q "Inicio rápido"'
out="$(menu 14 rollback 0)"
check "ayuda desde el menú (un tema)" 'echo "$out" | grep -q "volver a la versión anterior"'
out="$(menu 12 "" 0)"
check "cargar imágenes sin ruta se cancela" 'echo "$out" | grep -q "cancelado"'
out="$(menu 12 /no/existe.tar 0)"
check "cargar un archivo inexistente muestra el error y sigue en el menú" \
  'echo "$out" | grep -q "no existe el archivo" && echo "$out" | grep -q "terminó con errores" && [ "$(echo "$out" | grep -c "Menú")" -ge 2 ]'

section "5. operaciones destructivas piden confirmación"
clearcalls; out="$(menu 10 1 n 0)"
check "bajar: si se responde que no, no se ejecuta" '! calls | grep -q "COMPOSE down" && ! echo "$out" | grep -q "./deltactl down"'
clearcalls; out="$(menu 10 1 s 0)"
check "bajar: confirmado, ejecuta con --yes" 'echo "$out" | grep -q "./deltactl down mn-one --yes" && calls | grep -q "COMPOSE down"'
clearcalls; out="$(menu 7 1 otra-cosa 0)"
check "init: sin escribir el nombre exacto se cancela" 'echo "$out" | grep -q "cancelado" && ! echo "$out" | grep -q "./deltactl init"'
out="$(menu 7 1 mn-one 0)"
check "init: escribiendo el nombre ejecuta init --yes" 'echo "$out" | grep -q "./deltactl init mn-one --yes"'
check "init avisa de que borra datos" 'echo "$out" | grep -q "BORRAN datos"'
printf 'S1_TAG=1.5\nS1_IMAGE_ID=sha256:cccc3333\n' > instances/mn-two/.previous
printf 'S1_TAG=2.0\nS1_IMAGE_ID=sha256:bbbb2222\n' > instances/mn-two/.deployed
clearcalls; out="$(menu 6 2 2 n 0)"
check "rollback: si se responde que no, no cambia nada" 'grep -qx "S1_TAG=2.0" instances/mn-two/.env.instance && ! calls | grep -q "COMPOSE up"'
out="$(menu 6 2 2 s 0)"
check "rollback: confirmado, vuelve a la etiqueta anterior" 'echo "$out" | grep -q "./deltactl rollback mn-two s1 --yes" && grep -qx "S1_TAG=1.5" instances/mn-two/.env.instance'

section "6. actualizar a una versión nueva"
clearcalls; out="$(menu 5 1 2 3.0 s 0)"
check "muestra la etiqueta actual y las cargadas" 'echo "$out" | grep -q "etiqueta actual 2.0" && echo "$out" | grep -q "Cargadas de backend-s1:.* 3.0"'
check "cambia la etiqueta en .env.instance" 'grep -qx "S1_TAG=3.0" instances/mn-one/.env.instance'
check "comprueba y luego despliega solo ese servicio" \
  'echo "$out" | grep -q "./deltactl check mn-one s1" && echo "$out" | grep -q "./deltactl deploy mn-one s1" && calls | grep -q "COMPOSE up"'
check "no toca la etiqueta del otro servicio" 'grep -qx "S0_TAG=1.0" instances/mn-one/.env.instance'
out="$(menu 5 1 2 3.0 0)"
check "la misma etiqueta no hace nada" 'echo "$out" | grep -q "ya está en esa etiqueta"'
out="$(menu 5 1 2 "" 0)"
check "sin etiqueta se cancela" 'echo "$out" | grep -q "cancelado"'
newinst mn-three 1.0 2.0
clearcalls; out="$(menu 5 mn-three 2 3.0 n 0)"
check "decir que no a la confirmación deja todo igual" 'grep -qx "S1_TAG=2.0" instances/mn-three/.env.instance && ! calls | grep -q "COMPOSE up"'
out="$(menu 5 mn-three 2 9.9 n 0)"
check "una etiqueta no cargada avisa y deja decidir" 'echo "$out" | grep -q "no está entre las cargadas" && grep -qx "S1_TAG=2.0" instances/mn-three/.env.instance'
clearcalls; out="$(menu 5 mn-three 2 9.9 s s s 0)"
check "si la comprobación falla no despliega y ofrece restaurar" \
  'echo "$out" | grep -q "la comprobación falló: no se desplegó" && ! calls | grep -q "COMPOSE up"'
check "restaurar devuelve la etiqueta anterior" 'grep -qx "S1_TAG=2.0" instances/mn-three/.env.instance && echo "$out" | grep -q "etiqueta restaurada"'
clearcalls; out="$(menu 5 mn-three 2 9.9 s s n 0)"
check "sin restaurar, la etiqueta nueva se conserva" 'grep -qx "S1_TAG=9.9" instances/mn-three/.env.instance'

section "7. crear una instancia desde el menú"
out="$(menu 2 mn-wz s1 n backend-s1 3.0 http://h n s 0)"
check "el asistente corre dentro del menú y crea la instancia" \
  'echo "$out" | grep -q "./deltactl new --wizard" && [ -f instances/mn-wz/.env.instance ] && grep -qx "S1_TAG=3.0" instances/mn-wz/.env.instance'
check "después de crear vuelve al menú" '[ "$(echo "$out" | grep -c "Menú")" -ge 2 ]'

finish

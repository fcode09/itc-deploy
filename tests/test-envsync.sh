#!/usr/bin/env bash
# Tests de `./deltactl env <instancia> sync` y de lib/core/envsync.sh: las variables que las plantillas tienen y los .env de una instancia que ya
# existe no (una instancia creada antes de que se agregaran). Solo agrega: ningún valor cambia y nada se borra. Los servicios que la instancia no
# corre no se tocan salvo que se pidan por su nombre. También `check` y `service set ... tag` lo avisan.
# Usa el docker simulado (tests/fake-docker.sh): nunca toca Docker. Se ejecuta desde la raíz de la copia aislada (tests/run.sh).
# shellcheck disable=SC2016  # los casos de check van entre comillas simples y se evalúan con eval
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS

FIX="$(mktemp -d)"
export FIX
cleanup() { rm -rf "$FIX" instances/es-*; }
trap cleanup EXIT
rm -rf instances/es-*
mkdir -p "$FIX/bin"
: > "$FIX/images.txt"; : > "$FIX/calls.log"
cp tests/fake-docker.sh "$FIX/bin/docker"
chmod +x "$FIX/bin/docker"
export PATH="$FIX/bin:$PATH"
printf 'backend-s0:1.0|sha256:aaaa1111|amd64\nbackend-s1:2.0|sha256:bbbb2222|amd64\n' > "$FIX/images.txt"

D() { bash ./deltactl "$@" 2>&1; }
run() { ROOT="$PWD" bash -c "source lib/bootstrap.sh; $1"; }
has() { grep -q "^$2=" "instances/$1" ; }   # archivo (relativo a instances/) clave

# Una instancia "antigua": le faltan variables que hoy trae la plantilla, y le sobra una que ya no existe.
D new es-a --services s0,s1,robin > /dev/null
sed -i '/^QUEUE_BATCH_SIZE=/d; /^KAFKA_TOPIC=/d; /^QUEUE_POLL_INTERVAL_MS=/d' instances/es-a/.env.robin
echo "VIEJA_VAR=1" >> instances/es-a/.env.robin
sed -i '/^JWT_EXPIRES_IN=/d' instances/es-a/.env.s0

section "1. detectar: solo mirar"
check "sync lista por archivo lo que falta, marca las obligatorias y no escribe nada" '
  cp instances/es-a/.env.robin "$FIX/robin.before"
  out="$(D env es-a sync)"; echo "$out" | grep -q "\.env\.s0 .*1 nueva(s): JWT_EXPIRES_IN" \
    && echo "$out" | grep -q "\.env\.robin .*3 nueva(s): KAFKA_TOPIC (obligatoria), QUEUE_BATCH_SIZE, QUEUE_POLL_INTERVAL_MS" \
    && cmp -s "$FIX/robin.before" instances/es-a/.env.robin'
check "avisa de la variable que ya no está en la plantilla y dice que no se borra" 'D env es-a sync | grep -q "VIEJA_VAR" && D env es-a sync | grep -q "no se borran"'
check "dice cómo agregarlas" 'D env es-a sync | grep -q "env es-a sync --apply"'
check "--json trae los archivos, lo nuevo, lo obsoleto y el total" '
  j="$(D env es-a sync --json)"; echo "$j" | grep -q "\"total\": 4" && echo "$j" | grep -q "\"new\": \[\"KAFKA_TOPIC\", \"QUEUE_BATCH_SIZE\", \"QUEUE_POLL_INTERVAL_MS\"\]" && echo "$j" | grep -q "\"obsolete\": \[\"VIEJA_VAR\"\]"'
check "con el nombre de un servicio solo mira ese archivo" '
  out="$(D env es-a sync s0)"; echo "$out" | grep -q "\.env\.s0" && ! echo "$out" | grep -q "\.env\.robin"'
check "un archivo desconocido falla con la lista de válidos" '! D env es-a sync nada >/dev/null 2>&1 && D env es-a sync nada | grep -q "archivo de variables desconocido"'

section "2. aplicar: solo agrega"
cp instances/es-a/.env.robin "$FIX/robin.before"; cp instances/es-a/.env.s1 "$FIX/s1.before"
sed -i 's/^QUEUE_MAX_SIZE=.*/QUEUE_MAX_SIZE=99/' instances/es-a/.env.robin   # un valor que la persona cambió
cp instances/es-a/.env.robin "$FIX/robin.edited"
D env es-a sync --apply > "$FIX/apply.out"
check "--apply agrega lo que falta y dice cuál obligatoria queda por completar" '
  grep -q "agregada(s) 3 variable(s)" "$FIX/apply.out" && has es-a/.env.robin KAFKA_TOPIC && has es-a/.env.robin QUEUE_BATCH_SIZE && has es-a/.env.s0 JWT_EXPIRES_IN && grep -q "Falta completar: KAFKA_TOPIC" "$FIX/apply.out"'
check "no cambia ningún valor que ya estaba (ni siquiera uno que la persona modificó)" '
  f="^QUEUE_BATCH_SIZE=\|^QUEUE_POLL_INTERVAL_MS=\|^KAFKA_TOPIC=\|^# --- Variables nuevas\|^# Tópico del que\|^$"
  grep -q "^QUEUE_MAX_SIZE=99$" instances/es-a/.env.robin && diff <(grep -v "$f" instances/es-a/.env.robin) <(grep -v "$f" "$FIX/robin.edited") > /dev/null'
check "lo obsoleto sigue ahí (no se borra)" 'grep -q "^VIEJA_VAR=1$" instances/es-a/.env.robin'
check "lo nuevo lleva el comentario que tiene en la plantilla y el valor de ejemplo" '
  grep -q "^# Tópico del que Robin lee las tramas" instances/es-a/.env.robin && grep -q "^KAFKA_TOPIC=CAMBIAR-topic-de-kafka$" instances/es-a/.env.robin && grep -q "^QUEUE_BATCH_SIZE=20$" instances/es-a/.env.robin'
check "un archivo al día queda byte por byte igual" 'cmp -s "$FIX/s1.before" instances/es-a/.env.s1'
check "deja la copia .bak (con lo de antes) y ambos son legibles solo por su dueño" '
  [ "$(stat -c %a instances/es-a/.env.robin.bak)" = 600 ] && [ "$(stat -c %a instances/es-a/.env.robin)" = 600 ] && cmp -s "$FIX/robin.edited" instances/es-a/.env.robin.bak'
check "aplicar otra vez no agrega nada y lo dice" 'D env es-a sync --apply | grep -q "tienen todas las variables de las plantillas" && [ "$(grep -c "^QUEUE_BATCH_SIZE=" instances/es-a/.env.robin)" = 1 ]'
check "tras agregar, el estado de la obligatoria es «por completar» (el valor es el ejemplo)" '[ "$(run "envedit_state_r es-a .env.robin KAFKA_TOPIC; printf %s \$ED_STATE")" = "example" ]'
check "el archivo queda como cambio pendiente de despliegue (la marca era la de antes)" '
  run "envedit_mark_deployed es-a 1 s0 s1 robin" >/dev/null 2>&1; echo "X_NUEVA=1" >> instances/es-a/.env.s0; [ "$(run "envedit_pending es-a")" = ".env.s0" ]'

section "3. lo que no se toca"
D new es-b --services s0 > /dev/null
sed -i '/^QUEUE_BATCH_SIZE=/d' instances/es-b/.env.robin
check "un servicio que la instancia no corre no se revisa (robin no está en COMPOSE_PROFILES)" '
  [ "$(rget_prof() { :; }; grep ^COMPOSE_PROFILES= instances/es-b/.env.instance | cut -d= -f2)" = "s0" ] && D env es-b sync | grep -q "tienen todas las variables" && ! D env es-b sync | grep -q "QUEUE_BATCH_SIZE"'
check "…pero si se pide por su nombre sí" 'D env es-b sync robin | grep -q "QUEUE_BATCH_SIZE"'
check "las claves de .env.instance de un servicio que no se corre tampoco (ROBIN_TAG de es-b)" '
  sed -i "/^ROBIN_TAG=/d; /^ROBIN_PORT=/d" instances/es-b/.env.instance; ! D env es-b sync --json | grep -q "ROBIN_TAG"'
check "una variable comentada en el archivo es una decisión: no se agrega" '
  sed -i "s/^S1_MEM_LIMIT=/# S1_MEM_LIMIT=/" instances/es-a/.env.instance; ! D env es-a sync --json | grep -q "S1_MEM_LIMIT"'
check "los marcadores CAMBIAR_x_INSTANCIA de un valor nuevo son el nombre de la instancia" '
  sed -i "/^ROBIN_MONGO_URI=/d" instances/es-a/.env.robin; D env es-a sync --apply >/dev/null; grep -q "^ROBIN_MONGO_URI=.*robin_es-a$" instances/es-a/.env.robin'

section "4. check y service set avisan"
check "check avisa (sin impedir nada) de las variables que faltan, con el comando" '
  sed -i "/^QUEUE_BATCH_SIZE=/d" instances/es-a/.env.robin; out="$(D check es-a 2>&1)"; echo "$out" | grep -q "\.env\.robin: faltan 1 variable(s) de la plantilla actual" && echo "$out" | grep -q "env es-a sync --apply"'
check "service set ... tag avisa de lo que falta en el .env del servicio" '
  D service set es-a robin tag 1.2.3 2>&1 | grep -q "el \.env\.robin de .es-a. no tiene 1 variable(s) de la plantilla actual: QUEUE_BATCH_SIZE"'
check "service set port no avisa (no es una versión nueva)" '! D service set es-a robin port 4999 2>&1 | grep -q "de la plantilla actual"'

section "5. el núcleo"
check "envsync_r devuelve 1 para un archivo que no existe o sin plantilla" '
  ! run "envsync_r es-a .env.nada" && ! run "envsync_r es-a .env.instance2"'
check "envsync_value cambia CAMBIAR_x_INSTANCIA y deja el resto" '
  [ "$(run "envsync_value mi-inst mongodb://h/CAMBIAR_robin_INSTANCIA/x")" = "mongodb://h/robin_mi-inst/x" ] && [ "$(run "envsync_value i valor")" = "valor" ]'
check "un archivo sin salto de línea final no pierde su última línea al agregar" '
  printf "X=1" > "$FIX/nonl.env"; cp instances/es-a/.env.s0 "$FIX/s0.keep"; sed -i "/^IP_INTERNAL_CONNECTION=/d" instances/es-a/.env.s0; printf "%s" "$(cat instances/es-a/.env.s0)" > "$FIX/s0.nonl"; cp "$FIX/s0.nonl" instances/es-a/.env.s0
  D env es-a sync --apply >/dev/null; grep -q "^IP_INTERNAL_CONNECTION=" instances/es-a/.env.s0 && grep -q "^MONGO_URI=" instances/es-a/.env.s0'

finish

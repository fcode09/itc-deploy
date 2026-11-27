#!/usr/bin/env bash
# Tests de la lectura y escritura segura de los .env (lib/core/envedit.sh) y del comando `./deltactl env`: ida y vuelta sin pérdidas,
# escritura atómica, permisos, secretos que no se imprimen ni quedan en el historial, generación y marca de "desplegado".
# Usa el docker simulado (tests/fake-docker.sh): nunca toca Docker. Se ejecuta desde la raíz de la copia aislada (tests/run.sh).
# shellcheck disable=SC2016  # los casos de check van entre comillas simples y se evalúan con eval
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS

FIX="$(mktemp -d)"
export FIX
cleanup() { rm -rf "$FIX" instances/ee-*; }
trap cleanup EXIT
rm -rf instances/ee-*
mkdir -p "$FIX/bin"
: > "$FIX/images.txt"; : > "$FIX/calls.log"
cp tests/fake-docker.sh "$FIX/bin/docker"
chmod +x "$FIX/bin/docker"
export PATH="$FIX/bin:$PATH"
printf 'backend-s0:1.0|sha256:aaaa1111|amd64\nbackend-s1:2.0|sha256:bbbb2222|amd64\n' > "$FIX/images.txt"

D() { bash ./deltactl "$@"; }   # sin colores: la salida va a una tubería
run() { ROOT="$PWD" bash -c "source lib/bootstrap.sh; $1"; }
# El valor va como argumento, no dentro del código: así el test no depende de cómo se escapa en la cadena.
rset() { ROOT="$PWD" bash -c 'source lib/bootstrap.sh; envedit_set "$1" "$2" "$3" "${4:-0}"' _ "$@"; }
rget() { ROOT="$PWD" bash -c 'source lib/bootstrap.sh; get_var_r "$1" "$2"; printf %s "$GV"' _ "$@"; }
newinst() { # nombre
  D new "$1" --generate-secrets > /dev/null 2>&1
  fill_instance "instances/$1" 1.0 2.0
}
mode() { stat -c %a "$1"; }

newinst ee-a

section "1. ida y vuelta: ningún valor se pierde ni se cambia"
F="$FIX/rt.env"
printf '# comentario inicial\nA=1\n\n# otro comentario\nB=dos=tres\nC="entre comillas"\nD=\x27simples\x27\nE=con espacio al final \nF=\nG=a\\nb\\\\c\nH=$HOME y `x` y $(y)\nI=#no-es-comentario\nJ=%%s %%d\nK=ñandú ✓\n\n# fin\n' > "$F"
cp "$F" "$FIX/rt.orig"
check "set cambia solo la línea de la clave: el resto queda byte por byte (comentarios, vacías, orden)" '
  run "envedit_set $F A 99" && sed "s/^A=1$/A=99/" "$FIX/rt.orig" | cmp -s - "$F"'
check "cambiar una clave dos veces seguidas tampoco mueve nada" 'run "envedit_set $F A 1" && cmp -s "$FIX/rt.orig" "$F"'
check "cada valor sale igual que entró (=, comillas, espacio final, vacío, barras, \$, #, %, acentos)" '
  for k in A B C D E F G H I J K; do
    run "get_var_r $F $k; printf %s \"\$GV\"" > "$FIX/got.$k"
    run "get_var_r $FIX/rt.orig $k; printf %s \"\$GV\"" > "$FIX/want.$k"
    cmp -s "$FIX/got.$k" "$FIX/want.$k" || { echo "difiere $k"; exit 1; }
  done'
check "escribir un valor con = , comillas, barras invertidas y % lo deja tal cual (sin escapes de awk)" '
  v="x=\"y\" \\n \\\\ %s \$HOME"
  rset "$F" B "$v" && [ "$(rget "$F" B)" = "$v" ] && grep -qF "B=x=\"y\" \\n \\\\ %s \$HOME" "$F"'
check "un valor vacío se escribe como CLAVE= y se lee vacío" '
  rset "$F" A "" && grep -q "^A=$" "$F" && [ -z "$(rget "$F" A)" ]'
check "una clave nueva se añade al final" '
  run "envedit_set $F NUEVA valor" && [ "$(tail -n1 "$F")" = "NUEVA=valor" ]'
check "un archivo sin salto de línea final no pierde su última línea" '
  printf "X=1\nY=2" > "$FIX/nonl.env"; run "envedit_set $FIX/nonl.env X 9" && [ "$(cat "$FIX/nonl.env")" = "$(printf "X=9\nY=2")" ]'
check "una línea con CRLF conserva su CR" '
  printf "X=1\r\nY=2\r\n" > "$FIX/crlf.env"; run "envedit_set $FIX/crlf.env X 9" && [ "$(od -An -c "$FIX/crlf.env" | tr -d " \n")" = "X=9\\r\\nY=2\\r\\n" ]'
check "una clave repetida: todas las líneas quedan con el valor nuevo" '
  printf "K=1\n# c\nK=2\n" > "$FIX/dup.env"; run "envedit_set $FIX/dup.env K 3" && [ "$(grep -c "^K=3$" "$FIX/dup.env")" = "2" ]'
check "una clave que es prefijo de otra no toca a la otra (K vs KK)" '
  printf "KK=1\nK=2\n" > "$FIX/pre.env"; run "envedit_set $FIX/pre.env K 9" && [ "$(cat "$FIX/pre.env")" = "$(printf "KK=1\nK=9")" ]'
check "un archivo que no existe se crea con la clave" '
  rm -f "$FIX/new.env"; run "envedit_set $FIX/new.env A 1" && [ "$(cat "$FIX/new.env")" = "A=1" ]'

section "2. escritura atómica: un fallo a mitad no deja el archivo a medias"
cp "$FIX/rt.orig" "$F"
check "si escribir falla a mitad, el archivo queda idéntico y devuelve error" '
  ROOT="$PWD" bash -c "source lib/bootstrap.sh; envedit_emit() { head -n3 \"\$1\"; return 1; }; ! envedit_set $F A 99" && cmp -s "$FIX/rt.orig" "$F"'
check "…y no deja archivos temporales al lado" '[ "$(ls "$FIX" | grep -cE "^rt\.env\.[A-Za-z0-9]{6}$")" = "0" ]'
check "si la carpeta no se puede escribir, falla y el archivo queda como estaba (no root)" '
  [ "$(id -u)" = 0 ] && exit 0
  mkdir "$FIX/ro"; cp "$FIX/rt.orig" "$FIX/ro/x.env"; chmod 500 "$FIX/ro"
  r=0; run "envedit_set $FIX/ro/x.env A 99" 2>/dev/null || r=1; chmod 700 "$FIX/ro"; [ "$r" = 1 ] && cmp -s "$FIX/rt.orig" "$FIX/ro/x.env"'
check "…y tampoco escribe nada en la salida de error: el panel dibuja en esa terminal (no root)" '
  [ "$(id -u)" = 0 ] && exit 0
  chmod 500 "$FIX/ro"; e="$(run "envedit_set $FIX/ro/x.env A 99" 2>&1 > /dev/null)"; chmod 700 "$FIX/ro"; [ -z "$e" ]'
check "no usa awk para escribir (awk -v lee \\n y \\\\ del valor como escapes)" '! sed -n "/^envedit_emit()/,/^}/p;/^envedit_set()/,/^}/p" lib/core/envedit.sh | grep -qE "(^|[^a-z_])awk( |\$)"'

section "3. permisos y copia de seguridad"
cp "$FIX/rt.orig" "$FIX/m.env"; chmod 644 "$FIX/m.env"
check "una clave que no es secreta deja el modo del archivo como estaba (644)" 'run "envedit_set $FIX/m.env A 5 0" && [ "$(mode "$FIX/m.env")" = 644 ]'
check "un secreto deja el archivo en 600" 'run "envedit_set $FIX/m.env A 5 1" && [ "$(mode "$FIX/m.env")" = 600 ]'
check "un archivo nuevo nace en 600" 'rm -f "$FIX/n.env"; ( umask 022; run "envedit_set $FIX/n.env A 1" ); [ "$(mode "$FIX/n.env")" = 600 ]'
chmod 640 "$FIX/rt.env"
check "la copia .bak es siempre 600 (aunque el original sea 640) y tiene el contenido de antes del primer cambio" '
  cp "$FIX/rt.orig" "$F"; chmod 640 "$F"; rm -f "$F.bak"
  ROOT="$PWD" bash -c "source lib/bootstrap.sh; envedit_set $F A primero; envedit_set $F A segundo" \
    && [ "$(mode "$F.bak")" = 600 ] && cmp -s "$FIX/rt.orig" "$F.bak" && grep -q "^A=segundo$" "$F"'
check "la copia se hace una vez por sesión (proceso): el segundo cambio no la pisa (arriba .bak sigue siendo el original)" 'cmp -s "$FIX/rt.orig" "$F.bak"'
check "un archivo en 644 con secretos deja su .bak en 600, y un .bak viejo en 644 se aprieta a 600" '
  cp "$FIX/rt.orig" "$F"; chmod 644 "$F"; rm -f "$F.bak"; ( umask 022; : > "$F.bak" ); chmod 644 "$F.bak"
  run "envedit_set $F A nuevo 1" && [ "$(mode "$F.bak")" = 600 ] && cmp -s "$FIX/rt.orig" "$F.bak"'
check "cada ejecución del comando env hace su propia copia: el segundo set por CLI pisa el .bak con el estado previo al último cambio" '
  D env ee-a set s0:GOOGLE_KEY primeroZ1 >/dev/null 2>&1; D env ee-a set s0:GOOGLE_KEY segundoZ2 >/dev/null 2>&1
  grep -q "^GOOGLE_KEY=primeroZ1$" instances/ee-a/.env.s0.bak && grep -q "^GOOGLE_KEY=segundoZ2$" instances/ee-a/.env.s0 && [ "$(mode instances/ee-a/.env.s0.bak)" = 600 ]'
check "un fallo al escribir no crea la copia" '
  cp "$FIX/rt.orig" "$F"; rm -f "$F.bak"
  ROOT="$PWD" bash -c "source lib/bootstrap.sh; envedit_emit() { return 1; }; ! envedit_set $F A 1" && [ ! -e "$F.bak" ]'

section "4. envedit_save valida antes de escribir"
check "un valor inválido no escribe nada (devuelve 1)" '
  cp instances/ee-a/.env.instance "$FIX/i.before"; r=0; run "envedit_save ee-a .env.instance S0_PORT abc" || r=$?; [ "$r" = 1 ] && cmp -s "$FIX/i.before" instances/ee-a/.env.instance'
check "un valor válido se guarda (devuelve 0)" 'run "envedit_save ee-a .env.instance S0_PORT 4123" && [ "$(run "get_var_r instances/ee-a/.env.instance S0_PORT; printf %s \$GV")" = 4123 ]'
check "un aviso (localhost en una URI de Mongo) guarda y deja EV_RC=2" '[ "$(run "envedit_save ee-a .env.s0 MONGO_URI mongodb://localhost/x; echo \$? \$EV_RC")" = "0 2" ]'
check "una variable fija no se escribe, ni con force" '[ "$(run "envedit_save ee-a .env.s0 SERVER_PORT 3200 1; echo \$?")" = "1" ] && ! grep -q "^SERVER_PORT=" instances/ee-a/.env.s0'
check "una clave desconocida se rechaza; con force se escribe" '
  [ "$(run "envedit_save ee-a .env.s0 INVENTADA x; echo \$?")" = "1" ] && ! grep -q "^INVENTADA=" instances/ee-a/.env.s0 \
  && run "envedit_save ee-a .env.s0 INVENTADA x 1" && grep -q "^INVENTADA=x$" instances/ee-a/.env.s0'
check "force escribe un valor inválido pero deja EV_RC=1 para avisar" '[ "$(run "envedit_save ee-a .env.instance S0_PORT abc 1; echo \$? \$EV_RC")" = "0 1" ]'
run "envedit_save ee-a .env.instance S0_PORT 4123" > /dev/null
check "un salto de línea en el valor se rechaza siempre, también con force" '[ "$(run "nl=\$(printf \"a\\nb\"); envedit_save ee-a .env.s0 GOOGLE_KEY \"\$nl\" 1; echo \$?")" = "1" ]'
check "guardar un secreto deja el archivo en 600" 'chmod 644 instances/ee-a/.env.s0; run "envedit_save ee-a .env.s0 GOOGLE_KEY k123" && [ "$(mode instances/ee-a/.env.s0)" = 600 ]'
check "el estado de una variable: falta / ejemplo / bien / por defecto / sin definir" '
  sed -i "s/^S0_TAG=.*/S0_TAG=/" instances/ee-a/.env.instance
  [ "$(run "for k in S0_TAG S0_PORT REGISTRY S0_MEM_LIMIT; do envedit_state_r ee-a .env.instance \$k; printf \"%s \" \$ED_STATE; done")" = "missing ok unset ok " ] \
  && sed -i "s/^S0_TAG=.*/S0_TAG=CAMBIAR-x/" instances/ee-a/.env.instance \
  && [ "$(run "envedit_state_r ee-a .env.instance S0_TAG; echo \$ED_STATE")" = "example" ] \
  && sed -i "s/^S0_TAG=.*/S0_TAG=1.0/" instances/ee-a/.env.instance'
check "envedit_state_value_r da el estado de un valor que ya se tiene (el que el editor del panel está cambiando), sin leer el archivo" '
  [ "$(run "for v in \"\" CAMBIAR-x 4100 abc; do envedit_state_value_r ee-a .env.instance S0_PORT \"\$v\"; printf \"%s \" \$ED_STATE; done")" = "missing example ok invalid " ] \
  && [ "$(run "envedit_state_value_r ee-a .env.s0 MONGO_URI mongodb://u:p@localhost:27017/a; echo \$ED_STATE")" = "warn" ] \
  && [ "$(run "envedit_state_value_r ee-a .env.s0 NODE_ENV x; echo \$ED_STATE")" = "fixed" ]'
check "el estado de un valor no repite el valor en el mensaje" '
  [ -z "$(run "envedit_state_value_r ee-a .env.instance S0_PORT SECRETO-abc; case \"\$EV_MSG\" in *SECRETO*) echo leak;; esac")" ]'
check "un secreto se muestra enmascarado, y vacío se muestra vacío" '[ "$(ROOT="$PWD" bash -c "source lib/bootstrap.sh; envedit_show .env.s0 JWT_SECRET abc; printf \"[%s]\" \"\$ED_SHOW\"; envedit_show .env.s0 JWT_SECRET \"\"; printf \"[%s]\" \"\$ED_SHOW\"")" = "[********][]" ]'

section "4b. las variables de un servicio que la instancia no usa no cuentan como pendientes"
# `new` deja el archivo de cada servicio del catálogo (con su plantilla por completar), pero la instancia solo corre los de COMPOSE_PROFILES.
D new ee-off > /dev/null 2>&1
check "robin no está en COMPOSE_PROFILES: su etiqueta vacía y su valor de ejemplo no son «por completar»" '
  [ "$(rget instances/ee-off/.env.instance COMPOSE_PROFILES)" = "s0,s1" ] \
  && [ "$(run "envedit_state_r ee-off .env.instance ROBIN_TAG; printf %s \$ED_STATE")" = "unset" ] \
  && [ "$(run "envedit_state_r ee-off .env.robin KAFKA_TOPIC; printf %s \$ED_STATE")" = "unset" ]'
check "lo de los servicios que sí corre se sigue pidiendo (s0: su IP_SERVER de ejemplo)" '
  [ "$(run "envedit_state_r ee-off .env.s0 IP_SERVER; printf %s \$ED_STATE")" = "example" ] \
  && [ "$(run "envedit_state_r ee-off .env.instance S0_TAG; printf %s \$ED_STATE")" = "missing" ]'
check "al sumar robin a COMPOSE_PROFILES vuelve a pedirse (etiqueta vacía = falta, tópico de ejemplo = por completar)" '
  rset instances/ee-off/.env.instance COMPOSE_PROFILES s0,s1,robin \
  && [ "$(run "envedit_state_r ee-off .env.instance ROBIN_TAG; printf %s \$ED_STATE")" = "missing" ] \
  && [ "$(run "envedit_state_r ee-off .env.robin KAFKA_TOPIC; printf %s \$ED_STATE")" = "example" ]'
check "una lista de servicios vacía o rota no esconde nada (se pide todo, como siempre)" '
  rset instances/ee-off/.env.instance COMPOSE_PROFILES "" \
  && [ "$(run "envedit_state_r ee-off .env.instance ROBIN_TAG; printf %s \$ED_STATE")" = "missing" ]'
check "un guardado suelta lo que se sabía: cambiar COMPOSE_PROFILES con envedit_save se nota en el mismo proceso" '
  [ "$(run "envedit_save ee-off .env.instance COMPOSE_PROFILES s0,s1 && envedit_state_r ee-off .env.instance ROBIN_TAG; printf %s \$ED_STATE")" = "unset" ]'


section "5. el comando env: ver"
check "list muestra las variables de cada archivo con su estado" 'out="$(D env ee-a list 2>&1)"; echo "$out" | grep -q "S0_PORT" && echo "$out" | grep -q "JWT_SECRET" && echo "$out" | grep -q "FEDERATION_ENCRYPTION_KEY"'
check "list no muestra las variables fijas (SERVER_PORT, NODE_ENV)" '! D env ee-a list 2>&1 | grep -qE "SERVER_PORT|NODE_ENV"'
rset instances/ee-a/.env.s0 GOOGLE_KEY zK9Distintiva 1
check "list oculta los secretos y no deja ver su valor" '
  ! D env ee-a list 2>&1 | grep -qF "zK9Distintiva" && D env ee-a list 2>&1 | grep -q "\*\*\*\*\*\*\*\*"'
check "list --reveal sí los muestra" 'D env ee-a list --reveal 2>&1 | grep -qF "zK9Distintiva"'
check "list s1 solo trae las variables de ese archivo" 'out="$(D env ee-a list s1 2>&1)"; echo "$out" | grep -q "DEEPGRAM_API_KEY" && ! echo "$out" | grep -q "PROFILE_SYNC_CONCURRENCY"'
check "list avisa de una variable obligatoria sin valor (FALTA) y del ejemplo sin cambiar (CAMBIAR)" '
  sed -i "s/^DEEPGRAM_API_KEY=.*/DEEPGRAM_API_KEY=/" instances/ee-a/.env.s1; sed -i "s/^IP_SERVER=.*/IP_SERVER=http:\/\/CAMBIAR-x/" instances/ee-a/.env.s1
  out="$(D env ee-a list s1 2>&1)"; echo "$out" | grep "DEEPGRAM_API_KEY" | grep -q FALTA && echo "$out" | grep "IP_SERVER" | grep -q CAMBIAR'
check "list enseña las variables que el archivo tiene y el glosario no conoce" 'echo "EXTRA_PROPIA=1" >> instances/ee-a/.env.s0; D env ee-a list s0 2>&1 | grep "EXTRA_PROPIA" | grep -q "fuera del glosario"'
check "list --json es JSON con el estado, y oculta los secretos" '
  out="$(D env ee-a list --json 2>&1)"; echo "$out" | grep -q "\"instance\": \"ee-a\"" && echo "$out" | grep -q "\"key\": \"JWT_SECRET\", \"value\": \"\*\*\*\*\*\*\*\*\", \"secret\": true"'
check "list --json valida con python (si hay)" 'command -v python3 >/dev/null || exit 0; D env ee-a list --json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"variables\"]"'
check "get de un valor normal lo imprime solo" '[ "$(D env ee-a get S0_PORT 2>/dev/null)" = "4123" ]'
check "get de un secreto imprime ******** y avisa por stderr, sin el valor" '
  o="$(D env ee-a get s0:GOOGLE_KEY 2>/dev/null)"; e="$(D env ee-a get s0:GOOGLE_KEY 2>&1 >/dev/null)"
  [ "$o" = "********" ] && ! echo "$e" | grep -qF "zK9Distintiva" && echo "$e" | grep -q -- "--reveal"'
check "get --reveal imprime el valor del secreto y nada más" '[ "$(D env ee-a get s0:GOOGLE_KEY --reveal 2>/dev/null)" = "zK9Distintiva" ]'
check "una clave que está en dos archivos pide elegir (s0:JWT_SECRET)" 'out="$(D env ee-a get JWT_SECRET 2>&1)"; rc=$?; [ "$rc" -ne 0 ] && echo "$out" | grep -q "s0:JWT_SECRET s1:JWT_SECRET"'
check "get de una variable que no está escrita en el archivo falla con aviso" 'sed -i "/^LIVEKIT_URL=/d" instances/ee-a/.env.s1; ! D env ee-a get s1:LIVEKIT_URL >/dev/null 2>&1'
check "get de una variable vacía (presente) devuelve línea vacía y éxito" 'D env ee-a get s1:DEEPGRAM_API_KEY >/dev/null 2>&1'
check "una instancia que no existe falla" '! D env zz-no list >/dev/null 2>&1'
check "un subcomando desconocido falla y lista los válidos" 'out="$(D env ee-a borrar 2>&1)"; [ $? -ne 0 ] || exit 1; echo "$out" | grep -q "list, get, set, generate"'
check "sin instancia da el uso" 'D env 2>&1 | grep -q "uso: ./deltactl env"'

section "6. el comando env: cambiar"
check "set S0_PORT 4110 lo guarda y avisa que hay que desplegar" 'out="$(D env ee-a set S0_PORT 4110 2>&1)"; echo "$out" | grep -q "S0_PORT=4110" && echo "$out" | grep -q "deploy ee-a" && grep -q "^S0_PORT=4110$" instances/ee-a/.env.instance'
check "CLAVE=valor es lo mismo que CLAVE valor" 'D env ee-a set S0_PORT=4111 >/dev/null 2>&1 && grep -q "^S0_PORT=4111$" instances/ee-a/.env.instance'
check "un valor inválido sale con error, explica por qué y no escribe" '
  cp instances/ee-a/.env.instance "$FIX/b4"; out="$(D env ee-a set S0_PORT abc 2>&1)"; rc=$?; [ "$rc" -ne 0 ] && echo "$out" | grep -q "puerto" && cmp -s "$FIX/b4" instances/ee-a/.env.instance'
check "un aviso (Mongo en localhost) guarda y avisa" 'out="$(D env ee-a set s0:MONGO_URI mongodb://localhost/db 2>&1)"; echo "$out" | grep -q "localhost" && grep -q "^MONGO_URI=mongodb://localhost/db$" instances/ee-a/.env.s0'
check "el aviso y la respuesta de un secreto no repiten su valor" '
  out="$(D env ee-a set s0:MONGO_URI mongodb://admin:pa55w0rdX@localhost/db 2>&1)"; ! echo "$out" | grep -q "pa55w0rdX" && ! echo "$out" | grep -q "admin"'
check "--force guarda un valor inválido y lo avisa" 'out="$(D env ee-a set S0_PORT abc --force 2>&1)"; echo "$out" | grep -q -- "--force" && grep -q "^S0_PORT=abc$" instances/ee-a/.env.instance'
D env ee-a set S0_PORT 4110 > /dev/null 2>&1
check "una variable fija se rechaza aunque se fuerce" '! D env ee-a set s0:SERVER_PORT 3200 --force >/dev/null 2>&1 && ! grep -q "^SERVER_PORT=" instances/ee-a/.env.s0'
check "una clave desconocida se rechaza; con archivo:CLAVE y --force se añade" '
  ! D env ee-a set s0:NO_EXISTE_X algo >/dev/null 2>&1 && ! grep -q "^NO_EXISTE_X=" instances/ee-a/.env.s0 \
  && D env ee-a set s0:NO_EXISTE_X algo --force >/dev/null 2>&1 && grep -q "^NO_EXISTE_X=algo$" instances/ee-a/.env.s0'
check "un archivo de variables desconocido da error con los válidos" 'out="$(D env ee-a set s9:X 1 2>&1)"; [ $? -ne 0 ] || exit 1; echo "$out" | grep -q "instance s0 s1"'
check "--stdin lee el valor de la entrada estándar" 'printf "desdeStdin\n" | D env ee-a set s0:GOOGLE_KEY --stdin >/dev/null 2>&1 && grep -q "^GOOGLE_KEY=desdeStdin$" instances/ee-a/.env.s0'
check "un secreto sin valor y sin terminal pide el valor (error, no escribe)" '
  cp instances/ee-a/.env.s0 "$FIX/b5"; ! D env ee-a set s0:GOOGLE_KEY </dev/null >/dev/null 2>&1 && cmp -s "$FIX/b5" instances/ee-a/.env.s0'
check "un valor que empieza con guion se pasa tras --" 'D env ee-a set s0:GOOGLE_KEY -- -guion >/dev/null 2>&1 && grep -q "^GOOGLE_KEY=-guion$" instances/ee-a/.env.s0'
check "un valor vacío explícito (CLAVE=) vacía la variable" 'D env ee-a set s0:GOOGLE_KEY= >/dev/null 2>&1 && grep -q "^GOOGLE_KEY=$" instances/ee-a/.env.s0'
check "una obligatoria no se deja vacía" '! D env ee-a set s0:JWT_SECRET= >/dev/null 2>&1'
check "el valor de un secreto NO aparece en la salida de set" 'out="$(D env ee-a set s0:GOOGLE_KEY valorSecretoZ 2>&1)"; ! echo "$out" | grep -q "valorSecretoZ" && grep -q "^GOOGLE_KEY=valorSecretoZ$" instances/ee-a/.env.s0'
check "el valor no queda en el historial de operaciones (runs) ni en ningún archivo salvo el .env y su copia" '
  [ -z "$(grep -rl "valorSecretoZ" instances "$FIX" 2>/dev/null | grep -vE "/\.env\.s0(\.bak)?$")" ]'
check "env no es una operación del historial (runs): no deja entrada" '! run "source lib/core/runs.sh; runs_is_mutation env set ee-a s0:X valorSecretoZ"'
check "sobra un argumento: error" '! D env ee-a get S0_PORT otro >/dev/null 2>&1'
check "una opción desconocida: error" '! D env ee-a list --nada >/dev/null 2>&1'
check "el mensaje sale en inglés con DELTACTL_LANG=en" 'DELTACTL_LANG=en D env ee-a set S0_PORT abc 2>&1 | grep -q "must be a port"'

section "7. el comando env: generar secretos"
check "generate de una variable sin generador falla" '! D env ee-a generate s0:GOOGLE_KEY --yes >/dev/null 2>&1'
check "con un valor ya puesto y sin terminal ni --yes pide confirmación: falla y no cambia nada" '
  cp instances/ee-a/.env.s1 "$FIX/b6"; ! D env ee-a generate s1:FEDERATION_ENCRYPTION_KEY </dev/null >/dev/null 2>&1 && cmp -s "$FIX/b6" instances/ee-a/.env.s1'
check "generate FEDERATION_ENCRYPTION_KEY --yes escribe base64 de 32 bytes, que pasa su validador" '
  D env ee-a generate s1:FEDERATION_ENCRYPTION_KEY --yes >/dev/null 2>&1; v="$(grep "^FEDERATION_ENCRYPTION_KEY=" instances/ee-a/.env.s1 | cut -d= -f2-)"
  [ "$(run "envschema_validate_r b64-32 \"$v\" \"\"; echo \$EV_RC")" = 0 ] && [ ${#v} = 44 ]'
check "el aviso de reemplazo de FEDERATION_ENCRYPTION_KEY dice que lo cifrado dejará de leerse" 'D env ee-a generate s1:FEDERATION_ENCRYPTION_KEY --yes 2>&1 | grep -qi "cifr"'
check "generate no imprime el valor generado" '
  out="$(D env ee-a generate s1:DELTA_UNIVERSITY_HANDOFF_SECRET --yes 2>&1)"; v="$(grep "^DELTA_UNIVERSITY_HANDOFF_SECRET=" instances/ee-a/.env.s1 | cut -d= -f2-)"
  [ ${#v} = 64 ] && ! echo "$out" | grep -qF "$v"'
check "un valor generado cambia en cada ejecución" 'a="$(grep "^SHIFT_UPDATE_BASELINE_SECRET=" instances/ee-a/.env.s1)"; D env ee-a generate s1:SHIFT_UPDATE_BASELINE_SECRET --yes >/dev/null 2>&1; [ "$a" != "$(grep "^SHIFT_UPDATE_BASELINE_SECRET=" instances/ee-a/.env.s1)" ]'
check "JWT_SECRET (compartido) se escribe igual en s0 y s1" '
  D env ee-a generate s0:JWT_SECRET --yes >/dev/null 2>&1
  a="$(grep "^JWT_SECRET=" instances/ee-a/.env.s0)"; b="$(grep "^JWT_SECRET=" instances/ee-a/.env.s1)"; [ "$a" = "$b" ] && [ ${#a} -gt 60 ]'
check "…y el aviso lo dice (mismo valor en s0 y s1, sesiones)" 'D env ee-a generate s1:JWT_SECRET --yes 2>&1 | grep -q "MISMO valor"'
check "sin valor previo no pide confirmación (aunque no haya terminal)" '
  sed -i "s/^SHIFT_UPDATE_BASELINE_SECRET=.*/SHIFT_UPDATE_BASELINE_SECRET=/" instances/ee-a/.env.s1; D env ee-a generate s1:SHIFT_UPDATE_BASELINE_SECRET </dev/null >/dev/null 2>&1 && [ "$(grep "^SHIFT_UPDATE_BASELINE_SECRET=" instances/ee-a/.env.s1 | cut -d= -f2- | wc -c)" = 49 ]'
check "un secreto generado deja el archivo en 600" 'chmod 644 instances/ee-a/.env.s1; D env ee-a generate s1:SHIFT_UPDATE_BASELINE_SECRET --yes >/dev/null 2>&1; [ "$(mode instances/ee-a/.env.s1)" = 600 ]'
check "generate sin openssl falla con un mensaje claro y no cambia nada" '
  mkdir -p "$FIX/nossl"; for b in bash cat sed grep head tr cut wc dirname basename mktemp mv rm cp chmod stat date sort uname id ls; do p="$(command -v $b)" && ln -sf "$p" "$FIX/nossl/$b"; done
  cp instances/ee-a/.env.s1 "$FIX/b7"; out="$(PATH="$FIX/nossl" /bin/bash ./deltactl env ee-a generate s1:FEDERATION_ENCRYPTION_KEY --yes 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && echo "$out" | grep -q openssl && cmp -s "$FIX/b7" instances/ee-a/.env.s1'

section "8. marca de «desplegado»: qué cambios faltan por aplicar"
newinst ee-b
check "sin marca (nunca desplegada) no se afirma nada: 'unknown'" '[ "$(run "envedit_deploy_state_r ee-b .env.s0; echo \$ED_DEPLOY")" = unknown ]'
check "mark_deployed guarda la suma de cada archivo (no su contenido) en .deployed" '
  run "envedit_mark_deployed ee-b 1 s0 s1" && grep -qE "^ENV_SUM_S0=[0-9a-f]{20,}$" instances/ee-b/.deployed && grep -qE "^ENV_SUM_INSTANCE=" instances/ee-b/.deployed && ! grep -q "JWT_SECRET" instances/ee-b/.deployed'
check "tras marcar, los archivos están sincronizados" '[ "$(run "for f in .env.instance .env.s0 .env.s1; do envedit_deploy_state_r ee-b \$f; printf \"%s \" \$ED_DEPLOY; done")" = "synced synced synced " ]'
check "cambiar un valor deja ese archivo pendiente y los demás no" '
  D env ee-b set s0:JWT_EXPIRES_IN 12h >/dev/null 2>&1; [ "$(run "envedit_pending ee-b")" = ".env.s0" ]'
check "env pending lo cuenta" 'D env ee-b pending 2>&1 | grep -q ".env.s0"'
check "volver al valor anterior vuelve a dejarlo sincronizado" 'D env ee-b set s0:JWT_EXPIRES_IN 8h >/dev/null 2>&1; [ -z "$(run "envedit_pending ee-b")" ] && D env ee-b pending 2>&1 | grep -q "Sin cambios pendientes"'
check "list avisa de los archivos pendientes" 'D env ee-b set s1:TCP_LISTEN_HOST 10.0.0.9 >/dev/null 2>&1; D env ee-b list 2>&1 | grep -q "Cambios sin desplegar.*\.env\.s1"'
check "list --json trae los archivos pendientes" 'D env ee-b list --json 2>&1 | grep -q "\"pending\": \[\"\.env\.s1\"\]"'
check "un deploy correcto (docker simulado) deja la marca de todos los archivos" '
  newinst ee-c; sed -i "s/^S0_PORT=.*/S0_PORT=29790/; s/^S1_PORT=.*/S1_PORT=29791/; s/^ROBIN_PORT=.*/ROBIN_PORT=29891/" instances/ee-c/.env.instance
  D deploy ee-c >/dev/null 2>&1; [ "$(run "for f in .env.instance .env.s0 .env.s1; do envedit_deploy_state_r ee-c \$f; printf \"%s \" \$ED_DEPLOY; done")" = "synced synced synced " ]'
check "un deploy de un solo servicio marca su archivo y NO el de la instancia" '
  newinst ee-d; sed -i "s/^S0_PORT=.*/S0_PORT=29792/; s/^S1_PORT=.*/S1_PORT=29793/; s/^ROBIN_PORT=.*/ROBIN_PORT=29893/" instances/ee-d/.env.instance
  D deploy ee-d s1 >/dev/null 2>&1; grep -q "^ENV_SUM_S1=" instances/ee-d/.deployed && ! grep -q "^ENV_SUM_S0=" instances/ee-d/.deployed && ! grep -q "^ENV_SUM_INSTANCE=" instances/ee-d/.deployed'
check "un deploy que falla no deja marca" '
  newinst ee-e; sed -i "s/^S0_PORT=.*/S0_PORT=29794/; s/^S1_PORT=.*/S1_PORT=29795/; s/^ROBIN_PORT=.*/ROBIN_PORT=29895/" instances/ee-e/.env.instance
  echo 23 > "$FIX/fail_pull"; sed -i "s/^REGISTRY=.*/REGISTRY=reg.test/" instances/ee-e/.env.instance; D deploy ee-e >/dev/null 2>&1; rm -f "$FIX/fail_pull"; ! grep -q "^ENV_SUM" instances/ee-e/.deployed 2>/dev/null'
check "las marcas de .deployed no rompen la lectura de las etiquetas desplegadas (status)" '
  [ "$(run "get_var_r instances/ee-c/.deployed S0_TAG; printf %s \$GV")" = "1.0" ]'

section "9. un secreto que el glosario no conoce tampoco se imprime"
newinst ee-f
# A variable typed by hand whose name says it is a secret: set does not repeat it, get and list mask it, the file stays private.
hidden_unknown() { # KEY
  local k="$1" v="valor-$1-Q7" out
  chmod 644 instances/ee-f/.env.s0
  out="$(D env ee-f set "s0:$k" "$v" --force 2>&1)"
  ! grep -qF "$v" <<< "$out" || { echo "set repite el valor"; return 1; }
  grep -qx "$k=$v" instances/ee-f/.env.s0 || { echo "no se guardó"; return 1; }
  [ "$(mode instances/ee-f/.env.s0)" = 600 ] || { echo "el archivo no quedó en 600"; return 1; }
  [ "$(D env ee-f get "s0:$k" 2>/dev/null)" = "********" ] || { echo "get no lo enmascara"; return 1; }
  [ "$(D env ee-f get "s0:$k" --reveal 2>/dev/null)" = "$v" ] || { echo "get --reveal no lo muestra"; return 1; }
  ! D env ee-f list s0 2>&1 | grep -qF "$v" || { echo "list lo muestra"; return 1; }
  D env ee-f list s0 --reveal 2>&1 | grep -qF "$v" || { echo "list --reveal no lo muestra"; return 1; }
}
for k in DB_PASSWD SMTP_PASS JWT_SECRET_OLD EXTRA_PASSWORD API_PWD MY_PRIVATE_THING AWS_CREDENTIALS; do
  check "$k escrito a mano se trata como un secreto en set, get y list" "hidden_unknown $k"
done
check "get con la clave sola (sin archivo) también lo enmascara" '[ "$(D env ee-f get DB_PASSWD 2>/dev/null)" = "********" ]'
check "list --json no trae el valor de un secreto desconocido y dice secret: true" '
  out="$(D env ee-f list s0 --json 2>&1)"; ! grep -qF "valor-DB_PASSWD-Q7" <<< "$out" && grep -F "\"key\": \"DB_PASSWD\"" <<< "$out" | grep -q "\"secret\": true"'
check "una variable que no parece secreta sí se ve (EXTRA_NOTE)" '
  D env ee-f set s0:EXTRA_NOTE visibleX --force >/dev/null 2>&1; [ "$(D env ee-f get s0:EXTRA_NOTE 2>/dev/null)" = "visibleX" ]'
check "envedit_is_secret: conocida por el glosario (JWT_SECRET) y desconocida por su nombre (DB_PASSWD); S0_PORT y EXTRA_NOTE no" '
  [ "$(run "for k in JWT_SECRET DB_PASSWD S0_PORT EXTRA_NOTE; do if envedit_is_secret .env.s0 \$k; then printf 1; else printf 0; fi; done")" = "1100" ]'
check "SERVERS_CONFIG (el JSON de los webhooks) es un secreto: set no lo repite y list lo enmascara" '
  out="$(D env ee-f set s1:SERVERS_CONFIG "{\"a\":\"tokenZZ9\"}" 2>&1)"; ! grep -qF tokenZZ9 <<< "$out" && ! D env ee-f list s1 2>&1 | grep -qF tokenZZ9'
check "envedit_show enmascara un secreto desconocido" '[ "$(run "envedit_show .env.s0 DB_PASSWD abc; printf %s \"\$ED_SHOW\"")" = "********" ]'

section "10. generate de un secreto compartido: confirma si cualquiera de los archivos tiene valor, y no deja uno distinto del otro"
newinst ee-i
sed -i 's/^JWT_SECRET=.*/JWT_SECRET=/' instances/ee-i/.env.s0
cp instances/ee-i/.env.s0 "$FIX/i0.before"; cp instances/ee-i/.env.s1 "$FIX/i1.before"
check "el valor está solo en s1: generate sobre s0, sin terminal ni --yes, pide confirmación (falla) y no cambia nada" '
  ! D env ee-i generate s0:JWT_SECRET </dev/null >/dev/null 2>&1 && cmp -s "$FIX/i0.before" instances/ee-i/.env.s0 && cmp -s "$FIX/i1.before" instances/ee-i/.env.s1'
check "…y el aviso dice en qué archivo está el valor que se reemplaza (s1)" 'D env ee-i generate s0:JWT_SECRET </dev/null 2>&1 | grep -q "JWT_SECRET ya tiene un valor.*\.env\.s1"'
check "con --yes se escribe el MISMO valor en s0 y s1" '
  D env ee-i generate s0:JWT_SECRET --yes >/dev/null 2>&1; a="$(grep "^JWT_SECRET=" instances/ee-i/.env.s0)"; b="$(grep "^JWT_SECRET=" instances/ee-i/.env.s1)"; [ "$a" = "$b" ] && [ ${#a} -gt 60 ]'
cp instances/ee-i/.env.s0 "$FIX/i0.before"; cp instances/ee-i/.env.s1 "$FIX/i1.before"
no_leftovers() { # nothing next to the env files but their .bak copies (no temporary, no private original)
  local f
  for f in instances/ee-i/.env.s[01].*; do
    [ -e "$f" ] || continue
    case "$f" in *.bak) ;; *) return 1 ;; esac
  done
}
check "si no se puede preparar el segundo archivo, el primero no cambia (todo o nada) y no queda ningún temporal" '
  r="$(ROOT="$PWD" bash -c "source lib/bootstrap.sh; envedit_emit() { case \"\$1\" in *.env.s1) return 1 ;; esac; command true; }; envedit_generate ee-i .env.s0 JWT_SECRET; echo \$?")"
  [ "$r" = 2 ] && cmp -s "$FIX/i0.before" instances/ee-i/.env.s0 && cmp -s "$FIX/i1.before" instances/ee-i/.env.s1 && no_leftovers'
check "si el segundo renombrado falla, el primero vuelve a lo que era y s0 y s1 siguen con el mismo valor" '
  r="$(ROOT="$PWD" bash -c "source lib/bootstrap.sh; n=0; mv() { n=\$((n + 1)); if [ \$n -eq 2 ]; then return 1; fi; command mv \"\$@\"; }; envedit_generate ee-i .env.s0 JWT_SECRET; echo \$?")"
  [ "$r" = 2 ] && cmp -s "$FIX/i0.before" instances/ee-i/.env.s0 && cmp -s "$FIX/i1.before" instances/ee-i/.env.s1 && no_leftovers'

section "11. lo que se escribe es lo que se valida: sin depender del locale, con la clave correcta y sin forzar lo que no se puede"
check "los validadores no dependen del locale: en en_US.UTF-8 un acento no es una letra de host ni un dígito árabe es un puerto" '
  [ "$(ROOT="$PWD" LC_ALL=en_US.UTF-8 bash -c "source lib/bootstrap.sh; envschema_validate_r host \"é.com\"; echo \$EV_RC")" = 1 ] \
  && [ "$(ROOT="$PWD" LC_ALL=en_US.UTF-8 bash -c "source lib/bootstrap.sh; envschema_validate_r tag \"é\"; echo \$EV_RC")" = 1 ] \
  && [ "$(ROOT="$PWD" LC_ALL=en_US.UTF-8 bash -c "source lib/bootstrap.sh; envschema_validate_r port \"٣٣\"; echo \$EV_RC")" = 1 ]'
check "set de un puerto con dígitos árabes sale con un error del validador (no con un fallo de aritmética) y no escribe" '
  cp instances/ee-a/.env.instance "$FIX/b12"; out="$(LC_ALL=en_US.UTF-8 D env ee-a set S0_PORT "٣٣" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ! echo "$out" | grep -qi "invalid\|integer\|constant" && cmp -s "$FIX/b12" instances/ee-a/.env.instance'
check "el nombre de la variable se valida también al guardar (envedit_save): con un salto de línea no escribe nada" '
  cp instances/ee-a/.env.s0 "$FIX/b13"; k="$(printf "A\nB")"
  r="$(ROOT="$PWD" bash -c "source lib/bootstrap.sh; envedit_save ee-a .env.s0 \"\$1\" x 1; echo \$?" _ "$k")"; [ "$r" = 1 ] && cmp -s "$FIX/b13" instances/ee-a/.env.s0'
check "--force no cambia INSTANCE a un nombre que no es el de la carpeta" '
  cp instances/ee-a/.env.instance "$FIX/b14"; ! D env ee-a set INSTANCE=otra --force >/dev/null 2>&1 && cmp -s "$FIX/b14" instances/ee-a/.env.instance'
check "un secreto pasado como argumento avisa (historial del shell y ps); con --stdin o una variable que no es secreta, no" '
  D env ee-a set s0:GOOGLE_KEY argvZ9 2>&1 | grep -q "historial de tu shell" \
  && ! { printf "stdinZ9\n" | D env ee-a set s0:GOOGLE_KEY --stdin 2>&1 | grep -q "historial de tu shell"; } \
  && ! D env ee-a set S0_PORT 4110 2>&1 | grep -q "historial de tu shell"'
check "--stdin lee todo: un valor con saltos de línea (un PEM) se rechaza en vez de cortarse en la primera línea en silencio" '
  cp instances/ee-a/.env.s0 "$FIX/b15"; ! { printf "linea1\nlinea2\n" | D env ee-a set s0:GOOGLE_KEY --stdin >/dev/null 2>&1; } && cmp -s "$FIX/b15" instances/ee-a/.env.s0'
check "--stdin quita solo el salto de línea final (con o sin CRLF)" '
  printf "valorZ\r\n" | D env ee-a set s0:GOOGLE_KEY --stdin >/dev/null 2>&1; grep -qx "GOOGLE_KEY=valorZ" instances/ee-a/.env.s0'
newinst ee-j
mkdir -p "$FIX/nosha"; for b in bash cat sed grep head tr cut wc dirname basename mktemp mv rm cp chmod stat date sort uname id ls cksum readlink; do p="$(command -v $b)" && ln -sf "$p" "$FIX/nosha/$b"; done
check "sin sha256sum no se marca nada (un CRC de 32 bits no es una prueba): env pending dice que no puede saberlo" '
  ROOT="$PWD" PATH="$FIX/nosha" /bin/bash -c "source lib/bootstrap.sh; envedit_mark_deployed ee-j 1 s0 s1" >/dev/null 2>&1; ! grep -q "^ENV_SUM" instances/ee-j/.deployed 2>/dev/null \
  && [ "$(run "envedit_deploy_state_r ee-j .env.s0; echo \$ED_DEPLOY")" = unknown ]'

section "12. un cambio hecho mientras se despliega sigue pendiente"
newinst ee-g
sed -i "s/^S0_PORT=.*/S0_PORT=29796/; s/^S1_PORT=.*/S1_PORT=29797/; s/^ROBIN_PORT=.*/ROBIN_PORT=29897/" instances/ee-g/.env.instance
# While compose runs `up`, another terminal changes a value: the containers got the old one.
printf 'cd %q && bash ./deltactl env ee-g set s0:JWT_EXPIRES_IN 9h > "$FIX/hook.out" 2>&1\n' "$PWD" > "$FIX/hook_up"
D deploy ee-g > /dev/null 2>&1
rm -f "$FIX/hook_up"
check "el deploy terminó bien y el cambio de en medio llegó al archivo" 'grep -q "^JWT_EXPIRES_IN=9h$" instances/ee-g/.env.s0 && grep -q "^ENV_SUM_S0=" instances/ee-g/.deployed'
check "…pero ese archivo queda PENDIENTE: la marca es la de antes del cambio" '[ "$(run "envedit_pending ee-g")" = ".env.s0" ] && D env ee-g pending 2>&1 | grep -q ".env.s0"'
check "…y los que no cambiaron quedan sincronizados" '[ "$(run "for f in .env.instance .env.s1; do envedit_deploy_state_r ee-g \$f; printf \"%s \" \$ED_DEPLOY; done")" = "synced synced " ]'
check "env set avisa cuando hay una operación en curso (deploy)" 'grep -q "operación en curso" "$FIX/hook.out" && grep -q "deploy ee-g" "$FIX/hook.out"'
check "sin operación en curso no avisa" '! D env ee-g set s0:JWT_EXPIRES_IN 8h 2>&1 | grep -q "operación en curso"'


finish

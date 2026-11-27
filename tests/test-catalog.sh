#!/usr/bin/env bash
# Tests del catálogo de servicios como datos (lib/core/catalog.data + lib/core/catalog.sh): de él salen KNOWN_SERVICES,
# la imagen por defecto, las variables obligatorias, la ayuda y lo que crea `new`. Se ejecuta desde la raíz de la copia aislada.
# shellcheck disable=SC2016  # los casos de check van entre comillas simples y se evalúan con eval
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS

rm -rf instances/ct-*
trap 'rm -rf instances/ct-* "$TMPD"' EXIT
TMPD="$(mktemp -d)"
# Ejecuta código con la capa de lib cargada (y, si se pide, otro catálogo ya leído).
run() { ROOT="$PWD" bash -c "source lib/bootstrap.sh; $1"; }

section "1. el catálogo reproduce lo que había escrito a mano"
check "KNOWN_SERVICES = s0 s1 robin, en ese orden" '[ "$(run "echo \${KNOWN_SERVICES[*]}")" = "s0 s1 robin" ]'
check "imagen por defecto de s0 y s1" '[ "$(run "default_repo s0; default_repo s1" | tr "\n" " ")" = "backend-s0 backend-s1 " ]'
check "un servicio desconocido no tiene imagen por defecto" '! run "default_repo s9" >/dev/null 2>&1'
check "service_repo_r usa el valor por defecto" '[ "$(run "service_repo_r s1; echo \$SR")" = "backend-s1" ]'
check "REQUIRED_S0" '[ "$(run "echo \${REQUIRED_S0[*]}")" = "IP_SERVER JWT_SECRET MONGO_URI IP_INTERNAL_CONNECTION" ]'
check "REQUIRED_S1 tiene 11 variables" '[ "$(run "echo \${#REQUIRED_S1[@]}")" = "11" ]'
check "variables de URI de Mongo de cada servicio" \
  '[ "$(run "source lib/cmd/check.sh; ck_mongo_vars s0; ck_mongo_vars s1" | tr "\n" ",")" = "MONGO_URI,MONGO_DELTA_DISPATCH_URI MONGO_AUTHSOFTWARE_URI MONGO_ROBIN_URI," ]'
check "s1 depende de s0 y s0 de nadie" '[ "$(run "catalog_depends s1; echo --; catalog_depends s0" | tr "\n" " ")" = "s0 -- " ]'
check "límite de memoria por defecto = el del compose" \
  '[ "$(run "echo \${CAT_MEM[s0]} \${CAT_MEM[s1]}")" = "110m 400m" ] && grep -q "S0_MEM_LIMIT:-110m" services/compose-s0.yaml && grep -q "S1_MEM_LIMIT:-400m" services/compose-s1.yaml'
check "puerto interno y desplazamiento de puerto" '[ "$(run "echo \${CAT_PORT[s0]} \${CAT_PORT[s1]} \${CAT_OFFSET[s0]} \${CAT_OFFSET[s1]}")" = "3200 3000 0 1" ]'
check "cada plantilla del catálogo existe" 'run "for s in \${KNOWN_SERVICES[@]}; do [ -f templates/\${CAT_TEMPLATE[\$s]} ] || exit 1; done"'
check "el archivo de datos no tiene filas con otro número de campos" \
  '! grep -vE "^(#|$)" lib/core/catalog.data | awk -F"|" "NF != 13" | grep -q .'

section "2. leer el catálogo no lanza procesos"
check "catalog_load no usa subprocesos (sin comillas de \$() ni pipes en el cuerpo)" \
  '! sed -n "/^catalog_load()/,/^}/p" lib/core/catalog.sh | grep -qE "\\$\\(|\\| *(grep|awk|sed|cut|tr)"'
check "arranque: la capa completa carga en menos de 1,5 s aunque el catálogo se lea" '
  s=$(date +%s%N); for i in 1 2 3; do run ":" ; done; e=$(date +%s%N); [ $(( (e - s) / 3000000 )) -lt 1500 ]'

section "3. un servicio nuevo es una línea de datos"
CAT="$TMPD/catalog.data"
cp lib/core/catalog.data "$CAT"
printf 'walle|walle-backend|walle|3700|3|.env.walle.example|IP_SERVER PORT||s0|1g|media logs|CERT_FILE|TOKEN_SECRET:hex32 JWT_SECRET:shared\n' >> "$CAT"
check "catalog_load lee otra ruta y suma el servicio" '[ "$(run "catalog_load $CAT; echo \${KNOWN_SERVICES[*]}")" = "s0 s1 robin walle" ]'
check "su imagen por defecto sale de la fila" '[ "$(run "catalog_load $CAT; default_repo walle")" = "walle" ]'
check "su REQUIRED_WALLE sale de la fila" '[ "$(run "catalog_load $CAT; echo \${REQUIRED_WALLE[*]}")" = "IP_SERVER PORT" ]'
check "valid_service lo acepta" 'run "catalog_load $CAT; valid_service walle"'
check "una clave que no es una palabra en minúsculas (1x, Bad-Key) o que es 'instance' se ignora" \
  '[ "$(printf "1x|a|b\nBad-Key|a|b\ninstance|a|b\n" >> "$CAT"; run "catalog_load $CAT; echo \${#KNOWN_SERVICES[@]}")" = "4" ]'
check "la clave de un servicio puede ser una palabra (robin) y no solo sN" '[ "$(run "echo \${REQUIRED_ROBIN[0]} \${CAT_OFFSET[robin]} \${CAT_PORT[robin]}")" = "JWT_SECRET 2 3601" ]'
check "la guía de servicios lo lista en español" '[ "$(run "catalog_load $CAT; catalog_help_lines" | grep -c "^- ")" = "4" ] || run "catalog_load $CAT; catalog_help_lines" | grep -q "walle-backend"'
check "un comentario o línea vacía no es servicio" '[ "$(printf "\n# comentario\n" >> "$CAT"; run "catalog_load $CAT; echo \${#KNOWN_SERVICES[@]}")" = "4" ]'

section "4. new crea lo que dice el catálogo"
bash ./deltactl new ct-uno --generate-secrets >/dev/null 2>&1
check "crea .env.s0 y .env.s1 con permisos 600" '[ "$(stat -c %a instances/ct-uno/.env.s0 instances/ct-uno/.env.s1 | tr "\n" " ")" = "600 600 " ]'
check "crea las carpetas de datos del catálogo" \
  '[ -d instances/ct-uno/data/s0/media/certificate-settings ] && [ -d instances/ct-uno/data/s0/backups ] && [ -d instances/ct-uno/data/s1/imageIncidentsResolved ] && [ -d instances/ct-uno/data/s1/uploads ]'
check "puertos: s0 en el bloque y s1 en el siguiente" \
  'p="$(grep ^S0_PORT= instances/ct-uno/.env.instance | cut -d= -f2)"; [ "$(grep ^S1_PORT= instances/ct-uno/.env.instance | cut -d= -f2)" = "$((p + 1))" ]'
check "JWT_SECRET compartido entre s0 y s1" \
  'a="$(grep ^JWT_SECRET= instances/ct-uno/.env.s0)"; [ "$a" = "$(grep ^JWT_SECRET= instances/ct-uno/.env.s1)" ] && [ ${#a} -gt 20 ]'
check "s1 recibe sus secretos generados" \
  'for k in FEDERATION_ENCRYPTION_KEY DELTA_UNIVERSITY_HANDOFF_SECRET SHIFT_UPDATE_BASELINE_SECRET; do v="$(grep "^$k=" instances/ct-uno/.env.s1 | cut -d= -f2)"; [ -n "$v" ] && [[ "$v" != *CAMBIAR* ]] || exit 1; done'
check "las bases de datos llevan el nombre de la instancia" 'grep -q "^MONGO_URI=.*s0_ct-uno$" instances/ct-uno/.env.s0'
check "una opción --sN-tag de un servicio que no existe falla" '! bash ./deltactl new ct-dos --s9-tag 1 >/dev/null 2>&1 && [ ! -e instances/ct-dos ]'
check "--s1-tag y --s0-image siguen funcionando" \
  'bash ./deltactl new ct-tres --s1-tag 2.5 --s0-image otra-imagen >/dev/null 2>&1; grep -q "^S1_TAG=2.5" instances/ct-tres/.env.instance && grep -q "^S0_IMAGE=otra-imagen" instances/ct-tres/.env.instance'

section "5. new con un servicio que solo existe en el catálogo"
# Copia aislada: se añade la fila, su plantilla y su variable de puerto, y no hace falta tocar ningún .sh.
cp lib/core/catalog.data "$TMPD/orig.data"
printf 'walle|walle-backend|walle|3700|3|.env.walle.example|IP_SERVER||s0|1g|media logs||TOKEN_SECRET:hex32 JWT_SECRET:shared\n' >> lib/core/catalog.data
printf 'IP_SERVER=CAMBIAR\nTOKEN_SECRET=CAMBIAR\nMONGO_X=mongodb://h/CAMBIAR_walle_INSTANCIA\n' > templates/.env.walle.example
bash ./deltactl new ct-wal --services s0,walle --walle-tag 9 --walle-image walle-x --generate-secrets >/dev/null 2>&1
check "crea .env.walle desde su plantilla" '[ -f instances/ct-wal/.env.walle ] && [ "$(stat -c %a instances/ct-wal/.env.walle)" = "600" ]'
check "crea sus carpetas de datos" '[ -d instances/ct-wal/data/walle/media ] && [ -d instances/ct-wal/data/walle/logs ]'
check "su puerto es base + desplazamiento" \
  'p="$(grep ^S0_PORT= instances/ct-wal/.env.instance | cut -d= -f2)"; grep -q "^WALLE_PORT=$((p + 3))$" instances/ct-wal/.env.instance'
check "guarda su etiqueta e imagen" 'grep -q "^WALLE_TAG=9" instances/ct-wal/.env.instance && grep -q "^WALLE_IMAGE=walle-x" instances/ct-wal/.env.instance'
check "genera sus secretos y comparte el JWT con el resto" \
  '[ -n "$(grep ^TOKEN_SECRET= instances/ct-wal/.env.walle | cut -d= -f2)" ] && ! grep -q "TOKEN_SECRET=CAMBIAR" instances/ct-wal/.env.walle && grep -q "^JWT_SECRET=$(grep ^JWT_SECRET= instances/ct-wal/.env.s0 | cut -d= -f2)$" instances/ct-wal/.env.walle'
check "el nombre de la instancia entra en el marcador de la base" 'grep -q "walle_ct-wal" instances/ct-wal/.env.walle'
check "list muestra la columna del servicio nuevo" 'bash ./deltactl list 2>&1 | grep -q "WALLE_TAG"'
check "deploy valida las variables obligatorias del servicio nuevo" \
  'sed -i "s/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=walle/" instances/ct-wal/.env.instance; sed -i "s/^IP_SERVER=.*/IP_SERVER=/" instances/ct-wal/.env.walle; out="$(DELTACTL_NO_RUNS=1 bash ./deltactl deploy ct-wal 2>&1)"; echo "$out" | grep -q "IP_SERVER"'
check "la ayuda de servicios lo lista" 'bash ./deltactl help servicios 2>&1 | grep -q "walle. walle-backend"'
check "el completado de new ofrece sus opciones" 'bash ./deltactl completion bash | grep -q -- "--walle-image .*--walle-tag"'
cp "$TMPD/orig.data" lib/core/catalog.data
rm -f templates/.env.walle.example

finish

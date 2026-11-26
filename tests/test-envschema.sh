#!/usr/bin/env bash
# Tests del esquema de variables de entorno (lib/core/envschema.sh + envschema.data): la tabla que sale del glosario, las plantillas y el
# catálogo, y cada validador con valores válidos, inválidos y de borde. Se ejecuta desde la raíz de la copia aislada.
# shellcheck disable=SC2016  # los casos de check van entre comillas simples y se evalúan con eval
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
# Ejecuta código con la capa de lib cargada y el esquema leído.
run() { ROOT="${ROOT_OVERRIDE:-$PWD}" bash -c "source lib/bootstrap.sh; envschema_load; $1"; }

# Casos de un validador: líneas "valor" (esperado 0), "!valor" (esperado 1) o "?valor" (esperado 2, aviso). Ejecuta todos en UN proceso y
# deja en la salida los que no dan lo esperado (vacía = todo bien).
vcases() { # validador  (los casos por la entrada estándar)
  ROOT="$PWD" VNAME="$1" bash -c '
    source lib/bootstrap.sh
    while IFS= read -r line; do
      case "$line" in "!"*) want=1; v="${line#!}" ;; "?"*) want=2; v="${line#\?}" ;; *) want=0; v="$line" ;; esac
      envschema_validate_r "$VNAME" "$v" ""
      [ "$EV_RC" = "$want" ] || printf "valor <%s>: esperaba %s y dio %s\n" "$v" "$want" "$EV_RC"
    done'
}

section "1. la tabla sale del glosario, las plantillas y el catálogo"
check "cada variable del glosario está en el esquema (52 con las del catálogo)" \
  '[ "$(run "echo \${#ENV_IDS[@]}")" -ge 50 ]'
check "la clave es archivo|VARIABLE y una misma variable puede estar en dos archivos" \
  'run "[ -n \"\${ENV_KEY[.env.s0|JWT_SECRET]}\" ] && [ -n \"\${ENV_KEY[.env.s1|JWT_SECRET]}\" ]"'
check "el orden es el del glosario (INSTANCE primero, SIPCOP_ALERT_RESYNC al final)" \
  '[ "$(run "echo \${ENV_IDS[0]} \${ENV_IDS[-1]}")" = ".env.instance|INSTANCE .env.s1|SIPCOP_ALERT_RESYNC" ]'
check "tipo del glosario: obligatoria, opcional y fija" \
  '[ "$(run "echo \${ENV_TYPE[.env.s0|JWT_SECRET]} \${ENV_TYPE[.env.s0|JWT_EXPIRES_IN]} \${ENV_TYPE[.env.s0|SERVER_PORT]}")" = "req opt fixed" ]'
check "el valor por defecto sale del glosario" \
  '[ "$(run "echo \${ENV_DEFAULT[.env.instance|S0_PORT]} \${ENV_DEFAULT[.env.s0|JWT_EXPIRES_IN]}")" = "4100 8h" ]'
check "«ninguno» y «lo pone ./deltactl new» no son un valor por defecto" \
  '[ "$(run "echo \${ENV_HASDEF[.env.s0|JWT_SECRET]}\${ENV_HASDEF[.env.instance|INSTANCE]}")" = "00" ]'
check "«vacío» sí lo es, con valor vacío" \
  '[ "$(run "echo \${ENV_HASDEF[.env.instance|REGISTRY]}:\${ENV_DEFAULT[.env.instance|REGISTRY]}")" = "1:" ]'
check "un valor por defecto descrito con texto («desactivada») no se ofrece como valor" \
  '[ "$(run "echo \${ENV_HASDEF[.env.s1|SIPCOP_ALERT_RESYNC]}")" = "0" ] && [ "$(run "echo \${ENV_DEFNOTE[.env.s1|SIPCOP_ALERT_RESYNC]}")" = "desactivada" ]'
check "un valor por defecto con marcador (<INSTANCE>) tampoco" \
  '[ "$(run "echo \${ENV_HASDEF[.env.instance|DATA_DIR]}")" = "0" ]'
check "la descripción sale del glosario, en una línea" \
  '[ "$(run "echo \${ENV_DESC[.env.s0|JWT_EXPIRES_IN]}")" = "Duración de los tokens JWT." ] && [ "$(run "echo \${ENV_DESC[.env.s0|IP_SERVER]}" | wc -l)" = "1" ]'
check "en inglés usa el glosario en inglés" \
  '[ "$(DELTACTL_LANG=en run "echo \${ENV_DESC[.env.s0|JWT_EXPIRES_IN]}")" = "Lifetime of the JWT tokens." ]'
check "en inglés el tipo se entiende igual (required → req)" \
  '[ "$(DELTACTL_LANG=en run "echo \${ENV_TYPE[.env.s0|JWT_SECRET]}")" = "req" ]'
check "el valor de ejemplo sale de la plantilla" '[ -n "$(run "echo \${ENV_EXAMPLE[.env.instance|INSTANCE]}")" ] || [ -n "$(run "echo \${ENV_EXAMPLE[.env.instance|S0_PORT]}")" ]'
check "las obligatorias del catálogo (REQUIRED_S0/S1) están marcadas obligatorias" \
  '[ -z "$(run "for s in \${KNOWN_SERVICES[@]}; do declare -n r=REQUIRED_\${s^^}; for k in \${r[@]}; do [ \"\${ENV_REQUIRED[.env.\$s|\$k]}\" = 1 ] || echo \$s \$k; done; done")" ]'
check "las fijas no cuentan como obligatorias" '[ "$(run "echo \${ENV_REQUIRED[.env.s0|SERVER_PORT]}")" = "0" ]'
check "cargar dos veces no duplica" '[ "$(run "n=\${#ENV_IDS[@]}; envschema_load; echo \$((n - \${#ENV_IDS[@]}))")" = "0" ]'
check "leer el esquema no lanza procesos (el cuerpo de envschema_load y sus lectores no usan \$() ni tuberías)" \
  '! sed -n "/^envschema_read_glossary()/,/^}/p;/^envschema_read_template()/,/^}/p;/^envschema_rules_load()/,/^}/p" lib/core/envschema.sh | grep -qE "\\$\\(|\\| *(grep|awk|sed|cut|tr)"'

section "2. generadores y secretos"
check "de los generadores se encarga el catálogo: JWT_SECRET shared, FEDERATION_ENCRYPTION_KEY b64-32, handoff hex32, baseline hex24" \
  '[ "$(run "echo \$(envschema_generator .env.s0 JWT_SECRET) \$(envschema_generator .env.s1 FEDERATION_ENCRYPTION_KEY) \$(envschema_generator .env.s1 DELTA_UNIVERSITY_HANDOFF_SECRET) \$(envschema_generator .env.s1 SHIFT_UPDATE_BASELINE_SECRET)")" = "shared b64-32 hex32 hex24" ]'
check "una variable sin generador no devuelve nada" '[ -z "$(run "envschema_generator .env.s0 GOOGLE_KEY")" ]'
check "son secretas: JWT_SECRET, las URI de Mongo, las claves de API y los tokens" \
  'run "for id in .env.s0\|JWT_SECRET .env.s0\|MONGO_URI .env.s1\|MONGO_ROBIN_URI .env.s1\|DEEPGRAM_API_KEY .env.s1\|LIVEKIT_API_SECRET .env.s1\|VERIFY_TOKEN .env.s0\|GOOGLE_KEY .env.s1\|API_KEY_CLOUD_MESSAGING; do [ \"\${ENV_SECRET[\$id]}\" = 1 ] || { echo \$id; exit 1; }; done"'
check "no son secretas: puertos, URL públicas, memoria, rutas /run/secrets y los TTL" \
  'run "for id in .env.instance\|S0_PORT .env.s0\|IP_SERVER .env.instance\|S1_MEM_LIMIT .env.s1\|FCM_CERT .env.s1\|KEEPER_FCM_CERT .env.s1\|LIVEKIT_TOKEN_TTL_SECONDS .env.s0\|JWT_EXPIRES_IN; do [ \"\${ENV_SECRET[\$id]}\" = 0 ] || { echo \$id; exit 1; }; done"'

section "3. una variable nueva en el glosario aparece sin más cambios"
GL="$TMPD/root"
mkdir -p "$GL/lib/help" "$GL/lib/core"
cp -r lib "$GL/" && cp -r templates "$GL/"
cat >> "$GL/lib/help/variables.txt" <<'EOF'

@ NUEVA_CLAVE_API_KEY | .env.s0 | opcional | ninguno
Una variable que acaba de añadirse al glosario.

@ NUEVO_LIMITE_PORT | .env.s0 | obligatoria | 8080
Otra, con puerto.
EOF
check "aparece en el esquema" '[ "$(ROOT_OVERRIDE="$GL" run "echo \${ENV_KEY[.env.s0|NUEVA_CLAVE_API_KEY]}")" = "NUEVA_CLAVE_API_KEY" ]'
check "su validador y su carácter de secreta salen del nombre (…_API_KEY → secreta)" \
  '[ "$(ROOT_OVERRIDE="$GL" run "echo \${ENV_SECRET[.env.s0|NUEVA_CLAVE_API_KEY]}")" = "1" ]'
check "…_PORT → puerto, obligatoria y con su valor por defecto" \
  '[ "$(ROOT_OVERRIDE="$GL" run "echo \${ENV_VALIDATOR[.env.s0|NUEVO_LIMITE_PORT]} \${ENV_REQUIRED[.env.s0|NUEVO_LIMITE_PORT]} \${ENV_DEFAULT[.env.s0|NUEVO_LIMITE_PORT]}")" = "port 1 8080" ]'
check "una regla de envschema.data manda sobre el nombre" '
  printf "%s\n" ".env.s0:NUEVA_CLAVE_API_KEY|bool|0" | cat - "$GL/lib/core/envschema.data" > "$GL/lib/core/envschema.data.new" && mv "$GL/lib/core/envschema.data.new" "$GL/lib/core/envschema.data"
  [ "$(ROOT_OVERRIDE="$GL" run "echo \${ENV_VALIDATOR[.env.s0|NUEVA_CLAVE_API_KEY]} \${ENV_SECRET[.env.s0|NUEVA_CLAVE_API_KEY]}")" = "bool 0" ]'

section "4. un servicio que solo tiene plantilla también tiene esquema"
SV="$TMPD/svc"
mkdir -p "$SV"
cp -r lib templates "$SV/"
printf 's2|walle-backend|walle|3700|2|.env.s2.example|IP_SERVER PORT||s0|1g|media|CERT_FILE|TOKEN_SECRET:hex32\n' >> "$SV/lib/core/catalog.data"
printf '# plantilla de s2\nIP_SERVER=http://localhost\nPORT=3700\nTOKEN_SECRET=CAMBIAR\n' > "$SV/templates/.env.s2.example"
check "las claves de la plantilla entran como opcionales y con su ejemplo" \
  '[ "$(ROOT_OVERRIDE="$SV" run "echo \${ENV_EXAMPLE[.env.s2|PORT]}")" = "3700" ]'
check "las obligatorias del catálogo (IP_SERVER, PORT) quedan obligatorias" \
  '[ "$(ROOT_OVERRIDE="$SV" run "echo \${ENV_REQUIRED[.env.s2|IP_SERVER]}\${ENV_REQUIRED[.env.s2|PORT]}")" = "11" ]'
check "TOKEN_SECRET es secreta y la puede generar el catálogo (hex32)" \
  '[ "$(ROOT_OVERRIDE="$SV" run "echo \${ENV_SECRET[.env.s2|TOKEN_SECRET]} \$(envschema_generator .env.s2 TOKEN_SECRET)")" = "1 hex32" ]'
check "S2_TAG y S2_PORT del archivo de instancia pasan a obligatorias" \
  '[ "$(ROOT_OVERRIDE="$SV" run "echo \${ENV_REQUIRED[.env.instance|S2_TAG]}\${ENV_REQUIRED[.env.instance|S2_PORT]}")" = "11" ]'

section "5. validadores: puerto"
check "puerto: 1, 80, 4100 y 65535 valen; 0, 65536, vacío, letras y negativos no" \
  '[ -z "$(printf "%s\n" 1 80 4100 65535 "!0" "!65536" "!" "!abc" "!-1" "!80a" "!99999" "!100000" | vcases port)" ]'
check "puerto: ceros a la izquierda (0080) valen como 80" '[ -z "$(printf "%s\n" 0080 | vcases port)" ]'
section "6. validadores: URI de Mongo (avisa localhost)"
check "mongo: URI normales valen" \
  '[ -z "$(printf "%s\n" "mongodb://db.interno:27017/auth" "mongodb://u:p@host.docker.internal:27017/auth?authSource=admin" "mongodb+srv://u:p@c0.ab.mongodb.net/db" "mongodb://h1:27017,h2:27017/x?replicaSet=r" | vcases mongo-uri)" ]'
check "mongo: localhost, 127.x y ::1 avisan (2), también dentro de un replica set" \
  '[ -z "$(printf "%s\n" "?mongodb://localhost/x" "?mongodb://127.0.0.1:27017/x" "?mongodb://[::1]:27017/x" "?mongodb://u:p@LOCALHOST/x" "?mongodb://h1:27017,127.0.0.1:27017/x" | vcases mongo-uri)" ]'
check "mongo: una contraseña con @ no se toma por host (adm:p@ssw0rd@db1)" \
  '[ -z "$(printf "%s\n" "mongodb://adm:p@ssw0rd@db1:27017/x" "?mongodb://adm:p@ssw0rd@localhost:27017/x" | vcases mongo-uri)" ]'
check "mongo: un @ en las opciones tampoco (?authSource=a@b)" '[ -z "$(printf "%s\n" "mongodb://db1:27017/x?authSource=a@b" | vcases mongo-uri)" ]'
check "mongo: sin esquema, otro esquema, sin host o con espacios no valen" \
  '[ -z "$(printf "%s\n" "!db:27017/x" "!http://db/x" "!mongodb://" "!mongodb:///x" "!mongodb://h/a b" "!" | vcases mongo-uri)" ]'
check "mongo: el aviso no repite el valor (puede llevar la contraseña)" '
  [ -z "$(run "envschema_validate_r mongo-uri mongodb://admin:sup3rsecreta@localhost/x \"\"; case \"\$EV_MSG\" in *sup3rsecreta*|*admin*) echo LEAK ;; esac")" ]'
section "7. validadores: URL"
check "URL pública: http(s)://host, IP y localhost valen; un puerto avisa" \
  '[ -z "$(printf "%s\n" "http://localhost" "https://delta.example.com" "http://10.1.2.3" "http://[::1]" "?http://h:8080" "!http://h/" "!h" "!ftp://h" "!https://" "!http://h/x" "!http://h /x" | vcases public-url)" ]'
check "URL pública: una referencia (\${IP_SERVER}) vale" '[ -z "$(printf "%s\n" "\${IP_SERVER}" "\${IP_SERVER}:3200" | vcases public-url)" ]'
check "URL: con puerto y ruta vale; con barra final, sin esquema o con espacio no" \
  '[ -z "$(printf "%s\n" "http://s0:3200" "https://auth.example.com/api" "\${IP_SERVER}:3200" "!http://s0:3200/" "!s0:3200" "!http://a b" "!" | vcases url)" ]'
check "URL de LiveKit: ws://, wss://, http:// y https:// valen" \
  '[ -z "$(printf "%s\n" "wss://lk.example.com" "ws://10.0.0.1:7880" "https://lk.example.com" "!ftp://x" "!lk.example.com" | vcases url-ws)" ]'
section "8. validadores: secretos y rutas"
check "base64 de 32 bytes: 44 caracteres con un =; más corto, más largo o sin = no" \
  '[ -z "$(printf "%s\n" "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ=" "!AAAA" "!AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" "!AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" "!AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" "!AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA@=" "!" | vcases b64-32)" ]'
check "base64: lo que genera openssl rand -base64 32 vale" 'v="$(openssl rand -base64 32)"; [ -z "$(printf "%s\n" "$v" | vcases b64-32)" ]'
check "ruta de secreto: /run/secrets/<archivo> vale; el contenido, otra carpeta o ../ no" \
  '[ -z "$(printf "%s\n" "/run/secrets/fcm.json" "/run/secrets/keeper-fcm.json" "!{\"a\":1}" "!/etc/passwd" "!/run/secrets/../etc/x" "!/run/secrets/" "!fcm.json" "!" | vcases secret-path)" ]'
check "secreto de 32+ caracteres sin espacios" \
  '[ -z "$(printf "%s\n" "0123456789abcdef0123456789abcdef" "$(printf "x%.0s" $(seq 40))" "!0123456789abcdef0123456789abcde" "!0123456789abcdef 123456789abcdef0123" "!" | vcases secret-min32)" ]'
check "ruta (path): vale casi todo, menos caracteres de control" '[ -z "$(printf "%s\n" "./backups" "/mnt/discos/datos" "datos con espacio" "!$(printf "a\tb")" | vcases path)" ]'
section "9. validadores: tamaños, banderas, listas y nombres"
check "memoria: 512m, 2g, 1.5g, 1024, 512mb, 256K valen; 0, 0m, -1, m, 1x no" \
  '[ -z "$(printf "%s\n" 512m 2g 1.5g 1024 512mb 256K 1G "!0" "!0m" "!0.0g" "!-1" "!m" "!1x" "!" "!2 g" | vcases memory)" ]'
check "booleano: solo true y false, en minúsculas" '[ -z "$(printf "%s\n" true false "!True" "!1" "!yes" "!" | vcases bool)" ]'
check "entero: dígitos solamente" '[ -z "$(printf "%s\n" 0 4 600 "!-1" "!1.5" "!x" "!" | vcases int)" ]'
check "etiqueta: versiones y commits valen; latest avisa; espacios, :, vacío y empezar con - no" \
  '[ -z "$(printf "%s\n" 1.2.3 v1.2.3 2026.11.3 abc1234 1.2.3-rc.1 "?latest" "!1.2 3" "!a:b" "!" "!-x" "!a/b" | vcases tag)" ]'
check "nombre de imagen: sin etiqueta ni registry en mayúsculas" \
  '[ -z "$(printf "%s\n" backend-s0 backend-s1 s0 mi/imagen "!Auth" "!a:1.0" "!" "!a b" | vcases image-name)" ]'
check "servicios: s0, s1, s0,s1; desconocido, repetido, espacios, comas sobrantes o vacío no" \
  '[ -z "$(printf "%s\n" s0 s1 s0,s1 s1,s0 "!s9" "!s0,s0" "!s0, s1" "!s0,,s1" "!,s0" "!s0," "!" | vcases services-list)" ]'
check "servicios: mensaje que nombra el servicio desconocido" '[ "$(run "envschema_validate_r services-list s0,s9 \"\"; echo \$EV_MSG")" = "servicio desconocido: s9" ]'
check "nombre de instancia: minúsculas, números y guion" '[ -z "$(printf "%s\n" demo mi-instancia a1 "!A" "!1a" "!a" "!a_b" "!" | vcases instance-name)" ]'
check "nombre de instancia: debe coincidir con la carpeta (EV_INSTANCE)" '
  [ "$(run "envschema_validate_r instance-name demo demo; echo \$EV_RC; envschema_validate_r instance-name demo otra; echo \$EV_RC")" = "$(printf "0\n1")" ]'
check "registry: vacío, host, host:puerto y host/ruta valen; con esquema o barra final no" \
  '[ -z "$(printf "%s\n" "" registry.ejemplo.com registry.ejemplo.com:5000 registry.ejemplo.com/itc "!https://registry.ejemplo.com" "!registry.ejemplo.com/" "!a b" | vcases registry)" ]'
check "duración: 8h, 30m, 3600, 7d vale; 8 horas o h no" '[ -z "$(printf "%s\n" 8h 30m 3600 7d 500ms "!8 horas" "!h" "!" | vcases duration)" ]'
check "host: nombres, IPv4, [IPv6] y 0.0.0.0 valen; con espacio, con esquema o vacío no" \
  '[ -z "$(printf "%s\n" 127.0.0.1 0.0.0.0 s1 host.interno "[::1]" "!http://h" "!a b" "!" "!-a" | vcases host)" ]'
check "JSON en una línea: [] y {…} valen; texto, varias líneas o vacío no" '[ -z "$(printf "%s\n" "[]" "[{\"a\":1}]" "{\"a\":1}" "!texto" "!" "![" | vcases json-line)" ]'

section "10. comprobación de una variable del esquema (envschema_check_r)"
check "una obligatoria vacía es un error; una opcional vacía no" \
  '[ "$(run "envschema_check_r .env.s0 JWT_SECRET \"\"; echo \$EV_RC; envschema_check_r .env.s0 GOOGLE_KEY \"\"; echo \$EV_RC" | tr "\n" " ")" = "1 0 " ]'
check "una fija no va en el .env" '[ "$(run "envschema_check_r .env.s0 SERVER_PORT 3200; echo \$EV_RC")" = "1" ]'
check "una variable desconocida es un error (la CLI deja forzarla)" '[ "$(run "envschema_check_r .env.s0 INVENTADA x; echo \$EV_RC")" = "1" ]'
check "usa el validador de su variable: S0_PORT=abc falla y S0_PORT=4110 vale" \
  '[ "$(run "envschema_check_r .env.instance S0_PORT abc; echo \$EV_RC; envschema_check_r .env.instance S0_PORT 4110; echo \$EV_RC" | tr "\n" " ")" = "1 0 " ]'
check "un salto de línea en el valor nunca vale" '[ "$(run "nl=\$(printf \"a\\nb\"); envschema_check_r .env.s0 GOOGLE_KEY \"\$nl\"; echo \$EV_RC")" = "1" ]'
check "el mensaje sale en el idioma activo" \
  '[ "$(DELTACTL_LANG=en run "envschema_check_r .env.instance S0_PORT abc; echo \$EV_MSG")" = "must be a port: a number from 1 to 65535" ]'
check "el mensaje de error nunca repite el valor (secretos)" '
  [ -z "$(run "for v in abc x\$(printf \" \")y; do envschema_check_r .env.s0 JWT_SECRET \"\$v\"; envschema_check_r .env.s1 FEDERATION_ENCRYPTION_KEY \"supersecreto123\"; case \"\$EV_MSG\" in *supersecreto123*) echo LEAK ;; esac; done")" ]'
check "el glosario real: ningún valor por defecto de una obligatoria o fija es inválido para su propio validador" '
  [ -z "$(run "for id in \"\${ENV_IDS[@]}\"; do [ \"\${ENV_HASDEF[\$id]}\" = 1 ] && [ -n \"\${ENV_DEFAULT[\$id]}\" ] || continue; envschema_validate_r \"\${ENV_VALIDATOR[\$id]}\" \"\${ENV_DEFAULT[\$id]}\" \"\"; [ \"\$EV_RC\" = 1 ] && echo \"\$id\"; done")" ]'
check "los ejemplos de las plantillas pasan su validador, salvo los marcadores CAMBIAR…" '
  [ -z "$(run "for id in \"\${ENV_IDS[@]}\"; do v=\"\${ENV_EXAMPLE[\$id]}\"; [ -n \"\$v\" ] && [[ \"\$v\" != *CAMBIAR* ]] || continue; envschema_validate_r \"\${ENV_VALIDATOR[\$id]}\" \"\$v\" \"\"; [ \"\$EV_RC\" = 1 ] && echo \"\$id=\$v\"; done" | grep -v "^\.env\.instance|INSTANCE=")" ]'

finish

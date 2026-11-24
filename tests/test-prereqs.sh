#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # los casos de check van entre comillas simples y se evalúan con eval
# Tests de los requisitos del servidor (lib/core/prereqs.data + lib/core/prereqs.sh), de `doctor` y de `doctor --json`.
# Usan un `docker` simulado, os-release falsos y un PATH sin las herramientas que se quiere "quitar": no instalan ni tocan nada.
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS

FIX="$(mktemp -d)"
export FIX
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/bin" "$FIX/os"
: > "$FIX/images.txt"; : > "$FIX/calls.log"
cp tests/fake-docker.sh "$FIX/bin/docker"; chmod +x "$FIX/bin/docker"
# Ejecuta código con la capa de lib cargada y docker simulado.
run() { ROOT="$PWD" PATH="$FIX/bin:$PATH" bash -c "source lib/bootstrap.sh; $1"; }
os() { printf '%s\n' "$2" > "$FIX/os/$1"; }
os debian 'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
NAME="Debian GNU/Linux"
ID=debian'
os ubuntu 'NAME="Ubuntu"
PRETTY_NAME="Ubuntu 24.04 LTS"
ID=ubuntu
ID_LIKE=debian'
os mint 'NAME="Linux Mint"
ID=linuxmint
ID_LIKE="ubuntu debian"'
os fedora 'NAME="Fedora Linux"
ID=fedora'
os rocky 'NAME="Rocky Linux"
ID="rocky"
ID_LIKE="rhel centos fedora"'
os arch 'NAME="Arch Linux"
ID=arch'
os endeavour 'NAME="EndeavourOS"
ID=endeavouros
ID_LIKE=arch'
os alpine 'NAME="Alpine Linux"
ID=alpine'
os raro 'NAME="Plan 9"
ID=plan9'
mgr() { run "DELTACTL_OS_RELEASE=$FIX/os/$1 prereq_distro; echo \"\$PR_MANAGER|\$PR_DISTRO_ID|\$PR_DISTRO_NAME\""; }

section "1. el catálogo de requisitos"
check "los 15 requisitos esperados, en orden" \
  '[ "$(run "echo \${PR_IDS[*]}")" = "docker daemon compose disk ram mongo nofile ss openssl gunzip proxy certbot timesync firewall curl" ]'
check "todo requisito tiene una comprobación prereq_check_<id>" 'run "for i in \${PR_IDS[@]}; do declare -F prereq_check_\$i >/dev/null || exit 1; done"'
check "el nivel es required o recommended" 'run "for i in \${PR_IDS[@]}; do case \${PR_LEVEL[\$i]} in required|recommended) ;; *) exit 1;; esac; done"'
check "la sección es una de las que lista doctor" 'run "for i in \${PR_IDS[@]}; do case \${PR_SECTION[\$i]} in docker|resources|mongo|tools|recommended) ;; *) exit 1;; esac; done"'
check "obligatorios: Docker, daemon, Compose, disco, RAM, Mongo, ss, openssl y gunzip" \
  '[ "$(run "for i in \${PR_IDS[@]}; do [ \${PR_LEVEL[\$i]} = required ] && printf \"%s \" \$i; done")" = "docker daemon compose disk ram mongo ss openssl gunzip " ]'
check "recomendados: nofile, proxy, certbot, hora, cortafuegos y curl" \
  '[ "$(run "for i in \${PR_IDS[@]}; do [ \${PR_LEVEL[\$i]} = recommended ] && printf \"%s \" \$i; done")" = "nofile proxy certbot timesync firewall curl " ]'
check "los que se instalan con paquete traen comando para apt, dnf, pacman y apk" \
  'run "for i in docker daemon compose ss openssl gunzip proxy certbot timesync firewall curl; do for m in apt dnf pacman apk; do [ -n \"\${PR_CMD[\"\$i|\$m\"]:-}\" ] || { echo falta \$i \$m; exit 1; }; done; done"'
check "cada requisito tiene nombre y para-qué en español y en inglés" \
  'for l in es en; do DELTACTL_LANG=$l run "for i in \${PR_IDS[@]}; do n=\$(prereq_name \$i); w=\$(prereq_why \$i); case \"\$n\$w\" in *\\?\\?*|\"\") exit 1;; esac; done" || exit 1; done'
check "cada requisito dice para qué sirve (frase de al menos 20 caracteres)" 'run "for i in \${PR_IDS[@]}; do [ \${#PR_CMD_X} -ge 0 ] && [ \$(prereq_why \$i | wc -c) -ge 20 ] || exit 1; done"'
check "el archivo de datos tiene 8 campos por fila" '! grep -vE "^(#|$)" lib/core/prereqs.data | awk -F"|" "NF != 8" | grep -q .'
check "leer el catálogo no lanza procesos" '! sed -n "/^prereq_load()/,/^}/p" lib/core/prereqs.sh | grep -qE "\\$\\(|\\| *(grep|awk|sed|cut|tr)"'

section "2. detección de la distribución"
check "Debian -> apt" '[ "$(mgr debian)" = "apt|debian|Debian GNU/Linux 12 (bookworm)" ]'
check "Ubuntu -> apt" '[ "$(mgr ubuntu | cut -d"|" -f1,2)" = "apt|ubuntu" ]'
check "Linux Mint (ID_LIKE=\"ubuntu debian\") -> apt" '[ "$(mgr mint | cut -d"|" -f1)" = "apt" ]'
check "Fedora -> dnf" '[ "$(mgr fedora | cut -d"|" -f1)" = "dnf" ]'
check "Rocky (ID_LIKE=\"rhel centos fedora\") -> dnf" '[ "$(mgr rocky | cut -d"|" -f1)" = "dnf" ]'
check "Arch -> pacman" '[ "$(mgr arch | cut -d"|" -f1)" = "pacman" ]'
check "EndeavourOS (ID_LIKE=arch) -> pacman" '[ "$(mgr endeavour | cut -d"|" -f1)" = "pacman" ]'
check "Alpine -> apk" '[ "$(mgr alpine | cut -d"|" -f1)" = "apk" ]'
check "una distribución desconocida con os-release no adivina el gestor" '[ "$(mgr raro | cut -d"|" -f1,2)" = "|plan9" ]'
check "sin os-release no falla (usa el gestor instalado, si hay)" 'run "DELTACTL_OS_RELEASE=$FIX/os/no-existe prereq_distro; echo ok" | grep -q ok'
check "el nombre sale entre comillas ya limpio" '[ "$(mgr ubuntu | cut -d"|" -f3)" = "Ubuntu 24.04 LTS" ]'
check "el comando de instalación depende del gestor" \
  '[ "$(run "prereq_install_r openssl apt; echo \$PR_INSTALL")" = "sudo apt-get install -y openssl" ] && [ "$(run "prereq_install_r openssl dnf; echo \$PR_INSTALL")" = "sudo dnf install -y openssl" ] && [ "$(run "prereq_install_r ss pacman; echo \$PR_INSTALL")" = "sudo pacman -S --needed iproute2" ] && [ "$(run "prereq_install_r gunzip apk; echo \$PR_INSTALL")" = "sudo apk add gzip" ]'
check "un requisito sin paquete (Mongo) no tiene comando" '! run "prereq_install_r mongo apt"'
check "sin gestor conocido no hay comando" '! run "prereq_install_r openssl \"\""'

section "3. las comprobaciones, una a una"
st() { run "$1; prereq_run $2; echo \"\${PR_STATUS[$2]}\""; }
check "sin Docker: error y daemon/Compose no aplican" \
  '[ "$(st "dk_installed() { return 1; }" docker)" = err ] && [ "$(st "dk_installed() { return 1; }" daemon)" = na ] && [ "$(st "dk_installed() { return 1; }" compose)" = na ]'
check "Docker instalado pero el daemon no responde: error con las dos pistas" \
  '[ "$(st "dk_daemon_ok() { return 1; }" daemon)" = err ] && run "dk_daemon_ok() { return 1; }; prereq_run daemon; echo \"\${PR_RES_HINT[0]}\"" | grep -q "grupo docker"'
check "con el daemon caído Docker no se marca como error (lo explica el daemon)" '[ "$(st "dk_daemon_ok() { return 1; }" docker)" = ok ]'
check "daemon sano: Docker y daemon ok" '[ "$(st ":" docker)" = ok ] && [ "$(st ":" daemon)" = ok ]'
check "Compose antiguo: error" '[ "$(st "dk_compose_version() { echo 2.10.1; }" compose)" = err ]'
check "Compose justo en 2.20.0: ok" '[ "$(st "dk_compose_version() { echo 2.20.0; }" compose)" = ok ]'
check "sin plugin de Compose: error" '[ "$(st "dk_compose_version() { echo; }" compose)" = err ]'
check "disco por debajo de 3 GB: error; menos de 10: aviso; más: ok" \
  '[ "$(st "host_free_kb() { echo 1000000; }" disk)" = err ] && [ "$(st "host_free_kb() { echo 5000000; }" disk)" = warn ] && [ "$(st "host_free_kb() { echo 20000000; }" disk)" = ok ]'
check "disco ilegible: solo informa" '[ "$(st "host_free_kb() { echo; }" disk)" = info ]'
printf 'MemTotal:       8000000 kB\nMemAvailable:   4000000 kB\n' > "$FIX/meminfo"
check "memoria leída de DELTACTL_MEMINFO" 'run "DELTACTL_MEMINFO=$FIX/meminfo prereq_run ram; echo \"\${PR_RES_MSG[0]}\"" | grep -q "7812 MB en total, 3906 MB disponibles"'
check "memoria ilegible: solo informa" '[ "$(st "DELTACTL_MEMINFO=$FIX/no-existe" ram)" = info ]'
for t in ss openssl gunzip; do
  check "sin $t: aviso (no error, como antes) con la pista" \
    '[ "$(st "host_has() { [ \"\$1\" != '$t' ]; }" '$t')" = warn ]'
  check "con $t: ok" '[ "$(st "host_has() { return 0; }" '$t')" = ok ]'
done
check "proxy: sin nginx ni Caddy solo informa y dice cómo instalarlo" \
  '[ "$(st "DELTACTL_PR_SBIN=\"\"; host_has() { [ \"\$1\" != nginx ] && [ \"\$1\" != caddy ]; }" proxy)" = info ]'
check "proxy: con nginx es ok y lo nombra" 'run "DELTACTL_PR_SBIN=\"\"; host_has() { [ \"\$1\" = nginx ]; }; prereq_run proxy; echo \"\${PR_STATUS[proxy]} \${PR_RES_MSG[0]}\"" | grep -q "^ok .*nginx$"'
check "proxy: con Caddy y nginx nombra los dos" 'run "host_has() { return 0; }; prereq_run proxy; echo \"\${PR_RES_MSG[0]}\"" | grep -q "nginx, Caddy"'
check "proxy: encuentra nginx en /usr/sbin aunque no esté en el PATH" \
  'mkdir -p "$FIX/sbin"; printf "#!/bin/sh\n" > "$FIX/sbin/nginx"; chmod +x "$FIX/sbin/nginx"; [ "$(st "DELTACTL_PR_SBIN=$FIX/sbin; host_has() { return 1; }" proxy)" = ok ]'
check "certbot y curl que faltan solo informan" '[ "$(st "DELTACTL_PR_SBIN=\"\"; host_has() { return 1; }" certbot)" = info ] && [ "$(st "host_has() { return 1; }" curl)" = info ]'
# timedatectl y systemctl simulados
mkdir -p "$FIX/fake"
printf '#!/bin/sh\necho "$TD_ANSWER"\n' > "$FIX/fake/timedatectl"
printf '#!/bin/sh\n[ "$1" = is-active ] && [ "${FW_ACTIVE:-}" = "$3" ]\n' > "$FIX/fake/systemctl"
chmod +x "$FIX/fake/timedatectl" "$FIX/fake/systemctl"
check "hora: sincronizada = ok, no sincronizada = información" \
  '[ "$(TD_ANSWER=yes PATH="$FIX/fake:$PATH" st ":" timesync)" = ok ] && [ "$(TD_ANSWER=no PATH="$FIX/fake:$PATH" st ":" timesync)" = info ]'
check "hora: una respuesta rara es información, no error" '[ "$(TD_ANSWER=quien-sabe PATH="$FIX/fake:$PATH" st ":" timesync)" = info ]'
check "cortafuegos: ufw activo = ok; ninguno = información" \
  '[ "$(FW_ACTIVE=ufw PATH="$FIX/fake:$PATH" st ":" firewall)" = ok ] && [ "$(FW_ACTIVE=none PATH="$FIX/fake:$PATH" st ":" firewall)" = info ]'
check "ningún recomendado que falle cuenta como aviso ni error" \
  'run "DELTACTL_PR_SBIN=\"\"; host_has() { return 1; }; PATH=\"$FIX/fake:\$PATH\"; TD_ANSWER=no; for i in proxy certbot curl timesync firewall; do prereq_run \$i; case \${PR_STATUS[\$i]} in warn|err) exit 1;; esac; done"'

section "4. mongo según las instancias del catálogo"
mkdir -p instances/pr-uno
printf 'MONGO_URI=mongodb://127.0.0.1:1/x\n' > instances/pr-uno/.env.s0
printf 'MONGO_DELTA_DISPATCH_URI=mongodb://127.0.0.1:1/y\nMONGO_ROBIN_URI=mongodb://otro.host:27017/z\n' > instances/pr-uno/.env.s1
check "una URI repetida se prueba una sola vez" '[ "$(run "dr_tcp() { return 1; }; prereq_run mongo; echo \${#PR_RES_ST[@]}")" = "2" ]'
check "una URI inalcanzable es error con la pista" '[ "$(st "dr_tcp() { return 1; }" mongo)" = err ]'
check "todas alcanzables: ok" '[ "$(st "dr_tcp() { return 0; }" mongo)" = ok ]'
check "host.docker.internal se prueba contra la puerta de enlace" \
  'printf "MONGO_URI=mongodb://host.docker.internal:27017/x\n" > instances/pr-uno/.env.s0; rm instances/pr-uno/.env.s1; run "dr_tcp() { [ \"\$1\" = 127.0.0.1 ]; }; prereq_run mongo; echo \"\${PR_RES_MSG[0]}\"" | grep -q "alcanzable desde los contenedores (por 127.0.0.1)"'
rm -rf instances/pr-uno
check "sin instancias solo informa" '[ "$(st ":" mongo)" = info ]'

section "4b. dr_tcp y dr_mongo_hostport con datos del operador (sin ejecutar nada)"
# El host sale de MONGO_URI (un .env que puede editar cualquiera con acceso a la carpeta): no debe llegar a un shell como código.
# ra llama a una función de lib pasando los argumentos por argv, sin pasar por ninguna cita ni expansión de este script.
ra() { ROOT="$PWD" PATH="$FIX/bin:$PATH" bash -c 'source lib/bootstrap.sh; "$@"' _ "$@"; }
check "dr_tcp: un host con \$(...) no ejecuta nada y falla" \
  'rm -f "$FIX/pwned"; ! ra dr_tcp "127.0.0.1\$(touch\${IFS}$FIX/pwned)" 27017; [ ! -e "$FIX/pwned" ]'
check "dr_tcp: un host con ; o comillas invertidas no ejecuta nada" \
  'rm -f "$FIX/pwned2"; ! ra dr_tcp "x;touch $FIX/pwned2" 27017; ! ra dr_tcp "x\`touch $FIX/pwned2\`" 27017; [ ! -e "$FIX/pwned2" ]'
check "dr_tcp: un puerto que no es número no ejecuta nada y falla" \
  'rm -f "$FIX/pwned3"; ! ra dr_tcp 127.0.0.1 "1;touch $FIX/pwned3"; [ ! -e "$FIX/pwned3" ]'
check "dr_tcp: un host o un puerto vacío falla" '! ra dr_tcp "" 27017 && ! ra dr_tcp 127.0.0.1 ""'
if command -v python3 >/dev/null 2>&1; then
  python3 - "$FIX/port" <<'PY' &
import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(5)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
time.sleep(30)
PY
  LISTENER=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$FIX/port" ] && break; sleep 0.2; done
  check "dr_tcp: un host y un puerto válidos conectan de verdad" 'ra dr_tcp 127.0.0.1 "$(cat "$FIX/port")"'
  kill "$LISTENER" 2>/dev/null; wait "$LISTENER" 2>/dev/null
  check "dr_tcp: un puerto cerrado falla" '! ra dr_tcp 127.0.0.1 "$(cat "$FIX/port")"'
fi
hp() { ra dr_mongo_hostport "$1"; }
check "hostport: URI simple" '[ "$(hp mongodb://u:p@db1:27018/x)" = "db1 27018" ]'
check "hostport: sin puerto usa 27017" '[ "$(hp mongodb://db1/x)" = "db1 27017" ]'
check "hostport: una contraseña con @ no se mezcla con el host" '[ "$(hp mongodb://adm:p@ssw0rd@db1:27017/x)" = "db1 27017" ]'
check "hostport: un @ en la query no es un usuario" '[ "$(hp "mongodb://db1:27017/x?authSource=a@b")" = "db1 27017" ]'
check "hostport: sin base de datos y con query" '[ "$(hp "mongodb://db1?replicaSet=r")" = "db1 27017" ]'
check "hostport: IPv6 entre corchetes con y sin puerto" \
  '[ "$(hp "mongodb://[::1]:27018/x")" = "::1 27018" ] && [ "$(hp "mongodb://[::1]/x")" = "::1 27017" ]'
check "hostport: una lista de hosts usa el primero" '[ "$(hp mongodb://a:1,b:2/x)" = "a 1" ]'
check "hostport: mongodb+srv no tiene puerto que probar" '[ "$(hp mongodb+srv://u:p@c0.ab.mongodb.net/db)" = "c0.ab.mongodb.net srv" ]'
check "hostport: los caracteres raros del host salen sustituidos (no llegan a la terminal)" \
  '[ "$(hp "$(printf "mongodb://a\033[31mb:1/x")")" = "a??31mb 1" ]'
mkdir -p instances/pr-srv
printf 'MONGO_URI=mongodb+srv://u:p@c0.ab.mongodb.net/db\n' > instances/pr-srv/.env.s0
check "mongo+srv: no da un falso error de TCP al 27017, informa" '[ "$(st "dr_tcp() { return 1; }" mongo)" = info ]'
rm -rf instances/pr-srv

section "5. solo lectura"
check "ninguna comprobación escribe, instala ni borra (el código no usa esas órdenes)" \
  '! grep -vE "^\s*#" lib/core/prereqs.sh | grep -nE "\b(rm|mv|cp|tee|mkdir|chmod|chown|sudo|pacman -S|apk add|systemctl (start|enable|stop)|docker (run|compose up|pull))\b|[[:space:]]>>? *[\"/\$]" | grep -vE "/dev/(null|tcp)|>&2"'
check "ejecutar todas las comprobaciones no cambia ningún archivo" \
  'touch "$FIX/marker"; sleep 1; run "prereq_run_all" >/dev/null 2>&1; [ -z "$(find . -newer "$FIX/marker" -type f -not -path "./instances/*" | head -1)" ]'
check "no se llamó a docker para nada que no sea leer" '! grep -qE "COMPOSE up|COMPOSE pull|COMPOSE down|^run " "$FIX/calls.log"'

section "6. doctor --json"
OUT="$(DELTACTL_OS_RELEASE="$FIX/os/debian" PATH="$FIX/bin:$PATH" bash ./deltactl doctor --json 2>&1)"; rc=$?
check "imprime una sola línea de JSON" '[ "$(echo "$OUT" | wc -l)" = "1" ] && [[ "$OUT" == "{"* ]] && [[ "$OUT" == *"}" ]]'
if command -v python3 >/dev/null 2>&1; then
  check "es JSON válido" 'echo "$OUT" | python3 -c "import json,sys; json.load(sys.stdin)"'
  check "trae la distribución y el gestor de paquetes" 'echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin)[\"distro\"]; assert d[\"manager\"]==\"apt\" and d[\"id\"]==\"debian\""'
  check "trae los 15 requisitos con todos los campos" \
    'echo "$OUT" | python3 -c "
import json,sys
d=json.load(sys.stdin)[\"prerequisites\"]
assert len(d)==15
for p in d:
    for k in (\"id\",\"name\",\"level\",\"status\",\"summary\",\"why\",\"install\",\"url\",\"results\"): assert k in p, (p[\"id\"],k)
    assert p[\"level\"] in (\"required\",\"recommended\") and p[\"status\"] in (\"ok\",\"info\",\"warn\",\"err\",\"na\")
    assert p[\"why\"]
"'
  check "el comando de instalación es el de apt" 'echo "$OUT" | python3 -c "import json,sys; d={p[\"id\"]:p for p in json.load(sys.stdin)[\"prerequisites\"]}; assert d[\"openssl\"][\"install\"]==\"sudo apt-get install -y openssl\" and d[\"mongo\"][\"install\"]==\"\""'
  check "los totales coinciden con los estados" \
    'echo "$OUT" | python3 -c "
import json,sys
j=json.load(sys.stdin)
e=sum(1 for p in j[\"prerequisites\"] for r in p[\"results\"] if r[\"status\"]==\"err\")
w=sum(1 for p in j[\"prerequisites\"] for r in p[\"results\"] if r[\"status\"]==\"warn\")
assert j[\"summary\"][\"errors\"]==e and j[\"summary\"][\"warnings\"]==w and j[\"summary\"][\"ok\"]==(e==0)
"'
  check "las comillas y barras de los textos se escapan" 'echo "$OUT" | python3 -c "import json,sys; d={p[\"id\"]:p for p in json.load(sys.stdin)[\"prerequisites\"]}; assert \"USER\" in d[\"daemon\"][\"install\"] and chr(34) in d[\"daemon\"][\"install\"]"'
fi
check "no usa colores ni símbolos" '! echo "$OUT" | has_ansi'
check "con DELTACTL_LANG=en el JSON sale en inglés" 'DELTACTL_LANG=en PATH="$FIX/bin:$PATH" bash ./deltactl doctor --json | grep -q "Runs the services of each instance in containers"'
check "doctor --json con un argumento más falla" '! bash ./deltactl doctor --json x >/dev/null 2>&1'
check "doctor x sigue sin aceptar argumentos" 'bash ./deltactl doctor x 2>&1 | grep -q "no recibe argumentos"'

section "7. doctor sin Docker, con un PATH recortado"
# PATH con todo lo del sistema menos lo que se quiere "desinstalar"
mkdir -p "$FIX/nopath"
for d in /usr/bin /bin; do [ -d "$d" ] && ln -sf "$d"/* "$FIX/nopath/" 2>/dev/null; done
rm -f "$FIX/nopath"/{docker,openssl,ss,gunzip,nginx,caddy,certbot,curl,timedatectl,systemctl}
NOP="$(DELTACTL_OS_RELEASE="$FIX/os/fedora" DELTACTL_PR_SBIN="" PATH="$FIX/nopath" bash ./deltactl doctor 2>&1)"; rc=$?
check "dice que Docker no está instalado y cómo instalarlo en esa distro (dnf)" 'echo "$NOP" | grep -q "Docker no está instalado" && echo "$NOP" | grep -q "Instalar (dnf): sudo dnf config-manager"'
check "termina con código 1 y no falla a medias" '[ "$rc" -eq 1 ] && echo "$NOP" | grep -q "error(es)"'
check "faltan ss, openssl y gunzip: tres avisos con su paquete" '[ "$(echo "$NOP" | grep -c "Falta .\(ss\|openssl\|gunzip\).")" = 3 ] && echo "$NOP" | grep -q "Instalar (dnf): sudo dnf install -y iproute"'
check "los recomendados que faltan informan sin ser avisos" 'echo "$NOP" | grep -q "No se detectó nginx ni Caddy" && echo "$NOP" | grep -q "Falta .certbot."'
check "no acusa a Compose ni al daemon cuando falta Docker" '! echo "$NOP" | grep -qi "plugin .docker compose\|No se puede hablar con el daemon"'
check "con PATH recortado y --json sigue siendo JSON y trae el error" \
  'o="$(DELTACTL_OS_RELEASE="$FIX/os/arch" DELTACTL_PR_SBIN="" PATH="$FIX/nopath" bash ./deltactl doctor --json 2>&1)"; echo "$o" | grep -q "\"id\":\"docker\",\"name\":\"Docker Engine\",\"level\":\"required\",\"status\":\"err\"" && echo "$o" | grep -q "\"manager\":\"pacman\""'

section "8. doctor con Docker simulado"
OK="$(DELTACTL_OS_RELEASE="$FIX/os/arch" PATH="$FIX/bin:$PATH" bash ./deltactl doctor 2>&1)"
check "muestra las secciones, incluida Recomendado" 'for s in Docker Recursos MongoDB Instancias Herramientas Recomendado; do echo "$OK" | grep -qx "$s" || exit 1; done'
check "detecta Docker y Compose simulados" 'echo "$OK" | grep -q "Docker 27.0.0" && echo "$OK" | grep -q "Docker Compose 2.30.0"'
check "sin escapes en modo plano" '! echo "$OK" | has_ansi'
EN="$(DELTACTL_LANG=en PATH="$FIX/bin:$PATH" bash ./deltactl doctor 2>&1)"
check "en inglés: secciones y nombres" 'for s in Docker Resources MongoDB Instances Tools Recommended; do echo "$EN" | grep -qx "$s" || exit 1; done'

finish

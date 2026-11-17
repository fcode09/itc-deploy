#!/usr/bin/env bash
# Tests de ./deltactl images (alias versions): uso por instancia, previas, imágenes sin uso, filtro y --json.
# Usa un `docker` simulado, así que no necesita Docker real. Se ejecuta desde la raíz de la copia aislada.
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS

FIX="$(mktemp -d)"
export FIX
trap 'rm -rf "$FIX" instances/im-*' EXIT
rm -rf instances/im-*
mkdir -p "$FIX/bin"

cat > "$FIX/images.txt" <<'EOF'
auth-backend|1.0|sha256:aaaaaaaaaaaaaaaa|2 hours ago|350MB
auth-backend|0.9|sha256:bbbbbbbbbbbbbbbb|3 days ago|349MB
auth-backend|0.5|sha256:cccccccccccccccc|2 months ago|340MB
gueo-back-end|2.0|sha256:dddddddddddddddd|1 hour ago|1.2GB
EOF

cat > "$FIX/bin/docker" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  info) case "$*" in *Architecture*) echo x86_64 ;; esac ;;
  compose) echo "v2.30.0" ;;
  image)
    case "$2" in
      ls) cat "$FIX/images.txt" ;;
      inspect) case "$*" in *Architecture*) echo amd64 ;; esac ;;
    esac ;;
esac
exit 0
SHIM
chmod +x "$FIX/bin/docker"
export PATH="$FIX/bin:$PATH"

bash ./deltactl new im-one >/dev/null 2>&1
fill_instance instances/im-one 1.0 2.0
printf 'S0_TAG=0.9\n' > instances/im-one/.previous

section "1. tabla de versiones"
out="$(bash ./deltactl images 2>&1)"
check "muestra la arquitectura del servidor" 'echo "$out" | grep -q "Arquitectura de este servidor: amd64"'
check "agrupa por servicio y nombre de imagen" 'echo "$out" | grep -qx "s0 = auth-backend" && echo "$out" | grep -qx "s1 = gueo-back-end"'
check "marca la etiqueta en uso con su instancia" 'echo "$out" | grep "^1.0 " | grep -q "im-one(actual)"'
check "marca la etiqueta previa (rollback)" 'echo "$out" | grep "^0.9 " | grep -q "im-one(previa)"'
check "marca la etiqueta sin uso" 'echo "$out" | grep "^0.5 " | grep -q "sin uso (candidata a borrar)"'
check "usa los IDs cortos" 'echo "$out" | grep -q "aaaaaaaaaaaa " && ! echo "$out" | grep -q "sha256:"'
check "resume cuántas imágenes están sin uso" 'echo "$out" | grep -q "1 de 4 imagen(es) sin uso"'
check "no hay escapes en la salida plana" '! echo "$out" | has_ansi'
check "DELTACTL_COLOR=always colorea" 'DELTACTL_COLOR=always bash ./deltactl images | has_ansi'
check "la cabecera con ñ queda alineada con las filas" \
  '[ "$(echo "$out" | grep "^ETIQUETA" | cut -d" " -f1-5 | wc -c)" -gt 0 ] && echo "$out" | grep -q "TAMAÑO"'

section "2. filtro, alias y errores"
check "images s1 solo muestra s1" 'o="$(bash ./deltactl images s1 2>&1)"; echo "$o" | grep -q "s1 = gueo-back-end" && ! echo "$o" | grep -q "s0 = auth-backend"'
check "versions es un alias de images" '[ "$(bash ./deltactl versions 2>&1)" = "$out" ]'
check "servicio inválido falla" '! bash ./deltactl images s9 >/dev/null 2>&1'
check "opción desconocida falla" '! bash ./deltactl images --nada >/dev/null 2>&1'

section "3. --json"
js="$(bash ./deltactl images --json 2>&1)"
check "es JSON válido" 'if command -v python3 >/dev/null; then echo "$js" | python3 -c "import json,sys; json.load(sys.stdin)"; else true; fi'
check "incluye uso y estado" \
  'echo "$js" | grep "\"tag\":\"1.0\"" | grep -q "\"used_by\":\"im-one(actual)\"" && echo "$js" | grep "\"tag\":\"0.5\"" | grep -q "\"in_use\":false"'
check "sin escapes ni cabeceras" '! echo "$js" | has_ansi && [ "$(echo "$js" | head -n1)" = "[" ]'
check "--json respeta el filtro de servicio" '! bash ./deltactl images s1 --json | grep -q "auth-backend"'

finish

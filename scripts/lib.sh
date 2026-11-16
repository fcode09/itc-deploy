#!/usr/bin/env bash
# Funciones comunes de ./itc. Se carga con `source`; no se ejecuta directamente.
# Requiere que ROOT (raíz del repo) esté definida.

if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_OFF=''
fi

INSTANCES_DIR="$ROOT/instances"
BASE_PORT=4100        # primer bloque de puertos del host
PORT_STEP=10          # cada instancia ocupa un bloque de 10 puertos (sN usa base + N)
RUNTIME_UID=1000      # uid del usuario "node" dentro de las imágenes

info() { printf '%s\n' "$*"; }
ok()   { printf '%sOK%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%sAVISO%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%sERROR%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
itc: despliegue y operación de instancias (Docker Compose).

Uso: ./itc <comando> [instancia] [opciones]

  new <instancia>               Crea instances/<instancia>/ desde las plantillas
  deploy <instancia>            Valida, descarga imágenes y levanta (espera a healthy)
  rollback <instancia> [--yes]  Vuelve a las etiquetas del despliegue anterior
  list                          Instancias, puertos, etiquetas y estado
  ps <instancia>                Estado de los contenedores
  logs <instancia> [servicio] [-f]   Logs (últimas 200 líneas)
  down <instancia> [--yes]      Detiene y elimina los contenedores (los datos se conservan)
  help                          Esta ayuda

Nombre de instancia: minúsculas, números y guion; empieza con letra (ej. colorado).
EOF
}

valid_instance_name() { [[ "$1" =~ ^[a-z][a-z0-9-]{1,30}$ ]]; }

instance_dir() { printf '%s/%s' "$INSTANCES_DIR" "$1"; }

require_instance() {
  local name="${1:-}"
  [ -n "$name" ] || die "falta el nombre de la instancia. Uso: ./itc ${CMD:-<comando>} <instancia>"
  valid_instance_name "$name" \
    || die "nombre de instancia inválido: '$name' (minúsculas, números y guion; empieza con letra; 2 a 31 caracteres)"
  [ -f "$(instance_dir "$name")/instance.env" ] \
    || die "la instancia '$name' no existe. Créala con: ./itc new $name"
}

# Lee el valor de una clave de un archivo .env sin ejecutarlo (tolera CRLF).
get_var() { # archivo clave
  local line
  line="$(grep -E "^$2=" "$1" 2>/dev/null | tail -n1 || true)"
  line="${line#*=}"
  printf '%s' "${line%$'\r'}"
}

# Reemplaza (o añade) KEY=valor en un archivo .env.
set_var() { # archivo clave valor
  local file="$1" key="$2" val="$3" tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$val" 'BEGIN { FS = OFS = "=" }
    $1 == k { print k "=" v; found = 1; next }
    { print }
    END { if (!found) print k "=" v }' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

check_docker() {
  command -v docker >/dev/null 2>&1 || die "docker no está instalado o no está en el PATH"
  docker info >/dev/null 2>&1 || die "no se puede hablar con el daemon de Docker (¿servicio detenido o sin permisos?)"
  docker compose version >/dev/null 2>&1 || die "falta el plugin 'docker compose' (se necesita v2.20 o superior)"
  local v
  v="$(docker compose version --short 2>/dev/null | sed 's/^v//')"
  if [ -n "$v" ] && [ "$(printf '%s\n%s\n' 2.20.0 "$v" | sort -V | head -n1)" != "2.20.0" ]; then
    die "Docker Compose $v es demasiado antiguo: se necesita 2.20 o superior (por 'include')"
  fi
}

# Ejecuta docker compose para una instancia, siempre desde la raíz del repo.
dc() { # instancia args...
  local name="$1"
  shift
  (cd "$ROOT" && docker compose --env-file "instances/$name/instance.env" "$@")
}

# Pide confirmación. ASSUME_YES=1 (opción --yes) la omite.
confirm() { # mensaje
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  [ -t 0 ] || die "se requiere confirmación: ejecuta de forma interactiva o añade --yes"
  local ans
  read -r -p "$1 [s/N] " ans
  [[ "$ans" =~ ^[sSyY]$ ]]
}

# Retira --yes de los argumentos y fija ASSUME_YES. Resultado en el array ARGS.
parse_yes() {
  ASSUME_YES=0
  ARGS=()
  local a
  for a in "$@"; do
    if [ "$a" = "--yes" ] || [ "$a" = "-y" ]; then ASSUME_YES=1; else ARGS+=("$a"); fi
  done
}

# Etiquetas actuales de una instancia, en el formato de .deployed / .previous.
snapshot_tags() { # carpeta_instancia
  printf 'S0_TAG=%s\nS1_TAG=%s\n' \
    "$(get_var "$1/instance.env" S0_TAG)" "$(get_var "$1/instance.env" S1_TAG)"
}

# Siguiente puerto S0 libre: máximo existente + PORT_STEP (o BASE_PORT si no hay instancias).
next_s0_port() {
  local max=$((BASE_PORT - PORT_STEP)) f p
  for f in "$INSTANCES_DIR"/*/instance.env; do
    [ -f "$f" ] || continue
    p="$(get_var "$f" S0_PORT)"
    if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -gt "$max" ]; then max="$p"; fi
  done
  echo $((max + PORT_STEP))
}

# Nombre de la instancia (distinta de $2) que ya usa el puerto $1, o vacío.
port_owner() { # puerto instancia_excluida
  local f n
  for f in "$INSTANCES_DIR"/*/instance.env; do
    [ -f "$f" ] || continue
    n="$(basename "$(dirname "$f")")"
    [ "$n" = "${2:-}" ] && continue
    if [ "$(get_var "$f" S0_PORT)" = "$1" ] || [ "$(get_var "$f" S1_PORT)" = "$1" ]; then
      echo "$n"
      return 0
    fi
  done
}

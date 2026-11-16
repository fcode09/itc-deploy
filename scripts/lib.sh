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

# Servicios conocidos. Al sumar uno nuevo: añadirlo aquí y definir preflight_<sN> en scripts/cmd/deploy.sh.
KNOWN_SERVICES=(s0 s1)

info() { printf '%s\n' "$*"; }
ok()   { printf '%sOK%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%sAVISO%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%sERROR%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
itc: despliegue y operación de instancias (Docker Compose).

Uso: ./itc <comando> [instancia] [opciones]

  new <instancia> [--services s0,s1] [--existing]   Crea instances/<instancia>/ desde las plantillas
                                       (--existing: la municipalidad YA tiene datos; no se sembrará nunca)
  init <instancia> [--yes]             Siembra los datos iniciales de una instancia NUEVA (una sola vez)
  adopt <instancia>                    Marca como ya inicializada una instancia que YA tiene datos
  deploy <instancia> [servicio]        Valida, comprueba las imágenes y levanta (espera a healthy)
  rollback <instancia> [servicio] [--yes]  Vuelve a las etiquetas del despliegue anterior
  stop <instancia> <servicio>          Detiene un servicio sin tocar los demás
  load <archivo.tar|.tar.gz>           Carga imágenes en el Docker de este servidor
  images [servicio]                    Versiones de imagen disponibles y qué instancias las usan
  list                                 Instancias, servicios, puertos, etiquetas y estado
  ps <instancia>                       Estado de los contenedores
  logs <instancia> [servicio] [-f]     Logs (últimas 200 líneas)
  down <instancia> [--yes]             Detiene y elimina los contenedores (los datos se conservan)
  help                                 Esta ayuda

Nombre de instancia: minúsculas, números y guion; empieza con letra (ej. colorado).
Servicios: s0 (auth-backend), s1 (gueo-back-end). Sin [servicio], deploy y rollback actúan
sobre los que la instancia tiene en COMPOSE_PROFILES (.env.instance).
Imágenes: con REGISTRY vacío en .env.instance se usan las ya cargadas en este Docker
(auth-backend:<tag>) y no se descarga nada; con REGISTRY, deploy hace pull.
EOF
}

valid_instance_name() { [[ "$1" =~ ^[a-z][a-z0-9-]{1,30}$ ]]; }

instance_dir() { printf '%s/%s' "$INSTANCES_DIR" "$1"; }

require_instance() {
  local name="${1:-}"
  [ -n "$name" ] || die "falta el nombre de la instancia. Uso: ./itc ${CMD:-<comando>} <instancia>"
  valid_instance_name "$name" \
    || die "nombre de instancia inválido: '$name' (minúsculas, números y guion; empieza con letra; 2 a 31 caracteres)"
  [ -f "$(instance_dir "$name")/.env.instance" ] \
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

# Marcador de "datos iniciales ya sembrados o instancia con datos existentes". Mientras exista,
# `./itc init` se niega a ejecutarse: los seeds borran datos (drop de colecciones).
marker_file() { printf '%s/.initialized' "$(instance_dir "$1")"; }

write_marker() { # instancia origen(init|existing)
  local dir f
  dir="$(instance_dir "$1")"
  f="$(marker_file "$1")"
  {
    printf 'SOURCE=%s\n' "$2"
    printf 'INITIALIZED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'S0_TAG=%s\n' "$(get_var "$dir/.env.instance" S0_TAG)"
    printf 'S1_TAG=%s\n' "$(get_var "$dir/.env.instance" S1_TAG)"
  } > "$f"
  chmod 600 "$f"
}

# ¿La instancia usa imágenes ya cargadas en este Docker? (REGISTRY vacío en .env.instance)
uses_local_images() { # instancia
  [ -z "$(get_var "$(instance_dir "$1")/.env.instance" REGISTRY)" ]
}

# Ejecuta docker compose para una instancia, siempre desde la raíz del repo.
# - Se limpian COMPOSE_PROFILES y COMPOSE_PROJECT_NAME del shell: si estuvieran exportados
#   pisarían lo que define .env.instance y la instancia se comportaría distinto según quién la ejecute.
# - Con imágenes locales (REGISTRY vacío) se fija PULL_POLICY=never: si falta la imagen, Docker no
#   debe bajar de Docker Hub una imagen homónima que no es la nuestra.
dc() { # instancia args...
  local name="$1" policy=missing
  shift
  if uses_local_images "$name"; then policy=never; fi
  (cd "$ROOT" && unset COMPOSE_PROFILES COMPOSE_PROJECT_NAME \
    && PULL_POLICY="$policy" docker compose --env-file "instances/$name/.env.instance" "$@")
}

# Nombre de la imagen (sin registry ni etiqueta) de cada servicio.
service_repo() { # servicio
  case "$1" in
    s0) echo "auth-backend" ;;
    s1) echo "gueo-back-end" ;;
    *) return 1 ;;
  esac
}

# Referencia completa de imagen que Compose usará para un servicio de la instancia.
service_image_ref() { # instancia servicio
  dc "$1" --profile "$2" config --images 2>/dev/null | head -n1
}

image_exists() { docker image inspect "$1" >/dev/null 2>&1; }

image_id() { docker image inspect --format '{{.Id}}' "$1" 2>/dev/null || true; }

short_id() { local id="${1#sha256:}"; printf '%s' "${id:0:12}"; }

# Arquitectura de este servidor en el vocabulario de las imágenes (amd64, arm64...).
server_arch() {
  case "$(docker info --format '{{.Architecture}}' 2>/dev/null)" in
    x86_64) echo amd64 ;;
    aarch64) echo arm64 ;;
    *) docker info --format '{{.Architecture}}' 2>/dev/null ;;
  esac
}

# Avisa si una imagen no es de la arquitectura de este servidor (no arrancaría).
warn_arch_mismatch() { # referencia
  local img srv
  img="$(docker image inspect --format '{{.Architecture}}' "$1" 2>/dev/null || true)"
  srv="$(server_arch)"
  if [ -n "$img" ] && [ -n "$srv" ] && [ "$img" != "$srv" ]; then
    warn "la imagen $1 es $img y este servidor es $srv: no podrá arrancar"
  fi
}

valid_service() { # servicio
  local s
  for s in "${KNOWN_SERVICES[@]}"; do [ "$s" = "$1" ] && return 0; done
  return 1
}

# Variable de etiqueta de un servicio: s1 -> S1_TAG
tag_var() { printf '%s_TAG' "${1^^}"; }

# Lee COMPOSE_PROFILES de la instancia y deja los servicios activos en ENABLED.
ENABLED=()
load_enabled() { # instancia
  ENABLED=()
  local raw part
  local -a parts
  raw="$(get_var "$(instance_dir "$1")/.env.instance" COMPOSE_PROFILES)"
  [ -n "$raw" ] || die ".env.instance: COMPOSE_PROFILES está vacío; indica los servicios activos (ej. s0,s1)"
  IFS=',' read -ra parts <<< "$raw"
  for part in "${parts[@]}"; do
    part="${part// /}"
    [ -n "$part" ] || continue
    valid_service "$part" \
      || die ".env.instance: COMPOSE_PROFILES contiene '$part', que no es un servicio conocido (${KNOWN_SERVICES[*]})"
    ENABLED+=("$part")
  done
  [ "${#ENABLED[@]}" -gt 0 ] || die ".env.instance: COMPOSE_PROFILES no contiene servicios"
}

# Deja en SELECTED los servicios sobre los que actúa un comando: el indicado, o todos los
# activos de la instancia. Un servicio indicado debe estar activo en ella.
SELECTED=()
select_services() { # instancia [servicio]
  local name="$1" want="${2:-}" s found=0
  load_enabled "$name"
  if [ -z "$want" ]; then
    SELECTED=("${ENABLED[@]}")
    return 0
  fi
  valid_service "$want" || die "servicio desconocido: '$want' (válidos: ${KNOWN_SERVICES[*]})"
  for s in "${ENABLED[@]}"; do [ "$s" = "$want" ] && found=1; done
  [ "$found" -eq 1 ] \
    || die "'$want' no está activo en '$name' (COMPOSE_PROFILES=$(IFS=,; echo "${ENABLED[*]}")); añádelo a .env.instance si debe correr ahí"
  SELECTED=("$want")
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

# Siguiente puerto S0 libre: máximo existente + PORT_STEP (o BASE_PORT si no hay instancias).
next_s0_port() {
  local max=$((BASE_PORT - PORT_STEP)) f p
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    p="$(get_var "$f" S0_PORT)"
    if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -gt "$max" ]; then max="$p"; fi
  done
  echo $((max + PORT_STEP))
}

# Nombre de la instancia (distinta de $2) que ya usa el puerto $1, o vacío.
port_owner() { # puerto instancia_excluida
  local f n
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    n="$(basename "$(dirname "$f")")"
    [ "$n" = "${2:-}" ] && continue
    if [ "$(get_var "$f" S0_PORT)" = "$1" ] || [ "$(get_var "$f" S1_PORT)" = "$1" ]; then
      echo "$n"
      return 0
    fi
  done
}

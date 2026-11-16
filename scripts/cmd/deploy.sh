#!/usr/bin/env bash
# ./itc deploy <instancia> [servicio]: valida, descarga imágenes y levanta la instancia
# (o solo el servicio indicado).

PREFLIGHT_ERRORS=0

# Exige que cada clave exista, no esté vacía y no conserve el valor de ejemplo (CAMBIAR...).
check_required() { # archivo clave...
  local file="$1" key val
  shift
  for key in "$@"; do
    val="$(get_var "$file" "$key")"
    if [ -z "$val" ]; then
      warn "$(basename "$file"): $key está vacía$(see "variable $key")"
      PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
    elif [[ "$val" == *CAMBIAR* ]]; then
      warn "$(basename "$file"): $key aún tiene el valor de ejemplo (CAMBIAR...)$(see "variable $key")"
      PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
    fi
  done
}

# Validaciones propias de cada servicio. Un servicio nuevo define su preflight_<sN>.
# Variables obligatorias (única fuente de verdad: las usan los preflight y tests/test-help.sh las compara
# con el glosario de ./itc help variable). Las de etiqueta y puerto de cada servicio se suman en preflight().
REQUIRED_INSTANCE=(INSTANCE COMPOSE_PROFILES)
REQUIRED_S0=(IP_SERVER JWT_SECRET MONGO_URI IP_INTERNAL_CONNECTION)
REQUIRED_S1=(IP_SERVER AUTH_URL JWT_SECRET FEDERATION_ENCRYPTION_KEY SERVERS_CONFIG
  MONGO_DELTA_DISPATCH_URI MONGO_AUTHSOFTWARE_URI MONGO_ROBIN_URI FCM_CERT KEEPER_FCM_CERT DEEPGRAM_API_KEY)

preflight_s0() { # carpeta_instancia
  check_required "$1/.env.s0" "${REQUIRED_S0[@]}"
}

preflight_s1() { # carpeta_instancia
  local dir="$1" f path listen s
  # Si s0 corre en esta instancia, necesita alcanzar el TCP 5020 de s1 (en otro contenedor):
  # con TCP_LISTEN_HOST vacío o en loopback, s1 solo escucha dentro de su propio contenedor.
  listen="$(get_var "$dir/.env.s1" TCP_LISTEN_HOST)"
  for s in "${ENABLED[@]}"; do
    if [ "$s" = "s0" ] && { [ -z "$listen" ] || [ "$listen" = "127.0.0.1" ] || [ "$listen" = "localhost" ]; }; then
      warn ".env.s1: s0 está activo pero TCP_LISTEN_HOST es '${listen:-vacío}': s0 no podrá alcanzar el TCP 5020 de s1 (usa 0.0.0.0)$(see red)"
    fi
  done
  check_required "$dir/.env.s1" "${REQUIRED_S1[@]}"
  # Los JSON de Firebase referenciados con /run/secrets/... deben existir en secrets/.
  for f in FCM_CERT KEEPER_FCM_CERT; do
    path="$(get_var "$dir/.env.s1" "$f")"
    if [[ "$path" == /run/secrets/* ]] && [ ! -f "$dir/secrets/${path#/run/secrets/}" ]; then
      warn ".env.s1: $f apunta a $path, pero falta secrets/${path#/run/secrets/}$(see secretos)"
      PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
    fi
  done
}

# Valida solo los servicios indicados: un servicio inactivo en la instancia no se exige.
preflight() { # instancia servicio...
  local name="$1" dir svc tag_name port_name img_name
  shift
  dir="$(instance_dir "$name")"
  PREFLIGHT_ERRORS=0

  check_required "$dir/.env.instance" "${REQUIRED_INSTANCE[@]}"
  if [ "$(get_var "$dir/.env.instance" INSTANCE)" != "$name" ]; then
    warn ".env.instance: INSTANCE no coincide con el nombre de la carpeta ($name)"
    PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
  fi

  for svc in "$@"; do
    tag_name="$(tag_var "$svc")"
    port_name="${svc^^}_PORT"
    check_required "$dir/.env.instance" "$tag_name" "$port_name"
    # Nombre de imagen propio (opcional): sin etiqueta y con formato válido.
    img_name="$(get_var "$dir/.env.instance" "${svc^^}_IMAGE")"
    if [ -n "$img_name" ]; then
      if [[ "$img_name" == *:* ]]; then
        warn ".env.instance: ${svc^^}_IMAGE='$img_name' lleva ':'; el nombre va sin etiqueta (la etiqueta va en $tag_name)$(see imagenes)"
        PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
      elif ! valid_image_name "$img_name"; then
        warn ".env.instance: ${svc^^}_IMAGE='$img_name' no es un nombre de imagen válido (minúsculas, números y . _ - ; admite /)$(see imagenes)"
        PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
      fi
    fi
    if [ "$(get_var "$dir/.env.instance" "$tag_name")" = "latest" ]; then
      warn ".env.instance: $tag_name=latest; usa una etiqueta por versión o commit"
    fi
    [ -f "$dir/.env.$svc" ] || die "falta $dir/.env.$svc"
    "preflight_$svc" "$dir"
  done

  # Permisos de data/: solo aviso (puede que el despliegue lo haga otro usuario).
  if [ -d "$dir/data" ] && [ "$(stat -c %u "$dir/data" 2>/dev/null || echo "$RUNTIME_UID")" != "$RUNTIME_UID" ]; then
    warn "data/ no pertenece al uid $RUNTIME_UID: la app podría no poder escribir. Ejecuta: sudo chown -R $RUNTIME_UID:$RUNTIME_UID $dir/data"
  fi

  [ "$PREFLIGHT_ERRORS" -eq 0 ] || die "$PREFLIGHT_ERRORS problema(s) en la configuración de '$name'; corrígelos y reintenta$(see nueva-instancia)"
}

# Con imágenes locales, comprueba que cada imagen exista en este Docker antes de tocar nada.
check_images() { # instancia servicio...
  local name="$1" svc ref missing=0
  shift
  uses_local_images "$name" || return 0
  for svc in "$@"; do
    ref="$(service_image_ref "$name" "$svc")"
    if image_exists "$ref"; then
      warn_arch_mismatch "$ref"
    else
      warn "falta la imagen $ref ($svc) en este servidor"
      missing=$((missing + 1))
    fi
  done
  [ "$missing" -eq 0 ] \
    || die "$missing imagen(es) sin cargar. Cárgalas con ./itc load <archivo> y revisa las disponibles con ./itc images$(see imagenes)"
}

# Con imágenes locales una etiqueta se puede reconstruir y apuntar a otra imagen: si la etiqueta
# desplegada ahora apunta a un ID distinto del desplegado, solo se avisa.
warn_changed_images() { # instancia servicio...
  local name="$1" dir svc tag_name cur dep dep_id ref cur_id
  shift
  dir="$(instance_dir "$name")"
  uses_local_images "$name" || return 0
  for svc in "$@"; do
    tag_name="$(tag_var "$svc")"
    cur="$(get_var "$dir/.env.instance" "$tag_name")"
    dep="$(get_var "$dir/.deployed" "$tag_name")"
    dep_id="$(get_var "$dir/.deployed" "${svc^^}_IMAGE_ID")"
    if [ -n "$dep_id" ] && [ "$cur" = "$dep" ]; then
      ref="$(service_image_ref "$name" "$svc")"
      cur_id="$(image_id "$ref")"
      if [ -n "$cur_id" ] && [ "$cur_id" != "$dep_id" ]; then
        warn "$svc: la etiqueta $cur ahora apunta a otra imagen ($(short_id "$cur_id")) distinta de la desplegada ($(short_id "$dep_id")); no reutilices etiquetas$(see imagenes)"
      fi
    fi
  done
}

# Guarda como "previas" las etiquetas (y el ID de imagen) desplegadas que van a cambiar (para el rollback).
record_previous() { # instancia servicio...
  local name="$1" dir svc tag_name id_name cur dep
  shift
  dir="$(instance_dir "$name")"
  touch "$dir/.deployed" "$dir/.previous"
  for svc in "$@"; do
    tag_name="$(tag_var "$svc")"
    id_name="${svc^^}_IMAGE_ID"
    cur="$(get_var "$dir/.env.instance" "$tag_name")"
    dep="$(get_var "$dir/.deployed" "$tag_name")"
    if [ -n "$dep" ] && [ "$dep" != "$cur" ]; then
      set_var "$dir/.previous" "$tag_name" "$dep"
      set_var "$dir/.previous" "$id_name" "$(get_var "$dir/.deployed" "$id_name")"
    fi
  done
}

# Descarga y levanta. explicit=0: todo lo activo según COMPOSE_PROFILES. explicit=1: solo los
# servicios dados; --profile reemplaza COMPOSE_PROFILES, así que los demás no se tocan.
# Registra las etiquetas desplegadas solo si todo queda healthy.
deploy_up() { # explicit instancia servicio...
  local explicit="$1" name="$2" dir svc
  shift 2
  dir="$(instance_dir "$name")"
  local -a pargs=() svcs=() upflags=()

  if [ "$explicit" = "1" ]; then
    svcs=("$@")
    for svc in "$@"; do pargs+=(--profile "$svc"); done
    # Un solo servicio: sin dependencias, para no tocar nada más.
    [ "$#" -eq 1 ] && upflags+=(--no-deps)
  fi

  if uses_local_images "$name"; then
    info "Imágenes locales (REGISTRY vacío): no se descarga nada."
  else
    info "Descargando imágenes..."
    dc "$name" ${pargs[@]+"${pargs[@]}"} pull ${svcs[@]+"${svcs[@]}"}
  fi

  info "Levantando servicios (espera a que estén healthy)..."
  if ! dc "$name" ${pargs[@]+"${pargs[@]}"} up -d ${upflags[@]+"${upflags[@]}"} \
      --wait --wait-timeout "${WAIT_TIMEOUT:-300}" ${svcs[@]+"${svcs[@]}"}; then
    warn "los servicios no llegaron a healthy"
    warn "revisa: ./itc logs $name   |   para volver atrás: ./itc rollback $name"
    return 1
  fi

  touch "$dir/.deployed"
  for svc in "$@"; do
    set_var "$dir/.deployed" "$(tag_var "$svc")" "$(get_var "$dir/.env.instance" "$(tag_var "$svc")")"
    set_var "$dir/.deployed" "${svc^^}_IMAGE_ID" "$(image_id "$(service_image_ref "$name" "$svc")")"
  done
  dc "$name" --profile '*' ps
}

cmd_deploy() {
  local name="${1:-}" only="${2:-}"
  require_instance "$name"
  select_services "$name" "$only"

  check_docker
  preflight "$name" "${SELECTED[@]}"

  info "Validando compose..."
  if [ -n "$only" ]; then
    dc "$name" --profile "$only" config -q || die "el compose no es válido para '$name'"
  else
    dc "$name" config -q || die "el compose no es válido para '$name'"
  fi

  check_images "$name" "${SELECTED[@]}"
  warn_changed_images "$name" "${SELECTED[@]}"
  if [ ! -f "$(marker_file "$name")" ] && [ "${ITC_SUPPRESS_INIT_WARN:-0}" != "1" ]; then
    warn "'$name' no está inicializada: si es una municipalidad NUEVA ejecuta ./itc init $name; si YA tiene datos, ./itc adopt $name (deploy nunca siembra)$(see datos)"
  fi
  record_previous "$name" "${SELECTED[@]}"

  if [ -n "$only" ]; then
    deploy_up 1 "$name" "${SELECTED[@]}" || die "el despliegue de $only en '$name' falló"
    ok "$only desplegado en '$name'"
  else
    deploy_up 0 "$name" "${SELECTED[@]}" || die "el despliegue de '$name' falló"
    ok "instancia '$name' desplegada (${SELECTED[*]})"
  fi
}

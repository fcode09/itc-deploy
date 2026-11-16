#!/usr/bin/env bash
# ./itc deploy <instancia>: valida, descarga imágenes y levanta la instancia.

PREFLIGHT_ERRORS=0

# Exige que cada clave exista, no esté vacía y no conserve el valor de ejemplo (CAMBIAR...).
check_required() { # archivo clave...
  local file="$1" key val
  shift
  for key in "$@"; do
    val="$(get_var "$file" "$key")"
    if [ -z "$val" ]; then
      warn "$(basename "$file"): $key está vacía"
      PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
    elif [[ "$val" == *CAMBIAR* ]]; then
      warn "$(basename "$file"): $key aún tiene el valor de ejemplo (CAMBIAR...)"
      PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
    fi
  done
}

preflight() { # instancia
  local name="$1" dir tag f path
  dir="$(instance_dir "$name")"
  PREFLIGHT_ERRORS=0

  [ -f "$dir/s0.env" ] || die "falta $dir/s0.env"
  [ -f "$dir/s1.env" ] || die "falta $dir/s1.env"

  check_required "$dir/instance.env" INSTANCE REGISTRY S0_TAG S1_TAG S0_PORT S1_PORT
  if [ "$(get_var "$dir/instance.env" INSTANCE)" != "$name" ]; then
    warn "instance.env: INSTANCE no coincide con el nombre de la carpeta ($name)"
    PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
  fi
  for tag in S0_TAG S1_TAG; do
    [ "$(get_var "$dir/instance.env" "$tag")" = "latest" ] \
      && warn "instance.env: $tag=latest; usa una etiqueta por versión o commit"
  done

  check_required "$dir/s0.env" IP_SERVER JWT_SECRET MONGO_URI IP_INTERNAL_CONNECTION
  check_required "$dir/s1.env" IP_SERVER JWT_SECRET FEDERATION_ENCRYPTION_KEY SERVERS_CONFIG \
    MONGO_DELTA_DISPATCH_URI MONGO_AUTHSOFTWARE_URI MONGO_ROBIN_URI \
    FCM_CERT KEEPER_FCM_CERT DEEPGRAM_API_KEY

  # Los JSON de Firebase referenciados con /run/secrets/... deben existir en secrets/.
  for f in FCM_CERT KEEPER_FCM_CERT; do
    path="$(get_var "$dir/s1.env" "$f")"
    if [[ "$path" == /run/secrets/* ]] && [ ! -f "$dir/secrets/${path#/run/secrets/}" ]; then
      warn "s1.env: $f apunta a $path, pero falta secrets/${path#/run/secrets/}"
      PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
    fi
  done

  # Permisos de data/: solo aviso (puede que el despliegue lo haga otro usuario).
  if [ -d "$dir/data/s0/media" ] && [ "$(stat -c %u "$dir/data/s0/media" 2>/dev/null || echo "$RUNTIME_UID")" != "$RUNTIME_UID" ]; then
    warn "data/ no pertenece al uid $RUNTIME_UID: la app podría no poder escribir. Ejecuta: sudo chown -R $RUNTIME_UID:$RUNTIME_UID $dir/data"
  fi

  [ "$PREFLIGHT_ERRORS" -eq 0 ] || die "$PREFLIGHT_ERRORS problema(s) en la configuración de '$name'; corrígelos y reintenta"
}

# Descarga imágenes y levanta; registra las etiquetas desplegadas solo si todo queda healthy.
deploy_up() { # instancia
  local name="$1" dir
  dir="$(instance_dir "$name")"

  info "Descargando imágenes..."
  dc "$name" pull

  info "Levantando servicios (espera a que estén healthy)..."
  if ! dc "$name" up -d --wait --wait-timeout "${WAIT_TIMEOUT:-300}"; then
    warn "los servicios no llegaron a healthy"
    warn "revisa: ./itc logs $name   |   para volver atrás: ./itc rollback $name"
    return 1
  fi

  snapshot_tags "$dir" > "$dir/.deployed"
  dc "$name" ps
}

cmd_deploy() {
  local name="${1:-}"
  require_instance "$name"
  local dir
  dir="$(instance_dir "$name")"

  check_docker
  preflight "$name"
  info "Validando compose..."
  dc "$name" config -q || die "el compose no es válido para '$name'"

  # Si las etiquetas cambian, las que estaban desplegadas pasan a ser las "previas" del rollback.
  if [ -f "$dir/.deployed" ] && [ "$(cat "$dir/.deployed")" != "$(snapshot_tags "$dir")" ]; then
    cp "$dir/.deployed" "$dir/.previous"
  fi

  deploy_up "$name" || die "el despliegue de '$name' falló"
  ok "instancia '$name' desplegada"
}

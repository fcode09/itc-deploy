#!/usr/bin/env bash
# ./itc new <instancia>: crea instances/<instancia>/ desde las plantillas.

cmd_new() {
  local name="${1:-}"
  [ -n "$name" ] || die "uso: ./itc new <instancia>"
  valid_instance_name "$name" \
    || die "nombre de instancia inválido: '$name' (minúsculas, números y guion; empieza con letra; 2 a 31 caracteres)"

  local dir
  dir="$(instance_dir "$name")"
  [ ! -e "$dir" ] || die "la instancia '$name' ya existe en $dir"

  local s0_port s1_port owner
  s0_port="$(next_s0_port)"
  s1_port=$((s0_port + 1))
  for p in "$s0_port" "$s1_port"; do
    owner="$(port_owner "$p" "$name")"
    [ -z "$owner" ] || die "el puerto $p ya lo usa la instancia '$owner'"
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -qE "[:.]$p[[:space:]]"; then
      warn "el puerto $p ya está en uso en este servidor; edita instance.env antes de desplegar"
    fi
  done

  mkdir -p \
    "$dir/secrets" \
    "$dir/data/s0/media/user" "$dir/data/s0/media/loginSettings" \
    "$dir/data/s0/media/file" "$dir/data/s0/media/certificate-settings" \
    "$dir/data/s0/backups" \
    "$dir/data/s1/media" "$dir/data/s1/uploads" \
    "$dir/data/s1/fileIncidentsResolved" "$dir/data/s1/imageIncidentsResolved"

  cp "$ROOT/templates/instance.env.example" "$dir/instance.env"
  cp "$ROOT/templates/s0.env.example" "$dir/s0.env"
  cp "$ROOT/templates/s1.env.example" "$dir/s1.env"
  set_var "$dir/instance.env" INSTANCE "$name"
  set_var "$dir/instance.env" S0_PORT "$s0_port"
  set_var "$dir/instance.env" S1_PORT "$s1_port"
  chmod 600 "$dir/instance.env" "$dir/s0.env" "$dir/s1.env"
  chmod 700 "$dir/secrets"

  # Los contenedores corren como uid 1000: data/ debe pertenecerle para poder escribir.
  local me
  me="$(id -u)"
  if [ "$me" = "0" ]; then
    chown -R "$RUNTIME_UID:$RUNTIME_UID" "$dir/data"
  elif [ "$me" != "$RUNTIME_UID" ]; then
    warn "data/ pertenece al uid $me y los contenedores usan el uid $RUNTIME_UID; ejecuta:"
    warn "  sudo chown -R $RUNTIME_UID:$RUNTIME_UID $dir/data"
  fi

  ok "instancia '$name' creada en $dir (puertos $s0_port/$s1_port)"
  info ""
  info "Siguientes pasos:"
  info "  1. Completa $dir/instance.env (S0_TAG, S1_TAG, REGISTRY)"
  info "  2. Completa $dir/s0.env y $dir/s1.env (secretos, URI de Mongo, IP_SERVER)"
  info "  3. Copia los JSON de Firebase a $dir/secrets/ (fcm.json y keeper-fcm.json)"
  info "  4. ./itc deploy $name"
}

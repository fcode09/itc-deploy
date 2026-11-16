#!/usr/bin/env bash
# ./itc new <instancia>: crea instances/<instancia>/ desde las plantillas.

cmd_new() {
  local name="" services="" existing=0 a
  while [ "$#" -gt 0 ]; do
    a="$1"
    case "$a" in
      --services)
        [ "$#" -ge 2 ] || die "--services requiere un valor (ej. --services s1)"
        services="$2"
        shift 2
        ;;
      --existing)
        existing=1
        shift
        ;;
      -*) die "opción desconocida: $a" ;;
      *)
        [ -z "$name" ] || die "sobra el argumento '$a'"
        name="$a"
        shift
        ;;
    esac
  done
  [ -n "$name" ] || die "uso: ./itc new <instancia> [--services s0,s1] [--existing]"
  valid_instance_name "$name" \
    || die "nombre de instancia inválido: '$name' (minúsculas, números y guion; empieza con letra; 2 a 31 caracteres)$(see new)"

  if [ -n "$services" ]; then
    local part
    local -a parts
    IFS=',' read -ra parts <<< "$services"
    for part in "${parts[@]}"; do
      valid_service "${part// /}" \
        || die "servicio desconocido en --services: '$part' (válidos: ${KNOWN_SERVICES[*]})$(see servicios)"
    done
  fi

  local dir
  dir="$(instance_dir "$name")"
  [ ! -e "$dir" ] || die "la instancia '$name' ya existe en $dir"

  local s0_port s1_port owner
  s0_port="$(next_s0_port)"
  s1_port=$((s0_port + 1))
  for p in "$s0_port" "$s1_port"; do
    owner="$(port_owner "$p" "$name")"
    [ -z "$owner" ] || die "el puerto $p ya lo usa la instancia '$owner'$(see puertos)"
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -qE "[:.]$p[[:space:]]"; then
      warn "el puerto $p ya está en uso en este servidor; edita .env.instance antes de desplegar"
    fi
  done

  mkdir -p \
    "$dir/secrets" \
    "$dir/data/s0/media/user" "$dir/data/s0/media/loginSettings" \
    "$dir/data/s0/media/file" "$dir/data/s0/media/certificate-settings" \
    "$dir/data/s0/backups" \
    "$dir/data/s1/media" "$dir/data/s1/uploads" \
    "$dir/data/s1/fileIncidentsResolved" "$dir/data/s1/imageIncidentsResolved"

  cp "$ROOT/templates/.env.instance.example" "$dir/.env.instance"
  cp "$ROOT/templates/.env.s0.example" "$dir/.env.s0"
  cp "$ROOT/templates/.env.s1.example" "$dir/.env.s1"
  set_var "$dir/.env.instance" INSTANCE "$name"
  set_var "$dir/.env.instance" S0_PORT "$s0_port"
  set_var "$dir/.env.instance" S1_PORT "$s1_port"
  if [ -n "$services" ]; then
    set_var "$dir/.env.instance" COMPOSE_PROFILES "${services// /}"
  fi
  chmod 600 "$dir/.env.instance" "$dir/.env.s0" "$dir/.env.s1"
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

  if [ "$existing" -eq 1 ]; then
    write_marker "$name" existing
    info "Marcada como EXISTENTE: ./itc init no podrá ejecutarse sobre ella (apunta sus URI a las bases actuales)."
  fi
  ok "instancia '$name' creada en $dir (puertos $s0_port/$s1_port)"
  info ""
  info "Siguientes pasos:"
  info "  1. Completa $dir/.env.instance (S0_TAG, S1_TAG, REGISTRY)"
  info "  2. Completa $dir/.env.s0 y $dir/.env.s1 (secretos, URI de Mongo, IP_SERVER)"
  info "  3. Copia los JSON de Firebase a $dir/secrets/ (fcm.json y keeper-fcm.json)"
  info "  4. ./itc deploy $name"
}

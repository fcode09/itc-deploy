#!/usr/bin/env bash
# ./deltactl new <instancia> [--services s0,s1] [--existing] [--wizard]: crea instances/<instancia>/ desde las plantillas.
# Sin nombre y en una terminal (o con --wizard) abre un asistente que pregunta lo esencial.

# REQUIRED_* y check_required vienen de deploy.sh
source "$ROOT/lib/cmd/deploy.sh"

W_S0IMG="" W_S1IMG="" W_S0TAG="" W_S1TAG="" W_IP="" W_GEN=0

# Pregunta con valor por defecto. Resultado en REPLY_VAL.
new_ask() { # pregunta [defecto]
  local def="${2:-}" ans=""
  printf '  %s?%s %s%s%s ' "$C_CYN" "$C_OFF" "$1" "${def:+ [$def]}" ":" >&2
  IFS= read -r ans || true
  REPLY_VAL="${ans:-$def}"
}

# Pregunta sí/no. Devuelve 0 si la respuesta es sí. $2 = s | n (defecto).
new_ask_yn() { # pregunta [s|n]
  local def="${2:-n}" ans="" hint="s/N"
  [ "$def" != "s" ] || hint="S/n"
  printf '  %s?%s %s [%s]: ' "$C_CYN" "$C_OFF" "$1" "$hint" >&2
  IFS= read -r ans || true
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[sSyY]$ ]]
}

# Etiquetas ya cargadas en este Docker para una imagen (una por línea, sin <none>).
new_loaded_tags() { # nombre_de_imagen
  dk_ready || return 0
  dk_images_tags \
    | awk -F'|' -v r="$1" '($1 == r || $1 ~ ("/" r "$")) && $2 != "<none>" { print $2 }'
}

# Asistente: rellena name, services, existing y los W_*.
new_wizard() {
  local svc img tags
  ui_h1 "Asistente: crear una instancia"
  printf '  %sResponde con Enter para aceptar el valor entre corchetes.%s\n\n' "$C_GRY" "$C_OFF" >&2

  new_ask "Nombre de la instancia (minúsculas, números y guion; ej. colorado)"
  name="$REPLY_VAL"
  valid_instance_name "$name" \
    || die "nombre de instancia inválido: '$name' (minúsculas, números y guion; empieza con letra; 2 a 31 caracteres)$(see new)"
  [ ! -e "$(instance_dir "$name")" ] || die "la instancia '$name' ya existe en $(instance_dir "$name")"

  new_ask "Servicios activos (s0 = Auth, s1 = Gue)" "s0,s1"
  services="${REPLY_VAL// /}"

  if new_ask_yn "¿La municipalidad YA tiene datos (viene de PM2 u otro despliegue)?" n; then
    existing=1
    printf '  %sSe marcará como existente: init no podrá sembrarla. Usa sus mismas bases y secretos.%s\n' "$C_GRY" "$C_OFF" >&2
  fi

  local -a parts
  IFS=',' read -ra parts <<< "$services"
  for svc in "${parts[@]}"; do
    valid_service "$svc" || die "servicio desconocido en el asistente: '$svc' (válidos: ${KNOWN_SERVICES[*]})$(see servicios)"
    new_ask "Nombre de la imagen de $svc" "$(default_repo "$svc")"
    img="$REPLY_VAL"
    valid_image_name "$img" || die "'$img' no es un nombre de imagen válido$(see imagenes)"
    tags="$(new_loaded_tags "$img" | tr '\n' ' ')"
    [ -z "$tags" ] || printf '  %sEtiquetas cargadas de %s: %s%s\n' "$C_GRY" "$img" "$tags" "$C_OFF" >&2
    new_ask "Etiqueta de $svc (versión a desplegar; puedes dejarla vacía y completarla después)"
    case "$svc" in
      s0) W_S0IMG="$img"; W_S0TAG="$REPLY_VAL" ;;
      s1) W_S1IMG="$img"; W_S1TAG="$REPLY_VAL" ;;
    esac
  done

  new_ask "URL pública del sistema, con esquema (IP_SERVER; ej. http://203.0.113.10)"
  W_IP="$REPLY_VAL"
  if [ "$existing" -eq 0 ]; then
    if command -v openssl >/dev/null 2>&1; then
      if new_ask_yn "¿Generar automáticamente los secretos únicos (JWT, claves de cifrado)?" s; then W_GEN=1; fi
    else
      printf '  %sopenssl no está instalado: los secretos habrá que generarlos a mano.%s\n' "$C_GRY" "$C_OFF" >&2
    fi
  fi

  printf '\n  %sResumen%s\n' "$C_BLD" "$C_OFF" >&2
  printf '    instancia   %s\n    servicios   %s\n    datos       %s\n    versiones   s0=%s s1=%s\n    URL pública %s\n    secretos    %s\n\n' \
    "$name" "$services" "$([ "$existing" -eq 1 ] && echo "ya existentes" || echo "nueva (se sembrará con ./deltactl init)")" \
    "${W_S0TAG:-(pendiente)}" "${W_S1TAG:-(pendiente)}" "${W_IP:-(pendiente)}" \
    "$([ "$W_GEN" -eq 1 ] && echo "se generarán" || echo "a completar a mano")" >&2
  new_ask_yn "¿Crear la instancia con estos valores?" s || die "cancelado"
}

# Aplica a los .env recién creados lo que respondió el asistente.
new_apply_wizard() { # instancia existing
  local name="$1" existing="$2" dir f secret
  dir="$(instance_dir "$name")"
  [ -z "$W_S0IMG" ] || [ "$W_S0IMG" = "$(default_repo s0)" ] || set_var "$dir/.env.instance" S0_IMAGE "$W_S0IMG"
  [ -z "$W_S1IMG" ] || [ "$W_S1IMG" = "$(default_repo s1)" ] || set_var "$dir/.env.instance" S1_IMAGE "$W_S1IMG"
  [ -z "$W_S0TAG" ] || set_var "$dir/.env.instance" S0_TAG "$W_S0TAG"
  [ -z "$W_S1TAG" ] || set_var "$dir/.env.instance" S1_TAG "$W_S1TAG"
  if [ -n "$W_IP" ]; then
    for f in "$dir/.env.s0" "$dir/.env.s1"; do set_var "$f" IP_SERVER "$W_IP"; done
  fi
  # Municipalidad nueva: bases con el nombre de la instancia (en una existente las URI las pone el usuario).
  if [ "$existing" -eq 0 ]; then
    sed -i "s/CAMBIAR_\\(authsoftware\\|deltadispatch\\|robin\\)_INSTANCIA/\\1_$name/g" "$dir/.env.s0" "$dir/.env.s1"
  fi
  if [ "$W_GEN" -eq 1 ]; then
    # Un mismo JWT_SECRET en s0 y s1: es seguro dentro de una misma instancia y evita rechazos entre servicios.
    secret="$(openssl rand -hex 32)"
    for f in "$dir/.env.s0" "$dir/.env.s1"; do set_var "$f" JWT_SECRET "$secret"; done
    set_var "$dir/.env.s1" FEDERATION_ENCRYPTION_KEY "$(openssl rand -base64 32)"
    set_var "$dir/.env.s1" DELTA_UNIVERSITY_HANDOFF_SECRET "$(openssl rand -hex 32)"
    set_var "$dir/.env.s1" SHIFT_UPDATE_BASELINE_SECRET "$(openssl rand -hex 24)"
  fi
}

# Lista lo que falta completar antes de ./deltactl deploy, por archivo.
new_pending() { # instancia
  local name="$1" dir svc key val miss path any=0
  local -a svcs=()
  dir="$(instance_dir "$name")"
  IFS=',' read -ra svcs <<< "$(get_var "$dir/.env.instance" COMPOSE_PROFILES)"

  miss=""
  for svc in "${svcs[@]}"; do
    for key in "$(tag_var "$svc")"; do
      val="$(get_var "$dir/.env.instance" "$key")"
      [ -n "$val" ] || miss+="$key, "
    done
  done
  new_pending_line ".env.instance" "$miss" && any=1

  for svc in "${svcs[@]}"; do
    miss=""
    local -n req="REQUIRED_${svc^^}"
    for key in "${req[@]}"; do
      val="$(get_var "$dir/.env.$svc" "$key")"
      if [ -z "$val" ] || [[ "$val" == *CAMBIAR* ]]; then miss+="$key, "; fi
    done
    unset -n req
    new_pending_line ".env.$svc" "$miss" && any=1
  done

  miss=""
  for svc in "${svcs[@]}"; do
    [ "$svc" = "s1" ] || continue
    for key in FCM_CERT KEEPER_FCM_CERT; do
      path="$(get_var "$dir/.env.s1" "$key")"
      if [[ "$path" == /run/secrets/* ]] && [ ! -f "$dir/secrets/${path#/run/secrets/}" ]; then
        miss+="${path#/run/secrets/}, "
      fi
    done
  done
  new_pending_line "secrets/" "$miss" && any=1
  [ "$any" -eq 1 ] || printf '  %s Nada pendiente: puedes ejecutar ./deltactl check %s\n' "$(ui_sym ok)" "$name"
}

new_pending_line() { # archivo "A, B, "
  [ -n "$2" ] || return 1
  printf '  %s %s%-16s%s %s\n' "$(ui_sym warn)" "$C_BLD" "$1" "$C_OFF" "${2%, }"
}

cmd_new() {
  local name="" services="" existing=0 wizard=0 a
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
      --wizard | -i)
        wizard=1
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

  # Asistente: con --wizard, o sin nombre cuando hay una terminal interactiva.
  if [ "$wizard" -eq 1 ] || { [ -z "$name" ] && [ -t 0 ] && [ -t 1 ]; }; then
    [ -z "$name" ] || die "con el asistente no se indica el nombre: se pregunta (./deltactl new --wizard)"
    new_wizard
  fi

  [ -n "$name" ] || die "uso: ./deltactl new <instancia> [--services s0,s1] [--existing]   (o ./deltactl new --wizard)"
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
    if host_port_in_use "$p"; then
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
  new_apply_wizard "$name" "$existing"

  # Los contenedores corren como uid 1000: data/ debe pertenecerle para poder escribir.
  local me
  me="$(host_uid)"
  if [ "$me" = "0" ]; then
    chown -R "$RUNTIME_UID:$RUNTIME_UID" "$dir/data"
  elif [ "$me" != "$RUNTIME_UID" ]; then
    warn "data/ pertenece al uid $me y los contenedores usan el uid $RUNTIME_UID; ejecuta:"
    warn "  sudo chown -R $RUNTIME_UID:$RUNTIME_UID $dir/data"
  fi

  if [ "$existing" -eq 1 ]; then
    write_marker "$name" existing
    info "Marcada como EXISTENTE: ./deltactl init no podrá ejecutarse sobre ella (apunta sus URI a las bases actuales)."
  fi
  ok "instancia '$name' creada en $dir (puertos $s0_port/$s1_port)"
  info ""
  info "Pendiente de completar antes de ./deltactl deploy:"
  new_pending "$name"
  info ""
  info "Siguientes pasos:"
  info "  1. Completa $dir/.env.instance (S0_TAG, S1_TAG, REGISTRY)"
  info "  2. Completa $dir/.env.s0 y $dir/.env.s1 (secretos, URI de Mongo, IP_SERVER)"
  info "  3. Copia los JSON de Firebase a $dir/secrets/ (fcm.json y keeper-fcm.json)"
  info "  4. ./deltactl check $name   (comprueba todo sin levantar nada)"
  info "  5. ./deltactl deploy $name"
  info "Detalle de cada variable: ./deltactl help variable <NOMBRE>   ·   guía completa: ./deltactl help nueva-instancia"
}

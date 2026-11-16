#!/usr/bin/env bash
# ./itc init <instancia> [--yes]: siembra los datos iniciales de una instancia NUEVA, una sola vez.
# ./itc adopt <instancia>: marca como inicializada una instancia que YA tiene datos (no siembra nada).
#
# Los seeds son DESTRUCTIVOS: hacen drop de colecciones, y el seed de s0 le ordena a s1, por TCP, que
# vacíe su tabla de usuarios. Por eso init se niega si ya hay marcador o datos, y no tiene --force.
#
# Secuencia (verificada con contenedores reales):
#   1. seed de s1 (catálogos)              2. levantar s1 y esperar healthy (debe estar ARRIBA para el seed de s0)
#   3. seed de s0: populating_data_s0 (vacía los usuarios de s1 y los vuelve a enviar), create_root_user,
#      url_systems                          4. levantar s0
# Los seeds terminan siempre con código 0 aunque fallen: se lee su log.

# cmd_deploy viene de deploy.sh
source "$ROOT/scripts/cmd/deploy.sh"

MIN_STEPS_S1=30
MIN_STEPS_S0=17
SEED_OUT=""
SEED_LOG=""

# Cuenta documentos de una colección con un contenedor de un solo uso (usa mongoose de la propia imagen).
count_docs() { # instancia servicio variable_con_la_uri coleccion
  local name="$1" svc="$2" uri_var="$3" coll="$4" dir ref out
  dir="$(instance_dir "$name")"
  ref="$(service_image_ref "$name" "$svc")"
  out="$(docker run --rm --add-host host.docker.internal:host-gateway --env-file "$dir/.env.$svc" "$ref" node -e '
    const m = require("mongoose");
    (async () => {
      const uri = process.env[process.argv[1]], coll = process.argv[2];
      await m.connect(uri, { serverSelectionTimeoutMS: 8000 });
      console.log("COUNT=" + await m.connection.db.collection(coll).countDocuments());
      await m.disconnect();
    })().catch((e) => { console.log("ERR=" + e.message); process.exit(2); });
  ' "$uri_var" "$coll" 2>&1)" || true
  if [[ "$out" =~ COUNT=([0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf 'ERR'
    warn "no se pudo comprobar $svc ($uri_var): $(printf '%s' "$out" | grep -a 'ERR=' | head -1)"
  fi
}

# Ejecuta un comando de la CLI de una imagen en un contenedor de un solo uso. Deja el log en SEED_OUT/SEED_LOG.
run_seed() { # instancia servicio red|- comando...
  local name="$1" svc="$2" net="$3" dir ref
  shift 3
  dir="$(instance_dir "$name")"
  ref="$(service_image_ref "$name" "$svc")"
  local -a args=(run --rm --add-host host.docker.internal:host-gateway --env-file "$dir/.env.$svc")
  [ "$net" = "-" ] || args+=(--network "$net")
  [ "$svc" != "s1" ] || args+=(-v "$dir/secrets:/run/secrets:ro")
  mkdir -p "$dir/init-logs"
  SEED_LOG="$dir/init-logs/$(date -u +%Y%m%dT%H%M%SZ)-$svc-$1.log"
  SEED_OUT="$(docker "${args[@]}" "$ref" node dist/cli.js "$@" 2>&1)" || true
  printf '%s\n' "$SEED_OUT" > "$SEED_LOG"
  chmod 600 "$SEED_LOG"
}

seed_steps() { printf '%s\n' "$SEED_OUT" | grep -acE 'populated|has been created|initial data' || true; }
seed_errors() { printf '%s\n' "$SEED_OUT" | grep -ac 'Ocurred an error' || true; }

fail_incomplete() { # paso motivo
  warn "siembra INCOMPLETA en '$1': $2"
  warn "log completo: $SEED_LOG"
  die "la instancia NO se marcó como inicializada. Las bases pueden haber quedado a medias: límpialas a mano (drop de sus bases) antes de reintentar, y nunca reintentes sobre datos reales."
}

# Verifica un seed: sin 'Ocurred an error', con al menos N pasos y, si se pide, con una frase concreta.
check_seed() { # paso minimo_de_pasos [frase_obligatoria]
  local step="$1" min="$2" must="${3:-}" errs steps
  errs="$(seed_errors)"
  steps="$(seed_steps)"
  [ "$errs" -eq 0 ] || fail_incomplete "$step" "el log trae $errs 'Ocurred an error'"
  [ "$steps" -ge "$min" ] || fail_incomplete "$step" "solo $steps pasos completados (se esperaban al menos $min)"
  if [ -n "$must" ] && ! printf '%s\n' "$SEED_OUT" | grep -aq "$must"; then
    fail_incomplete "$step" "no aparece '$must' en el log"
  fi
  info "  $step: $steps pasos, sin errores"
}

cmd_init() {
  parse_yes "$@"
  local name="${ARGS[0]:-}"
  require_instance "$name"
  local dir s have0=0 have1=0
  dir="$(instance_dir "$name")"
  # Los deploy internos de init no deben avisar de que la instancia "no está inicializada".
  export ITC_SUPPRESS_INIT_WARN=1

  select_services "$name"
  for s in "${ENABLED[@]}"; do
    [ "$s" != "s0" ] || have0=1
    [ "$s" != "s1" ] || have1=1
  done
  [ "$have0" -eq 1 ] && [ "$have1" -eq 1 ] \
    || die "init necesita s0 y s1 activos en COMPOSE_PROFILES de '$name' (el seed de s0 sincroniza usuarios con s1)$(see servicios)"

  if [ -f "$(marker_file "$name")" ]; then
    die "'$name' ya está inicializada ($(get_var "$(marker_file "$name")" SOURCE), $(get_var "$(marker_file "$name")" INITIALIZED_AT)). init no se vuelve a ejecutar: los seeds borran datos."
  fi

  check_docker
  preflight "$name" s0 s1
  check_images "$name" s0 s1

  info "Comprobando que las bases no tengan datos (los seeds los borrarían)..."
  local n_auth n_gue
  n_auth="$(count_docs "$name" s0 MONGO_URI usuarios)"
  n_gue="$(count_docs "$name" s1 MONGO_DELTA_DISPATCH_URI users)"
  [ "$n_auth" != "ERR" ] && [ "$n_gue" != "ERR" ] || die "no se pudo comprobar Mongo; revisa las URI de .env.s0 y .env.s1 y que Mongo sea alcanzable$(see solucion-problemas)"
  if [ "$n_auth" -gt 0 ] || [ "$n_gue" -gt 0 ]; then
    die "'$name' ya tiene datos (Auth usuarios=$n_auth, Gue users=$n_gue): los seeds los BORRARÍAN. Si es una municipalidad existente, usa: ./itc adopt $name$(see instancia-existente)"
  fi

  info "Se sembrarán los datos iniciales de '$name' (operación única y destructiva sobre sus bases)."
  confirm "¿Continuar?" || die "cancelado"

  info "1/4 Seed de s1 (catálogos)..."
  run_seed "$name" s1 - populating_data_s1
  check_seed "populating_data_s1" "$MIN_STEPS_S1"

  info "2/4 Levantando s1 (debe estar arriba para que el seed de s0 sincronice usuarios)..."
  cmd_deploy "$name" s1

  info "3/4 Seeds de s0 (en la red privada de la instancia)..."
  run_seed "$name" s0 "${name}_net" populating_data_s0
  if printf '%s\n' "$SEED_OUT" | grep -aq 'GUEP SERVER IS DOWN'; then
    fail_incomplete "populating_data_s0" "s0 no alcanzó a s1 por TCP (¿TCP_LISTEN_HOST=0.0.0.0 en .env.s1 y una imagen de gueo con esa variable?): no se sincronizaron usuarios con s1"
  fi
  check_seed "populating_data_s0" "$MIN_STEPS_S0"
  run_seed "$name" s0 "${name}_net" create_root_user
  check_seed "create_root_user" 0 "Root user created"
  run_seed "$name" s0 "${name}_net" url_systems "$(get_var "$dir/.env.s0" IP_SERVER)"
  check_seed "url_systems" 0 "Url of server has created successfully"

  info "4/4 Levantando s0..."
  cmd_deploy "$name" s0

  local a_after g_after
  a_after="$(count_docs "$name" s0 MONGO_URI usuarios)"
  g_after="$(count_docs "$name" s1 MONGO_DELTA_DISPATCH_URI users)"
  [ "$g_after" != "ERR" ] && [ "$g_after" -gt 0 ] \
    || warn "Gue quedó sin usuarios (users=$g_after): la sincronización s0 -> s1 no llegó; revisa TCP_LISTEN_HOST$(see red)"

  write_marker "$name" init
  ok "instancia '$name' inicializada (Auth usuarios=$a_after, Gue users=$g_after). Logs en $dir/init-logs/"
  warn "Los usuarios root/superuser tienen contraseñas fijas en el código de Auth: cámbialas tras el primer login."
}

cmd_adopt() {
  local name="${1:-}"
  require_instance "$name"
  if [ -f "$(marker_file "$name")" ]; then
    die "'$name' ya está marcada ($(get_var "$(marker_file "$name")" SOURCE)): nada que hacer"
  fi
  write_marker "$name" existing
  ok "instancia '$name' marcada como existente: ./itc init no podrá ejecutarse sobre ella (no se sembró nada)"
}

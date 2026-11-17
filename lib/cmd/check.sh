#!/usr/bin/env bash
# ./deltactl check <instancia> [servicio] [--mongo]
# Comprueba, SIN levantar nada, todo lo que ./deltactl deploy exigiría, y lo muestra como un informe:
# configuración, compose, imágenes, etiquetas, puertos y datos. Con --mongo también prueba que cada
# servicio llegue a sus bases (con un contenedor de un solo uso). Es solo lectura.

# preflight, check_images y warn_changed_images viene de deploy.sh
source "$ROOT/lib/cmd/deploy.sh"

CK_ERR=0
CK_WARN=0

# ck <estado> <texto> [detalle...]   estado: ok | warn | err | info
ck() {
  local st="$1" msg="$2" d
  shift 2
  case "$st" in err) CK_ERR=$((CK_ERR + 1)) ;; warn) CK_WARN=$((CK_WARN + 1)) ;; esac
  printf '  %s %s\n' "$(ui_sym "$st")" "$msg"
  for d in "$@"; do
    [ -z "$d" ] || printf '      %s%s%s\n' "$C_GRY" "$d" "$C_OFF"
  done
}

# Quita los colores y los prefijos AVISO/ERROR de los mensajes capturados, una línea por entrada.
ck_lines() {
  sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^AVISO //' -e 's/^ERROR //' | sed '/^$/d'
}

# Prueba la conexión a una base con un contenedor de un solo uso (usa mongoose de la propia imagen).
ck_mongo() { # instancia servicio variable
  local name="$1" svc="$2" var="$3" dir ref out
  dir="$(instance_dir "$name")"
  ref="$(service_image_ref "$name" "$svc")"
  out="$(dk_run_once "$dir/.env.$svc" "$ref" -- node -e '
    const m = require("mongoose");
    (async () => {
      const uri = process.env[process.argv[1]];
      await m.connect(uri, { serverSelectionTimeoutMS: 6000 });
      await m.connection.db.admin().ping();
      console.log("OK=" + m.connection.name);
      await m.disconnect();
    })().catch((e) => { console.log("ERR=" + e.message); process.exit(2); });
  ' "$var" 2>&1)" || true
  if [[ "$out" =~ OK=([^[:space:]]*) ]]; then
    ck ok "$svc: $var responde (base '${BASH_REMATCH[1]}')"
  else
    ck err "$svc: $var no responde" "$(printf '%s' "$out" | grep -a 'ERR=' | head -1)" \
      "Revisa la URI y que Mongo sea alcanzable desde un contenedor (host.docker.internal)"
  fi
}

# Variables con la URI de Mongo de cada servicio.
ck_mongo_vars() { # servicio
  case "$1" in
    s0) echo MONGO_URI ;;
    s1) echo MONGO_DELTA_DISPATCH_URI MONGO_AUTHSOFTWARE_URI MONGO_ROBIN_URI ;;
  esac
}

cmd_check() {
  local name="" only="" mongo=0 a
  while [ "$#" -gt 0 ]; do
    a="$1"
    case "$a" in
      --mongo) mongo=1 ;;
      -*) die "opción desconocida: $a (ver ./deltactl help check)" ;;
      *)
        if [ -z "$name" ]; then name="$a"
        elif [ -z "$only" ]; then only="$a"
        else die "sobra el argumento '$a'"; fi
        ;;
    esac
    shift
  done
  require_instance "$name"
  select_services "$name" "$only"
  check_docker
  local dir svc ref out rc owner p var arch srv
  dir="$(instance_dir "$name")"

  ui_h1 "Comprobación de '$name'"
  ui_kv "servicios" "${SELECTED[*]}" 12
  printf '\n'

  # 1. Configuración (las mismas validaciones que ./deltactl deploy).
  out="$( (preflight "$name" "${SELECTED[@]}") 2>&1 )" && rc=0 || rc=$?
  out="$(printf '%s\n' "$out" | ck_lines)"
  if [ "$rc" -ne 0 ]; then
    mapfile -t lines <<< "$out"
    ck err "Configuración incompleta" "${lines[@]}"
  elif [ -n "$out" ]; then
    mapfile -t lines <<< "$out"
    ck warn "Configuración válida, con avisos" "${lines[@]}"
  else
    ck ok "Configuración completa (variables obligatorias, nombres de imagen y secretos)"
  fi

  # 2. Compose.
  if [ -n "$only" ]; then
    out="$(dk_compose "$name" --profile "$only" config -q 2>&1)" && rc=0 || rc=$?
  else
    out="$(dk_compose "$name" config -q 2>&1)" && rc=0 || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    ck ok "El compose de la instancia es válido"
  else
    ck err "El compose no es válido" "$(printf '%s' "$out" | head -n2 | tr '\n' ' ')"
  fi

  # 3. Imágenes.
  srv="$(server_arch)"
  for svc in "${SELECTED[@]}"; do
    ref="$(service_image_ref "$name" "$svc")"
    if ! uses_local_images "$name"; then
      ck info "$svc: se descargará $ref del registry al desplegar"
    elif dk_image_exists "$ref"; then
      arch="$(dk_image_arch "$ref")"
      [ -n "$arch" ] || arch='?'
      if [ -n "$srv" ] && [ "$arch" != "$srv" ] && [ "$arch" != "?" ]; then
        ck err "$svc: la imagen $ref es $arch y este servidor es $srv" "No podrá arrancar: constrúyela para $srv"
      else
        ck ok "$svc: imagen $ref cargada ($(short_id "$(dk_image_id "$ref")"), $arch)"
      fi
    else
      ck err "$svc: falta la imagen $ref en este servidor" \
        "Cárgala con ./deltactl load <archivo>  ·  etiquetas disponibles: ./deltactl images"
    fi
  done

  # 4. Etiquetas que apuntan a otra imagen distinta de la desplegada.
  out="$( (warn_changed_images "$name" "${SELECTED[@]}") 2>&1 | ck_lines)"
  if [ -n "$out" ]; then
    ck warn "Una etiqueta apunta a otra imagen que la desplegada" "$out"
  fi

  # 5. Puertos.
  for svc in "${SELECTED[@]}"; do
    p="$(get_var "$dir/.env.instance" "${svc^^}_PORT")"
    [ -n "$p" ] || continue
    owner="$(port_owner "$p" "$name")"
    if [ -n "$owner" ]; then
      ck err "$svc: el puerto $p ya lo usa la instancia '$owner'" "Cambia ${svc^^}_PORT en .env.instance"
    elif host_port_in_use "$p"; then
      if dk_project_publishes_port "$name" "$p"; then
        ck ok "$svc: puerto $p ocupado por esta misma instancia (ya está desplegada)"
      else
        ck warn "$svc: el puerto $p ya está en uso en este servidor" "Compruébalo con: ss -ltnp | grep :$p"
      fi
    else
      ck ok "$svc: puerto $p libre"
    fi
  done

  # 6. Datos.
  if [ -f "$(marker_file "$name")" ]; then
    ck ok "Datos: $(get_var "$(marker_file "$name")" SOURCE) (marcador .initialized presente)"
  else
    ck info "Datos: sin sembrar. Municipalidad NUEVA: ./deltactl init $name · con datos: ./deltactl adopt $name"
  fi

  # 7. Mongo (opcional: tarda y necesita las imágenes).
  if [ "$mongo" -eq 1 ]; then
    for svc in "${SELECTED[@]}"; do
      ref="$(service_image_ref "$name" "$svc")"
      if uses_local_images "$name" && ! dk_image_exists "$ref"; then
        ck warn "$svc: no se pueden probar las bases sin la imagen $ref"
        continue
      fi
      for var in $(ck_mongo_vars "$svc"); do ck_mongo "$name" "$svc" "$var"; done
    done
  else
    ck info "Bases de datos: no probadas. Añade --mongo para comprobar la conexión de cada servicio"
  fi

  printf '\n'
  if [ "$CK_ERR" -gt 0 ]; then
    printf '  %s %s%d error(es), %d aviso(s): corrige los errores antes de ./deltactl deploy %s%s\n' \
      "$(ui_sym err)" "$C_RED" "$CK_ERR" "$CK_WARN" "$name" "$C_OFF"
    ui_hint "Ayuda: ./deltactl help solucion-problemas   ·   variables: ./deltactl help variable"
    return 1
  fi
  if [ "$CK_WARN" -gt 0 ]; then
    printf '  %s %sListo para desplegar, con %d aviso(s)%s\n' "$(ui_sym warn)" "$C_YEL" "$CK_WARN" "$C_OFF"
  else
    printf '  %s %sTodo en orden: listo para desplegar%s\n' "$(ui_sym ok)" "$C_GRN" "$C_OFF"
  fi
  ui_hint "./deltactl deploy $name"
}

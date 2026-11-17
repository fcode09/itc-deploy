#!/usr/bin/env bash
# ./itc doctor
# Diagnóstico del servidor, SOLO LECTURA: Docker y Compose, disco, memoria, Mongo, permisos de las
# instancias y herramientas auxiliares. Cada fallo dice cómo arreglarlo. Termina con código 1 si hay errores.

# ck (informe con símbolos) viene de check.sh; st_enabled (servicios activos) de status.sh
source "$ROOT/scripts/cmd/check.sh"
source "$ROOT/scripts/cmd/status.sh"

# 512m -> 512, 2g -> 2048, 1.5g -> 1536 (megabytes)
dr_mem_mb() { # valor
  awk -v v="$1" 'BEGIN {
    u = tolower(substr(v, length(v))); n = substr(v, 1, length(v) - 1) + 0
    if (u == "g") n *= 1024; else if (u == "k") n /= 1024; else if (u != "m") n = v / 1048576
    printf "%d", n }'
}

# ¿Se puede abrir una conexión TCP? (3 s de límite, sin herramientas externas)
dr_tcp() { # host puerto
  timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" >/dev/null 2>&1
}

# host y puerto de una URI mongodb://[usuario:clave@]host[:puerto]/base
dr_mongo_hostport() { # uri -> "host puerto"
  local u="${1#*://}" h p
  u="${u#*@}"
  u="${u%%/*}"
  u="${u%%,*}"
  h="${u%%:*}"
  p="${u##*:}"
  [ "$p" != "$u" ] || p=27017
  printf '%s %s' "$h" "$p"
}

dr_kb_to_gb() { awk -v k="$1" 'BEGIN { printf "%.1f", k / 1048576 }'; }

cmd_doctor() {
  [ "$#" -eq 0 ] || die "doctor no recibe argumentos (ver ./itc help doctor)"
  local v cv root free total avail line f name svc raw mb sum=0 gw h p seen="" uri var pid lim

  ui_h1 "Diagnóstico del servidor"

  # --- Docker ------------------------------------------------------------------------------
  ui_h2 "Docker"
  if ! command -v docker >/dev/null 2>&1; then
    ck err "Docker no está instalado o no está en el PATH" "Instálalo: https://docs.docker.com/engine/install/"
  elif ! docker info >/dev/null 2>&1; then
    ck err "No se puede hablar con el daemon de Docker" \
      "¿Servicio detenido? sudo systemctl start docker" "¿Sin permisos? Añade tu usuario al grupo docker y vuelve a entrar"
  else
    v="$(docker info --format '{{.ServerVersion}}' 2>/dev/null)"
    ck ok "Docker $v (arquitectura $(server_arch))"
    cv="$(docker compose version --short 2>/dev/null | sed 's/^v//')"
    if [ -z "$cv" ]; then
      ck err "Falta el plugin 'docker compose'" "Se necesita Compose v2.20 o superior (por 'include')"
    elif [ "$(printf '%s\n%s\n' 2.20.0 "$cv" | sort -V | head -n1)" != "2.20.0" ]; then
      ck err "Docker Compose $cv es demasiado antiguo" "Se necesita 2.20 o superior"
    else
      ck ok "Docker Compose $cv"
    fi
  fi

  # --- Recursos ----------------------------------------------------------------------------
  ui_h2 "Recursos"
  root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  [ -n "$root" ] && [ -d "$root" ] || root="$ROOT"
  free="$(df -Pk "$root" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  if [[ "${free:-}" =~ ^[0-9]+$ ]]; then
    if [ "$free" -lt 3145728 ]; then
      ck err "Poco disco libre en $root: $(dr_kb_to_gb "$free") GB" "Las imágenes y los logs necesitan espacio. Libera disco o mueve Docker."
    elif [ "$free" -lt 10485760 ]; then
      ck warn "Disco libre en $root: $(dr_kb_to_gb "$free") GB (menos de 10 GB)"
    else
      ck ok "Disco libre en $root: $(dr_kb_to_gb "$free") GB"
    fi
  else
    ck info "No se pudo medir el disco libre"
  fi

  total="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || true)"
  avail="$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo 2>/dev/null || true)"
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    name="$(basename "$(dirname "$f")")"
    st_enabled "$name" 2>/dev/null || ST_ENABLED=()
    for svc in ${ST_ENABLED[@]+"${ST_ENABLED[@]}"}; do
      raw="$(get_var "$f" "${svc^^}_MEM_LIMIT")"
      [ -n "$raw" ] || continue
      mb="$(dr_mem_mb "$raw")"
      sum=$((sum + mb))
    done
  done
  if [[ "${total:-}" =~ ^[0-9]+$ ]]; then
    ck ok "Memoria: $((total / 1024)) MB en total, $((${avail:-0} / 1024)) MB disponibles"
    if [ "$sum" -gt $((total / 1024)) ]; then
      ck warn "Los límites de memoria de las instancias suman $sum MB, más que la RAM del servidor" \
        "Son techos, no reservas: si todas las instancias los alcanzan a la vez, el servidor se queda sin memoria"
    elif [ "$sum" -gt 0 ]; then
      ck ok "Límites de memoria de las instancias: $sum MB en total"
    fi
  else
    ck info "No se pudo leer la memoria de este servidor"
  fi

  # --- MongoDB -----------------------------------------------------------------------------
  ui_h2 "MongoDB"
  gw=""
  if docker info >/dev/null 2>&1; then
    gw="$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)"
  fi
  for f in "$INSTANCES_DIR"/*/.env.s0 "$INSTANCES_DIR"/*/.env.s1; do
    [ -f "$f" ] || continue
    for var in MONGO_URI MONGO_DELTA_DISPATCH_URI MONGO_AUTHSOFTWARE_URI MONGO_ROBIN_URI; do
      uri="$(get_var "$f" "$var")"
      [ -n "$uri" ] || continue
      read -r h p <<< "$(dr_mongo_hostport "$uri")"
      case " $seen " in *" $h:$p "*) continue ;; esac
      seen+=" $h:$p"
      if [ "$h" = "host.docker.internal" ]; then
        # Así llegan los contenedores: a la puerta de enlace de Docker, no a 127.0.0.1 del servidor.
        if [ -z "$gw" ]; then
          ck info "$h:$p: no se pudo averiguar la puerta de enlace de Docker para probarlo"
        elif dr_tcp "$gw" "$p"; then
          ck ok "$h:$p alcanzable desde los contenedores (por $gw)"
        else
          ck err "$h:$p NO es alcanzable desde los contenedores (probado contra $gw:$p)" \
            "Mongo debe escuchar en $gw o en 0.0.0.0 (bindIp en mongod.conf) y el firewall debe permitirlo"
        fi
      elif dr_tcp "$h" "$p"; then
        ck ok "$h:$p alcanzable"
      else
        ck err "$h:$p no responde por TCP" "Revisa la URI en $(basename "$(dirname "$f")")/$(basename "$f") y la red"
      fi
    done
  done
  [ -n "$seen" ] || ck info "Ninguna instancia define URI de Mongo todavía"

  pid="$(pgrep -x mongod 2>/dev/null | head -n1 || true)"
  if [ -n "$pid" ] && [ -r "/proc/$pid/limits" ]; then
    lim="$(awk '/^Max open files/ { print $4 }' "/proc/$pid/limits")"
    if [[ "$lim" =~ ^[0-9]+$ ]] && [ "$lim" -lt 64000 ]; then
      ck warn "mongod permite $lim archivos abiertos (recomendado: 64000 o más)" \
        "Con muchas instancias Mongo puede caer con EMFILE. Sube LimitNOFILE en su servicio systemd."
    elif [[ "$lim" =~ ^[0-9]+$ ]]; then
      ck ok "mongod permite $lim archivos abiertos"
    fi
  else
    ck info "No se pudo comprobar el límite de archivos abiertos de Mongo (no corre aquí o no es visible)" \
      "Con muchas instancias conviene 64000 o más: ./itc help solucion-problemas"
  fi

  # --- Instancias --------------------------------------------------------------------------
  ui_h2 "Instancias"
  local n=0 dir bad uid fstype
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    dir="$(dirname "$f")"
    name="$(basename "$dir")"
    bad=""
    # Windows montado en WSL (/mnt/c...) y otros sistemas sin permisos Unix muestran todo como 777:
    # no se puede comprobar nada y avisar sería un falso positivo. ITC_FSTYPE permite forzarlo en tests.
    fstype="${ITC_FSTYPE:-$(stat -f -c %T "$dir" 2>/dev/null || echo unknown)}"
    case "$fstype" in
      9p | drvfs | ntfs | fuseblk | vfat | msdos | exfat)
        ck info "$name: el sistema de archivos ($fstype) no maneja permisos Unix (¿WSL sobre Windows?): no se comprueban"
        continue
        ;;
    esac
    for v in .env.instance .env.s0 .env.s1; do
      [ -f "$dir/$v" ] || continue
      p="$(stat -c %a "$dir/$v" 2>/dev/null || echo 600)"
      case "$p" in *00) ;; *) bad+="$v ($p) " ;; esac
    done
    uid="$(stat -c %u "$dir/data" 2>/dev/null || echo "$RUNTIME_UID")"
    if [ -n "$bad" ]; then
      ck warn "$name: archivos con secretos legibles por otros usuarios: $bad" "Corrige con: chmod 600 $dir/.env.*"
    elif [ "$uid" != "$RUNTIME_UID" ]; then
      ck warn "$name: data/ pertenece al uid $uid y los contenedores usan el $RUNTIME_UID" \
        "Corrige con: sudo chown -R $RUNTIME_UID:$RUNTIME_UID $dir/data"
    else
      ck ok "$name: permisos correctos"
    fi
  done
  [ "$n" -gt 0 ] || ck info "No hay instancias todavía: crea la primera con ./itc new <instancia>"

  # --- Herramientas ------------------------------------------------------------------------
  ui_h2 "Herramientas"
  for v in ss openssl gunzip; do
    if command -v "$v" >/dev/null 2>&1; then
      ck ok "$v disponible"
    else
      case "$v" in
        ss) ck warn "Falta 'ss'" "Sin ella no se detectan puertos ocupados por otros procesos (paquete iproute2)" ;;
        openssl) ck warn "Falta 'openssl'" "Sin ella el asistente no puede generar secretos por ti" ;;
        gunzip) ck warn "Falta 'gunzip'" "Sin ella ./itc load no puede leer archivos .tar.gz" ;;
      esac
    fi
  done

  printf '\n'
  if [ "$CK_ERR" -gt 0 ]; then
    printf '  %s %s%d error(es) y %d aviso(s)%s\n' "$(ui_sym err)" "$C_RED" "$CK_ERR" "$CK_WARN" "$C_OFF"
    return 1
  fi
  if [ "$CK_WARN" -gt 0 ]; then
    printf '  %s %sEl servidor funciona, con %d aviso(s)%s\n' "$(ui_sym warn)" "$C_YEL" "$CK_WARN" "$C_OFF"
  else
    printf '  %s %sServidor en buen estado%s\n' "$(ui_sym ok)" "$C_GRN" "$C_OFF"
  fi
}

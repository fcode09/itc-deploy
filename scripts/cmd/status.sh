#!/usr/bin/env bash
# ./itc status [instancia] [--json] [--stats] [--strict] [--watch [segundos]]
# Panel de estado: por cada instancia y servicio activo muestra la etiqueta configurada, la que corre,
# la salud, el puerto, el uptime, el estado de los datos y los desajustes detectados.
# Es SOLO LECTURA: nunca modifica instancias ni contenedores.

# Estado de los contenedores indexado por "<proyecto>/<servicio>". El proyecto Compose es el nombre
# de la instancia, así que no se mezclan con otros proyectos del servidor.
declare -A ST_STATE=() ST_HEALTH=() ST_CIMAGE=() ST_STARTED=() ST_CNAME=() ST_STATS=()
declare -A ST_PORTS=() HINT_SEEN=()
ST_DOCKER=0
HINTS=()
STATUS_ISSUES=0
STATUS_SERVICES=0
STATUS_INSTANCES=0

# Una sola consulta a Docker para todos los contenedores de proyectos Compose.
st_collect() {
  ST_STATE=() ST_HEALTH=() ST_CIMAGE=() ST_STARTED=() ST_CNAME=() ST_STATS=()
  ST_DOCKER=0
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || return 0
  ST_DOCKER=1
  local -a ids=()
  local proj svc state health image started cname
  mapfile -t ids < <(docker ps -aq --filter label=com.docker.compose.project 2>/dev/null)
  [ "${#ids[@]}" -gt 0 ] || return 0
  while IFS='|' read -r proj svc state health image started cname; do
    [ -n "$proj" ] && [ -n "$svc" ] || continue
    ST_STATE["$proj/$svc"]="$state"
    ST_HEALTH["$proj/$svc"]="$health"
    ST_CIMAGE["$proj/$svc"]="$image"
    ST_STARTED["$proj/$svc"]="$started"
    ST_CNAME["$proj/$svc"]="${cname#/}"
  done < <(docker inspect --format \
    '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.Config.Image}}|{{.State.StartedAt}}|{{.Name}}' \
    "${ids[@]}" 2>/dev/null)
}

# Uso de memoria y CPU de los contenedores en marcha (tarda 1-2 s: solo con --stats o en el detalle).
st_collect_stats() {
  ST_STATS=()
  [ "$ST_DOCKER" -eq 1 ] || return 0
  local name mem cpu
  while IFS='|' read -r name mem cpu; do
    [ -n "$name" ] || continue
    ST_STATS["$name"]="${mem// /}|$cpu"
  done < <(docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}|{{.CPUPerc}}' 2>/dev/null)
}

# 3725 -> 1h02m
st_duration() { # segundos
  local s="$1" d h m
  [[ "$s" =~ ^[0-9]+$ ]] || { printf -- '-'; return 0; }
  d=$((s / 86400)); h=$(((s % 86400) / 3600)); m=$(((s % 3600) / 60))
  if [ "$d" -gt 0 ]; then printf '%dd%02dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf '%dm' "$m"
  else printf '%ds' "$s"; fi
}

# Segundos transcurridos desde un instante ISO 8601 (los contenedores informan StartedAt en UTC).
st_uptime_secs() { # iso
  local t now
  t="$(date -d "$1" +%s 2>/dev/null)" || return 1
  now="$(date +%s)"
  [ "$t" -gt 0 ] && [ "$now" -ge "$t" ] || return 1
  printf '%s' "$((now - t))"
}

# Registra una sugerencia de siguiente paso (sin repetir).
st_hint() { # comando motivo
  [ -z "${HINT_SEEN[$1]:-}" ] || return 0
  HINT_SEEN["$1"]=1
  HINTS+=("$1|$2")
}

# Servicios activos de una instancia, tolerante a errores (no aborta el panel si un archivo está mal).
ST_ENABLED=()
st_enabled() { # instancia
  ST_ENABLED=()
  local raw part
  local -a parts=()
  raw="$(get_var "$(instance_dir "$1")/.env.instance" COMPOSE_PROFILES)"
  IFS=',' read -ra parts <<< "$raw"
  for part in ${parts[@]+"${parts[@]}"}; do
    part="${part// /}"
    if [ -n "$part" ] && valid_service "$part"; then ST_ENABLED+=("$part"); fi
  done
}

# Referencia de imagen que usaría Compose para el servicio (misma regla que los compose).
st_ref() { # instancia servicio
  local dir reg tag
  dir="$(instance_dir "$1")"
  reg="$(get_var "$dir/.env.instance" REGISTRY)"
  tag="$(get_var "$dir/.env.instance" "$(tag_var "$2")")"
  printf '%s%s:%s' "${reg:+$reg/}" "$(service_repo "$2" "$1")" "$tag"
}

# Etiqueta de una referencia "[registro/]nombre:etiqueta"; vacío si no tiene.
st_tag_of() {
  local last="${1##*/}"
  case "$last" in *:*) printf '%s' "${last##*:}" ;; *) printf '' ;; esac
}

# Mapa puerto -> "instancia/servicio" de los servicios activos, para detectar puertos repetidos.
st_load_ports() {
  ST_PORTS=()
  local f name svc p
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    name="$(basename "$(dirname "$f")")"
    st_enabled "$name"
    for svc in ${ST_ENABLED[@]+"${ST_ENABLED[@]}"}; do
      p="$(get_var "$f" "${svc^^}_PORT")"
      [ -n "$p" ] || continue
      ST_PORTS["$p"]="${ST_PORTS[$p]:+${ST_PORTS[$p]} }$name/$svc"
    done
  done
}

# Evalúa una fila: deja el resultado en las variables E_*.
#   E_KIND/E_TEXT  estado (ok|warn|err|dim) y su texto     E_CODES  códigos de desajuste
#   E_CFG/E_RUN/E_DEP/E_PREV  etiquetas configurada, corriendo, desplegada y previa
E_KIND="" E_TEXT="" E_CODES="" E_CFG="" E_RUN="" E_DEP="" E_PREV="" E_PORT="" E_UP="" E_UPSECS=""
E_DATA="" E_NOTES="" E_REF="" E_HEALTH="" E_STATE=""
st_eval() { # instancia servicio
  local name="$1" svc="$2" dir key f ref cur_id dep_id marker owners
  dir="$(instance_dir "$name")"
  f="$dir/.env.instance"
  key="$name/$svc"
  E_KIND="" E_TEXT="" E_CODES="" E_NOTES="" E_UP="" E_UPSECS=""
  E_CFG="$(get_var "$f" "$(tag_var "$svc")")"
  E_PORT="$(get_var "$f" "${svc^^}_PORT")"
  E_DEP="$(get_var "$dir/.deployed" "$(tag_var "$svc")")"
  E_PREV="$(get_var "$dir/.previous" "$(tag_var "$svc")")"
  E_REF="$(st_ref "$name" "$svc")"
  E_STATE="${ST_STATE[$key]:-}"
  E_HEALTH="${ST_HEALTH[$key]:-}"
  E_RUN="-"

  marker="$(marker_file "$name")"
  if [ -f "$marker" ]; then
    E_DATA="$(get_var "$marker" SOURCE)"
    [ "$E_DATA" != "existing" ] || E_DATA="existente"
  else
    E_DATA="sin sembrar"
  fi

  if [ "$ST_DOCKER" -eq 0 ]; then
    E_KIND=warn E_TEXT="sin docker"
    return 0
  fi

  if [ -z "$E_STATE" ]; then
    E_KIND=dim E_TEXT="no creado"
    E_CODES="not-created"
  else
    local rt
    rt="$(st_tag_of "${ST_CIMAGE[$key]:-}")"
    E_RUN="${rt:-?}"
    case "$E_STATE" in
      running)
        case "$E_HEALTH" in
          healthy) E_KIND=ok E_TEXT=healthy ;;
          starting) E_KIND=warn E_TEXT=starting E_CODES+=" starting" ;;
          unhealthy) E_KIND=err E_TEXT=unhealthy E_CODES+=" unhealthy" ;;
          *) E_KIND=ok E_TEXT=running ;;
        esac
        E_UPSECS="$(st_uptime_secs "${ST_STARTED[$key]:-}" 2>/dev/null || true)"
        E_UP="$(st_duration "$E_UPSECS")"
        ;;
      restarting) E_KIND=err E_TEXT=reiniciando E_CODES+=" restarting" ;;
      exited | dead) E_KIND=warn E_TEXT=detenido E_CODES+=" stopped" ;;
      *) E_KIND=warn E_TEXT="$E_STATE" E_CODES+=" stopped" ;;
    esac
    # La etiqueta que corre no es la configurada: falta un `deploy`.
    if [ -n "$rt" ] && [ -n "$E_CFG" ] && [ "$rt" != "$E_CFG" ]; then
      E_CODES+=" tag-drift"
      [ "$E_KIND" = "err" ] || E_KIND=warn
    fi
  fi

  # Imagen local: debe existir, y su etiqueta no debe haber cambiado de imagen desde el despliegue.
  if uses_local_images "$name" && [ -n "$E_CFG" ]; then
    if ! image_exists "$E_REF"; then
      E_CODES+=" image-missing"
      [ "$E_KIND" = "err" ] || E_KIND=warn
    else
      dep_id="$(get_var "$dir/.deployed" "${svc^^}_IMAGE_ID")"
      if [ -n "$dep_id" ] && [ "$E_DEP" = "$E_CFG" ]; then
        cur_id="$(image_id "$E_REF")"
        if [ -n "$cur_id" ] && [ "$cur_id" != "$dep_id" ]; then
          E_CODES+=" image-rebuilt"
          [ "$E_KIND" = "err" ] || E_KIND=warn
        fi
      fi
    fi
  fi

  # Puerto repetido con otra instancia o servicio.
  owners=""
  [ -z "$E_PORT" ] || owners="${ST_PORTS[$E_PORT]:-}"
  if [ -n "$owners" ] && [ "$owners" != "$name/$svc" ]; then
    E_CODES+=" port-conflict"
    E_KIND=err
  fi

  E_CODES="${E_CODES# }"
  [ -n "$E_KIND" ] || E_KIND=ok
}

# Texto legible de los códigos de desajuste de la fila actual (y sugerencias de siguiente paso).
st_notes() { # instancia servicio
  local name="$1" svc="$2" code notes="" owners
  for code in $E_CODES; do
    case "$code" in
      tag-drift)
        notes+="configurada $E_CFG pero corre $E_RUN; "
        st_hint "./itc deploy $name $svc" "$name/$svc corre $E_RUN y está configurada $E_CFG"
        ;;
      image-rebuilt)
        notes+="la etiqueta $E_CFG apunta a otra imagen que la desplegada; "
        st_hint "./itc deploy $name $svc" "$name/$svc: recrear con la imagen reconstruida (no reutilices etiquetas)"
        ;;
      image-missing)
        notes+="falta la imagen $E_REF; "
        st_hint "./itc load <archivo.tar>" "cargar $E_REF en este servidor"
        ;;
      port-conflict)
        owners=""
        [ -z "$E_PORT" ] || owners="${ST_PORTS[$E_PORT]:-}"
        notes+="puerto $E_PORT repetido ($owners); "
        st_hint "edita instances/$name/.env.instance" "puerto $E_PORT repetido entre $owners"
        ;;
      stopped)
        notes+="detenido; "
        st_hint "./itc deploy $name $svc" "levantar de nuevo $name/$svc"
        ;;
      unhealthy | restarting)
        notes+="no está sano; "
        st_hint "./itc logs $name $svc" "revisar por qué $name/$svc no está sano"
        ;;
      not-created)
        st_hint "./itc deploy $name" "$name no tiene contenedores creados"
        ;;
    esac
  done
  if [ -n "$E_PREV" ] && [ "$E_PREV" != "$E_CFG" ]; then notes+="previa $E_PREV; "; fi
  E_NOTES="${notes%; }"
}

# Pistas a nivel de instancia (no de servicio).
st_instance_hints() { # instancia
  local name="$1" marker
  marker="$(marker_file "$name")"
  if [ ! -f "$marker" ]; then
    st_hint "./itc init $name" "$name no tiene datos iniciales (si ya tiene datos: ./itc adopt $name)"
  fi
}

# Servicios que corren en la instancia pero ya no están en COMPOSE_PROFILES.
st_orphans() { # instancia
  local name="$1" key svc s found
  for key in "${!ST_STATE[@]}"; do
    [ "${key%%/*}" = "$name" ] || continue
    svc="${key#*/}"
    found=0
    for s in ${ST_ENABLED[@]+"${ST_ENABLED[@]}"}; do [ "$s" = "$svc" ] && found=1; done
    [ "$found" -eq 1 ] && continue
    [ "${ST_STATE[$key]}" = "running" ] || continue
    printf '%s\n' "$svc"
  done
}

st_stats_cells() { # instancia servicio -> "mem|cpu"
  local cn="${ST_CNAME[$1/$2]:-}"
  printf '%s' "${ST_STATS[$cn]:--|-}"
}

status_table() { # [instancia]
  local only="${1:-}" f name svc first stats
  local -a widths=(16 4 10 10 17 6 8 12) head=(INSTANCIA SVC CONFIG CORRIENDO ESTADO PUERTO UPTIME DATOS) row=() orphans=()
  if [ "$STATUS_STATS" -eq 1 ]; then widths+=(17 7); head+=(MEMORIA CPU); fi
  widths+=(20)
  head+=(NOTAS)
  ui_table_cols "${widths[@]}"
  ui_th "${head[@]}"
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    name="$(basename "$(dirname "$f")")"
    [ -z "$only" ] || [ "$only" = "$name" ] || continue
    STATUS_INSTANCES=$((STATUS_INSTANCES + 1))
    st_enabled "$name"
    st_instance_hints "$name"
    first=1
    if [ "${#ST_ENABLED[@]}" -eq 0 ]; then
      ui_tr "bold:$name" "-" "-" "-" "err:perfil vacío" "-" "-" "-" "COMPOSE_PROFILES vacío o inválido en .env.instance"
      STATUS_ISSUES=$((STATUS_ISSUES + 1))
      continue
    fi
    for svc in "${ST_ENABLED[@]}"; do
      st_eval "$name" "$svc"
      st_notes "$name" "$svc"
      STATUS_SERVICES=$((STATUS_SERVICES + 1))
      case "$E_KIND" in warn | err) STATUS_ISSUES=$((STATUS_ISSUES + 1)) ;; esac
      row=()
      if [ "$first" -eq 1 ]; then row+=("bold:$name"); else row+=("dim:$name"); fi
      first=0
      row+=("$svc")
      if [ -n "$E_CFG" ]; then row+=("$E_CFG"); else row+=("err:(vacía)"); fi
      case " $E_CODES " in *" tag-drift "*) row+=("warn:$E_RUN") ;; *) row+=("$E_RUN") ;; esac
      row+=("st-$E_KIND:$E_TEXT")
      case " $E_CODES " in *" port-conflict "*) row+=("err:$E_PORT") ;; *) row+=("$E_PORT") ;; esac
      row+=("${E_UP:--}")
      if [ "$E_DATA" = "sin sembrar" ]; then row+=("warn:$E_DATA"); else row+=("$E_DATA"); fi
      if [ "$STATUS_STATS" -eq 1 ]; then
        stats="$(st_stats_cells "$name" "$svc")"
        row+=("${stats%%|*}" "${stats#*|}")
      fi
      row+=("dim:$E_NOTES")
      ui_tr "${row[@]}"
    done
    mapfile -t orphans < <(st_orphans "$name")
    for svc in ${orphans[@]+"${orphans[@]}"}; do
      ui_tr "dim:$name" "$svc" "-" "-" "st-warn:fuera de perfil" "-" "-" "-" "warn:corre pero no está en COMPOSE_PROFILES"
      STATUS_ISSUES=$((STATUS_ISSUES + 1))
      STATUS_SERVICES=$((STATUS_SERVICES + 1))
      st_hint "./itc stop $name $svc" "$svc corre en $name sin estar en COMPOSE_PROFILES (o añádelo a .env.instance)"
    done
  done
  if [ "$STATUS_INSTANCES" -eq 0 ]; then
    if [ -n "$only" ]; then die "la instancia '$only' no existe. Créala con: ./itc new $only"; fi
    info "(no hay instancias; crea una con ./itc new <instancia>)"
    st_hint "./itc new <instancia>" "crear la primera instancia"
  fi
}

# Salida JSON (sin depender de jq).
status_json() { # [instancia]
  local only="${1:-}" f name svc first=1 codes c cfirst up
  printf '[\n'
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    name="$(basename "$(dirname "$f")")"
    [ -z "$only" ] || [ "$only" = "$name" ] || continue
    st_enabled "$name"
    for svc in ${ST_ENABLED[@]+"${ST_ENABLED[@]}"}; do
      st_eval "$name" "$svc"
      st_notes "$name" "$svc"
      case "$E_KIND" in warn | err) STATUS_ISSUES=$((STATUS_ISSUES + 1)) ;; esac
      [ "$first" -eq 1 ] || printf ',\n'
      first=0
      up="${E_UPSECS:-null}"
      codes=""
      cfirst=1
      for c in $E_CODES; do
        [ "$cfirst" -eq 1 ] || codes+=","
        cfirst=0
        codes+="\"$(ui_json_escape "$c")\""
      done
      printf '  {"instance":"%s","service":"%s","configured_tag":"%s","running_tag":"%s","deployed_tag":"%s","previous_tag":"%s","state":"%s","health":"%s","status":"%s","port":"%s","uptime_seconds":%s,"data":"%s","issues":[%s]}' \
        "$(ui_json_escape "$name")" "$svc" "$(ui_json_escape "$E_CFG")" "$(ui_json_escape "$E_RUN")" \
        "$(ui_json_escape "$E_DEP")" "$(ui_json_escape "$E_PREV")" "$(ui_json_escape "$E_STATE")" \
        "$(ui_json_escape "$E_HEALTH")" "$(ui_json_escape "$E_KIND")" "$(ui_json_escape "$E_PORT")" \
        "$up" "$(ui_json_escape "$E_DATA")" "$codes"
    done
  done
  printf '\n]\n'
}

# Vista de detalle de una instancia.
status_detail() { # instancia
  local name="$1" dir svc marker raw errs
  dir="$(instance_dir "$name")"
  st_enabled "$name"
  st_instance_hints "$name"
  STATUS_INSTANCES=1
  marker="$(marker_file "$name")"
  ui_h1 "Instancia $name"
  ui_kv "servicios" "$(IFS=,; echo "${ST_ENABLED[*]:-}")"
  if [ -f "$marker" ]; then
    ui_kv "datos" "$(get_var "$marker" SOURCE) (desde $(get_var "$marker" INITIALIZED_AT))"
  else
    ui_kv "datos" "sin sembrar"
  fi
  ui_kv "imágenes" "$(if uses_local_images "$name"; then echo "locales (REGISTRY vacío)"; else echo "registry: $(get_var "$dir/.env.instance" REGISTRY)"; fi)"
  ui_kv "carpeta" "instances/$name"
  for svc in ${ST_ENABLED[@]+"${ST_ENABLED[@]}"}; do
    st_eval "$name" "$svc"
    st_notes "$name" "$svc"
    STATUS_SERVICES=$((STATUS_SERVICES + 1))
    case "$E_KIND" in warn | err) STATUS_ISSUES=$((STATUS_ISSUES + 1)) ;; esac
    ui_h2 "Servicio $svc"
    printf '  %s%-14s%s ' "$C_GRY" "estado" "$C_OFF"
    ui_cell 12 "st-$E_KIND" "$E_TEXT" 1
    [ -z "$E_UP" ] || printf '  desde hace %s' "$E_UP"
    printf '\n'
    ui_kv "versión" "configurada ${E_CFG:-(vacía)} · corriendo $E_RUN · desplegada ${E_DEP:--}"
    ui_kv "imagen" "$E_REF"
    if [ -n "$E_PREV" ] && [ "$E_PREV" != "$E_CFG" ]; then
      ui_kv "previa" "$E_PREV (volver: ./itc rollback $name $svc)"
    fi
    ui_kv "puerto" "http://127.0.0.1:$E_PORT (solo local; publícalo con tu proxy)"
    if [ "$ST_DOCKER" -eq 1 ] && [ "$E_STATE" = "running" ]; then
      raw="$(st_stats_cells "$name" "$svc")"
      ui_kv "recursos" "memoria ${raw%%|*} · cpu ${raw#*|}"
      errs="$(docker logs --since 10m "${ST_CNAME[$name/$svc]}" 2>&1 | grep -acE 'ERROR|ECONNREFUSED|Unable to connect' || true)"
      ui_kv "errores 10m" "${errs:-0} línea(s) con ERROR/ECONNREFUSED en los logs (./itc logs $name $svc)"
    fi
    [ -z "$E_NOTES" ] || ui_kv "notas" "$E_NOTES"
  done
}

status_footer() {
  local h cmd why
  printf '\n'
  if [ "$STATUS_ISSUES" -eq 0 ]; then
    printf '  %s %s%d instancia(s) · %d servicio(s) · todo en orden%s\n' "$(ui_sym ok)" "$C_GRN" \
      "$STATUS_INSTANCES" "$STATUS_SERVICES" "$C_OFF"
  else
    printf '  %s %s%d instancia(s) · %d servicio(s) · %d con avisos%s\n' "$(ui_sym warn)" "$C_YEL" \
      "$STATUS_INSTANCES" "$STATUS_SERVICES" "$STATUS_ISSUES" "$C_OFF"
  fi
  if [ "${#HINTS[@]}" -gt 0 ]; then
    printf '\n  %sSiguientes pasos sugeridos%s\n' "$C_BLD" "$C_OFF"
    for h in "${HINTS[@]}"; do
      cmd="${h%%|*}"
      why="${h#*|}"
      printf '  %s%s%s %s%s%s  %s# %s%s\n' "$C_CYN" "$UI_S_ARROW" "$C_OFF" "$C_GRN" "$cmd" "$C_OFF" "$C_GRY" "$why" "$C_OFF"
    done
  fi
}

status_once() { # instancia
  local name="${1:-}"
  HINTS=() HINT_SEEN=() STATUS_ISSUES=0 STATUS_SERVICES=0 STATUS_INSTANCES=0
  st_collect
  st_load_ports
  [ "$ST_DOCKER" -eq 1 ] || warn "docker no está disponible: se muestra solo la configuración"
  if [ "$STATUS_STATS" -eq 1 ] || { [ -n "$name" ] && [ "$STATUS_FORMAT" != "json" ]; }; then st_collect_stats; fi
  if [ "$STATUS_FORMAT" = "json" ]; then
    status_json "$name"
    return 0
  fi
  if [ -n "$name" ]; then
    status_detail "$name"
  else
    ui_h1 "Estado de las instancias"
    status_table
  fi
  status_footer
}

cmd_status() {
  local name="" a interval=2
  STATUS_FORMAT=table STATUS_STATS=0
  local strict=0 watch=0
  while [ "$#" -gt 0 ]; do
    a="$1"
    case "$a" in
      --json) STATUS_FORMAT=json ;;
      --stats) STATUS_STATS=1 ;;
      --strict) strict=1 ;;
      --watch)
        watch=1
        if [ "$#" -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]]; then interval="$2"; shift; fi
        ;;
      -*) die "opción desconocida: $a (ver ./itc help status)" ;;
      *)
        [ -z "$name" ] || die "sobra el argumento '$a'"
        name="$a"
        ;;
    esac
    shift
  done
  if [ -n "$name" ]; then require_instance "$name"; fi

  if [ "$watch" -eq 1 ]; then
    [ "$UI_RICH" -eq 1 ] && [ "$STATUS_FORMAT" != "json" ] || die "--watch necesita una terminal y no se combina con --json"
    trap 'printf "\n"; exit 0' INT
    while true; do
      printf '\033[H\033[2J'
      ui_banner "Estado en vivo · cada ${interval}s · Ctrl+C para salir"
      status_once "$name"
      sleep "$interval"
    done
  fi

  status_once "$name"
  if [ "$strict" -eq 1 ] && [ "$STATUS_ISSUES" -gt 0 ]; then return 2; fi
  return 0
}

# Pantalla de inicio: ./itc sin argumentos en una terminal.
cmd_home() {
  ui_banner
  STATUS_FORMAT=table STATUS_STATS=0
  status_once ""
  printf '\n  %sAyuda:%s ./itc help   %sMenú:%s ./itc menu   %sGuía:%s ./itc help nueva-instancia\n\n' \
    "$C_GRY" "$C_OFF" "$C_GRY" "$C_OFF" "$C_GRY" "$C_OFF"
}

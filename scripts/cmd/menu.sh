#!/usr/bin/env bash
# ./itc menu: menú interactivo con numeración. Cada opción pregunta lo necesario (instancia, servicio...),
# muestra el comando equivalente y lo ejecuta con ./itc: el menú no hace nada que la línea de comandos no haga.
# Las operaciones destructivas piden confirmación aquí (init exige escribir el nombre de la instancia).
# Con "?" delante de un número (por ejemplo "?4") muestra la ayuda de esa opción.

# new_ask, new_ask_yn y new_loaded_tags vienen de new.sh; st_enabled de status.sh
source "$ROOT/scripts/cmd/new.sh"
source "$ROOT/scripts/cmd/status.sh"

PICK=""

# Páginas de ayuda de cada opción del menú.
declare -A MENU_HELP=([1]=status [2]=new [3]=check [4]=deploy [5]=actualizar [6]=rollback [7]=init
  [8]=logs [9]=stop [10]=down [11]=images [12]=load [13]=doctor [14]=help)

menu_show() {
  local k label desc
  ui_h1 "Menú"
  while IFS='|' read -r k label desc; do
    printf '  %s%3s)%s %-34s %s%s%s\n' "$C_BLD$C_CYN" "$k" "$C_OFF" "$label" "$C_GRY" "$desc" "$C_OFF"
  done <<'EOF'
1|Ver estado|versiones, salud y desajustes
2|Crear una instancia|asistente paso a paso
3|Comprobar una instancia|todo lo que deploy exigiría, sin levantar nada
4|Desplegar|levantar una instancia o un servicio
5|Actualizar a una versión nueva|cambia la etiqueta y despliega
6|Volver a la versión anterior|rollback
7|Sembrar datos iniciales|solo municipalidades NUEVAS (destructivo)
8|Ver logs|de una instancia o un servicio
9|Detener un servicio|sin tocar los demás
10|Bajar una instancia|elimina los contenedores, conserva los datos
11|Versiones de imágenes|qué hay cargado y quién lo usa
12|Cargar imágenes|desde un archivo .tar o .tar.gz
13|Diagnóstico del servidor|Docker, disco, memoria, Mongo
14|Ayuda|índice de comandos y guías
0|Salir|
EOF
}

# Elige una instancia (por número o nombre). Resultado en PICK; con "all" admite "0 = todas" (PICK vacío).
menu_pick_instance() { # [all]
  local -a names=()
  local f n i ans
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] && names+=("$(basename "$(dirname "$f")")")
  done
  if [ "${#names[@]}" -eq 0 ]; then
    warn "no hay instancias todavía: crea una con la opción 2"
    return 1
  fi
  printf '\n  %sInstancia%s\n' "$C_BLD" "$C_OFF"
  i=0
  for n in "${names[@]}"; do
    i=$((i + 1))
    printf '    %s%d)%s %s %s(%s)%s\n' "$C_CYN" "$i" "$C_OFF" "$n" "$C_GRY" "$(get_var "$INSTANCES_DIR/$n/.env.instance" COMPOSE_PROFILES)" "$C_OFF"
  done
  [ "${1:-}" != "all" ] || printf '    %s0)%s todas\n' "$C_CYN" "$C_OFF"
  new_ask "Número o nombre"
  ans="$REPLY_VAL"
  if [ "${1:-}" = "all" ] && [ "$ans" = "0" ]; then PICK=""; return 0; fi
  if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "${#names[@]}" ]; then
    PICK="${names[$((ans - 1))]}"
    return 0
  fi
  for n in "${names[@]}"; do [ "$n" != "$ans" ] || { PICK="$n"; return 0; }; done
  warn "instancia no válida: '$ans'"
  return 1
}

# Elige un servicio activo de la instancia. Resultado en PICK; con "all" admite "0 = todos" (PICK vacío).
menu_pick_service() { # instancia [all]
  local inst="$1" i ans s
  st_enabled "$inst"
  if [ "${#ST_ENABLED[@]}" -eq 0 ]; then
    warn "'$inst' no tiene servicios válidos en COMPOSE_PROFILES"
    return 1
  fi
  printf '\n  %sServicio%s\n' "$C_BLD" "$C_OFF"
  i=0
  for s in "${ST_ENABLED[@]}"; do
    i=$((i + 1))
    printf '    %s%d)%s %s %s(%s)%s\n' "$C_CYN" "$i" "$C_OFF" "$s" "$C_GRY" "$(service_repo "$s" "$inst")" "$C_OFF"
  done
  [ "${2:-}" != "all" ] || printf '    %s0)%s todos\n' "$C_CYN" "$C_OFF"
  new_ask "Número o nombre"
  ans="$REPLY_VAL"
  if [ "${2:-}" = "all" ] && [ "$ans" = "0" ]; then PICK=""; return 0; fi
  if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "${#ST_ENABLED[@]}" ]; then
    PICK="${ST_ENABLED[$((ans - 1))]}"
    return 0
  fi
  for s in "${ST_ENABLED[@]}"; do [ "$s" != "$ans" ] || { PICK="$s"; return 0; }; done
  warn "servicio no válido: '$ans'"
  return 1
}

menu_pause() {
  [ -t 0 ] || return 0
  printf '\n  %sEnter para volver al menú...%s' "$C_GRY" "$C_OFF" >&2
  IFS= read -r _ || true
}

# Ejecuta ./itc con los argumentos, mostrando el comando equivalente. Devuelve su código de salida.
menu_exec() {
  local rc=0
  printf '\n  %s%s ./itc %s%s\n\n' "$C_GRY" "$UI_S_ARROW" "$*" "$C_OFF"
  "$ROOT/itc" "$@" || rc=$?
  [ "$rc" -eq 0 ] || printf '\n  %s El comando terminó con errores (código %d)\n' "$(ui_sym err)" "$rc"
  return "$rc"
}

menu_run() { menu_exec "$@" || true; menu_pause; }

menu_status() { menu_pick_instance all || return 0; menu_run status ${PICK:+"$PICK"}; }
menu_new() { menu_run new --wizard; }

menu_check() {
  menu_pick_instance || return 0
  local inst="$PICK"
  if new_ask_yn "¿Probar también la conexión a las bases de datos? (tarda unos segundos)" n; then
    menu_run check "$inst" --mongo
  else
    menu_run check "$inst"
  fi
}

menu_deploy() {
  menu_pick_instance || return 0
  local inst="$PICK"
  menu_pick_service "$inst" all || return 0
  menu_run deploy "$inst" ${PICK:+"$PICK"}
}

# Cambia la etiqueta de un servicio, comprueba y despliega solo ese servicio.
menu_update() {
  local inst svc repo cur tag tags f
  menu_pick_instance || return 0
  inst="$PICK"
  menu_pick_service "$inst" || return 0
  svc="$PICK"
  f="$(instance_dir "$inst")/.env.instance"
  repo="$(service_repo "$svc" "$inst")"
  cur="$(get_var "$f" "$(tag_var "$svc")")"
  tags="$(new_loaded_tags "$repo" | tr '\n' ' ')"
  printf '\n  %s: etiqueta actual %s%s%s\n' "$svc" "$C_BLD" "${cur:-(vacía)}" "$C_OFF"
  [ -z "$tags" ] || printf '  %sCargadas de %s: %s%s\n' "$C_GRY" "$repo" "$tags" "$C_OFF"
  new_ask "Nueva etiqueta de $svc"
  tag="$REPLY_VAL"
  if [ -z "$tag" ]; then info "  cancelado"; return 0; fi
  if [ "$tag" = "$cur" ]; then info "  ya está en esa etiqueta"; return 0; fi
  if [ -n "$tags" ] && [[ " $tags " != *" $tag "* ]]; then
    warn "la etiqueta '$tag' no está entre las cargadas (¿falta ./itc load?)"
    new_ask_yn "¿Continuar de todos modos?" n || return 0
  fi
  new_ask_yn "Se cambiará $(tag_var "$svc") de '${cur:-vacía}' a '$tag' en .env.instance y se desplegará solo $svc. ¿Continuar?" s || return 0
  set_var "$f" "$(tag_var "$svc")" "$tag"
  if ! menu_exec check "$inst" "$svc"; then
    warn "la comprobación falló: no se desplegó"
    if new_ask_yn "¿Volver a la etiqueta anterior (${cur:-vacía})?" s; then
      set_var "$f" "$(tag_var "$svc")" "$cur"
      info "  etiqueta restaurada"
    fi
    menu_pause
    return 0
  fi
  menu_run deploy "$inst" "$svc"
}

menu_rollback() {
  menu_pick_instance || return 0
  local inst="$PICK"
  menu_pick_service "$inst" all || return 0
  local svc="$PICK"
  new_ask_yn "Vuelve a la versión anterior de ${svc:-todos los servicios} de '$inst'. ¿Continuar?" n || return 0
  menu_run rollback "$inst" ${svc:+"$svc"} --yes
}

menu_init() {
  menu_pick_instance || return 0
  local inst="$PICK"
  printf '\n  %s Los seeds BORRAN datos (drop de colecciones). Solo para municipalidades NUEVAS, una vez.\n' "$(ui_sym warn)"
  new_ask "Para confirmar, escribe el nombre de la instancia ($inst)"
  if [ "$REPLY_VAL" != "$inst" ]; then info "  cancelado"; return 0; fi
  menu_run init "$inst" --yes
}

menu_logs() {
  menu_pick_instance || return 0
  local inst="$PICK"
  menu_pick_service "$inst" all || return 0
  local svc="$PICK"
  if new_ask_yn "¿Seguir en vivo? (Ctrl+C para volver)" n; then
    menu_exec logs "$inst" ${svc:+"$svc"} -f || true
  else
    menu_run logs "$inst" ${svc:+"$svc"}
  fi
}

menu_stop() {
  menu_pick_instance || return 0
  local inst="$PICK"
  menu_pick_service "$inst" || return 0
  menu_run stop "$inst" "$PICK"
}

menu_down() {
  menu_pick_instance || return 0
  local inst="$PICK"
  new_ask_yn "Detiene y elimina los contenedores de '$inst' (los datos se conservan). ¿Continuar?" n || return 0
  menu_run down "$inst" --yes
}

menu_images() { menu_run images; }

menu_load() {
  new_ask "Ruta del archivo .tar o .tar.gz"
  if [ -z "$REPLY_VAL" ]; then info "  cancelado"; return 0; fi
  menu_run load "$REPLY_VAL"
}

menu_doctor() { menu_run doctor; }

menu_help() {
  new_ask "Tema o comando (Enter = índice)"
  if [ -n "$REPLY_VAL" ]; then menu_run help "$REPLY_VAL"; else menu_run help; fi
}

menu_dispatch() { # opción
  case "$1" in
    1) menu_status ;;
    2) menu_new ;;
    3) menu_check ;;
    4) menu_deploy ;;
    5) menu_update ;;
    6) menu_rollback ;;
    7) menu_init ;;
    8) menu_logs ;;
    9) menu_stop ;;
    10) menu_down ;;
    11) menu_images ;;
    12) menu_load ;;
    13) menu_doctor ;;
    14) menu_help ;;
    *) warn "opción no válida: '$1' (elige un número del menú o 0 para salir)" ;;
  esac
}

cmd_menu() {
  [ "$#" -eq 0 ] || die "menu no recibe argumentos (ver ./itc help menu)"
  local choice help_page
  ui_banner
  while true; do
    menu_show
    printf '\n  Elige una opción (con ? delante, ayuda: ?4): ' >&2
    IFS= read -r choice || { printf '\n'; break; }
    choice="${choice// /}"
    case "$choice" in
      0 | q | Q) break ;;
      "") continue ;;
      \?*)
        help_page=""
        [[ "${choice#\?}" =~ ^[0-9]+$ ]] && help_page="${MENU_HELP[${choice#\?}]:-}"
        if [ -n "$help_page" ]; then menu_run help "$help_page"; else warn "no hay ayuda para '${choice#\?}'"; fi
        ;;
      *) menu_dispatch "$choice" ;;
    esac
  done
}

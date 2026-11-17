#!/usr/bin/env bash
# ./deltactl menu: interactive numbered menu. Every option asks what it needs (instance, service...),
# shows the equivalent command and runs it with ./deltactl: the menu does nothing the command line does not do.
# Destructive operations ask for confirmation here (init requires typing the instance name).
# With "?" before a number (for example "?4") it shows the help of that option.

# new_ask, new_ask_yn and new_loaded_tags come from new.sh; st_enabled from status.sh
source "$ROOT/lib/cmd/new.sh"
source "$ROOT/lib/cmd/status.sh"

PICK=""

# Help page of each menu option (English guide ids are accepted: update = the guide about updating).
declare -A MENU_HELP=([1]=status [2]=new [3]=check [4]=deploy [5]=update [6]=rollback [7]=init
  [8]=logs [9]=stop [10]=down [11]=images [12]=load [13]=doctor [14]=help)

menu_show() {
  local k
  ui_h1 "$(t menu.title)"
  for k in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 0; do
    printf '  %s%3s)%s %-34s %s%s%s\n' "$C_BLD$C_CYN" "$k" "$C_OFF" "$(t "menu.opt.$k.label")" "$C_GRY" "$(t "menu.opt.$k.desc")" "$C_OFF"
  done
}

# Picks an instance (by number or name). The result is in PICK; with "all" it accepts "0 = all" (empty PICK).
menu_pick_instance() { # [all]
  local -a names=()
  local f n i ans
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] && names+=("$(basename "$(dirname "$f")")")
  done
  if [ "${#names[@]}" -eq 0 ]; then
    warn "$(t menu.no_instances)"
    return 1
  fi
  printf '\n  %s%s%s\n' "$C_BLD" "$(t menu.instance)" "$C_OFF"
  i=0
  for n in "${names[@]}"; do
    i=$((i + 1))
    printf '    %s%d)%s %s %s(%s)%s\n' "$C_CYN" "$i" "$C_OFF" "$n" "$C_GRY" "$(get_var "$INSTANCES_DIR/$n/.env.instance" COMPOSE_PROFILES)" "$C_OFF"
  done
  [ "${1:-}" != "all" ] || printf '    %s0)%s %s\n' "$C_CYN" "$C_OFF" "$(t menu.all_instances)"
  new_ask "$(t menu.ask_pick)"
  ans="$REPLY_VAL"
  if [ "${1:-}" = "all" ] && [ "$ans" = "0" ]; then PICK=""; return 0; fi
  if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "${#names[@]}" ]; then
    PICK="${names[$((ans - 1))]}"
    return 0
  fi
  for n in "${names[@]}"; do [ "$n" != "$ans" ] || { PICK="$n"; return 0; }; done
  warn "$(t menu.bad_instance "$ans")"
  return 1
}

# Picks an active service of the instance. The result is in PICK; with "all" it accepts "0 = all" (empty PICK).
menu_pick_service() { # instance [all]
  local inst="$1" i ans s
  st_enabled "$inst"
  if [ "${#ST_ENABLED[@]}" -eq 0 ]; then
    warn "$(t menu.no_services "$inst")"
    return 1
  fi
  printf '\n  %s%s%s\n' "$C_BLD" "$(t menu.service)" "$C_OFF"
  i=0
  for s in "${ST_ENABLED[@]}"; do
    i=$((i + 1))
    printf '    %s%d)%s %s %s(%s)%s\n' "$C_CYN" "$i" "$C_OFF" "$s" "$C_GRY" "$(service_repo "$s" "$inst")" "$C_OFF"
  done
  [ "${2:-}" != "all" ] || printf '    %s0)%s %s\n' "$C_CYN" "$C_OFF" "$(t menu.all_services)"
  new_ask "$(t menu.ask_pick)"
  ans="$REPLY_VAL"
  if [ "${2:-}" = "all" ] && [ "$ans" = "0" ]; then PICK=""; return 0; fi
  if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "${#ST_ENABLED[@]}" ]; then
    PICK="${ST_ENABLED[$((ans - 1))]}"
    return 0
  fi
  for s in "${ST_ENABLED[@]}"; do [ "$s" != "$ans" ] || { PICK="$s"; return 0; }; done
  warn "$(t menu.bad_service "$ans")"
  return 1
}

menu_pause() {
  [ -t 0 ] || return 0
  printf '\n  %s%s%s' "$C_GRY" "$(t menu.pause)" "$C_OFF" >&2
  IFS= read -r _ || true
}

# Runs ./deltactl with the arguments, showing the equivalent command. Returns its exit code.
menu_exec() {
  local rc=0
  printf '\n  %s%s ./deltactl %s%s\n\n' "$C_GRY" "$UI_S_ARROW" "$*" "$C_OFF"
  "$ROOT/deltactl" "$@" || rc=$?
  [ "$rc" -eq 0 ] || printf '\n  %s %s\n' "$(ui_sym err)" "$(t menu.cmd_failed "$rc")"
  return "$rc"
}

menu_run() { menu_exec "$@" || true; menu_pause; }

menu_status() { menu_pick_instance all || return 0; menu_run status ${PICK:+"$PICK"}; }
menu_new() { menu_run new --wizard; }

menu_check() {
  menu_pick_instance || return 0
  local inst="$PICK"
  if new_ask_yn "$(t menu.ask_mongo)" n; then
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

# Changes the tag of a service, checks and deploys only that service.
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
  printf '\n  %s %s%s%s\n' "$(t menu.current_tag "$svc")" "$C_BLD" "${cur:-$(t menu.empty_paren)}" "$C_OFF"
  [ -z "$tags" ] || printf '  %s%s%s\n' "$C_GRY" "$(t menu.loaded_of "$repo" "$tags")" "$C_OFF"
  new_ask "$(t menu.ask_new_tag "$svc")"
  tag="$REPLY_VAL"
  if [ -z "$tag" ]; then info "$(t menu.cancelled)"; return 0; fi
  if [ "$tag" = "$cur" ]; then info "$(t menu.same_tag)"; return 0; fi
  if [ -n "$tags" ] && [[ " $tags " != *" $tag "* ]]; then
    warn "$(t menu.tag_not_loaded "$tag")"
    new_ask_yn "$(t menu.ask_anyway)" n || return 0
  fi
  new_ask_yn "$(t menu.confirm_update "$(tag_var "$svc")" "${cur:-$(t menu.empty_word)}" "$tag" "$svc")" y || return 0
  set_var "$f" "$(tag_var "$svc")" "$tag"
  if ! menu_exec check "$inst" "$svc"; then
    warn "$(t menu.check_failed)"
    if new_ask_yn "$(t menu.ask_restore "${cur:-$(t menu.empty_word)}")" y; then
      set_var "$f" "$(tag_var "$svc")" "$cur"
      info "$(t menu.tag_restored)"
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
  new_ask_yn "$(t menu.confirm_rollback "${svc:-$(t menu.all_the_services)}" "$inst")" n || return 0
  menu_run rollback "$inst" ${svc:+"$svc"} --yes
}

menu_init() {
  menu_pick_instance || return 0
  local inst="$PICK"
  printf '\n  %s %s\n' "$(ui_sym warn)" "$(t menu.init_warning)"
  new_ask "$(t menu.ask_confirm_name "$inst")"
  if [ "$REPLY_VAL" != "$inst" ]; then info "$(t menu.cancelled)"; return 0; fi
  menu_run init "$inst" --yes
}

menu_logs() {
  menu_pick_instance || return 0
  local inst="$PICK"
  menu_pick_service "$inst" all || return 0
  local svc="$PICK"
  if new_ask_yn "$(t menu.ask_follow)" n; then
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
  new_ask_yn "$(t menu.confirm_down "$inst")" n || return 0
  menu_run down "$inst" --yes
}

menu_images() { menu_run images; }

menu_load() {
  new_ask "$(t menu.ask_file)"
  if [ -z "$REPLY_VAL" ]; then info "$(t menu.cancelled)"; return 0; fi
  menu_run load "$REPLY_VAL"
}

menu_doctor() { menu_run doctor; }

menu_help() {
  new_ask "$(t menu.ask_help)"
  if [ -n "$REPLY_VAL" ]; then menu_run help "$REPLY_VAL"; else menu_run help; fi
}

menu_dispatch() { # option
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
    *) warn "$(t menu.bad_option "$1")" ;;
  esac
}

cmd_menu() {
  [ "$#" -eq 0 ] || die "$(t menu.args)"
  local choice help_page
  ui_banner
  while true; do
    menu_show
    printf '\n  %s ' "$(t menu.prompt)" >&2
    IFS= read -r choice || { printf '\n'; break; }
    choice="${choice// /}"
    case "$choice" in
      0 | q | Q) break ;;
      "") continue ;;
      \?*)
        help_page=""
        [[ "${choice#\?}" =~ ^[0-9]+$ ]] && help_page="${MENU_HELP[${choice#\?}]:-}"
        if [ -n "$help_page" ]; then menu_run help "$help_page"; else warn "$(t help.no_page "${choice#\?}")"; fi
        ;;
      *) menu_dispatch "$choice" ;;
    esac
  done
}

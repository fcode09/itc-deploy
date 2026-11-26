#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Mode: the actions menu of an instance or service (Enter on an instance).

dash_open_actions() { # instance
  local inst="$1" svc id
  local -a svcs
  read -ra svcs <<< "${DASH_SVCS[$inst]:-}"
  if [ "${#svcs[@]}" -eq 0 ]; then dash_msg warn "$(t tui.msg.no_service)"; return 0; fi
  svc="${svcs[$DASH_SVC]:-${svcs[0]}}"
  DASH_MENU_INST="$inst" DASH_MENU_SVC="$svc"
  DASH_MENU_IDS=(status check deploy_all deploy_svc rollback logs_live logs_recent stop_svc down)
  [ "${DASH_DATA[$inst]:-}" != "unseeded" ] || DASH_MENU_IDS+=(init)
  # The access: the block goes to nginx only when the instance already remembers a domain and this server has nginx (the tab asks for them
  # otherwise); editing names, domain, proxy and HTTPS, and the variables, is the tab's.
  proxy_meta_load "$inst"
  if [ -n "$PROXY_M_DOMAIN" ] && command -v nginx > /dev/null 2>&1; then DASH_MENU_IDS+=(access_all access_svc access_off); fi
  DASH_MENU_IDS+=(edit_access edit_vars)
  DASH_MENU_IDS+=(help)
  DASH_MENU_ITEMS=()
  for id in "${DASH_MENU_IDS[@]}"; do DASH_MENU_ITEMS+=("$(t "tui.act.$id" "$svc")"); done
  DASH_MENU_TITLE="$(t tui.actions_title "$inst" "${DASH_NM[$inst]:-}")"
  DASH_MENU_SEL=0
  DASH_MODE=menu
}

dash_menu_run() {
  local id="${DASH_MENU_IDS[$DASH_MENU_SEL]}" inst="$DASH_MENU_INST" svc="$DASH_MENU_SVC"
  DASH_MODE=normal
  case "$id" in
    status) dash_start_job output status "$inst" ;;
    check) dash_start_job stay check "$inst" ;;
    deploy_all) dash_start_job stay deploy "$inst" ;;
    deploy_svc) dash_start_job stay deploy "$inst" "$svc" ;;
    rollback) dash_confirm "$(t menu.confirm_rollback "$(t menu.all_the_services)" "$inst")" stay rollback "$inst" --yes ;;
    logs_live) dash_start_job output logs "$inst" "$svc" -f ;;
    logs_recent) dash_start_job output logs "$inst" "$svc" ;;
    stop_svc) dash_confirm "$(t tui.confirm_stop "$svc" "$inst")" stay stop "$inst" "$svc" ;;
    down) dash_confirm "$(t menu.confirm_down "$inst")" stay down "$inst" --yes ;;
    init) DASH_NAME_TARGET="$inst" DASH_BUF="" DASH_CUR=0 DASH_MODE=name ;;
    access_all) dash_confirm "$(t menu.confirm_access "$inst" "$(t menu.all_the_services)")" stay access "$inst" --apply --yes ;;
    access_svc) dash_confirm "$(t menu.confirm_access "$inst" "$svc")" stay access "$inst" --apply --yes --service "$svc" ;;
    access_off) dash_confirm "$(t menu.confirm_access_off "$inst")" stay access "$inst" --remove --yes ;;
    edit_access) dash_ws_tab_go acceso ;;
    edit_vars) dash_ws_tab_go variables ;;
    help) dash_start_job output help status ;;
  esac
}

dash_key_menu() {
  local n="${#DASH_MENU_ITEMS[@]}"
  case "$1" in
    up | k) DASH_MENU_SEL=$(((DASH_MENU_SEL + n - 1) % n)) ;;
    down | j) DASH_MENU_SEL=$(((DASH_MENU_SEL + 1) % n)) ;;
    enter | right) dash_menu_run ;;
    esc | left | q | backspace) DASH_MODE=normal ;;
  esac
}

dash_dialog_menu() { # body_height
  local i
  DASH_DLG=("")
  for i in "${!DASH_MENU_ITEMS[@]}"; do
    if [ "$i" -eq "$DASH_MENU_SEL" ]; then
      DASH_DLG+=("$TUI_SEL$C_CYN$UI_S_SEL$C_OFF $C_BLD${DASH_MENU_ITEMS[$i]}$C_OFF")
    else
      DASH_DLG+=("   ${DASH_MENU_ITEMS[$i]}")
    fi
  done
  DASH_DLG+=("")
  dash_dialog "$1" "$DASH_MENU_TITLE" 50
}

# --- The contract of lib/screens/registry.sh --------------------------------------------------------------------
scr_menu_render() { dash_dialog_menu "$2"; } # width height
scr_menu_key() { dash_key_menu "$1"; }
scr_menu_keys() { # width
  dt tui.dialog.keys; dash_keyfit "${DTV//\{1\}/$DASH_UD}" "$1"; TUI_FRAME+=(" $C_GRY$DASH_KF$C_OFF")
}
scr_menu_sig() { DASH_SIG+="|$DASH_MENU_SEL"; }

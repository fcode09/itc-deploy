#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Mode: the actions menu of an instance or service (Enter on an instance).
#
# It is a list in sections, so what acts on the whole instance is not mixed with what acts on one service, and what is destructive is not next to
# what is harmless:
#   VER                 the state, the check
#   TODA LA INSTANCIA   deploy everything, go back to the previous version
#   SERVICIO <s>        deploy only it, its logs, stop it         (left / right choose the service without leaving the menu)
#   NGINX               put the blocks of the instance in nginx, take them out (the title says what state the block of the service is in)
#   CONFIGURAR          the names and the access, the variables (they open the tabs of the instance)
#   PELIGRO             take the whole instance down
# The titles are not selectable. Every action has a letter that does it from anywhere in the list; the ones that stop or remove something are drawn
# in the colour of the warnings, with the mark, and still ask first. A list taller than the screen scrolls with the cursor.
#
#   DASH_MENU_IDS   the actions, in order (what the selection points at; the palette runs one by putting its id here)
#   DASH_MENU_ROWS  what is drawn: "h|<title>|<note>" for a title, "i|<id>|<label>|<key>|<danger 0|1>|<dim 0|1>" for an action

DASH_MENU_ROWS=()

# The letter of each action. j k h g G are not used: with the vim keys off (Options) the panel drops them before they reach a menu.
dash_menu_key_of() { # id -> DASH_MENU_K
  case "$1" in
    status) DASH_MENU_K=e ;;
    check) DASH_MENU_K=c ;;
    help) DASH_MENU_K='?' ;;
    deploy_all) DASH_MENU_K=d ;;
    rollback) DASH_MENU_K=r ;;
    deploy_svc) DASH_MENU_K=u ;;
    logs_live) DASH_MENU_K=l ;;
    logs_recent) DASH_MENU_K=L ;;
    stop_svc) DASH_MENU_K=x ;;
    access_all) DASH_MENU_K=a ;;
    access_svc) DASH_MENU_K=A ;;
    access_off) DASH_MENU_K=n ;;
    edit_access) DASH_MENU_K=o ;;
    edit_vars) DASH_MENU_K=v ;;
    init) DASH_MENU_K=i ;;
    down) DASH_MENU_K=b ;;
    *) DASH_MENU_K="" ;;
  esac
}

# Adds a title / an action to the list being built.
dash_menu_h() { DASH_MENU_ROWS+=("h|$1|${2:-}"); } # title [note]
dash_menu_i() { # id [danger] [dim]
  local id="$1" danger="${2:-0}" dim="${3:-0}"
  dash_menu_key_of "$id"
  DASH_MENU_IDS+=("$id")
  DASH_MENU_ROWS+=("i|$id|$(t "tui.menu.act.$id" "$DASH_MENU_SVC")|$DASH_MENU_K|$danger|$dim")
}

# Builds the list for DASH_MENU_INST and DASH_MENU_SVC.
dash_menu_build() {
  local inst="$DASH_MENU_INST" svc="$DASH_MENU_SVC" st="" off_dim=0
  DASH_MENU_IDS=() DASH_MENU_ROWS=()
  dash_menu_h "$(t tui.menu.sec.view)"
  dash_menu_i status
  dash_menu_i check
  dash_menu_i help
  dash_menu_h "$(t tui.menu.sec.instance)"
  dash_menu_i deploy_all
  dash_menu_i rollback 1
  [ "${DASH_DATA[$inst]:-}" != "unseeded" ] || dash_menu_i init
  dash_menu_h "$(t tui.menu.sec.service "$svc")" "$(t tui.menu.sec.service_note)"
  dash_menu_i deploy_svc
  dash_menu_i logs_live
  dash_menu_i logs_recent
  dash_menu_i stop_svc 1
  # nginx: the block goes there only when the instance already remembers a domain and this server has nginx (the tab asks for them otherwise)
  if command -v nginx > /dev/null 2>&1; then
    proxy_meta_load "$inst"
    st="${DASH_ACC_NG[$inst/$svc]:-}"
    if [ -n "$PROXY_M_DOMAIN" ]; then
      if [ -n "$st" ]; then dash_menu_h "$(t tui.menu.sec.nginx_state "$svc" "$(t "tui.acc.ng.$st")")"; else dash_menu_h "$(t tui.menu.sec.nginx)"; fi
      case "$st" in none | disabled) off_dim=1 ;; esac
      dash_menu_i access_all
      dash_menu_i access_svc
      dash_menu_i access_off 1 "$off_dim"
    else
      dash_menu_h "$(t tui.menu.sec.nginx)" "$(t tui.menu.nginx_nodomain)"
    fi
  fi
  dash_menu_h "$(t tui.menu.sec.config)"
  dash_menu_i edit_access
  dash_menu_i edit_vars
  dash_menu_h "$(t tui.menu.sec.danger)"
  dash_menu_i down 1
}

dash_open_actions() { # instance
  local inst="$1"
  local -a svcs
  read -ra svcs <<< "${DASH_SVCS[$inst]:-}"
  if [ "${#svcs[@]}" -eq 0 ]; then dash_msg warn "$(t tui.msg.no_service)"; return 0; fi
  DASH_MENU_INST="$inst" DASH_MENU_SVC="${svcs[$DASH_SVC]:-${svcs[0]}}"
  dash_menu_build
  DASH_MENU_TITLE="$(t tui.actions_title "$inst" "${DASH_NM[$inst]:-}")"
  DASH_MENU_SEL=0
  DASH_MODE=menu
}

# left / right: another service of the instance, without leaving the menu. The action under the cursor stays under it (by its id).
dash_menu_service() { # step (1|-1)
  local inst="$DASH_MENU_INST" i cur=0 n id="${DASH_MENU_IDS[$DASH_MENU_SEL]:-}"
  local -a svcs
  read -ra svcs <<< "${DASH_SVCS[$inst]:-}"
  n="${#svcs[@]}"
  [ "$n" -gt 1 ] || return 0
  for i in "${!svcs[@]}"; do [ "${svcs[$i]}" != "$DASH_MENU_SVC" ] || cur="$i"; done
  DASH_MENU_SVC="${svcs[$(((cur + n + $1) % n))]}"
  dash_menu_build
  DASH_MENU_SEL=0
  for i in "${!DASH_MENU_IDS[@]}"; do [ "${DASH_MENU_IDS[$i]}" != "$id" ] || DASH_MENU_SEL="$i"; done
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
    access_all) dash_acc_install apply all ;;
    access_svc) dash_acc_install apply one ;;
    access_off) dash_acc_install remove all ;;
    edit_access) dash_ws_tab_go acceso ;;
    edit_vars) dash_ws_tab_go variables ;;
    help) dash_start_job output help status ;;
  esac
}

dash_key_menu() {
  local n="${#DASH_MENU_IDS[@]}" i k
  [ "$n" -gt 0 ] || { DASH_MODE=normal; return 0; }
  case "$1" in
    up | k) DASH_MENU_SEL=$(((DASH_MENU_SEL + n - 1) % n)) ;;
    down | j) DASH_MENU_SEL=$(((DASH_MENU_SEL + 1) % n)) ;;
    left) dash_menu_service -1 ;;
    right) dash_menu_service 1 ;;
    enter) dash_menu_run ;;
    esc | q | backspace) DASH_MODE=normal ;;
    *)
      # the letter of an action does it, wherever the cursor is
      for i in "${!DASH_MENU_IDS[@]}"; do
        dash_menu_key_of "${DASH_MENU_IDS[$i]}"
        k="$DASH_MENU_K"
        if [ -n "$k" ] && [ "$k" = "$1" ]; then DASH_MENU_SEL="$i"; dash_menu_run; return 0; fi
      done
      ;;
  esac
}

# The box: a blank line, the part of the list that fits (the cursor always in it, with the title of its group when it fits), and the keys.
dash_dialog_menu() { # body_height
  local bh="$1" i r kind a b c d e lw=0 sel_row=0 ai=0 maxrows ws start end total up=0 dn=0 scrolling=0 line pad mark kcol lab
  local -a lines=() isel=()
  # the width of the labels, to put the letters in one column
  for r in "${DASH_MENU_ROWS[@]}"; do
    IFS='|' read -r kind a b c d e <<< "$r"
    [ "$kind" = i ] || continue
    [ "${#b}" -le "$lw" ] || lw="${#b}"
  done
  for r in "${DASH_MENU_ROWS[@]}"; do
    IFS='|' read -r kind a b c d e <<< "$r"
    if [ "$kind" = h ]; then
      line=" ${TH[dim]:-$C_GRY}$C_BLD$a$C_OFF"
      [ -z "$b" ] || line+="  ${TH[dim]:-$C_GRY}$b$C_OFF"
      lines+=("$line")
      isel+=(0)
      continue
    fi
    # a = id, b = label, c = key, d = danger, e = dim
    lab="$b"
    printf -v pad '%*s' $((lw - ${#lab})) ''
    mark="  "
    [ "$d" != 1 ] || kcol="${TH[warn]:-$C_YEL}$UI_S_WARN$C_OFF"
    [ "$d" = 1 ] || kcol=" "
    if [ "$ai" -eq "$DASH_MENU_SEL" ]; then
      line="$TUI_SEL${TH[accent]:-$C_CYN}$UI_S_SEL$C_OFF $C_BLD$lab$C_OFF$pad $kcol ${TH[dim]:-$C_GRY}$c$C_OFF"
      sel_row="${#lines[@]}"
    elif [ "$e" = 1 ]; then
      line="$mark${TH[dim]:-$C_GRY}$lab$C_OFF$pad $kcol ${TH[dim]:-$C_GRY}$c$C_OFF"
    elif [ "$d" = 1 ]; then
      line="$mark${TH[warn]:-$C_YEL}$lab$C_OFF$pad $kcol ${TH[dim]:-$C_GRY}$c$C_OFF"
    else
      line="$mark$lab$pad $kcol ${TH[dim]:-$C_GRY}$c$C_OFF"
    fi
    lines+=(" $line")
    isel+=(1)
    ai=$((ai + 1))
  done
  total="${#lines[@]}"
  # the window: the box has its two borders, the blank line at the top and the keys (two lines, with the blank before them) at the bottom
  maxrows=$((bh - 2))
  ws=$((maxrows - 4))
  [ "$ws" -ge 3 ] || ws=3
  start=0 end="$total"
  if [ "$total" -gt "$ws" ]; then
    # (it scrolls: two lines of the window say whether there is more above and below, and the rest is the list)
    scrolling=1
    ws=$((ws - 2))
    [ "$ws" -ge 1 ] || ws=1
    start=$((sel_row - ws / 2))
    # the title of the group of the cursor stays in view when it fits
    if [ "$sel_row" -gt 0 ] && [ "${isel[$((sel_row - 1))]}" = 0 ] && [ "$start" -gt $((sel_row - 1)) ]; then start=$((sel_row - 1)); fi
    [ "$start" -ge 0 ] || start=0
    [ "$start" -le $((total - ws)) ] || start=$((total - ws))
    end=$((start + ws))
    [ "$start" -eq 0 ] || up=1
    [ "$end" -ge "$total" ] || dn=1
  fi
  DASH_DLG=("")
  if [ "$scrolling" -eq 1 ]; then
    if [ "$up" -eq 1 ]; then DASH_DLG+=("  ${TH[dim]:-$C_GRY}$UI_S_UP$C_OFF"); else DASH_DLG+=(""); fi
  fi
  for ((i = start; i < end; i++)); do DASH_DLG+=("${lines[$i]}"); done
  if [ "$scrolling" -eq 1 ]; then
    if [ "$dn" -eq 1 ]; then DASH_DLG+=("  ${TH[dim]:-$C_GRY}$UI_S_ELL$C_OFF"); else DASH_DLG+=(""); fi
  fi
  DASH_DLG+=("")
  if [ "$UI_UTF8" -eq 1 ] && [ "$UI_RICH" -eq 1 ]; then dt tui.menu.keys; else dt tui.menu.keys.ascii; fi
  dash_wrap "$DTV" 54
  for line in "${DASH_WRAP[@]}"; do DASH_DLG+=(" ${TH[dim]:-$C_GRY}$line$C_OFF"); done
  dash_dialog "$bh" "$DASH_MENU_TITLE" 56
}

# --- The contract of lib/screens/registry.sh --------------------------------------------------------------------
scr_menu_render() { dash_dialog_menu "$2"; } # width height
scr_menu_key() { dash_key_menu "$1"; }
scr_menu_keys() { # width
  dt tui.dialog.keys; dash_keyfit "${DTV//\{1\}/$DASH_UD}" "$1"; TUI_FRAME+=(" $C_GRY$DASH_KF$C_OFF")
}
scr_menu_sig() { DASH_SIG+="|$DASH_MENU_SEL|$DASH_MENU_SVC"; }

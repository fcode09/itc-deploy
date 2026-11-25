#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Tab of the workspace: Servicios. One row per service of the catalog: the ones the instance runs (state, version, port, memory) and the ones it
# does not, with what can be done to the one under the cursor: add it, remove it (its data stays), change its version, port or memory, deploy
# it, stop it, roll it back. Every change is `./deltactl service ...` (lib/core/svcmgmt.sh) or the command of always, run in the background
# like any other, so it shows in Output and the history. The keys are the ones of the footer; the tab owns the keyboard (DASH_FOCUS=tab) while
# it is on screen. Loaded by lib/screens/instances_ws.sh (dash_ws_register).

DASH_WSV_SEL=0           # the row under the cursor (0 = the first service of the catalog)
DASH_WSV_NAME=""         # the instance the cursor was last used on (a different instance starts on its first row)

# Is the service active in the instance?
dash_wsv_active() { # instance service
  case " ${DASH_SVCS[$1]:-} " in *" $2 "*) return 0 ;; esac
  return 1
}

# Keeps the cursor inside the rows, and on the first one when the instance changed.
dash_wsv_clamp() { # instance
  local n="${#KNOWN_SERVICES[@]}"
  if [ "$DASH_WSV_NAME" != "$1" ]; then DASH_WSV_NAME="$1" DASH_WSV_SEL=0; fi
  [ "$DASH_WSV_SEL" -lt "$n" ] || DASH_WSV_SEL=$((n - 1))
  [ "$DASH_WSV_SEL" -ge 0 ] || DASH_WSV_SEL=0
}

ws_servicios_avail() { # instance
  [ -n "$1" ]
}

ws_servicios_sig() {
  local name="${DASH_NAMES[$DASH_SEL]:-}"
  DASH_WS_SIG+="|$DASH_WSV_SEL|${DASH_SVCS[$name]:-}|$DASH_WSV_NAME"
}

ws_servicios_texts() {
  DASH_KEYS[ws_servicios]="$(t tui.svc.keys "$DASH_UD" "$DASH_LEFT")"
}

ws_servicios_box() { # instance width height
  local name="$1" w="$2" h="$3" iw ih s i n=0 act tag port mem line room sym kind txt sel foc=0 f chip
  local -a body=() rows=() detail=()
  iw=$((w - 3)) ih=$((h - 2))
  dash_wsv_clamp "$name"
  [ "$DASH_FOCUS" != "tab" ] || foc=1
  f="$INSTANCES_DIR/$name/.env.instance"
  for i in "${!KNOWN_SERVICES[@]}"; do
    s="${KNOWN_SERVICES[$i]}"
    sel=0; [ "$i" -ne "$DASH_WSV_SEL" ] || sel=1
    dash_ws_esc "${CAT_NAME[$s]:-$s}"
    if dash_wsv_active "$name" "$s"; then
      get_var_r "$f" "$(tag_var "$s")"; tag="${GV:--}"
      get_var_r "$f" "${s^^}_PORT"; port="${GV:--}"
      get_var_r "$f" "${s^^}_MEM_LIMIT"; mem="${GV:-${CAT_MEM[$s]:--}}"
      kind="${DSV_KIND[$name/$s]:-dim}" txt="${DSV_TEXT[$name/$s]:-}"
      sym="${DASH_SYM[$kind]:-${DASH_SYM[dim]}}"
      line="$sym $C_BLD$s$C_OFF $DASH_WS_ESC  $C_GRY$UI_S_DOT$C_OFF $tag  $C_GRY:$port  mem $mem$C_OFF"
      [ -z "$txt" ] || line+="  $C_GRY$UI_S_DOT$C_OFF $txt"
    else
      dt tui.svc.row.off
      line="${DASH_SYM[dim]} $s $DASH_WS_ESC  $C_GRY$UI_S_DOT $DTV$C_OFF"
    fi
    room=$((iw - 2))
    tui_fit "$line" "$room"
    if [ "$sel" -eq 1 ]; then rows+=("$TUI_SEL${TH[accent]:-$C_CYN}$UI_S_SEL$TH_RESET $TUI_OUT"); else rows+=("  $TUI_OUT"); fi
  done
  body=("${rows[@]}")
  # What is under the cursor: what the service is and what the keys will do to it.
  s="${KNOWN_SERVICES[$DASH_WSV_SEL]:-}"
  if [ -n "$s" ]; then
    body+=("")
    dt "catalog.desc.$s"; dash_wrap "$DTV" $((iw - 2))
    for line in "${DASH_WRAP[@]}"; do body+=("$C_GRY$line$C_OFF"); done
    if dash_wsv_active "$name" "$s"; then dt tui.svc.hint.active; else dt tui.svc.hint.off; fi
    dash_wrap "$DTV" $((iw - 2))
    for line in "${DASH_WRAP[@]}"; do body+=("$line"); done
  fi
  n="${#body[@]}"
  [ "$n" -le "$ih" ] || body=("${body[@]:0:$ih}")
  act="" n=0
  dt tui.svc.foot.add; act+="$DTV"
  for i in remove version port mem deploy stop rollback; do dt "tui.svc.foot.$i"; act+="|$DTV"; done
  dt tui.ws.foot.tabs; act+="|$DTV"
  dash_ws_esc "$name"; chip="$DASH_WS_ESC"
  dash_ws_status "$name"
  local -a opts=("chips=$chip" "status=$DASH_WS_STATUS" "footer=$act")
  [ "$foc" -eq 0 ] || opts+=(focus=1)
  kit_box "$w" "$h" body "${opts[@]}"
  TUI_BOX=("${KIT_BOX[@]}")
}

# The command of the tab for a key (the tab owns the keyboard). Returns 0 when it took the key.
ws_servicios_key() { # key
  local name="${DASH_NAMES[$DASH_SEL]:-}" s n="${#KNOWN_SERVICES[@]}" active=0 kind
  local -a cur=()
  [ -n "$name" ] || return 1
  dash_wsv_clamp "$name"
  s="${KNOWN_SERVICES[$DASH_WSV_SEL]:-}"
  dash_wsv_active "$name" "$s" && active=1
  case "$1" in
    up | k) DASH_WSV_SEL=$(((DASH_WSV_SEL + n - 1) % n)) ;;
    down | j) DASH_WSV_SEL=$(((DASH_WSV_SEL + 1) % n)) ;;
    right) ;;
    a)
      if [ "$active" -eq 1 ]; then dash_msg info "$(t tui.svc.is_active "$s")"; return 0; fi
      dash_confirm "$(t tui.svc.confirm_add "$s" "${CAT_NAME[$s]}" "$name")" stay service add "$name" "$s" --tag latest --generate-secrets --yes
      ;;
    enter)
      if [ "$active" -eq 0 ]; then ws_servicios_key a; else dash_msg info "$(t tui.svc.enter_active "$s")"; fi
      ;;
    X)
      [ "$active" -eq 1 ] || { dash_msg info "$(t tui.svc.not_active "$s")"; return 0; }
      read -ra cur <<< "${DASH_SVCS[$name]:-}"
      if [ "${#cur[@]}" -le 1 ]; then dash_msg warn "$(t service.last "$s" "$name")"; return 0; fi
      dash_sa_open remove "$name" "$s"
      ;;
    v | P | m)
      [ "$active" -eq 1 ] || { dash_msg info "$(t tui.svc.not_active "$s")"; return 0; }
      case "$1" in v) kind=tag ;; P) kind=port ;; *) kind=memory ;; esac
      dash_sa_open "$kind" "$name" "$s"
      ;;
    u)
      [ "$active" -eq 1 ] || { dash_msg info "$(t tui.svc.not_active "$s")"; return 0; }
      dash_confirm "$(t tui.svc.confirm_deploy "$s" "$name")" stay deploy "$name" "$s"
      ;;
    s)
      [ "$active" -eq 1 ] || { dash_msg info "$(t tui.svc.not_active "$s")"; return 0; }
      dash_confirm "$(t tui.confirm_stop "$s" "$name")" stay stop "$name" "$s"
      ;;
    R)
      [ "$active" -eq 1 ] || { dash_msg info "$(t tui.svc.not_active "$s")"; return 0; }
      dash_confirm "$(t tui.svc.confirm_rollback "$s" "$name")" stay rollback "$name" "$s" --yes
      ;;
    *) return 1 ;;
  esac
  return 0
}

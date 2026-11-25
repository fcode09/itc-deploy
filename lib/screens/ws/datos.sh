#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Tab of the workspace: Datos. What the instance's data is: whether its databases were seeded (and from what), the marker that protects them from
# being seeded again, the folders of data/ of each service, and the records of the seeds (init-logs/). The two actions are the ones of always,
# with the same confirmations: `I` seeds (init asks to type the name of the instance, as it does from the menu) and `A` marks an existing one
# as seeded (adopt, after asking). Nothing here reads a file with a process: the marker and the folders are read with the shell itself.
# Loaded by lib/screens/instances_ws.sh (dash_ws_register).

ws_datos_avail() { # instance
  [ -n "$1" ]
}

ws_datos_texts() {
  DASH_KEYS[ws_datos]="$(t tui.wsd.keys "$DASH_LEFT")"
}

ws_datos_box() { # instance width height
  local name="$1" w="$2" h="$3" iw ih dir marker src at st s d ok miss line chip n
  local -a body=() logs=() svcs=()
  iw=$((w - 3)) ih=$((h - 2))
  dir="$INSTANCES_DIR/$name"
  marker="$dir/.initialized"
  st="${DASH_DATA[$name]:-existing}"
  # the state, in words and colour
  case "$st" in init) ok="$C_GRN${DASH_SYM[ok]}$C_OFF" ;; unseeded) ok="$C_YEL$UI_S_WARN$C_OFF" ;; *) ok="$C_CYN${DASH_SYM[ok]}$C_OFF" ;; esac
  dt tui.wsd.state; line="$C_BLD$DTV$C_OFF  $ok "
  dt "tui.data.$st"; line+="$DTV"
  body+=("$line")
  # the marker
  if [ -f "$marker" ]; then
    get_var_r "$marker" SOURCE; src="$GV"
    get_var_r "$marker" INITIALIZED_AT; at="$GV"
    dt tui.wsd.marker; line="$C_BLD$DTV$C_OFF  .initialized  ${C_GRY}SOURCE=$src${at:+  $UI_S_DOT  $at}$C_OFF"
  else
    dt tui.wsd.marker; line="$C_BLD$DTV$C_OFF  "
    dt tui.wsd.no_marker; line+="$C_YEL$DTV$C_OFF"
  fi
  body+=("$line" "")
  # the folders of data/ of each service the instance runs
  read -ra svcs <<< "${DASH_SVCS[$name]:-}"
  dt tui.wsd.folders; body+=("$C_BLD$DTV$C_OFF")
  for s in "${svcs[@]}"; do
    line="  $C_BLD$s$C_OFF "
    miss=0
    for d in ${CAT_DATA[$s]:-}; do
      if [ -d "$dir/data/$s/$d" ]; then line+=" $C_GRN$UI_S_OK$C_OFF$d"; else line+=" $C_RED$UI_S_ERR$C_OFF$d"; miss=$((miss + 1)); fi
    done
    [ -n "${CAT_DATA[$s]:-}" ] || line+=" ${C_GRY}-$C_OFF"
    body+=("$line")
  done
  body+=("")
  # the records of the seeds
  if [ -d "$dir/init-logs" ]; then
    for d in "$dir/init-logs"/*; do [ -e "$d" ] && logs+=("${d##*/}"); done
  fi
  n="${#logs[@]}"
  dt tui.wsd.logs; line="$C_BLD$DTV$C_OFF"
  [ "$n" -eq 0 ] || line+=" $C_GRY$UI_S_DOT $n$C_OFF"
  body+=("$line")
  if [ "$n" -eq 0 ]; then dt tui.wsd.no_logs; body+=("  $C_GRY$DTV$C_OFF")
  else
    local first=$((n > 5 ? n - 5 : 0)) i
    for ((i = n - 1; i >= first; i--)); do body+=("  $C_GRY${logs[$i]}$C_OFF"); done
  fi
  body+=("")
  case "$st" in unseeded) dt tui.wsd.hint.unseeded ;; *) dt tui.wsd.hint.done ;; esac
  dash_wrap "$DTV" $((iw - 2))
  for line in "${DASH_WRAP[@]}"; do body+=("$line"); done
  [ "${#body[@]}" -le "$ih" ] || body=("${body[@]:0:$ih}")
  local act=""
  dt tui.wsd.foot.init; act+="$DTV"
  dt tui.wsd.foot.adopt; act+="|$DTV"
  dt tui.ws.foot.tabs; act+="|$DTV"
  dash_ws_esc "$name"; chip="$DASH_WS_ESC"
  dash_ws_status "$name"
  local -a opts=("chips=$chip" "status=$DASH_WS_STATUS" "footer=$act")
  [ "$DASH_FOCUS" != "tab" ] || opts+=(focus=1)
  kit_box "$w" "$h" body "${opts[@]}"
  TUI_BOX=("${KIT_BOX[@]}")
}

ws_datos_key() { # key
  local name="${DASH_NAMES[$DASH_SEL]:-}" st
  [ -n "$name" ] || return 1
  st="${DASH_DATA[$name]:-existing}"
  case "$1" in
    I)
      if [ "$st" = "unseeded" ]; then
        DASH_NAME_TARGET="$name" DASH_BUF="" DASH_CUR=0 DASH_MODE=name
      else
        dash_msg info "$(t tui.wsd.already "$name")"
      fi
      ;;
    A)
      if [ -f "$INSTANCES_DIR/$name/.initialized" ]; then dash_msg info "$(t tui.wsd.already "$name")"; return 0; fi
      dash_confirm "$(t tui.wsd.confirm_adopt "$name")" stay adopt "$name"
      ;;
    up | down | k | j | right) ;;
    *) return 1 ;;
  esac
  return 0
}

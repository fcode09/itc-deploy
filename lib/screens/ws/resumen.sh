#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Tab of the workspace: Resumen. One box for the instance: in its border the lifecycle (its n/m and state at the top, the actions that work
# on it at the bottom), inside it a card per service (memory and CPU with the graph of each, as btop draws them) and under them "Para
# desplegar", the rows that say what is left before the instance is deployed and run or lead to what resolves them.
# When the box is too small for cards the services are the list they have always been (dash_detail_lines: a block of lines per service, that
# scrolls); nothing a service showed is lost, it is just denser. Loaded by lib/screens/instances_ws.sh (dash_ws_register).

# The highest of a history and a floor, into DASH_WS_PK.
DASH_WS_PK=0
dash_ws_peak() { # history floor
  local v pk="$2"
  for v in $1; do [ "$v" -le "$pk" ] || pk="$v"; done
  DASH_WS_PK="$pk"
}

# The card of a service: a box $3 x $4 whose body is its facts, then its memory and its CPU as metric rows (label and value, the percentage,
# and a graph of $5 rows). Into KIT_BOX. $6 = 1 when it is the service under the cursor, $7 = 1 when the cursor is in the services.
dash_ws_card() { # instance service width height graph_rows selected focused
  local name="$1" svc="$2" cw="$3" ch="$4" gr="$5" sel="$6" foc="$7" key="$1/$2" iw chips status facts rs mem lim pct val c a peak up
  local -a body=() opts=()
  iw=$((cw - 3))                      # (the box puts a space before each line and its border right after)
  dash_ws_esc "$svc"; chips="$DASH_WS_ESC"
  dash_ws_esc "${DSV_REF[$key]:-}"; [ -z "$DASH_WS_ESC" ] || chips+="|$DASH_WS_ESC"
  status="${DASH_SYM[${DSV_KIND[$key]:-dim}]} ${DSV_TEXT[$key]:-}"
  facts=""
  up="${DSV_UP[$key]:-}"
  if [ -n "$up" ]; then dt tui.lbl.up; facts+="$C_GRY$DTV$C_OFF $up"; fi
  [ -z "${DSV_PORT[$key]:-}" ] || facts+="${facts:+  $UI_S_DOT  }$C_GRY:${DSV_PORT[$key]}$C_OFF"
  rs="${ST_RESTARTS[$key]:-0}"
  if [ "$rs" -gt 0 ] 2> /dev/null; then dt tui.lbl.restarts; facts+="${facts:+  $UI_S_DOT  }$C_YEL$DTV $rs$C_OFF"; fi
  if [ -z "$facts" ] && [ -n "${DSV_NOTE[$key]:-}" ]; then facts="$C_YEL$UI_S_WARN$C_OFF ${DSV_NOTE[$key]}"; fi
  tui_fit "$facts" "$iw"; body+=("$TUI_OUT")
  if [ -n "${MT_MEM[$key]:-}" ]; then
    mem="${MT_MEM[$key]}" lim="${MT_LIM[$key]:-0}"
    mt_bytes_v "$mem"; a="$MT_B"
    if [ "$lim" -gt 0 ]; then
      pct=$((mem * 100 / lim)); mt_bytes_v "$lim"; val="$a/$MT_B"
    else
      pct=0
      [ -z "$MT_HOST_TOTAL_KB" ] || pct=$((mem * 100 / (MT_HOST_TOTAL_KB * 1024)))
      val="$a"
    fi
    dt tui.lbl.mem
    kit_metric_row "$DTV" "$val" "$pct" "${MT_HMEM[$key]:-}" "$([ "$lim" -gt 0 ] && echo "$lim" || echo auto)" "$iw" "$gr" mem
    body+=("${KM_LINES[@]}")
    c="${MT_CPU[$key]:-}"
    dt tui.lbl.cpu
    if [ -n "$c" ]; then
      mt_tenths_v "$c"; val="$MT_T%"
      pct=$((c / 10)); [ "$pct" -le 100 ] || pct=100
      dash_ws_peak "${MT_HCPU[$key]:-}" 200
      kit_metric_row "$DTV" "$val" "$pct" "${MT_HCPU[$key]:-}" "$DASH_WS_PK" "$iw" "$gr" cpu
      body+=("${KM_LINES[@]}")
    else
      dt tui.ws.card.no_reading
      kit_leader "$DTV" "-" "$iw"
      body+=("$KIT_OUT")
    fi
  else
    dt tui.ws.card.no_reading
    body+=("$C_GRY$DTV$C_OFF")
  fi
  opts=("chips=$chips" "status=$status")
  if [ "$foc" -eq 1 ] && [ "$sel" -eq 1 ]; then opts+=(focus=1)
  elif [ "$sel" -eq 1 ]; then opts+=("color=${TH[accent]:-$C_CYN}"); fi
  kit_box "$cw" "$ch" body "${opts[@]}"
}

# The cards of the services of an instance, in as many columns as fit, into DASH_WS_SVC when they fit in $3 lines at $2 cells.
# Returns 1 when they do not (the list of lines is used instead).
dash_ws_cards() { # instance width avail
  local name="$1" iw="$2" avail="$3" ns cols rows gr ch base last r k i j line cw foc=0 inrow
  local -a svcs=() CL=()
  read -ra svcs <<< "${DASH_SVCS[$name]:-}"
  ns="${#svcs[@]}"
  [ "$ns" -gt 0 ] && [ "$iw" -ge 34 ] || return 1
  cols=$((iw / 34)); [ "$cols" -le "$ns" ] || cols="$ns"
  [ "$cols" -le 3 ] || cols=3
  rows=$(((ns + cols - 1) / cols))
  gr=$(((avail / rows - 7) / 2))
  [ "$gr" -ge 1 ] || return 1
  [ "$gr" -le 3 ] || gr=3
  ch=$((7 + 2 * gr))
  [ "$DASH_FOCUS" != "svc" ] || foc=1
  base=$((iw / cols)) last=$((iw - base * (cols - 1)))
  DASH_WS_SVC=()
  for ((r = 0; r < rows; r++)); do
    inrow=0
    for ((k = 0; k < cols; k++)); do
      i=$((r * cols + k))
      [ "$i" -lt "$ns" ] || break
      cw="$base"; [ "$k" -lt $((cols - 1)) ] || cw="$last"
      # (a row that is not full gives each card the width it would have in a full one)
      dash_ws_card "$name" "${svcs[$i]}" "$cw" "$ch" "$gr" "$([ "$i" -eq "$DASH_SVC" ] && echo 1 || echo 0)" "$foc"
      for ((j = 0; j < ch; j++)); do CL[k * ch + j]="${KIT_BOX[$j]}"; done
      inrow=$((inrow + 1))
    done
    for ((j = 0; j < ch; j++)); do
      line=""
      for ((k = 0; k < inrow; k++)); do line+="${CL[k * ch + j]}"; done
      DASH_WS_SVC+=("$line")
    done
  done
  return 0
}
DASH_WS_SVC=()

# The state of the instance as a chip: its state in words, coloured, and the count of what is left to resolve.
dash_ws_status() { # instance
  local name="$1" kind word
  kind="${DASH_KIND[$name]:-dim}"
  if [ "$ST_DOCKER" -ne 1 ]; then dt tui.ws.state.unknown; word="$DTV"; kind=dim
  else dt "tui.ws.state.$kind"; word="$DTV"; fi
  dash_kcol "$kind"
  DASH_WS_STATUS="${DASH_SYM[$kind]} $DASH_KC$word$C_OFF"
}

# The actions in the bottom border: the ones that work on the instance from anywhere (their keys do the same with the list focused).
dash_ws_footer() { # instance
  local items="" k
  for k in deploy check status logs; do dt "tui.ws.foot.$k"; items+="${items:+|}$DTV"; done
  if [ "$DASH_TODO_N" -gt 0 ]; then dt tui.ws.foot.todo; items+="|$DTV"; fi
  if dash_ws_has_strip; then dt tui.ws.foot.tabs; items+="|$DTV"; fi
  dt tui.ws.foot.actions; items+="|$DTV"
  DASH_WS_FOOT="$items"
}

# The rows of "Para desplegar" ($1 cells wide) from the items in `items`: the state, the text (what it is, and in the dim colour what about it)
# and, at the right, what Enter does. The one under the cursor (index $2, -1 for none) is marked and drawn as a selected row. Into
# DASH_WS_TROWS. (The kit's checklist cuts the title to a third of the width; a to-do row is a sentence, so it gets all the room.)
DASH_WS_TROWS=()
dash_ws_todo_rows() { # width sel
  local w="$1" sel="$2" i item st rest title detail action act aw room text line
  DASH_WS_TROWS=()
  for i in "${!items[@]}"; do
    item="${items[$i]}"
    st="${item%%|*}" rest="${item#*|}"
    title="${rest%%|*}" rest="${rest#*|}"
    detail="${rest%%|*}" action="${rest#*|}"
    [ "$action" != "$rest" ] || action=""
    kit_state_icon "$st"
    act="" aw=0
    if [ -n "$action" ]; then act="${TH[accent]:-}$C_BLD$UI_S_ENTER $action$TH_RESET"; aw=$((${#UI_S_ENTER} + 1 + ${#action} + 2)); fi
    text="$title"
    [ -z "$detail" ] || text+="  ${TH[dim]:-$C_GRY}$detail$TH_RESET"
    room=$((w - 4 - aw))
    [ "$room" -ge 8 ] || { room=$((w - 4)); act=""; }
    tui_fit "$text" "$room"
    line="$KIT_ICON $TUI_OUT"
    [ -z "$act" ] || line+="  $act"
    if [ "$i" -eq "$sel" ]; then DASH_WS_TROWS+=("$TUI_SEL${TH[accent]:-$C_CYN}$UI_S_SEL$TH_RESET $line")
    else DASH_WS_TROWS+=("  $line"); fi
  done
}

ws_resumen_box() { # instance width height
  local name="$1" w="$2" h="$3" iw ih n th avail rows shown start i foc=0 sel chip nm kind first_rel lines_n title cnt
  local -a body=() svcl=() items=()
  iw=$((w - 3)) ih=$((h - 2))
  dash_todo_build "$name"
  n="$DASH_TODO_N"
  [ "$DASH_FOCUS" != "todo" ] || foc=1
  # The rows of "Para desplegar": a header and up to five rows, and never so many that the services are left with less than five lines.
  th=0
  if [ "$n" -gt 0 ]; then
    th=$((1 + n)); [ "$th" -le 6 ] || th=6
    if [ "$foc" -eq 1 ]; then
      [ "$th" -le $((ih - 2)) ] || th=$((ih - 2))      # (with the cursor in them the rows come first: the services keep what is left)
    else
      [ "$th" -le $((ih - 5)) ] || th=$((ih - 5))
    fi
    # Too little room for rows: the header alone says how many there are and how to get to them.
    [ "$th" -ge 2 ] || { th=0; [ "$ih" -lt 3 ] || th=1; }
  elif [ "$ih" -ge 15 ]; then
    th=2       # (nothing is left: said only when there is room, the services come first)
  fi
  avail=$((ih - th))
  DASH_WS_SVC=()
  dash_ws_totals "$name"
  if dash_ws_cards "$name" "$iw" $((avail - ${#DASH_WS_TOT[@]})); then
    DASH_WS_SVC+=("${DASH_WS_TOT[@]}")        # (what the services add up to, under their cards)
  else
    # The list of lines of each service, scrolled to keep the selected one inside.
    local s e
    dash_detail_lines "$name"
    s="${DASH_DET_START[$DASH_SVC]:-0}" e=$((s + 4))
    [ "$DASH_DET_OFF" -le "$s" ] || DASH_DET_OFF="$s"
    [ "$e" -le $((DASH_DET_OFF + avail)) ] || DASH_DET_OFF=$((e - avail))
    [ "$DASH_DET_OFF" -ge 0 ] || DASH_DET_OFF=0
    [ "${#DASH_DET_LINES[@]}" -gt "$avail" ] || DASH_DET_OFF=0
    if [ "$avail" -gt 0 ]; then DASH_WS_SVC=("${DASH_DET_LINES[@]:$DASH_DET_OFF:$avail}"); fi
  fi
  body=("${DASH_WS_SVC[@]}")
  DASH_WS_TODO_REL=-1 DASH_WS_TODO_SHOWN=0 DASH_WS_TODO_START=0
  if [ "$th" -eq 1 ]; then
    dt tui.ws.todo.title; title="$DTV"
    dt tui.ws.foot.todo; kit_hotkey "$DTV" "$C_GRY"
    body+=("$C_BLD$title$C_OFF $C_GRY$UI_S_DOT $n  $KIT_OUT$C_OFF")
  elif [ "$th" -ge 2 ]; then
    rows=$((th - 1))
    if [ "$n" -gt 0 ]; then
      shown="$rows"; [ "$shown" -le "$n" ] || shown="$n"
      start=$((DASH_TODO_SEL - shown + 1)); [ "$start" -ge 0 ] || start=0
      [ "$start" -le $((n - shown)) ] || start=$((n - shown))
      items=("${DASH_TODO[@]:$start:$shown}")
      sel=-1; [ "$foc" -eq 0 ] || sel=$((DASH_TODO_SEL - start))
      dt tui.ws.todo.title; title="$DTV"
      cnt=" $C_GRY$UI_S_DOT $n$C_OFF"
    else
      shown=1 start=0
      dt tui.ws.todo.ok; title="$DTV"
      dt tui.ws.todo.ok_detail
      items=("ok|$title|$DTV|")
      dt tui.ws.todo.title; title="$DTV"
      cnt=""
      sel=-1
    fi
    dash_ws_todo_rows "$iw" "$sel"
    if [ "$foc" -eq 1 ]; then body+=("${TH[accent]:-$C_CYN}$C_BLD$title$C_OFF$cnt"); else body+=("$C_BLD$title$C_OFF$cnt"); fi
    DASH_WS_TODO_REL="${#body[@]}" DASH_WS_TODO_SHOWN="$shown" DASH_WS_TODO_START="$start"
    [ "$n" -gt 0 ] || DASH_WS_TODO_REL=-1
    body+=("${DASH_WS_TROWS[@]}")
  fi
  # The border: who it is and how it is, what can be done to it.
  nm="${DASH_NM[$name]:-}" kind="${DASH_KIND[$name]:-dim}"
  dash_ws_esc "$name"; chip="$DASH_WS_ESC $UI_S_DOT $nm"
  dash_ws_status "$name"
  dash_ws_footer "$name"
  local -a opts=("chips=$chip" "status=$DASH_WS_STATUS" "footer=$DASH_WS_FOOT")
  { [ "$DASH_FOCUS" = "svc" ] || [ "$DASH_FOCUS" = "todo" ]; } && opts+=(focus=1)
  kit_box "$w" "$h" body "${opts[@]}"
  TUI_BOX=("${KIT_BOX[@]}")
}

#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Screen: Resources (view 2). Every service of every instance with memory, CPU and trend; `s` sorts them.

# Services of every instance as "instance/service" keys, ordered by DASH_RES_SORT, into DASH_RES_KEYS.
DASH_RES_KEYS=()

dash_res_rows() {
  local name svc i j best tmp
  local -a keys=()
  for name in "${DASH_NAMES[@]}"; do
    for svc in ${DASH_SVCS[$name]}; do keys+=("$name/$svc"); done
  done
  case "$DASH_RES_SORT" in
    mem | cpu)
      local -a val=()
      for i in "${!keys[@]}"; do
        if [ "$DASH_RES_SORT" = "mem" ]; then val[i]="${MT_MEM[${keys[$i]}]:--1}"; else val[i]="${MT_CPU[${keys[$i]}]:--1}"; fi
      done
      for ((i = 0; i < ${#keys[@]}; i++)); do
        best="$i"
        for ((j = i + 1; j < ${#keys[@]}; j++)); do
          [ "${val[$j]}" -le "${val[$best]}" ] || best="$j"
        done
        if [ "$best" -ne "$i" ]; then
          tmp="${keys[$i]}"; keys[i]="${keys[$best]}"; keys[best]="$tmp"
          tmp="${val[$i]}"; val[i]="${val[$best]}"; val[best]="$tmp"
        fi
      done
      ;;
  esac
  DASH_RES_KEYS=("${keys[@]}")
}

dash_view_resources() { # body_height
  local bh="$1" inner w key inst svc sym row mem lim pct c up rs st i start avail wide=0 title
  local -a body=()
  inner=$((bh - 2))
  w=$((TUI_COLS - 2))
  [ "$w" -lt 91 ] || wide=1
  dash_res_rows
  # Summary of the server.
  dt tui.lbl.host; title="$DTV"
  if [ -n "$MT_HOST_PCT" ]; then
    dash_bar "$MT_HOST_PCT" 20
    dash_gb "$MT_HOST_USED_KB"; mem="$DASH_GB"; dash_gb "$MT_HOST_TOTAL_KB"
    dt status.hdr.memory
    row=" $C_GRY$DTV$C_OFF $DASH_BAR $mem/$DASH_GB GB $MT_HOST_PCT%"
    mt_spark_v "$MT_HOST_HIST" 100 20 20
    [ -z "$MT_S" ] || row+="  $C_GRY$MT_S$C_OFF"
    body+=("$row")
  fi
  c=0
  for key in "${!MT_MEM[@]}"; do c=$((c + MT_MEM[$key])); done
  if [ "$c" -gt 0 ] && [ -n "$MT_HOST_TOTAL_KB" ]; then
    mt_bytes_v "$c"; dt tui.lbl.containers; row=" $C_GRY$DTV$C_OFF $MT_B"
    pct=$((c / 1024 * 100 / MT_HOST_TOTAL_KB))
    dt tui.of_ram; row+="  $C_GRY(${DTV//\{1\}/$pct})$C_OFF"
    [ -z "$MT_HOST_LOAD" ] || { dt status.hdr.load; row+="  $UI_S_DOT  $C_GRY$DTV$C_OFF $MT_HOST_LOAD"; }
    body+=("$row")
  fi
  dt "tui.res.sort.$DASH_RES_SORT"; st="$DTV"
  dt tui.res.sort
  body+=("$C_GRY ${DTV//\{1\}/$st}$C_OFF" "")
  # Header and rows.
  if [ "$wide" -eq 1 ]; then
    dt tui.res.col.instance; local ci="$DTV"; dt tui.res.col.svc; local cs="$DTV"; dt tui.res.col.state; local ce="$DTV"
    dt tui.res.col.mem; local cm="$DTV"; dt tui.res.col.cpu; local cc="$DTV"; dt tui.res.col.trend; local ct="$DTV"
    dt tui.res.col.restarts; local cr="$DTV"; dt tui.res.col.up; local cu="$DTV"
    printf -v row '    %-12s %-3s %-10s %-25s %-6s %-9s %-7s %s' "$ci" "$cs" "$ce" "$cm" "$cc" "$ct" "$cr" "$cu"
  else
    dt tui.res.col.instance; local ci="$DTV"; dt tui.res.col.svc; local cs="$DTV"; dt tui.res.col.state; local ce="$DTV"
    dt tui.res.col.mem; local cm="$DTV"; dt tui.res.col.cpu; local cc="$DTV"
    printf -v row '    %-12s %-3s %-10s %-16s %s' "$ci" "$cs" "$ce" "$cm" "$cc"
  fi
  body+=("$C_GRY$row$C_OFF")
  if [ "${#DASH_RES_KEYS[@]}" -eq 0 ]; then
    dt tui.res.none; body+=("$C_GRY $DTV$C_OFF")
  fi
  [ "$DASH_RES_SEL" -lt "${#DASH_RES_KEYS[@]}" ] || DASH_RES_SEL=$((${#DASH_RES_KEYS[@]} - 1))
  [ "$DASH_RES_SEL" -ge 0 ] || DASH_RES_SEL=0
  avail=$((inner - ${#body[@]}))
  [ "$avail" -ge 1 ] || avail=1
  start=0
  [ "$DASH_RES_SEL" -lt "$avail" ] || start=$((DASH_RES_SEL - avail + 1))
  for ((i = start; i < ${#DASH_RES_KEYS[@]} && i < start + avail; i++)); do
    key="${DASH_RES_KEYS[$i]}"
    inst="${key%%/*}"; svc="${key#*/}"
    sym="${DASH_SYM[${DSV_KIND[$key]:-dim}]}"
    printf -v row '%-12.12s %-3s' "$inst" "$svc"
    tui_fit "${DSV_TEXT[$key]:-}" 10; row+=" $TUI_OUT"
    up="${DSV_UP[$key]:--}"
    rs="${ST_RESTARTS[$key]:-0}"
    if [ -n "${MT_MEM[$key]:-}" ]; then
      mem="${MT_MEM[$key]}"; lim="${MT_LIM[$key]:-0}"
      mt_bytes_v "$mem"; c="$MT_B"
      if [ "$lim" -gt 0 ]; then
        pct=$((mem * 100 / lim)); mt_bytes_v "$lim"; c="$c/$MT_B $pct%"
      else
        pct=0
        [ -z "$MT_HOST_TOTAL_KB" ] || pct=$((mem / 1024 * 100 / MT_HOST_TOTAL_KB))
      fi
      if [ "$wide" -eq 1 ]; then
        dash_bar "$pct" 8
        tui_fit "$DASH_BAR $c" 25; row+=" $TUI_OUT"
      else
        tui_fit "$c" 16; row+=" $TUI_OUT"
      fi
      if [ -n "${MT_CPU[$key]:-}" ]; then
        mt_tenths_v "${MT_CPU[$key]}"; c="$MT_T%"
      else
        c="-"
      fi
      tui_fit "$c" 6; row+=" $TUI_OUT"
      if [ "$wide" -eq 1 ]; then
        mt_spark_v "${MT_HCPU[$key]:-}" 0 8 100
        tui_fit "$C_GRY$MT_S$C_OFF" 9; row+=" $TUI_OUT"
      fi
    else
      if [ "$wide" -eq 1 ]; then tui_fit "$C_GRY-$C_OFF" 25; else tui_fit "$C_GRY-$C_OFF" 16; fi
      row+=" $TUI_OUT"
      tui_fit "$C_GRY-$C_OFF" 6; row+=" $TUI_OUT"
      if [ "$wide" -eq 1 ]; then tui_fit "" 9; row+=" $TUI_OUT"; fi
    fi
    if [ "$wide" -eq 1 ]; then
      printf -v c '%-7s %s' "$rs" "$up"
      row+=" $c"
    fi
    if [ "$i" -eq "$DASH_RES_SEL" ]; then
      body+=("$TUI_SEL$C_CYN$UI_S_SEL$C_OFF $sym $C_BLD$row$C_OFF")
    else
      body+=("  $sym $row")
    fi
  done
  tui_box "$title" "$TUI_COLS" "$bh" body "" 1
  TUI_FRAME+=("${TUI_BOX[@]}")
}

dash_key_resources() {
  local key inst svc i name s
  case "$1" in
    up | k) [ "$DASH_RES_SEL" -le 0 ] || DASH_RES_SEL=$((DASH_RES_SEL - 1)) ;;
    down | j) DASH_RES_SEL=$((DASH_RES_SEL + 1)) ;;
    pgup) DASH_RES_SEL=$((DASH_RES_SEL - 10)); [ "$DASH_RES_SEL" -ge 0 ] || DASH_RES_SEL=0 ;;
    pgdn) DASH_RES_SEL=$((DASH_RES_SEL + 10)) ;;
    s)
      case "$DASH_RES_SORT" in name) DASH_RES_SORT=mem ;; mem) DASH_RES_SORT=cpu ;; *) DASH_RES_SORT=name ;; esac
      ;;
    enter)
      dash_res_rows
      key="${DASH_RES_KEYS[$DASH_RES_SEL]:-}"
      [ -n "$key" ] || return 0
      inst="${key%%/*}" svc="${key#*/}"
      for i in "${!DASH_NAMES[@]}"; do
        [ "${DASH_NAMES[$i]}" != "$inst" ] || DASH_SEL="$i"
      done
      DASH_SVC=0 s=0
      for name in ${DASH_SVCS[$inst]:-}; do
        [ "$name" != "$svc" ] || DASH_SVC="$s"
        s=$((s + 1))
      done
      DASH_DET_OFF=0 DASH_VIEW=instances DASH_ON_NEW=0 DASH_FOCUS=svc
      ;;
  esac
}

# --- The contract of lib/screens/registry.sh --------------------------------------------------------------------
scr_resources_render() { dash_view_resources "$2"; } # width height
scr_resources_key() { dash_key_resources "$1"; }
scr_resources_keys() { dash_keys_view resources "$1"; } # width
scr_resources_texts() { DASH_KEYS[resources]="$(t tui.keys.resources "$DASH_UD" "$DASH_LR")"; }
scr_resources_sig() { DASH_SIG+="|$DASH_RES_SEL|$DASH_RES_SORT"; }

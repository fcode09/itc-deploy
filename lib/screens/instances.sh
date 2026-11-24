#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Screen: Instances (view 1). The list of instances, the detail of the selected one (its services, figures, charts, logs and next
# steps) and the strip of the console. Wide screens get the Overview; small ones the compact view; `z` zooms one pane.
# Loaded by lib/screens/registry.sh. The logs pane (a stream of `docker logs`) is in instances_logs.sh.

source "$ROOT/lib/screens/instances_logs.sh"

# Where the list of instances is on screen, for the mouse: drawn in this body or not, its width, and the first instance it shows
# and how many fit. Its box is always the first thing of the body, so its first row (the New button) is screen row 4.
DASH_LIST_SHOWN=0 DASH_LIST_W=0 DASH_LIST_START=0 DASH_LIST_AVAIL=0 DASH_LIST_OFF=0

DASH_TBL=() DASH_GL=() DASH_CB=() DASH_NX=() DASH_TOT=() DASH_HB=()

# The centre without its logs box, into DASH_CB; the height, the key and the service of the logs box go to DASH_CT_*.
DASH_CT_LH=0 DASH_CT_KEY="" DASH_CT_SVC=""

DASH_EBOX=() DASH_EBOX_SIG="" DASH_LBOX=() DASH_LBOX_SIG=""

# Lines of the list of instances. The first row is the "New instance" button; then a header and one row per instance: a dot per
# service (green, yellow, red, or an empty circle when it is stopped), the name, n/m, memory and CPU. The selected row is a filled
# bar while the list has the focus and just a marker while the focus is in the services. Kept inside $1 rows and, when given,
# $2 cells.
dash_list_lines() { # inner_height [inner_width]
  local h="$1" iw="${2:-0}" i name n="${#DASH_NAMES[@]}" nw=8 start=0 avail row nm mem cpu kind nmp dots svc cnt dw=2 btn acc lf=0
  [ "$DASH_FOCUS" != "list" ] || lf=1
  acc="${TH[accent]:-$C_CYN}"
  DASH_LIST_LINES=()
  dt tui.new.button; btn="$DTV"
  if [ "$DASH_ON_NEW" -eq 1 ]; then
    if [ "$lf" -eq 1 ]; then DASH_LIST_LINES+=("$TUI_SEL$acc$UI_S_SEL$C_OFF $acc$C_BLD$btn$C_OFF")
    else DASH_LIST_LINES+=("$acc$UI_S_SEL$C_OFF $acc$C_BLD$btn$C_OFF"); fi
  else
    DASH_LIST_LINES+=("  $acc$btn$C_OFF")
  fi
  if [ "$n" -eq 0 ]; then
    dt tui.none
    DASH_LIST_LINES+=("" "$C_GRY$DTV$C_OFF")
    return 0
  fi
  for name in "${DASH_NAMES[@]}"; do
    [ "${#name}" -le "$nw" ] || nw="${#name}"
    cnt=0; for svc in ${DASH_SVCS[$name]:-}; do cnt=$((cnt + 1)); done
    [ "$cnt" -le "$dw" ] || dw="$cnt"
  done
  [ "$dw" -le 4 ] || dw=4
  [ "$nw" -le 16 ] || nw=16
  # In a narrow pane the name gives way: the other columns (n/m, memory, cpu) and the dots need the rest.
  if [ "$iw" -gt 0 ] && [ "$nw" -gt $((iw - 25 - dw)) ]; then nw=$((iw - 25 - dw)); [ "$nw" -ge 4 ] || nw=4; fi
  dt tui.lbl.mem; mem="$DTV"
  dt tui.lbl.cpu; cpu="$DTV"
  printf -v row '%*s %-*s %-5s %6s %6s' $((2 + dw)) '' "$nw" '' 'n/m' "$mem" "$cpu"
  DASH_LIST_LINES+=("$C_GRY$row$C_OFF")
  avail=$((h - 2))
  [ "$avail" -ge 1 ] || avail=1
  # The first instance shown stays where it was until the selection leaves the window: a list that jumped at every selection
  # would move the instance away from under the pointer that clicked it.
  if [ "$DASH_ON_NEW" -eq 1 ]; then
    start=0
  else
    start="$DASH_LIST_OFF"
    [ "$DASH_SEL" -ge "$start" ] || start="$DASH_SEL"
    [ "$DASH_SEL" -lt $((start + avail)) ] || start=$((DASH_SEL - avail + 1))
    [ "$start" -le $((n - avail)) ] || start=$((n - avail))
    [ "$start" -ge 0 ] || start=0
  fi
  DASH_LIST_OFF="$start"
  # Where a click lands (see dash_mouse): the rows really inside the box, which can be none on a short terminal.
  DASH_LIST_START="$start" DASH_LIST_AVAIL=$((h - 2))
  [ "$DASH_LIST_AVAIL" -ge 0 ] || DASH_LIST_AVAIL=0
  for ((i = start; i < n && i < start + avail; i++)); do
    name="${DASH_NAMES[$i]}"
    kind="${DASH_KIND[$name]}"
    dash_kcol "$kind"
    dots=""; cnt=0
    for svc in ${DASH_SVCS[$name]:-}; do
      if [ "$cnt" -lt "$dw" ]; then dots+="${DASH_SYM[${DSV_KIND[$name/$svc]:-dim}]}"; cnt=$((cnt + 1)); fi
    done
    while [ "$cnt" -lt "$dw" ]; do dots+=" "; cnt=$((cnt + 1)); done
    mt_instance_sum "$name" ${DASH_SVCS[$name]}
    if [ "$MT_SUM_MEM" -gt 0 ]; then
      mt_bytes_v "$MT_SUM_MEM"; mem="$MT_B"
      mt_tenths_v "$MT_SUM_CPU"; cpu="$MT_T%"
    else
      mem="-" cpu="-"
    fi
    printf -v nmp '%-5s' "${DASH_NM[$name]}"
    printf -v row '%-*s' "$nw" "$name"
    printf -v mem '%6s' "$mem"; printf -v cpu '%6s' "$cpu"
    if [ "$DASH_ON_NEW" -eq 0 ] && [ "$i" -eq "$DASH_SEL" ]; then
      if [ "$lf" -eq 1 ]; then
        DASH_LIST_LINES+=("$TUI_SEL$acc$UI_S_SEL$C_OFF $dots $C_BLD$row$C_OFF $DASH_KC$nmp$C_OFF$C_BLD$mem $cpu$C_OFF")
      else
        DASH_LIST_LINES+=("$acc$UI_S_SEL$C_OFF $dots $C_BLD$row$C_OFF $DASH_KC$nmp$C_OFF$mem $cpu")
      fi
    else
      DASH_LIST_LINES+=("  $dots $row $DASH_KC$nmp$C_OFF$mem $cpu")
    fi
  done
}

# What the center shows while the New button is selected: what it does, and how else to get there.
dash_new_box() { # width height
  local w="$1" h="$2"
  local -a body=()
  dt tui.new.l1; body+=("" "$DTV")
  dt tui.new.l2; body+=("$DTV")
  dt tui.new.l3; body+=("" "$C_GRY$DTV$C_OFF")
  dt tui.new.title
  tui_box "$DTV" "$w" "$h" body
}

# Memory and CPU lines of a running service.
dash_service_meter_lines() { # key
  local key="$1" mem lim pct txt a c
  mem="${MT_MEM[$key]}"
  lim="${MT_LIM[$key]:-0}"
  mt_bytes_v "$mem"; a="$MT_B"
  if [ "$lim" -gt 0 ]; then
    pct=$((mem * 100 / lim))
    mt_bytes_v "$lim"
    txt="$a/$MT_B  $pct%"
  else
    pct=0
    [ -z "$MT_HOST_TOTAL_KB" ] || pct=$((mem / 1024 * 100 / MT_HOST_TOTAL_KB))
    dt tui.of_ram
    txt="$a  $C_GRY${DTV//\{1\}/$pct}$C_OFF"
  fi
  dash_bar "$pct" 12
  mt_spark_v "${MT_HMEM[$key]:-}" "$lim" 14 0
  dt tui.lbl.mem
  DASH_DET_LINES+=("    $C_GRY$DTV$C_OFF  $DASH_BAR $txt  $C_GRY$MT_S$C_OFF")
  c="${MT_CPU[$key]:-}"
  dt tui.lbl.cpu
  if [ -z "$c" ]; then
    local lbl="$DTV"
    dt tui.no_reading
    DASH_DET_LINES+=("    $C_GRY$lbl  $DTV$C_OFF")
  else
    pct=$((c / 10))
    dash_bar "$pct" 12
    mt_tenths_v "$c"
    mt_spark_v "${MT_HCPU[$key]:-}" 0 14 100
    DASH_DET_LINES+=("    $C_GRY$DTV$C_OFF  $DASH_BAR $MT_T%  $C_GRY$MT_S$C_OFF")
  fi
}

# Detail of the selected instance: one block per service, totals, errors and next steps. Result in DASH_DET_LINES,
# with the line where each service starts in DASH_DET_START.
dash_detail_lines() { # instance
  local name="$1" key svc idx=0 marker sym line rs h cmd why shown=0 n lbl errs="" facts
  local -a svcs
  DASH_DET_LINES=() DASH_DET_START=()
  read -ra svcs <<< "${DASH_SVCS[$name]:-}"
  for svc in "${svcs[@]}"; do
    key="$name/$svc"
    DASH_DET_START[idx]="${#DASH_DET_LINES[@]}"
    sym="${DASH_SYM[${DSV_KIND[$key]:-dim}]}"
    if [ "$idx" -eq "$DASH_SVC" ]; then
      marker="$C_CYN$UI_S_SEL$C_OFF"
      [ "$DASH_FOCUS" != "svc" ] || marker="$TUI_SEL$marker"
    else
      marker=" "
    fi
    line="$marker $C_BLD$svc$C_OFF $C_GRY${DSV_REF[$key]:-}$C_OFF  $sym ${DSV_TEXT[$key]:-}"
    DASH_DET_LINES+=("$line")
    facts=""
    if [ -n "${DSV_UP[$key]:-}" ]; then dt tui.lbl.up; facts+="$C_GRY$DTV$C_OFF ${DSV_UP[$key]}"; fi
    [ -z "${DSV_PORT[$key]:-}" ] || facts+="${facts:+  $UI_S_DOT  }$C_GRY:${DSV_PORT[$key]}$C_OFF"
    rs="${ST_RESTARTS[$key]:-0}"
    if [ "$rs" -gt 0 ] 2>/dev/null; then dt tui.lbl.restarts; facts+="${facts:+  $UI_S_DOT  }$C_YEL$DTV $rs$C_OFF"; fi
    [ -z "$facts" ] || DASH_DET_LINES+=("    $facts")
    [ -z "${DSV_NOTE[$key]:-}" ] || DASH_DET_LINES+=("    $C_YEL$UI_S_WARN$C_OFF ${DSV_NOTE[$key]}")
    if [ -n "${MT_MEM[$key]:-}" ]; then
      dash_service_meter_lines "$key"
    elif [ "${ST_STATE[$key]:-}" = "running" ]; then
      dt tui.no_reading
      DASH_DET_LINES+=("    $C_GRY$DTV$C_OFF")
    fi
    DASH_DET_LINES+=("")
    idx=$((idx + 1))
  done
  if [ "${#svcs[@]}" -gt 0 ]; then
    mt_instance_sum "$name" "${svcs[@]}"
    dt tui.lbl.total; lbl="$DTV"
    line="  $C_BLD$lbl$C_OFF"
    if [ "$MT_SUM_MEM" -gt 0 ]; then
      mt_bytes_v "$MT_SUM_MEM"; line+="  mem $MT_B"
      if [ "$MT_SUM_LIM" -gt 0 ]; then mt_bytes_v "$MT_SUM_LIM"; line+="/$MT_B"; fi
      mt_tenths_v "$MT_SUM_CPU"; line+="  cpu $MT_T%"
    fi
    dt tui.lbl.data; line+="  $C_GRY$DTV:$C_OFF "
    dt "tui.data.${DASH_DATA[$name]:-existing}"; line+="$DTV"
    DASH_DET_LINES+=("$line")
    if [ -n "${DASH_ERRS_AT[$name]:-}" ]; then
      for svc in "${svcs[@]}"; do
        n="${DASH_ERRS[$name/$svc]:-}"
        [ -n "$n" ] || continue
        if [ "$n" -gt 0 ]; then errs+="${errs:+ $UI_S_DOT }$C_RED$svc $n$C_OFF"; else errs+="${errs:+ $UI_S_DOT }$svc 0"; fi
      done
      if [ -n "$errs" ]; then dt tui.lbl.errors; DASH_DET_LINES+=("  $C_GRY$DTV:$C_OFF $errs"); fi
    fi
  fi
  for h in ${HINTS[@]+"${HINTS[@]}"}; do
    [ "$shown" -lt 3 ] || break
    cmd="${h%%|*}"; why="${h#*|}"
    case " $cmd " in *" $name "* | *" $name") ;; *) continue ;; esac
    [ "$shown" -ne 0 ] || DASH_DET_LINES+=("")
    DASH_DET_LINES+=("  $C_CYN$UI_S_ARROW$C_OFF $C_GRN$cmd$C_OFF  $C_GRY# $why$C_OFF")
    shown=$((shown + 1))
  done
}

# The box of the list of instances, cached: what it shows changes with the state of Docker, the figures, the selection and the
# focus. The rows it shows go with it (dash_mouse needs them).
dash_list_box() { # width height inner_width focused
  local sig="$1|$2|${3:-}|$4|$DASH_SEL|$DASH_ON_NEW|$DASH_FOCUS|$DASH_LIST_OFF|$DASH_REFRESH_N|$MT_SAMPLES|$DASH_LANG_N|${#DASH_NAMES[@]}"
  if dash_pc_get list "$sig"; then
    read -r DASH_LIST_START DASH_LIST_AVAIL DASH_LIST_OFF <<< "$DASH_PC_M"
    return 0
  fi
  if [ -n "${3:-}" ]; then dash_list_lines $(($2 - 2)) "$3"; else dash_list_lines $(($2 - 2)); fi
  dt tui.instances
  tui_box "$DTV" "$1" "$2" DASH_LIST_LINES "" "$4"
  # (stored under the signature it was asked with: a selection that moved the window gives another one next time)
  dash_pc_put list "$sig" "$DASH_LIST_START $DASH_LIST_AVAIL $DASH_LIST_OFF"
}

dash_view_instances() { # body_height
  local bh="$1" oh th lw rw lh dh name inner_h title off n="${#DASH_NAMES[@]}" lf=0 mx
  [ "$DASH_FOCUS" != "list" ] || lf=1
  # Rows: the panes on top grow, the console under them asks for more as the terminal gets taller.
  if [ "$bh" -ge 40 ]; then oh=$((bh * 3 / 10))   # tall terminal: the output of a command (a check is ~15 lines) fits whole
  elif [ "$bh" -ge 22 ]; then oh=8; elif [ "$bh" -ge 16 ]; then oh=6; else oh=4; fi
  lay_split "$bh" "0:0::1" "$oh:$oh:$oh"
  th="${LAY[0]}" oh="${LAY[1]}"
  name="${DASH_NAMES[$DASH_SEL]:-}"
  if [ "$TUI_COLS" -ge 100 ]; then
    # Columns: the list is fixed, the detail takes the rest.
    lay_split "$TUI_COLS" "44:44:44" "0:0::1"
    lw="${LAY[0]}" rw="${LAY[1]}"
    dash_list_box "$lw" "$th" "" "$lf"; DASH_L=("${TUI_BOX[@]}")
    DASH_LIST_SHOWN=1 DASH_LIST_W="$lw"
    dash_detail_box_cached "$name" "$rw" "$th"; DASH_R=("${TUI_BOX[@]}")
    dash_join DASH_L DASH_R
  else
    # One column: the list asks for a row per instance (at most half the rows, never less than 4), the detail takes the rest.
    mx=$((th / 2)); [ "$mx" -ge 4 ] || mx=4
    lay_split "$th" "$((n + 4)):4:$mx" "0:0::1"
    lh="${LAY[0]}" dh="${LAY[1]}"
    dash_list_box "$TUI_COLS" "$lh" "" "$lf"
    DASH_LIST_SHOWN=1 DASH_LIST_W="$TUI_COLS"
    TUI_FRAME+=("${TUI_BOX[@]}")
    dash_detail_box_cached "$name" "$TUI_COLS" "$dh"
    TUI_FRAME+=("${TUI_BOX[@]}")
  fi
  dash_console_box "$TUI_COLS" "$oh"
  TUI_FRAME+=("${TUI_BOX[@]}")
}

# The detail box, cached (see dash_list_box). Its scroll goes with it.
dash_detail_box_cached() { # instance width height
  local sig="$1|$2|$3|$DASH_SVC|$DASH_FOCUS|$DASH_ON_NEW|$DASH_DET_OFF|$DASH_REFRESH_N|$MT_SAMPLES|$DASH_ERRS_N|$DASH_LANG_N"
  if dash_pc_get detail "$sig"; then DASH_DET_OFF="$DASH_PC_M"; return 0; fi
  dash_detail_box "$1" "$2" "$3"
  dash_pc_put detail "$sig" "$DASH_DET_OFF"
}

# The box with the detail of an instance.
dash_detail_box() { # instance width height
  local name="$1" w="$2" h="$3" inner s e title sf=0
  local -a shown=()
  inner=$((h - 2))
  [ "$DASH_FOCUS" != "svc" ] || sf=1
  if [ "$DASH_ON_NEW" -eq 1 ]; then dash_new_box "$w" "$h"; return 0; fi
  if [ -z "$name" ]; then
    dt tui.select_one
    shown=("$C_GRY$DTV$C_OFF")
    tui_box "" "$w" "$h" shown
    return 0
  fi
  dash_detail_lines "$name"
  # Keep the selected service inside the box.
  s="${DASH_DET_START[$DASH_SVC]:-0}"
  e=$((s + 4))
  [ "$DASH_DET_OFF" -le "$s" ] || DASH_DET_OFF="$s"
  [ "$e" -le $((DASH_DET_OFF + inner)) ] || DASH_DET_OFF=$((e - inner))
  [ "$DASH_DET_OFF" -ge 0 ] || DASH_DET_OFF=0
  [ "${#DASH_DET_LINES[@]}" -gt "$inner" ] || DASH_DET_OFF=0
  shown=("${DASH_DET_LINES[@]:$DASH_DET_OFF:$inner}")
  dash_kcol "${DASH_KIND[$name]:-dim}"
  title="$name $UI_S_DOT $DASH_KC${DASH_NM[$name]:-}$C_OFF"
  tui_box "$title" "$w" "$h" shown "" "$sf"
}

dash_overview_fits() { [ "$TUI_COLS" -ge 120 ] && [ "$TUI_ROWS" -ge 28 ]; }

# Lines of the services table of an instance, $2 cells wide. Result in DASH_TBL (header first). The selected service gets the
# selection marker. The image reference never takes more than 24 cells; what is left goes to a memory trend.
dash_svc_table_lines() { # instance inner_width
  local name="$1" iw="$2" svc key idx=0 sym row img_w show_up=0 show_bar=0 mem lim pct c cpu used tw
  local -a svcs
  DASH_TBL=()
  read -ra svcs <<< "${DASH_SVCS[$name]:-}"
  [ "$iw" -lt 80 ] || show_up=1
  [ "$iw" -lt 64 ] || show_bar=1
  used=$((2 + 2 + 5 + 12 + 11 + 7))                      # marker, symbol, svc, state, cpu (the image comes next)
  [ "$show_up" -eq 0 ] || used=$((used + 8))
  if [ "$show_bar" -eq 1 ]; then used=$((used + 22)); else used=$((used + 11)); fi
  img_w=$((iw - used))
  [ "$img_w" -ge 8 ] || img_w=8
  [ "$img_w" -le 24 ] || img_w=24
  tw=$((iw - used - img_w - 2))
  [ "$tw" -ge 8 ] || tw=0
  [ "$tw" -le 30 ] || tw=30
  dt tui.res.col.svc; row="    "; tui_fit "$DTV" 6; row+="$TUI_OUT"
  dt tui.col.image; tui_fit "$DTV" $((img_w + 1)); row+="$TUI_OUT"
  dt tui.res.col.state; tui_fit "$DTV" 11; row+="$TUI_OUT"
  if [ "$show_up" -eq 1 ]; then dt tui.res.col.up; tui_fit "$DTV" 8; row+="$TUI_OUT"; fi
  dt tui.res.col.mem; if [ "$show_bar" -eq 1 ]; then tui_fit "$DTV" 22; else tui_fit "$DTV" 11; fi; row+="$TUI_OUT"
  dt tui.res.col.cpu; tui_fit "$DTV" 7; row+="$TUI_OUT"
  if [ "$tw" -gt 0 ]; then dt tui.res.col.trend; row+="$DTV"; fi
  DASH_TBL+=("$C_GRY$row$C_OFF")
  for svc in "${svcs[@]}"; do
    key="$name/$svc"
    sym="${DASH_SYM[${DSV_KIND[$key]:-dim}]}"
    row=""
    tui_fit "$svc" 6; row+="$C_BLD$TUI_OUT$C_OFF"
    tui_fit "${DSV_REF[$key]:-}" $((img_w + 1)); row+="$C_GRY$TUI_OUT$C_OFF"
    dash_kcol "${DSV_KIND[$key]:-dim}"
    tui_fit "${DSV_TEXT[$key]:-}" 11; row+="$DASH_KC$TUI_OUT$C_OFF"
    if [ "$show_up" -eq 1 ]; then tui_fit "${DSV_UP[$key]:--}" 8; row+="$TUI_OUT"; fi
    cpu="-"
    if [ -n "${MT_MEM[$key]:-}" ]; then
      mem="${MT_MEM[$key]}"; lim="${MT_LIM[$key]:-0}"
      mt_bytes_v "$mem"; c="$MT_B"
      pct=0
      if [ "$lim" -gt 0 ]; then
        pct=$((mem * 100 / lim)); mt_bytes_v "$lim"; c="$c/$MT_B"
      elif [ -n "$MT_HOST_TOTAL_KB" ]; then
        pct=$((mem / 1024 * 100 / MT_HOST_TOTAL_KB))
      fi
      if [ "$show_bar" -eq 1 ]; then dash_bar "$pct" 10; tui_fit "$c" 11; row+="$DASH_BAR $TUI_OUT"; else tui_fit "$c" 11; row+="$TUI_OUT"; fi
      if [ -n "${MT_CPU[$key]:-}" ]; then mt_tenths_v "${MT_CPU[$key]}"; cpu="$MT_T%"; fi
    else
      if [ "$show_bar" -eq 1 ]; then tui_fit "-" 22; else tui_fit "-" 11; fi
      row+="$C_GRY$TUI_OUT$C_OFF"
    fi
    tui_fit "$cpu" 7; row+="$TUI_OUT"
    if [ "$tw" -gt 0 ]; then
      mt_spark_v "${MT_HMEM[$key]:-}" "${MT_LIM[$key]:-0}" "$tw" 0
      row+="${TH[accent]:-$C_CYN}$MT_S$C_OFF"
    fi
    if [ "$idx" -eq "$DASH_SVC" ]; then
      if [ "$DASH_FOCUS" = "svc" ]; then DASH_TBL+=("$TUI_SEL$C_CYN$UI_S_SEL$C_OFF $sym $row"); else DASH_TBL+=("$C_CYN$UI_S_SEL$C_OFF $sym $row"); fi
    else
      DASH_TBL+=("  $sym $row")
    fi
    idx=$((idx + 1))
  done
}

# Charts and facts of a service: $2 cells wide, $3 rows per chart. Result in DASH_GL (3 + 2 * rows lines).
dash_graph_lines() { # key inner_width chart_rows
  local key="$1" w=$(($2 - 1)) rows="$3" mem lim pct txt scale peak h v k facts rs pk lbl full
  DASH_GL=()
  mem="${MT_MEM[$key]:-}"
  if [ -z "$mem" ]; then
    dt tui.no_reading; DASH_GL+=("$C_GRY$DTV$C_OFF")
    return 0
  fi
  # Memory: scaled to the limit when there is one, else to the highest value seen.
  lim="${MT_LIM[$key]:-0}"
  scale=0
  mt_bytes_v "$mem"; txt="$MT_B"
  if [ "$lim" -gt 0 ]; then pct=$((mem * 100 / lim)); mt_bytes_v "$lim"; txt+="/$MT_B  $pct%"; scale="$lim"; fi
  h="${MT_HMEM[$key]:-}"
  peak=0
  for v in $h; do [ "$v" -le "$peak" ] || peak="$v"; done
  # Autoscale (like btop): the chart fits the highest value seen plus 20 %, never above the limit, so changes are visible even
  # when the service uses a small part of its limit.
  scale=$((peak * 120 / 100))
  [ "$scale" -gt 0 ] || scale=1
  if [ "$lim" -gt 0 ] && [ "$scale" -gt "$lim" ]; then scale="$lim"; fi
  mt_bytes_v "$peak"; pk="$MT_B"
  dt tui.lbl.mem; lbl="$DTV"
  dt tui.stats.peak
  DASH_GL+=("$C_BLD$lbl$C_OFF $txt  $C_GRY${DTV//\{1\}/$pk}$C_OFF")
  full="$lim"
  [ "$full" -gt 0 ] || full=$((${MT_HOST_TOTAL_KB:-0} * 1024))
  [ "$full" -gt 0 ] || full="$scale"
  gfx_area_cached "mem/$key" "$h" "$scale" "$w" "$rows"
  for k in "${!GFX_LINES[@]}"; do
    th_ramp_pct $(((rows - k) * scale * 100 / (rows * full)))
    DASH_GL+=("${TH_C:-$C_GRN}${GFX_LINES[$k]}$C_OFF")
  done
  # CPU (tenths of a percent). The chart never scales below 20 %, so an idle service looks idle.
  txt="-"
  if [ -n "${MT_CPU[$key]:-}" ]; then mt_tenths_v "${MT_CPU[$key]}"; txt="$MT_T%"; fi
  h="${MT_HCPU[$key]:-}"
  peak=200
  for v in $h; do [ "$v" -le "$peak" ] || peak="$v"; done
  dt tui.lbl.cpu
  DASH_GL+=("$C_BLD$DTV$C_OFF $txt")
  gfx_area_cached "cpu/$key" "$h" "$peak" "$w" "$rows"
  for k in "${!GFX_LINES[@]}"; do
    th_ramp_pct $(((rows - k) * peak * 100 / (rows * 1000)))
    DASH_GL+=("${TH_C:-$C_GRN}${GFX_LINES[$k]}$C_OFF")
  done
  facts=""
  if [ -n "${DSV_UP[$key]:-}" ]; then dt tui.lbl.up; facts+="$C_GRY$DTV$C_OFF ${DSV_UP[$key]}"; fi
  [ -z "${DSV_PORT[$key]:-}" ] || facts+="${facts:+  $UI_S_DOT  }$C_GRY:${DSV_PORT[$key]}$C_OFF"
  rs="${ST_RESTARTS[$key]:-0}"
  if [ "$rs" -gt 0 ] 2>/dev/null; then dt tui.lbl.restarts; facts+="${facts:+  $UI_S_DOT  }$C_YEL$DTV $rs$C_OFF"; fi
  [ -z "$facts" ] || DASH_GL+=("$facts")
}

# Totals of an instance and the errors seen in the last minutes (DASH_TOT, shown under the services table) and the next steps
# (DASH_NX, a box of its own that only exists when there is something to suggest).
dash_summary_lines() { # instance
  local name="$1" svc n errs="" shown=0 h cmd why line lbl
  local -a svcs
  DASH_NX=() DASH_TOT=()
  read -ra svcs <<< "${DASH_SVCS[$name]:-}"
  [ "${#svcs[@]}" -gt 0 ] || return 0
  mt_instance_sum "$name" "${svcs[@]}"
  dt tui.lbl.total; lbl="$DTV"
  line="$C_BLD$lbl$C_OFF"
  if [ "$MT_SUM_MEM" -gt 0 ]; then
    mt_bytes_v "$MT_SUM_MEM"; line+="  mem $MT_B"
    if [ "$MT_SUM_LIM" -gt 0 ]; then mt_bytes_v "$MT_SUM_LIM"; line+="/$MT_B"; fi
    mt_tenths_v "$MT_SUM_CPU"; line+="  cpu $MT_T%"
  fi
  dt tui.lbl.data; line+="  $C_GRY$DTV:$C_OFF "
  dt "tui.data.${DASH_DATA[$name]:-existing}"; line+="$DTV"
  DASH_TOT+=("  $line")
  if [ -n "${DASH_ERRS_AT[$name]:-}" ]; then
    for svc in "${svcs[@]}"; do
      n="${DASH_ERRS[$name/$svc]:-}"
      [ -n "$n" ] || continue
      if [ "$n" -gt 0 ]; then errs+="${errs:+ $UI_S_DOT }$C_RED$svc $n$C_OFF"; else errs+="${errs:+ $UI_S_DOT }$svc 0"; fi
    done
    if [ -n "$errs" ]; then dt tui.lbl.errors; DASH_TOT+=("  $C_GRY$DTV:$C_OFF $errs"); fi
  fi
  for h in ${HINTS[@]+"${HINTS[@]}"}; do
    [ "$shown" -lt 4 ] || break
    cmd="${h%%|*}"; why="${h#*|}"
    case " $cmd " in *" $name "* | *" $name") ;; *) continue ;; esac
    DASH_NX+=("$C_CYN$UI_S_ARROW$C_OFF $C_GRN$cmd$C_OFF  $C_GRY# $why$C_OFF")
    shown=$((shown + 1))
  done
}

# The center column: services table, charts of the selected service and the summary. Result in DASH_CB ($3 lines).
# The centre of the Overview: everything but its logs box is cached (see dash_list_box); the logs have their own cache.
dash_center_boxes() { # instance width height
  local sig="$1|$2|$3|$DASH_SVC|$DASH_FOCUS|$DASH_ON_NEW|$DASH_REFRESH_N|$MT_SAMPLES|$DASH_ERRS_N|$DASH_LANG_N" lh key svc
  if dash_pc_get center "$sig"; then
    DASH_CB=("${TUI_BOX[@]}")
    IFS=$'\x1f' read -r lh key svc <<< "$DASH_PC_M"   # (a hand-made instance folder may have a space in its name)
  else
    dash_center_top "$1" "$2" "$3"
    TUI_BOX=("${DASH_CB[@]}")
    lh="$DASH_CT_LH" key="$DASH_CT_KEY" svc="$DASH_CT_SVC"
    dash_pc_put center "$sig" "$lh"$'\x1f'"$key"$'\x1f'"$svc"
  fi
  if [ "$lh" -ge 5 ]; then
    dash_logs_box "$key" "$svc" "$2" "$lh"
    DASH_CB+=("${TUI_BOX[@]}")
  fi
}

dash_center_top() { # instance width height
  local name="$1" w="$2" h="$3" n st rem R gh sh lh title key svc sf=0
  DASH_CT_LH=0 DASH_CT_KEY="-" DASH_CT_SVC="-"
  [ "$DASH_FOCUS" != "svc" ] || sf=1
  local -a svcs shown=()
  DASH_CB=()
  if [ "$DASH_ON_NEW" -eq 1 ]; then
    dash_new_box "$w" "$h"
    DASH_CB=("${TUI_BOX[@]}")
    return 0
  fi
  if [ -z "$name" ]; then
    dt tui.select_one; shown=("$C_GRY$DTV$C_OFF")
    tui_box "" "$w" "$h" shown
    DASH_CB=("${TUI_BOX[@]}")
    return 0
  fi
  read -ra svcs <<< "${DASH_SVCS[$name]:-}"
  n="${#svcs[@]}"
  # The table carries the totals and the error counts under its rows; the box of next steps exists only when there are some.
  dash_summary_lines "$name"
  dash_svc_table_lines "$name" $((w - 3))
  DASH_TBL+=("${DASH_TOT[@]}")
  st=$((${#DASH_TBL[@]} + 2))
  [ "$st" -ge 5 ] || st=5
  [ "$st" -le $((h - 8)) ] || st=$((h - 8))
  dash_kcol "${DASH_KIND[$name]:-dim}"
  title="$name $UI_S_DOT $DASH_KC${DASH_NM[$name]:-}$C_OFF"
  tui_box "$title" "$w" "$st" DASH_TBL "" "$sf"
  DASH_CB=("${TUI_BOX[@]}")
  rem=$((h - st))
  svc="${svcs[$DASH_SVC]:-${svcs[0]:-}}"
  key="$name/$svc"
  # What goes under the table: charts (2 * rows + 5 lines), the next steps (when there are any) and the logs (at least 6 lines).
  sh=0
  [ "${#DASH_NX[@]}" -eq 0 ] || sh=$((${#DASH_NX[@]} + 2))
  [ "$sh" -le 9 ] || sh=9
  R=$(((rem - 5 - sh - 6) / 2))
  [ "$R" -le 6 ] || R=6
  lh=0
  if [ "$R" -ge 2 ]; then
    gh=$((2 * R + 5)); lh=$((rem - gh - sh))
  else
    R=$(((rem - 5 - sh) / 2))
    if [ "$R" -ge 1 ]; then gh=$((rem - sh)); else R=$(((rem - 5) / 2)); [ "$R" -ge 1 ] || R=1; gh="$rem"; sh=0; fi
  fi
  dash_graph_lines "$key" $((w - 2)) "$R"
  dt tui.lbl.mem; title="$DTV"
  dt tui.lbl.cpu; title="$svc $UI_S_DOT $title/$DTV"
  tui_box "$title" "$w" "$gh" DASH_GL
  DASH_CB+=("${TUI_BOX[@]}")
  if [ "$sh" -ge 3 ]; then
    dt tui.summary.title
    tui_box "$DTV" "$w" "$sh" DASH_NX
    DASH_CB+=("${TUI_BOX[@]}")
  fi
  DASH_CT_LH="$lh" DASH_CT_KEY="$key" DASH_CT_SVC="$svc"
}

# The logs box: the last lines of the service's log (cleaned when they arrived), errors in red and warnings in yellow. With the
# focus it scrolls (the title says how far back it is) and `/` filters the lines by a text (case-insensitive).
dash_logs_box() { # key service width height [focused]
  local key="$1" svc="$2" w="$3" h="$4" foc="${5:-0}" inner n i start end line sig flt="$DASH_LOG_FILTER" title before at after f low ed=0 mark
  local -a body=()
  { [ "$DASH_MODE" = "filter" ] || [ "$DASH_MODE" = "find" ]; } && ed=1
  [ "$DASH_FOCUS" != "logs" ] || foc=1
  sig="$key|$DASH_LOGS_N|$w|$h|$foc|$DASH_LOG_SCROLL|$flt|$DASH_MODE|$TH_NAME|$DASH_LANG_N|$DASH_LOG_ERRONLY|$DASH_LOG_FIND|$DASH_LS_PAUSED|$DASH_LS_PEND|$DASH_LOG_MIDX"
  [ "$ed" -eq 0 ] || sig+="|$DASH_BUF|$DASH_CUR"
  if [ "$sig" = "$DASH_LBOX_SIG" ]; then TUI_BOX=("${DASH_LBOX[@]}"); return 0; fi
  inner=$((h - 2))
  [ "$ed" -eq 0 ] || inner=$((inner - 1))     # one line for the prompt of the filter or of the search
  [ "$inner" -ge 1 ] || inner=1
  DASH_LOG_INNER="$inner"
  f="${DASH_LOG_FIND,,}"
  if [ -z "${DASH_LOGS_AT[$key]+x}" ]; then
    dt tui.logs.loading; body=("$C_GRY$DTV$C_OFF")
  elif [ -z "${DASH_LOGS[$key]}" ]; then
    dt tui.logs.none; body=("$C_GRY$DTV$C_OFF")
  else
    dash_logs_select "$key"
    n="${#DASH_LS_SEL[@]}"
    [ "$DASH_LOG_SCROLL" -le $((n - inner)) ] || DASH_LOG_SCROLL=$((n - inner))   # never past the oldest line
    [ "$DASH_LOG_SCROLL" -ge 0 ] || DASH_LOG_SCROLL=0
    end=$((n - DASH_LOG_SCROLL))
    start=$((end - inner)); [ "$start" -ge 0 ] || start=0
    if [ "$n" -eq 0 ]; then dt tui.logs.no_match; body=("$C_GRY$DTV$C_OFF"); fi
    for ((i = start; i < end; i++)); do
      line="${DASH_LS_SEL[$i]}"
      low="${line,,}"
      dash_log_class_l "$low"
      if [ -n "$f" ]; then dash_log_mark "$line" "$f"; line="$DASH_LH"; fi
      case "$DASH_LC" in
        err) body+=("$C_RED$line$C_OFF") ;;
        warn) body+=("$C_YEL$line$C_OFF") ;;
        *) body+=("$C_GRY$line$C_OFF") ;;
      esac
    done
  fi
  if [ "$ed" -eq 1 ]; then
    before="${DASH_BUF:0:$DASH_CUR}"; at="${DASH_BUF:$DASH_CUR:1}"; after="${DASH_BUF:$((DASH_CUR + 1))}"
    mark="/"; [ "$DASH_MODE" != "find" ] || mark="~"
    while [ "${#body[@]}" -lt "$inner" ]; do body+=(""); done
    if [ -n "$DASH_REV" ]; then body+=("${TH[accent]:-$C_CYN}$mark$C_OFF $before$DASH_REV${at:- }$C_OFF$after"); else body+=("$mark $before|$at$after"); fi
  fi
  dt tui.logs.title; title="$DTV $UI_S_DOT $svc"
  if [ "$DASH_LS_PAUSED" -eq 1 ]; then
    if [ "$DASH_LS_PEND" -gt 0 ]; then dtf tui.logs.paused_n "$DASH_LS_PEND"; else dt tui.logs.paused; DTF="$DTV"; fi
    title+=" $UI_S_DOT $DTF"
  fi
  if [ "$DASH_LOG_ERRONLY" -eq 1 ]; then dt tui.logs.errors; title+=" $UI_S_DOT $DTV"; fi
  [ -z "$flt" ] || title+=" $UI_S_DOT /$flt"
  [ -z "$DASH_LOG_FIND" ] || title+=" $UI_S_DOT ~$DASH_LOG_FIND"
  if [ "$DASH_LOG_SCROLL" -gt 0 ]; then dt tui.logs.scrolled; title+=" $UI_S_DOT ${DTV//\{1\}/$DASH_LOG_SCROLL}"
  elif [ "$DASH_LS_PAUSED" -eq 0 ]; then dt tui.logs.follow; title+=" $UI_S_DOT $DTV"; fi
  tui_box "$title" "$w" "$h" body "" "$foc"
  DASH_LBOX=("${TUI_BOX[@]}") DASH_LBOX_SIG="$sig"
}

# The box about the server: memory bar and chart, load, what the containers use and the Docker version. Result in TUI_BOX.
dash_host_box() { # width height
  local w="$1" h="$2" inner rows used total k chip
  DASH_HB=()
  inner=$((h - 2))
  if [ -n "$MT_HOST_PCT" ]; then
    dt status.hdr.memory
    dash_bar "$MT_HOST_PCT" 10
    dash_gb "$MT_HOST_USED_KB"; used="$DASH_GB"; dash_gb "$MT_HOST_TOTAL_KB"
    DASH_HB+=("$C_GRY$DTV$C_OFF $DASH_BAR $used/$DASH_GB GB $MT_HOST_PCT%")
    rows=$((inner - 3))
    [ "$rows" -le 6 ] || rows=6
    if [ "$rows" -ge 1 ]; then
      gfx_area_cached host "$MT_HOST_HIST" 100 $((w - 3)) "$rows"
      for k in "${!GFX_LINES[@]}"; do
        th_ramp_pct $(((rows - k) * 100 / rows))
        DASH_HB+=("${TH_C:-$C_GRN}${GFX_LINES[$k]}$C_OFF")
      done
    fi
  fi
  if [ -n "$MT_HOST_LOAD" ]; then dt status.hdr.load; DASH_HB+=("$C_GRY$DTV$C_OFF $MT_HOST_LOAD"); fi
  total=0
  for k in "${!MT_MEM[@]}"; do total=$((total + MT_MEM[$k])); done
  if [ "$total" -gt 0 ]; then mt_bytes_v "$total"; dt tui.lbl.containers; DASH_HB+=("$C_GRY$DTV$C_OFF $MT_B"); fi
  [ -z "$DASH_DOCKER_VER" ] || DASH_HB+=("${C_GRY}Docker$C_OFF $DASH_DOCKER_VER")
  dt tui.lbl.host
  tui_box "$DTV" "$w" "$h" DASH_HB
}

# The events box: the newest events at the bottom, with their time, a symbol for what happened and the container.
dash_events_box() { # width height
  local w="$1" h="$2" inner i n ep nm act t sym col start row sig
  local -a body=()
  # Rebuilt only when an event arrived or the size, theme or language changed (not at every sample).
  sig="$DASH_EV_N|$w|$h|$TH_NAME|$DASH_LANG_N"
  if [ "$sig" = "$DASH_EBOX_SIG" ]; then TUI_BOX=("${DASH_EBOX[@]}"); return 0; fi
  inner=$((h - 2))
  n="${#DASH_EVENTS[@]}"
  if [ "$n" -eq 0 ]; then
    dt tui.events.none; body=("$C_GRY$DTV$C_OFF")
  else
    start=$((n - inner)); [ "$start" -ge 0 ] || start=0
    for ((i = start; i < n; i++)); do
      ep="${DASH_EVENTS[$i]%%|*}"; row="${DASH_EVENTS[$i]#*|}"; nm="${row%%|*}"; act="${row#*|}"
      printf -v t '%(%H:%M:%S)T' "$ep"
      case "$act" in
        die | oom | kill | "health_status: unhealthy") sym="${DASH_SYM[err]}"; col="$C_RED" ;;
        start | restart | "health_status: healthy") sym="${DASH_SYM[ok]}"; col="$C_GRN" ;;
        stop | destroy) sym="${DASH_SYM[warn]}"; col="$C_YEL" ;;
        *) sym="${DASH_SYM[dim]}"; col="$C_GRY" ;;
      esac
      body+=("$C_GRY$t$C_OFF $sym $C_BLD$nm$C_OFF $col${act#health_status: }$C_OFF")
    done
  fi
  dt tui.events.title
  tui_box "$DTV" "$w" "$h" body
  DASH_EBOX=("${TUI_BOX[@]}") DASH_EBOX_SIG="$sig"
}

# The whole overview body into TUI_FRAME ($1 lines).
dash_view_overview() { # body_height
  local bh="$1" lw=38 ew cw cs top name i lh hh n="${#DASH_NAMES[@]}" lf=0 sig
  [ "$DASH_FOCUS" != "list" ] || lf=1
  local -a left=() center=() right=()
  name="${DASH_NAMES[$DASH_SEL]:-}"
  # Columns: the list is fixed (wider on a wide terminal), the centre takes the rest but never less than 76, and the events column
  # (36) only exists when it fits next to that.
  [ "$TUI_COLS" -lt 160 ] || lw=42
  lay_split "$TUI_COLS" "$lw:$lw:$lw" "0:76::1" "36:36:36:0:1"
  lw="${LAY[0]}" cw="${LAY[1]}" ew="${LAY[2]}"
  # Rows: the panes grow, the console asks for 8 rows (22 % of a tall terminal, at most 16).
  cs=8
  [ "$bh" -lt 40 ] || cs=$((bh * 22 / 100))
  [ "$cs" -le 16 ] || cs=16
  lay_split "$bh" "0:0::1" "$cs:$cs:$cs"
  top="${LAY[0]}" cs="${LAY[1]}"
  # Left: the list asks for a row per instance (at least 6, at most 40 % of the rows); the server box takes the rest and is
  # dropped when it would have less than 6.
  lay_split "$top" "$((n + 4)):6:$((top * 40 / 100))" "0:6::1:1"
  lh="${LAY[0]}" hh="${LAY[1]}"
  dash_list_box "$lw" "$lh" $((lw - 3)) "$lf"; left=("${TUI_BOX[@]}")
  DASH_LIST_SHOWN=1 DASH_LIST_W="$lw"
  if [ "$hh" -gt 0 ]; then
    sig="$lw|$hh|$MT_SAMPLES|$DASH_REFRESH_N|$DASH_LANG_N|$DASH_DOCKER_VER"
    dash_pc_get host "$sig" || { dash_host_box "$lw" "$hh"; dash_pc_put host "$sig"; }
    left+=("${TUI_BOX[@]}")
  fi
  dash_center_boxes "$name" "$cw" "$top"; center=("${DASH_CB[@]}")
  if [ "$ew" -gt 0 ]; then dash_events_box "$ew" "$top"; right=("${TUI_BOX[@]}"); fi
  for ((i = 0; i < top; i++)); do TUI_FRAME+=("${left[$i]}${center[$i]:-}${right[$i]:-}"); done
  dash_console_box "$TUI_COLS" "$cs"
  TUI_FRAME+=("${TUI_BOX[@]}")
}

# --- Zoom ------------------------------------------------------------------------------------------------------------
# `z` gives the whole body to the focused pane: the list, the services of the instance, or its logs (a log viewer).
dash_view_zoom() { # body_height
  local bh="$1" name key svc
  name="${DASH_NAMES[$DASH_SEL]:-}"
  if [ "$DASH_ON_NEW" -eq 1 ]; then
    dash_new_box "$TUI_COLS" "$bh"
  else
    case "$DASH_FOCUS" in
      list)
        dash_list_lines $((bh - 2)) $((TUI_COLS - 3))
        DASH_LIST_SHOWN=1 DASH_LIST_W="$TUI_COLS"
        dt tui.instances
        tui_box "$DTV" "$TUI_COLS" "$bh" DASH_LIST_LINES "" 1
        ;;
      logs)
        if dash_current_target; then
          dash_logs_box "$DASH_T_INST/$DASH_T_SVC" "$DASH_T_SVC" "$TUI_COLS" "$bh" 1
        else
          dash_detail_box "$name" "$TUI_COLS" "$bh"
        fi
        ;;
      *) dash_detail_box "$name" "$TUI_COLS" "$bh" ;;
    esac
  fi
  TUI_FRAME+=("${TUI_BOX[@]}")
}

DASH_T_INST="" DASH_T_SVC=""

# The list of instances has one more position than instances: the "New instance" button, at the top. Up and down walk the
# whole ring (button, instance 1, ..., instance n, button).
dash_select() { # delta
  local n="${#DASH_NAMES[@]}" pos
  if [ "$DASH_ON_NEW" -eq 1 ]; then pos=0; else pos=$((DASH_SEL + 1)); fi
  pos=$(((pos + n + 1 + $1) % (n + 1)))
  if [ "$pos" -eq 0 ]; then
    DASH_ON_NEW=1
  else
    DASH_ON_NEW=0 DASH_SEL=$((pos - 1))
  fi
  DASH_SVC=0 DASH_DET_OFF=0 DASH_FOCUS=list
}

dash_select_service() { # delta
  local -a svcs
  [ "$DASH_ON_NEW" -eq 0 ] && [ "${#DASH_NAMES[@]}" -gt 0 ] || return 0
  read -ra svcs <<< "${DASH_SVCS[${DASH_NAMES[$DASH_SEL]}]:-}"
  [ "${#svcs[@]}" -gt 0 ] || return 0
  DASH_SVC=$(((DASH_SVC + ${#svcs[@]} + $1) % ${#svcs[@]}))
}

# Right arrow: the focus goes from the list of instances into the services of the selected instance.
dash_focus_services() {
  local -a svcs
  [ "$DASH_ON_NEW" -eq 0 ] && [ "${#DASH_NAMES[@]}" -gt 0 ] || return 0
  read -ra svcs <<< "${DASH_SVCS[${DASH_NAMES[$DASH_SEL]}]:-}"
  [ "${#svcs[@]}" -gt 0 ] || return 0
  DASH_FOCUS=svc
}

# Service of the selected instance as "instance service" (empty when there is none).
dash_current_target() {
  local name svc
  local -a svcs
  [ "$DASH_ON_NEW" -eq 0 ] || return 1
  [ "${#DASH_NAMES[@]}" -gt 0 ] || return 1
  name="${DASH_NAMES[$DASH_SEL]}"
  read -ra svcs <<< "${DASH_SVCS[$name]:-}"
  [ "${#svcs[@]}" -gt 0 ] || return 1
  svc="${svcs[$DASH_SVC]:-${svcs[0]}}"
  DASH_T_INST="$name" DASH_T_SVC="$svc"
}

# Two places can have the focus: the list of instances (up/down choose an instance; right enters its services) and the services
# of the selected instance (up/down choose a service; left or Esc go back to the list). The first row of the list is the
# "New instance" button.
dash_key_instances() {
  local have=1
  { [ "$DASH_ON_NEW" -eq 0 ] && [ "${#DASH_NAMES[@]}" -gt 0 ]; } || have=0
  if [ "$DASH_FOCUS" = "logs" ] && dash_key_logs "$1"; then return 0; fi
  case "$1" in
    z) dash_toggle_zoom ;;
    up | k) if [ "$DASH_FOCUS" = "svc" ]; then dash_select_service -1; else dash_select -1; fi ;;
    down | j) if [ "$DASH_FOCUS" = "svc" ]; then dash_select_service 1; else dash_select 1; fi ;;
    left | h) DASH_FOCUS=list ;;
    right) if [ "$DASH_FOCUS" = "svc" ]; then dash_focus_logs; else dash_focus_services; fi ;;
    enter)
      if [ "$DASH_ON_NEW" -eq 1 ]; then dash_open_new
      elif [ "$have" -eq 1 ]; then dash_open_actions "${DASH_NAMES[$DASH_SEL]}"; fi
      ;;
    l) [ "$have" -eq 0 ] || { dash_current_target && dash_start_job output logs "$DASH_T_INST" "$DASH_T_SVC" -f; } ;;
    u) [ "$have" -eq 0 ] || dash_start_job stay deploy "${DASH_NAMES[$DASH_SEL]}" ;;
    c) [ "$have" -eq 0 ] || dash_start_job stay check "${DASH_NAMES[$DASH_SEL]}" ;;
    s) [ "$have" -eq 0 ] || dash_start_job output status "${DASH_NAMES[$DASH_SEL]}" ;;
    e) [ "$have" -eq 0 ] || dash_errors_request "${DASH_NAMES[$DASH_SEL]}" ;;
  esac
}

dash_focus_cycle() { # +1 | -1
  local -a order=(list)
  local i cur=0 n
  { [ "$DASH_ON_NEW" -eq 0 ] && [ "${#DASH_NAMES[@]}" -gt 0 ]; } || { DASH_FOCUS=list; return 0; }
  order+=(svc)
  if dash_overview_fits; then order+=(logs); fi
  n="${#order[@]}"
  for i in "${!order[@]}"; do [ "${order[$i]}" != "$DASH_FOCUS" ] || cur="$i"; done
  DASH_FOCUS="${order[$(((cur + n + $1) % n))]}"
}

# Right arrow from the services: on to the logs (they only exist on the wide layout).
dash_focus_logs() { if dash_overview_fits; then DASH_FOCUS=logs; fi; }

dash_toggle_zoom() {
  [ "$DASH_VIEW" = "instances" ] || return 0
  if [ "$DASH_FOCUS" = "logs" ] && ! dash_overview_fits; then return 0; fi
  DASH_ZOOM=$((1 - DASH_ZOOM))
}

# Keys of the logs pane: scroll by line or page, Home/End, `/` to filter. Returns 0 when it handled the key.
dash_key_logs() { # key
  local page=$((TUI_ROWS / 2))
  case "$1" in
    up | k) DASH_LOG_SCROLL=$((DASH_LOG_SCROLL + 1)) ;;
    down | j) [ "$DASH_LOG_SCROLL" -le 0 ] || DASH_LOG_SCROLL=$((DASH_LOG_SCROLL - 1)) ;;
    pgup) DASH_LOG_SCROLL=$((DASH_LOG_SCROLL + page)) ;;
    pgdn) DASH_LOG_SCROLL=$((DASH_LOG_SCROLL - page)); [ "$DASH_LOG_SCROLL" -ge 0 ] || DASH_LOG_SCROLL=0 ;;
    home) DASH_LOG_SCROLL=100000 ;;           # clamped to the oldest line when drawn
    end | G | f)                              # follow the end again (and resume, if it was paused)
      DASH_LOG_SCROLL=0 DASH_LOG_MIDX=-1
      [ "$DASH_LS_PAUSED" -eq 0 ] || dash_logs_pause_toggle
      ;;
    space | ' ') dash_logs_pause_toggle ;;
    e) DASH_LOG_ERRONLY=$((1 - DASH_LOG_ERRONLY)) DASH_LOG_SCROLL=0 DASH_LOG_MIDX=-1 ;;
    '/') DASH_MODE=filter DASH_BUF="$DASH_LOG_FILTER" DASH_CUR="${#DASH_LOG_FILTER}" ;;
    s) DASH_MODE=find DASH_BUF="$DASH_LOG_FIND" DASH_CUR="${#DASH_LOG_FIND}" ;;
    ']') dash_logs_jump 1 ;;
    '[') dash_logs_jump -1 ;;
    left | h) DASH_FOCUS=svc ;;
    *) return 1 ;;
  esac
  return 0
}

# --- The contract of lib/screens/registry.sh --------------------------------------------------------------------
scr_instances_render() { # width height
  if [ "$DASH_ZOOM" -eq 1 ]; then dash_view_zoom "$2"
  elif dash_overview_fits; then dash_view_overview "$2"
  else dash_view_instances "$2"; fi
}

scr_instances_key() { dash_key_instances "$1"; }

# The hints follow the focus: on the New button, inside the services, or on the list of instances.
scr_instances_keys() { # width
  local kv=instances
  if [ "$DASH_ZOOM" -eq 1 ]; then kv=zoom
  elif [ "$DASH_ON_NEW" -eq 1 ]; then kv=new
  elif [ "$DASH_FOCUS" = "svc" ]; then kv=services
  elif [ "$DASH_FOCUS" = "logs" ]; then kv=logs; fi
  dash_keys_view "$kv" "$1"
}

scr_instances_texts() {
  DASH_KEYS[instances]="$(t tui.keys.instances "$DASH_UD" "$DASH_RIGHT")"
  DASH_KEYS[services]="$(t tui.keys.services "$DASH_UD" "$DASH_LEFT")"
  DASH_KEYS[new]="$(t tui.keys.new "$DASH_UD")"
  DASH_KEYS[logs]="$(t tui.keys.logs "$DASH_UD" "$DASH_LEFT")"
  DASH_KEYS[zoom]="$(t tui.keys.zoom "$DASH_UD")"
}

scr_instances_sig() {
  DASH_SIG+="|$DASH_SEL|$DASH_SVC|$DASH_FOCUS|$DASH_ON_NEW|$DASH_ZOOM|$DASH_LOG_SCROLL|$DASH_LOG_FILTER"
  DASH_SIG+="|$DASH_LOG_ERRONLY|$DASH_LOG_FIND|$DASH_LS_PAUSED|$DASH_LS_PEND|$DASH_LOG_MIDX"
}

# Tab walks the panes (list, services, logs) instead of leaving the view.
scr_instances_tab() { dash_focus_cycle "$1"; }

# Esc: the zoom first, then one step back to the list; with nothing left to close it returns 1 (the router then quits).
scr_instances_back() {
  if [ "$DASH_ZOOM" -eq 1 ]; then DASH_ZOOM=0
  elif [ "$DASH_FOCUS" != "list" ]; then DASH_FOCUS=list
  else return 1; fi
}

scr_instances_tick() { dash_ls_tick; }

scr_instances_poll() {
  # The log tail of the selected service: only while the overview shows it, and every 5 s.
  if dash_overview_fits && dash_current_target; then
    local lk="$DASH_T_INST/$DASH_T_SVC"
    # While the user reads older lines the log stands still (no new request); a focused pane refreshes faster.
    local every=5
    [ "$DASH_FOCUS" != "logs" ] || every=3
    # (a stream feeds the pane when there is one; paused, the pane stands still)
    if [ "${ST_STATE[$lk]:-}" = "running" ] && [ "$DASH_LOG_SCROLL" -eq 0 ] && [ "$DASH_LS_PAUSED" -eq 0 ] && ! dash_ls_active "$lk" && { [ -z "${DASH_LOGS_AT[$lk]:-}" ] || [ $((SECONDS - DASH_LOGS_AT[$lk])) -ge "$every" ]; }; then
      dash_logs_request "$lk"
    fi
  fi
  # Error counts of the selected instance: when the user pauses on it, then every 30 s.
  if [ "$DASH_IDLE" -eq 1 ] && [ "$DASH_ON_NEW" -eq 0 ] && [ "${#DASH_NAMES[@]}" -gt 0 ]; then
    local sel="${DASH_NAMES[$DASH_SEL]}"
    if [ -z "${DASH_ERRS_AT[$sel]:-}" ] || [ $((SECONDS - DASH_ERRS_AT[$sel])) -ge $((DASH_AWAY == 1 ? 120 : 30)) ]; then dash_errors_request "$sel"; fi
  fi
}

# A click on the list: the New button, or an instance (a second click on the selected one opens its actions).
scr_instances_click() { # column row
  local x="$1" y="$2" j i n="${#DASH_NAMES[@]}"
  { [ "$DASH_LIST_SHOWN" -eq 1 ] && [ "$x" -le "$DASH_LIST_W" ]; } || return 0
  if [ "$y" -eq 4 ]; then
    if [ "$DASH_ON_NEW" -eq 1 ] && [ "$DASH_FOCUS" = "list" ]; then dash_key_instances enter; else DASH_ON_NEW=1 DASH_SVC=0 DASH_DET_OFF=0 DASH_FOCUS=list; fi
    return 0
  fi
  [ "$n" -gt 0 ] || return 0
  j=$((y - 6))
  { [ "$j" -ge 0 ] && [ "$j" -lt "$DASH_LIST_AVAIL" ]; } || return 0
  i=$((DASH_LIST_START + j))
  [ "$i" -lt "$n" ] || return 0
  if [ "$DASH_ON_NEW" -eq 0 ] && [ "$i" -eq "$DASH_SEL" ] && [ "$DASH_FOCUS" = "list" ]; then dash_key_instances enter; return 0; fi
  DASH_ON_NEW=0 DASH_SEL="$i" DASH_SVC=0 DASH_DET_OFF=0 DASH_FOCUS=list
}

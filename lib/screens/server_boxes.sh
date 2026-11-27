#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2154  # the DASH_* variables are declared in lib/cmd/dashboard*.sh and lib/screens/server.sh and shared
# The boxes of the figures of the Server view (lib/screens/server.sh sources this file): CPU, memory, disks, network and containers. Each one is
# dash_srv_<name> <width> <height>, leaves its lines in DASH_SRV_BOX and is built from the figures already in memory (lib/core/metrics.sh,
# lib/adapters/host.sh): it starts no process. While DASH_SRV_ZM is 1 the box is drawn zoomed (z): it shows everything it has (all the cores,
# all the mounts and disks, all the interfaces, all the columns of the containers), because the whole body is its own.
#
# Every graph is a kit_graph_cached with its own id (a new sample moves it one cell at most) and, when the box is tall enough, a time axis
# ("-8 min ──── now") and the minimum, mean and maximum of what it shows. What does not fit is cut with "+N more", never silently.

# --- Pieces ---------------------------------------------------------------------------------------------------------------------

# The first $2 lines of the array named $1 into DASH_SRV_W; when there are more, the last line says how many were left out (DASH_SRV_WN).
DASH_SRV_W=() DASH_SRV_WN=0
dash_srv_win() { # array height
  local -n _src="$1"
  local h="$2" n="${#_src[@]}" keep
  DASH_SRV_W=() DASH_SRV_WN=0
  [ "$h" -gt 0 ] || return 0
  if [ "$n" -le "$h" ]; then DASH_SRV_W=("${_src[@]}"); return 0; fi
  keep=$((h - 1))
  DASH_SRV_WN=$((n - keep))
  [ "$keep" -le 0 ] || DASH_SRV_W=("${_src[@]:0:keep}")
  dash_srv_t tui.srv.more "$DASH_SRV_WN"
  DASH_SRV_W+=("${TH[dim]:-}$DASH_T$TH_RESET")
}

# Minimum, mean and maximum of the last $2 values of a history into DASH_ST_MIN, DASH_ST_AVG and DASH_ST_MAX (DASH_ST_N values counted).
DASH_ST_MIN=0 DASH_ST_AVG=0 DASH_ST_MAX=0 DASH_ST_N=0
dash_srv_stats() { # history samples
  local -a v
  local n i start x sum=0 mn=-1 mx=0 cnt=0
  DASH_ST_MIN=0 DASH_ST_AVG=0 DASH_ST_MAX=0 DASH_ST_N=0
  [ -n "$1" ] || return 0
  v=($1)
  n="${#v[@]}"
  start=0
  [ "$n" -le "$2" ] || start=$((n - $2))
  for ((i = start; i < n; i++)); do
    x="${v[$i]}"
    [[ "$x" =~ ^[0-9]+$ ]] || continue
    sum=$((sum + x)) cnt=$((cnt + 1))
    if [ "$mn" -lt 0 ] || [ "$x" -lt "$mn" ]; then mn="$x"; fi
    [ "$x" -le "$mx" ] || mx="$x"
  done
  [ "$cnt" -gt 0 ] || return 0
  DASH_ST_MIN="$mn" DASH_ST_MAX="$mx" DASH_ST_AVG=$((sum / cnt)) DASH_ST_N="$cnt"
}

# A figure of a history in the unit of its graph (pct, bytes per second, hund: hundredths of a load) into DASH_FV.
DASH_FV=""
dash_srv_fmtv() { # kind value
  case "$1" in
    bytes) dash_srv_b "$2"; DASH_FV="$DASH_SZ/s" ;;
    hund) printf -v DASH_FV '%d.%02d' $(($2 / 100)) $(($2 % 100)) ;;
    *) DASH_FV="$2%" ;;
  esac
}

# How long the samples drawn cover, from the interval between samples, into DASH_SPAN ("-8 min").
DASH_SPAN=""
dash_srv_span() { # samples
  local iv=$((${MT_INTERVAL_US:-2000000} / 1000000)) secs
  [ "$iv" -ge 1 ] || iv=2
  secs=$(($1 * iv))
  if [ "$secs" -ge 7200 ]; then DASH_SPAN="-$((secs / 3600)) h"
  elif [ "$secs" -ge 120 ]; then DASH_SPAN="-$((secs / 60)) min"
  else DASH_SPAN="-$secs s"; fi
}

# A graph with its axis and its figures, $5 lines in all, into DASH_CH: from 6 lines the graph, the time axis and "min · mean · max"; from 4 the
# graph and the axis; fewer, the graph alone. The scale is $3 (a number, or auto); KG_MAX is left as kit_graph_cached found it.
DASH_CH=()
dash_srv_chart() { # id history max width rows magnitude kind
  local id="$1" hist="$2" max="$3" w="$4" rows="$5" mag="$6" kind="$7" gr="$5" ax=0 st=0 shown pad left right a b c
  local -a v
  DASH_CH=()
  { [ "$rows" -gt 0 ] && [ "$w" -gt 0 ]; } || return 0
  if [ "$rows" -ge 6 ]; then gr=$((rows - 2)) ax=1 st=1; elif [ "$rows" -ge 4 ]; then gr=$((rows - 1)) ax=1; fi
  kit_graph_cached "$id" "$hist" "$max" "$w" "$gr" "mag=$mag" zero=1
  DASH_CH=("${KG_LINES[@]}")
  [ "$ax" -eq 1 ] || return 0
  v=($hist)
  shown="${#v[@]}"
  [ "$shown" -le $((w * 2)) ] || shown=$((w * 2))
  dash_srv_span "$shown"; left="$DASH_SPAN"
  dt tui.srv.now; right="$DTV"
  pad=$((w - ${#left} - ${#right} - 2))
  if [ "$pad" -ge 2 ]; then
    tui_rep "$UI_S_RULE" "$pad"
    DASH_CH+=("${TH[dim]:-}$left $TUI_OUT $right$TH_RESET")
  else
    tui_fit "${TH[dim]:-}$right$TH_RESET" "$w"; DASH_CH+=("$TUI_OUT")
  fi
  [ "$st" -eq 1 ] || return 0
  dash_srv_stats "$hist" "$shown"
  dash_srv_fmtv "$kind" "$DASH_ST_MIN"; a="$DASH_FV"
  dash_srv_fmtv "$kind" "$DASH_ST_AVG"; b="$DASH_FV"
  dash_srv_fmtv "$kind" "$DASH_ST_MAX"; c="$DASH_FV"
  dash_srv_t tui.srv.stat "$a" "$b" "$c"
  tui_fit "${TH[dim]:-}$DASH_T$TH_RESET" "$w"; DASH_CH+=("$TUI_OUT")
}

# Two labelled figures side by side in $5 cells into DASH_PAIR: "label ···· value  label ···· value".
DASH_PAIR=""
dash_srv_pair() { # label1 value1 label2 value2 width
  local hw=$(($5 / 2 - 1)) a
  kit_leader "$1" "$2" "$hw"; a="$KIT_OUT"
  kit_leader "$3" "$4" $(($5 - hw - 2))
  DASH_PAIR="$a  $KIT_OUT"
}

# A bar of the memory as btop draws it: what is used (the gradient of its magnitude), the cache (what the kernel keeps but gives back) and what
# is free, in $1 cells, into DASH_STK.
DASH_STK=""
dash_srv_stack() { # width used cache total
  local w="$1" used="$2" cache="$3" total="$4" u c f on mid off pct
  if [ "${UI_UTF8:-0}" -eq 1 ] && [ "${UI_RICH:-0}" -eq 1 ]; then on="█" mid="▒" off="░"; else on="#" mid="=" off="."; fi
  [ "$total" -gt 0 ] || total=1
  u=$((used * w / total)); c=$((cache * w / total))
  [ "$u" -le "$w" ] || u="$w"
  [ $((u + c)) -le "$w" ] || c=$((w - u))
  f=$((w - u - c))
  pct=$((used * 100 / total))
  th_grad mem "$pct"
  tui_rep "$on" "$u"; DASH_STK="$TH_C$TUI_OUT$TH_RESET"
  tui_rep "$mid" "$c"; DASH_STK+="${TH[info]:-}$TUI_OUT$TH_RESET"
  tui_rep "$off" "$f"; DASH_STK+="${TH[track]:-}$TUI_OUT$TH_RESET"
}

# The load of one minute, five and fifteen with the trend of the first and what each core carries, into DASH_LOADL.
DASH_LOADL=""
dash_srv_loadline() { # cores
  local l1 l5 trend per
  dash_srv_glyphs
  dash_srv_hund "$HOST_LOAD1"; l1="$DASH_HU"
  dash_srv_hund "$HOST_LOAD5"; l5="$DASH_HU"
  trend="$UI_S_FLAT"
  if [ $((l1 * 10)) -gt $((l5 * 11)) ]; then trend="$UI_S_RISE"; elif [ $((l1 * 11)) -lt $((l5 * 10)) ]; then trend="$UI_S_FALL"; fi
  dt tui.srv.load
  DASH_LOADL="${TH[dim]:-}$DTV$TH_RESET $HOST_LOAD1$trend $HOST_LOAD5 $HOST_LOAD15"
  if [ "$1" -gt 0 ]; then
    printf -v per '%d.%02d' $((l1 / $1 / 100)) $((l1 / $1 % 100))
    dash_srv_t tui.srv.loadcore "$per"; DASH_LOADL+=" ${TH[dim]:-}$UI_S_DOT $DASH_T$TH_RESET"
  fi
}

# A line that says a figure is not there: not available on this system, or not read yet.
dash_srv_note() { # kind(na|waiting)
  if [ "$1" = "na" ]; then dt tui.srv.na; else dt tui.srv.waiting; fi
  DASH_SRV_L=("${TH[dim]:-}$DTV$TH_RESET")
}

# The degrees sign for the temperature chip and the arrows of the network and disk speeds.
DASH_DEG="" DASH_DN="" DASH_UPA=""
dash_srv_glyphs() {
  if [ "${UI_UTF8:-0}" -eq 1 ]; then
    DASH_DEG="°C" DASH_DN="▼" DASH_UPA="▲" UI_S_RISE="↗" UI_S_FALL="↘" UI_S_FLAT="→"
  else
    DASH_DEG=" C" DASH_DN="v" DASH_UPA="^" UI_S_RISE="^" UI_S_FALL="v" UI_S_FLAT="="
  fi
}

# Rows of the box being built (DASH_SRV_L) and the chips and status it gets; the result is left in DASH_SRV_BOX. The box that has the focus is
# drawn as focused, and one with a warning takes the colour of it in its border.
DASH_SRV_L=() DASH_SRV_BOX=()
dash_srv_mbox() { # name width height [status] [chips-extra]
  local title foc=0 col=""
  dt "tui.srv.title.$1"; title="$DTV"
  [ -z "${5:-}" ] || title+="|$5"
  [ "$DASH_SRV_FOCUS" != "$1" ] || foc=1
  case "${DASH_SRV_AL[$1]:-0}" in 2) col="${TH[err]:-}" ;; 1) col="${TH[warn]:-}" ;; esac
  kit_box "$2" "$3" DASH_SRV_L "chips=$title" "status=${4:-}" "focus=$foc" ${col:+"color=$col"}
  DASH_SRV_BOX=("${KIT_BOX[@]}")
}

# --- CPU ------------------------------------------------------------------------------------------------------------------------

# The total with a graph (its axis and figures) and, when the box is wide enough, the cores in a grid at its right ("+N more" when they do not all
# fit). Zoomed it also draws the history of the load, the temperature and the pressure of the kernel.
dash_srv_cpu() { # width height
  local w="$1" h="$2" cw=$(($1 - 4)) ch=$(($2 - 2)) zm="$DASH_SRV_ZM" status="" n i r c k nc rows gw gridw ncmax lc lr cell lbl pad p hid line l rr
  local -a left=() right=() cores=()
  DASH_SRV_L=()
  dash_srv_glyphs
  [ -z "$HOST_TEMP_CPU_C" ] || [ "${MT_SRC[temp]:-0}" != 1 ] || status="$HOST_TEMP_CPU_C$DASH_DEG"
  if [ "${MT_SRC[cpu]:-}" = "0" ]; then dash_srv_note na; dash_srv_mbox cpu "$w" "$h"; return 0; fi
  if [ -z "${MT_CPU_ALL:-}" ]; then dash_srv_note waiting; dash_srv_mbox cpu "$w" "$h"; return 0; fi
  n=$((${#MT_CORE_PCT[@]} - 1))   # (index 0 is the whole CPU)
  local total pad
  kit_meter "$MT_CPU_ALL" 5 cpu
  printf -v pad '%3d' "$MT_CPU_ALL"
  total="CPU$KIT_OUT $pad%"
  local loadl=""
  if [ -n "${HOST_LOAD1:-}" ] && [ "${MT_SRC[load]:-0}" = 1 ]; then dash_srv_loadline "$n"; loadl="$DASH_LOADL"; fi
  ncmax=$(((cw - 29) / 15))
  if [ "$ch" -ge 6 ] && [ "$ncmax" -ge 1 ] && [ "$n" -gt 0 ]; then
    # --- with the grid of cores at the right: the graph on the left, one cell wide per 15 cells of the grid
    rows=$((ch - 1))
    nc=$(((n + rows - 1) / rows))
    [ "$nc" -le "$ncmax" ] || nc="$ncmax"
    [ "$nc" -ge 1 ] || nc=1
    gridw=$((nc * 15 - 2)); gw=$((cw - gridw - 1))
    for ((i = 1; i <= n; i++)); do
      printf -v lbl 'C%-2d' $((i - 1))
      p="${MT_CORE_PCT[$i]}"
      kit_meter "$p" 5 cpu
      printf -v pad '%3d' "$p"
      cores+=("$lbl$KIT_OUT $pad%")
    done
    right=("$total")
    hid=0
    if [ "$n" -gt $((nc * rows)) ]; then hid=$((n - nc * rows + 1)); fi
    for ((r = 0; r < rows; r++)); do
      line=""
      for ((c = 0; c < nc; c++)); do
        k=$((r * nc + c))
        if [ "$hid" -gt 0 ] && [ "$k" -eq $((nc * rows - 1)) ]; then
          dash_srv_t tui.srv.more "$hid"; cell="${TH[dim]:-}$DASH_T$TH_RESET"
        elif [ "$k" -lt "$n" ]; then cell="${cores[$k]}"
        else cell=""; fi
        tui_fit "$cell" 13
        line+="${line:+  }$TUI_OUT"
      done
      right+=("$line")
    done
    # The left column: the load, then the graph(s).
    left=()
    [ -z "$loadl" ] || left+=("$loadl")
    # (zoomed: what the box can say besides the figures, the temperature and the pressure of the kernel, in a line of its own)
    if [ "$zm" -eq 1 ]; then
      l=""
      if [ -n "$HOST_TEMP_CPU_C" ] && [ "${MT_SRC[temp]:-0}" = 1 ]; then dash_srv_t tui.srv.temp "$HOST_TEMP_CPU_C$DASH_DEG"; l="$DASH_T"; fi
      if [ "${MT_SRC[psi]:-0}" = 1 ] && [ -n "$HOST_PSI_CPU" ]; then dash_srv_t tui.srv.psi "$HOST_PSI_CPU"; else dt tui.srv.psi.na; DASH_T="$DTV"; fi
      l+="${l:+ · }$DASH_T"
      [ -z "$l" ] || left+=("${TH[dim]:-}$l$TH_RESET")
    fi
    lr=$((ch - ${#left[@]}))
    if [ "$zm" -eq 1 ] && [ "$lr" -ge 14 ] && [ -n "$MT_HH_LOAD" ]; then
      lc=$((lr * 3 / 5))
      dash_srv_chart srv_cpu "$MT_HH_CPU" 100 "$gw" "$lc" cpu pct; left+=("${DASH_CH[@]}")
      kit_scale "$MT_HH_LOAD" 100
      dash_srv_chart srv_load "$MT_HH_LOAD" "$KG_MAX" "$gw" $((lr - lc)) cpu hund; left+=("${DASH_CH[@]}")
    else
      dash_srv_chart srv_cpu "$MT_HH_CPU" 100 "$gw" "$lr" cpu pct; left+=("${DASH_CH[@]}")
    fi
    for ((i = 0; i < ch; i++)); do
      dash_srv_fit "${left[$i]:-}" "$gw"; l="$TUI_OUT"
      tui_fit "${right[$i]:-}" "$gridw"; rr="$TUI_OUT"
      DASH_SRV_L+=("$l $rr")
    done
  else
    # --- narrow or short: the total, the load and the graph
    kit_meter "$MT_CPU_ALL" $((cw > 40 ? 24 : cw - 12)) cpu caps=1
    DASH_SRV_L+=("CPU $KIT_OUT ${MT_CPU_ALL}%")
    dash_srv_t tui.srv.cores "$n"
    if [ -n "$loadl" ]; then tui_fit "$loadl ${TH[dim]:-}$UI_S_DOT $DASH_T$TH_RESET" "$cw"; else tui_fit "${TH[dim]:-}$DASH_T$TH_RESET" "$cw"; fi
    DASH_SRV_L+=("$TUI_OUT")
    if [ $((ch - 2)) -ge 2 ]; then
      dash_srv_chart srv_cpu "$MT_HH_CPU" 100 "$cw" $((ch - 2)) cpu pct
      DASH_SRV_L+=("${DASH_CH[@]}")
    fi
  fi
  dash_srv_mbox cpu "$w" "$h" "$status"
}

# --- Memory ---------------------------------------------------------------------------------------------------------------------

# The memory by kind: a bar with what is used, the cache and what is free, the figures (in pairs when the box is wide), the swap, what the kernel
# says about the pressure and the processes killed for lack of memory, and the history of what is used with its axis.
dash_srv_mem() { # width height
  local w="$1" h="$2" cw=$(($1 - 4)) ch=$(($2 - 2)) zm="$DASH_SRV_ZM" pct sw pad used avail total cached free two=0 r a b c swu
  local -a L=()
  DASH_SRV_L=()
  if [ "${MT_SRC[mem]:-}" = "0" ]; then dash_srv_note na; dash_srv_mbox mem "$w" "$h"; return 0; fi
  if [ -z "${MT_SRC[mem]:-}" ]; then dash_srv_note waiting; dash_srv_mbox mem "$w" "$h"; return 0; fi
  if [ -z "$HOST_MEMD_TOTAL" ] || [ -z "$HOST_MEMD_USED" ] || [ "$HOST_MEMD_TOTAL" -eq 0 ]; then dash_srv_note na; dash_srv_mbox mem "$w" "$h"; return 0; fi
  total="$HOST_MEMD_TOTAL" used="$HOST_MEMD_USED" avail="${HOST_MEMD_AVAIL:-0}" cached="${HOST_MEMD_CACHED:-0}" free="${HOST_MEMD_FREE:-0}"
  pct=$((used * 100 / total))
  [ "$cw" -lt 58 ] || two=1
  # (the labels and the figures: one per line when narrow, two by two when wide)
  dash_srv_kb "$used"; local su="$DASH_SZ"; dash_srv_kb "$total"; local st="$DASH_SZ"
  dash_srv_kb "$avail"; local sa="$DASH_SZ"; dash_srv_kb "$cached"; local sc="$DASH_SZ"; dash_srv_kb "$free"; local sf="$DASH_SZ"
  local lu la lt lc lf
  dt tui.srv.mem.used; lu="$DTV"; dt tui.srv.mem.avail; la="$DTV"; dt tui.srv.mem.total; lt="$DTV"; dt tui.srv.mem.cached; lc="$DTV"; dt tui.srv.mem.free; lf="$DTV"
  printf -v pad '%3d' "$pct"
  if [ "$two" -eq 1 ]; then
    dash_srv_pair "$lu" "$su" "$lt" "$st" "$cw"; L+=("$DASH_PAIR")
  else
    kit_leader "$lu" "$su" "$cw"; L+=("$KIT_OUT")
  fi
  dash_srv_stack $((cw - 5)) "$used" "$cached" "$total"; L+=("$DASH_STK $pad%")
  if [ "$two" -eq 1 ]; then
    dash_srv_pair "$la" "$sa" "$lc" "$sc" "$cw"; L+=("$DASH_PAIR")
    kit_leader "$lf" "$sf" "$cw"; L+=("$KIT_OUT")
  else
    kit_leader "$la" "$sa" "$cw"; L+=("$KIT_OUT")
    kit_leader "$lt" "$st" "$cw"; L+=("$KIT_OUT")
    kit_leader "$lc" "$sc" "$cw"; L+=("$KIT_OUT")
    kit_leader "$lf" "$sf" "$cw"; L+=("$KIT_OUT")
  fi
  if [ -n "$HOST_MEMD_SWAP_TOTAL" ] && [ "$HOST_MEMD_SWAP_TOTAL" -gt 0 ]; then
    swu="${HOST_MEMD_SWAP_USED:-0}"
    sw=$((swu * 100 / HOST_MEMD_SWAP_TOTAL))
    dash_srv_kb "$HOST_MEMD_SWAP_TOTAL"; dt tui.srv.mem.swap; kit_leader "$DTV" "$DASH_SZ" "$cw"; L+=("$KIT_OUT")
    printf -v pad '%3d' "$sw"
    kit_meter "$sw" $((cw - 5)) mem; L+=("$KIT_OUT $pad%")
  fi
  # What the kernel says: pressure, pages swapped since the last reading, processes killed for lack of memory.
  a="-" b="-" c="-"
  [ "${MT_SRC[psi]:-0}" != 1 ] || [ -z "$HOST_PSI_MEM" ] || a="$HOST_PSI_MEM%"
  [ "${MT_SRC[vm]:-0}" != 1 ] || [ -z "$HOST_VM_SWAP_D" ] || b="$HOST_VM_SWAP_D"
  [ "${MT_SRC[vm]:-0}" != 1 ] || [ -z "$HOST_VM_OOM" ] || c="$HOST_VM_OOM"
  if [ "$a$b$c" != "---" ]; then
    dash_srv_t tui.srv.mem.kernel "$a" "$b" "$c"
    tui_fit "${TH[dim]:-}$DASH_T$TH_RESET" "$cw"; L+=("$TUI_OUT")
  elif [ "$zm" -eq 1 ]; then
    dt tui.srv.na; L+=("${TH[dim]:-}$DTV$TH_RESET")
  fi
  # The lines that fit, then the graph under them; a box too short for everything keeps the first lines and says how many it left out.
  r=$((ch - ${#L[@]}))
  if [ "$r" -ge 3 ]; then
    DASH_SRV_L=("${L[@]}")
    dash_srv_chart srv_mem "$MT_HOST_HIST" 100 "$cw" "$r" mem pct
    DASH_SRV_L+=("${DASH_CH[@]}")
  else
    dash_srv_win L "$ch"
    DASH_SRV_L=("${DASH_SRV_W[@]}")
  fi
  dash_srv_mbox mem "$w" "$h" "$pct%"
}

# --- Disks ----------------------------------------------------------------------------------------------------------------------

# Every mount with its use (a meter and its size), the speed of the disks and, when there is room (zoomed: always), each disk with how busy it is, the
# pressure of the kernel and the graph of what is read and written.
dash_srv_disks() { # width height
  local w="$1" h="$2" cw=$(($1 - 4)) ch=$(($2 - 2)) zm="$DASH_SRV_ZM" i n two=0 mw lab pct pad rd wr b r k want
  local -a L=() M=() D=()
  dash_srv_glyphs
  DASH_SRV_L=()
  if [ "${MT_SRC[disk]:-}" = "0" ]; then dash_srv_note na; dash_srv_mbox disks "$w" "$h"; return 0; fi
  if [ -z "${MT_SRC[disk]:-}" ]; then dash_srv_note waiting; dash_srv_mbox disks "$w" "$h"; return 0; fi
  n="$HOST_DISK_N"
  if [ "$n" -eq 0 ]; then dash_srv_note na; dash_srv_mbox disks "$w" "$h"; return 0; fi
  # The speed of the disks: the total, then one line per disk.
  if [ -n "$HOST_DISKIO_READ_BPS" ]; then
    dt tui.srv.disk.io
    dash_srv_b "$HOST_DISKIO_READ_BPS"; rd="$DASH_SZ/s"
    dash_srv_b "$HOST_DISKIO_WRITE_BPS"
    D+=("${TH[dim]:-}$DTV$TH_RESET ${TH[net_down]:-}$DASH_DN$TH_RESET $rd ${TH[net_up]:-}$DASH_UPA$TH_RESET $DASH_SZ/s")
    dt tui.srv.lbl.busy; local busy="$DTV"
    for k in "${!HOST_DISKIO_NAME[@]}"; do
      dash_srv_b "${HOST_DISKIO_DR[$k]}"; rd="$DASH_SZ/s"
      dash_srv_b "${HOST_DISKIO_DW[$k]}"; wr="$DASH_SZ/s"
      b="${HOST_DISKIO_BUSY[$k]}"; printf -v pad '%3d' "$b"
      kit_meter "$b" 6 disk
      tui_fit "${HOST_DISKIO_NAME[$k]}" 8; lab="$TUI_OUT"
      [ "$cw" -ge 70 ] || busy=""
      dash_srv_fit "$lab ${TH[dim]:-}${busy:+$busy }$TH_RESET$KIT_OUT $pad% ${TH[net_down]:-}$DASH_DN$TH_RESET $rd ${TH[net_up]:-}$DASH_UPA$TH_RESET $wr" "$cw"
      D+=("$TUI_OUT")
    done
  elif [ "$zm" -eq 1 ]; then
    dt tui.srv.na; lab="$DTV"; dt tui.srv.disk.io; D+=("${TH[dim]:-}$DTV: $lab$TH_RESET")
  fi
  if [ "${MT_SRC[psi]:-0}" = 1 ] && [ -n "$HOST_PSI_IO" ]; then
    dash_srv_t tui.srv.psi "$HOST_PSI_IO"; D+=("$DASH_T")
  elif [ "$zm" -eq 1 ]; then
    dt tui.srv.psi.na; D+=("${TH[dim]:-}$DTV$TH_RESET")
  fi
  # The mounts: two lines each (name and size, meter) when there is room for all of them, else one.
  want=$((ch - ${#D[@]}))
  [ "$zm" -eq 1 ] || want=$((ch - 1))   # (compact: the line of the speed always stays)
  [ "$want" -ge 1 ] || want=1
  [ "$want" -lt $((n * 2)) ] || two=1
  for ((i = 0; i < n; i++)); do
    dash_srv_kb "${HOST_DISK_TOTAL[$i]:-}"
    pct="${HOST_DISK_PCT[$i]:-0}"
    [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
    printf -v pad '%3d' "$pct"
    if [ "$two" -eq 1 ]; then
      kit_leader "${HOST_DISK_MNT[$i]}" "$DASH_SZ" "$cw"; M+=("$KIT_OUT")
      kit_meter "$pct" $((cw - 5)) disk; M+=("$KIT_OUT $pad%")
    else
      mw=$((cw - 25)); [ "$mw" -ge 4 ] || mw=4
      tui_fit "${HOST_DISK_MNT[$i]}" 10; lab="$TUI_OUT"
      kit_meter "$pct" "$mw" disk
      printf -v rd '%8s' "$DASH_SZ"
      tui_fit "$lab $KIT_OUT $pad% $rd" "$cw"; M+=("$TUI_OUT")
    fi
  done
  # What the box holds, by priority: the mounts and the speed; the graph of the I/O under them when at least 4 lines are left.
  L=("${M[@]}" ${D[@]+"${D[@]}"})
  r=$((ch - ${#L[@]}))
  if [ "$r" -ge 4 ] && [ -n "$MT_HH_DIOR" ]; then
    DASH_SRV_L=("${L[@]}")
    dash_srv_mirror srv_dior "$MT_HH_DIOR" srv_diow "$MT_HH_DIOW" "$cw" $((r / 2)) $((r - r / 2)) net_down net_up
    DASH_SRV_L+=("${KG_LINES[@]}")
  elif [ "$r" -ge 0 ]; then
    DASH_SRV_L=("${L[@]}")
  elif [ "${#D[@]}" -gt 0 ] && [ "$zm" -eq 0 ]; then
    # (too short for everything: the mounts give way, the line with the speed of the disks stays)
    dash_srv_win M $((ch - 1))
    DASH_SRV_L=("${DASH_SRV_W[@]}" "${D[0]}")
  else
    dash_srv_win L "$ch"
    DASH_SRV_L=("${DASH_SRV_W[@]}")
  fi
  dash_srv_mbox disks "$w" "$h"
}

# --- Network --------------------------------------------------------------------------------------------------------------------

# The mirrored graph of two series (the first above, the second below, one scale) as kit_graph_mirror draws it, but from two cached graphs: a new
# sample moves each of them one cell at most, which costs a tenth of drawing them again. Into KG_LINES, with the scale written at the lower left.
dash_srv_mirror() { # id-up hist-up id-down hist-down width rows-up rows-down magnitude-up magnitude-down
  local idu="$1" hu="$2" idd="$3" hd="$4" w="$5" ru="$6" rd="$7" mu="${8:-net_down}" md="${9:-net_up}" max lab rest last
  local -a up=()
  kit_scale "$hu $hd"; max="$KG_MAX"
  kit_graph_cached "$idu" "$hu" "$max" "$w" "$ru" "mag=$mu"
  up=("${KG_LINES[@]}")
  kit_graph_cached "$idd" "$hd" "$max" "$w" "$rd" "mag=$md" invert=1
  last=$((${#KG_LINES[@]} - 1))
  kit_si "$max"; lab="${KIT_OUT}B"
  if [ "$last" -ge 0 ] && [ "${#lab}" -lt "$w" ]; then
    kit_slice "${KG_LINES[$last]}" "${#lab}" $((w - ${#lab})); rest="$KIT_OUT"
    KG_LINES[last]="${TH[dim]:-}$lab$TH_RESET$rest"
  fi
  KG_LINES=("${up[@]}" "${KG_LINES[@]}")
}

# The main interface as a mirrored graph (download above, upload below) with its speeds, its largest ones and the sockets; zoomed, every interface.
dash_srv_net() { # width height
  local w="$1" h="$2" cw=$(($1 - 4)) ch=$(($2 - 2)) zm="$DASH_SRV_ZM" gr up dn lab i r ifs rd wr sk
  local -a L=() I=()
  dash_srv_glyphs
  DASH_SRV_L=()
  if [ "${MT_SRC[net]:-}" = "0" ]; then dash_srv_note na; dash_srv_mbox net "$w" "$h"; return 0; fi
  if [ -z "${MT_SRC[net]:-}" ] || [ -z "$HOST_NET_DOWN_BPS" ]; then dash_srv_note waiting; dash_srv_mbox net "$w" "$h" "" "$HOST_NET_MAIN"; return 0; fi
  dt tui.srv.net.top; lab="$DTV"
  dash_srv_b "$HOST_NET_DOWN_BPS"; up="$DASH_SZ/s"
  dash_srv_b "$MT_NET_DOWN_MAX"; dn="$DASH_SZ/s"
  tui_fit "${TH[net_down]:-}$DASH_DN$TH_RESET $up  ${TH[dim]:-}$lab $dn$TH_RESET" "$cw"; L+=("$TUI_OUT")
  dash_srv_b "$HOST_NET_UP_BPS"; up="$DASH_SZ/s"
  dash_srv_b "$MT_NET_UP_MAX"; dn="$DASH_SZ/s"
  tui_fit "${TH[net_up]:-}$DASH_UPA$TH_RESET $up  ${TH[dim]:-}$lab $dn$TH_RESET" "$cw"; L+=("$TUI_OUT")
  # The sockets.
  if [ "${MT_SRC[sock]:-0}" = 1 ] && [ -n "$HOST_SOCK_TCP" ]; then
    dash_srv_t tui.srv.sockets "$HOST_SOCK_TCP" "${HOST_SOCK_TW:-0}" "${HOST_SOCK_USED:-0}"
    tui_fit "${TH[dim]:-}$DASH_T$TH_RESET" "$cw"; sk="$TUI_OUT"
  elif [ "$zm" -eq 1 ]; then
    dt tui.srv.na; lab="$DTV"; dt tui.srv.lbl.sockets; sk="${TH[dim]:-}$DTV: $lab$TH_RESET"
  else sk=""; fi
  # Every interface (zoomed, or with room): the speeds of each.
  if [ "$zm" -eq 1 ]; then
    for ifs in $HOST_NET_IFACES; do
      dash_srv_b "${HOST_NET_IF_DN[$ifs]:-0}"; rd="$DASH_SZ/s"
      dash_srv_b "${HOST_NET_IF_UP[$ifs]:-0}"; wr="$DASH_SZ/s"
      tui_fit "$ifs" 14; lab="$TUI_OUT"
      tui_fit "$lab ${TH[net_down]:-}$DASH_DN$TH_RESET $rd ${TH[net_up]:-}$DASH_UPA$TH_RESET $wr" "$cw"; I+=("$TUI_OUT")
    done
  fi
  [ -z "$sk" ] || I+=("$sk")
  r=$((ch - ${#L[@]} - ${#I[@]}))
  if [ "$r" -ge 4 ]; then
    gr="$r"
    dn=$((gr / 2)) up=$((gr - dn))
    dash_srv_mirror srv_netd "$MT_HH_NETD" srv_netu "$MT_HH_NETU" "$cw" "$up" "$dn" net_down net_up
    DASH_SRV_L=("${KG_LINES[@]}" "${L[@]}" ${I[@]+"${I[@]}"})
  else
    L+=(${I[@]+"${I[@]}"})
    dash_srv_win L "$ch"
    DASH_SRV_L=("${DASH_SRV_W[@]}")
  fi
  dash_srv_uptime "$HOST_UPTIME_S"
  lab=""
  if [ -n "$DASH_UPT" ]; then dash_srv_t tui.srv.up "$DASH_UPT"; lab="$DASH_T"; fi
  dash_srv_mbox net "$w" "$h" "$lab" "$HOST_NET_MAIN"
}

# --- Containers -----------------------------------------------------------------------------------------------------------------

# The services that are there, in the order of DASH_RES_SORT (the Resources view's, `s`), into DASH_SRV_CK; how many of the services of the
# instances are not created into DASH_SRV_NC (they are folded into one line at the end unless `h` shows them), DASH_SRV_NT how many there are.
DASH_SRV_CK=() DASH_SRV_NC=0 DASH_SRV_NT=0
dash_srv_crows() {
  local key
  DASH_SRV_CK=() DASH_SRV_NC=0
  dash_res_rows
  DASH_SRV_NT="${#DASH_RES_KEYS[@]}"
  for key in ${DASH_RES_KEYS[@]+"${DASH_RES_KEYS[@]}"}; do
    case " ${DSV_CODES[$key]:-} " in
      *" not-created "*) DASH_SRV_NC=$((DASH_SRV_NC + 1)); [ "$DASH_SRV_SHOW_NC" -eq 0 ] || DASH_SRV_CK+=("$key") ;;
      *) DASH_SRV_CK+=("$key") ;;
    esac
  done
}

# Every service with its state, how long it has been up, restarts, port, CPU (a number and its trend) and memory (a bar, the figure and its trend).
# The columns that fit the width are the ones drawn (zoomed: all of them, with the processes of each); only the rows in view are built. The ones that
# were never created are one line at the end ("+N not created"); the cursor is on screen when the box has the focus.
DASH_SRV_SHOW_NC=0   # 1: the services that were never created are listed too (h)
DASH_SRV_CSEL=0 DASH_SRV_CTOP=0
dash_srv_containers() { # width height
  local w="$1" h="$2" cw=$(($1 - 4)) ch=$(($2 - 2)) zm="$DASH_SRV_ZM" mk k n nk rows top sel key name svc st kind cpu mem lim pct c up port rs sc sm sw mw iw tier sp sm_txt pids=0 chip="" ex exw io net
  local -a cols=() rws=()
  DASH_SRV_L=()
  nk="${#DASH_SRV_CK[@]}"
  # How wide each part is. The wider the box, the more columns: the narrowest has the service, the instance, the state, the CPU and the
  # memory; then the port; then how long it has been up and its restarts. The trends take what is left, 8 to 30 cells each.
  tier=1
  if [ "$cw" -ge 118 ]; then tier=3; elif [ "$cw" -ge 92 ]; then tier=2; fi
  iw=12; sc=0 sm=0 mw=10 ex=0 exw=0
  [ "$cw" -lt 150 ] || { ex=1 exw=22; }   # (from 150 cells the table also has the disk and the network of each container)
  case "$tier" in
    3) mw=26; sw=$((cw - (6 + iw + 12 + 8 + 6 + 6 + 6 + mw) - 9 - exw)); sc=$((sw / 2)); [ "$sc" -le 30 ] || sc=30; sm="$sc"
       if [ "$sc" -lt 8 ]; then tier=2; fi ;;
  esac
  if [ "$tier" -eq 2 ]; then
    mw=22; sc=$((cw - (6 + iw + 12 + 6 + 6 + mw) - 6)); [ "$sc" -le 24 ] || sc=24; sm=0
    if [ "$sc" -lt 6 ]; then tier=1; fi
  fi
  if [ "$tier" -eq 1 ]; then mw=10; sc=0 sm=0; iw=$((cw - (6 + 12 + 6 + mw) - 4)); [ "$iw" -le 18 ] || iw=18; [ "$iw" -ge 6 ] || iw=6; fi
  # Zoomed with room: the processes of each container.
  if [ "$zm" -eq 1 ] && [ "$tier" -eq 3 ] && [ "$cw" -ge 140 ]; then pids=1; sc=$((sc - 3 - ex * 3)); [ "$sc" -ge 8 ] || sc=8; sm=$((sm - ex * 3)); [ "$sm" -ge 8 ] || sm=8; fi
  dt tui.res.col.svc; cols+=("$DTV|6|l")
  dt tui.res.col.instance; cols+=("$DTV|$iw|l")
  dt tui.res.col.state; cols+=("$DTV|12|l")
  [ "$tier" -lt 3 ] || { dt tui.res.col.up; cols+=("$DTV|8|l"); dt tui.res.col.restarts; cols+=("$DTV|6|r"); }
  [ "$tier" -lt 2 ] || { dt tui.srv.col.port; cols+=("$DTV|6|l"); }
  dt tui.res.col.cpu; cols+=("$DTV|6|r")
  [ "$sc" -le 0 ] || { dt tui.res.col.trend; cols+=("$DTV|$sc|l"); }
  dt tui.res.col.mem; cols+=("$DTV|$mw|l")
  [ "$sm" -le 0 ] || { dt tui.res.col.trend; cols+=("$DTV|$sm|l"); }
  [ "$tier" -ne 3 ] || [ "$ex" -eq 0 ] || { dt tui.srv.col.io; cols+=("$DTV|10|r"); dt tui.srv.col.net; cols+=("$DTV|10|r"); }
  [ "$pids" -eq 0 ] || { dt tui.srv.col.pids; cols+=("$DTV|5|r"); }
  # The window over the rows: it keeps the cursor in view. A line at the end holds the folded ones.
  rows=$((ch - 1))
  n="$nk"
  [ "$DASH_SRV_SHOW_NC" -eq 1 ] || [ "$DASH_SRV_NC" -eq 0 ] || n=$((nk + 1))
  [ "$DASH_SRV_CSEL" -lt "$nk" ] || DASH_SRV_CSEL=$((nk - 1))
  [ "$DASH_SRV_CSEL" -ge 0 ] || DASH_SRV_CSEL=0
  top="$DASH_SRV_CTOP"
  if [ "$DASH_SRV_CSEL" -lt "$top" ]; then top="$DASH_SRV_CSEL"; fi
  if [ "$DASH_SRV_CSEL" -ge $((top + rows)) ]; then top=$((DASH_SRV_CSEL - rows + 1)); fi
  [ $((top + rows)) -le "$n" ] || top=$((n - rows))
  [ "$top" -ge 0 ] || top=0
  DASH_SRV_CTOP="$top"
  sel=-1
  if [ "$DASH_SRV_FOCUS" = "containers" ] && [ "$nk" -gt 0 ]; then sel=$((DASH_SRV_CSEL - top)); fi
  for ((k = top; k < n && k < top + rows; k++)); do
    if [ "$k" -ge "$nk" ]; then
      dash_srv_t tui.srv.nc "$DASH_SRV_NC"
      rws+=("${TH[dim]:-}$DASH_T$TH_RESET")
      continue
    fi
    key="${DASH_SRV_CK[$k]}"
    name="${key%%/*}" svc="${key#*/}"
    kind="${DSV_KIND[$key]:-dim}"
    st="${DASH_SYM[$kind]} ${DSV_TEXT[$key]:-}"
    # CPU: the figure, coloured by its own value, and its trend (a line of blocks coloured by the last figure).
    cpu="-" sp=""
    if [ -n "${MT_CPU[$key]:-}" ]; then
      mt_tenths_v "${MT_CPU[$key]}"; cpu="$MT_T%"
      th_grad cpu $((MT_CPU[$key] / 10)); cpu="$TH_C$cpu$TH_RESET"
      if [ "$sc" -gt 0 ]; then mt_spark_v "${MT_HCPU[$key]:-}" 0 "$sc" 100; sp="$TH_C$MT_S$TH_RESET"; fi
    fi
    # Memory: a bar and its percentage of the limit (of the server's memory without one), the figure and, wide, its trend.
    mem="-" sm_txt=""
    if [ -n "${MT_MEM[$key]:-}" ]; then
      mt_bytes_v "${MT_MEM[$key]}"; mem="$MT_B"
      lim="${MT_LIM[$key]:-0}"
      pct=0
      if [ "$lim" -gt 0 ]; then
        pct=$((MT_MEM[$key] * 100 / lim)); mt_bytes_v "$lim"; mem+="/$MT_B"
      elif [ -n "${MT_HOST_TOTAL_KB:-}" ] && [ "$MT_HOST_TOTAL_KB" -gt 0 ]; then
        pct=$((MT_MEM[$key] / 1024 * 100 / MT_HOST_TOTAL_KB))
      fi
      if [ "$tier" -ge 2 ]; then
        kit_meter "$pct" 6 mem; printf -v c '%3d%%' "$pct"; mem="$KIT_OUT$c $mem"
      fi
      if [ "$sm" -gt 0 ]; then
        mt_spark_v "${MT_HMEM[$key]:-}" "$lim" "$sm" 0; sm_txt="${TH[dim]:-}$MT_S$TH_RESET"
      fi
    fi
    rs="${ST_RESTARTS[$key]:-0}"; [ "$rs" -le 0 ] 2> /dev/null || rs="${TH[warn]:-}$rs$TH_RESET"
    up="${DSV_UP[$key]:--}"; port="${DSV_PORT[$key]:--}"
    # (the row the cursor is on carries a marker too: with no colours the selection is otherwise not seen)
    mk="  "; if [ "$k" -eq "$DASH_SRV_CSEL" ] && [ "$sel" -ge 0 ]; then mk="$UI_S_SEL "; fi
    c="$mk$svc$KIT_SEP$name$KIT_SEP$st"
    [ "$tier" -lt 3 ] || c+="$KIT_SEP$up$KIT_SEP$rs"
    [ "$tier" -lt 2 ] || c+="$KIT_SEP$port"
    c+="$KIT_SEP$cpu"
    [ "$sc" -le 0 ] || c+="$KIT_SEP$sp"
    c+="$KIT_SEP$mem"
    [ "$sm" -le 0 ] || c+="$KIT_SEP$sm_txt"
    if [ "$tier" -eq 3 ] && [ "$ex" -eq 1 ]; then
      dash_srv_iorate "${MT_IOR[$key]:-}" "${MT_IOW[$key]:-}"; io="$DASH_IOR"
      dash_srv_iorate "${MT_NRX[$key]:-}" "${MT_NTX[$key]:-}"; net="$DASH_IOR"
      c+="$KIT_SEP$io$KIT_SEP$net"
    fi
    [ "$pids" -eq 0 ] || c+="$KIT_SEP${MT_PIDS[$key]:--}"
    rws+=("$c")
  done
  dt tui.res.none
  kit_table "$cw" "$ch" cols rws mag=cpu "sel=$sel" "empty=$DTV"
  DASH_SRV_L=("${KTB_LINES[@]}")
  if [ "$sel" -lt 0 ]; then
    # (the table always marks a row; with no focus nothing is selected)
    DASH_SRV_L=("${KTB_LINES[@]#"$TUI_SEL"}")
  fi
  if [ "$DASH_SRV_FOCUS" = "containers" ] || [ "$zm" -eq 1 ]; then dt "tui.res.sort.$DASH_RES_SORT"; chip="$DTV"; dash_srv_t tui.res.sort "$chip"; chip="$DASH_T"; fi
  dash_srv_mbox containers "$w" "$h" "$((DASH_SRV_NT - DASH_SRV_NC))/$DASH_SRV_NT" "$chip"
}

# --- Instances ------------------------------------------------------------------------------------------------------------------

# The rate of two counters ("12K/s 3K/s" as read and written, or received and sent) into DASH_IOR; a dash while there is no reading.
DASH_IOR=""
dash_srv_iorate() { # first second
  local a="" b=""
  if [ -n "$1" ]; then mt_bytes_v "$1"; a="$MT_B"; fi
  if [ -n "$2" ]; then mt_bytes_v "$2"; b="$MT_B"; fi
  if [ -z "$a$b" ]; then DASH_IOR="-"; return 0; fi
  DASH_IOR="${a:--}/${b:--}"
}

# The instances that have a service in the table of containers, in the order of its first service, into DASH_SRV_IK.
DASH_SRV_IK=() DASH_SRV_ISEL=0 DASH_SRV_ITOP=0
dash_srv_irows() {
  local key name seen=" "
  DASH_SRV_IK=()
  for key in ${DASH_SRV_CK[@]+"${DASH_SRV_CK[@]}"}; do
    name="${key%%/*}"
    case "$seen" in *" $name "*) ;; *) seen+="$name "; DASH_SRV_IK+=("$name") ;; esac
  done
}

# The services of every instance added up: what each instance costs the server, with the service that weighs most. One row per instance:
# its services running, CPU (tenths of a core summed), memory (and its share of the server's), the disk read and written and the network
# received and sent per second, the limits that hurt (CPU throttled, processes killed for lack of memory) and the service with most memory.
# Enter opens the instance. It is built from the figures in memory (no process).
dash_srv_inst() { # width height
  local w="$1" h="$2" cw=$(($1 - 4)) ch=$(($2 - 2)) zm="$DASH_SRV_ZM" n nk rows top sel i name key svc k tier=1 mk c lim pct
  local cpu mem io net thr oom top_key top_mem run tot pids lm th_max oom_sum ior iow nrx ntx kb
  local -a cols=() rws=()
  DASH_SRV_L=()
  nk="${#DASH_SRV_IK[@]}"
  [ "$cw" -lt 56 ] || tier=2
  [ "$cw" -lt 94 ] || tier=3
  dt tui.res.col.instance; cols+=("$DTV|*|l")
  [ "$tier" -lt 2 ] || { dt tui.srv.col.svcs; cols+=("$DTV|4|r"); }
  dt tui.res.col.cpu; cols+=("$DTV|6|r")
  dt tui.res.col.mem; cols+=("$DTV|$((tier >= 2 ? 19 : 9))|l")
  [ "$tier" -lt 2 ] || { dt tui.srv.col.io; cols+=("$DTV|10|r"); }
  [ "$tier" -lt 3 ] || { dt tui.srv.col.data; cols+=("$DTV|8|r"); }
  [ "$tier" -lt 3 ] || { dt tui.srv.col.net; cols+=("$DTV|10|r"); dt tui.srv.col.limits; cols+=("$DTV|13|l"); dt tui.srv.col.top; cols+=("$DTV|5|l"); }
  rows=$((ch - 1))
  [ "$DASH_SRV_ISEL" -lt "$nk" ] || DASH_SRV_ISEL=$((nk - 1))
  [ "$DASH_SRV_ISEL" -ge 0 ] || DASH_SRV_ISEL=0
  top="$DASH_SRV_ITOP"
  [ "$DASH_SRV_ISEL" -ge "$top" ] || top="$DASH_SRV_ISEL"
  [ "$DASH_SRV_ISEL" -lt $((top + rows)) ] || top=$((DASH_SRV_ISEL - rows + 1))
  [ $((top + rows)) -le "$nk" ] || top=$((nk - rows))
  [ "$top" -ge 0 ] || top=0
  DASH_SRV_ITOP="$top"
  sel=-1
  if [ "$DASH_SRV_FOCUS" = "inst" ] && [ "$nk" -gt 0 ]; then sel=$((DASH_SRV_ISEL - top)); fi
  for ((i = top; i < nk && i < top + rows; i++)); do
    name="${DASH_SRV_IK[$i]}"
    cpu=0 mem=0 lim=0 run=0 tot=0 pids=0 th_max=0 oom_sum=0 ior="" iow="" nrx="" ntx="" top_key="" top_mem=-1
    for key in ${DASH_SRV_CK[@]+"${DASH_SRV_CK[@]}"}; do
      [ "${key%%/*}" = "$name" ] || continue
      tot=$((tot + 1))
      case "${DSV_KIND[$key]:-}" in ok) run=$((run + 1)) ;; esac
      [ -z "${MT_CPU[$key]:-}" ] || cpu=$((cpu + MT_CPU[$key]))
      if [ -n "${MT_MEM[$key]:-}" ]; then
        mem=$((mem + MT_MEM[$key]))
        [ "${MT_MEM[$key]}" -le "$top_mem" ] || { top_mem="${MT_MEM[$key]}"; top_key="${key#*/}"; }
      fi
      [ -z "${MT_LIM[$key]:-}" ] || lim=$((lim + MT_LIM[$key]))
      [ -z "${MT_PIDS[$key]:-}" ] || pids=$((pids + MT_PIDS[$key]))
      [ "${MT_THR[$key]:-0}" -le "$th_max" ] || th_max="${MT_THR[$key]}"
      [ -z "${MT_OOM[$key]:-}" ] || oom_sum=$((oom_sum + MT_OOM[$key]))
      if [ -n "${MT_IOR[$key]:-}" ]; then ior=$((${ior:-0} + MT_IOR[$key])) iow=$((${iow:-0} + ${MT_IOW[$key]:-0})); fi
      if [ -n "${MT_NRX[$key]:-}" ]; then nrx=$((${nrx:-0} + MT_NRX[$key])) ntx=$((${ntx:-0} + ${MT_NTX[$key]:-0})); fi
    done
    mt_tenths_v "$cpu"; th_grad cpu $((cpu / 10)); cpu="$TH_C$MT_T%$TH_RESET"
    mt_bytes_v "$mem"; c="$MT_B"
    if [ "$lim" -gt 0 ]; then pct=$((mem * 100 / lim)); mt_bytes_v "$lim"; c+="/$MT_B"
    elif [ -n "${MT_HOST_TOTAL_KB:-}" ] && [ "$MT_HOST_TOTAL_KB" -gt 0 ]; then pct=$((mem / 1024 * 100 / MT_HOST_TOTAL_KB)); else pct=0; fi
    if [ "$tier" -ge 2 ]; then kit_meter "$pct" 4 mem; printf -v lm '%3d%%' "$pct"; mem="$KIT_OUT$lm $c"; else mem="$c"; fi
    dash_srv_iorate "$ior" "$iow"; io="$DASH_IOR"
    dash_srv_iorate "$nrx" "$ntx"; net="$DASH_IOR"
    thr="" ; if [ "$th_max" -gt 0 ]; then thr="${TH[warn]:-}cpu $th_max%$TH_RESET"; fi
    if [ "$oom_sum" -gt 0 ]; then thr+="${thr:+ }${TH[err]:-}oom $oom_sum$TH_RESET"; fi
    [ -n "$thr" ] || thr="${TH[dim]:-}-$TH_RESET"
    mk="  "; if [ "$i" -eq "$DASH_SRV_ISEL" ] && [ "$sel" -ge 0 ]; then mk="$UI_S_SEL "; fi
    c="$mk$name"
    [ "$tier" -lt 2 ] || c+="$KIT_SEP$run/$tot"
    c+="$KIT_SEP$cpu$KIT_SEP$mem"
    [ "$tier" -lt 2 ] || c+="$KIT_SEP$io"
    if [ "$tier" -ge 3 ]; then
      if [ -n "${DASH_SRV_DU[$name]:-}" ]; then dash_srv_kb "${DASH_SRV_DU[$name]}"; kb="$DASH_SZ"; else kb="-"; fi
      c+="$KIT_SEP$kb$KIT_SEP$net$KIT_SEP$thr$KIT_SEP${top_key:--}"
    fi
    rws+=("$c")
  done
  dt tui.res.none
  kit_table "$cw" "$ch" cols rws mag=cpu "sel=$sel" "empty=$DTV"
  DASH_SRV_L=("${KTB_LINES[@]}")
  if [ "$sel" -lt 0 ]; then DASH_SRV_L=("${KTB_LINES[@]#"$TUI_SEL"}"); fi
  dash_srv_mbox inst "$w" "$h" "$nk"
}

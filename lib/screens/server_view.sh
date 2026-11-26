#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2154  # the DASH_* variables are declared in lib/cmd/dashboard*.sh and lib/screens/server.sh and shared
# The screen of the Server view (lib/screens/server.sh sources this file): how the boxes are laid out by the size of the terminal, the memo of
# every box, the focus ring, the keys, the mouse and the background work. See the header of lib/screens/server.sh.

# What each box draws, as one string: the same string means the same box, so a box whose figures did not move since the last frame (an idle
# server: its graphs are lines of zeros, the disks hardly change) is not built again. Into DASH_SRV_KEYV. It must hold EVERYTHING the box draws.
DASH_SRV_KEYV=""
dash_srv_key_req() {
  local root=0 i
  for ((i = 0; i < HOST_DISK_N; i++)); do [ "${HOST_DISK_MNT[$i]}" != "/" ] || root="$i"; done
  DASH_SRV_KEYV="$DASH_SRV_SEL|$DASH_SRV_OPEN|$DASH_SRV_REQ|$DASH_SRV_STATE|$DASH_SRV_BUSY|$DASH_SRV_N|$DASH_SRV_ALKEY|${MT_SRC[disk]:-}|${HOST_DISK_PCT[$root]:-}|${MT_SRC[load]:-}|$HOST_LOAD1|$HOST_LOAD5|${#MT_CORE_PCT[@]}|${MT_SRC[uptime]:-}|$HOST_UPTIME_S|${MT_SRC[net]:-}|$HOST_NET_DOWN_BPS|$HOST_NET_UP_BPS"
  DASH_SRV_REQ_KEY="$DASH_SRV_KEYV"
}
dash_srv_key_cpu() { DASH_SRV_KEYV="${MT_SRC[cpu]:-}|${MT_SRC[temp]:-}|${MT_SRC[load]:-}|${MT_SRC[psi]:-}|$MT_CPU_ALL|${MT_CORE_PCT[*]}|$MT_HH_CPU|$MT_HH_LOAD|$HOST_TEMP_CPU_C|$HOST_LOAD1 $HOST_LOAD5 $HOST_LOAD15|$HOST_PSI_CPU|${MT_INTERVAL_US:-}"; }
dash_srv_key_mem() { DASH_SRV_KEYV="${MT_SRC[mem]:-}|${MT_SRC[psi]:-}|${MT_SRC[vm]:-}|$HOST_MEMD_TOTAL|$HOST_MEMD_USED|$HOST_MEMD_AVAIL|$HOST_MEMD_CACHED|$HOST_MEMD_FREE|$HOST_MEMD_SWAP_TOTAL|$HOST_MEMD_SWAP_USED|$MT_HOST_HIST|$HOST_PSI_MEM|$HOST_VM_SWAP_D|$HOST_VM_OOM|${MT_INTERVAL_US:-}"; }
dash_srv_key_disks() { DASH_SRV_KEYV="${MT_SRC[disk]:-}|${MT_SRC[psi]:-}|$HOST_DISK_N|${HOST_DISK_MNT[*]}|${HOST_DISK_TOTAL[*]}|${HOST_DISK_PCT[*]}|$HOST_DISKIO_READ_BPS|$HOST_DISKIO_WRITE_BPS|${HOST_DISKIO_NAME[*]}|${HOST_DISKIO_DR[*]}|${HOST_DISKIO_DW[*]}|${HOST_DISKIO_BUSY[*]}|$HOST_PSI_IO|$MT_HH_DIOR|$MT_HH_DIOW"; }
dash_srv_key_net() {
  local i k=""
  for i in $HOST_NET_IFACES; do k+="$i:${HOST_NET_IF_DN[$i]:-}:${HOST_NET_IF_UP[$i]:-};"; done
  dash_srv_uptime "$HOST_UPTIME_S"
  DASH_SRV_KEYV="${MT_SRC[net]:-}|${MT_SRC[sock]:-}|$HOST_NET_MAIN|$HOST_NET_DOWN_BPS|$HOST_NET_UP_BPS|$MT_NET_DOWN_MAX|$MT_NET_UP_MAX|$DASH_UPT|$MT_HH_NETD|$MT_HH_NETU|$HOST_SOCK_TCP|$HOST_SOCK_TW|$HOST_SOCK_USED|$k|${MT_INTERVAL_US:-}"
}
dash_srv_key_containers() {
  DASH_SRV_KEYV="${DASH_SRV_CK[*]}|$DASH_SRV_NC|$DASH_SRV_NT|${DSV_KIND[*]}|${DSV_TEXT[*]}|${DSV_CODES[*]}|${DSV_UP[*]}|${DSV_PORT[*]}|${ST_RESTARTS[*]}|${MT_MEM[*]}|${MT_LIM[*]}|${MT_CPU[*]}|${MT_HCPU[*]}|${MT_HMEM[*]}|${MT_PIDS[*]}|$DASH_RES_SORT|$DASH_SRV_SHOW_NC|$DASH_SRV_CSEL|$DASH_SRV_CTOP|${MT_HOST_TOTAL_KB:-}"
}
dash_srv_key_procs() { DASH_SRV_KEYV="$DASH_SRV_PS_STATE|$DASH_SRV_PSEL|$DASH_SRV_PTOP|$DASH_SRV_PS_RAW"; }
dash_srv_key_ports() { DASH_SRV_KEYV="$DASH_SRV_SS_STATE|$DASH_SRV_TSEL|$DASH_SRV_TTOP|$DASH_SRV_SS_RAW|${DSV_PORT[*]}"; }

# The boxes of one row side by side, $1 lines high, into TUI_FRAME. $2 is the array of their widths and $3.. the names of the boxes
# (req, cpu, mem, disks, net, containers, procs, ports: dash_srv_<name> draws one, taking a width and a height and leaving its lines in
# DASH_SRV_BOX). A box is built again only when its key (dash_srv_key_<name>, plus its size, the language, the theme, the zoom, whether it has the
# focus and its warning) is not the one it was last built with. Where each box is on the screen is kept in DASH_SRV_RECT (x y width height, for
# the mouse) and the names of the boxes of the frame in DASH_SRV_VIS (the ring of Tab).
DASH_SRV_FLAT=()
declare -gA DASH_SRV_MEMO_KEY=() DASH_SRV_RECT=()
DASH_SRV_MEMO_req=() DASH_SRV_MEMO_cpu=() DASH_SRV_MEMO_mem=() DASH_SRV_MEMO_disks=() DASH_SRV_MEMO_net=() DASH_SRV_MEMO_containers=()
DASH_SRV_MEMO_procs=() DASH_SRV_MEMO_ports=()
DASH_SRV_VIS=()
dash_srv_row_boxes() { # height widths-array name...
  local h="$1" i k line n nm key x=1 y
  local -n _wd="$2"
  local -a names
  shift 2
  names=("$@")
  n="${#names[@]}"
  y=$((${#TUI_FRAME[@]} + 1))
  DASH_SRV_FLAT=()
  for ((i = 0; i < n; i++)); do
    nm="${names[$i]}"
    local -n _memo="DASH_SRV_MEMO_$nm"
    "dash_srv_key_$nm"
    key="${_wd[$i]}|$h|$DASH_LANG_N|${UI_UTF8:-0}|$DASH_SRV_FOCUS|$DASH_SRV_ZM|${DASH_SRV_AL[$nm]:-0}|$DASH_SRV_KEYV"
    if [ "${DASH_SRV_MEMO_KEY[$nm]:-}" = "$key" ] && [ "${#_memo[@]}" -eq "$h" ]; then
      prof_count "box.$nm.hit"
      DASH_SRV_BOX=("${_memo[@]}")
    else
      prof_b "box.$nm"
      "dash_srv_$nm" "${_wd[$i]}" "$h"
      _memo=("${DASH_SRV_BOX[@]}")
      DASH_SRV_MEMO_KEY[$nm]="$key"
      prof_e "box.$nm"
    fi
    for ((k = 0; k < h; k++)); do DASH_SRV_FLAT[i * h + k]="${DASH_SRV_BOX[$k]:-}"; done
    DASH_SRV_RECT[$nm]="$x $y ${_wd[$i]} $h"
    DASH_SRV_VIS+=("$nm")
    x=$((x + _wd[i]))
    unset -n _memo
  done
  for ((k = 0; k < h; k++)); do
    line=""
    for ((i = 0; i < n; i++)); do line+="${DASH_SRV_FLAT[i * h + k]}"; done
    TUI_FRAME+=("$line")
  done
}

# The widths of the boxes of a row of a screen of class $2 (L wide, M medium, N narrow) in $1 cells into LAY: each box asks for what it needs, never
# takes more than it can use (a graph 300 cells wide says nothing a 100 wide one does not) and the last one takes what nobody else could.
declare -gA DASH_SRV_WSPEC=(
  [L:cpu]="50:40:100:3" [L:mem]="40:30:60:2" [L:disks]="40:30:60:2" [L:net]="44:34:90:2"
  [M:cpu]="48:40:100:3" [M:mem]="38:30:70:2" [M:disks]="40:30:70:2" [M:net]="40:34:48:1" [M:containers]="0:60::3"
  [N:cpu]="44:30:100:3" [N:mem]="36:26:70:2" [N:disks]="42:30:70:1" [N:net]="38:28::1"
  [procs]="60:40::2" [ports]="40:30:60:1"
)
dash_srv_widths() { # total class name...
  local total="$1" cls="$2" nm
  local -a specs=()
  shift 2
  if [ "$#" -le 1 ]; then LAY=("$total"); return 0; fi
  for nm in "$@"; do specs+=("${DASH_SRV_WSPEC[$cls:$nm]:-${DASH_SRV_WSPEC[$nm]:-0:20::1}}"); done
  lay_split "$total" "${specs[@]}"
}

# Rows too small to hold a box (under 4 lines) give theirs to the one before. $1 is the name of an array of heights.
dash_srv_merge() { # array
  local -n _h="$1"
  local i last=0
  # (the first row is the strip: three lines are enough for it)
  for ((i = 1; i < ${#_h[@]}; i++)); do
    if [ "${_h[$i]}" -ge 4 ]; then last="$i"; continue; fi
    [ "${_h[$i]}" -gt 0 ] || continue
    _h[last]=$((_h[last] + _h[i]))
    _h[i]=0
  done
}

# The screen. The strip (three rows) or, with something to fix, the list of the requirements; under it rows of boxes by the width of the screen:
#   wide (200 columns and more)   cpu | memory | disks | network, then the containers across the whole width
#   medium (120 and more)         cpu | memory | disks, then network | containers
#   narrow                        cpu | memory, then the containers (and, tall: disks | network)
# and, from 49 rows of body (55 of terminal), one more row with the processes and the ports. Each row asks for what its content needs (the
# containers: a line each), the figures take the rest. With a box zoomed (z) it is the only thing on screen.
scr_server_render() { # width height
  local w="$1" h="$2" top=3 cls="" i bw bmin bmax nk nr f ok=0 topmin
  local -a hs=() wa=() specs=() rows=() nms=() vis=()
  DASH_SRV_VIS=()
  prof_b srv.alerts
  dash_srv_alerts
  dash_srv_crows
  prof_e srv.alerts
  if [ -n "$DASH_SRV_PZ" ]; then
    DASH_SRV_ZM=1
    wa=("$w")
    dash_srv_row_boxes "$h" wa "$DASH_SRV_PZ"
    DASH_SRV_ZM=0
    return 0
  fi
  if [ "$w" -ge 200 ]; then cls=L; elif [ "$w" -ge 120 ]; then cls=M; else cls=N; fi
  if [ "$DASH_SRV_ZOOM" -eq 1 ]; then top=0
  elif dash_srv_expanded; then dash_srv_need $((w - 4)); top="$DASH_SRV_NEED"
  fi
  # The names of the boxes of each row (the strip is above them).
  case "$cls" in
    L) rows=("cpu mem disks net" "containers"); [ "$h" -lt 49 ] || rows+=("procs ports") ;;
    M) rows=("cpu mem disks" "net containers"); [ "$h" -lt 49 ] || rows+=("procs ports") ;;
    *) rows=("cpu mem" "containers"); [ "$h" -lt 38 ] || rows+=("disks net") ;;
  esac
  # The containers ask for a line each (and the header, the borders and the line of the ones not created).
  nk="${#DASH_SRV_CK[@]}"
  bw=$((nk + 3)); [ "$DASH_SRV_NC" -eq 0 ] || [ "$DASH_SRV_SHOW_NC" -eq 1 ] || bw=$((bw + 1))
  [ "$bw" -ge 6 ] || bw=6
  # (the list of requirements, when it is open, is what the person came to see: the figures give way to it, down to 6 and 5 lines)
  topmin="$top"
  if [ "$top" -gt 3 ]; then topmin=$((h * 5 / 9)); [ "$topmin" -ge 10 ] || topmin=10; [ "$topmin" -le "$top" ] || topmin="$top"; fi
  # (with many services the containers keep at least two fifths of the body; the figures take what they do not need, up to 44 lines)
  bmin=$((h * 2 / 5)); [ "$bmin" -ge 6 ] || bmin=6; [ "$bmin" -le "$bw" ] || bmin="$bw"
  [ "$top" -le 3 ] || bmin=5
  specs=("$top:$topmin:$top:0" "14:6:44:3")
  case "$cls" in
    M) bmax="$bw"; [ "$bmax" -ge 16 ] || bmax=16; [ "$bw" -ge 12 ] || bw=12; specs+=("$bw:$bmin:$bmax:1") ;;
    *) specs+=("$bw:$bmin:$bw:1") ;;
  esac
  [ "${#rows[@]}" -lt 3 ] || specs+=("10:6:12:2")
  lay_split "$h" "${specs[@]}"
  hs=("${LAY[@]}")
  # A row too small to draw a box (under 4 lines) gives its lines to the one above it.
  dash_srv_merge hs
  # The boxes that are on screen: the focus goes to the first one when the one that had it is not there.
  [ "${hs[0]}" -lt 3 ] || [ "$DASH_SRV_ZOOM" -eq 1 ] || vis+=(req)
  for i in "${!rows[@]}"; do
    [ "${hs[$((i + 1))]:-0}" -gt 0 ] || continue
    read -ra nms <<< "${rows[$i]}"
    vis+=("${nms[@]}")
  done
  for f in "${vis[@]}"; do [ "$f" != "$DASH_SRV_FOCUS" ] || ok=1; done
  [ "$ok" -eq 1 ] || [ "${#vis[@]}" -eq 0 ] || DASH_SRV_FOCUS="${vis[0]}"
  if [ "${hs[0]}" -ge 3 ] && [ "$DASH_SRV_ZOOM" -eq 0 ]; then
    lay_split "$w" "$w"
    dash_srv_row_boxes "${hs[0]}" LAY req
  fi
  for i in "${!rows[@]}"; do
    nr="${hs[$((i + 1))]:-0}"
    [ "$nr" -gt 0 ] || continue
    read -ra nms <<< "${rows[$i]}"
    dash_srv_widths "$w" "$cls" "${nms[@]}"
    wa=("${LAY[@]}")
    dash_srv_row_boxes "$nr" wa "${nms[@]}"
  done
}

# Moves the focus to the box that follows (+1) or precedes (-1) the one that has it among those on screen.
scr_server_tab() { # +1 | -1
  local i n="${#DASH_SRV_VIS[@]}" cur=0
  [ "$n" -gt 0 ] || return 0
  for ((i = 0; i < n; i++)); do [ "${DASH_SRV_VIS[$i]}" != "$DASH_SRV_FOCUS" ] || cur="$i"; done
  DASH_SRV_FOCUS="${DASH_SRV_VIS[$(((cur + n + $1) % n))]}"
}

# --- Keys ---------------------------------------------------------------------------------------------------------------

# The keys of the list of requirements (with the strip only Enter does something: it opens the list).
dash_srv_key_req_k() { # key
  local n="${#DASH_SRV_ORDER[@]}" open=0
  if dash_srv_expanded || [ "$DASH_SRV_PZ" = req ]; then open=1; fi
  case "$1" in
    enter | space)
      # With the strip it opens the list; with the list open it opens or closes the detail of the requirement.
      if [ "$open" -eq 1 ]; then DASH_SRV_OPEN=$((1 - DASH_SRV_OPEN)); else DASH_SRV_REQ=open; fi
      return 0 ;;
    c) [ "$open" -eq 0 ] || dash_srv_copy_sel; return 0 ;;
  esac
  [ "$open" -eq 1 ] || return 0
  case "$1" in
    up | k) [ "$DASH_SRV_SEL" -le 0 ] || DASH_SRV_SEL=$((DASH_SRV_SEL - 1)) ;;
    down | j) [ "$DASH_SRV_SEL" -ge $((n - 1)) ] || DASH_SRV_SEL=$((DASH_SRV_SEL + 1)) ;;
    pgup) DASH_SRV_SEL=$((DASH_SRV_SEL - 5)); [ "$DASH_SRV_SEL" -ge 0 ] || DASH_SRV_SEL=0 ;;
    pgdn) DASH_SRV_SEL=$((DASH_SRV_SEL + 5)); [ "$DASH_SRV_SEL" -lt "$n" ] || DASH_SRV_SEL=$((n - 1)) ;;
    home) DASH_SRV_SEL=0 ;;
    end) DASH_SRV_SEL=$((n - 1)) ;;
  esac
}

# Moves the cursor $1 (up, down, pgup, pgdn, home, end) of a list of $2 rows whose cursor is the variable named $3.
dash_srv_cursor() { # key count variable
  local -n _c="$3"
  local n="$2"
  [ "$n" -gt 0 ] || return 0
  case "$1" in
    up | k) [ "$_c" -le 0 ] || _c=$((_c - 1)) ;;
    down | j) [ "$_c" -ge $((n - 1)) ] || _c=$((_c + 1)) ;;
    pgup) _c=$((_c - 5)); [ "$_c" -ge 0 ] || _c=0 ;;
    pgdn) _c=$((_c + 5)); [ "$_c" -lt "$n" ] || _c=$((n - 1)) ;;
    home) _c=0 ;;
    end) _c=$((n - 1)) ;;
  esac
}

# The keys of the containers: the cursor, Enter opens the instance with the cursor on that service, l goes on to its logs, s sorts, h shows the
# services that were never created.
dash_srv_key_cont() { # key
  local nk="${#DASH_SRV_CK[@]}"
  case "$1" in
    up | k | down | j | pgup | pgdn | home | end) dash_srv_cursor "$1" "$nk" DASH_SRV_CSEL ;;
    enter | space) if dash_res_open_key "${DASH_SRV_CK[$DASH_SRV_CSEL]:-}"; then DASH_SRV_PZ=""; fi ;;
    l) if dash_res_open_key "${DASH_SRV_CK[$DASH_SRV_CSEL]:-}"; then DASH_SRV_PZ=""; dash_focus_logs; fi ;;
    s) case "$DASH_RES_SORT" in name) DASH_RES_SORT=mem ;; mem) DASH_RES_SORT=cpu ;; *) DASH_RES_SORT=name ;; esac ;;
    h) DASH_SRV_SHOW_NC=$((1 - DASH_SRV_SHOW_NC)) ;;
  esac
}

scr_server_key() { # key
  case "$1" in
    m) DASH_SRV_ZOOM=$((1 - DASH_SRV_ZOOM)); DASH_SRV_OPEN=0; DASH_SRV_PZ=""; return 0 ;;
    z) if [ -n "$DASH_SRV_PZ" ]; then DASH_SRV_PZ=""; else DASH_SRV_PZ="$DASH_SRV_FOCUS"; fi; DASH_SRV_OPEN=0; return 0 ;;
    R) dash_srv_request; dash_msg info "$(t tui.srv.checking)"; return 0 ;;
  esac
  case "$DASH_SRV_FOCUS" in
    req) dash_srv_key_req_k "$1" ;;
    containers) dash_srv_key_cont "$1" ;;
    procs) dash_srv_cursor "$1" "$DASH_SRV_PS_N" DASH_SRV_PSEL ;;
    ports) dash_srv_cursor "$1" "$DASH_SRV_SS_N" DASH_SRV_TSEL ;;
  esac
}

# The key `!` of this view (it replaces the global one): asks before running the command of the selected requirement, when the list of the
# requirements has the focus; anywhere else it is the command line that runs in the terminal.
scr_server_bang() {
  local id="${DASH_SRV_ORDER[$DASH_SRV_SEL]:-}"
  [ "$DASH_VIEW" = "server" ] || return 1
  [ "$DASH_SRV_ZOOM" -eq 0 ] || return 0   # only the metrics are on screen: the requirement that would run is not shown
  [ "$DASH_SRV_FOCUS" = "req" ] || return 1
  dash_srv_expanded || [ "$DASH_SRV_PZ" = req ] || return 1
  [ -n "$id" ] || return 0
  if dash_srv_waiting "$id"; then dash_msg info "$(t tui.srv.nothing_wait)"; return 0; fi
  if [ "${PR_STATUS[$id]:-}" = "ok" ]; then dash_msg info "$(t tui.srv.nothing)"; return 0; fi
  dash_srv_cmd "$id"
  if [ -z "$DASH_SRV_CMD" ]; then dash_msg warn "$(t tui.srv.nothing_cmd)"; return 0; fi
  dash_srv_ask_run "$DASH_SRV_CMD"
}

# The hints of the last line: those of the box that has the focus (the zoom has its own).
scr_server_keys() { # width
  if [ "$DASH_SRV_ZOOM" -eq 1 ]; then dash_keys_view server_met "$1"
  elif [ -n "$DASH_SRV_PZ" ]; then dash_keys_view server_zoom "$1"
  elif [ "$DASH_SRV_FOCUS" = "req" ]; then
    if dash_srv_expanded; then dash_keys_view server "$1"; else dash_keys_view server_strip "$1"; fi
  else dash_keys_view "server_$DASH_SRV_FOCUS" "$1"; fi
}
scr_server_texts() {
  local f k
  DASH_KEYS[server]="$(t tui.keys.server "$DASH_UD" "$DASH_LR")"
  DASH_KEYS[server_strip]="$(t tui.keys.server_strip)"
  DASH_KEYS[server_met]="$(t tui.keys.server_met)"
  DASH_KEYS[server_zoom]="$(t tui.keys.server_zoom "$DASH_UD")"
  for f in cpu mem disks net containers procs ports; do k="tui.keys.server_$f"; DASH_KEYS[server_$f]="$(t "$k" "$DASH_UD")"; done
}
scr_server_sig() { DASH_SIG+="|$DASH_SRV_SEL|$DASH_SRV_OPEN|$DASH_SRV_REQ|$DASH_SRV_ZOOM|$DASH_SRV_PZ|$DASH_SRV_STATE|$DASH_SRV_BUSY|$DASH_SRV_N|$DASH_SRV_FOCUS|$DASH_SRV_CSEL|$DASH_SRV_SHOW_NC|$DASH_RES_SORT|$DASH_SRV_PSEL|$DASH_SRV_TSEL|$DASH_SRV_PS_STATE|$DASH_SRV_SS_STATE"; }

# Esc: first the zoom of a box, then the detail, then the list opened by hand, then the metrics view; else leave the view.
scr_server_back() {
  if [ -n "$DASH_SRV_PZ" ]; then DASH_SRV_PZ=""; return 0; fi
  if [ "$DASH_SRV_OPEN" -eq 1 ]; then DASH_SRV_OPEN=0; return 0; fi
  if [ "$DASH_SRV_REQ" = "open" ]; then DASH_SRV_REQ=auto; return 0; fi
  if [ "$DASH_SRV_ZOOM" -eq 1 ]; then DASH_SRV_ZOOM=0; return 0; fi
  return 1
}

# --- The mouse (Options: off by default) ------------------------------------------------------------------------------------

# The box under the screen cell ($1 column, $2 row; both start at 1) into DASH_SRV_HIT, with its row inside it (0 is its top border) in DASH_SRV_HROW
# and its column in DASH_SRV_HCOL. 1 when no box is there.
DASH_SRV_HIT="" DASH_SRV_HROW=0 DASH_SRV_HCOL=0
dash_srv_hit() { # column row
  local nm x y bw bh
  DASH_SRV_HIT=""
  for nm in ${DASH_SRV_VIS[@]+"${DASH_SRV_VIS[@]}"}; do
    read -r x y bw bh <<< "${DASH_SRV_RECT[$nm]:-}"
    [ -n "${bh:-}" ] || continue
    if [ "$1" -ge "$x" ] && [ "$1" -lt $((x + bw)) ] && [ "$2" -ge "$y" ] && [ "$2" -lt $((y + bh)) ]; then
      DASH_SRV_HIT="$nm" DASH_SRV_HROW=$(($2 - y)) DASH_SRV_HCOL=$(($1 - x))
      return 0
    fi
  done
  return 1
}

# A click: on a box it gives it the focus; on the strip it opens the requirements; on a row of the box that already has the focus it puts the
# cursor there and, if the cursor was already on it, does what Enter does.
scr_server_click() { # column row
  local nm idx l r
  dash_srv_hit "$1" "$2" || return 0
  nm="$DASH_SRV_HIT"
  if [ "$nm" != "$DASH_SRV_FOCUS" ]; then DASH_SRV_FOCUS="$nm"; return 0; fi
  case "$nm" in
    req)
      if ! dash_srv_expanded; then DASH_SRV_REQ=open; return 0; fi
      IFS='|' read -r l r <<< "${DASH_SRV_RMAP[$DASH_SRV_HROW]:-}"
      idx="${l:-}"
      if [ "$DASH_SRV_RCOLW" -gt 0 ] && [ "$DASH_SRV_HCOL" -gt $((DASH_SRV_RCOLW + 2)) ]; then idx="${r:-}"; fi
      [[ "$idx" =~ ^[0-9]+$ ]] || return 0
      if [ "$idx" -eq "$DASH_SRV_SEL" ]; then DASH_SRV_OPEN=$((1 - DASH_SRV_OPEN)); else DASH_SRV_SEL="$idx"; fi
      ;;
    containers)
      [ "$DASH_SRV_HROW" -ge 2 ] || return 0   # (the border and the header are not rows)
      idx=$((DASH_SRV_CTOP + DASH_SRV_HROW - 2))
      [ "$idx" -lt "${#DASH_SRV_CK[@]}" ] || return 0
      if [ "$idx" -eq "$DASH_SRV_CSEL" ]; then scr_server_key enter; else DASH_SRV_CSEL="$idx"; fi
      ;;
    procs)
      [ "$DASH_SRV_HROW" -ge 2 ] || return 0
      idx=$((DASH_SRV_PTOP + DASH_SRV_HROW - 2))
      if [ "$idx" -lt "$DASH_SRV_PS_N" ]; then DASH_SRV_PSEL="$idx"; fi
      ;;
    ports)
      [ "$DASH_SRV_HROW" -ge 2 ] || return 0
      idx=$((DASH_SRV_TTOP + DASH_SRV_HROW - 2))
      if [ "$idx" -lt "$DASH_SRV_SS_N" ]; then DASH_SRV_TSEL="$idx"; fi
      ;;
  esac
  return 0
}

# The wheel moves the cursor of the box that has the focus (the arrows do it; the box under the pointer takes the focus first).
scr_server_wheel() { # button column row
  if dash_srv_hit "$2" "$3" && [ "$DASH_SRV_HIT" != "$DASH_SRV_FOCUS" ]; then DASH_SRV_FOCUS="$DASH_SRV_HIT"; fi
  if [ "$1" -eq 64 ]; then scr_server_key up; else scr_server_key down; fi
}

# --- Background work ----------------------------------------------------------------------------------------------------

# The first time the view is chosen it asks for the check; the figures of the server start being read.
scr_server_enter() {
  [ "$DASH_SRV_STATE" != "none" ] || dash_srv_request
  MT_LAST_US=0
}

# Every turn of the loop, whatever the view: the answer of the background check, the processes and the ports, and the figures of the server (see
# DASH_SRV_ALWAYS: while this view is not the current one they are not read, unless the cost was measured and found negligible).
DASH_SRV_ALWAYS=0
scr_server_tick() {
  if dash_async_take prereq; then
    dash_srv_apply "$DASH_AS_TEXT"
  elif [ "$DASH_SRV_BUSY" -eq 1 ] && [ -z "${DASH_AS_PID[prereq]:-}" ]; then
    DASH_SRV_BUSY=0 DASH_DIRTY=1   # the check died or was cut after a minute: free the view, R and the periodic check ask again
  fi
  dash_srv_ps_tick
  if [ "$DASH_VIEW" = "server" ] || [ "$DASH_SRV_ALWAYS" -eq 1 ]; then
    if [ "$MT_HOST_DETAIL" -ne 1 ]; then MT_HOST_DETAIL=1 MT_LAST_US=0; fi
    if [ "$DASH_VIEW" = "server" ] && [ "$DASH_SRV_STATE" = "none" ]; then dash_srv_request; fi
  elif [ "$MT_HOST_DETAIL" -ne 0 ]; then
    MT_HOST_DETAIL=0
  fi
}

# Only while the view is current and the panel runs: the requirements are checked again every DASH_SRV_EVERY seconds.
scr_server_poll() {
  tui_test_mode && return 0
  if [ "$DASH_SRV_BUSY" -eq 0 ] && [ $((SECONDS - DASH_SRV_AT)) -ge "$DASH_SRV_EVERY" ]; then dash_srv_request; fi
}

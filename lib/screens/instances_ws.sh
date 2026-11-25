#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# The WORKSPACE of an instance: what the Instances view shows at the right of the list for the instance that is selected. It is the
# place where an instance is worked on, so it shows its options instead of hiding them behind Enter: the lifecycle (state, and the actions
# in the border of the box), a card per service, and what is left to do before the instance is deployed ("Para desplegar": rows that run
# or lead to what resolves them).
#
# It is made of TABS. A tab is a file in lib/screens/ws/<id>.sh and ONE line at the end of this file (dash_ws_register <id> <title key>):
#   ws_<id>_box <instance> <width> <height>   (required) the box of the tab, exactly <height> lines, into TUI_BOX
#   ws_<id>_avail <instance>                  return 1 to hide the tab (for this instance, or at this size of the terminal)
#   ws_<id>_sig                               appends "|value" pieces to the signature of the box (everything its drawing depends on)
#   ws_<id>_key <key>                         a key while the tab has the focus (DASH_FOCUS=tab); return 0 when it took it (up and down choose the
#                                             service and left goes back to the list: they are the tab's only if it takes them first)
#   ws_<id>_texts                             the texts that depend on the language: DASH_KEYS[ws_<id>] is the hint line of its keys
#   ws_<id>_tick                              every turn of the loop (background work: it must cost nothing while the tab is not on screen)
# The strip of tabs only exists while there are two or more visible (the first one is always there). The tab on screen is the one the
# focus says (the services and the to-do rows are the summary's; the logs pane is the logs') and, while the list has the focus, the one
# chosen with `<` and `>` or a click.
#
# "Para desplegar" (the to-do list) is built from what the panel already knows (the next steps of `status`, the files of variables that
# changed since the last deploy, the variables still to fill in, the most recent version of an image, what the server lacks). The last two
# are read in the background (the files of the instance, the catalog of Docker): the panel never waits for them.

DASH_WS_TABS=()                      # ids of the tabs, in order
DASH_WS_TICKS=() DASH_WS_TEXTS=() DASH_WS_KEYS=()   # the tabs that define ws_<id>_tick, ws_<id>_texts and ws_<id>_key (found once, when they are registered)
declare -gA DASH_WS_TITLE=()         # their title keys
DASH_WS_TAB=resumen                  # the tab chosen while the list has the focus
DASH_WS_VIS=()                       # the tabs that are visible for the instance on screen
DASH_WS_ID=resumen                   # the tab on screen (dash_ws_effective)
DASH_WS_SIG=""                       # the signature being built
DASH_WS_N=0                          # answers of the background reads applied, for the signature of the frame
# Where the workspace is on screen, for the mouse: the column its box starts at (0-based) and the screen row of its first line, the row of
# the strip of tabs (0: there is none) and, for each tab, its first column and width.
DASH_WS_X0=0 DASH_WS_Y0=3 DASH_WS_STRIP=0 DASH_WS_W=0   # (DASH_WS_W: its width; 0 while it is not on screen)
DASH_WS_TAB_IDS=() DASH_WS_TAB_COL=() DASH_WS_TAB_WID=()
# The to-do rows of the instance on screen: kit_checklist items, what Enter does with each and which row has the cursor. DASH_WS_TODO_REL
# is the line of the box (0 = its first inner line) where the first one is drawn, for the mouse.
DASH_TODO=() DASH_TODO_ACT=() DASH_TODO_N=0 DASH_TODO_SEL=0 DASH_WS_TODO_REL=-1 DASH_WS_TODO_SHOWN=0 DASH_WS_TODO_START=0
# What the background reads found out about each instance's files: the ones changed since the last deploy (words), what is still to fill in
# (text and total) and when it was asked.
declare -gA DASH_WS_ENVPEND=() DASH_WS_ENVMISS=() DASH_WS_ENVMISSN=() DASH_WS_ENVAT=()
DASH_WS_ENVKEY=""                    # instance|JOB_SEQ of the last read asked for (a command that ends makes the files worth reading again)

# Registers a tab and loads its file.
dash_ws_register() { # id title_key
  DASH_WS_TABS+=("$1")
  DASH_WS_TITLE[$1]="$2"
  # shellcheck source=/dev/null
  source "$ROOT/lib/screens/ws/$1.sh"
  if declare -F "ws_$1_tick" > /dev/null; then DASH_WS_TICKS+=("$1"); fi
  if declare -F "ws_$1_texts" > /dev/null; then DASH_WS_TEXTS+=("$1"); fi
  if declare -F "ws_$1_key" > /dev/null; then DASH_WS_KEYS+=("$1"); fi
}

# The tabs that are visible for an instance, into DASH_WS_VIS.
dash_ws_visible() { # instance
  local id
  DASH_WS_VIS=()
  for id in "${DASH_WS_TABS[@]}"; do
    if declare -F "ws_${id}_avail" > /dev/null && ! "ws_${id}_avail" "$1"; then continue; fi
    DASH_WS_VIS+=("$id")
  done
  [ "${#DASH_WS_VIS[@]}" -gt 0 ] || DASH_WS_VIS=("${DASH_WS_TABS[0]}")
}

# The tab on screen into DASH_WS_ID.
dash_ws_effective() { # instance
  local id want
  if [ -z "$1" ]; then DASH_WS_ID="${DASH_WS_TABS[0]}" DASH_WS_VIS=("${DASH_WS_TABS[0]}"); return 0; fi
  dash_ws_visible "$1"
  case "$DASH_FOCUS" in
    svc | todo) want=resumen ;;
    logs) want=logs ;;
    *) want="$DASH_WS_TAB" ;;       # (list, and tab: the pane of the tab that was chosen)
  esac
  DASH_WS_ID="${DASH_WS_VIS[0]}"
  for id in "${DASH_WS_VIS[@]}"; do [ "$id" != "$want" ] || DASH_WS_ID="$id"; done
}

# The tab strip is drawn only when there are two tabs or more.
dash_ws_has_strip() { [ "${#DASH_WS_VIS[@]}" -ge 2 ]; }

# Chooses the next (+1) or previous (-1) visible tab: the focus goes with it (the pane of that tab).
dash_ws_tab_step() { # +1 | -1
  local name="${DASH_NAMES[$DASH_SEL]:-}" i n cur=0
  { [ "$DASH_ON_NEW" -eq 0 ] && [ -n "$name" ]; } || return 0
  dash_ws_effective "$name"
  n="${#DASH_WS_VIS[@]}"
  [ "$n" -ge 2 ] || return 0
  for i in "${!DASH_WS_VIS[@]}"; do [ "${DASH_WS_VIS[$i]}" != "$DASH_WS_ID" ] || cur="$i"; done
  dash_ws_tab_go "${DASH_WS_VIS[$(((cur + n + $1) % n))]}"
}

# Opens a tab: the one chosen stays while the list has the focus, and the focus goes to the tab's pane.
dash_ws_tab_go() { # id
  DASH_WS_TAB="$1"
  case "$1" in
    resumen) DASH_FOCUS=svc ;;
    logs) DASH_FOCUS=logs ;;
    *) DASH_FOCUS=tab ;;
  esac
  DASH_LOG_SCROLL=0
}

# Is the tab that was chosen one of those that own a pane (neither the summary nor the logs) and visible for the instance on screen?
dash_ws_tab_custom() {
  local name="${DASH_NAMES[$DASH_SEL]:-}" id
  case "$DASH_WS_TAB" in resumen | logs) return 1 ;; esac
  [ "$DASH_ON_NEW" -eq 0 ] && [ -n "$name" ] || return 1
  dash_ws_visible "$name"
  for id in "${DASH_WS_VIS[@]}"; do [ "$id" != "$DASH_WS_TAB" ] || return 0; done
  return 1
}

# A key for the pane of the tab on screen (the focus is "tab"). Returns 0 when the tab took it.
dash_ws_key() { # key
  local name="${DASH_NAMES[$DASH_SEL]:-}" id
  [ -n "$name" ] || return 1
  dash_ws_effective "$name"
  for id in "${DASH_WS_KEYS[@]}"; do
    [ "$id" = "$DASH_WS_ID" ] || continue
    "ws_${id}_key" "$1"
    return
  done
  return 1
}

# The texts of the tabs, in the language that is on (scr_instances_texts).
dash_ws_texts() {
  local id
  for id in "${DASH_WS_TEXTS[@]}"; do "ws_${id}_texts"; done
}

# What the frame depends on besides the summary's own: what the tab on screen says (a tab that is neither the summary nor the logs).
dash_ws_frame_sig() {
  local name="${DASH_NAMES[$DASH_SEL]:-}"
  [ "$DASH_ON_NEW" -eq 0 ] && [ -n "$name" ] || return 0
  dash_ws_effective "$name"
  case "$DASH_WS_ID" in resumen | logs) return 0 ;; esac
  DASH_WS_SIG=""
  if declare -F "ws_${DASH_WS_ID}_sig" > /dev/null; then "ws_${DASH_WS_ID}_sig"; fi
  DASH_SIG+="|$DASH_WS_ID$DASH_WS_SIG"
}

# --- The to-do list ------------------------------------------------------------------------------------------------------------

# The text of a key with the arguments filled in, into DASH_T (no process: the texts are cached).
dash_ws_t() { # key [a] [b]
  dt "$1"
  DASH_T="${DTV//\{1\}/${2:-}}"
  DASH_T="${DASH_T//\{2\}/${3:-}}"
}

# The most recent version of an image that an instance does not use yet, from the catalog of images when it has been read:
# row text in DASH_TODO_STAR ("sN|star tag|current tag"), one per line.
dash_ws_stars() { # instance
  local name="$1" g svc cur star i
  DASH_TODO_STAR=""
  [ "$DASH_IMG_STATE" = "ready" ] || return 0
  for g in "${IC_GROUPS[@]}"; do
    svc="${g%%|*}"
    case " ${DASH_SVCS[$name]:-} " in *" $svc "*) ;; *) continue ;; esac
    star="${IC_STARIDX[$g]:--1}"
    [ "$star" -ge 0 ] 2> /dev/null || continue
    cur=-1
    for i in ${IC_ORDER[$g]:-}; do
      case " ${IC_USE[$i]:-}" in *" $name(current) "*) cur="$i"; break ;; esac
    done
    [ "$cur" -ge 0 ] && [ "$cur" -ne "$star" ] || continue
    ic_before "$star" "$cur" || continue          # only a version that is newer than the one in use
    DASH_TODO_STAR+="$svc|${IC_TAG[$star]}|${IC_TAG[$cur]}"$'\n'
  done
}
DASH_TODO_STAR=""

# Builds the to-do rows of an instance into DASH_TODO (kit_checklist items "state|title|detail|action"), DASH_TODO_ACT (what Enter does:
# job:<args> runs a command, init:<instance> asks to seed, view:<id> goes to a view, none) and DASH_TODO_N.
dash_todo_build() { # instance
  local name="$1" h cmd why args verb st lbl act n=0 line svc s0 s1 files
  DASH_TODO=() DASH_TODO_ACT=() DASH_TODO_N=0
  [ -n "$name" ] || return 0
  # What `status` suggests for this instance (the commands that are ours are rows that run).
  for h in ${HINTS[@]+"${HINTS[@]}"}; do
    [ "$n" -lt 4 ] || break
    cmd="${h%%|*}" why="${h#*|}"
    case " $cmd " in *" $name "* | *" $name") ;; *) continue ;; esac
    args="${cmd#./deltactl }"
    st=warn act=none lbl=""
    if [ "$args" != "$cmd" ]; then
      verb="${args%% *}"
      case "$verb" in
        init) act="init:$name"; dt tui.ws.act.init; lbl="$DTV" ;;
        deploy | check) act="job:$args"; dt "tui.ws.act.$verb"; lbl="$DTV" ;;
        stop) act="job:$args"; dt tui.ws.act.stop; lbl="$DTV" ;;
        logs) act="job:$args"; st=err; dt tui.ws.act.logs; lbl="$DTV" ;;
        *) act="job:$args"; dt tui.ws.act.run; lbl="$DTV" ;;
      esac
    else
      st=info
    fi
    DASH_TODO+=("$st|$why||$lbl")
    DASH_TODO_ACT+=("$act")
    n=$((n + 1))
  done
  # Files of variables that changed after the last deploy, and the variables that are still to fill in (read in the background).
  if [ "${DASH_WS_ENVMISSN[$name]:-0}" -gt 0 ] 2> /dev/null; then
    dt tui.ws.todo.missing; line="$DTV"
    dash_ws_t tui.ws.todo.missing_detail "${DASH_WS_ENVMISS[$name]:-}"
    dt tui.ws.todo.missing_act
    DASH_TODO+=("err|$line|$DASH_T|$DTV")
    DASH_TODO_ACT+=("view:env")
  fi
  if [ -n "${DASH_WS_ENVPEND[$name]:-}" ]; then
    files="${DASH_WS_ENVPEND[$name]// /, }"
    dt tui.ws.todo.env; line="$DTV"
    dash_ws_t tui.ws.todo.env_detail "$files"
    dt tui.ws.todo.env_act
    DASH_TODO+=("pend|$line|$DASH_T|$DTV")
    DASH_TODO_ACT+=("view:env")
  fi
  # A version more recent than the one in use (once the catalog of Docker has been read).
  dash_ws_stars "$name"
  while IFS='|' read -r svc s0 s1; do
    [ -n "$svc" ] || continue
    dash_ws_t tui.ws.todo.star "$svc"; line="$DASH_T"
    dash_ws_t tui.ws.todo.star_detail "$s0" "$s1"
    dt tui.ws.todo.star_act
    DASH_TODO+=("info|$line|$DASH_T|$DTV")
    DASH_TODO_ACT+=("view:images")
  done <<< "$DASH_TODO_STAR"
  # What the server lacks (the requirements of the Server view), while the instance is not running.
  if [ "$DASH_SRV_STATE" = "ready" ] && [ "$DASH_SRV_BAD" -gt 0 ] && [ "${DASH_KIND[$name]:-}" != "ok" ]; then
    dash_ws_t tui.ws.todo.server "$DASH_SRV_BAD_NAMES"; line="$DASH_T"
    dt tui.ws.todo.server_act
    DASH_TODO+=("err|$line||$DTV")
    DASH_TODO_ACT+=("view:server")
  fi
  DASH_TODO_N="${#DASH_TODO[@]}"
  [ "$DASH_TODO_SEL" -lt "$DASH_TODO_N" ] || DASH_TODO_SEL=$((DASH_TODO_N - 1))
  [ "$DASH_TODO_SEL" -ge 0 ] || DASH_TODO_SEL=0
}

# Enter on a to-do row: runs what resolves it, or goes to where it is resolved.
dash_todo_run() { # instance
  local name="$1" act args verb svc
  dash_todo_build "$name"
  [ "$DASH_TODO_N" -gt 0 ] || { dash_msg info "$(t tui.ws.nothing)"; return 0; }
  act="${DASH_TODO_ACT[$DASH_TODO_SEL]:-none}"
  case "$act" in
    init:*) DASH_NAME_TARGET="${act#init:}" DASH_BUF="" DASH_CUR=0 DASH_MODE=name ;;
    view:*) dash_screen_goto "${act#view:}" ;;
    job:*)
      args="${act#job:}"
      verb="${args%% *}"
      # shellcheck disable=SC2086  # the arguments of a command of ours: instance and service names, no spaces
      case "$verb" in
        stop)
          svc="${args##* }"
          dash_confirm "$(t tui.confirm_stop "$svc" "$name")" stay $args
          ;;
        logs) dash_start_job output $args ;;
        *) dash_start_job stay $args ;;
      esac
      ;;
    *) dash_msg info "$(t tui.ws.nothing)" ;;
  esac
}

# Keys while the to-do rows have the focus. Returns 0 when it took the key.
dash_key_todo() { # key
  local name="${DASH_NAMES[$DASH_SEL]:-}"
  dash_todo_build "$name"
  case "$1" in
    up | k) [ "$DASH_TODO_N" -eq 0 ] || DASH_TODO_SEL=$(((DASH_TODO_SEL + DASH_TODO_N - 1) % DASH_TODO_N)) ;;
    down | j) [ "$DASH_TODO_N" -eq 0 ] || DASH_TODO_SEL=$(((DASH_TODO_SEL + 1) % DASH_TODO_N)) ;;
    enter) dash_todo_run "$name" ;;
    left | h) DASH_FOCUS=svc ;;
    right) if dash_logs_reachable; then DASH_FOCUS=logs; fi ;;
    *) return 1 ;;
  esac
  return 0
}

# --- What the background reads find out ----------------------------------------------------------------------------------------

# Runs in the background: for each file of the instance, the state of its last deploy and how many variables are still to fill in.
# Prints "D <file> <synced|pending|unknown>" and "M <file> <n>" lines (the file as a word: instance, s0, s1).
dash_ws_dump() { # instance
  local f id key n
  envschema_load
  envedit_files_r "$1"
  for f in "${ENVEDIT_FILES[@]}"; do
    envedit_deploy_state_r "$1" "$f"
    printf 'D %s %s\n' "$(envedit_word "$f")" "$ED_DEPLOY"
    n=0
    for id in "${ENV_IDS[@]}"; do
      [ "${ENV_FILE[$id]}" = "$f" ] || continue
      [ "${ENV_TYPE[$id]}" != fixed ] || continue
      key="${ENV_KEY[$id]}"
      envedit_state_r "$1" "$f" "$key"
      case "$ED_STATE" in missing | invalid | example) n=$((n + 1)) ;; esac
    done
    printf 'M %s %s\n' "$(envedit_word "$f")" "$n"
  done
}

# Applies the lines of dash_ws_dump.
dash_ws_apply() { # instance text
  local kind f v pend="" miss="" total=0
  while read -r kind f v; do
    case "$kind" in
      D) [ "$v" != "pending" ] || pend+="${pend:+ }$f" ;;
      M) if [ "${v:-0}" -gt 0 ] 2> /dev/null; then miss+="${miss:+ · }$f: $v"; total=$((total + v)); fi ;;
    esac
  done <<< "$2"
  DASH_WS_ENVPEND[$1]="$pend" DASH_WS_ENVMISS[$1]="$miss" DASH_WS_ENVMISSN[$1]="$total"
  DASH_WS_N=$((DASH_WS_N + 1)) DASH_DIRTY=1
}

# Asks for the read of the files of an instance (the test mode reads at once, and only when a test asks for it with DELTACTL_TUI_WSENV).
dash_ws_request() { # instance
  DASH_WS_ENVAT[$1]="$SECONDS"
  if tui_test_mode; then dash_ws_apply "$1" "$(dash_ws_dump "$1")"; return 0; fi
  dash_async wsenv "$1" dash_ws_dump "$1" || true
}

# Every turn of the loop: the answer of the read, and a new read when the instance or the last command that ended changed what it says.
dash_ws_tick() {
  local name key id
  for id in "${DASH_WS_TICKS[@]}"; do "ws_${id}_tick"; done
  if dash_async_take wsenv; then dash_ws_apply "${DASH_AS_ARG[wsenv]}" "$DASH_AS_TEXT"; fi
  [ "$DASH_VIEW" = "instances" ] && [ "$DASH_ON_NEW" -eq 0 ] && [ "${#DASH_NAMES[@]}" -gt 0 ] || return 0
  # The cursor was in the rows and they are all resolved: it goes back to the services.
  if [ "$DASH_FOCUS" = "todo" ]; then
    dash_todo_build "${DASH_NAMES[$DASH_SEL]}"
    if [ "$DASH_TODO_N" -eq 0 ]; then DASH_FOCUS=svc DASH_DIRTY=1; fi
  fi
  if tui_test_mode && [ -z "${DELTACTL_TUI_WSENV:-}" ]; then return 0; fi
  name="${DASH_NAMES[$DASH_SEL]}"
  key="$name|$JOB_SEQ"
  if [ "$key" != "$DASH_WS_ENVKEY" ] && [ -z "${DASH_AS_PID[wsenv]:-}" ]; then
    DASH_WS_ENVKEY="$key"
    dash_ws_request "$name"
  elif ! tui_test_mode && [ -z "${DASH_AS_PID[wsenv]:-}" ] && [ -n "${DASH_WS_ENVAT[$name]:-}" ] && [ $((SECONDS - DASH_WS_ENVAT[$name])) -ge 30 ]; then
    dash_ws_request "$name"
  fi
}

# The catalog of Docker is read (by the Images view's own machinery) when the summary is on screen and it has not been read, or a command
# ended, or it is five minutes old. The test mode leaves it alone.
dash_ws_poll_images() {
  tui_test_mode && return 0
  [ "$DASH_IMG_BUSY" -eq 0 ] || return 0
  if [ "$DASH_IMG_STATE" = "none" ] || [ "$DASH_IMG_STALE" -eq 1 ] || [ $((SECONDS - DASH_IMG_AT)) -ge 300 ]; then dash_img_request; fi
}

# What the instance adds up to, in one or two lines into DASH_WS_TOT: memory (against the sum of the limits), CPU and the state of its data, and
# the errors seen in the log of each service in the last minutes (once they have been counted). Empty when it has no services.
DASH_WS_TOT=()
dash_ws_totals() { # instance
  local name="$1" svc n lbl line errs=""
  local -a svcs
  DASH_WS_TOT=()
  read -ra svcs <<< "${DASH_SVCS[$name]:-}"
  [ "${#svcs[@]}" -gt 0 ] || return 0
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
  DASH_WS_TOT+=("$line")
  if [ -n "${DASH_ERRS_AT[$name]:-}" ]; then
    for svc in "${svcs[@]}"; do
      n="${DASH_ERRS[$name/$svc]:-}"
      [ -n "$n" ] || continue
      if [ "$n" -gt 0 ]; then errs+="${errs:+ $UI_S_DOT }$C_RED$svc $n$C_OFF"; else errs+="${errs:+ $UI_S_DOT }$svc 0"; fi
    done
    if [ -n "$errs" ]; then dt tui.lbl.errors; DASH_WS_TOT+=("  $C_GRY$DTV:$C_OFF $errs"); fi
  fi
}

# --- Drawing -------------------------------------------------------------------------------------------------------------------

# Markup of the kit (^ and {) escaped, for a text that is not a label.
DASH_WS_ESC=""
dash_ws_esc() { # text
  local s="${1//\^/^^}"
  DASH_WS_ESC="${s//\{/\{\{}"
}

# The strip of tabs (one line, $1 cells wide) into DASH_WS_STRIPLINE; the mouse learns where each tab is.
DASH_WS_STRIPLINE=""
dash_ws_strip() { # width
  local id i cur=1 labels=()
  DASH_WS_TAB_IDS=() DASH_WS_TAB_COL=() DASH_WS_TAB_WID=()
  i=0
  for id in "${DASH_WS_VIS[@]}"; do
    i=$((i + 1))
    dt "${DASH_WS_TITLE[$id]}"; labels+=("$DTV")
    DASH_WS_TAB_IDS+=("$id")
    [ "$id" != "$DASH_WS_ID" ] || cur="$i"
  done
  kit_tabs "$1" "$cur" "${labels[@]}"
  DASH_WS_STRIPLINE="$KT_LINE"
  for i in "${!KT_COLS[@]}"; do DASH_WS_TAB_COL[i]="${KT_COLS[$i]}" DASH_WS_TAB_WID[i]="${KT_WID[$i]}"; done
}

# The signature of the box of the tab on screen.
dash_ws_sig() { # instance
  dash_ws_effective "$1"
  DASH_WS_SIG="$DASH_WS_ID|$DASH_SVC|$DASH_FOCUS|$DASH_DET_OFF|$DASH_REFRESH_N|$MT_SAMPLES|$DASH_ERRS_N|$DASH_LANG_N|$DASH_TODO_SEL|$DASH_WS_N|$DASH_IMG_N|$DASH_SRV_N|$TH_NAME|${#HINTS[@]}"
  if declare -F "ws_${DASH_WS_ID}_sig" > /dev/null; then "ws_${DASH_WS_ID}_sig"; fi
}

# The workspace of an instance: its strip of tabs (when there are several) and the box of the tab on screen. Result in TUI_BOX, exactly
# <height> lines. This is the part of the view the per-panel cache keeps (the logs box has a cache of its own).
dash_detail_box() { # instance width height
  local name="$1" w="$2" h="$3" bh="$3" strip=0 sig lines
  local -a shown=() out=()
  if [ "$DASH_ON_NEW" -eq 1 ]; then dash_new_box "$w" "$h"; return 0; fi
  if [ -z "$name" ]; then
    dt tui.select_one
    shown=("$C_GRY$DTV$C_OFF")
    tui_box "" "$w" "$h" shown
    return 0
  fi
  dash_ws_effective "$name"
  DASH_WS_STRIP=0
  if dash_ws_has_strip && [ "$h" -ge 6 ]; then
    strip=1 bh=$((h - 1)) DASH_WS_STRIP=1
    dash_ws_strip "$w"
  fi
  "ws_${DASH_WS_ID}_box" "$name" "$w" "$bh"
  if [ "$strip" -eq 1 ]; then
    out=("$DASH_WS_STRIPLINE" "${TUI_BOX[@]}")
    TUI_BOX=("${out[@]}")
  fi
}

# The detail box, cached (see dash_list_box). The box of the logs tab is not: its own cache knows what its lines depend on.
dash_detail_box_cached() { # instance width height
  local sig
  dash_ws_effective "$1"
  if [ "$DASH_ON_NEW" -eq 0 ] && [ "$DASH_WS_ID" = "logs" ]; then dash_detail_box "$1" "$2" "$3"; return 0; fi
  dash_ws_sig "$1"
  sig="$1|$2|$3|$DASH_ON_NEW|$DASH_WS_SIG"
  if dash_pc_get detail "$sig"; then
    read -r DASH_WS_TODO_REL DASH_WS_TODO_SHOWN DASH_WS_TODO_START DASH_WS_STRIP <<< "$DASH_PC_M"
    return 0
  fi
  dash_detail_box "$1" "$2" "$3"
  dash_pc_put detail "$sig" "$DASH_WS_TODO_REL $DASH_WS_TODO_SHOWN $DASH_WS_TODO_START $DASH_WS_STRIP"
}

# Is there a logs pane that can have the focus? It is under the summary on a wide screen, and a tab on the others.
dash_logs_reachable() {
  local name="${DASH_NAMES[$DASH_SEL]:-}"
  [ "$DASH_ON_NEW" -eq 0 ] && [ -n "$name" ] || return 1
  [ -n "${DASH_SVCS[$name]:-}" ] || return 1
  dash_overview_fits && return 0
  dash_ws_visible "$name"
  local id
  for id in "${DASH_WS_VIS[@]}"; do [ "$id" != "logs" ] || return 0; done
  return 1
}

# Is the logs pane on screen now (and so worth a stream)?
dash_logs_visible() {
  if [ "$DASH_ZOOM" -eq 1 ]; then [ "$DASH_FOCUS" = "logs" ]; return; fi
  if dash_overview_fits; then
    # (the logs sit under the summary; a tab with a pane of its own takes their place)
    if [ "$DASH_ON_NEW" -eq 0 ] && [ -n "${DASH_NAMES[$DASH_SEL]:-}" ]; then
      dash_ws_effective "${DASH_NAMES[$DASH_SEL]}"
      case "$DASH_WS_ID" in resumen | logs) ;; *) return 1 ;; esac
    fi
    return 0
  fi
  [ "$DASH_ON_NEW" -eq 0 ] && [ -n "${DASH_NAMES[$DASH_SEL]:-}" ] || return 1
  dash_ws_effective "${DASH_NAMES[$DASH_SEL]}"
  [ "$DASH_WS_ID" = "logs" ]
}

# --- The tabs: ONE line each -------------------------------------------------------------------------------------------------
dash_ws_register resumen tui.ws.tab.resumen
dash_ws_register logs tui.ws.tab.logs
dash_ws_register acceso tui.ws.tab.acceso
dash_ws_register historial tui.ws.tab.historial

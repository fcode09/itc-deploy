#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Screen: Server (view 7). What the server needs for deltactl to work (the requirements of lib/core/prereqs.sh, with what each one is for and
# the command that installs it) and how the server is doing (CPU, memory, disks, network and the containers), drawn as btop does: boxes with
# chips in their border, braille graphs, gradient meters and a mirrored network graph. It is built from the UI kit (lib/ui/kit/*).
#
# The requirements are checked in the background (a check can ask Docker or open a TCP connection, which takes seconds) and shown as soon as
# they arrive; they are checked again every 30 s while the view is on screen, and with R. The panel NEVER installs anything: `c` copies the
# command of the selected requirement and `!` asks (lib/screens/srvask.sh) before running it in the terminal, where sudo asks for the password.
# The figures of the server (lib/core/metrics.sh, MT_HOST_DETAIL=1) are only read while this view is current.
#
# Keys: Up/Down choose a requirement · Enter opens its detail · c copies the command · ! runs it (asks first) · m shows only the metrics
# (the requirements give their room to the figures) · R checks again · Esc closes the detail, then the metrics view.

DASH_SRV_SEL=0           # the requirement under the cursor (index into DASH_SRV_ORDER)
DASH_SRV_OPEN=0          # 1: the detail of the requirement is open
DASH_SRV_ZOOM=0          # 1: only the metrics (m)
DASH_SRV_STATE=none      # none (never asked) | loading (first answer pending) | ready
DASH_SRV_BUSY=0          # 1 while a check runs (the previous answer stays on screen)
DASH_SRV_N=0             # answers applied, for the frame signature
DASH_SRV_AT=0            # SECONDS of the last request
DASH_SRV_EVERY=30        # seconds between two checks while the view is on screen
DASH_SRV_STARTUP=0       # 1: the panel just started and the first answer decides whether to open this view
DASH_SRV_SKIP=0          # 1: the person chose to create instances although something required is missing
DASH_PREREQ=1            # TUI_PREREQ: warn about the missing requirements (Options)
DASH_SRV_ORDER=()        # ids of the requirements: the required ones first, then the recommended ones
DASH_SRV_NREQ=0          # how many of them are required
DASH_SRV_BAD=0 DASH_SRV_BAD_NAMES="" DASH_SRV_READY=0 DASH_SRV_REC_PEND=0

# The requirements in the order they are shown.
dash_srv_order() {
  local id
  DASH_SRV_ORDER=() DASH_SRV_NREQ=0
  for id in "${PR_IDS[@]}"; do
    [ "${PR_LEVEL[$id]}" != "required" ] || { DASH_SRV_ORDER+=("$id"); DASH_SRV_NREQ=$((DASH_SRV_NREQ + 1)); }
  done
  for id in "${PR_IDS[@]}"; do
    [ "${PR_LEVEL[$id]}" = "required" ] || DASH_SRV_ORDER+=("$id")
  done
}
dash_srv_order

# A text with {1} {2} {3} filled in, into DASH_T (cached like dt, so no process).
DASH_T=""
dash_srv_t() { # key [a] [b] [c]
  dt "$1"
  DASH_T="${DTV//\{1\}/${2:-}}"
  DASH_T="${DASH_T//\{2\}/${3:-}}"
  DASH_T="${DASH_T//\{3\}/${4:-}}"
}

# --- Figures in human units (integer arithmetic, no process) ------------------------------------------------------------

# Kilobytes -> "5.62 GiB", "512 MiB" into DASH_SZ.
DASH_SZ=""
dash_srv_kb() { # kilobytes
  local kb="$1" v f
  [[ "$kb" =~ ^[0-9]+$ ]] || { DASH_SZ="-"; return 0; }
  if [ "$kb" -ge 10485760 ]; then DASH_SZ="$((kb / 1048576)) GiB"
  elif [ "$kb" -ge 1048576 ]; then v=$((kb * 100 / 1048576)); printf -v f '%02d' $((v % 100)); DASH_SZ="$((v / 100)).$f GiB"
  elif [ "$kb" -ge 1024 ]; then DASH_SZ="$((kb / 1024)) MiB"
  else DASH_SZ="$kb KiB"; fi
}

# Bytes -> "950 B", "4.0 MiB" into DASH_SZ.
dash_srv_b() { # bytes
  local b="$1" t
  [[ "$b" =~ ^[0-9]+$ ]] || { DASH_SZ="-"; return 0; }
  if [ "$b" -lt 1024 ]; then DASH_SZ="$b B"
  elif [ "$b" -lt 1048576 ]; then t=$((b * 10 / 1024)); DASH_SZ="$((t / 10)).$((t % 10)) KiB"
  elif [ "$b" -lt 1073741824 ]; then t=$((b * 10 / 1048576)); DASH_SZ="$((t / 10)).$((t % 10)) MiB"
  else t=$((b * 100 / 1073741824)); printf -v t '%d.%02d' $((t / 100)) $((t % 100)); DASH_SZ="$t GiB"; fi
}

# Seconds -> "2d 03:14" into DASH_UPT.
DASH_UPT=""
dash_srv_uptime() { # seconds
  local s="$1" d h m
  [[ "$s" =~ ^[0-9]+$ ]] || { DASH_UPT=""; return 0; }
  d=$((s / 86400)) h=$((s % 86400 / 3600)) m=$((s % 3600 / 60))
  if [ "$d" -gt 0 ]; then printf -v DASH_UPT '%dd %02d:%02d' "$d" "$h" "$m"; else printf -v DASH_UPT '%02d:%02d' "$h" "$m"; fi
}

# --- The requirements -------------------------------------------------------------------------------------------------

# The kit state of a requirement (ok warn err pend run info) into DASH_SRV_ST. A recommended one that is missing counts as a warning.
DASH_SRV_ST=""
dash_srv_kit_state() { # id
  local st="${PR_STATUS[$1]:-}"
  if [ "$DASH_SRV_STATE" != "ready" ] || [ -z "$st" ]; then DASH_SRV_ST=run; return 0; fi
  case "$st" in
    ok) DASH_SRV_ST=ok ;;
    err) DASH_SRV_ST=err ;;
    warn) DASH_SRV_ST=warn ;;
    na) DASH_SRV_ST=pend ;;
    *) if [ "${PR_LEVEL[$1]}" = "required" ]; then DASH_SRV_ST=info; else DASH_SRV_ST=warn; fi ;;
  esac
}

# Counts what the last answer says: DASH_SRV_READY of the required ones are fine, DASH_SRV_BAD fail (their names in
# DASH_SRV_BAD_NAMES) and DASH_SRV_REC_PEND recommended ones are still to do.
dash_srv_counts() {
  local id st
  DASH_SRV_READY=0 DASH_SRV_BAD=0 DASH_SRV_BAD_NAMES="" DASH_SRV_REC_PEND=0
  [ "$DASH_SRV_STATE" = "ready" ] || return 0
  for id in "${DASH_SRV_ORDER[@]}"; do
    st="${PR_STATUS[$id]:-}"
    if [ "${PR_LEVEL[$id]}" = "required" ]; then
      case "$st" in
        ok | info) DASH_SRV_READY=$((DASH_SRV_READY + 1)) ;;
        err) DASH_SRV_BAD=$((DASH_SRV_BAD + 1)); dt "prereq.name.$id"; DASH_SRV_BAD_NAMES+="${DASH_SRV_BAD_NAMES:+, }$DTV" ;;
      esac
    else
      [ "$st" = "ok" ] || DASH_SRV_REC_PEND=$((DASH_SRV_REC_PEND + 1))
    fi
  done
}

# Runs in the background: checks everything and prints the results as `declare -p` lines.
dash_srv_dump() {
  prereq_distro
  prereq_run_all
  declare -p PR_STATUS PR_SUMMARY PR_RECORDS PR_N_ERR PR_N_WARN PR_DISTRO_ID PR_DISTRO_NAME PR_MANAGER
}

# Loads the lines of dash_srv_dump (only the variables of the requirements) and tells the panel.
dash_srv_apply() { # text
  local line
  while IFS= read -r line; do
    if [[ "$line" =~ ^declare\ -[-AaFgrx]+\ (PR_STATUS|PR_SUMMARY|PR_RECORDS|PR_N_ERR|PR_N_WARN|PR_DISTRO_ID|PR_DISTRO_NAME|PR_MANAGER)= ]]; then
      eval "declare -g${line#declare}"
    fi
  done <<< "$1"
  DASH_SRV_STATE=ready DASH_SRV_BUSY=0 DASH_SRV_N=$((DASH_SRV_N + 1)) DASH_DIRTY=1
  dash_srv_counts
  [ "$DASH_SRV_SEL" -lt "${#DASH_SRV_ORDER[@]}" ] || DASH_SRV_SEL=$((${#DASH_SRV_ORDER[@]} - 1))
  dash_srv_after_apply
}

# Asks for a check without waiting for it (the synchronous one in the test mode).
dash_srv_request() {
  DASH_SRV_AT="$SECONDS"
  if tui_test_mode; then dash_srv_apply "$(dash_srv_dump)"; return 0; fi
  [ -z "${DASH_AS_PID[prereq]:-}" ] || return 0
  [ "$DASH_SRV_STATE" = "ready" ] || DASH_SRV_STATE=loading
  DASH_SRV_BUSY=1 DASH_DIRTY=1
  dash_async prereq "" dash_srv_dump || true
}

# What the first answer after the panel started does: with something required missing it says so and, when nobody went anywhere else,
# opens this view. A panel with everything in place says nothing.
dash_srv_after_apply() {
  [ "$DASH_SRV_STARTUP" -eq 1 ] || return 0
  DASH_SRV_STARTUP=0
  [ "$DASH_SRV_BAD" -gt 0 ] || return 0
  dash_msg warn "$(t tui.srv.startup "$DASH_SRV_BAD" "$DASH_SRV_BAD_NAMES")"
  if [ "$DASH_VIEW" = "instances" ] && [ "$DASH_MODE" = "normal" ]; then dash_screen_goto server; fi
}

# Called once when the panel starts (see cmd_dashboard).
dash_srv_startup() {
  [ "$DASH_PREREQ" -eq 1 ] || return 0
  # The tests of the other screens must not open on this one because the machine they run on lacks a program.
  if tui_test_mode && [ -z "${DELTACTL_TUI_GATE:-}" ]; then return 0; fi
  DASH_SRV_STARTUP=1
  dash_srv_request
}

# Is something required missing, and the person has not chosen to go on? Used before creating an instance.
dash_srv_blocking() {
  [ "$DASH_PREREQ" -eq 1 ] && [ "$DASH_SRV_SKIP" -eq 0 ] && [ "$DASH_SRV_STATE" = "ready" ] && [ "$DASH_SRV_BAD" -gt 0 ]
}

# The install command of a requirement, for this server's package manager, into DASH_SRV_CMD (empty when there is none).
DASH_SRV_CMD=""
dash_srv_cmd() { # id
  DASH_SRV_CMD=""
  if prereq_install_r "$1"; then DASH_SRV_CMD="$PR_INSTALL"; fi
}

# --- Copy and run -----------------------------------------------------------------------------------------------------

# Puts a text in the clipboard: a tool of the desktop when there is one (DELTACTL_CLIP replaces them, for tests: a command that reads the
# text from its input), else the terminal's own clipboard (OSC 52, which most terminals accept). Returns 1 when nothing could take it.
DASH_SRV_COPIED=""
dash_srv_copy() { # text
  local text="$1" tool
  DASH_SRV_COPIED=""
  if [ -n "${DELTACTL_CLIP:-}" ]; then
    printf '%s' "$text" | bash -c "$DELTACTL_CLIP" > /dev/null 2>&1 && DASH_SRV_COPIED=tool
  else
    for tool in "wl-copy" "xclip -selection clipboard" "xsel --clipboard --input" "pbcopy"; do
      host_has "${tool%% *}" || continue
      printf '%s' "$text" | $tool > /dev/null 2>&1 && { DASH_SRV_COPIED=tool; break; }
    done
    if [ -z "$DASH_SRV_COPIED" ] && ! tui_test_mode && host_has base64; then
      printf '\033]52;c;%s\a' "$(printf '%s' "$text" | base64 | tr -d '\n')" > /dev/tty 2> /dev/null && DASH_SRV_COPIED=term
    fi
  fi
  [ -n "$DASH_SRV_COPIED" ]
}

# `c`: copies the install command of the selected requirement.
dash_srv_copy_sel() {
  local id="${DASH_SRV_ORDER[$DASH_SRV_SEL]:-}"
  [ -n "$id" ] || return 0
  dash_srv_cmd "$id"
  if [ -z "$DASH_SRV_CMD" ]; then dash_msg warn "$(t tui.srv.nothing_cmd)"; return 0; fi
  if dash_srv_copy "$DASH_SRV_CMD"; then
    if [ "$DASH_SRV_COPIED" = "term" ]; then dash_msg ok "$(t tui.srv.copied_term "$DASH_SRV_CMD")"; else dash_msg ok "$(t tui.srv.copied "$DASH_SRV_CMD")"; fi
  else
    dash_msg warn "$(t tui.srv.copy_none "$DASH_SRV_CMD")"
  fi
}

# The command runs in the real terminal (the panel steps aside and comes back), so sudo can ask for the password. Only srvask.sh calls it,
# after the person said yes. DELTACTL_PR_SHELL replaces bash (tests).
dash_srv_terminal() { # command
  local cmd="$1"
  dash_msg info "$(t tui.srv.terminal "$cmd")"
  tui_leave
  printf '\n  %s%s %s%s\n\n' "$C_GRY" "$UI_S_ARROW" "$cmd" "$C_OFF"
  dash_prompt_name
  dash_con_add "${TH[accent]:-$C_CYN}$DASH_PN $(dash_prompt_glyph)$C_OFF $cmd"
  "${DELTACTL_PR_SHELL:-bash}" -c "$cmd" || printf '\n  %s %s\n' "$(ui_sym err)" "$(t menu.cmd_failed "$?")"
  menu_pause
  tui_enter
  DASH_SIGINT=0
  dash_key_seen
  dash_srv_request
}

# The key `!` of this view (it replaces the global one): asks before running the command of the selected requirement.
scr_server_bang() {
  local id="${DASH_SRV_ORDER[$DASH_SRV_SEL]:-}"
  [ "$DASH_VIEW" = "server" ] || return 1
  [ -n "$id" ] || return 0
  if [ "${PR_STATUS[$id]:-}" = "ok" ]; then dash_msg info "$(t tui.srv.nothing)"; return 0; fi
  dash_srv_cmd "$id"
  if [ -z "$DASH_SRV_CMD" ]; then dash_msg warn "$(t tui.srv.nothing_cmd)"; return 0; fi
  dash_srv_ask_run "$DASH_SRV_CMD"
}

# --- Drawing: the requirements ------------------------------------------------------------------------------------------

# The first row of a window of $3 rows over $1 rows that keeps row $2 in view, into DASH_SRV_TOP.
DASH_SRV_TOP=0
dash_srv_top() { # total selected rows
  local top=0
  [ "$2" -lt "$3" ] || top=$(($2 - $3 + 1))
  [ $((top + $3)) -le "$1" ] || top=$(($1 - $3))
  [ "$top" -ge 0 ] || top=0
  DASH_SRV_TOP="$top"
}

# One requirement as a row of $2 cells: mark, state icon, name (in a column of $3 cells) and what the check said.
DASH_SRV_ROW=""
dash_srv_row() { # id width title_width selected
  local id="$1" w="$2" tw="$3" mark title detail dw icon dcol=""
  dash_srv_kit_state "$id"; kit_state_icon "$DASH_SRV_ST"; icon="$KIT_ICON"
  case "$DASH_SRV_ST" in err | warn) dcol="$KIT_COL" ;; *) dcol="${TH[dim]:-}" ;; esac
  dt "prereq.name.$id"; tui_fit "$DTV" "$tw"; title="$TUI_OUT"
  if [ "$DASH_SRV_STATE" = "ready" ]; then detail="${PR_SUMMARY[$id]:-}"; else detail=""; fi
  dw=$((w - 6 - tw))
  [ "$dw" -ge 0 ] || dw=0
  tui_fit "$dcol$detail$TH_RESET" "$dw"; detail="$TUI_OUT"
  if [ "$4" -eq 1 ]; then mark="${TH[accent]:-}$UI_S_SEL$TH_RESET "; else mark="  "; fi
  DASH_SRV_ROW="$mark$icon $title  $detail"
}

# The lines of a group of requirements (indexes $2..$3 of DASH_SRV_ORDER) under its heading, $4 cells wide, into the array named $1. The
# selected one is marked; in a single column its whole line carries the selection colours (a column of two shares its line).
dash_srv_group() { # array first last width single
  local -n _out="$1"
  local i id tw=0 sel hd key
  _out=()
  for ((i = $2; i <= $3; i++)); do
    dt "prereq.name.${DASH_SRV_ORDER[$i]}"
    [ "${#DTV}" -le "$tw" ] || tw="${#DTV}"
  done
  [ "$tw" -le $(($4 / 2)) ] || tw=$(($4 / 2))
  if [ "${PR_LEVEL[${DASH_SRV_ORDER[$2]}]}" = "required" ]; then key=tui.srv.group.required; else key=tui.srv.group.recommended; fi
  dt "$key"; hd="${TH[dim]:-}$C_BLD  $DTV$TH_RESET"
  _out+=("$hd")
  for ((i = $2; i <= $3; i++)); do
    id="${DASH_SRV_ORDER[$i]}"
    sel=0; [ "$i" -ne "$DASH_SRV_SEL" ] || sel=1
    dash_srv_row "$id" "$4" "$tw" "$sel"
    if [ "$sel" -eq 1 ]; then
      if [ "$5" -eq 1 ]; then _out+=("$TUI_SEL$DASH_SRV_ROW"); else _out+=("${TH[sel]:-}${DASH_SRV_ROW//"$TH_RESET"/"$TH_RESET${TH[sel]:-}"}$TH_RESET"); fi
    else
      _out+=("$DASH_SRV_ROW")
    fi
  done
}

# The first hint a check gave for a requirement (what to do about it) into DASH_SRV_HINT; empty when there is none.
DASH_SRV_HINT=""
dash_srv_hint() { # id
  local rec st msg hint
  local -a recs
  DASH_SRV_HINT=""
  IFS="$PR_RS" read -ra recs <<< "${PR_RECORDS[$1]:-}"
  for rec in "${recs[@]}"; do
    [ -n "$rec" ] || continue
    IFS="$PR_FS" read -r st msg hint <<< "$rec"
    if [ -n "$hint" ]; then DASH_SRV_HINT="$hint"; return 0; fi
  done
}

# The detail of the selected requirement in $2 lines of $1 cells, into DASH_SRV_DET: what it is for, what the check found and how to
# fix it (the install command of this distribution, else the hint of the check, else the page of the guide). Open (Enter), it also gives
# every result with its hint, the command of every package manager when the distribution is not known, and the page of the guide.
DASH_SRV_DET=()
dash_srv_detail() { # width lines
  local w="$1" n="$2" id="${DASH_SRV_ORDER[$DASH_SRV_SEL]:-}" lab why cmd="" rec st msg hint m url l fix=""
  local -a recs
  DASH_SRV_DET=()
  [ -n "$id" ] && [ "$n" -gt 0 ] || return 0
  dt tui.srv.why; lab="$DTV"
  dt "prereq.why.$id"; why="$DTV"
  dash_srv_cmd "$id"; cmd="$DASH_SRV_CMD"
  url="${PR_URL[$id]:-}"
  dash_srv_hint "$id"; hint="$DASH_SRV_HINT"
  if [ "$DASH_SRV_STATE" = "ready" ] && [ "${PR_STATUS[$id]:-}" != "ok" ]; then
    # What to do: the command, or what the check advised, or the guide.
    if [ -n "$cmd" ]; then fix="$cmd"
    elif [ -n "$hint" ]; then fix="$hint"
    elif [ -n "$url" ]; then dt tui.srv.link; fix="$DTV: $url"
    fi
  fi
  if [ "$DASH_SRV_OPEN" -eq 0 ]; then
    tui_fit "${TH[dim]:-}  $UI_S_BL ${TH[accent]:-}$lab:${TH[dim]:-} $why$TH_RESET" "$w"; DASH_SRV_DET+=("$TUI_OUT")
    if [ "$n" -ge 3 ]; then
      dt tui.srv.result
      if [ "$DASH_SRV_STATE" = "ready" ]; then
        dash_srv_kit_state "$id"; kit_state_color "$DASH_SRV_ST"
        tui_fit "${TH[dim]:-}  $UI_S_BL ${TH[accent]:-}$DTV:$TH_RESET $KIT_COL${PR_SUMMARY[$id]:-}$TH_RESET" "$w"
      else
        dt tui.srv.status.checking; tui_fit "${TH[dim]:-}  $UI_S_BL $DTV$TH_RESET" "$w"
      fi
      DASH_SRV_DET+=("$TUI_OUT")
    fi
    if [ -n "$fix" ]; then
      dt tui.srv.how
      if [ -n "$cmd" ]; then tui_fit "${TH[dim]:-}  $UI_S_BL ${TH[accent]:-}$DTV:$TH_RESET $fix" "$w"; else tui_fit "${TH[dim]:-}  $UI_S_BL ${TH[accent]:-}$DTV:${TH[dim]:-} $fix$TH_RESET" "$w"; fi
      DASH_SRV_DET+=("$TUI_OUT")
    elif [ "$DASH_SRV_STATE" = "ready" ] && [ -n "$url" ]; then
      dt tui.srv.link; tui_fit "${TH[dim]:-}  $UI_S_BL ${TH[accent]:-}$DTV:${TH[dim]:-} $url$TH_RESET" "$w"; DASH_SRV_DET+=("$TUI_OUT")
    fi
    [ "${#DASH_SRV_DET[@]}" -le "$n" ] || DASH_SRV_DET=("${DASH_SRV_DET[@]:0:n}")
    return 0
  fi
  # Open: a block per topic, wrapped to the width.
  kit_wrap "$lab: $why" $((w - 4))
  for l in "${KW_LINES[@]}"; do DASH_SRV_DET+=("  ${TH[dim]:-}$l$TH_RESET"); done
  IFS="$PR_RS" read -ra recs <<< "${PR_RECORDS[$id]:-}"
  for rec in "${recs[@]}"; do
    [ -n "$rec" ] || continue
    IFS="$PR_FS" read -r st msg hint <<< "$rec"
    case "$st" in ok) kit_state_icon ok ;; err) kit_state_icon err ;; warn) kit_state_icon warn ;; info) kit_state_icon info ;; *) kit_state_icon pend ;; esac
    kit_wrap "$msg" $((w - 6))
    for l in "${KW_LINES[@]}"; do DASH_SRV_DET+=("  $KIT_ICON $l"); KIT_ICON=" "; done
    if [ -n "$hint" ]; then
      kit_wrap "$hint" $((w - 6))
      for l in "${KW_LINES[@]}"; do DASH_SRV_DET+=("    ${TH[dim]:-}$l$TH_RESET"); done
    fi
  done
  if [ "$DASH_SRV_STATE" = "ready" ] && [ "${PR_STATUS[$id]:-}" != "ok" ]; then
    dt tui.srv.how; lab="$DTV"
    if [ -n "$cmd" ]; then
      DASH_SRV_DET+=("  ${TH[accent]:-}$lab:$TH_RESET $cmd")
    elif [ -z "$PR_MANAGER" ]; then
      # The distribution is not known: the command of every package manager there is.
      dt tui.srv.no_distro; DASH_SRV_DET+=("  ${TH[accent]:-}$lab:$TH_RESET ${TH[dim]:-}$DTV$TH_RESET")
      for m in "${PR_MANAGERS[@]}"; do
        [ -z "${PR_CMD["$id|$m"]:-}" ] || DASH_SRV_DET+=("  ${TH[dim]:-}$m:$TH_RESET ${PR_CMD["$id|$m"]}")
      done
    fi
  fi
  if [ -n "$url" ]; then dt tui.srv.link; DASH_SRV_DET+=("  ${TH[accent]:-}$DTV:$TH_RESET $url"); fi
  [ "${#DASH_SRV_DET[@]}" -le "$n" ] || DASH_SRV_DET=("${DASH_SRV_DET[@]:0:n}")
}

# The box of the requirements, $1 cells wide and $2 high, into DASH_SRV_REQ_BOX.
DASH_SRV_REQ_BOX=()
dash_srv_req_box() { # width height
  local w="$1" h="$2" cw=$(($1 - 4)) inner=$(($2 - 2)) dh lh two=0 colw i n nrec rows foot chips status
  local -a left=() right=() body=() lines=()
  [ "$cw" -lt 100 ] || two=1
  n="${#DASH_SRV_ORDER[@]}"
  nrec=$((n - DASH_SRV_NREQ))
  # The detail takes three lines (two when the box is small); open, as many as it needs, and the list keeps at least three rows.
  if [ "$DASH_SRV_OPEN" -eq 1 ]; then
    # Open: what the detail needs, and the list keeps the rest (at least three rows).
    dash_srv_detail "$cw" $((inner - 3))
    dh="${#DASH_SRV_DET[@]}"
    [ "$dh" -ge 3 ] || dh=3
  elif [ "$inner" -ge 11 ]; then dh=3
  else dh=2; fi
  [ "$dh" -ge 0 ] || dh=0
  lh=$((inner - dh))
  if [ "$lh" -lt 3 ]; then dh=$((inner - 3)); [ "$dh" -ge 0 ] || dh=0; lh=$((inner - dh)); fi
  if [ "$two" -eq 1 ]; then
    colw=$(((cw - 3) / 2))
    dash_srv_group left 0 $((DASH_SRV_NREQ - 1)) "$colw" 0
    if [ "$nrec" -gt 0 ]; then dash_srv_group right "$DASH_SRV_NREQ" $((n - 1)) "$((cw - 3 - colw))" 0; fi
    # The heading of each column stays; below it each column is a window over its own rows, and the one that holds the selection follows it.
    local ltop=0 rtop=0 lc rc
    if [ "$DASH_SRV_SEL" -lt "$DASH_SRV_NREQ" ]; then dash_srv_top $((${#left[@]} - 1)) "$DASH_SRV_SEL" $((lh - 1)); ltop="$DASH_SRV_TOP"; fi
    if [ "$DASH_SRV_SEL" -ge "$DASH_SRV_NREQ" ]; then dash_srv_top $((${#right[@]} - 1)) $((DASH_SRV_SEL - DASH_SRV_NREQ)) $((lh - 1)); rtop="$DASH_SRV_TOP"; fi
    for ((i = 0; i < lh; i++)); do
      if [ "$i" -eq 0 ]; then lc="${left[0]}" rc="${right[0]:-}"; else lc="${left[$((ltop + i))]:-}" rc="${right[$((rtop + i))]:-}"; fi
      tui_fit "$lc" "$colw"; lc="$TUI_OUT"
      body+=("$lc ${TH[border]:-}$UI_S_V$TH_RESET $rc")
    done
  else
    dash_srv_group left 0 $((DASH_SRV_NREQ - 1)) "$cw" 1
    if [ "$nrec" -gt 0 ]; then dash_srv_group right "$DASH_SRV_NREQ" $((n - 1)) "$cw" 1; fi
    lines=("${left[@]}" ${right[@]+"${right[@]}"})
    # The selected row is the row of the requirement plus the heading(s) above it.
    if [ "$DASH_SRV_SEL" -lt "$DASH_SRV_NREQ" ]; then rows=$((DASH_SRV_SEL + 1)); else rows=$((DASH_SRV_SEL + 2)); fi
    dash_srv_top "${#lines[@]}" "$rows" "$lh"
    # (a selection at the top of a group scrolls its heading into view too)
    for ((i = DASH_SRV_TOP; i < DASH_SRV_TOP + lh && i < ${#lines[@]}; i++)); do body+=("${lines[$i]}"); done
  fi
  while [ "${#body[@]}" -lt "$lh" ]; do body+=(""); done
  dash_srv_detail "$cw" "$dh"
  if [ "$dh" -gt 0 ]; then body+=("${DASH_SRV_DET[@]}"); fi
  while [ "${#body[@]}" -lt "$inner" ]; do body+=(""); done
  if [ "$DASH_SRV_STATE" != "ready" ] || [ "$DASH_SRV_BUSY" -eq 1 ]; then
    dt tui.srv.status.checking; status="$DTV"
  else
    dash_srv_t tui.srv.status.req "$DASH_SRV_READY" "$DASH_SRV_NREQ"; status="$DASH_T"
    if [ "$DASH_SRV_REC_PEND" -gt 0 ]; then dash_srv_t tui.srv.status.rec "$DASH_SRV_REC_PEND"; status+=" $UI_S_DOT $DASH_T"; fi
  fi
  dt tui.srv.title.req; chips="$DTV"
  dt tui.srv.foot.req; foot="$DTV"
  kit_box "$w" "$h" body "chips=$chips" "status=$status" "footer=$foot" focus=1
  DASH_SRV_REQ_BOX=("${KIT_BOX[@]}")
}

# --- Drawing: the figures -----------------------------------------------------------------------------------------------

# Rows of the box being built (DASH_SRV_L) and the chips and status it gets; the result is left in DASH_SRV_BOX.
DASH_SRV_L=() DASH_SRV_BOX=()
dash_srv_mbox() { # name width height [status] [chips-extra]
  local title
  dt "tui.srv.title.$1"; title="$DTV"
  [ -z "${5:-}" ] || title+="|$5"
  kit_box "$2" "$3" DASH_SRV_L "chips=$title" "status=${4:-}"
  DASH_SRV_BOX=("${KIT_BOX[@]}")
}

# A line that says a figure is not there: not available on this system, or not read yet.
dash_srv_note() { # kind(na|waiting)
  if [ "$1" = "na" ]; then dt tui.srv.na; else dt tui.srv.waiting; fi
  DASH_SRV_L=("${TH[dim]:-}$DTV$TH_RESET")
}

# The degrees sign for the temperature chip and the arrows of the network and disk speeds.
DASH_DEG="" DASH_DN="" DASH_UPA=""
dash_srv_glyphs() {
  if [ "${UI_UTF8:-0}" -eq 1 ]; then DASH_DEG="°C" DASH_DN="▼" DASH_UPA="▲"; else DASH_DEG=" C" DASH_DN="v" DASH_UPA="^"; fi
}

# CPU: a graph of the total and, when the box is big enough, a floating box over it with the total and every core; else lines.
dash_srv_cpu() { # width height
  local w="$1" h="$2" cw=$(($1 - 4)) ch=$(($2 - 2)) status="" i n row iw ih cr c1 p pad lbl
  local -a inset=() base=()
  DASH_SRV_L=()
  dash_srv_glyphs
  [ -z "$HOST_TEMP_CPU_C" ] || [ "${MT_SRC[temp]:-0}" != 1 ] || status="$HOST_TEMP_CPU_C$DASH_DEG"
  if [ "${MT_SRC[cpu]:-}" = "0" ]; then dash_srv_note na; dash_srv_mbox cpu "$w" "$h"; return 0; fi
  if [ -z "${MT_CPU_ALL:-}" ]; then dash_srv_note waiting; dash_srv_mbox cpu "$w" "$h"; return 0; fi
  n="${#MT_CORE_PCT[@]}"; n=$((n - 1))   # (index 0 is the whole CPU)
  if [ "$ch" -ge 6 ] && [ "$cw" -ge 56 ]; then
    # The graph takes the whole body; the box floats over its right side.
    kit_graph "$MT_HH_CPU" 100 "$cw" "$ch" mag=cpu zero=1
    base=("${KG_LINES[@]}")
    iw=31
    cr=$(((n + 1) / 2))
    ih=$((cr + 4)); [ "$ih" -le "$ch" ] || ih="$ch"
    cr=$((ih - 4))
    kit_meter "$MT_CPU_ALL" 12 cpu
    inset+=("CPU $KIT_OUT ${MT_CPU_ALL}%")
    for ((i = 0; i < cr; i++)); do
      row=""
      for c1 in $((i * 2 + 1)) $((i * 2 + 2)); do
        if [ "$c1" -le "$n" ]; then
          p="${MT_CORE_PCT[$c1]}"
          printf -v lbl 'C%-2d' $((c1 - 1))
          kit_meter "$p" 5 cpu
          printf -v pad '%3d' "$p"
          row+="${row:+ }$lbl$KIT_OUT $pad%"
        fi
      done
      inset+=("$row")
    done
    if [ -n "${HOST_LOAD1:-}" ] && [ "${MT_SRC[load]:-0}" = 1 ]; then
      dt tui.srv.load; inset+=("${TH[dim]:-}$DTV$TH_RESET $HOST_LOAD1 $HOST_LOAD5 $HOST_LOAD15")
    fi
    dash_srv_t tui.srv.cores "$n"
    DASH_SRV_L=("${inset[@]}")
    kit_box "$iw" "$ih" DASH_SRV_L "chips=CPU" "status=$DASH_T"
    inset=("${KIT_BOX[@]}")
    kit_overlay base 0 inset $((cw - iw))
    DASH_SRV_L=("${base[@]}")
  else
    kit_meter "$MT_CPU_ALL" $((cw > 40 ? 24 : cw - 12)) cpu caps=1
    DASH_SRV_L+=("CPU $KIT_OUT ${MT_CPU_ALL}%")
    row=""
    if [ -n "${HOST_LOAD1:-}" ] && [ "${MT_SRC[load]:-0}" = 1 ]; then dt tui.srv.load; row="$DTV $HOST_LOAD1 $HOST_LOAD5 $HOST_LOAD15"; fi
    dash_srv_t tui.srv.cores "$n"; row+="${row:+ $UI_S_DOT }$DASH_T"
    tui_fit "${TH[dim]:-}$row$TH_RESET" "$cw"; DASH_SRV_L+=("$TUI_OUT")
    if [ $((ch - 2)) -ge 2 ]; then
      kit_graph "$MT_HH_CPU" 100 "$cw" $((ch - 2)) mag=cpu zero=1
      DASH_SRV_L+=("${KG_LINES[@]}")
    fi
  fi
  dash_srv_mbox cpu "$w" "$h" "$status"
}

# Memory by kind: the used figure with its meter and graph, then what is available, the total, the cache, what is free and the swap.
dash_srv_mem() { # width height
  local w="$1" h="$2" cw=$(($1 - 4)) ch=$(($2 - 2)) pct sw r pad
  DASH_SRV_L=()
  if [ "${MT_SRC[mem]:-}" = "0" ]; then dash_srv_note na; dash_srv_mbox mem "$w" "$h"; return 0; fi
  if [ -z "${MT_SRC[mem]:-}" ]; then dash_srv_note waiting; dash_srv_mbox mem "$w" "$h"; return 0; fi
  if [ -z "$HOST_MEMD_TOTAL" ] || [ -z "$HOST_MEMD_USED" ] || [ "$HOST_MEMD_TOTAL" -eq 0 ]; then dash_srv_note na; dash_srv_mbox mem "$w" "$h"; return 0; fi
  pct=$((HOST_MEMD_USED * 100 / HOST_MEMD_TOTAL))
  dash_srv_kb "$HOST_MEMD_USED"; dt tui.srv.mem.used; kit_leader "$DTV" "$DASH_SZ" "$cw"; DASH_SRV_L+=("$KIT_OUT")
  printf -v pad '%3d' "$pct"
  kit_meter "$pct" $((cw - 5)) mem; DASH_SRV_L+=("$KIT_OUT $pad%")
  dash_srv_kb "$HOST_MEMD_AVAIL"; dt tui.srv.mem.avail; kit_leader "$DTV" "$DASH_SZ" "$cw"; DASH_SRV_L+=("$KIT_OUT")
  dash_srv_kb "$HOST_MEMD_TOTAL"; dt tui.srv.mem.total; kit_leader "$DTV" "$DASH_SZ" "$cw"; DASH_SRV_L+=("$KIT_OUT")
  r=$((ch - 4))
  if [ "$r" -ge 1 ] && [ -n "$HOST_MEMD_CACHED" ]; then
    dash_srv_kb "$HOST_MEMD_CACHED"; dt tui.srv.mem.cached; kit_leader "$DTV" "$DASH_SZ" "$cw"; DASH_SRV_L+=("$KIT_OUT"); r=$((r - 1))
  fi
  if [ "$r" -ge 1 ] && [ -n "$HOST_MEMD_FREE" ]; then
    dash_srv_kb "$HOST_MEMD_FREE"; dt tui.srv.mem.free; kit_leader "$DTV" "$DASH_SZ" "$cw"; DASH_SRV_L+=("$KIT_OUT"); r=$((r - 1))
  fi
  if [ "$r" -ge 2 ] && [ -n "$HOST_MEMD_SWAP_TOTAL" ] && [ "$HOST_MEMD_SWAP_TOTAL" -gt 0 ]; then
    sw=$((HOST_MEMD_SWAP_USED * 100 / HOST_MEMD_SWAP_TOTAL))
    dash_srv_kb "$HOST_MEMD_SWAP_TOTAL"; dt tui.srv.mem.swap; kit_leader "$DTV" "$DASH_SZ" "$cw"; DASH_SRV_L+=("$KIT_OUT")
    printf -v pad '%3d' "$sw"
    kit_meter "$sw" $((cw - 5)) mem; DASH_SRV_L+=("$KIT_OUT $pad%"); r=$((r - 2))
  fi
  if [ "$r" -ge 2 ]; then
    kit_graph "$MT_HOST_HIST" 100 "$cw" "$r" mag=mem zero=1
    DASH_SRV_L+=("${KG_LINES[@]}")
  fi
  dash_srv_mbox mem "$w" "$h" "$pct%"
}

# Disks: every mount with its use as a meter and its size; the I/O of the disks at the end when there is room.
dash_srv_disks() { # width height
  local w="$1" h="$2" cw=$(($1 - 4)) ch=$(($2 - 2)) i n two=0 shown=0 mw lab pct rows pad rd
  dash_srv_glyphs
  DASH_SRV_L=()
  if [ "${MT_SRC[disk]:-}" = "0" ]; then dash_srv_note na; dash_srv_mbox disks "$w" "$h"; return 0; fi
  if [ -z "${MT_SRC[disk]:-}" ]; then dash_srv_note waiting; dash_srv_mbox disks "$w" "$h"; return 0; fi
  n="$HOST_DISK_N"
  if [ "$n" -eq 0 ]; then dash_srv_note na; dash_srv_mbox disks "$w" "$h"; return 0; fi
  rows="$ch"
  [ -z "$HOST_DISKIO_READ_BPS" ] || rows=$((rows - 1))   # (a line for the I/O)
  [ "$rows" -lt $((n * 2)) ] || two=1
  for ((i = 0; i < n && shown < rows; i++)); do
    dash_srv_kb "${HOST_DISK_TOTAL[$i]:-}"
    pct="${HOST_DISK_PCT[$i]:-0}"
    printf -v pad '%3d' "$pct"
    if [ "$two" -eq 1 ]; then
      kit_leader "${HOST_DISK_MNT[$i]}" "$DASH_SZ" "$cw"; DASH_SRV_L+=("$KIT_OUT")
      kit_meter "$pct" $((cw - 5)) disk; DASH_SRV_L+=("$KIT_OUT $pad%")
      shown=$((shown + 2))
    else
      # One line each: name, meter, percentage and size.
      mw=$((cw - 25))
      [ "$mw" -ge 4 ] || mw=4
      tui_fit "${HOST_DISK_MNT[$i]}" 10; lab="$TUI_OUT"
      kit_meter "$pct" "$mw" disk
      printf -v rd '%8s' "$DASH_SZ"
      tui_fit "$lab $KIT_OUT $pad% $rd" "$cw"; DASH_SRV_L+=("$TUI_OUT")
      shown=$((shown + 1))
    fi
  done
  if [ -n "$HOST_DISKIO_READ_BPS" ] && [ "${#DASH_SRV_L[@]}" -lt "$ch" ]; then
    dt tui.srv.disk.io
    dash_srv_b "$HOST_DISKIO_READ_BPS"; rd="$DASH_SZ/s"
    dash_srv_b "$HOST_DISKIO_WRITE_BPS"
    DASH_SRV_L+=("${TH[dim]:-}$DTV$TH_RESET ${TH[net_down]:-}$DASH_DN$TH_RESET $rd ${TH[net_up]:-}$DASH_UPA$TH_RESET $DASH_SZ/s")
  fi
  dash_srv_mbox disks "$w" "$h"
}

# Network: the main interface as a mirrored graph (download above, upload below) with the speeds and totals under it.
dash_srv_net() { # width height
  local w="$1" h="$2" cw=$(($1 - 4)) ch=$(($2 - 2)) gr up dn lab
  dash_srv_glyphs
  DASH_SRV_L=()
  if [ "${MT_SRC[net]:-}" = "0" ]; then dash_srv_note na; dash_srv_mbox net "$w" "$h"; return 0; fi
  if [ -z "${MT_SRC[net]:-}" ] || [ -z "$HOST_NET_DOWN_BPS" ]; then dash_srv_note waiting; dash_srv_mbox net "$w" "$h" "" "$HOST_NET_MAIN"; return 0; fi
  gr=$((ch - 2))
  if [ "$gr" -ge 2 ]; then
    dn=$((gr / 2)) up=$((gr - dn))
    kit_graph_mirror "$MT_HH_NETD" "$MT_HH_NETU" auto "$cw" "$up" "$dn" axis=1 unit=B
    DASH_SRV_L+=("${KG_LINES[@]}")
  fi
  dt tui.srv.net.top; lab="$DTV"
  dash_srv_b "$HOST_NET_DOWN_BPS"; up="$DASH_SZ/s"
  dash_srv_b "$MT_NET_DOWN_MAX"; dn="$DASH_SZ/s"
  tui_fit "${TH[net_down]:-}$DASH_DN$TH_RESET $up  ${TH[dim]:-}$lab $dn$TH_RESET" "$cw"; DASH_SRV_L+=("$TUI_OUT")
  dash_srv_b "$HOST_NET_UP_BPS"; up="$DASH_SZ/s"
  dash_srv_b "$MT_NET_UP_MAX"; dn="$DASH_SZ/s"
  tui_fit "${TH[net_up]:-}$DASH_UPA$TH_RESET $up  ${TH[dim]:-}$lab $dn$TH_RESET" "$cw"; DASH_SRV_L+=("$TUI_OUT")
  dash_srv_uptime "$HOST_UPTIME_S"
  lab=""
  if [ -n "$DASH_UPT" ]; then dash_srv_t tui.srv.up "$DASH_UPT"; lab="$DASH_T"; fi
  dash_srv_mbox net "$w" "$h" "$lab" "$HOST_NET_MAIN"
}

# Containers: every service with its CPU trend, memory and state (the same figures as the Resources view).
dash_srv_containers() { # width height
  local w="$1" h="$2" cw=$(($1 - 4)) ch=$(($2 - 2)) name svc key mem lim st
  local -a cols=() rows=()
  DASH_SRV_L=()
  dt tui.res.col.svc; cols+=("$DTV|4|l")
  dt tui.res.col.instance; cols+=("$DTV|*|l")
  dt tui.res.col.cpu; cols+=("$DTV|12|l|spark")
  dt tui.res.col.mem; cols+=("$DTV|16|r")
  dt tui.res.col.state; cols+=("$DTV|12|l")
  for name in "${DASH_NAMES[@]}"; do
    for svc in ${DASH_SVCS[$name]:-}; do
      key="$name/$svc"
      st="${DASH_SYM[${DSV_KIND[$key]:-dim}]} ${DSV_TEXT[$key]:-}"
      if [ -n "${MT_MEM[$key]:-}" ]; then
        mt_bytes_v "${MT_MEM[$key]}"; mem="$MT_B"
        lim="${MT_LIM[$key]:-0}"
        if [ "$lim" -gt 0 ]; then mt_bytes_v "$lim"; mem+="/$MT_B"; fi
      else
        mem="-"
      fi
      rows+=("$svc$KIT_SEP$name$KIT_SEP${MT_HCPU[$key]:-}$KIT_SEP$mem$KIT_SEP$st")
    done
  done
  dt tui.res.none
  kit_table "$cw" "$ch" cols rows mag=cpu "empty=$DTV"
  # (the table always marks a row; this one is only to look at: nothing is selected)
  DASH_SRV_L=("${KTB_LINES[@]#"$TUI_SEL"}")
  dash_srv_mbox containers "$w" "$h" "$KTB_COUNT"
}

# --- The view ---------------------------------------------------------------------------------------------------------

# The boxes of one row side by side, $1 lines high, into TUI_FRAME. $2 is the array of their widths and $3.. the functions that draw
# them (each one takes a width and a height and leaves its lines in DASH_SRV_BOX).
DASH_SRV_FLAT=()
dash_srv_row_boxes() { # height widths-array fn...
  local h="$1" i k line n
  local -n _wd="$2"
  local -a fns
  shift 2
  fns=("$@")
  n="${#fns[@]}"
  DASH_SRV_FLAT=()
  for ((i = 0; i < n; i++)); do
    "${fns[$i]}" "${_wd[$i]}" "$h"
    for ((k = 0; k < h; k++)); do DASH_SRV_FLAT[i * h + k]="${DASH_SRV_BOX[$k]:-}"; done
  done
  for ((k = 0; k < h; k++)); do
    line=""
    for ((i = 0; i < n; i++)); do line+="${DASH_SRV_FLAT[i * h + k]}"; done
    TUI_FRAME+=("$line")
  done
}

scr_server_render() { # width height
  local w="$1" h="$2" rh ah bh wide=0
  [ "$w" -lt 120 ] || wide=1
  local -a wa=() wb=()
  # Rows: the requirements, the first row of boxes (CPU, memory, and the disks when wide) and the second (the network and the
  # containers when wide; the disks and the network when not). What does not fit goes: the second row first.
  if [ "$DASH_SRV_ZOOM" -eq 1 ]; then lay_split "$h" "0:0:0" "10:8:14:3" "9:6:14:2:1"; else lay_split "$h" "14:9:14:1" "10:8:12:3" "9:6:12:2:1"; fi
  rh="${LAY[0]}" ah="${LAY[1]}" bh="${LAY[2]}"
  # A row too small to draw a box (under 4 lines) gives its lines to the requirements, or to the first row.
  if [ "$ah" -gt 0 ] && [ "$ah" -lt 4 ]; then rh=$((rh + ah)); ah=0; fi
  if [ "$bh" -gt 0 ] && [ "$bh" -lt 4 ]; then if [ "$ah" -gt 0 ]; then ah=$((ah + bh)); else rh=$((rh + bh)); fi; bh=0; fi
  if [ "$DASH_SRV_ZOOM" -eq 0 ] && [ "$rh" -ge 4 ]; then
    dash_srv_req_box "$w" "$rh"
    TUI_FRAME+=("${DASH_SRV_REQ_BOX[@]}")
  fi
  if [ "$ah" -gt 0 ]; then
    if [ "$wide" -eq 1 ]; then lay_split "$w" "48:34::3" "38:26::2" "40:30::2"; else lay_split "$w" "44:30::3" "36:26::2"; fi
    wa=("${LAY[@]}")
    if [ "$wide" -eq 1 ]; then dash_srv_row_boxes "$ah" wa dash_srv_cpu dash_srv_mem dash_srv_disks; else dash_srv_row_boxes "$ah" wa dash_srv_cpu dash_srv_mem; fi
  fi
  if [ "$bh" -gt 0 ]; then
    if [ "$wide" -eq 1 ]; then lay_split "$w" "44:34::1" "0:50::2"; else lay_split "$w" "42:30::1" "38:28::1"; fi
    wb=("${LAY[@]}")
    if [ "$wide" -eq 1 ]; then dash_srv_row_boxes "$bh" wb dash_srv_net dash_srv_containers; else dash_srv_row_boxes "$bh" wb dash_srv_disks dash_srv_net; fi
  fi
}

scr_server_key() { # key
  local n="${#DASH_SRV_ORDER[@]}"
  [ "$DASH_SRV_ZOOM" -eq 0 ] || case "$1" in up | down | k | j | pgup | pgdn | home | end | enter | space | c) return 0 ;; esac
  case "$1" in
    up | k) [ "$DASH_SRV_SEL" -le 0 ] || DASH_SRV_SEL=$((DASH_SRV_SEL - 1)) ;;
    down | j) [ "$DASH_SRV_SEL" -ge $((n - 1)) ] || DASH_SRV_SEL=$((DASH_SRV_SEL + 1)) ;;
    pgup) DASH_SRV_SEL=$((DASH_SRV_SEL - 5)); [ "$DASH_SRV_SEL" -ge 0 ] || DASH_SRV_SEL=0 ;;
    pgdn) DASH_SRV_SEL=$((DASH_SRV_SEL + 5)); [ "$DASH_SRV_SEL" -lt "$n" ] || DASH_SRV_SEL=$((n - 1)) ;;
    home) DASH_SRV_SEL=0 ;;
    end) DASH_SRV_SEL=$((n - 1)) ;;
    enter | space) DASH_SRV_OPEN=$((1 - DASH_SRV_OPEN)) ;;
    c) dash_srv_copy_sel ;;
    m) DASH_SRV_ZOOM=$((1 - DASH_SRV_ZOOM)); DASH_SRV_OPEN=0 ;;
    R) dash_srv_request; dash_msg info "$(t tui.srv.checking)" ;;
  esac
}

scr_server_keys() { # width
  if [ "$DASH_SRV_ZOOM" -eq 1 ]; then dash_keys_view server_met "$1"; else dash_keys_view server "$1"; fi
}
scr_server_texts() {
  DASH_KEYS[server]="$(t tui.keys.server "$DASH_UD" "$DASH_LR")"
  DASH_KEYS[server_met]="$(t tui.keys.server_met)"
}
scr_server_sig() { DASH_SIG+="|$DASH_SRV_SEL|$DASH_SRV_OPEN|$DASH_SRV_ZOOM|$DASH_SRV_STATE|$DASH_SRV_BUSY|$DASH_SRV_N"; }

# Esc: first the detail, then the metrics view; else leave the view.
scr_server_back() {
  if [ "$DASH_SRV_OPEN" -eq 1 ]; then DASH_SRV_OPEN=0; return 0; fi
  if [ "$DASH_SRV_ZOOM" -eq 1 ]; then DASH_SRV_ZOOM=0; return 0; fi
  return 1
}

# The first time the view is chosen it asks for the check; the figures of the server start being read.
scr_server_enter() {
  [ "$DASH_SRV_STATE" != "none" ] || dash_srv_request
  MT_LAST_US=0
}

# Every turn of the loop, whatever the view: the answer of the background check, and the figures of the server read only while this view
# is the current one (the first sample after choosing it comes at once).
scr_server_tick() {
  if dash_async_take prereq; then dash_srv_apply "$DASH_AS_TEXT"; fi
  if [ "$DASH_VIEW" = "server" ]; then
    if [ "$MT_HOST_DETAIL" -ne 1 ]; then MT_HOST_DETAIL=1 MT_LAST_US=0; fi
    if [ "$DASH_SRV_STATE" = "none" ]; then dash_srv_request; fi
  elif [ "$MT_HOST_DETAIL" -ne 0 ]; then
    MT_HOST_DETAIL=0
  fi
}

# Only while the view is current and the panel runs: the requirements are checked again every DASH_SRV_EVERY seconds.
scr_server_poll() {
  tui_test_mode && return 0
  if [ "$DASH_SRV_BUSY" -eq 0 ] && [ $((SECONDS - DASH_SRV_AT)) -ge "$DASH_SRV_EVERY" ]; then dash_srv_request; fi
}

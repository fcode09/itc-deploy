#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Screen: Server (view 1, the one the panel opens on). What the server needs for deltactl to work (the requirements of lib/core/prereqs.sh,
# with what each one is for and the command that installs it) and how the server is doing (CPU, memory, disks, network, the containers),
# drawn as btop does: boxes with chips in their border, braille graphs, gradient meters and a mirrored network graph. It is built from the
# UI kit (lib/ui/kit/*).
#
# The top of the view is a STRIP of three rows: the requirements (`9/9 listos`) and the vital signs of the server (disk, load, uptime,
# network) with the warnings that are active. While everything required is fine it stays a strip; when something required fails or warns it
# opens by itself into the list of requirements (grouped as required and recommended, what is pending or failing first) with the detail of
# the selected one in its own zone (what it is for, the whole result, how to fix it, where to read more); Enter opens it by hand, Esc closes it.
#
# The requirements are checked in the background (a check can ask Docker or open a TCP connection, which takes seconds) and shown as soon as
# they arrive; they are checked again every 2 minutes while the view is on screen, and with R. The panel NEVER installs anything: `c` copies
# the command of the selected requirement and `!` asks (lib/screens/srvask.sh) before running it in the terminal, where sudo asks for the password.
# The figures of the server (lib/core/metrics.sh, MT_HOST_DETAIL=1) are read while this view is current (DASH_SRV_ALWAYS=1 would read them always: the
# cost measured, 30-40 ms per sample against the 0.3 points of CPU that were allowed, does not allow it; see docs/panel-pendiente.md).
#
# The warnings (dash_srv_alerts) have fixed thresholds that an environment variable moves: DELTACTL_ALERT_DISK_WARN / _DISK_ERR (percent
# used, 85 / 95), DELTACTL_ALERT_MEM_AVAIL (percent available below which it warns, 10; below half of it, it is an error),
# DELTACTL_ALERT_SWAP (percent of swap in use, 50), DELTACTL_ALERT_LOAD_PCT (load of one minute over the cores, in percent, 100),
# DELTACTL_ALERT_TEMP_MARGIN (degrees below the critical temperature of the CPU, 10).
#
# Below the strip the figures are boxes: cpu, memory, disks, network, containers (lib/screens/server_boxes.sh) and, on a tall screen, the busiest
# processes and the ports that listen (lib/screens/server_ps.sh, the only ones that start a program, in the background). How they are laid out
# depends on the size of the screen (see scr_server_render): the more room, the more boxes side by side, the more columns, the longer the history.
#
# Keys. One box has the focus (Tab and Shift+Tab move it; DASH_SRV_FOCUS): Up/Down choose a requirement or a container (or a process or a port) ·
# Enter opens the detail of a requirement or the instance of a container · c copies the command · ! runs it (asks first) · l opens the logs of a
# container · s sorts the containers · h shows or hides the services that were never created · z zooms the box that has the focus (it shows
# everything it has) · m shows only the figures (the strip gives its room to them) · R checks again · Esc steps back: the zoom, the detail, the
# list, the figures-only view, then the panel. The mouse (when it is on): a click focuses a box (a second click on a row does what Enter does,
# a click on the strip opens the requirements), the wheel moves the cursor of the box that has the focus.

DASH_SRV_SEL=0           # the requirement under the cursor (index into DASH_SRV_ORDER)
DASH_SRV_OPEN=0          # 1: the detail of the requirement is open (every result, with its hint)
DASH_SRV_REQ=auto        # auto: the list of requirements opens by itself when something required fails | open: opened by hand (Enter)
DASH_SRV_ZOOM=0          # 1: only the metrics (m)
DASH_SRV_FOCUS=req       # the box that has the keys: req, cpu, mem, disks, net, containers, procs or ports
DASH_SRV_PZ=""           # the box that is zoomed (z): it takes the whole body and shows everything it has
DASH_SRV_ZM=0            # 1 while a zoomed box is being drawn
DASH_SRV_STATE=none      # none (never asked) | loading (first answer pending) | ready
DASH_SRV_BUSY=0          # 1 while a check runs (the previous answer stays on screen)
DASH_SRV_N=0             # answers applied, for the frame signature
DASH_SRV_AT=0            # SECONDS of the last request
DASH_SRV_EVERY=120       # seconds between two checks while the view is on screen (a check starts a few dozen processes: ~0.35 s)
DASH_SRV_STARTUP=0       # 1: the panel just started and the first answer decides whether to open this view
DASH_SRV_SKIP=0          # 1: the person chose to create instances although something required is missing
DASH_PREREQ=1            # TUI_PREREQ: warn about the missing requirements (Options)
DASH_SRV_ORDER=()        # ids of the requirements as they are listed: the required ones first, then the recommended ones
DASH_SRV_NREQ=0          # how many of them are required
DASH_SRV_BAD=0 DASH_SRV_BAD_NAMES="" DASH_SRV_READY=0 DASH_SRV_REC_PEND=0 DASH_SRV_RWARN=0

# How urgent a requirement is (0 fails, 1 warns, 2 is pending or still to do, 3 is fine) into DASH_SRV_RK. Before the first answer nothing is.
DASH_SRV_RK=2
dash_srv_rank() { # id
  DASH_SRV_RK=2
  [ "$DASH_SRV_STATE" = "ready" ] || return 0
  case "${PR_STATUS[$1]:-}" in err) DASH_SRV_RK=0 ;; warn) DASH_SRV_RK=1 ;; ok) DASH_SRV_RK=3 ;; esac
}

# The requirements in the order they are shown: the required ones first, then the recommended ones; inside each group what fails comes
# first, then what warns, then what is pending, then what is fine (the order of the catalog inside each). Before the first answer: the catalog.
dash_srv_order() {
  local id rk lvl
  DASH_SRV_ORDER=() DASH_SRV_NREQ=0
  local -A rank=()
  for id in "${PR_IDS[@]}"; do dash_srv_rank "$id"; rank[$id]="$DASH_SRV_RK"; done
  for lvl in required recommended; do
    for rk in 0 1 2 3; do
      for id in "${PR_IDS[@]}"; do
        [ "${rank[$id]}" -eq "$rk" ] || continue
        if [ "${PR_LEVEL[$id]}" = "required" ]; then
          [ "$lvl" = required ] || continue
          DASH_SRV_NREQ=$((DASH_SRV_NREQ + 1))
        else
          [ "$lvl" = recommended ] || continue
        fi
        DASH_SRV_ORDER+=("$id")
      done
    done
  done
}
dash_srv_order

# Orders them again keeping the cursor on the same requirement (an answer can move what fails to the top).
dash_srv_reorder() {
  local keep="${DASH_SRV_ORDER[$DASH_SRV_SEL]:-}" i
  dash_srv_order
  [ -z "$keep" ] || for i in "${!DASH_SRV_ORDER[@]}"; do [ "${DASH_SRV_ORDER[$i]}" != "$keep" ] || DASH_SRV_SEL="$i"; done
}

# A text with {1} {2} {3} filled in, into DASH_T (cached like dt, so no process).
DASH_T=""
dash_srv_t() { # key [a] [b] [c]
  dt "$1"
  DASH_T="${DTV//\{1\}/"${2:-}"}"   # (quoted: with patsub_replacement, Bash 5.2+, an & in the value would become the matched text)
  DASH_T="${DASH_T//\{2\}/"${3:-}"}"
  DASH_T="${DASH_T//\{3\}/"${4:-}"}"
}

# A text fitted to $2 cells (padded, or cut ending in … so a cut is never silent) into TUI_OUT. Colours are kept.
dash_srv_fit() { # text width
  local w="$2"
  tui_vlen "$1"
  if [ "$TUI_VL" -le "$w" ]; then TUI_OUT="$1${TUI_SPACES:0:$((w - TUI_VL))}"; return 0; fi
  if [ "$w" -le 1 ]; then tui_clip "$1" "$w"; return 0; fi
  tui_clip "$1" $((w - 1))
  TUI_OUT="$TUI_OUT$TH_RESET$UI_S_ELL"
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

# A decimal figure of the kernel ("3.18", "0.5", "12") in hundredths (318, 50, 1200) into DASH_HU; 0 when it is not a number.
DASH_HU=0
dash_srv_hund() { # figure
  local v="$1" i f
  DASH_HU=0
  [[ "$v" =~ ^[0-9]+([.][0-9]*)?$ ]] || return 0
  i="${v%%.*}"
  f=""; [ "$i" = "$v" ] || f="${v#*.}"
  f="${f}00"; f="${f:0:2}"
  DASH_HU=$((10#$i * 100 + 10#$f))
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
# DASH_SRV_BAD_NAMES), DASH_SRV_RWARN warn and DASH_SRV_REC_PEND recommended ones are still to do.
dash_srv_counts() {
  local id st
  DASH_SRV_READY=0 DASH_SRV_BAD=0 DASH_SRV_BAD_NAMES="" DASH_SRV_REC_PEND=0 DASH_SRV_RWARN=0
  [ "$DASH_SRV_STATE" = "ready" ] || return 0
  for id in "${DASH_SRV_ORDER[@]}"; do
    st="${PR_STATUS[$id]:-}"
    if [ "${PR_LEVEL[$id]}" = "required" ]; then
      case "$st" in
        ok | info) DASH_SRV_READY=$((DASH_SRV_READY + 1)) ;;
        err) DASH_SRV_BAD=$((DASH_SRV_BAD + 1)); dt "prereq.name.$id"; DASH_SRV_BAD_NAMES+="${DASH_SRV_BAD_NAMES:+, }$DTV" ;;
        warn) DASH_SRV_RWARN=$((DASH_SRV_RWARN + 1)) ;;
      esac
    else
      [ "$st" = "ok" ] || DASH_SRV_REC_PEND=$((DASH_SRV_REC_PEND + 1))
    fi
  done
}

# Is the list of requirements open? By hand (Enter), or by itself because something required fails or warns.
dash_srv_expanded() {
  [ "$DASH_SRV_STATE" = "ready" ] || return 1
  [ "$DASH_SRV_REQ" = "open" ] || [ "$DASH_SRV_BAD" -gt 0 ] || [ "$DASH_SRV_RWARN" -gt 0 ]
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
  dash_srv_reorder
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

# What the first answer after the panel started does: with something required missing it says so and, when nobody went anywhere else
# from the view the panel started on, opens this view (when the panel starts on it, that is already so).
dash_srv_after_apply() {
  [ "$DASH_SRV_STARTUP" -eq 1 ] || return 0
  DASH_SRV_STARTUP=0
  [ "$DASH_SRV_BAD" -gt 0 ] || return 0
  dash_msg warn "$(t tui.srv.startup "$DASH_SRV_BAD" "$DASH_SRV_BAD_NAMES")"
  if [ "$DASH_VIEW" != "server" ] && [ "$DASH_VIEW" = "${DASH_START_VIEW:-instances}" ] && [ "$DASH_MODE" = "normal" ]; then dash_screen_goto server; fi
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

# Puts a text in the clipboard: a tool of the desktop when there is one (DELTACTL_CLIP replaces them, only inside the tests: a command that
# reads the text from its input), else the terminal's own clipboard (OSC 52, which most terminals accept). Returns 1 when nothing could take it.
DASH_SRV_COPIED=""
dash_srv_copy() { # text
  local text="$1" tool
  DASH_SRV_COPIED=""
  if host_test_hook && [ -n "${DELTACTL_CLIP:-}" ]; then
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

# Has this requirement no answer to act on yet? It is waiting for another one (the daemon of a Docker that is not installed: its command
# would fail) or its check has not answered. There is nothing to copy or run for it.
dash_srv_waiting() { # id
  [ "$DASH_SRV_STATE" != "ready" ] && return 0
  case "${PR_STATUS[$1]:-}" in na | "") return 0 ;; esac
  return 1
}

# `c`: copies the install command of the selected requirement.
dash_srv_copy_sel() {
  local id="${DASH_SRV_ORDER[$DASH_SRV_SEL]:-}"
  [ -n "$id" ] || return 0
  if dash_srv_waiting "$id"; then dash_msg info "$(t tui.srv.nothing_wait)"; return 0; fi
  dash_srv_cmd "$id"
  if [ -z "$DASH_SRV_CMD" ]; then dash_msg warn "$(t tui.srv.nothing_cmd)"; return 0; fi
  if dash_srv_copy "$DASH_SRV_CMD"; then
    if [ "$DASH_SRV_COPIED" = "term" ]; then dash_msg ok "$(t tui.srv.copied_term "$DASH_SRV_CMD")"; else dash_msg ok "$(t tui.srv.copied "$DASH_SRV_CMD")"; fi
  else
    dash_msg warn "$(t tui.srv.copy_none "$DASH_SRV_CMD")"
  fi
}

# The command runs in the real terminal (the panel steps aside and comes back), so sudo can ask for the password. Only srvask.sh calls it,
# after the person said yes. DELTACTL_PR_SHELL replaces bash, only inside the tests.
DASH_SRV_SHELL=bash
dash_srv_shell() { # -> the program that runs a confirmed command
  if host_test_hook && [ -n "${DELTACTL_PR_SHELL:-}" ]; then printf '%s' "$DELTACTL_PR_SHELL"; else printf bash; fi
}
dash_srv_terminal() { # command
  local cmd="$1" rc=0
  dash_msg info "$(t tui.srv.terminal "$cmd")"
  tui_leave
  printf '\n  %s%s %s%s\n\n' "$C_GRY" "$UI_S_ARROW" "$cmd" "$C_OFF"
  dash_prompt_name
  dash_con_add "${TH[accent]:-$C_CYN}$DASH_PN $(dash_prompt_glyph)$C_OFF $cmd"
  DASH_SRV_SHELL="$(dash_srv_shell)"
  "$DASH_SRV_SHELL" -c "$cmd" || rc=$?   # (the code is taken here: in the message it would be the one of the previous substitution)
  if [ "$rc" -ne 0 ]; then printf '\n  %s %s\n' "$(ui_sym err)" "$(t menu.cmd_failed "$rc")"; fi
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
  [ "$DASH_SRV_ZOOM" -eq 0 ] || return 0   # only the metrics are on screen: the requirement that would run is not shown
  [ -n "$id" ] || return 0
  if dash_srv_waiting "$id"; then dash_msg info "$(t tui.srv.nothing_wait)"; return 0; fi
  if [ "${PR_STATUS[$id]:-}" = "ok" ]; then dash_msg info "$(t tui.srv.nothing)"; return 0; fi
  dash_srv_cmd "$id"
  if [ -z "$DASH_SRV_CMD" ]; then dash_msg warn "$(t tui.srv.nothing_cmd)"; return 0; fi
  dash_srv_ask_run "$DASH_SRV_CMD"
}

# --- The warnings -----------------------------------------------------------------------------------------------------

# What is wrong with the server right now, from the figures and the requirements already in memory (no process, no reading):
# DASH_SRV_ALERTS holds one "kind|box|text" per warning (kind err or warn; errors first), DASH_SRV_AL[box] the worst kind of each box of the
# view (1 warn, 2 err: the border of that box takes its colour) and DASH_SRV_ALKEY everything that was found, for the memo keys of the boxes.
# The thresholds are fixed and an environment variable moves each one (see the header of this file).
DASH_SRV_ALERTS=() DASH_SRV_ALKEY="" DASH_THR=0
declare -gA DASH_SRV_AL=()
dash_srv_thr() { # variable default -> DASH_THR
  local v="${!1:-}"
  [[ "$v" =~ ^[0-9]+$ ]] || v="$2"
  DASH_THR="$v"
}
dash_srv_alerts() {
  local i n pct ta sw kind key warnat errat cores l1 cap crit margin names
  local -a errs=() warns=()
  DASH_SRV_ALERTS=() DASH_SRV_AL=()
  # The disks.
  if [ "${MT_SRC[disk]:-0}" = 1 ]; then
    dash_srv_thr DELTACTL_ALERT_DISK_WARN 85; warnat="$DASH_THR"
    dash_srv_thr DELTACTL_ALERT_DISK_ERR 95; errat="$DASH_THR"
    for ((i = 0; i < HOST_DISK_N; i++)); do
      pct="${HOST_DISK_PCT[$i]:-0}"
      [[ "$pct" =~ ^[0-9]+$ ]] || continue
      if [ "$pct" -ge "$errat" ]; then dash_srv_t tui.srv.al.disk "${HOST_DISK_MNT[$i]}" "$pct"; errs+=("err|disks|$DASH_T")
      elif [ "$pct" -ge "$warnat" ]; then dash_srv_t tui.srv.al.disk "${HOST_DISK_MNT[$i]}" "$pct"; warns+=("warn|disks|$DASH_T"); fi
    done
  fi
  # The memory (what is available, not what is free: the cache is not a problem) and the swap.
  if [ "${MT_SRC[mem]:-0}" = 1 ] && [[ "${HOST_MEMD_TOTAL:-}" =~ ^[0-9]+$ ]] && [ "$HOST_MEMD_TOTAL" -gt 0 ] && [[ "${HOST_MEMD_AVAIL:-}" =~ ^[0-9]+$ ]]; then
    dash_srv_thr DELTACTL_ALERT_MEM_AVAIL 10; ta="$DASH_THR"
    pct=$((HOST_MEMD_AVAIL * 100 / HOST_MEMD_TOTAL))
    if [ "$pct" -lt $((ta / 2)) ]; then dash_srv_t tui.srv.al.mem "$pct"; errs+=("err|mem|$DASH_T")
    elif [ "$pct" -lt "$ta" ]; then dash_srv_t tui.srv.al.mem "$pct"; warns+=("warn|mem|$DASH_T"); fi
    dash_srv_thr DELTACTL_ALERT_SWAP 50; sw="$DASH_THR"
    if [[ "${HOST_MEMD_SWAP_TOTAL:-}" =~ ^[0-9]+$ ]] && [ "$HOST_MEMD_SWAP_TOTAL" -gt 0 ] && [[ "${HOST_MEMD_SWAP_USED:-}" =~ ^[0-9]+$ ]]; then
      pct=$((HOST_MEMD_SWAP_USED * 100 / HOST_MEMD_SWAP_TOTAL))
      if [ "$pct" -ge "$sw" ]; then dash_srv_t tui.srv.al.swap "$pct"; warns+=("warn|mem|$DASH_T"); fi
    fi
  fi
  # The load of one minute over the cores (more runnable work than the server can run at once).
  if [ "${MT_SRC[load]:-0}" = 1 ] && [ -n "${HOST_LOAD1:-}" ]; then
    cores=$((${#MT_CORE_PCT[@]} - 1))
    if [ "$cores" -gt 0 ]; then
      dash_srv_thr DELTACTL_ALERT_LOAD_PCT 100; cap="$DASH_THR"
      dash_srv_hund "$HOST_LOAD1"; l1="$DASH_HU"
      if [ "$l1" -gt $((cores * cap)) ]; then dash_srv_t tui.srv.al.load "$HOST_LOAD1" "$cores"; warns+=("warn|cpu|$DASH_T"); fi
    fi
  fi
  # The temperature of the processor, near the limit its sensor reports (without a limit there is nothing to compare with).
  if [ "${MT_SRC[temp]:-0}" = 1 ] && [[ "${HOST_TEMP_CPU_C:-}" =~ ^[0-9]+$ ]] && [[ "${HOST_TEMP_CPU_CRIT:-}" =~ ^[0-9]+$ ]]; then
    dash_srv_thr DELTACTL_ALERT_TEMP_MARGIN 10; margin="$DASH_THR"
    crit="$HOST_TEMP_CPU_CRIT"
    if [ "$HOST_TEMP_CPU_C" -ge "$crit" ]; then dash_srv_t tui.srv.al.temp "$HOST_TEMP_CPU_C" "$crit"; errs+=("err|cpu|$DASH_T")
    elif [ "$HOST_TEMP_CPU_C" -ge $((crit - margin)) ]; then dash_srv_t tui.srv.al.temp "$HOST_TEMP_CPU_C" "$crit"; warns+=("warn|cpu|$DASH_T"); fi
  fi
  # The containers that are not well (a service that was never created is not a problem: it is just not there).
  for key in "${!DSV_KIND[@]}"; do
    kind="${DSV_KIND[$key]}"
    case "$kind" in err | warn) ;; *) continue ;; esac
    dash_srv_t tui.srv.al.cont "$key" "${DSV_TEXT[$key]:-}"
    if [ "$kind" = err ]; then errs+=("err|containers|$DASH_T"); else warns+=("warn|containers|$DASH_T"); fi
  done
  # The requirements: what is required and fails, what is required and warns, and the clock.
  if [ "$DASH_SRV_STATE" = "ready" ]; then
    if [ "$DASH_SRV_BAD" -gt 0 ]; then dash_srv_t tui.srv.al.req "$DASH_SRV_BAD"; errs+=("err|req|$DASH_T"); fi
    if [ "$DASH_SRV_RWARN" -gt 0 ]; then dash_srv_t tui.srv.al.reqw "$DASH_SRV_RWARN"; warns+=("warn|req|$DASH_T"); fi
    if [ "${PR_STATUS[timesync]:-}" = "info" ]; then
      dt prereq.time_off
      if [ "${PR_SUMMARY[timesync]:-}" = "$DTV" ]; then dt tui.srv.al.ntp; warns+=("warn|req|$DTV"); fi
    fi
  fi
  DASH_SRV_ALERTS=(${errs[@]+"${errs[@]}"} ${warns[@]+"${warns[@]}"})
  names=""
  for n in "${DASH_SRV_ALERTS[@]}"; do
    key="${n#*|}"; key="${key%%|*}"
    case "${n%%|*}" in err) DASH_SRV_AL[$key]=2 ;; *) [ "${DASH_SRV_AL[$key]:-0}" -ge 1 ] || DASH_SRV_AL[$key]=1 ;; esac
    names+="$n;"
  done
  DASH_SRV_ALKEY="$names"
}

# --- Drawing: the strip and the requirements ----------------------------------------------------------------------------

# The first row of a window of $3 rows over $1 rows that keeps row $2 in view, into DASH_SRV_TOP.
DASH_SRV_TOP=0
dash_srv_top() { # total selected rows
  local top=0
  [ "$2" -lt "$3" ] || top=$(($2 - $3 + 1))
  [ $((top + $3)) -le "$1" ] || top=$(($1 - $3))
  [ "$top" -ge 0 ] || top=0
  DASH_SRV_TOP="$top"
}

# The vital signs of the server on one line of $1 cells, and the warnings, into DASH_SRV_VIT: the disk of /, the load with its trend and the
# cores, the uptime, the network, and what is wrong (or that nothing is). What does not fit is dropped whole, from the right, except the
# warnings, which are cut with … when even they alone do not fit.
DASH_SRV_VIT=""
dash_srv_vitals() { # width
  local w="$1" i root=0 pct cores l1 l5 trend sp alert plain dim="${TH[dim]:-}" sep n first kind text
  local -a pcs=()
  dash_srv_glyphs
  sep=" ${TH[dim]:-}$UI_S_DOT$TH_RESET "
  if [ "${MT_SRC[disk]:-0}" = 1 ] && [ "$HOST_DISK_N" -gt 0 ]; then
    for ((i = 0; i < HOST_DISK_N; i++)); do [ "${HOST_DISK_MNT[$i]}" != "/" ] || root="$i"; done
    pct="${HOST_DISK_PCT[$root]:-0}"
    [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
    th_grad disk "$pct"
    dash_srv_t tui.srv.vit.disk "${HOST_DISK_MNT[$root]}" "$pct"
    pcs+=("$TH_C$DASH_T$TH_RESET")
  fi
  if [ "${MT_SRC[load]:-0}" = 1 ] && [ -n "${HOST_LOAD1:-}" ]; then
    cores=$((${#MT_CORE_PCT[@]} - 1))
    dash_srv_hund "$HOST_LOAD1"; l1="$DASH_HU"
    dash_srv_hund "$HOST_LOAD5"; l5="$DASH_HU"
    trend="$UI_S_FLAT"
    if [ $((l1 * 10)) -gt $((l5 * 11)) ]; then trend="$UI_S_RISE"; elif [ $((l1 * 11)) -lt $((l5 * 10)) ]; then trend="$UI_S_FALL"; fi
    if [ "$cores" -gt 0 ]; then dash_srv_t tui.srv.vit.load "$HOST_LOAD1" "$trend" "$cores"; else dash_srv_t tui.srv.vit.load1 "$HOST_LOAD1" "$trend"; fi
    pcs+=("$DASH_T")
  fi
  if [ "${MT_SRC[uptime]:-0}" = 1 ]; then
    dash_srv_uptime "$HOST_UPTIME_S"
    if [ -n "$DASH_UPT" ]; then dash_srv_t tui.srv.up "$DASH_UPT"; pcs+=("$DASH_T"); fi
  fi
  if [ "${MT_SRC[net]:-0}" = 1 ] && [ -n "${HOST_NET_DOWN_BPS:-}" ]; then
    dash_srv_b "$HOST_NET_DOWN_BPS"; sp="${TH[net_down]:-}$DASH_DN$TH_RESET $DASH_SZ/s"
    dash_srv_b "$HOST_NET_UP_BPS"; sp+=" ${TH[net_up]:-}$DASH_UPA$TH_RESET $DASH_SZ/s"
    pcs+=("$sp")
  fi
  # The warning (or the lack of them), last in the line but the one that is kept.
  if [ "${#DASH_SRV_ALERTS[@]}" -gt 0 ]; then
    kind="${DASH_SRV_ALERTS[0]%%|*}" text="${DASH_SRV_ALERTS[0]#*|}"; text="${text#*|}"
    kit_state_icon "$kind"
    if [ "${#DASH_SRV_ALERTS[@]}" -gt 1 ]; then dash_srv_t tui.srv.al.n "${#DASH_SRV_ALERTS[@]}" "$text"; text="$DASH_T"; fi
    alert="$KIT_ICON $KIT_COL$text$TH_RESET"
  else
    kit_state_icon ok; dt tui.srv.al.none
    alert="$KIT_ICON $dim$DTV$TH_RESET"
  fi
  n="${#pcs[@]}"
  while :; do
    first=""
    for ((i = 0; i < n; i++)); do first+="${pcs[$i]}$sep"; done
    plain="$first$alert"
    tui_vlen "$plain"
    [ "$TUI_VL" -le "$w" ] && break
    [ "$n" -gt 0 ] || break
    n=$((n - 1))
  done
  dash_srv_fit " $plain" "$w"
  DASH_SRV_VIT="$TUI_OUT"
}

# One requirement as a row of $2 cells: mark, state icon, name (in a column of $3 cells) and what the check said (cut with … when it is
# longer: the whole result is in the detail).
DASH_SRV_ROW=""
dash_srv_row() { # id width name_width selected
  local id="$1" w="$2" tw="$3" mark title detail dw icon dcol=""
  dash_srv_kit_state "$id"; kit_state_icon "$DASH_SRV_ST"; icon="$KIT_ICON"
  case "$DASH_SRV_ST" in err | warn) dcol="$KIT_COL" ;; *) dcol="${TH[dim]:-}" ;; esac
  dt "prereq.name.$id"; dash_srv_fit "$DTV" "$tw"; title="$TUI_OUT"
  if [ "$DASH_SRV_STATE" = "ready" ]; then detail="${PR_SUMMARY[$id]:-}"; else detail=""; fi
  dw=$((w - 6 - tw))
  [ "$dw" -ge 0 ] || dw=0
  dash_srv_fit "$dcol$detail$TH_RESET" "$dw"; detail="$TUI_OUT"
  if [ "$4" -eq 1 ]; then mark="${TH[accent]:-}$UI_S_SEL$TH_RESET "; else mark="  "; fi
  DASH_SRV_ROW="$mark$icon $title  $detail"
}

# The lines of a group of requirements (indexes $2..$3 of DASH_SRV_ORDER) under its heading, $4 cells wide, into the array named $1. The
# heading says how many are fine. The selected one is marked; in a single column its whole line carries the selection colours (a column
# of two shares its line).
dash_srv_group() { # array first last width single
  local -n _out="$1"
  local i id tw=0 sel hd key ok=0 st n=$(($3 - $2 + 1))
  _out=()
  for ((i = $2; i <= $3; i++)); do
    dt "prereq.name.${DASH_SRV_ORDER[$i]}"
    [ "${#DTV}" -le "$tw" ] || tw="${#DTV}"
    st="${PR_STATUS[${DASH_SRV_ORDER[$i]}]:-}"
    if [ "$DASH_SRV_STATE" = "ready" ]; then
      case "$st" in ok) ok=$((ok + 1)) ;; info) [ "${PR_LEVEL[${DASH_SRV_ORDER[$i]}]}" != "required" ] || ok=$((ok + 1)) ;; esac
    fi
  done
  [ "$tw" -le $(($4 * 2 / 5)) ] || tw=$(($4 * 2 / 5))
  [ "$tw" -le 34 ] || tw=34
  if [ "${PR_LEVEL[${DASH_SRV_ORDER[$2]}]}" = "required" ]; then key=tui.srv.group.required; else key=tui.srv.group.recommended; fi
  dt "$key"; hd="${TH[dim]:-}$C_BLD  $DTV"
  if [ "$DASH_SRV_STATE" = "ready" ]; then hd+="  $ok/$n"; fi
  hd+="$TH_RESET"
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
# Does a requirement have an install command for some package manager although this distribution is not known?
dash_srv_nodistro() { # id
  local m
  [ -z "${PR_MANAGER:-}" ] || return 1
  for m in ${PR_MANAGERS[@]+"${PR_MANAGERS[@]}"}; do [ -z "${PR_CMD["$1|$m"]:-}" ] || return 0; done
  return 1
}
DASH_SRV_HINT=""
dash_srv_hint() { # id
  local rec st msg hint
  local -a recs
  DASH_SRV_HINT=""
  IFS="$PR_RS" read -ra recs <<< "${PR_RECORDS[$1]:-}"
  for rec in ${recs[@]+"${recs[@]}"}; do   # (an empty array is an unbound variable under set -u in Bash 4.3)
    [ -n "$rec" ] || continue
    IFS="$PR_FS" read -r st msg hint <<< "$rec"
    if [ -n "$hint" ]; then DASH_SRV_HINT="$hint"; return 0; fi
  done
}

# One block of the detail (a label and its text, wrapped to the width that is left of the line) appended to the array named $1. $2 is the label
# column, $3 the label, $4 the text, $5 the whole width, $6 the colour of the text (may be empty). The label is only on the first line.
dash_srv_blk() { # array label_width label text width colour
  local -n _blk="$1"
  local lw="$2" lab="$3" txt="$4" w="$5" col="${6:-}" i pad
  kit_wrap "$txt" $((w - lw - 3))
  printf -v pad '%*s' "$lw" ''
  for i in "${!KW_LINES[@]}"; do
    if [ "$i" -eq 0 ]; then
      printf -v lab '%-*s' "$lw" "$lab"
      _blk+=(" ${TH[accent]:-}$lab$TH_RESET  $col${KW_LINES[$i]}$TH_RESET")
    else
      _blk+=(" $pad  $col${KW_LINES[$i]}$TH_RESET")
    fi
  done
}

# The detail of the selected requirement in at most $2 lines of $1 cells, into DASH_SRV_DET, in a column of labels: what it is for, the whole
# result, how to fix it (the install command of this distribution, else the hint of the check, else the page of the guide) and where to read
# more. Open (Enter) it also gives every result with its hint and the command of every package manager when the distribution is not known.
# When the lines are not enough the blocks that matter most stay (result, how, what for, more) and the others go, never half a block.
# DASH_SRV_DET_N is how many lines everything would take.
DASH_SRV_DET=() DASH_SRV_DET_N=0
dash_srv_detail() { # width lines
  local w="$1" n="$2" id="${DASH_SRV_ORDER[$DASH_SRV_SEL]:-}" lw=0 l why cmd="" rec st msg hint m url fix="" b used k
  local -a recs why_b=() res_b=() how_b=() more_b=() keep=()
  local -A size=()
  DASH_SRV_DET=() DASH_SRV_DET_N=0
  [ -n "$id" ] || return 0
  for l in tui.srv.why tui.srv.result tui.srv.how tui.srv.link; do dt "$l"; [ "${#DTV}" -le "$lw" ] || lw="${#DTV}"; done
  dt "prereq.why.$id"; why="$DTV"
  dash_srv_cmd "$id"; cmd="$DASH_SRV_CMD"
  url="${PR_URL[$id]:-}"
  dash_srv_hint "$id"; hint="$DASH_SRV_HINT"
  if [ "$DASH_SRV_STATE" = "ready" ] && [ "${PR_STATUS[$id]:-}" != "ok" ]; then
    # What to do: the command, or what the check advised, or the guide.
    if [ -n "$cmd" ]; then fix="$cmd"
    elif dash_srv_nodistro "$id"; then fix=""   # (the distribution is not known: below, the command of every package manager)
    elif [ -n "$hint" ]; then fix="$hint"
    elif [ -n "$url" ]; then dt tui.srv.link; fix="$DTV: $url"
    fi
  fi
  dt tui.srv.why; dash_srv_blk why_b "$lw" "$DTV" "$why" "$w" "${TH[dim]:-}"
  # The result.
  dt tui.srv.result; l="$DTV"
  if [ "$DASH_SRV_STATE" != "ready" ]; then
    dt tui.srv.status.checking; dash_srv_blk res_b "$lw" "$l" "$DTV" "$w" "${TH[dim]:-}"
  elif [ "$DASH_SRV_OPEN" -eq 0 ]; then
    dash_srv_kit_state "$id"; kit_state_icon "$DASH_SRV_ST"
    dash_srv_blk res_b "$lw" "$l" "${PR_SUMMARY[$id]:-}" "$w" "$KIT_COL"
  else
    IFS="$PR_RS" read -ra recs <<< "${PR_RECORDS[$id]:-}"
    for rec in ${recs[@]+"${recs[@]}"}; do
      [ -n "$rec" ] || continue
      IFS="$PR_FS" read -r st msg hint <<< "$rec"
      case "$st" in ok) kit_state_icon ok ;; err) kit_state_icon err ;; warn) kit_state_icon warn ;; info) kit_state_icon info ;; *) kit_state_icon pend ;; esac
      dash_srv_blk res_b "$lw" "$l" "$msg" "$w" "$KIT_COL"
      l=""
      if [ -n "$hint" ]; then dash_srv_blk res_b "$lw" "" "$hint" "$w" "${TH[dim]:-}"; fi
    done
    hint="$DASH_SRV_HINT"
  fi
  # How to fix it.
  if [ -n "$fix" ]; then
    dt tui.srv.how; dash_srv_blk how_b "$lw" "$DTV" "$fix" "$w" ""
  elif [ "$DASH_SRV_STATE" = "ready" ] && [ "${PR_STATUS[$id]:-}" != "ok" ] && dash_srv_nodistro "$id"; then
    # The distribution is not known: it says so and, with the detail open, the command of every package manager there is.
    dt tui.srv.how; l="$DTV"
    dt tui.srv.no_distro; dash_srv_blk how_b "$lw" "$l" "$DTV" "$w" "${TH[dim]:-}"
    if [ "$DASH_SRV_OPEN" -eq 1 ]; then
      for m in "${PR_MANAGERS[@]}"; do
        [ -z "${PR_CMD["$id|$m"]:-}" ] || dash_srv_blk how_b "$lw" "$m:" "${PR_CMD["$id|$m"]}" "$w" ""
      done
    fi
  fi
  # More information (the guide), unless it is already the advice.
  if [ -n "$url" ] && { [ -n "$cmd" ] || [ -n "$hint" ] || [ -z "$fix" ]; }; then
    dt tui.srv.link; dash_srv_blk more_b "$lw" "$DTV" "$url" "$w" "${TH[dim]:-}"
  fi
  size[why]="${#why_b[@]}" size[res]="${#res_b[@]}" size[how]="${#how_b[@]}" size[more]="${#more_b[@]}"
  DASH_SRV_DET_N=$((size[why] + size[res] + size[how] + size[more]))
  [ "$n" -gt 0 ] || return 0
  # What stays: by importance, a whole block at a time.
  used=0
  for b in res how why more; do
    [ "${size[$b]}" -gt 0 ] || continue
    if [ $((used + size[$b])) -le "$n" ]; then keep+=("$b"); used=$((used + size[$b])); fi
  done
  if [ "${#keep[@]}" -eq 0 ]; then res_b=("${res_b[@]:0:n}"); keep=(res); fi
  for b in why res how more; do
    for k in "${keep[@]}"; do
      [ "$k" = "$b" ] || continue
      case "$b" in
        why) DASH_SRV_DET+=("${why_b[@]}") ;;
        res) DASH_SRV_DET+=("${res_b[@]}") ;;
        how) DASH_SRV_DET+=("${how_b[@]}") ;;
        more) DASH_SRV_DET+=("${more_b[@]}") ;;
      esac
    done
  done
}

# How many rows the box of the requirements wants when it is open, with $1 cells inside: the strip and its rule, the list, the line of the
# detail and the detail (a few lines; open, as many as it needs), into DASH_SRV_NEED.
DASH_SRV_NEED=3
dash_srv_need() { # inner_width
  local n="${#DASH_SRV_ORDER[@]}" nrec rows
  nrec=$((n - DASH_SRV_NREQ))
  if [ "$1" -ge 110 ]; then
    rows="$DASH_SRV_NREQ"; [ "$nrec" -le "$rows" ] || rows="$nrec"
    rows=$((rows + 1))
  else
    rows=$((n + 1)); [ "$nrec" -le 0 ] || rows=$((rows + 1))
  fi
  if [ "$DASH_SRV_OPEN" -eq 1 ]; then rows=$((rows + 1 + 12)); else rows=$((rows + 1 + 6)); fi
  DASH_SRV_NEED=$((2 + 2 + rows))
}

# The box of the requirements, $1 cells wide and $2 high, into DASH_SRV_BOX. Three rows: the strip (the requirements as a chip and the vital
# signs of the server). Taller: the strip, then the list of the requirements (required and recommended, what fails first) and, in a zone of
# its own under a line that names it, the detail of the selected one.
DASH_SRV_REQ_BOX=()
declare -gA DASH_SRV_RMAP=()   # row inside the box (counting its top border as 0) -> "requirement in the left column|in the right one" (-1: none), for the mouse
DASH_SRV_RCOLW=0               # width of the left column when the list has two, else 0
# The rule, the list of requirements and the detail of the selected one, appended to the lines of the box in `body` (the strip is its first
# line), and the footer into `foot`; dash_srv_req owns those variables (and w, h, cw, inner), this one only fills them.
DASH_SRV_REQL_KEY="" DASH_SRV_REQL_BODY=() DASH_SRV_REQL_FOOT="" DASH_SRV_REQL_COLW=0
declare -gA DASH_SRV_REQL_MAP=()
dash_srv_req_list() {
  local R lh dh two=0 colw i n nrec seph cn sel nm
  local -a left=() right=() lines=()
  tui_rep "$UI_S_RULE" "$cw"; body+=("${TH[border]:-}$TUI_OUT$TH_RESET")
  R=$((inner - 2))
  n="${#DASH_SRV_ORDER[@]}"
  nrec=$((n - DASH_SRV_NREQ))
  [ "$cw" -lt 110 ] || two=1
  dash_srv_detail "$cw" 0
  dh="$DASH_SRV_DET_N"
  if [ "$DASH_SRV_OPEN" -eq 0 ] && [ "$dh" -gt 6 ]; then dh=6; fi
  [ "$dh" -gt 0 ] || dh=1
  lh=$((R - 1 - dh))
  if [ "$lh" -lt 4 ]; then dh=$((R - 1 - 4)); lh=$((R - 1 - dh)); fi
  if [ "$dh" -le 0 ]; then dh=0; lh="$R"; fi
  if [ "$two" -eq 1 ]; then
    colw=$(((cw - 3) / 2)); DASH_SRV_RCOLW="$colw"
    dash_srv_group left 0 $((DASH_SRV_NREQ - 1)) "$colw" 0
    if [ "$nrec" -gt 0 ]; then dash_srv_group right "$DASH_SRV_NREQ" $((n - 1)) "$((cw - 3 - colw))" 0; fi
    # The heading of each column stays; below it each column is a window over its own rows, and the one that holds the selection follows it.
    local ltop=0 rtop=0 lc rc
    if [ "$DASH_SRV_SEL" -lt "$DASH_SRV_NREQ" ]; then dash_srv_top $((${#left[@]} - 1)) "$DASH_SRV_SEL" $((lh - 1)); ltop="$DASH_SRV_TOP"; fi
    if [ "$DASH_SRV_SEL" -ge "$DASH_SRV_NREQ" ]; then dash_srv_top $((${#right[@]} - 1)) $((DASH_SRV_SEL - DASH_SRV_NREQ)) $((lh - 1)); rtop="$DASH_SRV_TOP"; fi
    for ((i = 0; i < lh; i++)); do
      if [ "$i" -eq 0 ]; then lc="${left[0]}" rc="${right[0]:-}"; else lc="${left[$((ltop + i))]:-}" rc="${right[$((rtop + i))]:-}"; fi
      dash_srv_fit "$lc" "$colw"; lc="$TUI_OUT"
      body+=("$lc ${TH[border]:-}$UI_S_V$TH_RESET $rc")
      if [ "$i" -gt 0 ]; then
        local li=-1 ri=-1
        [ $((ltop + i)) -ge "${#left[@]}" ] || li=$((ltop + i - 1))
        [ $((rtop + i)) -ge "${#right[@]}" ] || ri=$((DASH_SRV_NREQ + rtop + i - 1))
        DASH_SRV_RMAP[$((3 + i))]="$li|$ri"
      fi
    done
  else
    dash_srv_group left 0 $((DASH_SRV_NREQ - 1)) "$cw" 1
    if [ "$nrec" -gt 0 ]; then dash_srv_group right "$DASH_SRV_NREQ" $((n - 1)) "$cw" 1; fi
    lines=("${left[@]}" ${right[@]+"${right[@]}"})
    # The selected row is the row of the requirement plus the heading(s) above it.
    if [ "$DASH_SRV_SEL" -lt "$DASH_SRV_NREQ" ]; then sel=$((DASH_SRV_SEL + 1)); else sel=$((DASH_SRV_SEL + 2)); fi
    dash_srv_top "${#lines[@]}" "$sel" "$lh"
    # (a selection at the top of a group scrolls its heading into view too)
    for ((i = DASH_SRV_TOP; i < DASH_SRV_TOP + lh && i < ${#lines[@]}; i++)); do
      body+=("${lines[$i]}")
      if [ "$i" -eq 0 ] || [ "$i" -eq $((DASH_SRV_NREQ + 1)) ]; then :
      elif [ "$i" -le "$DASH_SRV_NREQ" ]; then DASH_SRV_RMAP[${#body[@]}]="$((i - 1))|-1"
      else DASH_SRV_RMAP[${#body[@]}]="$((i - 2))|-1"; fi
    done
  fi
  while [ "${#body[@]}" -lt $((2 + lh)) ]; do body+=(""); done
  if [ "$dh" -gt 0 ]; then
    # The line that names the detail (the state and the name of the requirement), then the detail.
    cn="${DASH_SRV_ORDER[$DASH_SRV_SEL]}"
    dt "prereq.name.$cn"; nm="$DTV"
    dash_srv_fit "$nm" $((cw - 6)); nm="${TUI_OUT%"${TUI_OUT##*[![:space:]]}"}"
    tui_vlen "$nm"; seph=$((cw - TUI_VL - 5))
    tui_rep "$UI_S_RULE" "$((seph > 0 ? seph : 0))"
    dash_srv_kit_state "$cn"; kit_state_icon "$DASH_SRV_ST"
    body+=("${TH[border]:-}$UI_S_RULE$TH_RESET $KIT_ICON ${TH[accent]:-}$C_BLD$nm$TH_RESET ${TH[border]:-}$TUI_OUT$TH_RESET")
    dash_srv_detail "$cw" "$dh"
    body+=("${DASH_SRV_DET[@]}")
  fi
  while [ "${#body[@]}" -lt "$inner" ]; do body+=(""); done
  dt tui.srv.foot.req; foot="$DTV"
}

dash_srv_req() { # width height
  local w="$1" h="$2" cw=$(($1 - 4)) inner=$(($2 - 2)) i foot chips status lkey
  local -a body=()
  local foc=0 col=""
  [ "$DASH_SRV_FOCUS" != "req" ] || foc=1
  case "${DASH_SRV_AL[req]:-0}" in 2) col="${TH[err]:-}" ;; 1) col="${TH[warn]:-}" ;; esac
  dash_srv_vitals "$cw"; body+=("$DASH_SRV_VIT")
  if [ "$DASH_SRV_STATE" != "ready" ] || [ "$DASH_SRV_BUSY" -eq 1 ]; then
    dt tui.srv.status.checking; status="$UI_S_RUN $DTV"
  else
    dash_srv_t tui.srv.status.req "$DASH_SRV_READY" "$DASH_SRV_NREQ"; status="$DASH_T"
    if [ "$DASH_SRV_REC_PEND" -gt 0 ]; then dash_srv_t tui.srv.status.rec "$DASH_SRV_REC_PEND"; status+=" $UI_S_DOT $DASH_T"; fi
  fi
  dt tui.srv.title.req; chips="$DTV"
  DASH_SRV_RMAP=() DASH_SRV_RCOLW=0
  if [ "$inner" -lt 5 ] || { ! dash_srv_expanded && [ "$DASH_SRV_PZ" != req ]; }; then
    dt tui.srv.foot.strip; foot="$DTV"
    while [ "${#body[@]}" -lt "$inner" ]; do body+=(""); done
    kit_box "$w" "$h" body "chips=$chips" "status=$status" "footer=$foot" "focus=$foc" ${col:+"color=$col"}
    DASH_SRV_BOX=("${KIT_BOX[@]}")
    return 0
  fi
  # Open: the strip, a rule, the list and the detail. The list and the detail are the expensive part (about two thirds of the box) and they do not
  # depend on the figures of the strip, which move at every sample: they are kept apart and built again only when what they draw changed.
  lkey="$w|$h|$foc|$col|$DASH_LANG_N|${UI_UTF8:-0}|${TH_NAME:-}|$DASH_SRV_PZ|$DASH_SRV_SEL|$DASH_SRV_OPEN|$DASH_SRV_REQ|$DASH_SRV_STATE|$DASH_SRV_BUSY|$DASH_SRV_N|$DASH_SRV_ALKEY"
  if [ "$lkey" = "$DASH_SRV_REQL_KEY" ]; then
    prof_count box.req.list.hit
    body+=("${DASH_SRV_REQL_BODY[@]}")
    foot="$DASH_SRV_REQL_FOOT" DASH_SRV_RCOLW="$DASH_SRV_REQL_COLW"
    DASH_SRV_RMAP=()
    for i in "${!DASH_SRV_REQL_MAP[@]}"; do DASH_SRV_RMAP[$i]="${DASH_SRV_REQL_MAP[$i]}"; done
  else
    prof_b box.req.list
    dash_srv_req_list
    DASH_SRV_REQL_KEY="$lkey" DASH_SRV_REQL_BODY=("${body[@]:1}") DASH_SRV_REQL_FOOT="$foot" DASH_SRV_REQL_COLW="$DASH_SRV_RCOLW"
    DASH_SRV_REQL_MAP=()
    for i in "${!DASH_SRV_RMAP[@]}"; do DASH_SRV_REQL_MAP[$i]="${DASH_SRV_RMAP[$i]}"; done
    prof_e box.req.list
  fi
  kit_box "$w" "$h" body "chips=$chips" "status=$status" "footer=$foot" "focus=$foc" ${col:+"color=$col"}
  DASH_SRV_BOX=("${KIT_BOX[@]}")
}

# --- The figures and the screen (their own files: this one is the requirements) ---------------------------------------------
# shellcheck source=lib/screens/server_boxes.sh
source "$ROOT/lib/screens/server_boxes.sh"
# shellcheck source=lib/screens/server_ps.sh
source "$ROOT/lib/screens/server_ps.sh"
# shellcheck source=lib/screens/server_view.sh
source "$ROOT/lib/screens/server_view.sh"

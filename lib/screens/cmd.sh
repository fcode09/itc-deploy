#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Mode: a command being typed (`:` or `!`, or the Console view). It draws nothing of its own: the console box (or the last line) shows it.

# Typing in the command line (mode cmd) or in the name confirmation (mode name). The line has a cursor.
dash_key_edit() {
  local k="$1" b
  case "$k" in
    enter)
      if [ "$DASH_MODE" = "name" ]; then
        DASH_MODE=normal
        if [ "$DASH_BUF" = "$DASH_NAME_TARGET" ]; then dash_start_job stay init "$DASH_NAME_TARGET" --yes; else dash_msg warn "$(t tui.msg.bad_name)"; fi
      elif [ "$DASH_MODE" = "filter" ]; then
        DASH_MODE=normal DASH_LOG_FILTER="$DASH_BUF" DASH_LOG_SCROLL=0 DASH_CUR=0 DASH_LOG_MIDX=-1   # an empty line removes the filter
      elif [ "$DASH_MODE" = "find" ]; then
        DASH_MODE=normal DASH_LOG_FIND="$DASH_BUF" DASH_CUR=0 DASH_LOG_MIDX=-1      # an empty line removes the search
        [ -z "$DASH_LOG_FIND" ] || dash_logs_jump 0                                   # and a text goes to the newest match
      else
        dash_submit_cmd
        # The Console view is a workspace: after a command the line is ready for the next one.
        if [ "$DASH_VIEW" = "console" ] && [ "$DASH_MODE" = "normal" ] && [ "$DASH_QUIT" -eq 0 ]; then DASH_MODE=cmd DASH_BUF="" DASH_CUR=0; fi
      fi
      ;;
    esc) DASH_MODE=normal DASH_CUR=0; dash_msg info "$(t tui.msg.cancelled)" ;;
    backspace) if [ "$DASH_CUR" -gt 0 ]; then DASH_BUF="${DASH_BUF:0:$((DASH_CUR - 1))}${DASH_BUF:$DASH_CUR}"; DASH_CUR=$((DASH_CUR - 1)); fi ;;
    delete) DASH_BUF="${DASH_BUF:0:$DASH_CUR}${DASH_BUF:$((DASH_CUR + 1))}" ;;
    left) [ "$DASH_CUR" -le 0 ] || DASH_CUR=$((DASH_CUR - 1)) ;;
    right) [ "$DASH_CUR" -ge "${#DASH_BUF}" ] || DASH_CUR=$((DASH_CUR + 1)) ;;
    home | $'\001') DASH_CUR=0 ;;                                   # Ctrl+A
    end | $'\005') DASH_CUR="${#DASH_BUF}" ;;                       # Ctrl+E
    $'\025') DASH_BUF="${DASH_BUF:$DASH_CUR}" DASH_CUR=0 ;;         # Ctrl+U: up to the start of the line
    $'\013') DASH_BUF="${DASH_BUF:0:$DASH_CUR}" ;;                  # Ctrl+K: to the end of the line
    $'\027')                                                        # Ctrl+W: the word before the cursor
      b="${DASH_BUF:0:$DASH_CUR}"
      b="${b%"${b##*[![:space:]]}"}"
      b="${b%"${b##*[[:space:]]}"}"
      DASH_BUF="$b${DASH_BUF:$DASH_CUR}" DASH_CUR="${#b}"
      ;;
    $'\014') DASH_CON=() DASH_CON_N=$((DASH_CON_N + 1)) ;;          # Ctrl+L: clear the transcript
    space) DASH_BUF="${DASH_BUF:0:$DASH_CUR} ${DASH_BUF:$DASH_CUR}"; DASH_CUR=$((DASH_CUR + 1)) ;;
    tab) if [ "$DASH_MODE" = "cmd" ]; then dash_complete; DASH_CUR="${#DASH_BUF}"; fi ;;
    up)
      if [ "$DASH_MODE" = "cmd" ] && [ "$DASH_HIDX" -gt 0 ]; then DASH_HIDX=$((DASH_HIDX - 1)); DASH_BUF="${DASH_HIST[$DASH_HIDX]}"; DASH_CUR="${#DASH_BUF}"; fi
      ;;
    down)
      if [ "$DASH_MODE" = "cmd" ]; then
        if [ "$DASH_HIDX" -lt $((${#DASH_HIST[@]} - 1)) ]; then DASH_HIDX=$((DASH_HIDX + 1)); DASH_BUF="${DASH_HIST[$DASH_HIDX]}"
        else DASH_HIDX="${#DASH_HIST[@]}"; DASH_BUF=""; fi
        DASH_CUR="${#DASH_BUF}"
      fi
      ;;
    pgup) [ "$DASH_MODE" != "cmd" ] || { dash_con_page; DASH_CON_SCROLL=$((DASH_CON_SCROLL + DASH_CON_PAGE)); dash_con_clamp; } ;;
    pgdn) [ "$DASH_MODE" != "cmd" ] || { dash_con_page; DASH_CON_SCROLL=$((DASH_CON_SCROLL - DASH_CON_PAGE)); dash_con_clamp; } ;;
    other | timeout) ;;
    *)
      if [ "${#k}" -eq 1 ] && [[ "$k" != [[:cntrl:]] ]]; then DASH_BUF="${DASH_BUF:0:$DASH_CUR}$k${DASH_BUF:$DASH_CUR}"; DASH_CUR=$((DASH_CUR + 1)); fi
      ;;
  esac
}

# --- The contract of lib/screens/registry.sh --------------------------------------------------------------------
scr_cmd_key() { dash_key_edit "$1"; }
scr_cmd_keys() { # width
  local w="$1"
  if [ "$DASH_VIEW" = "instances" ] || [ "$DASH_VIEW" = "console" ]; then
    # The console box holds the prompt: the last line only lists the keys of the line editor.
    dt tui.con.keys; dash_keybar "${DTV//\{1\}/$DASH_UD}" "$w"
    TUI_FRAME+=(" $DASH_KBV")
    return 0
  fi
  dt tui.cmd.prompt
  TUI_FRAME+=(" $C_GRY$DTV$C_OFF $C_BLD:$C_OFF$DASH_BUF")
  tui_vlen " $DTV :$DASH_BUF"
  TUI_CURSOR="$TUI_ROWS;$((TUI_VL + 2))"
}
# The line is part of the body only inside the console box.
scr_cmd_sig() {
  { [ "$DASH_MODE" != "cmd" ] || { [ "$DASH_VIEW" != "instances" ] && [ "$DASH_VIEW" != "console" ]; }; } || DASH_SIG+="|$DASH_BUF|$DASH_CUR"
}

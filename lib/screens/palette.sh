#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Mode: the palette of actions (Ctrl+P).

# --- The palette: a fuzzy list of what can be done now. Actions reuse the menu runner (and so its confirmations).
dash_pal_add() { DASH_PAL_ALL_L+=("$1"); DASH_PAL_ALL_A+=("$2"); }

dash_pal_build() {
  local inst svc id i v th
  local -a svcs
  DASH_PAL_ALL_L=() DASH_PAL_ALL_A=()
  if [ "$DASH_ON_NEW" -eq 0 ] && [ "${#DASH_NAMES[@]}" -gt 0 ]; then
    inst="${DASH_NAMES[$DASH_SEL]}"
    read -ra svcs <<< "${DASH_SVCS[$inst]:-}"
    svc="${svcs[$DASH_SVC]:-${svcs[0]:-}}"
    for id in status check deploy_all deploy_svc rollback logs_live logs_recent stop_svc down; do
      if [ -z "$svc" ]; then case "$id" in deploy_svc | logs_live | logs_recent | stop_svc) continue ;; esac; fi
      dt "tui.act.$id"; dash_pal_add "${DTV//\{1\}/$svc}" "act:$id"
    done
    if [ "${DASH_DATA[$inst]:-}" = "unseeded" ]; then dt tui.act.init; dash_pal_add "${DTV//\{1\}/$svc}" "act:init"; fi
    dt tui.pal.svc
    for i in "${!svcs[@]}"; do dash_pal_add "${DTV//\{1\}/${svcs[$i]}}" "svc:$i"; done
  fi
  dt tui.pal.go
  for i in "${!DASH_NAMES[@]}"; do dash_pal_add "${DTV//\{1\}/${DASH_NAMES[$i]}}" "inst:$i"; done
  for v in instances resources output runs procs console server images env; do dt "tui.tab.$v"; id="$DTV"; dt tui.pal.view; dash_pal_add "${DTV//\{1\}/$id}" "view:$v"; done
  dt tui.pal.theme
  for th in "${TH_THEMES[@]}"; do dash_pal_add "${DTV//\{1\}/$th}" "theme:$th"; done
  dt tui.pal.new; dash_pal_add "$DTV" "new"
  dt tui.pal.lang; dash_pal_add "$DTV" "lang"
  dt tui.pal.options; dash_pal_add "$DTV" "options"
  dt tui.pal.clear; dash_pal_add "$DTV" "clear"
  dt tui.pal.quit; dash_pal_add "$DTV" "quit"
}

# Does the query appear in the label as a subsequence (case-insensitive)? PAL_SCORE gets the total gap: the lower, the better.
dash_pal_match() { # query label
  local q="${1,,}" l="${2,,}" qi=0 li=0 score=0 last=-1 ch
  while [ "$qi" -lt "${#q}" ]; do
    ch="${q:$qi:1}"
    while [ "$li" -lt "${#l}" ] && [ "${l:$li:1}" != "$ch" ]; do li=$((li + 1)); done
    [ "$li" -lt "${#l}" ] || return 1
    if [ "$last" -ge 0 ]; then score=$((score + li - last - 1)); else score=$((score + li)); fi
    last="$li" li=$((li + 1)) qi=$((qi + 1))
  done
  PAL_SCORE="$score"
}

# Filters and orders the items for the query. With no query the ones used recently come first.
dash_pal_filter() {
  local i r score a j k tmp
  local -a sc=() ix=()
  DASH_PAL_LABELS=() DASH_PAL_ACTS=()
  for i in "${!DASH_PAL_ALL_L[@]}"; do
    a="${DASH_PAL_ALL_A[$i]}"
    if [ -z "$DASH_PAL_Q" ]; then
      score="$i"
      for r in "${!DASH_PAL_RECENT[@]}"; do [ "${DASH_PAL_RECENT[$r]}" != "$a" ] || score=$((r - 1000)); done
    else
      dash_pal_match "$DASH_PAL_Q" "${DASH_PAL_ALL_L[$i]}" || continue
      score="$PAL_SCORE"
    fi
    sc+=("$score") ix+=("$i")
  done
  # Insertion sort by score (a few dozen items).
  for ((j = 1; j < ${#sc[@]}; j++)); do
    tmp="${sc[$j]}" k="${ix[$j]}" i=$((j - 1))
    while [ "$i" -ge 0 ] && [ "${sc[$i]}" -gt "$tmp" ]; do sc[i + 1]="${sc[$i]}" ix[i + 1]="${ix[$i]}"; i=$((i - 1)); done
    sc[i + 1]="$tmp" ix[i + 1]="$k"
  done
  for i in "${ix[@]}"; do DASH_PAL_LABELS+=("${DASH_PAL_ALL_L[$i]}"); DASH_PAL_ACTS+=("${DASH_PAL_ALL_A[$i]}"); done
  [ "$DASH_PAL_SEL" -lt "${#DASH_PAL_LABELS[@]}" ] || DASH_PAL_SEL=0
}

dash_open_palette() {
  dash_pal_build
  DASH_PAL_Q="" DASH_PAL_SEL=0
  dash_pal_filter
  DASH_MODE=palette
}

dash_pal_run() {
  local act="${DASH_PAL_ACTS[$DASH_PAL_SEL]:-}" kind arg a
  local -a keep=()
  DASH_MODE=normal
  [ -n "$act" ] || return 0
  keep=("$act")
  for a in "${DASH_PAL_RECENT[@]}"; do [ "$a" = "$act" ] || keep+=("$a"); done
  DASH_PAL_RECENT=("${keep[@]:0:5}")
  kind="${act%%:*}" arg="${act#*:}"
  case "$kind" in
    act)
      dash_current_target || return 0
      DASH_MENU_INST="$DASH_T_INST" DASH_MENU_SVC="$DASH_T_SVC" DASH_MENU_IDS=("$arg") DASH_MENU_SEL=0
      dash_menu_run
      ;;
    inst) DASH_ON_NEW=0 DASH_SEL="$arg" DASH_SVC=0 DASH_FOCUS=list DASH_VIEW=instances ;;
    svc) DASH_SVC="$arg" DASH_FOCUS=svc DASH_VIEW=instances ;;
    view) DASH_VIEW="$arg" ;;
    theme) if theme_apply "$arg"; then th_save "$arg"; dash_theme_refresh; fi ;;
    new) dash_open_new ;;
    lang) dash_toggle_language ;;
    options) dash_open_options ;;
    clear) DASH_CON=() DASH_CON_N=$((DASH_CON_N + 1)) ;;
    quit) DASH_QUIT=1 ;;
  esac
}

dash_key_palette() { # key
  case "$1" in
    esc) DASH_MODE=normal ;;
    enter) dash_pal_run ;;
    up) [ "$DASH_PAL_SEL" -le 0 ] || DASH_PAL_SEL=$((DASH_PAL_SEL - 1)) ;;
    down) [ "$DASH_PAL_SEL" -ge $((${#DASH_PAL_LABELS[@]} - 1)) ] || DASH_PAL_SEL=$((DASH_PAL_SEL + 1)) ;;
    backspace) DASH_PAL_Q="${DASH_PAL_Q%?}" DASH_PAL_SEL=0; dash_pal_filter ;;
    $'\025') DASH_PAL_Q="" DASH_PAL_SEL=0; dash_pal_filter ;;     # Ctrl+U
    space) DASH_PAL_Q+=" " DASH_PAL_SEL=0; dash_pal_filter ;;
    *) if [ "${#1}" -eq 1 ] && [[ "$1" != [[:cntrl:]] ]]; then DASH_PAL_Q+="$1" DASH_PAL_SEL=0; dash_pal_filter; fi ;;
  esac
}

# --- Palette ---------------------------------------------------------------------------------------------------------
dash_dialog_palette() { # body_height
  local i n="${#DASH_PAL_LABELS[@]}" shown=10 start=0 acc cur
  acc="${TH[accent]:-$C_CYN}"
  DASH_DLG=("")
  if [ -n "$DASH_REV" ]; then cur="$DASH_REV $C_OFF"; else cur="_"; fi
  DASH_DLG+=("$acc$DASH_PG$C_OFF $DASH_PAL_Q$cur" "")
  if [ "$n" -eq 0 ]; then
    dt tui.pal.none; DASH_DLG+=("$C_GRY$DTV$C_OFF")
  else
    [ "$DASH_PAL_SEL" -lt "$shown" ] || start=$((DASH_PAL_SEL - shown + 1))
    for ((i = start; i < n && i < start + shown; i++)); do
      if [ "$i" -eq "$DASH_PAL_SEL" ]; then DASH_DLG+=("$TUI_SEL$acc$UI_S_SEL$C_OFF $C_BLD${DASH_PAL_LABELS[$i]}$C_OFF")
      else DASH_DLG+=("  ${DASH_PAL_LABELS[$i]}"); fi
    done
  fi
  DASH_DLG+=("")
  dt tui.pal.title
  dash_dialog "$1" "$DTV" 64
}

# --- The contract of lib/screens/registry.sh --------------------------------------------------------------------
scr_palette_render() { dash_dialog_palette "$2"; } # width height
scr_palette_key() { dash_key_palette "$1"; }
scr_palette_keys() { # width
  dt tui.pal.keys; dash_keyfit "${DTV//\{1\}/$DASH_UD}" "$1"; TUI_FRAME+=(" $C_GRY$DASH_KF$C_OFF")
}
scr_palette_sig() { DASH_SIG+="|$DASH_PAL_Q|$DASH_PAL_SEL"; }

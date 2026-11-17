#!/usr/bin/env bash
# The interactive panel: every instance with its n/m state, navigable with the arrow keys; Enter opens the actions
# of the selected instance. It is what ./deltactl and ./deltactl menu open in a real terminal; without one (a pipe,
# a script, TERM=dumb) they keep showing the static home screen and the numbered menu.
#
# Keys: up/down (or k/j) move, Enter opens the actions, r refreshes, n creates an instance, d runs the server
# diagnosis, i lists the images, L switches the language, ? shows the keys, q or Esc quits. The data refreshes by
# itself every few seconds. An action runs the same ./deltactl command the numbered menu runs, and shows it.

# menu_exec / menu_run (run a command and show it) and the new_ask helpers come from menu.sh; the terminal layer from tui.sh
source "$ROOT/lib/cmd/menu.sh"
source "$ROOT/lib/cmd/status.sh"
source "$ROOT/lib/ui/tui.sh"

DASH_SEL=0
DASH_REFRESH_SECONDS="${DELTACTL_REFRESH:-5}"
DASH_NAMES=()
declare -gA DASH_KIND=() DASH_NM=() DASH_DOTS=() DASH_PORTS=() DASH_TAGS=() DASH_SVCS=() DASH_DATA=()

# Collects the state of every instance (one query to Docker) and prepares what each row shows.
dash_refresh() {
  local f name svc n m kind dots ports tags key any
  HINTS=() HINT_SEEN=()
  st_collect
  st_load_ports
  DASH_NAMES=()
  DASH_KIND=() DASH_NM=() DASH_DOTS=() DASH_PORTS=() DASH_TAGS=() DASH_SVCS=() DASH_DATA=()
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    name="$(basename "$(dirname "$f")")"
    st_enabled "$name"
    st_instance_hints "$name"
    n=0 m="${#ST_ENABLED[@]}" dots="" ports="" tags="" any=0
    for svc in ${ST_ENABLED[@]+"${ST_ENABLED[@]}"}; do
      st_eval "$name" "$svc"
      st_notes "$name" "$svc"
      [ "$E_KIND" != "ok" ] || n=$((n + 1))
      dots+="${dots:+ }$svc $(ui_sym "$E_KIND")"
      ports+="${ports:+/}${E_PORT:--}"
      tags+="${tags:+/}${E_CFG:--}"
    done
    for key in "${!ST_STATE[@]}"; do [ "${key%%/*}" != "$name" ] || any=1; done
    if [ "$ST_DOCKER" -ne 1 ]; then kind=dim
    elif [ "$m" -eq 0 ]; then kind=err
    elif [ "$n" -eq "$m" ]; then kind=ok
    elif [ "$n" -gt 0 ]; then kind=warn
    elif [ "$any" -eq 1 ]; then kind=err
    else kind=dim; fi
    DASH_NAMES+=("$name")
    DASH_KIND[$name]="$kind"
    if [ "$ST_DOCKER" -eq 1 ]; then DASH_NM[$name]="$n/$m"; else DASH_NM[$name]="?/$m"; fi
    DASH_DOTS[$name]="$dots"
    DASH_PORTS[$name]="$ports"
    DASH_TAGS[$name]="$tags"
    DASH_SVCS[$name]="${ST_ENABLED[*]:-}"
    DASH_DATA[$name]="$(data_state "$name")"
  done
  [ "$DASH_SEL" -lt "${#DASH_NAMES[@]}" ] || DASH_SEL=$((${#DASH_NAMES[@]} - 1))
  [ "$DASH_SEL" -ge 0 ] || DASH_SEL=0
}

# Footer text: the keys, with arrows only where Unicode is available.
dash_keys_line() { # message-key
  if [ "$UI_UTF8" -eq 1 ] && [ "$UI_RICH" -eq 1 ]; then t "$1"; else t "$1.ascii"; fi
}

# Builds the main frame: host line, instance rows, next steps and the keys.
dash_frame() {
  local i name row h cmd why shown=0
  TUI_FRAME=("$(status_host_line)" "" "  $C_BLD$(t tui.instances)$C_OFF")
  if [ "${#DASH_NAMES[@]}" -eq 0 ]; then
    TUI_FRAME+=("  $C_GRY$(t tui.none)$C_OFF")
  fi
  for i in "${!DASH_NAMES[@]}"; do
    name="${DASH_NAMES[$i]}"
    row="$(printf '%s %-14s %-5s %s   %s   v%s' "$(ui_sym "${DASH_KIND[$name]}")" "$name" "${DASH_NM[$name]}" \
      "${DASH_DOTS[$name]}" "${DASH_PORTS[$name]}" "${DASH_TAGS[$name]}")"
    if [ "$i" -eq "$DASH_SEL" ]; then
      TUI_FRAME+=("$C_CYN$UI_S_SEL$C_OFF $C_BLD$row$C_OFF")
    else
      TUI_FRAME+=("  $row")
    fi
  done
  TUI_FRAME+=("")
  for h in ${HINTS[@]+"${HINTS[@]}"}; do
    [ "$shown" -lt 3 ] || break
    cmd="${h%%|*}"
    why="${h#*|}"
    [ "$shown" -ne 0 ] || TUI_FRAME+=("  $C_BLD$(t status.footer.next_steps)$C_OFF")
    TUI_FRAME+=("  $C_CYN$UI_S_ARROW$C_OFF $C_GRN$cmd$C_OFF  $C_GRY# $why$C_OFF")
    shown=$((shown + 1))
  done
  [ "$shown" -eq 0 ] || TUI_FRAME+=("")
  TUI_FRAME+=("  $C_GRY$(dash_keys_line tui.keys)$C_OFF")
}

dash_draw() { dash_frame; tui_draw; }

# Shows a list and lets the user pick one item with the arrows. $1 is the title, the rest are the labels.
# The index of the choice is left in DASH_CHOICE (empty if the user went back).
dash_choose() { # title label...
  local title="$1" sel=0 i
  shift
  local -a items=("$@")
  DASH_CHOICE=""
  while true; do
    TUI_FRAME=("$(status_host_line)" "" "  $C_BLD$title$C_OFF" "")
    for i in "${!items[@]}"; do
      if [ "$i" -eq "$sel" ]; then
        TUI_FRAME+=("$C_CYN$UI_S_SEL$C_OFF $C_BLD${items[$i]}$C_OFF")
      else
        TUI_FRAME+=("  ${items[$i]}")
      fi
    done
    TUI_FRAME+=("" "  $C_GRY$(dash_keys_line tui.choose_keys)$C_OFF")
    tui_draw
    tui_key
    case "$TUI_KEY" in
      up | k) sel=$(((sel + ${#items[@]} - 1) % ${#items[@]})) ;;
      down | j) sel=$(((sel + 1) % ${#items[@]})) ;;
      enter | right) DASH_CHOICE="$sel"; return 0 ;;
      esc | left | q) return 0 ;;
    esac
  done
}

# Runs a ./deltactl command outside the alternate screen, shows its output and waits for Enter.
dash_exec() {
  tui_leave
  menu_run "$@"
  tui_enter
  dash_refresh
}

# Same, without waiting (for live logs: Ctrl+C returns).
dash_exec_live() {
  tui_leave
  menu_exec "$@" || true
  tui_enter
  dash_refresh
}

# y/N question in the normal screen. Returns 0 for yes.
dash_confirm() { # question
  local rc=0
  tui_leave
  new_ask_yn "$1" n || rc=$?
  tui_enter
  return "$rc"
}

# The actions of an instance.
dash_actions() { # instance
  local inst="$1" id svc
  local -a ids=(details check deploy rollback logs follow stop down) labels=() svcs=()
  [ "${DASH_DATA[$inst]:-}" != "unseeded" ] || ids+=(init)
  ids+=(help)
  for id in "${ids[@]}"; do labels+=("$(t "tui.act.$id")"); done
  dash_choose "$(t tui.actions_title "$inst" "${DASH_NM[$inst]:-}")" "${labels[@]}"
  [ -n "$DASH_CHOICE" ] || return 0
  id="${ids[$DASH_CHOICE]}"
  case "$id" in
    details) dash_exec status "$inst" ;;
    check) dash_exec check "$inst" ;;
    deploy) dash_exec deploy "$inst" ;;
    rollback)
      if dash_confirm "$(t menu.confirm_rollback "$(t menu.all_the_services)" "$inst")"; then dash_exec rollback "$inst" --yes; fi
      ;;
    logs) dash_exec logs "$inst" ;;
    follow) dash_exec_live logs "$inst" -f ;;
    stop)
      read -ra svcs <<< "${DASH_SVCS[$inst]:-}"
      [ "${#svcs[@]}" -gt 0 ] || return 0
      dash_choose "$(t tui.pick_service "$inst")" "${svcs[@]}"
      [ -n "$DASH_CHOICE" ] || return 0
      svc="${svcs[$DASH_CHOICE]}"
      dash_exec stop "$inst" "$svc"
      ;;
    down)
      if dash_confirm "$(t menu.confirm_down "$inst")"; then dash_exec down "$inst" --yes; fi
      ;;
    init) dash_init "$inst" ;;
    help) dash_exec help status ;;
  esac
}

# init is destructive: it asks to type the instance name, as the numbered menu does.
dash_init() { # instance
  local inst="$1"
  tui_leave
  printf '\n  %s %s\n' "$(ui_sym warn)" "$(t menu.init_warning)"
  new_ask "$(t menu.ask_confirm_name "$inst")"
  if [ "$REPLY_VAL" != "$inst" ]; then
    info "$(t menu.cancelled)"
    tui_enter
    return 0
  fi
  menu_run init "$inst" --yes
  tui_enter
  dash_refresh
}

# The list of keys, over the whole screen; any key closes it.
dash_help() {
  local line
  TUI_FRAME=("$(status_host_line)" "" "  $C_BLD$(t tui.help_title)$C_OFF" "")
  while IFS= read -r line; do TUI_FRAME+=("  $line"); done <<< "$(t tui.help)"
  TUI_FRAME+=("" "  $C_GRY$(t tui.help_close)$C_OFF")
  tui_draw
  tui_key
}

# Switches between Spanish and English, remembers the choice and reloads the messages.
dash_toggle_language() {
  local next=en
  [ "${DELTACTL_LANG_ACTIVE:-es}" != "en" ] || next=es
  i18n_save_lang "$next"
  DELTACTL_LANG="$next"
  export DELTACTL_LANG
  i18n_init
}

dash_loop() {
  local n
  while true; do
    dash_draw
    tui_key "$DASH_REFRESH_SECONDS"
    n="${#DASH_NAMES[@]}"
    case "$TUI_KEY" in
      up | k) [ "$n" -eq 0 ] || DASH_SEL=$(((DASH_SEL + n - 1) % n)) ;;
      down | j) [ "$n" -eq 0 ] || DASH_SEL=$(((DASH_SEL + 1) % n)) ;;
      enter | right) [ "$n" -eq 0 ] || dash_actions "${DASH_NAMES[$DASH_SEL]}" ;;
      r | timeout) dash_refresh ;;
      n) dash_exec new --wizard ;;
      d) dash_exec doctor ;;
      i) dash_exec images ;;
      L) dash_toggle_language ;;
      '?') dash_help ;;
      q | esc) return 0 ;;
    esac
  done
}

cmd_dashboard() {
  if ! tui_interactive; then
    cmd_home
    return 0
  fi
  trap 'tui_leave' EXIT
  trap 'tui_leave; exit 130' INT TERM
  tui_enter
  dash_refresh
  dash_loop
  tui_leave
}

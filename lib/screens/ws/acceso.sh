#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Tab of the workspace: Acceso. How the instance is reached from outside: the public domain (the host of each service is <name>.<domain>), the
# proxy (nginx or Caddy) and HTTPS, whether each service answers on the server itself, and the BLOCK of the proxy that puts them behind their names:
# shown, copied (y) and saved inside the instance (g: instances/<name>/proxy/). The block is TEXT (lib/core/proxy.sh): nothing is ever written under
# /etc, nothing is reloaded or installed; the person puts it where their proxy reads it. What the tab remembers (domain, proxy, HTTPS) is
# instances/<name>/proxy/access.conf, written only when the block is saved.
# Keys while the tab has the focus: Enter writes the domain (mode accdom), b the other block (nginx / Caddy), w HTTPS, y copies the block, g saves
# it, e types the whole public name of the selected service, a / A put its block / all of them in nginx and R / X take it / all out (the panel keeps
# n and x for itself), PgUp / PgDn scroll it; up and down choose a service (its row is the one marked). Loaded by lib/screens/instances_ws.sh (dash_ws_register).
#
# Cost: the figures are made when something changes (the model, cached by its signature); a read of the ports and a probe of each port
# (a connection to 127.0.0.1, in the background) run every ten seconds while the tab is on screen, and never in the drawing.

declare -gA DASH_ACC_DOM=() DASH_ACC_FL=() DASH_ACC_TLS=() DASH_ACC_LOADED=() DASH_ACC_PORT=() DASH_ACC_REACH=() DASH_ACC_AT=()
# What the instance remembered besides the three answers: the www alias (0|1) and the name of each service that has one of its own ("s0=a.pe s1=b.pe"),
# written by `./deltactl access`. The tab does not edit them but keeps them: what it generates and saves carries them.
declare -gA DASH_ACC_WWW=() DASH_ACC_OV=()
# The state of the nginx block of each service, read in the same background job as the ports (lib/core/proxystate.sh): <instance>/<service> -> state,
# and the hosts that lack a certificate. Empty until the first read; nothing when there is no domain or the proxy is not nginx.
declare -gA DASH_ACC_NG=() DASH_ACC_NGM=() DASH_ACC_NGN=()   # (the third: the command that follows, worked out in the background too)
DASH_ACC_DET="" DASH_ACC_DET_SET=0       # the proxy this server has (nginx | caddy | none), asked once
DASH_ACC_SCROLL=0 DASH_ACC_N=0          # the first line of the block on screen; a counter that says "something changed" (signature)
DASH_ACC_SIGM=""                        # the signature of the model that was built
DASH_ACC_ENT=() DASH_ACC_BLOCK=() DASH_ACC_TEXT="" DASH_ACC_ERR="" DASH_ACC_SAVED=none DASH_ACC_HOSTS=()

ws_acceso_avail() { # instance
  [ -n "${DASH_SVCS[$1]:-}" ]
}

# What the instance remembers (once per instance and session), and what this server has.
dash_acc_load() { # instance
  local name="$1" s
  if [ "$DASH_ACC_DET_SET" -eq 0 ]; then
    proxy_detect_r
    DASH_ACC_DET="$PROXY_DET"
    DASH_ACC_DET_SET=1
  fi
  [ -z "${DASH_ACC_LOADED[$name]:-}" ] || return 0
  proxy_meta_load "$name"
  DASH_ACC_DOM[$name]="$PROXY_M_DOMAIN"
  DASH_ACC_FL[$name]="${PROXY_M_FLAVOR:-${DASH_ACC_DET:-nginx}}"
  DASH_ACC_TLS[$name]="$PROXY_M_TLS"
  DASH_ACC_WWW[$name]="$PROXY_M_WWW"
  DASH_ACC_OV[$name]=""
  for s in "${KNOWN_SERVICES[@]}"; do [ -z "${PROXY_M_HOSTS[$s]:-}" ] || DASH_ACC_OV[$name]+="$s=${PROXY_M_HOSTS[$s]} "; done
  DASH_ACC_OV[$name]="${DASH_ACC_OV[$name]% }"
  DASH_ACC_LOADED[$name]=1
  dash_acc_ports "$name"
  DASH_ACC_N=$((DASH_ACC_N + 1))
}

# The ports of the services of an instance (a read of .env.instance: no process).
dash_acc_ports() { # instance
  local name="$1" s
  local -a svcs
  read -ra svcs <<< "${DASH_SVCS[$name]:-}"
  proxy_instance_ports "$name" "${svcs[@]}"
  for s in "${svcs[@]}"; do DASH_ACC_PORT[$name/$s]="${PROXY_PORTS[$s]:-}"; done
}

# Puts the www alias and the names of the services of the instance where the generator reads them (PROXY_WWW, PROXY_HOSTS).
dash_acc_proxy_vars() { # instance
  local kv
  PROXY_HOSTS=() PROXY_WWW="${DASH_ACC_WWW[$1]:-0}"
  for kv in ${DASH_ACC_OV[$1]:-}; do PROXY_HOSTS[${kv%%=*}]="${kv#*=}"; done
}

# The block and the table of the instance into DASH_ACC_*: made again only when what it depends on changed.
dash_acc_model() { # instance
  local name="$1" dom fl tls sig s
  local -a svcs
  dash_acc_edom "$name"
  dom="$DASH_ACC_ED" fl="${DASH_ACC_FL[$name]:-nginx}" tls="${DASH_ACC_TLS[$name]:-1}"
  sig="$name|$dom|$fl|$tls|$DASH_ACC_N|${DASH_SVCS[$name]:-}|${DASH_ACC_WWW[$name]:-0}|${DASH_ACC_OV[$name]:-}"
  [ "$sig" != "$DASH_ACC_SIGM" ] || return 0
  DASH_ACC_SIGM="$sig" DASH_ACC_TEXT="" DASH_ACC_BLOCK=() DASH_ACC_ERR="" DASH_ACC_SAVED=none DASH_ACC_ENT=() DASH_ACC_HOSTS=()
  read -ra svcs <<< "${DASH_SVCS[$name]:-}"
  [ -n "$dom" ] || return 0
  proxy_host_ok "$dom" || { DASH_ACC_ERR=domain; return 0; }
  PROXY_PORTS=()
  for s in "${svcs[@]}"; do
    PROXY_PORTS[$s]="${DASH_ACC_PORT[$name/$s]:-}"
    if ! proxy_port_ok "${PROXY_PORTS[$s]}"; then DASH_ACC_ERR="port:$s"; fi
  done
  dash_acc_proxy_vars "$name"
  proxy_domain_names "$dom" "${svcs[@]}" || { DASH_ACC_ERR=domain; return 0; }
  DASH_ACC_ENT=("${PROXY_ENTRIES[@]}")
  for s in "${!DASH_ACC_ENT[@]}"; do DASH_ACC_HOSTS[s]="${DASH_ACC_ENT[$s]%%|*}"; done
  [ -z "$DASH_ACC_ERR" ] || return 0
  if proxy_render "$fl" "$tls" "${DASH_ACC_ENT[@]}"; then
    DASH_ACC_TEXT="$PROXY_OUT"
    mapfile -t DASH_ACC_BLOCK <<< "${PROXY_OUT%$'\n'}"
    # (what is shown starts at the first directive: the comments that open the file say where to put it, and the tab says that in its own words)
    while [ "${#DASH_ACC_BLOCK[@]}" -gt 1 ] && [[ "${DASH_ACC_BLOCK[0]}" == "#"* ]]; do DASH_ACC_BLOCK=("${DASH_ACC_BLOCK[@]:1}"); done
    # (and the blank line after them: what is shown starts at the label of the first service, `# s0`)
    while [ "${#DASH_ACC_BLOCK[@]}" -gt 1 ] && [ -z "${DASH_ACC_BLOCK[0]}" ]; do DASH_ACC_BLOCK=("${DASH_ACC_BLOCK[@]:1}"); done
    proxy_state "$name" "$fl"
    DASH_ACC_SAVED="$PROXY_SAVED"
  else
    DASH_ACC_ERR="render:$PROXY_ERR"
  fi
}

# --- Background work ------------------------------------------------------------------------------------------------------------

# Runs in the background: for each service of the instance "<service> <port> <up|down|none>" (none: no valid port).
dash_acc_dump() { # instance
  local name="$1" s port st
  local -a svcs
  read -ra svcs <<< "${DASH_SVCS[$name]:-}"
  proxy_instance_ports "$name" "${svcs[@]}"
  for s in "${svcs[@]}"; do
    port="${PROXY_PORTS[$s]:-}"
    if proxy_port_ok "$port"; then
      if proxy_reach "$port"; then st=up; else st=down; fi
    else
      st=none
    fi
    printf '%s %s %s\n' "$s" "${port:--}" "$st"
  done
  dash_acc_ng_lines "$name"
}

# "ng <service> <state> <hosts without a certificate>" for each service: what the nginx block of each one is in (lib/core/proxystate.sh), against the
# block the tab would show now (the domain being typed included). Nothing when there is no domain or the proxy is not nginx.
dash_acc_ng_lines() { # instance
  local name="$1" dom e svc fl tls
  local -a svcs
  fl="${DASH_ACC_FL[$name]:-nginx}"
  [ "$fl" = nginx ] || return 0
  tls="${DASH_ACC_TLS[$name]:-1}"
  read -ra svcs <<< "${DASH_SVCS[$name]:-}"
  dash_acc_edom "$name"
  dom="$DASH_ACC_ED"
  { [ -n "$dom" ] && proxy_host_ok "$dom"; } || return 0
  proxy_instance_ports "$name" "${svcs[@]}"
  dash_acc_proxy_vars "$name"
  proxy_domain_names "$dom" "${svcs[@]}" || return 0
  for e in "${PROXY_ENTRIES[@]}"; do
    svc="${e##*|}"
    proxy_port_ok "${PROXY_PORTS[$svc]:-}" || continue
    proxy_block_state_r "$name" "$svc" "$tls" "$e"
    printf 'ng %s %s %s\n' "$svc" "$PSTATE" "${PSTATE_MISSING:-${e%%|*}}"
    proxy_state_next_r "$PSTATE" "$name" "$svc" "${PSTATE_MISSING:-${e%%|*}}"
    [ -z "$PSTATE_NEXT" ] || printf 'nx %s %s\n' "$svc" "$PSTATE_NEXT"
  done
}

dash_acc_apply() { # instance text
  local s port st name="$1" k ngsvc ngst ngm
  # what was known of the blocks is dropped: a service with no line now has no state (the domain was removed, or the proxy changed)
  for k in "${!DASH_ACC_NG[@]}"; do
    [[ "$k" != "$name/"* ]] || unset "DASH_ACC_NG[$k]" "DASH_ACC_NGM[$k]" "DASH_ACC_NGN[$k]"
  done
  while read -r s port st; do
    [ -n "$s" ] || continue
    if [ "$s" = ng ]; then
      read -r ngsvc ngst ngm <<< "$port $st"
      DASH_ACC_NG[$name/$ngsvc]="$ngst" DASH_ACC_NGM[$name/$ngsvc]="$ngm"
      continue
    fi
    if [ "$s" = nx ]; then DASH_ACC_NGN[$name/$port]="$st"; continue; fi
    [ "$port" != "-" ] || port=""
    DASH_ACC_PORT[$name/$s]="$port" DASH_ACC_REACH[$name/$s]="$st"
  done <<< "$2"
  DASH_ACC_N=$((DASH_ACC_N + 1)) DASH_DIRTY=1
}

# Asks for the read (the test mode reads at once, and only when a test asks for it with DELTACTL_TUI_WSACC).
dash_acc_request() { # instance
  DASH_ACC_AT[$1]="$SECONDS"
  if tui_test_mode; then dash_acc_apply "$1" "$(dash_acc_dump "$1")"; return 0; fi
  dash_async accreach "$1" dash_acc_dump "$1" || true
}

ws_acceso_tick() {
  local name
  if dash_async_take accreach; then dash_acc_apply "${DASH_AS_ARG[accreach]}" "$DASH_AS_TEXT"; fi
  [ "$DASH_VIEW" = "instances" ] && [ "$DASH_ON_NEW" -eq 0 ] && [ "${#DASH_NAMES[@]}" -gt 0 ] || return 0
  [ "$DASH_WS_TAB" = "acceso" ] || return 0
  name="${DASH_NAMES[$DASH_SEL]}"
  dash_ws_effective "$name"
  [ "$DASH_WS_ID" = "acceso" ] || return 0
  dash_acc_load "$name"
  if tui_test_mode && [ -z "${DELTACTL_TUI_WSACC:-}" ]; then return 0; fi
  [ -z "${DASH_AS_PID[accreach]:-}" ] || return 0
  if [ -z "${DASH_ACC_AT[$name]:-}" ] || { ! tui_test_mode && [ $((SECONDS - DASH_ACC_AT[$name])) -ge 10 ]; }; then dash_acc_request "$name"; fi
}

# --- The names of the services, and putting the block in nginx ---------------------------------------------------------------------

DASH_ACC_TGT=""   # what the mode accdom is typing: "" the domain, or a service (its whole public name)
DASH_ACC_S="" DASH_ACC_OVV="" DASH_ACC_ED=""

# The service that is selected (the one of the marked row), into DASH_ACC_S.
dash_acc_svc() { # instance
  local -a svcs
  read -ra svcs <<< "${DASH_SVCS[$1]:-}"
  DASH_ACC_S="${svcs[$DASH_SVC]:-${svcs[0]:-}}"
}

# The name of its own that a service has (typed here or kept from `access`), into DASH_ACC_OVV.
dash_acc_ov_get() { # instance service
  local kv
  DASH_ACC_OVV=""
  for kv in ${DASH_ACC_OV[$1]:-}; do [ "${kv%%=*}" != "$2" ] || DASH_ACC_OVV="${kv#*=}"; done
}

# The domain that is in use, into DASH_ACC_ED: the typed one or, with none, what is left of the first name without its first label when every service
# has a name of its own (the names are what counts; the domain only has to be valid).
dash_acc_edom() { # instance
  local name="$1" s kv h first="" all=1
  local -a svcs
  read -ra svcs <<< "${DASH_SVCS[$name]:-}"
  DASH_ACC_ED="${DASH_ACC_DOM[$name]:-}"
  [ -z "$DASH_ACC_ED" ] || return 0
  [ "${#svcs[@]}" -gt 0 ] || return 0
  for s in "${svcs[@]}"; do
    h=""
    for kv in ${DASH_ACC_OV[$name]:-}; do [ "${kv%%=*}" != "$s" ] || h="${kv#*=}"; done
    if [ -z "$h" ]; then all=0; else [ -n "$first" ] || first="$h"; fi
  done
  [ "$all" -eq 1 ] && [ -n "$first" ] || return 0
  if [[ "$first" == *.*.* ]]; then DASH_ACC_ED="${first#*.}"; else DASH_ACC_ED="$first"; fi
}

# The whole name typed for a service in the mode accdom: a valid name that no other service uses is kept (lowered), an empty line gives the service
# back its default one; anything else is refused and the line stays open.
dash_acc_set_name() { # text service   (returns 1 when it is not accepted)
  local name="${DASH_NAMES[$DASH_SEL]:-}" s="$2" h="${1,,}" kv out=""
  h="${h#"${h%%[![:space:]]*}"}"
  h="${h%"${h##*[![:space:]]}"}"
  if [ -n "$h" ]; then
    if ! proxy_host_ok "$h"; then dash_msg warn "$(t tui.acc.msg.name_bad "$1")"; return 1; fi
    for kv in ${DASH_ACC_OV[$name]:-}; do
      if [ "${kv%%=*}" != "$s" ] && [ "${kv#*=}" = "$h" ]; then dash_msg warn "$(t tui.acc.msg.name_dup "${kv%%=*}")"; return 1; fi
    done
  fi
  for kv in ${DASH_ACC_OV[$name]:-}; do [ "${kv%%=*}" = "$s" ] || out+="$kv "; done
  [ -z "$h" ] || out+="$s=$h"
  DASH_ACC_OV[$name]="${out% }"
  DASH_ACC_N=$((DASH_ACC_N + 1)) DASH_ACC_SCROLL=0
  if [ -n "$h" ]; then dash_msg ok "$(t tui.acc.msg.name_set "$s" "$h")"; else dash_msg info "$(t tui.acc.msg.name_cleared "$s")"; fi
  return 0
}

# Saves the block and what the tab remembers (what `g` does) in instances/<name>/proxy/. 0 saved; 1 nothing to save; 2 it could not be written.
dash_acc_save() { # instance
  local name="$1" fl="${DASH_ACC_FL[$1]:-nginx}" rc=0
  dash_acc_model "$name"
  [ -n "$DASH_ACC_TEXT" ] || return 1
  PROXY_OUT="$DASH_ACC_TEXT"
  proxy_save "$name" "$fl" || rc=$?
  if [ "$rc" -eq 0 ]; then
    dash_acc_proxy_vars "$name"; dash_acc_edom "$name"
    proxy_meta_save "$name" "$DASH_ACC_ED" "$fl" "${DASH_ACC_TLS[$name]:-1}" || rc=$?
  fi
  DASH_ACC_N=$((DASH_ACC_N + 1))
  [ "$rc" -eq 0 ] || return 2
  return 0
}

# a / A (put the block of the selected service / of all of them in nginx) and x / X (take it out): it asks first, saying which names go to which port,
# and then runs `./deltactl access <instance> --apply|--remove` as a command, so what nginx said is in the Output view.
dash_acc_install() { # apply|remove one|all
  local name="${DASH_NAMES[$DASH_SEL]:-}" action="$1" scope="$2" fl rc s e host port label list="" note
  local -a args=()
  [ -n "$name" ] || return 0
  dash_acc_load "$name"
  fl="${DASH_ACC_FL[$name]:-nginx}"
  if [ "$fl" != nginx ]; then dash_msg warn "$(t tui.acc.msg.only_nginx)"; return 0; fi
  if [ "$action" = apply ]; then
    rc=0; dash_acc_save "$name" || rc=$?
    case "$rc" in
      0) ;;
      1) dash_msg warn "$(t tui.acc.msg.nothing)"; return 0 ;;
      *) dash_msg err "$(t tui.acc.msg.save_fail)"; return 0 ;;
    esac
  fi
  dash_acc_model "$name"
  dash_acc_svc "$name"; s="$DASH_ACC_S"
  for e in "${DASH_ACC_ENT[@]}"; do
    host="${e%%|*}" port="${e#*|}" label="${port#*|}" port="${port%%|*}"
    [ "$scope" = all ] || [ "$label" = "$s" ] || continue
    list+="${list:+, }$label $host :$port"
  done
  [ -n "$list" ] || { dash_msg warn "$(t tui.acc.msg.nothing)"; return 0; }
  if [ "${DASH_ACC_TLS[$name]:-1}" -eq 1 ]; then note="$(t tui.acc.confirm_tls)"; else note="$(t tui.acc.confirm_notls)"; fi
  args=(access "$name" "--$action" --yes)
  [ "$scope" = all ] || args+=(--service "$s")
  t_r "tui.acc.confirm_$action" "$name" "$list" "$note"   # (t_r: the key depends on the action)
  dash_confirm "$T_OUT" output "${args[@]}"
}

# --- Keys -----------------------------------------------------------------------------------------------------------------------

# The domain typed in the mode accdom: a valid name is kept (lowered), an empty line removes it, anything else is refused and the line stays open.
dash_acc_set_domain() { # text   (returns 1 when it is not a name)
  local name="${DASH_NAMES[$DASH_SEL]:-}" d="${1,,}"
  d="${d#"${d%%[![:space:]]*}"}"
  d="${d%"${d##*[![:space:]]}"}"
  if [ -n "$d" ] && ! proxy_host_ok "$d"; then dash_msg warn "$(t tui.acc.msg.domain_bad "$1")"; return 1; fi
  DASH_ACC_DOM[$name]="$d"
  DASH_ACC_N=$((DASH_ACC_N + 1)) DASH_ACC_SCROLL=0
  if [ -n "$d" ]; then dash_msg ok "$(t tui.acc.msg.domain_set "$d")"; else dash_msg info "$(t tui.acc.msg.domain_cleared)"; fi
  return 0
}

ws_acceso_key() { # key
  local name="${DASH_NAMES[$DASH_SEL]:-}" fl page rc
  [ -n "$name" ] || return 1
  dash_acc_load "$name"
  fl="${DASH_ACC_FL[$name]:-nginx}"
  page=$((TUI_ROWS / 2))
  case "$1" in
    enter) DASH_MODE=accdom DASH_BUF="${DASH_ACC_DOM[$name]:-}" DASH_CUR="${#DASH_BUF}" ;;
    b)
      if [ "$fl" = nginx ]; then DASH_ACC_FL[$name]=caddy; else DASH_ACC_FL[$name]=nginx; fi
      DASH_ACC_N=$((DASH_ACC_N + 1)) DASH_ACC_SCROLL=0
      ;;
    w) DASH_ACC_TLS[$name]=$((1 - ${DASH_ACC_TLS[$name]:-1})); DASH_ACC_N=$((DASH_ACC_N + 1)) ;;
    y)
      dash_acc_model "$name"
      if [ -z "$DASH_ACC_TEXT" ]; then dash_msg warn "$(t tui.acc.msg.nothing)"
      elif dash_srv_copy "$DASH_ACC_TEXT"; then dash_msg ok "$(t tui.acc.msg.copied "$fl")"
      else dash_msg warn "$(t tui.acc.msg.copy_fail)"; fi
      ;;
    g)
      rc=0; dash_acc_save "$name" || rc=$?
      case "$rc" in
        0) dash_msg ok "$(t tui.acc.msg.saved "instances/$name/proxy/$(proxy_file "$fl")")" ;;
        1) dash_msg warn "$(t tui.acc.msg.nothing)" ;;
        *) dash_msg err "$(t tui.acc.msg.save_fail)" ;;
      esac
      ;;
    e)
      dash_acc_svc "$name"
      [ -n "$DASH_ACC_S" ] || return 0
      dash_acc_ov_get "$name" "$DASH_ACC_S"
      DASH_ACC_TGT="$DASH_ACC_S" DASH_BUF="$DASH_ACC_OVV" DASH_CUR="${#DASH_ACC_OVV}" DASH_MODE=accdom
      ;;
    a) dash_acc_install apply one ;;
    A) dash_acc_install apply all ;;
    R) dash_acc_install remove one ;;
    X) dash_acc_install remove all ;;
    pgup) DASH_ACC_SCROLL=$((DASH_ACC_SCROLL - page)); [ "$DASH_ACC_SCROLL" -ge 0 ] || DASH_ACC_SCROLL=0 ;;
    pgdn) DASH_ACC_SCROLL=$((DASH_ACC_SCROLL + page)) ;;    # (clamped to the last line when drawn)
    home) DASH_ACC_SCROLL=0 ;;
    *) return 1 ;;
  esac
  return 0
}

ws_acceso_texts() {
  DASH_KEYS[ws_acceso]="$(t tui.acc.keys "$DASH_UD" "$DASH_LEFT")"
}

# What the box depends on.
ws_acceso_sig() {
  local name="${DASH_NAMES[$DASH_SEL]:-}"
  DASH_WS_SIG+="|$name|$DASH_ACC_N|$DASH_ACC_SCROLL|$DASH_SVC|${DASH_ACC_FL[$name]:-}|${DASH_ACC_TLS[$name]:-}|$DASH_ACC_DET|$TH_NAME|${UI_UTF8:-0}"
  if [ "$DASH_MODE" = "accdom" ]; then DASH_WS_SIG+="|$DASH_BUF|$DASH_CUR"; fi
}

# --- Drawing --------------------------------------------------------------------------------------------------------------------

# The label column of a line (10 cells, dim) into DASH_ACC_LAB.
DASH_ACC_LAB=""
dash_acc_label() { # key
  dt "$1"
  tui_fit "$DTV" 10
  DASH_ACC_LAB="${TH[dim]:-$C_GRY}$TUI_OUT$TH_RESET"
}

# The lines of the top of the box (the domain, the proxy and HTTPS) into DASH_ACC_TOP.
DASH_ACC_TOP=()
dash_acc_top() { # instance width
  local name="$1" iw="$2" dom fl tls editing=0 val cur st msg ph n line d lbl
  DASH_ACC_TOP=()
  dom="${DASH_ACC_DOM[$name]:-}" fl="${DASH_ACC_FL[$name]:-nginx}" tls="${DASH_ACC_TLS[$name]:-1}"
  [ "$DASH_MODE" != "accdom" ] || editing=1
  val="$dom" cur="${#dom}" d="$dom"
  if [ "$editing" -eq 1 ]; then val="$DASH_BUF" cur="$DASH_CUR" d="${DASH_BUF,,}"; fi
  if [ -z "$d" ]; then st=pend msg=""
  elif proxy_host_ok "$d"; then st=ok msg=""
  else st=err; dt tui.acc.dom_bad; msg="$DTV"; fi
  dt tui.acc.lbl.domain; lbl="$DTV"
  if [ "$editing" -eq 1 ] && [ -n "$DASH_ACC_TGT" ]; then t_r tui.acc.lbl.name "$DASH_ACC_TGT"; lbl="$T_OUT"; fi
  dt tui.acc.ph; ph="$DTV"
  kit_field_render "$lbl" "$val" "$cur" "$iw" label_width=10 focus="$editing" placeholder="$ph" state="$st" msg="$msg"
  DASH_ACC_TOP+=("$KIT_OUT")
  # The proxy: the two, the one chosen marked, and which one this server has.
  dash_acc_label tui.acc.lbl.proxy
  line="$DASH_ACC_LAB"
  for n in nginx caddy; do
    if [ "$n" = "$fl" ]; then line+="${TH[accent]:-$C_CYN}$C_BLD$UI_S_OK $n$TH_RESET   "; else line+="${TH[dim]:-$C_GRY}$UI_S_PEND $n$TH_RESET   "; fi
  done
  if [ -n "$DASH_ACC_DET" ]; then dash_ws_t tui.acc.detected "$DASH_ACC_DET"; else dt tui.acc.not_detected; DASH_T="$DTV"; fi
  line+="${TH[dim]:-$C_GRY}$DASH_T$TH_RESET"
  tui_fit "$line" "$iw"; DASH_ACC_TOP+=("$TUI_OUT")
  # HTTPS.
  dash_acc_label tui.acc.lbl.https
  line="$DASH_ACC_LAB"
  if [ "$tls" -eq 1 ]; then
    dt tui.acc.yes; line+="${TH[ok]:-$C_GRN}$DTV$TH_RESET"
    if [ "$fl" = caddy ]; then dt tui.acc.tls_caddy; else dt tui.acc.tls_nginx; fi
  else
    dt tui.acc.no; line+="${TH[warn]:-$C_YEL}$DTV$TH_RESET"
    dt tui.acc.tls_no
  fi
  line+="   ${TH[dim]:-$C_GRY}$DTV$TH_RESET"
  tui_fit "$line" "$iw"; DASH_ACC_TOP+=("$TUI_OUT")
}

# The table of the services (their port, whether they answer on this server, their public name) into DASH_ACC_TAB.
DASH_ACC_TAB=()
dash_acc_table() { # instance width
  local name="$1" iw="$2" s i port st icon txt line host pw=7 rw=17 withname=1 ngw=18 withng=0 ng ngi ngt
  local -a svcs
  DASH_ACC_TAB=()
  read -ra svcs <<< "${DASH_SVCS[$name]:-}"
  [ "$iw" -ge 58 ] || withname=0
  # the column of nginx only when some service has a state (the read has been made) and there is room for it and for the names
  if [ "$iw" -ge 74 ]; then
    for s in "${svcs[@]}"; do [ -z "${DASH_ACC_NG[$name/$s]:-}" ] || withng=1; done
  fi
  [ "$withng" -eq 0 ] || rw=14    # (the column of whether it answers is made shorter to make room: its words are short)
  dt tui.acc.th.svc; line="  $DTV"
  tui_fit "$line" 11; line="$TUI_OUT"
  dt tui.acc.th.port; tui_fit "$DTV" "$pw"; line+="$TUI_OUT"
  if [ "$withng" -eq 1 ]; then dt tui.acc.th.local_short; else dt tui.acc.th.local; fi
  tui_fit "$DTV" "$rw"; line+="  $TUI_OUT"
  if [ "$withng" -eq 1 ]; then dt tui.acc.th.ng; tui_fit "$DTV" "$ngw"; line+="  $TUI_OUT"; fi
  if [ "$withname" -eq 1 ]; then dt tui.acc.th.name; line+="  $DTV"; fi
  tui_fit "$line" "$iw"; DASH_ACC_TAB+=("${TH[dim]:-$C_GRY}$TUI_OUT$TH_RESET")
  for i in "${!svcs[@]}"; do
    s="${svcs[$i]}"
    port="${DASH_ACC_PORT[$name/$s]:-}"
    st="${DASH_ACC_REACH[$name/$s]:-}"
    [ -n "$port" ] || st=noport
    case "$st" in
      up) kit_state_icon ok; dt tui.acc.reach.up ;;
      down) kit_state_icon err; dt tui.acc.reach.down ;;
      noport) kit_state_icon warn; dt tui.acc.reach.noport ;;
      *) kit_state_icon pend; dt tui.acc.reach.none ;;
    esac
    icon="$KIT_ICON" txt="$DTV"
    tui_fit "$s" 8; line="$icon $TUI_OUT"
    if [ -n "$port" ]; then tui_fit ":$port" "$pw"; else tui_fit "-" "$pw"; fi
    line+="$TUI_OUT"
    tui_fit "$txt" "$rw"; line+="  $TUI_OUT"
    if [ "$withng" -eq 1 ]; then
      ng="${DASH_ACC_NG[$name/$s]:-}"
      dash_acc_ng_cell "$ng"; ngi="$KIT_ICON" ngt="$DTV"
      tui_fit "$ngt" $((ngw - 2)); line+="  $ngi $TUI_OUT"
    fi
    host="${DASH_ACC_HOSTS[$i]:-}"
    if [ "$withname" -eq 1 ] && [ -n "$host" ]; then line+="  ${TH[accent]:-$C_CYN}$host$TH_RESET"; fi
    tui_fit "$line" "$((iw - 2))"; line="$TUI_OUT"
    if [ "$DASH_FOCUS" = "tab" ] && [ "$i" -eq "$DASH_SVC" ]; then DASH_ACC_TAB+=("$TUI_SEL${TH[accent]:-$C_CYN}$UI_S_SEL$TH_RESET $line")
    else DASH_ACC_TAB+=("  $line"); fi
  done
  # what the nginx block of the selected service needs, in a line (nothing when it is active or not read yet)
  s="${svcs[$DASH_SVC]:-}"
  ng="${DASH_ACC_NG[$name/$s]:-}"
  if [ -n "$ng" ] && [ "$ng" != active ]; then
    t_r access.state.$ng "${DASH_ACC_NGM[$name/$s]:-}"; ngt="$T_OUT"
    line="  ${TH[dim]:-$C_GRY}$s: $ngt"
    tui_fit "$line$TH_RESET" "$((iw - 2))"; DASH_ACC_TAB+=("$TUI_OUT")
    if [ -n "${DASH_ACC_NGN[$name/$s]:-}" ]; then
      tui_fit "    ${TH[dim]:-$C_GRY}${DASH_ACC_NGN[$name/$s]}$TH_RESET" "$((iw - 2))"; DASH_ACC_TAB+=("$TUI_OUT")
    fi
  fi
}

# The icon and the short text of the state of a block (into KIT_ICON and DTV).
dash_acc_ng_cell() { # state
  case "$1" in
    active) kit_state_icon ok ;;
    reload | installed | stale | disabled | none) kit_state_icon warn ;;
    nocert | down) kit_state_icon err ;;
    *) kit_state_icon pend ;;
  esac
  case "$1" in
    '') dt tui.acc.ng.none_read ;;
    *) dt "tui.acc.ng.$1" ;;
  esac
}

ws_acceso_box() { # instance width height
  local name="$1" w="$2" h="$3" iw ih rows fl i n start line st chip foot tab_n bf
  local -a body=() opts=()
  iw=$((w - 3)) ih=$((h - 2))
  dash_acc_load "$name"
  dash_acc_model "$name"
  fl="${DASH_ACC_FL[$name]:-nginx}"
  dash_acc_top "$name" "$iw"
  body=("${DASH_ACC_TOP[@]}")
  # The table of the services when there is room for it and still four lines of block.
  dash_acc_table "$name" "$iw"
  tab_n="${#DASH_ACC_TAB[@]}"
  if [ $((ih - 3 - 1 - tab_n - 1 - 4)) -ge 0 ]; then body+=("" "${DASH_ACC_TAB[@]}"); fi
  # The block: its header (which one, and whether what is saved is what would be written now) and as many lines as fit, scrolled.
  if [ "$ih" -gt "${#body[@]}" ]; then
    body+=("")
    dash_ws_t tui.acc.block "$fl"
    line="$C_BLD$DASH_T$C_OFF"
    if [ -n "$DASH_ACC_TEXT" ]; then
      case "$DASH_ACC_SAVED" in
        same) kit_state_icon ok; dt tui.acc.saved.same ;;
        differs) kit_state_icon warn; dt tui.acc.saved.differs ;;
        *) kit_state_icon pend; dt tui.acc.saved.none ;;
      esac
      line+="  $KIT_ICON $DTV"
      if [ "$fl" = nginx ]; then bf=nginx.conf; else bf=Caddyfile; fi      # (proxy_file, with no process)
      dash_ws_t tui.acc.block_file "$bf"
      line+="  ${TH[dim]:-$C_GRY}$DASH_T$TH_RESET"
    fi
    tui_fit "$line" "$iw"; body+=("$TUI_OUT")
    # Where the block goes, in a line (deltactl does not put it there).
    if [ -n "$DASH_ACC_TEXT" ] && [ "$ih" -gt "${#body[@]}" ]; then
      dt "tui.acc.where.$fl"
      tui_fit "${TH[dim]:-$C_GRY}$DTV$TH_RESET" "$iw"; body+=("$TUI_OUT")
    fi
  fi
  rows=$((ih - ${#body[@]}))
  if [ "$rows" -gt 0 ]; then
    if [ -n "$DASH_ACC_TEXT" ]; then
      n="${#DASH_ACC_BLOCK[@]}"
      start="$DASH_ACC_SCROLL"
      [ "$start" -le $((n - rows)) ] || start=$((n - rows))
      [ "$start" -ge 0 ] || start=0
      DASH_ACC_SCROLL="$start"
      for ((i = start; i < start + rows && i < n; i++)); do
        line="${DASH_ACC_BLOCK[$i]}"
        if [[ "$line" == "#"* ]]; then tui_fit "${TH[dim]:-$C_GRY}$line$TH_RESET" "$iw"; else tui_fit "$line" "$iw"; fi
        body+=("$TUI_OUT")
      done
    elif [ -z "${DASH_ACC_DOM[$name]:-}" ] && [ "$DASH_MODE" != "accdom" ]; then
      dash_ws_t tui.acc.hint "$fl"
      kit_wrap "$DASH_T" "$((iw - 2))"
      for line in "${KW_LINES[@]}"; do tui_fit "  ${TH[dim]:-$C_GRY}$line$TH_RESET" "$iw"; body+=("$TUI_OUT"); done
    elif [ -n "$DASH_ACC_ERR" ]; then
      case "$DASH_ACC_ERR" in
        port:*) dash_ws_t tui.acc.err.port "${DASH_ACC_ERR#port:}" ;;
        domain) dt tui.acc.dom_bad; DASH_T="$DTV" ;;
        *) dash_ws_t tui.acc.err.render "${DASH_ACC_ERR#render:}" ;;
      esac
      kit_wrap "$DASH_T" "$((iw - 2))"
      for line in "${KW_LINES[@]}"; do tui_fit "  ${TH[err]:-$C_RED}$line$TH_RESET" "$iw"; body+=("$TUI_OUT"); done
    fi
  fi
  # The border: who it is and which proxy this server has; the keys of the tab at the bottom.
  dash_ws_esc "$name"; dt tui.ws.tab.acceso
  chip="$DASH_WS_ESC|$DTV"
  if [ -n "$DASH_ACC_DET" ]; then kit_state_icon ok; dash_ws_t tui.acc.detected "$DASH_ACC_DET"; else kit_state_icon dim; dt tui.acc.not_detected_short; DASH_T="$DTV"; fi
  st="$KIT_ICON $DASH_T"
  foot=""
  for i in domain name nginx save block https copy off; do dt "tui.acc.foot.$i"; foot+="${foot:+|}$DTV"; done
  if dash_ws_has_strip; then dt tui.ws.foot.tabs; foot+="|$DTV"; fi
  opts=("chips=$chip" "status=$st" "footer=$foot")
  if [ "$DASH_FOCUS" = "tab" ]; then opts+=(focus=1); fi
  [ "${#body[@]}" -le "$ih" ] || body=("${body[@]:0:$ih}")    # (a box smaller than the three first lines shows the first ones)
  kit_box "$w" "$h" body "${opts[@]}"
  TUI_BOX=("${KIT_BOX[@]}")
}

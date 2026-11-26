#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # DASH_NZ_* belong to lib/screens/newinst.sh
# Step 7 of the new-instance wizard: the access. With what name is the instance reached from the internet? Each service has its own public name (a DNS
# name written whole: backs0m1.delta-dispatch.com), typed or pasted in a modal that opens with Enter on its row. A base domain is optional: when it is
# there it gives <name of the service>.<domain> to the services that were left without a name; when it is not, every service needs its own name and the
# base domain the command carries is what is left of the first name without its first label (the names are what counts, the base only has to be valid).
# With a name or a domain `new` prepares the block of the reverse proxy of each service: nginx, Caddy or both, with HTTPS or not.
# THE BLOCK IS TEXT (lib/core/proxy.sh): it is shown here, can be copied (c), and `new` saves it inside the instance (instances/<name>/proxy/).
# Nothing is written under /etc and nothing is reloaded or installed, ever: the person puts it where their proxy reads it. Everything here is
# optional; without a name or a domain nothing is generated (the access tab of the instance will do it later).
#
# The focus moves with ↑↓ through the rows: the base domain (a text field), one row per service (Enter edits its name in a modal), the proxy (←→ or
# Space change it) and HTTPS (Space). `c` copies the block shown, `v` shows the other one when both are chosen. Enter on the proxy or on HTTPS goes
# on to the review, which is where the instance is created; on a row of a service Enter edits, so `s` goes on from there.

DASH_NZA_DOMAIN="" DASH_NZA_FLAVOR="" DASH_NZA_TLS=1 DASH_NZA_FOCUS=0 DASH_NZA_VIEW=0 DASH_NZA_DET=""
DASH_NZA_OKD=0                      # 1 when what was answered is valid (a domain, the names of the services)
DASH_NZA_WHY=""                     # why it is not (a text), when it is not
DASH_NZA_BASE=""                    # the base domain in use: the one typed, or the one taken from the names
DASH_NZA_BLOCK=() DASH_NZA_BSIG="" DASH_NZA_BTEXT="" DASH_NZA_BERR=""
declare -gA DASH_NZA_HOST=()        # the name of each service typed in the modal ("" or not there: the default)
DASH_NZA_EDIT=0 DASH_NZA_ES="" DASH_NZA_EST=pend DASH_NZA_EMSG="" DASH_NZA_MODAL=()   # the modal: open, the service, its state and what it says
DASH_NZA_NS=0 DASH_NZA_FP=1 DASH_NZA_FT=2                                             # rows: services, the focus of the proxy and of HTTPS

dash_nzs_access_reset() {
  DASH_NZA_DOMAIN="" DASH_NZA_FLAVOR="" DASH_NZA_TLS=1 DASH_NZA_FOCUS=0 DASH_NZA_VIEW=0 DASH_NZA_DET=""
  DASH_NZA_BLOCK=() DASH_NZA_BSIG="" DASH_NZA_BTEXT="" DASH_NZA_BERR="" DASH_NZA_BASE="" DASH_NZA_WHY=""
  DASH_NZA_HOST=() DASH_NZA_EDIT=0 DASH_NZA_ES="" DASH_NZA_EMSG="" DASH_NZA_MODAL=()
}

dash_nzs_access_enter() {
  DASH_NZA_DET="$(proxy_detect)"
  # The proxy that is on this server is the one proposed; with none, both are generated (they are only text).
  [ -n "$DASH_NZA_FLAVOR" ] || { if [ -n "$DASH_NZA_DET" ]; then DASH_NZA_FLAVOR="$DASH_NZA_DET"; else DASH_NZA_FLAVOR=both; fi; }
  KF_VALUE="$DASH_NZA_DOMAIN" KF_CUR="${#DASH_NZA_DOMAIN}"
  DASH_NZA_EDIT=0
  dash_nzsa_rows
  [ "$DASH_NZA_FOCUS" -le "$DASH_NZA_FT" ] || DASH_NZA_FOCUS="$DASH_NZA_FT"
}

dash_nzs_access_typing() { [ "$DASH_NZA_FOCUS" -eq 0 ] || [ "$DASH_NZA_EDIT" -ne 0 ]; }

# The rows below the domain: one for each service chosen, then the proxy and HTTPS (into DASH_NZA_NS, DASH_NZA_FP and DASH_NZA_FT).
dash_nzsa_rows() {
  dash_nz_sel_list
  DASH_NZA_NS="${#DASH_NZ_SL[@]}"
  DASH_NZA_FP=$((DASH_NZA_NS + 1)) DASH_NZA_FT=$((DASH_NZA_NS + 2))
}

# The base domain in use, into DASH_NZA_BASE: the one typed, or (with none) what is left of the first name without its first label when every
# service has a name of its own. Empty when there is nothing to base a block on.
dash_nzsa_base() {
  local s h first="" all=1
  DASH_NZA_BASE=""
  if [ -n "$DASH_NZA_DOMAIN" ]; then DASH_NZA_BASE="${DASH_NZA_DOMAIN,,}"; return 0; fi
  dash_nz_sel_list
  [ "${#DASH_NZ_SL[@]}" -gt 0 ] || return 0
  for s in "${DASH_NZ_SL[@]}"; do
    h="${DASH_NZA_HOST[$s]:-}"
    if [ -z "$h" ]; then all=0; else [ -n "$first" ] || first="$h"; fi
  done
  [ "$all" -eq 1 ] && [ -n "$first" ] || return 0
  if [[ "$first" == *.*.* ]]; then DASH_NZA_BASE="${first#*.}"; else DASH_NZA_BASE="$first"; fi
}

# What the services answer to: the name typed for each one goes where the generator reads it (PROXY_HOSTS).
dash_nzsa_hosts() {
  local s
  PROXY_HOSTS=()
  for s in "${DASH_NZ_SL[@]}"; do
    [ -z "${DASH_NZA_HOST[$s]:-}" ] || PROXY_HOSTS[$s]="${DASH_NZA_HOST[$s]}"
  done
}

# Is what was answered valid? DASH_NZA_OKD, and DASH_NZA_WHY says why not: a domain that is not one, a name that is not valid or that two services
# share, or names for only some of the services when there is no domain to give the others theirs. Empty answers are valid (nothing is generated).
dash_nzsa_check() {
  local d="${DASH_NZA_DOMAIN,,}" s h t seen="" missing=""
  DASH_NZA_OKD=1 DASH_NZA_WHY=""
  dash_nz_sel_list
  if [ -n "$d" ] && ! proxy_host_ok "$d"; then t_r tui.nz.acc.invalid "$DASH_NZA_DOMAIN"; DASH_NZA_OKD=0 DASH_NZA_WHY="$T_OUT"; return 0; fi
  for s in "${DASH_NZ_SL[@]}"; do
    h="${DASH_NZA_HOST[$s]:-}"
    if [ -z "$h" ]; then missing+="${missing:+, }$s"; continue; fi
    if ! proxy_host_ok "$h"; then t_r tui.nz.acc.bad_host "$s" "$h"; DASH_NZA_OKD=0 DASH_NZA_WHY="$T_OUT"; return 0; fi
    for t in $seen; do
      if [ "${DASH_NZA_HOST[${t}]}" = "$h" ]; then t_r tui.nz.acc.dup "$s" "$t"; DASH_NZA_OKD=0 DASH_NZA_WHY="$T_OUT"; return 0; fi
    done
    seen+="${seen:+ }$s"
  done
  # some names and no domain for the rest: those services would have no name
  if [ -z "$d" ] && [ -n "$seen" ] && [ -n "$missing" ]; then t_r tui.nz.acc.need_hosts "$missing"; DASH_NZA_OKD=0 DASH_NZA_WHY="$T_OUT"; fi
  return 0
}

# The flavors that are shown/generated (nginx, caddy or both) into DASH_NZA_FLS.
DASH_NZA_FLS=()
dash_nzsa_flavors() {
  case "${DASH_NZA_FLAVOR:-both}" in both) DASH_NZA_FLS=(nginx caddy) ;; *) DASH_NZA_FLS=("$DASH_NZA_FLAVOR") ;; esac
}

# The name of the file of a flavor, into DASH_NZA_FILE (the same as proxy_file, with no process).
DASH_NZA_FILE=""
dash_nzsa_file() { # flavor
  if [ "$1" = nginx ]; then DASH_NZA_FILE=nginx.conf; else DASH_NZA_FILE=Caddyfile; fi
}

# --- The modal: the whole name of a service ----------------------------------------------------------------------------------------------------

# The look at the name being typed: valid, not valid, or the same as another service's.
dash_nzsa_medit_check() {
  local v="${KF_VALUE,,}" s
  DASH_NZA_EMSG=""
  if [ -z "$v" ]; then DASH_NZA_EST=pend; return 0; fi
  if ! proxy_host_ok "$v"; then DASH_NZA_EST=err; t_r tui.nz.acc.m_bad; DASH_NZA_EMSG="$T_OUT"; return 0; fi
  for s in "${DASH_NZ_SL[@]}"; do
    if [ "$s" != "$DASH_NZA_ES" ] && [ "${DASH_NZA_HOST[$s]:-}" = "$v" ]; then DASH_NZA_EST=err; t_r tui.nz.acc.m_dup "$s"; DASH_NZA_EMSG="$T_OUT"; return 0; fi
  done
  DASH_NZA_EST=ok
}

dash_nzsa_medit_open() { # service
  DASH_NZA_ES="$1" DASH_NZA_EDIT=1
  KF_VALUE="${DASH_NZA_HOST[$1]:-}" KF_CUR="${#KF_VALUE}"
  dash_nzsa_medit_check
  DASH_NZ_ERR=""
}

dash_nzsa_medit_key() { # key
  local k="$1"
  case "$k" in
    enter)
      dash_nzsa_medit_check
      [ "$DASH_NZA_EST" != err ] || return 0
      if [ -z "$KF_VALUE" ]; then unset 'DASH_NZA_HOST[$DASH_NZA_ES]'; else DASH_NZA_HOST[$DASH_NZA_ES]="${KF_VALUE,,}"; fi
      DASH_NZA_EDIT=0 DASH_NZA_BSIG=""
      ;;
    esc) DASH_NZA_EDIT=0 ;;
    tab | btab | up | down | pgup | pgdn) ;;
    *) if kit_field_key "$k"; then dash_nzsa_medit_check; fi ;;
  esac
}

# The modal as lines (into DASH_NZA_MODAL), $1 cells of screen wide: what it asks, the field and what is wrong with the name.
dash_nzsa_modal() { # width
  local mw=$(($1 - 6)) l body=()
  [ "$mw" -le 76 ] || mw=76
  [ "$mw" -ge 30 ] || mw="$1"
  t_r tui.nz.acc.m_text "${CAT_NAME[$DASH_NZA_ES]:-$DASH_NZA_ES}" "${DASH_NZA_BASE:-example.com}"
  kit_wrap "$T_OUT" $((mw - 4))
  body=("")
  for l in "${KW_LINES[@]}"; do body+=("$l"); done
  body+=("")
  kit_field_render "" "$KF_VALUE" "$KF_CUR" $((mw - 4)) label_width=0 focus=1 state="$DASH_NZA_EST"
  body+=("$KIT_OUT")
  if [ -n "$DASH_NZA_EMSG" ]; then tui_fit "  ${TH[err]:-}$DASH_NZA_EMSG$TH_RESET" $((mw - 4)); body+=("$TUI_OUT"); else body+=(""); fi
  t_r tui.nz.acc.m_foot
  kit_box "$mw" $((${#body[@]} + 2)) body "chips=$DASH_NZA_ES" "footer=$T_OUT" focus=1
  DASH_NZA_MODAL=("${KIT_BOX[@]}")
}

# Lays the modal over what the step drew (DASH_NZ_B, $1 cells wide) while a name is being typed.
dash_nzsa_overlay() { # width
  local i
  [ "$DASH_NZA_EDIT" -ne 0 ] || return 0
  dash_nzsa_modal "$1"
  for ((i = 0; i < ${#DASH_NZ_B[@]}; i++)); do
    DASH_NZ_B[i]="${DASH_NZ_B[$i]#"$TUI_SEL"}"   # (the marker of the selected row does not survive being cut)
    tui_fit "${DASH_NZ_B[$i]}" "$1"; DASH_NZ_B[i]="$TUI_OUT"
  done
  kit_center DASH_NZ_B DASH_NZA_MODAL
}

# --- Keys --------------------------------------------------------------------------------------------------------------------------------

dash_nzs_access_key() { # key
  local k="$1" f
  dash_nzsa_rows
  if [ "$DASH_NZA_EDIT" -ne 0 ]; then dash_nzsa_medit_key "$k"; return 0; fi
  case "$k" in
    up | down)
      # (inside the text field up/down only move the focus)
      if [ "$k" = up ]; then [ "$DASH_NZA_FOCUS" -le 0 ] || DASH_NZA_FOCUS=$((DASH_NZA_FOCUS - 1))
      else [ "$DASH_NZA_FOCUS" -ge "$DASH_NZA_FT" ] || DASH_NZA_FOCUS=$((DASH_NZA_FOCUS + 1)); fi
      DASH_NZ_ERR=""
      return 0
      ;;
  esac
  if [ "$DASH_NZA_FOCUS" -eq 0 ]; then
    case "$k" in enter | esc | tab | btab | pgup | pgdn) return 1 ;; esac
    kit_field_key "$k" || return 1
    DASH_NZA_DOMAIN="$KF_VALUE" DASH_NZ_ERR="" DASH_NZA_BSIG=""
    return 0
  fi
  # a row of a service: Enter edits its name (and `s` goes on, since Enter is taken)
  if [ "$DASH_NZA_FOCUS" -le "$DASH_NZA_NS" ]; then
    case "$k" in
      enter | e) dash_nzsa_medit_open "${DASH_NZ_SL[$((DASH_NZA_FOCUS - 1))]}"; return 0 ;;
      s) dash_nz_next; return 0 ;;
      x | delete | backspace) unset 'DASH_NZA_HOST[${DASH_NZ_SL[$((DASH_NZA_FOCUS - 1))]}]'; DASH_NZA_BSIG="" DASH_NZ_ERR=""; return 0 ;;
    esac
  fi
  case "$k" in
    c)
      dash_nzsa_build
      if [ -z "$DASH_NZA_BTEXT" ]; then t_r tui.nz.acc.nothing_copy; DASH_NZ_ERR="$T_OUT"; return 0; fi
      if dash_srv_copy "$DASH_NZA_BTEXT"; then dash_msg ok "$(t tui.nz.acc.copied)"; else dash_msg warn "$(t tui.nz.acc.copy_fail)"; fi
      ;;
    v) DASH_NZA_VIEW=$((1 - DASH_NZA_VIEW)) DASH_NZA_BSIG="" ;;
    left | right | space | h | l)
      if [ "$DASH_NZA_FOCUS" -eq "$DASH_NZA_FP" ]; then
        case "$DASH_NZA_FLAVOR:$k" in
          nginx:right | nginx:space | nginx:l) f=caddy ;;
          caddy:right | caddy:space | caddy:l) f=both ;;
          both:right | both:space | both:l) f=nginx ;;
          nginx:left | nginx:h) f=both ;;
          caddy:left | caddy:h) f=nginx ;;
          *) f=caddy ;;
        esac
        DASH_NZA_FLAVOR="$f" DASH_NZA_VIEW=0 DASH_NZA_BSIG=""
      elif [ "$DASH_NZA_FOCUS" -eq "$DASH_NZA_FT" ]; then
        DASH_NZA_TLS=$((1 - DASH_NZA_TLS)) DASH_NZA_BSIG=""
      fi
      ;;
    x) [ "$DASH_NZA_FOCUS" -ne "$DASH_NZA_FT" ] || { DASH_NZA_TLS=$((1 - DASH_NZA_TLS)); DASH_NZA_BSIG=""; } ;;
    *) return 1 ;;
  esac
  return 0
}

# --- The block ---------------------------------------------------------------------------------------------------------------------------

# The text of the block that is shown (the first flavor, or the second one with `v`) into DASH_NZA_BTEXT, and its lines into DASH_NZA_BLOCK. It is made
# again only when what it depends on changed.
dash_nzsa_build() {
  local sig s fl view
  local -a ent=()
  dash_nz_sel_list
  dash_nzsa_check
  dash_nzsa_base
  sig="$DASH_NZA_DOMAIN|$DASH_NZA_FLAVOR|$DASH_NZA_TLS|$DASH_NZA_VIEW|$DASH_NZ_CSV"
  for s in "${DASH_NZ_SL[@]}"; do sig+="|${DASH_NZ_PORT[$s]:-}:${DASH_NZA_HOST[$s]:-}"; done
  [ "$sig" != "$DASH_NZA_BSIG" ] || return 0
  DASH_NZA_BSIG="$sig" DASH_NZA_BTEXT="" DASH_NZA_BLOCK=() DASH_NZA_BERR=""
  [ -n "$DASH_NZA_BASE" ] && [ "$DASH_NZA_OKD" -eq 1 ] || return 0
  PROXY_PORTS=()
  for s in "${DASH_NZ_SL[@]}"; do PROXY_PORTS[$s]="${DASH_NZ_PORT[$s]:-}"; done
  dash_nzsa_hosts
  proxy_domain_names "$DASH_NZA_BASE" "${DASH_NZ_SL[@]}" || return 0
  ent=("${PROXY_ENTRIES[@]}")
  dash_nzsa_flavors
  view=$((DASH_NZA_VIEW % ${#DASH_NZA_FLS[@]}))
  fl="${DASH_NZA_FLS[$view]}"
  if proxy_render "$fl" "$DASH_NZA_TLS" "${ent[@]}"; then
    DASH_NZA_BTEXT="$PROXY_OUT"
    mapfile -t DASH_NZA_BLOCK <<< "${PROXY_OUT%$'\n'}"
    # (what is shown starts at the first directive: the lines of comments that open the file are said by the title and the note)
    while [ "${#DASH_NZA_BLOCK[@]}" -gt 1 ] && [[ "${DASH_NZA_BLOCK[0]}" == "#"* ]]; do DASH_NZA_BLOCK=("${DASH_NZA_BLOCK[@]:1}"); done
  else
    DASH_NZA_BERR="$PROXY_ERR"
  fi
}

# --- State, gate, what it adds to the command, the preview ----------------------------------------------------------------------------------

dash_nzs_access_state() {
  dash_nzsa_check
  dash_nzsa_base
  if [ "$DASH_NZA_OKD" -eq 0 ]; then DASH_NZ_ST=err DASH_NZ_VAL="${DASH_NZA_DOMAIN:-…}"
  elif [ -z "$DASH_NZA_BASE" ]; then DASH_NZ_ST=ok; t_r tui.nz.acc.v_none; DASH_NZ_VAL="$T_OUT"
  else DASH_NZ_ST=ok DASH_NZ_VAL="$DASH_NZA_BASE"; fi
}

dash_nzs_access_gate() {
  dash_nzsa_check
  [ "$DASH_NZA_OKD" -eq 1 ] && return 0
  DASH_NZ_ERR="$DASH_NZA_WHY"
  return 1
}

dash_nzs_access_sig() {
  local s h=""
  dash_nz_sel_list
  for s in "${DASH_NZ_SL[@]}"; do h+=":${DASH_NZA_HOST[$s]:-}"; done
  DASH_NZ_AS+="|acc:$DASH_NZA_DOMAIN:$DASH_NZA_FLAVOR:$DASH_NZA_TLS$h:$DASH_NZA_EDIT"
}

dash_nzs_access_args() {
  local s
  dash_nzsa_check
  dash_nzsa_base
  [ -n "$DASH_NZA_BASE" ] && [ "$DASH_NZA_OKD" -eq 1 ] || return 0
  DASH_NZ_ARGV+=(--domain "$DASH_NZA_BASE")
  dash_nz_sel_list
  for s in "${DASH_NZ_SL[@]}"; do [ -z "${DASH_NZA_HOST[$s]:-}" ] || DASH_NZ_ARGV+=(--host "$s=${DASH_NZA_HOST[$s]}"); done
  [ "${DASH_NZA_FLAVOR:-both}" = both ] || DASH_NZ_ARGV+=(--proxy "$DASH_NZA_FLAVOR")
  [ "$DASH_NZA_TLS" -eq 0 ] || DASH_NZ_ARGV+=(--tls)
}

dash_nzs_access_preview() { # width
  local fl list="" s h
  dash_nzsa_check
  dash_nzsa_base
  [ -n "$DASH_NZA_BASE" ] && [ "$DASH_NZA_OKD" -eq 1 ] || return 0
  dash_nzsa_flavors
  for fl in "${DASH_NZA_FLS[@]}"; do dash_nzsa_file "$fl"; list+="${list:+ }$DASH_NZA_FILE"; done
  DASH_NZ_P+=("  proxy/ ${TH[dim]:-}$list${TH_RESET}")
  for s in "${DASH_NZ_SL[@]}"; do
    h="${DASH_NZA_HOST[$s]:-${CAT_NAME[$s]:-$s}.$DASH_NZA_BASE}"
    DASH_NZ_P+=("    ${TH[dim]:-}$s →${TH_RESET} $h")
  done
}

# --- Drawing --------------------------------------------------------------------------------------------------------------------------

dash_nzs_access_render() { # width height
  local iw="$1" ih="$2" l dim="${TH[dim]:-}" r="$TH_RESET" acc="${TH[accent]:-}" st label ip="" id room k n shown="" fl ph pad tight=0 i s h line
  DASH_NZ_B=()
  # On a short screen the blank lines and the explanation go: what is asked and the block matter more.
  [ "$ih" -ge 20 ] || tight=1
  if [ "$tight" -eq 0 ]; then
    DASH_NZ_B+=("")
    t_r tui.nz.help.access; dash_wrap "$T_OUT" "$iw"
    for l in "${DASH_WRAP[@]}"; do DASH_NZ_B+=("$dim$l$r"); done
    DASH_NZ_B+=("")
  fi
  dash_nzsa_rows
  dash_nzsa_check
  dash_nzsa_base
  # 1. the base domain (a field)
  if [ -z "$DASH_NZA_DOMAIN" ]; then st=pend; elif proxy_host_ok "${DASH_NZA_DOMAIN,,}"; then st=ok; else st=err; fi
  t_r tui.nz.acc.placeholder; ph="$T_OUT"
  t_r tui.nz.acc.domain
  kit_field_render "$T_OUT" "$DASH_NZA_DOMAIN" "$KF_CUR" "$iw" label_width=10 focus=$((DASH_NZA_FOCUS == 0 && DASH_NZA_EDIT == 0 ? 1 : 0)) "state=$st" "placeholder=$ph"
  DASH_NZ_B+=("$KIT_OUT")
  # 2. one row for each service: its name (the one typed, or the one the base domain gives it)
  for i in "${!DASH_NZ_SL[@]}"; do
    s="${DASH_NZ_SL[$i]}"
    t_r tui.nz.acc.name "$s"; printf -v label '%-10s' "$T_OUT"
    if [ -n "${DASH_NZA_HOST[$s]:-}" ]; then h="$acc${DASH_NZA_HOST[$s]}$r"
    elif [ -n "$DASH_NZA_BASE" ] && [ "$DASH_NZA_OKD" -eq 1 ]; then h="$dim${CAT_NAME[$s]:-$s}.$DASH_NZA_BASE$r"
    else t_r tui.nz.acc.name_none; h="$dim$T_OUT$r"; fi
    line="$label$h"
    if [ "$DASH_NZA_FOCUS" -eq $((i + 1)) ] && [ "$DASH_NZA_EDIT" -eq 0 ]; then tui_fit "$TUI_SEL$C_BLD$label$r$h" "$iw"; DASH_NZ_B+=("$TUI_OUT")
    else tui_fit "$dim$label$r$h" "$iw"; DASH_NZ_B+=("$TUI_OUT"); fi
  done
  # 3. the proxy
  t_r tui.nz.acc.proxy; printf -v pad '%-10s' "$T_OUT"; label="$pad"
  for k in nginx caddy both; do
    t_r "tui.nz.acc.fl_$k"
    if [ "$DASH_NZA_FLAVOR" = "$k" ]; then shown+="$acc$UI_S_SEL ($T_OUT)$r  "; else shown+="${dim}( $T_OUT)$r  "; fi
  done
  if [ "$DASH_NZA_FOCUS" -eq "$DASH_NZA_FP" ]; then tui_fit "$TUI_SEL$C_BLD$label$r$shown" "$iw"; DASH_NZ_B+=("$TUI_OUT")
  else tui_fit "$dim$label$r$shown" "$iw"; DASH_NZ_B+=("$TUI_OUT"); fi
  # 4. HTTPS
  t_r tui.nz.acc.tls; printf -v pad '%-10s' "$T_OUT"; label="$pad"
  if [ "$DASH_NZA_TLS" -eq 1 ]; then shown="${acc}[x]${r}"; else shown="${dim}[ ]${r}"; fi
  if [ "$DASH_NZA_FOCUS" -eq "$DASH_NZA_FT" ]; then tui_fit "$TUI_SEL$C_BLD$label$r$shown" "$iw"; DASH_NZ_B+=("$TUI_OUT")
  else tui_fit "$dim$label$r$shown" "$iw"; DASH_NZ_B+=("$TUI_OUT"); fi
  [ "$tight" -eq 1 ] || DASH_NZ_B+=("")
  # what was detected, and the server's address when the variables step has it
  if [ -n "$DASH_NZA_DET" ]; then kit_state_icon ok; t_r tui.nz.acc.detected "$DASH_NZA_DET"; else kit_state_icon info; t_r tui.nz.acc.none_detected; fi
  dash_wrap "$T_OUT" $((iw - 2))
  DASH_NZ_B+=("$KIT_ICON $dim${DASH_WRAP[0]}$r")
  for l in "${DASH_WRAP[@]:1}"; do DASH_NZ_B+=("  $dim$l$r"); done
  if [ "${DASH_NZV_BUILT:-0}" -eq 1 ]; then
    id=".env.s0|IP_SERVER"; ip="${KEE_VAL[$id]:-}"
    if [ -n "$ip" ]; then t_r tui.nz.acc.ip "$ip"; tui_fit "  $dim$T_OUT$r" "$iw"; DASH_NZ_B+=("$TUI_OUT"); fi
  fi
  # the block
  if [ "$DASH_NZA_OKD" -eq 0 ]; then
    DASH_NZ_B+=("")
    kit_state_icon err; dash_wrap "$DASH_NZA_WHY" $((iw - 2))
    DASH_NZ_B+=("$KIT_ICON ${TH[err]:-}${DASH_WRAP[0]}$r")
    for l in "${DASH_WRAP[@]:1}"; do DASH_NZ_B+=("  ${TH[err]:-}$l$r"); done
  elif [ -z "$DASH_NZA_BASE" ]; then
    [ "$tight" -eq 1 ] || DASH_NZ_B+=("")
    t_r tui.nz.acc.nodomain; dash_wrap "$T_OUT" "$iw"
    for l in "${DASH_WRAP[@]}"; do DASH_NZ_B+=("$dim$l$r"); done
  else
    dash_nzsa_build
    dash_nzsa_flavors
    fl="${DASH_NZA_FLS[$((DASH_NZA_VIEW % ${#DASH_NZA_FLS[@]}))]}"
    dash_nzsa_file "$fl"
    [ "$tight" -eq 1 ] || DASH_NZ_B+=("")
    t_r tui.nz.acc.block "$fl" "$DASH_NZ_NAME" "$DASH_NZA_FILE"
    tui_fit "$acc$C_BLD$T_OUT$r" "$iw"; DASH_NZ_B+=("$TUI_OUT")
    room=$((ih - ${#DASH_NZ_B[@]} - 1))
    n="${#DASH_NZA_BLOCK[@]}"
    for ((k = 0; k < n && k < room; k++)); do tui_fit "$dim${DASH_NZA_BLOCK[$k]}$r" "$iw"; DASH_NZ_B+=("$TUI_OUT"); done
    if [ "$n" -gt "$room" ] && [ "$room" -ge 1 ]; then
      t_r tui.nz.acc.more "$((n - room))"; DASH_NZ_B[${#DASH_NZ_B[@]} - 1]="$dim$T_OUT$r"
    fi
  fi
  dash_nzsa_overlay "$iw"
}

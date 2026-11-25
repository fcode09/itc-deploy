#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # DASH_NZ_* belong to lib/screens/newinst.sh
# Step 7 of the new-instance wizard: the access. With what name is the instance reached from the internet? With a domain, `new` prepares the block
# of the reverse proxy of each service (<name of the service>.<domain> to the port of the instance): nginx, Caddy or both, with HTTPS or not.
# THE BLOCK IS TEXT (lib/core/proxy.sh): it is shown here, can be copied (c), and `new` saves it inside the instance (instances/<name>/proxy/).
# Nothing is written under /etc and nothing is reloaded or installed, ever: the person puts it where their proxy reads it. The domain is
# optional; without one nothing is generated (the access tab of the instance will do it later).
#
# The focus moves with ↑↓ through three rows: the domain (a text field), the proxy (←→ or Space change it) and HTTPS (Space). `c` copies the
# block shown, `v` shows the other one when both are chosen. Enter goes on to the review, which is where the instance is created.

DASH_NZA_DOMAIN="" DASH_NZA_FLAVOR="" DASH_NZA_TLS=1 DASH_NZA_FOCUS=0 DASH_NZA_VIEW=0 DASH_NZA_DET=""
DASH_NZA_OKD=0                      # 1 when the domain is valid (or empty)
DASH_NZA_BLOCK=() DASH_NZA_BSIG="" DASH_NZA_BTEXT="" DASH_NZA_BERR=""

dash_nzs_access_reset() {
  DASH_NZA_DOMAIN="" DASH_NZA_FLAVOR="" DASH_NZA_TLS=1 DASH_NZA_FOCUS=0 DASH_NZA_VIEW=0 DASH_NZA_DET=""
  DASH_NZA_BLOCK=() DASH_NZA_BSIG="" DASH_NZA_BTEXT="" DASH_NZA_BERR=""
}

dash_nzs_access_enter() {
  DASH_NZA_DET="$(proxy_detect)"
  # The proxy that is on this server is the one proposed; with none, both are generated (they are only text).
  [ -n "$DASH_NZA_FLAVOR" ] || { if [ -n "$DASH_NZA_DET" ]; then DASH_NZA_FLAVOR="$DASH_NZA_DET"; else DASH_NZA_FLAVOR=both; fi; }
  KF_VALUE="$DASH_NZA_DOMAIN" KF_CUR="${#DASH_NZA_DOMAIN}"
}

dash_nzs_access_typing() { [ "$DASH_NZA_FOCUS" -eq 0 ]; }

# The state of the domain: empty (nothing is generated), a valid one or one that is not.
dash_nzsa_check() {
  local d="${DASH_NZA_DOMAIN,,}"
  if [ -z "$d" ]; then DASH_NZA_OKD=1; return 0; fi
  if proxy_host_ok "$d"; then DASH_NZA_OKD=1; else DASH_NZA_OKD=0; fi
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

dash_nzs_access_key() { # key
  local k="$1" f
  case "$k" in
    up | down)
      # (inside the text field up/down only move the focus)
      if [ "$k" = up ]; then [ "$DASH_NZA_FOCUS" -le 0 ] || DASH_NZA_FOCUS=$((DASH_NZA_FOCUS - 1))
      else [ "$DASH_NZA_FOCUS" -ge 2 ] || DASH_NZA_FOCUS=$((DASH_NZA_FOCUS + 1)); fi
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
  case "$k" in
    c)
      dash_nzsa_build
      if [ -z "$DASH_NZA_BTEXT" ]; then t_r tui.nz.acc.nothing_copy; DASH_NZ_ERR="$T_OUT"; return 0; fi
      if dash_srv_copy "$DASH_NZA_BTEXT"; then dash_msg ok "$(t tui.nz.acc.copied)"; else dash_msg warn "$(t tui.nz.acc.copy_fail)"; fi
      ;;
    v) DASH_NZA_VIEW=$((1 - DASH_NZA_VIEW)) DASH_NZA_BSIG="" ;;
    left | right | space | h | l)
      if [ "$DASH_NZA_FOCUS" -eq 1 ]; then
        case "$DASH_NZA_FLAVOR:$k" in
          nginx:right | nginx:space | nginx:l) f=caddy ;;
          caddy:right | caddy:space | caddy:l) f=both ;;
          both:right | both:space | both:l) f=nginx ;;
          nginx:left | nginx:h) f=both ;;
          caddy:left | caddy:h) f=nginx ;;
          *) f=caddy ;;
        esac
        DASH_NZA_FLAVOR="$f" DASH_NZA_VIEW=0 DASH_NZA_BSIG=""
      else
        DASH_NZA_TLS=$((1 - DASH_NZA_TLS)) DASH_NZA_BSIG=""
      fi
      ;;
    x) [ "$DASH_NZA_FOCUS" -ne 2 ] || { DASH_NZA_TLS=$((1 - DASH_NZA_TLS)); DASH_NZA_BSIG=""; } ;;
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
  sig="$DASH_NZA_DOMAIN|$DASH_NZA_FLAVOR|$DASH_NZA_TLS|$DASH_NZA_VIEW|$DASH_NZ_CSV"
  for s in "${DASH_NZ_SL[@]}"; do sig+="|${DASH_NZ_PORT[$s]:-}"; done
  [ "$sig" != "$DASH_NZA_BSIG" ] || return 0
  DASH_NZA_BSIG="$sig" DASH_NZA_BTEXT="" DASH_NZA_BLOCK=() DASH_NZA_BERR=""
  [ -n "$DASH_NZA_DOMAIN" ] && [ "$DASH_NZA_OKD" -eq 1 ] || return 0
  PROXY_PORTS=()
  for s in "${DASH_NZ_SL[@]}"; do PROXY_PORTS[$s]="${DASH_NZ_PORT[$s]:-}"; done
  proxy_domain_names "$DASH_NZA_DOMAIN" "${DASH_NZ_SL[@]}" || return 0
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
  if [ -z "$DASH_NZA_DOMAIN" ]; then DASH_NZ_ST=ok; t_r tui.nz.acc.v_none; DASH_NZ_VAL="$T_OUT"
  elif [ "$DASH_NZA_OKD" -eq 1 ]; then DASH_NZ_ST=ok DASH_NZ_VAL="${DASH_NZA_DOMAIN,,}"
  else DASH_NZ_ST=err DASH_NZ_VAL="$DASH_NZA_DOMAIN"; fi
}

dash_nzs_access_gate() {
  dash_nzsa_check
  [ "$DASH_NZA_OKD" -eq 1 ] && return 0
  t_r tui.nz.acc.invalid "$DASH_NZA_DOMAIN"; DASH_NZ_ERR="$T_OUT"
  return 1
}

dash_nzs_access_sig() { DASH_NZ_AS+="|acc:$DASH_NZA_DOMAIN:$DASH_NZA_FLAVOR:$DASH_NZA_TLS"; }

dash_nzs_access_args() {
  dash_nzsa_check
  [ -n "$DASH_NZA_DOMAIN" ] && [ "$DASH_NZA_OKD" -eq 1 ] || return 0
  DASH_NZ_ARGV+=(--domain "${DASH_NZA_DOMAIN,,}")
  [ "${DASH_NZA_FLAVOR:-both}" = both ] || DASH_NZ_ARGV+=(--proxy "$DASH_NZA_FLAVOR")
  [ "$DASH_NZA_TLS" -eq 0 ] || DASH_NZ_ARGV+=(--tls)
}

dash_nzs_access_preview() { # width
  local fl list=""
  dash_nzsa_check
  [ -n "$DASH_NZA_DOMAIN" ] && [ "$DASH_NZA_OKD" -eq 1 ] || return 0
  dash_nzsa_flavors
  for fl in "${DASH_NZA_FLS[@]}"; do dash_nzsa_file "$fl"; list+="${list:+ }$DASH_NZA_FILE"; done
  DASH_NZ_P+=("  proxy/ ${TH[dim]:-}$list${TH_RESET}")
}

# --- Drawing --------------------------------------------------------------------------------------------------------------------------

dash_nzs_access_render() { # width height
  local iw="$1" ih="$2" l dim="${TH[dim]:-}" r="$TH_RESET" acc="${TH[accent]:-}" st label ip="" id room k n shown="" fl ph pad tight=0
  DASH_NZ_B=()
  # On a short screen the blank lines and the explanation go: what is asked and the block matter more.
  [ "$ih" -ge 20 ] || tight=1
  if [ "$tight" -eq 0 ]; then
    DASH_NZ_B+=("")
    t_r tui.nz.help.access; dash_wrap "$T_OUT" "$iw"
    for l in "${DASH_WRAP[@]}"; do DASH_NZ_B+=("$dim$l$r"); done
    DASH_NZ_B+=("")
  fi
  dash_nzsa_check
  # 1. the domain (a field)
  if [ -z "$DASH_NZA_DOMAIN" ]; then st=pend; elif [ "$DASH_NZA_OKD" -eq 1 ]; then st=ok; else st=err; fi
  t_r tui.nz.acc.placeholder; ph="$T_OUT"
  t_r tui.nz.acc.domain
  kit_field_render "$T_OUT" "$DASH_NZA_DOMAIN" "$KF_CUR" "$iw" label_width=10 focus=$((DASH_NZA_FOCUS == 0 ? 1 : 0)) "state=$st" "placeholder=$ph"
  DASH_NZ_B+=("$KIT_OUT")
  # 2. the proxy
  t_r tui.nz.acc.proxy; printf -v pad '%-10s' "$T_OUT"; label="$pad"
  for k in nginx caddy both; do
    t_r "tui.nz.acc.fl_$k"
    if [ "$DASH_NZA_FLAVOR" = "$k" ]; then shown+="$acc$UI_S_SEL ($T_OUT)$r  "; else shown+="${dim}( $T_OUT)$r  "; fi
  done
  if [ "$DASH_NZA_FOCUS" -eq 1 ]; then tui_fit "$TUI_SEL$C_BLD$label$r$shown" "$iw"; DASH_NZ_B+=("$TUI_OUT")
  else tui_fit "$dim$label$r$shown" "$iw"; DASH_NZ_B+=("$TUI_OUT"); fi
  # 3. HTTPS
  t_r tui.nz.acc.tls; printf -v pad '%-10s' "$T_OUT"; label="$pad"
  if [ "$DASH_NZA_TLS" -eq 1 ]; then shown="${acc}[x]${r}"; else shown="${dim}[ ]${r}"; fi
  if [ "$DASH_NZA_FOCUS" -eq 2 ]; then tui_fit "$TUI_SEL$C_BLD$label$r$shown" "$iw"; DASH_NZ_B+=("$TUI_OUT")
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
  if [ -z "$DASH_NZA_DOMAIN" ]; then
    [ "$tight" -eq 1 ] || DASH_NZ_B+=("")
    t_r tui.nz.acc.nodomain; dash_wrap "$T_OUT" "$iw"
    for l in "${DASH_WRAP[@]}"; do DASH_NZ_B+=("$dim$l$r"); done
  elif [ "$DASH_NZA_OKD" -eq 0 ]; then
    DASH_NZ_B+=("")
    kit_state_icon err; t_r tui.nz.acc.invalid "$DASH_NZA_DOMAIN"; dash_wrap "$T_OUT" $((iw - 2))
    DASH_NZ_B+=("$KIT_ICON ${TH[err]:-}${DASH_WRAP[0]}$r")
    for l in "${DASH_WRAP[@]:1}"; do DASH_NZ_B+=("  ${TH[err]:-}$l$r"); done
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
}

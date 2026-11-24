#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # DASH_NZ_* belong to lib/screens/newinst.sh
# Step 2 of the new-instance wizard: the services. One card per service of the catalog (lib/core/catalog.data: so a service added there
# appears here with no change): what it is, the port it would get on the host (and whether something already holds it), its memory limit
# and what it depends on. Space marks and unmarks; Enter goes on with what is marked (both services at the start). At least one is needed.
# A service that uses another one (s1 asks s0 to validate its users) warns when that other one is not in the instance: it is allowed (the
# dependency is soft), but the person is told what will not work.

DASH_NZ_SC=0   # the card with the cursor (an index into KNOWN_SERVICES)

dash_nzs_services_enter() { DASH_NZ_SC=0; }

dash_nzs_services_key() { # key
  local k="$1" n="${#KNOWN_SERVICES[@]}" s
  s="${KNOWN_SERVICES[$DASH_NZ_SC]:-}"
  case "$k" in
    up | k) [ "$DASH_NZ_SC" -le 0 ] || DASH_NZ_SC=$((DASH_NZ_SC - 1)); DASH_NZ_ERR="" ;;
    down | j) [ "$DASH_NZ_SC" -ge $((n - 1)) ] || DASH_NZ_SC=$((DASH_NZ_SC + 1)); DASH_NZ_ERR="" ;;
    space | x) [ -z "$s" ] || DASH_NZ_SEL["$s"]=$((1 - ${DASH_NZ_SEL[$s]:-0})); DASH_NZ_ERR="" ;;
    a) for s in "${KNOWN_SERVICES[@]}"; do DASH_NZ_SEL["$s"]=1; done; DASH_NZ_ERR="" ;;
    *) return 1 ;;
  esac
  return 0
}

dash_nzs_services_state() {
  dash_nz_sel_list
  if [ -z "$DASH_NZ_CSV" ]; then DASH_NZ_ST=err; t_r tui.nz.svc.v_none; DASH_NZ_VAL="$T_OUT"
  else DASH_NZ_ST=ok DASH_NZ_VAL="${DASH_NZ_CSV//,/ }"; fi
}

dash_nzs_services_gate() {
  dash_nz_sel_list
  [ -n "$DASH_NZ_CSV" ] || { t_r tui.nz.svc.none; DASH_NZ_ERR="$T_OUT"; return 1; }
  return 0
}

# The services the one given depends on that are not in the instance, into DASH_NZ_T (names separated by a space).
dash_nz_svc_missing() { # service
  local d
  DASH_NZ_T=""
  for d in ${CAT_DEPENDS[$1]:-}; do
    [ "${DASH_NZ_SEL[$d]:-0}" -eq 1 ] || DASH_NZ_T+="${DASH_NZ_T:+ }$d"
  done
}

dash_nzs_services_render() { # width height
  local iw="$1" s i mark box row acc="${TH[accent]:-}" dim="${TH[dim]:-}" r="$TH_RESET" l d txt ports
  DASH_NZ_B=("")
  t_r tui.nz.help.services; dash_wrap "$T_OUT" "$iw"
  for l in "${DASH_WRAP[@]}"; do DASH_NZ_B+=("$dim$l$r"); done
  DASH_NZ_B+=("")
  for i in "${!KNOWN_SERVICES[@]}"; do
    s="${KNOWN_SERVICES[$i]}"
    if [ "$i" -eq "$DASH_NZ_SC" ]; then mark="$acc$UI_S_SEL$r"; else mark=" "; fi
    if [ "${DASH_NZ_SEL[$s]:-0}" -eq 1 ]; then box="${acc}[x]$r"; else box="[ ]"; fi
    # the line of the card: the mark, the box, the service and its image at the left; the port and the memory at the right
    row="$mark $box $C_BLD$s$r $UI_S_DOT ${CAT_NAME[$s]}"
    if [ "${DASH_NZ_PBUSY[$s]:-0}" -eq 1 ]; then kit_state_icon warn; t_r tui.nz.svc.port_busy "${DASH_NZ_PORT[$s]:-}"; ports="$KIT_ICON ${TH[warn]:-}$T_OUT$r"
    else kit_state_icon ok; t_r tui.nz.svc.port_ok "${DASH_NZ_PORT[$s]:-}"; ports="$KIT_ICON $dim$T_OUT$r"; fi
    txt="$ports  $dim${CAT_MEM[$s]:-}$r"
    tui_vlen "$row"; l="$TUI_VL"
    tui_vlen "$txt"
    if [ $((l + 2 + TUI_VL)) -le "$iw" ]; then printf -v d '%*s' $((iw - l - TUI_VL)) ''; row+="$d$txt"; fi
    if [ "$i" -eq "$DASH_NZ_SC" ]; then DASH_NZ_B+=("$TUI_SEL$row"); else DASH_NZ_B+=("$row"); fi
    # (the catalog writes "(NestJS): what it does" or "(NestJS + Chromium ...)": the description is what follows, or what is inside)
    t_r "catalog.desc.$s"; txt="$T_OUT"
    case "$txt" in
      "("*"): "*) txt="${txt#*): }" ;;
      "("*")") txt="${txt:1:${#txt}-2}" ;;
    esac
    tui_fit "      $dim$txt$r" "$iw"; DASH_NZ_B+=("$TUI_OUT")
    # what it depends on, and a warning when that is not in the instance
    dash_nz_svc_missing "$s"
    if [ "${DASH_NZ_SEL[$s]:-0}" -eq 1 ] && [ -n "$DASH_NZ_T" ]; then
      kit_state_icon warn; t_r tui.nz.svc.dep_missing "$s" "$DASH_NZ_T"
      tui_fit "    $KIT_ICON ${TH[warn]:-}$T_OUT$r" "$iw"; DASH_NZ_B+=("$TUI_OUT")
    elif [ -n "${CAT_DEPENDS[$s]:-}" ]; then
      t_r tui.nz.svc.dep "${CAT_DEPENDS[$s]}"; tui_fit "      $dim$T_OUT$r" "$iw"; DASH_NZ_B+=("$TUI_OUT")
    fi
    DASH_NZ_B+=("")
  done
  dash_nz_sel_list
  if [ -z "$DASH_NZ_CSV" ]; then
    kit_state_icon err; t_r tui.nz.svc.none; DASH_NZ_B+=("$KIT_ICON ${TH[err]:-}$T_OUT$r")
  fi
}

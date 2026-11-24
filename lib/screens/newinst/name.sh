#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # DASH_NZ_* belong to lib/screens/newinst.sh
# Step 1 of the new-instance wizard: the name. It is the name of the folder (instances/<name>) and of the Compose project, so it must be a
# valid name AND free: not a folder, not a project that still has containers in Docker, not a network called <name>_default. The check runs
# at every key typed and costs nothing (lib/core/instname.sh compares with what it read once when the wizard opened).
# The name is proposed (instancia-N, the first free one) and the first key typed replaces it; Enter accepts it.

DASH_NZ_FRESH=0   # 1 while the value is still the proposed one

# The state of the name into DASH_NZ_NS: ok | empty | bad | folder | project | network.
DASH_NZ_NS=""
dash_nz_name_state() {
  local n="$DASH_NZ_NAME"
  n="${n#"${n%%[![:space:]]*}"}"
  n="${n%"${n##*[![:space:]]}"}"
  if [ -z "$n" ]; then DASH_NZ_NS=empty
  elif ! valid_instance_name "$n"; then DASH_NZ_NS=bad
  elif inst_name_clash "$n"; then DASH_NZ_NS=ok
  else DASH_NZ_NS="$INST_CLASH"; fi
}

dash_nzs_name_enter() {
  KF_VALUE="$DASH_NZ_NAME" KF_CUR="${#DASH_NZ_NAME}" DASH_NZ_FRESH=0
  if [ -n "$KF_VALUE" ] && [ "$KF_VALUE" = "$DASH_NZ_PROPOSED" ]; then DASH_NZ_FRESH=1; fi
}

dash_nzs_name_typing() { return 0; }

dash_nzs_name_key() { # key
  local k="$1"
  case "$k" in enter | esc | tab | btab | up | down | pgup | pgdn) return 1 ;; esac
  if [ "$DASH_NZ_FRESH" -eq 1 ]; then
    case "$k" in
      left | right | home | end) DASH_NZ_FRESH=0 ;;
      backspace | delete) KF_VALUE="" KF_CUR=0 DASH_NZ_FRESH=0; DASH_NZ_NAME=""; DASH_NZ_ERR=""; return 0 ;;
      *) if [ "$k" = space ] || { [ "${#k}" -eq 1 ] && [[ "$k" != [[:cntrl:]] ]]; }; then KF_VALUE="" KF_CUR=0 DASH_NZ_FRESH=0; fi ;;
    esac
  fi
  kit_field_key "$k" || return 1
  DASH_NZ_NAME="$KF_VALUE" DASH_NZ_ERR=""
  return 0
}

dash_nzs_name_state() {
  dash_nz_name_state
  case "$DASH_NZ_NS" in
    ok) DASH_NZ_ST=ok DASH_NZ_VAL="$DASH_NZ_NAME" ;;
    empty) DASH_NZ_ST=pend; t_r tui.nz.name.v_empty; DASH_NZ_VAL="$T_OUT" ;;
    *) DASH_NZ_ST=err DASH_NZ_VAL="$DASH_NZ_NAME" ;;
  esac
}

dash_nzs_name_gate() {
  dash_nz_name_state
  [ "$DASH_NZ_NS" != ok ] || return 0
  t_r "tui.nz.name.$DASH_NZ_NS" "$DASH_NZ_NAME"
  DASH_NZ_ERR="$T_OUT"
  return 1
}

dash_nzs_name_render() { # width height
  local iw="$1" st msg l
  DASH_NZ_B=("")
  t_r tui.nz.help.name; dash_wrap "$T_OUT" "$iw"
  for l in "${DASH_WRAP[@]}"; do DASH_NZ_B+=("${TH[dim]:-}$l$TH_RESET"); done
  DASH_NZ_B+=("")
  dash_nz_name_state
  case "$DASH_NZ_NS" in ok) st=ok ;; empty) st=pend ;; *) st=err ;; esac
  t_r tui.nz.name.label
  kit_field_render "$T_OUT" "$KF_VALUE" "$KF_CUR" "$iw" label_width=9 focus=1 "state=$st"
  DASH_NZ_B+=("$KIT_OUT")
  DASH_NZ_B+=("")
  # What the state means, in a sentence under the field.
  t_r "tui.nz.name.$DASH_NZ_NS" "$DASH_NZ_NAME"; msg="$T_OUT"
  dash_wrap "$msg" $((iw - 2))
  kit_state_icon "$st"
  DASH_NZ_B+=("$KIT_ICON ${DASH_WRAP[0]}")
  for l in "${DASH_WRAP[@]:1}"; do DASH_NZ_B+=("  $l"); done
  if [ "$DASH_NZ_NS" = ok ]; then
    DASH_NZ_B+=("")
    t_r tui.nz.name.where "instances/$DASH_NZ_NAME"; dash_wrap "$T_OUT" "$iw"
    for l in "${DASH_WRAP[@]}"; do DASH_NZ_B+=("${TH[dim]:-}$l$TH_RESET"); done
  fi
  if [ "$DASH_NZ_DOCKER" -eq 0 ]; then
    DASH_NZ_B+=("")
    kit_state_icon warn
    t_r tui.nz.name.nodocker; dash_wrap "$T_OUT" $((iw - 2))
    DASH_NZ_B+=("$KIT_ICON ${TH[warn]:-}${DASH_WRAP[0]}$TH_RESET")
    for l in "${DASH_WRAP[@]:1}"; do DASH_NZ_B+=("  ${TH[warn]:-}$l$TH_RESET"); done
  fi
  if [ "$DASH_NZ_FRESH" -eq 1 ]; then
    DASH_NZ_B+=("")
    t_r tui.nz.name.proposed; DASH_NZ_B+=("${TH[accent]:-}$T_OUT$TH_RESET")
  fi
}

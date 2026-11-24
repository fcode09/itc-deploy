#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # DASH_NZ_* belong to lib/screens/newinst.sh
# Step 4 of the new-instance wizard: the data. Is it a municipality that starts empty (the first `init` seeds its databases) or one that
# already has data (it comes from PM2 or another deployment: the instance is marked as existing, `init` will refuse to seed it, and it
# reuses its databases and secrets)? Each option says in a sentence what it does and what it cannot undo. New is the proposed one.

dash_nzs_data_enter() { :; }

dash_nzs_data_key() { # key
  case "$1" in
    up | k | left) DASH_NZ_DATA=0 DASH_NZ_ERR="" ;;
    down | j | right) DASH_NZ_DATA=1 DASH_NZ_ERR="" ;;
    space | x) DASH_NZ_DATA=$((1 - DASH_NZ_DATA)) DASH_NZ_ERR="" ;;
    n) DASH_NZ_DATA=0 DASH_NZ_ERR="" ;;
    e) DASH_NZ_DATA=1 DASH_NZ_ERR="" ;;
    *) return 1 ;;
  esac
  return 0
}

dash_nzs_data_state() {
  DASH_NZ_ST=ok
  if [ "$DASH_NZ_DATA" -eq 1 ]; then t_r tui.nz.data.v_existing; else t_r tui.nz.data.v_new; fi
  DASH_NZ_VAL="$T_OUT"
}

# One option: the radio, its title and what it means (wrapped under it).
dash_nz_data_option() { # value title-key note-key width
  local on=0 radio acc="${TH[accent]:-}" dim="${TH[dim]:-}" r="$TH_RESET" l
  [ "$DASH_NZ_DATA" -ne "$1" ] || on=1
  if [ "$on" -eq 1 ]; then radio="$acc$UI_S_SEL (o)$r"; else radio="  ( )"; fi
  t_r "$2"
  if [ "$on" -eq 1 ]; then DASH_NZ_B+=("$TUI_SEL$radio $C_BLD$T_OUT$r"); else DASH_NZ_B+=("$radio $C_BLD$T_OUT$r"); fi
  t_r "$3"; dash_wrap "$T_OUT" $(($4 - 7))
  for l in "${DASH_WRAP[@]}"; do DASH_NZ_B+=("       $dim$l$r"); done
}

dash_nzs_data_render() { # width height
  local iw="$1" l dim="${TH[dim]:-}" r="$TH_RESET"
  DASH_NZ_B=("")
  t_r tui.nz.help.data; dash_wrap "$T_OUT" "$iw"
  for l in "${DASH_WRAP[@]}"; do DASH_NZ_B+=("$dim$l$r"); done
  DASH_NZ_B+=("")
  dash_nz_data_option 0 tui.nz.data.new tui.nz.data.new_note "$iw"
  DASH_NZ_B+=("")
  dash_nz_data_option 1 tui.nz.data.existing tui.nz.data.existing_note "$iw"
  if [ "$DASH_NZ_DATA" -eq 1 ]; then
    DASH_NZ_B+=("")
    kit_state_icon warn; t_r tui.nz.data.warn; dash_wrap "$T_OUT" $((iw - 2))
    DASH_NZ_B+=("$KIT_ICON ${TH[warn]:-}${DASH_WRAP[0]}$r")
    for l in "${DASH_WRAP[@]:1}"; do DASH_NZ_B+=("  ${TH[warn]:-}$l$r"); done
  fi
}

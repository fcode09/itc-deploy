#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # DASH_NZ_* belong to lib/screens/newinst.sh
# Step 3 of the new-instance wizard: the version of each service. The version picker of the kit (kit_vpick) shows the versions of the image
# loaded in this Docker, newest first, with the most recent one starred; the star is already chosen when the step opens, so Enter alone
# takes it. Only the service with the cursor shows its table; the others are one line with their choice. Up and Down walk the rows and,
# past the first or the last one, go to the previous or next service; Enter chooses the row and goes to the next service (after the last
# one, to the next step). "write another version" types a tag; one that is not loaded can be written now and loaded before deploying.
# A version for another architecture cannot be chosen: the picker says why. R reads Docker again.
# The images are the default ones of the catalog: a different image name is a variable of the instance (the variables step).

DASH_NZ_VS=""                  # the service with the cursor
DASH_NZ_TYPING=0               # 1 while a tag is being typed (the row "write another version")
declare -gA DASH_NZ_ROW=() DASH_NZ_TOP=()

# The row of the table of $1 that holds the tag $2 (the one chosen), or the row to start on, into DASH_NZ_T.
dash_nz_ver_row() { # service tag
  local s="$1" i
  kit_vpick_select "DASH_NZ_REC_$s" "" other=1 load=0
  DASH_NZ_T="$KVP_DEFAULT"
  [ -n "$2" ] || return 0
  for ((i = 0; i < KVP_NV; i++)); do
    kit_vpick_pick "DASH_NZ_REC_$s" "$i" "$DASH_NZ_ARCH"
    if [ "$KVP_TAG" = "$2" ]; then DASH_NZ_T="$i"; return 0; fi
  done
}

# The star is chosen for every service that has none; the cursor goes to the chosen version.
dash_nzs_versions_enter() {
  local s
  DASH_NZ_TYPING=0
  dash_nz_sel_list
  DASH_NZ_VS="${DASH_NZ_SL[0]:-}"
  for s in "${DASH_NZ_SL[@]}"; do
    dash_nz_ver_row "$s" "${DASH_NZ_TAG[$s]:-}"
    DASH_NZ_ROW["$s"]="$DASH_NZ_T" DASH_NZ_TOP["$s"]=0
    if [ -z "${DASH_NZ_TAG[$s]:-}" ]; then
      kit_vpick_pick "DASH_NZ_REC_$s" "$DASH_NZ_T" "$DASH_NZ_ARCH"
      if [ "$KVP_KIND" = version ] && [ "$KVP_OK" -eq 1 ]; then DASH_NZ_TAG["$s"]="$KVP_TAG"; fi
    fi
  done
}

dash_nzs_versions_typing() { [ "$DASH_NZ_TYPING" -eq 1 ]; }

# The position of the service $1 among the selected ones, into DASH_NZ_T (-1 when it is not there).
dash_nz_ver_pos() { # service
  local i
  DASH_NZ_T=-1
  for i in "${!DASH_NZ_SL[@]}"; do [ "${DASH_NZ_SL[$i]}" != "$1" ] || { DASH_NZ_T="$i"; return 0; }; done
}

# The cursor to the service at position $1 of the selected ones, on its row $2 (-1: the first).
dash_nz_ver_move() { # position row
  local s="${DASH_NZ_SL[$1]:-}"
  [ -n "$s" ] || return 0
  DASH_NZ_VS="$s"
  kit_vpick_select "DASH_NZ_REC_$s" "" other=1 load=0
  if [ "$2" -lt 0 ]; then DASH_NZ_ROW["$s"]="${DASH_NZ_ROW[$s]:-0}"; else DASH_NZ_ROW["$s"]="$2"; fi
}

# Chooses the row under the cursor of the service with it. 0 when it was chosen (and the cursor moved on or the step may end).
dash_nz_ver_choose() {
  local s="$DASH_NZ_VS" pos
  kit_vpick_select "DASH_NZ_REC_$s" "" other=1 load=0
  kit_vpick_pick "DASH_NZ_REC_$s" "${DASH_NZ_ROW[$s]:-0}" "$DASH_NZ_ARCH"
  case "$KVP_KIND" in
    version)
      if [ "$KVP_OK" -ne 1 ]; then DASH_NZ_ERR="$KVP_WHY"; return 1; fi
      DASH_NZ_TAG["$s"]="$KVP_TAG" DASH_NZ_ERR=""
      ;;
    other)
      DASH_NZ_TYPING=1 KF_VALUE="" KF_CUR=0 DASH_NZ_ERR=""
      return 1
      ;;
    *) return 1 ;;
  esac
  dash_nz_ver_pos "$s"; pos="$DASH_NZ_T"
  if [ "$pos" -ge 0 ] && [ "$pos" -lt $((${#DASH_NZ_SL[@]} - 1)) ]; then
    dash_nz_ver_move $((pos + 1)) -1
    return 1
  fi
  return 0
}

dash_nzs_versions_key() { # key
  local k="$1" s="$DASH_NZ_VS" pos row
  [ -n "$s" ] || return 1
  if [ "$DASH_NZ_TYPING" -eq 1 ]; then
    case "$k" in
      esc) DASH_NZ_TYPING=0 DASH_NZ_ERR=""; return 0 ;;
      enter)
        kit_vpick_typed "DASH_NZ_REC_$s" "$KF_VALUE"
        case "$KVP_TYPED_STATE" in
          ok | warn)
            DASH_NZ_TAG["$s"]="$KF_VALUE" DASH_NZ_TYPING=0 DASH_NZ_ERR=""
            dash_nz_ver_pos "$s"; pos="$DASH_NZ_T"
            if [ "$pos" -ge 0 ] && [ "$pos" -lt $((${#DASH_NZ_SL[@]} - 1)) ]; then dash_nz_ver_move $((pos + 1)) -1; return 0; fi
            return 1   # (the last service: Enter goes on to the next step)
            ;;
          *) t_r tui.nz.ver.typed_bad; DASH_NZ_ERR="$T_OUT" ;;
        esac
        return 0
        ;;
    esac
    kit_field_key "$k" || true
    return 0
  fi
  dash_nz_ver_pos "$s"; pos="$DASH_NZ_T"
  kit_vpick_select "DASH_NZ_REC_$s" "" other=1 load=0
  row="${DASH_NZ_ROW[$s]:-0}"
  case "$k" in
    up | k)
      DASH_NZ_ERR=""
      if [ "$row" -gt 0 ]; then DASH_NZ_ROW["$s"]=$((row - 1))
      elif [ "$pos" -gt 0 ]; then dash_nz_ver_move $((pos - 1)) -1; fi
      ;;
    down | j)
      DASH_NZ_ERR=""
      if [ "$row" -lt $((KVP_N - 1)) ]; then DASH_NZ_ROW["$s"]=$((row + 1))
      elif [ "$pos" -ge 0 ] && [ "$pos" -lt $((${#DASH_NZ_SL[@]} - 1)) ]; then dash_nz_ver_move $((pos + 1)) -1; fi
      ;;
    home) DASH_NZ_ROW["$s"]=0 ;;
    end) DASH_NZ_ROW["$s"]=$((KVP_N - 1)) ;;
    R)
      dash_nz_images_load
      dash_nzs_versions_enter
      ;;
    enter)
      # Chooses the row; on the last service it is not consumed, so the engine goes on to the next step.
      if dash_nz_ver_choose; then return 1; fi
      return 0
      ;;
    *) return 1 ;;
  esac
  return 0
}

dash_nzs_versions_state() {
  local s chosen=0 total=0 first=""
  dash_nz_sel_list
  for s in "${DASH_NZ_SL[@]}"; do
    total=$((total + 1))
    if [ -n "${DASH_NZ_TAG[$s]:-}" ]; then chosen=$((chosen + 1)); first+="${first:+ }${DASH_NZ_TAG[$s]}"; fi
  done
  if [ "$total" -gt 0 ] && [ "$chosen" -eq "$total" ]; then DASH_NZ_ST=ok DASH_NZ_VAL="$first"
  else DASH_NZ_ST=warn; t_r tui.nz.ver.v_notag; DASH_NZ_VAL="$T_OUT"; fi
}

# The line of a service that does not have the cursor: its name and its choice.
dash_nz_ver_summary() { # service width
  local s="$1" tag="${DASH_NZ_TAG[$1]:-}" row acc="${TH[accent]:-}" dim="${TH[dim]:-}" r="$TH_RESET" star=""
  if [ -n "$tag" ]; then
    dash_nz_ver_row "$s" "$tag"
    [ "$DASH_NZ_T" -ne "$KVP_STAR" ] || star=" ${TH[ok]:-}$UI_S_STAR$r"
    kit_state_icon ok
    row="  $KIT_ICON $C_BLD$s$r $UI_S_DOT ${CAT_NAME[$s]}  $acc$tag$r$star"
  else
    kit_state_icon warn; t_r tui.nz.ver.v_notag
    row="  $KIT_ICON $C_BLD$s$r $UI_S_DOT ${CAT_NAME[$s]}  $dim$T_OUT$r"
  fi
  tui_fit "$row" "$2"
  DASH_NZ_T="$TUI_OUT"
}

dash_nzs_versions_render() { # width height
  local iw="$1" ih="$2" s sel pos l avail note acc="${TH[accent]:-}" dim="${TH[dim]:-}" r="$TH_RESET" i
  local -a before=() after=()
  DASH_NZ_B=("")
  t_r tui.nz.help.versions; dash_wrap "$T_OUT" "$iw"
  for l in "${DASH_WRAP[@]}"; do DASH_NZ_B+=("$dim$l$r"); done
  if [ "$DASH_NZ_DOCKER" -eq 0 ]; then
    # (what the picker would say about an empty table is "no versions loaded", which hides why: Docker does not answer)
    kit_state_icon warn; t_r tui.nz.ver.nodocker; dash_wrap "$T_OUT" $((iw - 2))
    DASH_NZ_B+=("$KIT_ICON ${TH[warn]:-}${DASH_WRAP[0]}$r")
    for l in "${DASH_WRAP[@]:1}"; do DASH_NZ_B+=("  ${TH[warn]:-}$l$r"); done
  fi
  DASH_NZ_B+=("")
  dash_nz_sel_list
  if [ "${#DASH_NZ_SL[@]}" -eq 0 ]; then
    kit_state_icon err; t_r tui.nz.svc.none; DASH_NZ_B+=("$KIT_ICON ${TH[err]:-}$T_OUT$r")
    return 0
  fi
  [ -n "$DASH_NZ_VS" ] && [[ " ${DASH_NZ_SL[*]} " == *" $DASH_NZ_VS "* ]] || DASH_NZ_VS="${DASH_NZ_SL[0]}"
  dash_nz_ver_pos "$DASH_NZ_VS"; pos="$DASH_NZ_T"
  for i in "${!DASH_NZ_SL[@]}"; do
    s="${DASH_NZ_SL[$i]}"
    [ "$s" != "$DASH_NZ_VS" ] || continue
    dash_nz_ver_summary "$s" "$iw"
    if [ "$i" -lt "$pos" ]; then before+=("$DASH_NZ_T"); else after+=("$DASH_NZ_T"); fi
  done
  for l in "${before[@]}"; do DASH_NZ_B+=("$l"); done
  s="$DASH_NZ_VS"
  # the heading of the service with the cursor and its table: the rows that are left once the other lines are placed
  t_r tui.nz.ver.image "$(default_repo "$s")"
  tui_fit "$acc$C_BLD$UI_S_SEL $s $UI_S_DOT ${CAT_NAME[$s]}$r  $dim$T_OUT$r" "$iw"; DASH_NZ_B+=("$TUI_OUT")
  avail=$((ih - ${#DASH_NZ_B[@]} - ${#after[@]}))
  note="${DASH_NZ_NOTE[$s]:-}"
  [ -z "$note" ] || avail=$((avail - 1))
  [ "$avail" -ge 3 ] || avail=3
  # (no taller than the table needs: its header, its rows and the line of the message)
  kit_vpick_select "DASH_NZ_REC_$s" "" other=1 load=0
  [ $((KVP_N + 2)) -ge "$avail" ] || avail=$((KVP_N + 2))
  sel="${DASH_NZ_ROW[$s]:-0}"
  kit_vpick $((iw - 2)) "$avail" "DASH_NZ_REC_$s" "sel=$sel" "top=${DASH_NZ_TOP[$s]:-0}" other=1 load=0 texts=DASH_NZ_TX "server_arch=$DASH_NZ_ARCH" \
    "typing=$DASH_NZ_TYPING" "typed=$KF_VALUE" "cursor=$KF_CUR"
  DASH_NZ_ROW["$s"]="$KVP_SEL" DASH_NZ_TOP["$s"]="$KVP_TOP"
  # (a line that starts with TUI_SEL is the selected row: the marker stays at its start, the indent goes after it)
  for l in "${KVP_LINES[@]}"; do
    if [[ "$l" == "$TUI_SEL"* ]]; then DASH_NZ_B+=("$TUI_SEL  ${l#"$TUI_SEL"}"); else DASH_NZ_B+=("  $l"); fi
  done
  if [ -n "$note" ]; then kit_state_icon warn; tui_fit "  $KIT_ICON ${TH[warn]:-}$note$r" "$iw"; DASH_NZ_B+=("$TUI_OUT"); fi
  for l in "${after[@]}"; do DASH_NZ_B+=("$l"); done
}

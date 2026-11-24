#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Mode: use a version of an image in an instance (from the Images view). Two steps in one dialog:
#   pick     which instance. Only the instances that have the service active are listed; the ones that cannot take this version say why
#            (it is the version they already use, or they use another image name for that service).
#   confirm  what will change: <SN>_TAG of the instance from the version it has to the chosen one. y writes the tag and deploys that service
#            (the previous version is kept for rollback by deploy); g only writes the tag (deploy later, from the instance); Esc cancels.
# Nothing is written before the answer, and deploy is a command like any other (it runs in the background, shows in Output and can be
# cancelled with x).

DASH_IU_STEP=pick        # pick | confirm
DASH_IU_SVC="" DASH_IU_REPO="" DASH_IU_TAG=""
DASH_IU_NAMES=()         # the instances that have the service active
DASH_IU_CUR=()           # the tag each one has now
DASH_IU_WHY=()           # "" when the version can be used there, else why not
DASH_IU_SEL=0

# Opens the dialog for the version under the cursor of the Images view (a message when it cannot be used anywhere).
dash_img_use() {
  local name svc repo tag cur sr f
  dash_img_cur || { dash_msg info "$(t tui.img.nothing)"; return 0; }
  if [ "${IC_OK[$DASH_IMG_CI]}" -eq 0 ]; then
    dash_msg warn "$(t images.pick.why_arch "${IC_ARCH[$DASH_IMG_CI]}" "$IC_SERVER_ARCH")"
    return 0
  fi
  svc="${DASH_IMG_G%%|*}" repo="${DASH_IMG_G#*|}" tag="${IC_TAG[$DASH_IMG_CI]}"
  DASH_IU_SVC="$svc" DASH_IU_REPO="$repo" DASH_IU_TAG="$tag"
  DASH_IU_NAMES=() DASH_IU_CUR=() DASH_IU_WHY=() DASH_IU_SEL=0
  for name in "${DASH_NAMES[@]}"; do
    case " ${DASH_SVCS[$name]:-} " in *" $svc "*) ;; *) continue ;; esac
    f="$INSTANCES_DIR/$name/.env.instance"
    get_var_r "$f" "$(tag_var "$svc")"; cur="$GV"
    service_repo_r "$svc" "$name"; sr="$SR"
    DASH_IU_NAMES+=("$name") DASH_IU_CUR+=("$cur")
    if [ "$sr" != "$repo" ]; then t_r tui.img.use.other_image "$sr"; DASH_IU_WHY+=("$T_OUT")
    elif [ "$cur" = "$tag" ]; then t_r tui.img.use.same; DASH_IU_WHY+=("$T_OUT")
    else DASH_IU_WHY+=(""); fi
  done
  if [ "${#DASH_IU_NAMES[@]}" -eq 0 ]; then dash_msg warn "$(t tui.img.use.none "$svc")"; return 0; fi
  # The cursor starts on the first instance that can take it.
  local i
  for i in "${!DASH_IU_NAMES[@]}"; do if [ -z "${DASH_IU_WHY[$i]}" ]; then DASH_IU_SEL="$i"; break; fi; done
  DASH_IU_STEP=pick
  DASH_MODE=imguse
}

# Writes the tag into the instance's .env.instance (set_var swaps the file in atomically). Returns 1 with a message when it cannot.
dash_iu_write() { # instance service tag
  local f="$INSTANCES_DIR/$1/.env.instance"
  if [ ! -w "$f" ] || ! set_var "$f" "$(tag_var "$2")" "$3"; then dash_msg err "$(t tui.img.use.write_failed "$f")"; return 1; fi
  DASH_IMG_STALE=1
  return 0
}

dash_key_imguse() { # key
  local n="${#DASH_IU_NAMES[@]}" name="${DASH_IU_NAMES[$DASH_IU_SEL]:-}"
  if [ "$DASH_IU_STEP" = "pick" ]; then
    case "$1" in
      up | k) [ "$DASH_IU_SEL" -le 0 ] || DASH_IU_SEL=$((DASH_IU_SEL - 1)) ;;
      down | j) [ "$DASH_IU_SEL" -ge $((n - 1)) ] || DASH_IU_SEL=$((DASH_IU_SEL + 1)) ;;
      enter)
        if [ -n "${DASH_IU_WHY[$DASH_IU_SEL]:-}" ]; then dash_msg warn "${DASH_IU_WHY[$DASH_IU_SEL]}"; else DASH_IU_STEP=confirm; fi
        ;;
      esc | q) DASH_MODE=normal; dash_msg info "$(t tui.msg.cancelled)" ;;
    esac
    return 0
  fi
  case "$1" in
    y | Y | s | S)
      DASH_MODE=normal
      dash_iu_write "$name" "$DASH_IU_SVC" "$DASH_IU_TAG" || return 0
      dash_start_job stay deploy "$name" "$DASH_IU_SVC"
      ;;
    g | G)
      DASH_MODE=normal
      dash_iu_write "$name" "$DASH_IU_SVC" "$DASH_IU_TAG" || return 0
      dash_msg ok "$(t tui.img.use.saved "$name" "$(tag_var "$DASH_IU_SVC")" "$DASH_IU_TAG")"
      ;;
    esc | q | n | N) DASH_MODE=normal; dash_msg info "$(t tui.msg.cancelled)" ;;
    left | backspace) DASH_IU_STEP=pick ;;
  esac
}

dash_dialog_imguse() { # body_height
  local l i ww=64 name cur sel mark why
  [ "$ww" -le $((TUI_COLS - 10)) ] || ww=$((TUI_COLS - 10))
  DASH_DLG=("")
  if [ "$DASH_IU_STEP" = "pick" ]; then
    t_r tui.img.use.pick "$DASH_IU_REPO:$DASH_IU_TAG" "$DASH_IU_SVC"; dash_wrap "$T_OUT" "$ww"
    for l in "${DASH_WRAP[@]}"; do DASH_DLG+=("  $l"); done
    DASH_DLG+=("")
    local nw=0
    for name in "${DASH_IU_NAMES[@]}"; do [ "${#name}" -le "$nw" ] || nw="${#name}"; done
    for i in "${!DASH_IU_NAMES[@]}"; do
      name="${DASH_IU_NAMES[$i]}" cur="${DASH_IU_CUR[$i]:-?}" why="${DASH_IU_WHY[$i]}"
      printf -v name '%-*s' "$nw" "$name"
      if [ "$i" -eq "$DASH_IU_SEL" ]; then mark="${TH[accent]:-}$UI_S_SEL$TH_RESET "; else mark="  "; fi
      if [ -n "$why" ]; then
        l="$mark${TH[dim]:-}$name  $UI_S_DOT $why$TH_RESET"
      else
        t_r tui.img.use.row "$cur" "$DASH_IU_TAG"
        l="$mark$C_BLD$name$TH_RESET  ${TH[dim]:-}$T_OUT$TH_RESET"
      fi
      if [ "$i" -eq "$DASH_IU_SEL" ]; then tui_fit "$l" "$ww"; l="$TUI_SEL$TUI_OUT"; fi
      DASH_DLG+=(" $l")
    done
    DASH_DLG+=("")
    t_r tui.img.use.title "$DASH_IU_TAG"
  else
    name="${DASH_IU_NAMES[$DASH_IU_SEL]}" cur="${DASH_IU_CUR[$DASH_IU_SEL]:-?}"
    t_r tui.img.use.confirm "$DASH_IU_SVC" "$name" "$cur" "$DASH_IU_TAG" "$(tag_var "$DASH_IU_SVC")"; dash_wrap "$T_OUT" "$ww"
    for l in "${DASH_WRAP[@]}"; do DASH_DLG+=("  $l"); done
    DASH_DLG+=("")
    t_r tui.img.use.deploy_warn "$DASH_IU_SVC" "$name"; dash_wrap "$T_OUT" "$ww"
    for l in "${DASH_WRAP[@]}"; do DASH_DLG+=("  ${TH[warn]:-$C_YEL}$l$C_OFF"); done
    DASH_DLG+=("")
    t_r tui.img.use.title "$DASH_IU_TAG"
  fi
  dash_dialog "$1" "$T_OUT" 50
}

# --- The contract of lib/screens/registry.sh --------------------------------------------------------------------
scr_imguse_render() { dash_dialog_imguse "$2"; } # width height
scr_imguse_key() { dash_key_imguse "$1"; }
scr_imguse_keys() { # width
  local k=tui.img.use.keys_pick
  [ "$DASH_IU_STEP" = "pick" ] || k=tui.img.use.keys_confirm
  if [ "$UI_UTF8" -ne 1 ] || [ "$UI_RICH" -ne 1 ]; then k+=.ascii; fi
  dt "$k"
  dash_keyfit "$DTV" "$1"; TUI_FRAME+=(" $C_GRY$DASH_KF$C_OFF")
}
scr_imguse_sig() { DASH_SIG+="|$DASH_IU_STEP|$DASH_IU_SEL|$DASH_IU_SVC|$DASH_IU_TAG|${DASH_IU_NAMES[*]}|${DASH_IU_CUR[*]}"; }

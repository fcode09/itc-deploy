#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Mode: ask for an image archive (the output of `docker save`, .tar or .tar.gz) and load it into this Docker (from the Images view). The
# path is typed in a field that says whether the file is there; Enter runs `./deltactl load <file>` as a background command: the panel keeps
# working, the Images view shows what is being loaded, and when the command ends the catalog is read again. A path may start with ~/.

# The field being edited is the kit's (KF_VALUE and KF_CUR, lib/ui/kit/field.sh).
DASH_IL_MSG=""

# Opens the dialog.
dash_img_load_ask() {
  if job_running; then dash_msg warn "$(t tui.msg.busy)"; return 0; fi
  KF_VALUE="" KF_CUR=0 DASH_IL_MSG=""
  DASH_MODE=imgload
}

# The path typed, with a leading ~/ expanded, into DASH_IL_PATH.
DASH_IL_PATH=""
dash_il_path() {
  DASH_IL_PATH="$KF_VALUE"
  # shellcheck disable=SC2088  # the literal text ~/ is what is matched
  case "$DASH_IL_PATH" in "~/"*) DASH_IL_PATH="$HOME/${DASH_IL_PATH#\~/}" ;; esac
}

dash_key_imgload() { # key
  case "$1" in
    esc) DASH_MODE=normal; dash_msg info "$(t tui.msg.cancelled)"; return 0 ;;
    enter)
      dash_il_path
      if [ -z "$DASH_IL_PATH" ]; then DASH_IL_MSG="$(t tui.img.load.empty)"; return 0; fi
      if [ ! -f "$DASH_IL_PATH" ]; then DASH_IL_MSG="$(t tui.img.load.no_file)"; return 0; fi
      DASH_MODE=normal
      if dash_start_job stay load "$DASH_IL_PATH"; then DASH_IMG_JOB="$JOB_SEQ" DASH_IMG_LOADING="${DASH_IL_PATH##*/}"; fi
      return 0
      ;;
  esac
  DASH_IL_MSG=""
  kit_field_key "$1" || true
}

dash_dialog_imgload() { # body_height
  local l ww=64 st=pend msg=""
  [ "$ww" -le $((TUI_COLS - 10)) ] || ww=$((TUI_COLS - 10))
  dash_il_path
  if [ -n "$DASH_IL_PATH" ]; then
    if [ -f "$DASH_IL_PATH" ]; then st=ok; else st=warn; msg="$(t tui.img.load.no_file)"; fi
  fi
  [ -z "$DASH_IL_MSG" ] || { st=err; msg="$DASH_IL_MSG"; }
  DASH_DLG=("")
  t_r tui.img.load.text; dash_wrap "$T_OUT" "$ww"
  for l in "${DASH_WRAP[@]}"; do DASH_DLG+=("  $l"); done
  DASH_DLG+=("")
  t_r tui.img.load.label
  kit_field_render "$T_OUT" "$KF_VALUE" "$KF_CUR" $((ww - 2)) focus=1 state="$st" ${msg:+"msg=$msg"} label_width=10
  DASH_DLG+=("  $KIT_OUT" "")
  t_r tui.img.load.note; dash_wrap "$T_OUT" "$ww"
  for l in "${DASH_WRAP[@]}"; do DASH_DLG+=("  $C_GRY$l$C_OFF"); done
  DASH_DLG+=("")
  t_r tui.img.load.title
  dash_dialog "$1" "$T_OUT" 56
}

# --- The contract of lib/screens/registry.sh --------------------------------------------------------------------
scr_imgload_render() { dash_dialog_imgload "$2"; } # width height
scr_imgload_key() { dash_key_imgload "$1"; }
scr_imgload_keys() { # width
  local k=tui.img.load.keys
  if [ "$UI_UTF8" -ne 1 ] || [ "$UI_RICH" -ne 1 ]; then k+=.ascii; fi
  dt "$k"
  dash_keyfit "$DTV" "$1"; TUI_FRAME+=(" $C_GRY$DASH_KF$C_OFF")
}
scr_imgload_sig() { DASH_SIG+="|$KF_VALUE|$KF_CUR|$DASH_IL_MSG"; }

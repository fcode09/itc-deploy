#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Mode: a value typed for a service of an instance (the Services tab). Four kinds:
#   remove   the key of the service, typed to confirm that it leaves the instance (its data stays)
#   tag      the version (a loaded one is shown; ↑ takes the most recent; `latest` is the most recent at the time it is saved)
#   port     the port
#   memory   the memory limit (512m, 2g)
# What is typed is checked as it is typed with the same rules the command uses (lib/core/svcmgmt.sh); Enter runs `./deltactl service ...` in the
# background (it shows in Output and in the history). Nothing is written before Enter.

DASH_SA_KIND="" DASH_SA_INST="" DASH_SA_SVC=""
DASH_SA_STAR="" DASH_SA_TAGS="" DASH_SA_CUR=""

# The loaded versions of the image of the service (the most recent one starred), when the catalog of Docker has been read, into DASH_SA_TAGS
# (words, the star marked with a *) and DASH_SA_STAR (its tag).
dash_sa_loaded() { # instance service
  local g svc="$2" repo i star tags=""
  DASH_SA_STAR="" DASH_SA_TAGS=""
  [ "${DASH_IMG_STATE:-none}" = "ready" ] || return 0
  service_repo_r "$svc" "$1"; repo="$SR"
  g="$svc|$repo"
  star="${IC_STARIDX[$g]:--1}"
  for i in ${IC_ORDER[$g]:-}; do
    [ "${IC_OK[$i]:-1}" -eq 1 ] || continue
    if [ "$i" = "$star" ]; then tags+="${tags:+ }${IC_TAG[$i]}*"; DASH_SA_STAR="${IC_TAG[$i]}"; else tags+="${tags:+ }${IC_TAG[$i]}"; fi
  done
  DASH_SA_TAGS="$tags"
}

# Opens the prompt. The value that the service has now is the starting text (nothing for `remove`).
dash_sa_open() { # kind instance service
  local f
  DASH_SA_KIND="$1" DASH_SA_INST="$2" DASH_SA_SVC="$3"
  f="$INSTANCES_DIR/$2/.env.instance"
  case "$1" in
    tag) get_var_r "$f" "$(tag_var "$3")"; DASH_SA_CUR="$GV"; dash_sa_loaded "$2" "$3" ;;
    port) get_var_r "$f" "${3^^}_PORT"; DASH_SA_CUR="$GV" ;;
    memory) get_var_r "$f" "${3^^}_MEM_LIMIT"; DASH_SA_CUR="${GV:-${CAT_MEM[$3]:-}}" ;;
    *) DASH_SA_CUR="" ;;
  esac
  DASH_BUF="$DASH_SA_CUR"
  [ "$1" != remove ] || DASH_BUF=""
  DASH_CUR="${#DASH_BUF}"
  DASH_MODE=svcask
}

# What the typed text is: ok, or err with the reason in DASH_SA_WHY.
DASH_SA_WHY=""
dash_sa_check() {
  DASH_SA_WHY=""
  case "$DASH_SA_KIND" in
    remove) [ "$DASH_BUF" = "$DASH_SA_SVC" ] || { DASH_SA_WHY="$(t tui.svc.ask.remove_wait "$DASH_SA_SVC")"; return 1; } ;;
    tag) [ "$DASH_BUF" = latest ] && return 0
      svc_value_ok "$DASH_SA_INST" "$DASH_SA_SVC" tag "$DASH_BUF" || { DASH_SA_WHY="$SVC_MSG"; return 1; } ;;
    *)
      [ -n "$DASH_BUF" ] || { DASH_SA_WHY="$(t tui.svc.ask.empty)"; return 1; }
      svc_value_ok "$DASH_SA_INST" "$DASH_SA_SVC" "$DASH_SA_KIND" "$DASH_BUF" || { DASH_SA_WHY="$SVC_MSG"; return 1; } ;;
  esac
  return 0
}

dash_key_svcask() { # key
  case "$1" in
    enter)
      if ! dash_sa_check; then dash_msg warn "$DASH_SA_WHY"; return 0; fi
      DASH_MODE=normal DASH_CUR=0
      if [ "$DASH_SA_KIND" = remove ]; then
        dash_start_job stay service remove "$DASH_SA_INST" "$DASH_SA_SVC" --yes
      elif [ "$DASH_BUF" = "$DASH_SA_CUR" ]; then
        dash_msg info "$(t tui.svc.ask.same)"
      else
        dash_start_job stay service set "$DASH_SA_INST" "$DASH_SA_SVC" "$DASH_SA_KIND" "$DASH_BUF"
      fi
      ;;
    up)
      if [ "$DASH_SA_KIND" = tag ] && [ -n "$DASH_SA_STAR" ]; then DASH_BUF="$DASH_SA_STAR" DASH_CUR="${#DASH_BUF}"; fi
      ;;
    down | tab) ;;
    *) dash_key_edit "$1" ;;
  esac
}

dash_dialog_svcask() { # body_height
  local l ww=64 q state=""
  [ "$ww" -le $((TUI_COLS - 10)) ] || ww=$((TUI_COLS - 10))
  DASH_DLG=("")
  case "$DASH_SA_KIND" in
    remove) t_r tui.svc.ask.remove "$DASH_SA_SVC" "$DASH_SA_INST"; q="$T_OUT" ;;
    tag) t_r tui.svc.ask.tag "$DASH_SA_SVC" "$DASH_SA_INST" "${DASH_SA_CUR:--}"; q="$T_OUT" ;;
    port) t_r tui.svc.ask.port "$DASH_SA_SVC" "$DASH_SA_INST" "${DASH_SA_CUR:--}"; q="$T_OUT" ;;
    *) t_r tui.svc.ask.memory "$DASH_SA_SVC" "$DASH_SA_INST" "${DASH_SA_CUR:--}"; q="$T_OUT" ;;
  esac
  dash_wrap "$q" "$ww"
  for l in "${DASH_WRAP[@]}"; do DASH_DLG+=(" $l"); done
  DASH_DLG+=("" " $C_BLD$DASH_BUF$C_OFF$C_CYN$UI_S_SEL$C_OFF" "")
  if dash_sa_check; then
    state=" $C_GRN$UI_S_OK$C_OFF $(t tui.svc.ask.ok)"
    [ -n "$DASH_BUF" ] || state=""
  else
    [ -z "$DASH_BUF" ] || { dash_wrap "$DASH_SA_WHY" $((ww - 3)); state=" $C_RED$UI_S_ERR$C_OFF ${DASH_WRAP[0]}"; }
  fi
  [ -z "$state" ] || DASH_DLG+=("$state" "")
  if [ "$DASH_SA_KIND" = tag ] && [ -n "$DASH_SA_TAGS" ]; then
    t_r tui.svc.ask.loaded "$DASH_SA_TAGS"; dash_wrap "$T_OUT" "$ww"
    for l in "${DASH_WRAP[@]}"; do DASH_DLG+=(" $C_GRY$l$C_OFF"); done
    DASH_DLG+=("")
  fi
  dt "tui.svc.ask.title.$DASH_SA_KIND"
  dash_dialog "$1" "$DTV" 50
}

# --- The contract of lib/screens/registry.sh --------------------------------------------------------------------
scr_svcask_render() { dash_dialog_svcask "$2"; } # width height
scr_svcask_key() { dash_key_svcask "$1"; }
scr_svcask_keys() { dt tui.svc.ask.keys; dash_keyfit "$DTV" "$1"; TUI_FRAME+=(" $C_GRY$DASH_KF$C_OFF"); } # width
scr_svcask_sig() {
  DASH_SIG+="|$DASH_SA_KIND|$DASH_SA_INST|$DASH_SA_SVC"
  [ "$DASH_MODE" != "svcask" ] || DASH_SIG+="|$DASH_BUF|$DASH_CUR"
}

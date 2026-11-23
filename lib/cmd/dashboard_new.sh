#!/usr/bin/env bash
# shellcheck disable=SC2034  # the DASH_* variables are shared with lib/cmd/dashboard.sh and lib/cmd/dashboard_view.sh
# The "New instance" form of the panel (mode wizard): the questions of `./deltactl new --wizard`, one dialog at a time, without
# leaving the panel. Sourced by lib/cmd/dashboard.sh.
#
# The steps follow the terminal wizard (lib/cmd/new.sh): name, services, existing, image and tag of each service, public URL,
# generate the secrets (only for a new instance and with openssl) and a summary. Enter goes on, Up goes back, Esc cancels.
# The form validates each answer as the terminal wizard does (valid_instance_name, valid_service, valid_image_name). At the end
# it starts `./deltactl new <name> ...` as a job of the panel, with the answers as options (--services, --existing, --s0-image,
# --s0-tag, --ip, --generate-secrets), so the output lands in the console like any other command and the panel keeps running.

DASH_NW_STEPS=()            # ids of the steps now: name services existing image:<svc> tag:<svc> ... ip gen confirm
DASH_NW_I=0 DASH_NW_ERR="" DASH_NW_HINT="" DASH_NW_SSL=0
DASH_NW_NAME="" DASH_NW_SVCS="s0,s1" DASH_NW_EXISTING=0 DASH_NW_IP="" DASH_NW_GEN=1
declare -gA DASH_NW_IMG=() DASH_NW_TAG=()

# Opens the form. It refuses while a command runs: the answers would have nowhere to go at the end.
dash_open_new() {
  if job_running; then dash_msg warn "$(t tui.msg.busy)"; return 0; fi
  DASH_NW_NAME="" DASH_NW_SVCS="s0,s1" DASH_NW_EXISTING=0 DASH_NW_IP="" DASH_NW_GEN=1 DASH_NW_ERR="" DASH_NW_HINT=""
  DASH_NW_IMG=() DASH_NW_TAG=()
  if command -v openssl > /dev/null 2>&1; then DASH_NW_SSL=1; else DASH_NW_SSL=0; fi
  dash_nw_steps
  DASH_NW_I=0
  dash_nw_enter
  DASH_MODE=wizard
}

# The steps for the answers so far (the services and "existing" change which ones there are).
dash_nw_steps() {
  local svc
  local -a parts=()
  DASH_NW_STEPS=(name services existing)
  IFS=',' read -ra parts <<< "${DASH_NW_SVCS// /}"
  for svc in "${parts[@]}"; do DASH_NW_STEPS+=("image:$svc" "tag:$svc"); done
  DASH_NW_STEPS+=(ip)
  if [ "$DASH_NW_EXISTING" -eq 0 ] && [ "$DASH_NW_SSL" -eq 1 ]; then DASH_NW_STEPS+=(gen); fi
  DASH_NW_STEPS+=(confirm)
}

# Kind of the current step (name, services, existing, image, tag, ip, gen, confirm) and its service, if any.
dash_nw_kind() {
  local id="${DASH_NW_STEPS[$DASH_NW_I]}"
  DASH_NW_K="${id%%:*}" DASH_NW_S=""
  [ "$id" = "$DASH_NW_K" ] || DASH_NW_S="${id#*:}"
}
DASH_NW_K="" DASH_NW_S=""

# Prepares the step that is now current: the line starts with the answer already given, or the default.
dash_nw_enter() {
  local img tags=""
  dash_nw_kind
  DASH_NW_ERR="" DASH_NW_HINT=""
  case "$DASH_NW_K" in
    name) DASH_BUF="$DASH_NW_NAME" ;;
    services) DASH_BUF="$DASH_NW_SVCS" ;;
    image) DASH_BUF="${DASH_NW_IMG[$DASH_NW_S]:-}"; [ -n "$DASH_BUF" ] || DASH_BUF="$(default_repo "$DASH_NW_S")" ;;
    tag)
      DASH_BUF="${DASH_NW_TAG[$DASH_NW_S]:-}"
      img="${DASH_NW_IMG[$DASH_NW_S]:-}"; [ -n "$img" ] || img="$(default_repo "$DASH_NW_S")"
      # The tags already loaded in this Docker, as in the terminal wizard (one `docker image ls` when the step opens).
      tags="$(loaded_tags "$img" | tr '\n' ' ')" || tags=""
      if [ -n "$tags" ]; then t_r new.loaded_tags "$img" "${tags% }"; DASH_NW_HINT="$T_OUT"; fi
      ;;
    ip) DASH_BUF="$DASH_NW_IP" ;;
    existing) t_r new.existing_note; DASH_NW_HINT="$T_OUT"; DASH_BUF="" ;;
    *) DASH_BUF="" ;;
  esac
  DASH_CUR="${#DASH_BUF}"
}

dash_nw_go() { # +1 | -1
  local n="${#DASH_NW_STEPS[@]}"
  DASH_NW_I=$((DASH_NW_I + $1))
  [ "$DASH_NW_I" -ge 0 ] || DASH_NW_I=0
  [ "$DASH_NW_I" -lt "$n" ] || DASH_NW_I=$((n - 1))
  dash_nw_enter
}

dash_nw_cancel() {
  DASH_MODE=normal DASH_CUR=0 DASH_BUF=""
  dash_msg info "$(t tui.msg.cancelled)"
}

# Enter on a step that takes text: checks the answer (as the terminal wizard does), keeps it and goes on. A wrong one stays on the
# step with the reason in the dialog.
dash_nw_submit() {
  local v="$DASH_BUF" p seen=" " svcs=""
  local -a parts=()
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  case "$DASH_NW_K" in
    name)
      if ! valid_instance_name "$v"; then DASH_NW_ERR="$(t err.instance_name_invalid "$v")"; return 0; fi
      if [ -e "$(instance_dir "$v")" ]; then DASH_NW_ERR="$(t new.err_exists "$v" "$(instance_dir "$v")")"; return 0; fi
      DASH_NW_NAME="$v"
      ;;
    services)
      IFS=',' read -ra parts <<< "${v// /}"
      for p in "${parts[@]}"; do
        if ! valid_service "$p"; then DASH_NW_ERR="$(t new.err_wiz_service "$p" "${KNOWN_SERVICES[*]}")"; return 0; fi
        case "$seen" in *" $p "*) continue ;; esac   # a service named twice counts once
        seen+="$p "
        svcs+="${svcs:+,}$p"
      done
      if [ -z "$svcs" ]; then DASH_NW_ERR="$(t new.err_wiz_service "$v" "${KNOWN_SERVICES[*]}")"; return 0; fi
      DASH_NW_SVCS="$svcs"
      dash_nw_steps   # (the steps after this one depend on the services)
      ;;
    image)
      if ! valid_image_name "$v"; then DASH_NW_ERR="$(t new.err_image_invalid "$v")"; return 0; fi
      DASH_NW_IMG[$DASH_NW_S]="$v"
      ;;
    tag) DASH_NW_TAG[$DASH_NW_S]="$v" ;;
    ip) DASH_NW_IP="$v" ;;
  esac
  dash_nw_go 1
}

# Answer to a yes/no step; the "existing" answer changes the steps (a new instance may generate secrets).
dash_nw_yn() { # 1 | 0 | keep
  case "$DASH_NW_K" in
    existing) [ "$1" = keep ] || DASH_NW_EXISTING="$1"; dash_nw_steps ;;
    gen) [ "$1" = keep ] || DASH_NW_GEN="$1" ;;
  esac
  dash_nw_go 1
}

# Starts `new` with the answers as options. The panel's own busy check applies: if a command started in the meantime the form stays.
dash_nw_create() {
  local s
  local -a argv=(new "$DASH_NW_NAME" --services "$DASH_NW_SVCS")
  if job_running; then DASH_NW_ERR="$(t tui.msg.busy)"; return 0; fi
  [ "$DASH_NW_EXISTING" -eq 0 ] || argv+=(--existing)
  for s in ${DASH_NW_SVCS//,/ }; do
    [ -z "${DASH_NW_IMG[$s]:-}" ] || argv+=("--$s-image" "${DASH_NW_IMG[$s]}")
    [ -z "${DASH_NW_TAG[$s]:-}" ] || argv+=("--$s-tag" "${DASH_NW_TAG[$s]}")
  done
  [ -z "$DASH_NW_IP" ] || argv+=(--ip "$DASH_NW_IP")
  if [ "$DASH_NW_EXISTING" -eq 0 ] && [ "$DASH_NW_SSL" -eq 1 ] && [ "$DASH_NW_GEN" -eq 1 ]; then argv+=(--generate-secrets); fi
  DASH_MODE=normal DASH_CUR=0 DASH_BUF=""
  dash_start_job stay "${argv[@]}"
}

dash_key_wizard() { # key
  local k="$1"
  dash_nw_kind
  case "$k" in
    esc) dash_nw_cancel; return 0 ;;
    up | btab) dash_nw_go -1; return 0 ;;
  esac
  case "$DASH_NW_K" in
    existing | gen)
      case "$k" in
        y | Y | s | S) dash_nw_yn 1 ;;
        n | N) dash_nw_yn 0 ;;
        enter) dash_nw_yn keep ;;
      esac
      ;;
    confirm)
      case "$k" in
        y | Y | s | S | enter) dash_nw_create ;;
        n | N) dash_nw_cancel ;;
      esac
      ;;
    *)
      case "$k" in
        enter) dash_nw_submit ;;
        down | tab) ;;
        *) DASH_NW_ERR=""; dash_key_edit "$k" ;;
      esac
      ;;
  esac
}

# --- Drawing ---------------------------------------------------------------------------------------------------

# The question of the current step into T_OUT.
dash_nw_question() {
  case "$DASH_NW_K" in
    name) t_r new.ask_name ;;
    services) t_r new.ask_services ;;
    existing) t_r new.ask_existing ;;
    image) t_r new.ask_image "$DASH_NW_S" ;;
    tag) t_r new.ask_tag "$DASH_NW_S" ;;
    ip) t_r new.ask_url ;;
    gen) t_r new.ask_generate ;;
    confirm) t_r new.ask_create ;;
  esac
}

# The summary of the answers (the same text as the terminal wizard) into DASH_DLG, one row per line.
dash_nw_summary() {
  local pending data secrets line
  t_r new.pending_word; pending="$T_OUT"
  if [ "$DASH_NW_EXISTING" -eq 1 ]; then t_r new.data_existing; else t_r new.data_new; fi
  data="$T_OUT"
  if [ "$DASH_NW_EXISTING" -eq 0 ] && [ "$DASH_NW_SSL" -eq 1 ] && [ "$DASH_NW_GEN" -eq 1 ]; then t_r new.secrets_generated; else t_r new.secrets_manual; fi
  secrets="$T_OUT"
  t_r new.summary "$DASH_NW_NAME" "$DASH_NW_SVCS" "$data" "${DASH_NW_TAG[s0]:-$pending}" "${DASH_NW_TAG[s1]:-$pending}" "${DASH_NW_IP:-$pending}" "$secrets"
  while IFS= read -r line; do DASH_DLG+=("$line"); done <<< "$T_OUT"
}

dash_dialog_wizard() { # body_height
  local l acc="${TH[accent]:-$C_CYN}" before after yes no title mark_y mark_n
  dash_nw_kind
  DASH_DLG=("")
  # The last step shows what was answered before asking to create.
  if [ "$DASH_NW_K" = confirm ]; then
    t_r new.summary_title; DASH_DLG+=(" $C_BLD$T_OUT$C_OFF")
    dash_nw_summary
    DASH_DLG+=("")
  fi
  dash_nw_question
  dash_wrap "$T_OUT" 58
  for l in "${DASH_WRAP[@]}"; do DASH_DLG+=(" $l"); done
  if [ -n "$DASH_NW_HINT" ]; then
    dash_wrap "$DASH_NW_HINT" 58
    for l in "${DASH_WRAP[@]}"; do DASH_DLG+=(" $C_GRY$l$C_OFF"); done
  fi
  DASH_DLG+=("")
  case "$DASH_NW_K" in
    existing | gen)
      t_r tui.nw.yes; yes="$T_OUT"
      t_r tui.nw.no; no="$T_OUT"
      if [ "$DASH_NW_K" = existing ]; then mark_y="$DASH_NW_EXISTING"; else mark_y="$DASH_NW_GEN"; fi
      if [ "$mark_y" -eq 1 ]; then
        mark_y="${acc}[x]$C_OFF $C_BLD$yes$C_OFF" mark_n="[ ] $no"
      else
        mark_y="[ ] $yes" mark_n="${acc}[x]$C_OFF $C_BLD$no$C_OFF"
      fi
      DASH_DLG+=(" $mark_y    $mark_n" "")
      ;;
    confirm) ;;   # (the summary is above the question)
    *)
      before="${DASH_BUF:0:$DASH_CUR}" after="${DASH_BUF:$DASH_CUR}"
      DASH_DLG+=(" $C_BLD$before$C_OFF$acc$UI_S_SEL$C_OFF$C_BLD$after$C_OFF" "")
      ;;
  esac
  if [ -n "$DASH_NW_ERR" ]; then
    dash_wrap "$DASH_NW_ERR" 58
    for l in "${DASH_WRAP[@]}"; do DASH_DLG+=(" $C_RED$l$C_OFF"); done
    DASH_DLG+=("")
  fi
  # On a short terminal the blank rows between the parts go first, so the question and the summary still fit.
  if [ $((${#DASH_DLG[@]} + 2)) -gt "$1" ]; then
    local -a compact=()
    for l in "${DASH_DLG[@]}"; do [ -z "$l" ] || compact+=("$l"); done
    DASH_DLG=("${compact[@]}")
  fi
  t_r new.wiz_title; title="$T_OUT $UI_S_DOT $((DASH_NW_I + 1))/${#DASH_NW_STEPS[@]}"
  dash_dialog "$1" "$title" 64
}

# The last line while the form is open (result in DASH_KBV, like the key bars of the views).
dash_nw_keys() { # width
  local up=Up
  if [ "$UI_UTF8" -eq 1 ] && [ "$UI_RICH" -eq 1 ]; then up='↑'; fi
  dash_nw_kind
  case "$DASH_NW_K" in
    existing | gen) t_r tui.nw.keys.yn "$up" ;;
    confirm) t_r tui.nw.keys.confirm "$up" ;;
    *) t_r tui.nw.keys.text "$up" ;;
  esac
  dash_keybar "$T_OUT" "$1"
}

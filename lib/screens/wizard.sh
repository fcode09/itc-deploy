#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables are shared with lib/cmd/dashboard.sh, dashboard_view.sh and the other screens
# The "New instance" form of the panel (mode wizard). Loaded by lib/screens/registry.sh.
#
# It is a settings form, not a questionnaire: on the left the sections of an instance with their state (an icon at the start of
# each row), on the right the fields of the section in use. Sections: name, services, data, images, access (URL and secrets) and
# summary. Every field is checked as it is typed and the state of each section follows, so what is missing is always in view.
#
# Keys. Fields: text (a line editor), check ([x] / [ ]), radio ((o) / ( )) and a button. Up and Down walk the fields and, past the
# first or the last one, go on to the previous or next section; Enter on a text field goes to the next one; Space or Enter toggle a
# check or a radio; PgUp / PgDn change section; Tab moves the focus between the list of sections and the fields; Esc goes back to
# the list and, from the list, cancels. `c` in the list creates. On a narrow terminal (< 92 columns or < 20 rows) only the fields
# are drawn, Tab / Shift+Tab change section and Esc cancels.
#
# At the end it starts `./deltactl new <name> ...` as a job of the panel with the answers as options (--services, --existing,
# --s0-image, --s0-tag, --ip, --generate-secrets), so the output lands in the console like any other command. The checks are the
# ones of lib/cmd/new.sh (valid_instance_name, valid_service, valid_image_name): a rule changed there changes here.

DASH_NW_SECS=(name services data images access summary)
DASH_NW_SEC=0 DASH_NW_F=0 DASH_NW_FOCUS=pane DASH_NW_FRESH=0 DASH_NW_ERR="" DASH_NW_V=0 DASH_NW_WIDE=1
DASH_NW_NAME="" DASH_NW_PROPOSED="" DASH_NW_DATA=0 DASH_NW_IP="" DASH_NW_GEN=1 DASH_NW_SSL=0 DASH_NW_IMGLIST=""
DASH_NW_FL=() DASH_NW_R=() DASH_NW_L=()
DASH_NW_FK="" DASH_NW_FR="" DASH_NW_TV="" DASH_NW_TD="" DASH_NW_TG="" DASH_NW_NS="" DASH_NW_ST="" DASH_NW_VAL="" DASH_NW_IC=""
DASH_NW_CSV="" DASH_NW_WHY="" DASH_NW_FIRST=-1 DASH_NW_RT="" DASH_NW_T=""
DASH_NW_CRI=-1 DASH_NW_CK=0 DASH_NW_CR=0 DASH_NW_CC=0   # the real cursor: row of the right pane, offset in it, and screen row/column
declare -gA DASH_NW_SEL=() DASH_NW_IMG=() DASH_NW_TAG=() DASH_NW_PORT=() DASH_NW_PBUSY=() DASH_NW_MEM=() DASH_NW_TGC=()

# --- Opening ---------------------------------------------------------------------------------------------------

# Opens the form. It refuses while a command runs: the answers would have nowhere to go at the end.
dash_open_new() {
  local s n=1
  if job_running; then dash_msg warn "$(t tui.msg.busy)"; return 0; fi
  # With something required missing on the server the form does not open until the person says to go on (or looks at the requirements).
  if dash_srv_blocking; then dash_srv_ask_gate; return 0; fi
  # The wizard of steps (lib/screens/newinst.sh) opens instead of this form when TUI_WIZARD=2.
  if [ "$DASH_WIZARD" = 2 ]; then dash_nz_open; return 0; fi
  if command -v openssl > /dev/null 2>&1; then DASH_NW_SSL=1; else DASH_NW_SSL=0; fi
  # A name is proposed: the first instancia-N that is free (the first key typed replaces it).
  while [ -e "$INSTANCES_DIR/instancia-$n" ]; do n=$((n + 1)); done
  DASH_NW_PROPOSED="instancia-$n" DASH_NW_NAME="instancia-$n"
  DASH_NW_DATA=0 DASH_NW_IP="" DASH_NW_GEN=1 DASH_NW_ERR=""
  DASH_NW_SEL=() DASH_NW_IMG=() DASH_NW_TAG=() DASH_NW_TGC=()
  for s in "${KNOWN_SERVICES[@]}"; do DASH_NW_SEL[$s]=1 DASH_NW_IMG[$s]="$(default_repo "$s")" DASH_NW_TAG[$s]=""; done
  dash_nw_probe
  DASH_NW_SEC=0 DASH_NW_F=0 DASH_NW_FOCUS=pane
  dash_nw_load
  DASH_MODE=wizard
}

# What the services section shows about the machine, read once when the form opens: the images in this Docker (one `docker image ls`),
# the ports the new instance would get and whether anything holds them, and the memory limit each service gets by default.
dash_nw_probe() {
  local s base p
  DASH_NW_IMGLIST=""
  if dk_ready; then DASH_NW_IMGLIST="$(dk_images_tags)" || DASH_NW_IMGLIST=""; fi
  base="$(next_s0_port)"
  for s in "${KNOWN_SERVICES[@]}"; do
    p=$((base + ${s#s}))
    DASH_NW_PORT[$s]="$p" DASH_NW_PBUSY[$s]=0
    if [ -n "$(port_owner "$p" "")" ] || host_port_in_use "$p"; then DASH_NW_PBUSY[$s]=1; fi
    DASH_NW_MEM[$s]="$(get_var "$ROOT/templates/.env.instance.example" "${s^^}_MEM_LIMIT")"
  done
}

# Tags loaded in this Docker for an image, into DASH_NW_TG (space separated; empty when there is none or the name is not valid).
dash_nw_tags_for() { # image
  DASH_NW_TG=""
  { [ -n "$1" ] && [ -n "$DASH_NW_IMGLIST" ] && valid_image_name "$1"; } || return 0
  if [ -z "${DASH_NW_TGC[$1]+x}" ]; then
    DASH_NW_TGC[$1]="$(awk -F'|' -v r="$1" '($1 == r || $1 ~ ("/" r "$")) && $2 != "<none>" { printf "%s ", $2 }' <<< "$DASH_NW_IMGLIST")"
  fi
  DASH_NW_TG="${DASH_NW_TGC[$1]% }"
}

# --- State -----------------------------------------------------------------------------------------------------

dash_nw_trim() { # text -> DASH_NW_T
  DASH_NW_T="${1#"${1%%[![:space:]]*}"}"
  DASH_NW_T="${DASH_NW_T%"${DASH_NW_T##*[![:space:]]}"}"
}

# The selected services as "s0,s1" into DASH_NW_CSV.
dash_nw_sel_csv() {
  local s
  DASH_NW_CSV=""
  for s in "${KNOWN_SERVICES[@]}"; do
    if [ "${DASH_NW_SEL[$s]:-0}" -eq 1 ]; then DASH_NW_CSV+="${DASH_NW_CSV:+,}$s"; fi
  done
}

dash_nw_svc_name() { # service
  case "$1" in s0) DASH_NW_SN=Auth ;; s1) DASH_NW_SN=Gue ;; *) DASH_NW_SN="${1^^}" ;; esac
}
DASH_NW_SN=""

# Secrets can be generated for a new instance (an existing one keeps its own) and when openssl is there.
dash_nw_gen_ok() { [ "$DASH_NW_DATA" -eq 0 ] && [ "$DASH_NW_SSL" -eq 1 ]; }

# State of the name into DASH_NW_NS: ok | empty | bad | exists.
dash_nw_name_state() {
  if [ -z "$DASH_NW_NAME" ]; then DASH_NW_NS=empty
  elif ! valid_instance_name "$DASH_NW_NAME"; then DASH_NW_NS=bad
  elif [ -e "$INSTANCES_DIR/$DASH_NW_NAME" ]; then DASH_NW_NS=exists
  else DASH_NW_NS=ok; fi
}

# State of a section into DASH_NW_ST (ok | todo | warn | err) and a short text of its value into DASH_NW_VAL.
dash_nw_status() { # section index
  local s n=0 bad=0 notag=0
  DASH_NW_ST=ok DASH_NW_VAL=""
  case "${DASH_NW_SECS[$1]}" in
    name)
      dash_nw_name_state
      case "$DASH_NW_NS" in
        ok) DASH_NW_VAL="$DASH_NW_NAME" ;;
        empty) DASH_NW_ST=todo; t_r tui.nw.v.empty; DASH_NW_VAL="$T_OUT" ;;
        *) DASH_NW_ST=err; DASH_NW_VAL="$DASH_NW_NAME" ;;
      esac
      ;;
    services)
      dash_nw_sel_csv
      if [ -z "$DASH_NW_CSV" ]; then DASH_NW_ST=err; t_r tui.nw.v.none; DASH_NW_VAL="$T_OUT"; else DASH_NW_VAL="${DASH_NW_CSV//,/ }"; fi
      ;;
    data) if [ "$DASH_NW_DATA" -eq 1 ]; then t_r tui.nw.v.existing; else t_r tui.nw.v.new; fi; DASH_NW_VAL="$T_OUT" ;;
    images)
      for s in "${KNOWN_SERVICES[@]}"; do
        [ "${DASH_NW_SEL[$s]:-0}" -eq 1 ] || continue
        n=$((n + 1))
        valid_image_name "${DASH_NW_IMG[$s]:-}" || bad=1
        [ -n "${DASH_NW_TAG[$s]:-}" ] || notag=1
      done
      if [ "$n" -eq 0 ]; then DASH_NW_ST=todo; t_r tui.nw.v.empty
      elif [ "$bad" -eq 1 ]; then DASH_NW_ST=err; t_r tui.nw.v.badimg
      elif [ "$notag" -eq 1 ]; then DASH_NW_ST=warn; t_r tui.nw.v.notag
      else t_r tui.nw.v.ready; fi
      DASH_NW_VAL="$T_OUT"
      ;;
    access)
      dash_nw_trim "$DASH_NW_IP"
      if [ -z "$DASH_NW_T" ]; then DASH_NW_ST=warn; t_r tui.nw.v.nourl; DASH_NW_VAL="$T_OUT"; else DASH_NW_VAL="$DASH_NW_T"; fi
      ;;
    summary)
      if dash_nw_ready; then t_r tui.nw.v.ready; else DASH_NW_ST=todo; t_r tui.nw.v.blocked; fi
      DASH_NW_VAL="$T_OUT"
      ;;
  esac
}

# 0 when the instance can be created. What blocks it (the labels of the sections) goes to DASH_NW_WHY and the first of them to
# DASH_NW_FIRST. Only the name, the services and the images are required: the rest can be completed after creating.
dash_nw_ready() {
  local i st
  DASH_NW_WHY="" DASH_NW_FIRST=-1
  for i in 0 1 3; do
    dash_nw_status_plain "$i"
    st="$DASH_NW_PST"
    if [ "$st" = err ] || [ "$st" = todo ]; then
      t_r "tui.nw.sec.${DASH_NW_SECS[$i]}"
      DASH_NW_WHY+="${DASH_NW_WHY:+, }$T_OUT"
      [ "$DASH_NW_FIRST" -ge 0 ] || DASH_NW_FIRST="$i"
    fi
  done
  [ -z "$DASH_NW_WHY" ]
}

# The state of a section without touching the text of the last one (dash_nw_status of "summary" asks dash_nw_ready).
dash_nw_status_plain() { # section index -> DASH_NW_PST
  local keep_st="$DASH_NW_ST" keep_val="$DASH_NW_VAL"
  dash_nw_status "$1"
  DASH_NW_PST="$DASH_NW_ST"
  DASH_NW_ST="$keep_st" DASH_NW_VAL="$keep_val"
}
DASH_NW_PST=""

dash_nw_icon() { # state -> DASH_NW_IC
  case "$1" in
    ok) DASH_NW_IC="${DASH_SYM[ok]}" ;;
    warn) DASH_NW_IC="${DASH_SYM[warn]}" ;;
    err) DASH_NW_IC="${DASH_SYM[err]}" ;;
    *) DASH_NW_IC="${DASH_SYM[dim]}" ;;
  esac
}

# --- Fields ----------------------------------------------------------------------------------------------------
# A field is "kind:what": text:name text:ip text:image:s0 text:tag:s0 | check:s0 check:gen | radio:0 radio:1 | button:create

dash_nw_fields() {
  local s
  DASH_NW_FL=()
  case "${DASH_NW_SECS[$DASH_NW_SEC]}" in
    name) DASH_NW_FL=(text:name) ;;
    services) for s in "${KNOWN_SERVICES[@]}"; do DASH_NW_FL+=("check:$s"); done ;;
    data) DASH_NW_FL=(radio:0 radio:1) ;;
    images)
      for s in "${KNOWN_SERVICES[@]}"; do
        [ "${DASH_NW_SEL[$s]:-0}" -eq 1 ] || continue
        DASH_NW_FL+=("text:image:$s" "text:tag:$s")
      done
      ;;
    access)
      DASH_NW_FL=(text:ip)
      if dash_nw_gen_ok; then DASH_NW_FL+=(check:gen); fi
      ;;
    summary) DASH_NW_FL=(button:create) ;;
  esac
}

# The current field into DASH_NW_FK (kind) and DASH_NW_FR (what). The index stays inside the fields there are now.
dash_nw_cur() {
  local id n
  dash_nw_fields
  n="${#DASH_NW_FL[@]}"
  if [ "$DASH_NW_F" -ge "$n" ]; then DASH_NW_F=$((n > 0 ? n - 1 : 0)); fi
  id="${DASH_NW_FL[$DASH_NW_F]:-}"
  DASH_NW_FK="${id%%:*}" DASH_NW_FR="${id#*:}"
  if [ -z "$id" ]; then DASH_NW_FK="" DASH_NW_FR=""; fi
}

dash_nw_text_get() { # what -> DASH_NW_TV
  case "$1" in
    name) DASH_NW_TV="$DASH_NW_NAME" ;;
    ip) DASH_NW_TV="$DASH_NW_IP" ;;
    image:*) DASH_NW_TV="${DASH_NW_IMG[${1#image:}]:-}" ;;
    tag:*) DASH_NW_TV="${DASH_NW_TAG[${1#tag:}]:-}" ;;
    *) DASH_NW_TV="" ;;
  esac
}

dash_nw_text_set() { # what value
  case "$1" in
    name) DASH_NW_NAME="$2" ;;
    ip) DASH_NW_IP="$2" ;;
    image:*) DASH_NW_IMG[${1#image:}]="$2" ;;
    tag:*) DASH_NW_TAG[${1#tag:}]="$2" ;;
  esac
}

# The proposed value of a field into DASH_NW_TD (empty when it has none).
dash_nw_text_default() { # what
  case "$1" in
    name) DASH_NW_TD="$DASH_NW_PROPOSED" ;;
    image:*) DASH_NW_TD="$(default_repo "${1#image:}")" ;;
    *) DASH_NW_TD="" ;;
  esac
}

# Makes the line editor hold the value of the current field. A value that is still the proposed one is "fresh": the first key
# typed replaces it instead of adding to it.
dash_nw_load() {
  dash_nw_cur
  DASH_NW_FRESH=0
  if [ "$DASH_NW_FK" = text ]; then
    dash_nw_text_get "$DASH_NW_FR"
    DASH_BUF="$DASH_NW_TV"
    dash_nw_text_default "$DASH_NW_FR"
    if [ -n "$DASH_NW_TD" ] && [ "$DASH_BUF" = "$DASH_NW_TD" ]; then DASH_NW_FRESH=1; fi
  else
    DASH_BUF=""
  fi
  DASH_CUR="${#DASH_BUF}"
}

# Keeps what the line editor holds in the answer of the current field (called after every key, so the states follow the typing).
dash_nw_commit() {
  dash_nw_cur
  if [ "$DASH_NW_FK" = text ]; then dash_nw_text_set "$DASH_NW_FR" "$DASH_BUF"; fi
}

# --- Moving ----------------------------------------------------------------------------------------------------

dash_nw_after_move() { DASH_NW_ERR=""; dash_nw_load; }

# To the previous or next field; past the first or the last one, to the previous or next section.
dash_nw_move() { # +1 | -1
  local n last=$((${#DASH_NW_SECS[@]} - 1))
  dash_nw_commit
  dash_nw_fields
  n="${#DASH_NW_FL[@]}"
  DASH_NW_F=$((DASH_NW_F + $1))
  if [ "$DASH_NW_F" -ge "$n" ]; then
    if [ "$DASH_NW_SEC" -lt "$last" ]; then DASH_NW_SEC=$((DASH_NW_SEC + 1)) DASH_NW_F=0; else DASH_NW_F=$((n > 0 ? n - 1 : 0)); fi
  elif [ "$DASH_NW_F" -lt 0 ]; then
    if [ "$DASH_NW_SEC" -gt 0 ]; then
      DASH_NW_SEC=$((DASH_NW_SEC - 1))
      dash_nw_fields
      DASH_NW_F=$((${#DASH_NW_FL[@]} > 0 ? ${#DASH_NW_FL[@]} - 1 : 0))
    else
      DASH_NW_F=0
    fi
  fi
  dash_nw_after_move
}

dash_nw_section() { # index
  local last=$((${#DASH_NW_SECS[@]} - 1))
  [ "$1" -ge 0 ] || return 0
  [ "$1" -le "$last" ] || return 0
  dash_nw_commit
  DASH_NW_SEC="$1" DASH_NW_F=0
  dash_nw_after_move
}

# Flips the check or chooses the radio under the cursor.
dash_nw_toggle() {
  case "$DASH_NW_FK:$DASH_NW_FR" in
    check:gen) DASH_NW_GEN=$((1 - DASH_NW_GEN)) ;;
    check:*) DASH_NW_SEL[$DASH_NW_FR]=$((1 - ${DASH_NW_SEL[$DASH_NW_FR]:-0})) ;;
    radio:*) DASH_NW_DATA="$DASH_NW_FR" ;;
  esac
  DASH_NW_ERR=""
}

dash_nw_cancel() {
  DASH_MODE=normal DASH_CUR=0 DASH_BUF=""
  dash_msg info "$(t tui.msg.cancelled)"
}

# Creates when everything required is there; if not, goes to the first section that is not and says what is missing.
dash_nw_try_create() {
  local why
  dash_nw_commit
  if job_running; then DASH_NW_ERR="$(t tui.msg.busy)"; return 0; fi
  if ! dash_nw_ready; then
    why="$(t tui.nw.sum.blocked "$DASH_NW_WHY")"
    dash_nw_section "$DASH_NW_FIRST"
    DASH_NW_FOCUS=pane DASH_NW_ERR="$why"
    dash_msg warn "$why"
    return 0
  fi
  dash_nw_create
}

# Starts `new` with the answers as options. The panel's own busy check applies.
dash_nw_create() {
  local s name
  local -a argv
  dash_nw_trim "$DASH_NW_NAME"; name="$DASH_NW_T"
  dash_nw_sel_csv
  argv=(new "$name" --services "$DASH_NW_CSV")
  [ "$DASH_NW_DATA" -eq 0 ] || argv+=(--existing)
  for s in ${DASH_NW_CSV//,/ }; do
    dash_nw_trim "${DASH_NW_IMG[$s]:-}"; [ -z "$DASH_NW_T" ] || argv+=("--$s-image" "$DASH_NW_T")
    dash_nw_trim "${DASH_NW_TAG[$s]:-}"; [ -z "$DASH_NW_T" ] || argv+=("--$s-tag" "$DASH_NW_T")
  done
  dash_nw_trim "$DASH_NW_IP"; [ -z "$DASH_NW_T" ] || argv+=(--ip "$DASH_NW_T")
  if dash_nw_gen_ok && [ "$DASH_NW_GEN" -eq 1 ]; then argv+=(--generate-secrets); fi
  DASH_MODE=normal DASH_CUR=0 DASH_BUF=""
  dash_start_job stay "${argv[@]}"
}

# --- Keys ------------------------------------------------------------------------------------------------------

# Two panes need room; below that only the fields are drawn.
dash_nw_wide() {
  if [ "$TUI_COLS" -ge 92 ] && [ "$TUI_ROWS" -ge 20 ]; then DASH_NW_WIDE=1; else DASH_NW_WIDE=0; fi
}

dash_key_wizard() { # key
  DASH_NW_V=$((DASH_NW_V + 1))
  dash_nw_wide
  if [ "$DASH_NW_FOCUS" = list ] && [ "$DASH_NW_WIDE" -eq 1 ]; then dash_nw_key_list "$1"; else dash_nw_key_pane "$1"; fi
}

dash_nw_key_list() { # key
  case "$1" in
    esc) dash_nw_cancel ;;
    up) dash_nw_section $((DASH_NW_SEC - 1)) ;;
    down) dash_nw_section $((DASH_NW_SEC + 1)) ;;
    enter | right | tab | btab) DASH_NW_FOCUS=pane; dash_nw_load ;;
    c | C) dash_nw_try_create ;;
  esac
}

dash_nw_key_pane() { # key
  local k="$1"
  dash_nw_cur
  case "$k" in
    esc)
      if [ "$DASH_NW_WIDE" -eq 1 ]; then dash_nw_commit; DASH_NW_FOCUS=list DASH_NW_ERR=""; else dash_nw_cancel; fi
      return 0
      ;;
    tab | btab)
      if [ "$DASH_NW_WIDE" -eq 1 ]; then
        dash_nw_commit; DASH_NW_FOCUS=list DASH_NW_ERR=""
      elif [ "$k" = tab ]; then dash_nw_section $((DASH_NW_SEC + 1))
      else dash_nw_section $((DASH_NW_SEC - 1)); fi
      return 0
      ;;
    pgdn) dash_nw_section $((DASH_NW_SEC + 1)); return 0 ;;
    pgup) dash_nw_section $((DASH_NW_SEC - 1)); return 0 ;;
    up) dash_nw_move -1; return 0 ;;
    down) dash_nw_move 1; return 0 ;;
  esac
  case "$DASH_NW_FK" in
    text) dash_nw_key_text "$k" ;;
    check | radio) case "$k" in space | enter) dash_nw_toggle ;; esac ;;
    button) case "$k" in enter) dash_nw_try_create ;; esac ;;
  esac
}

dash_nw_key_text() { # key
  local k="$1"
  if [ "$k" = enter ]; then
    if [ "$DASH_NW_FR" = name ]; then
      dash_nw_commit
      dash_nw_name_state
      if [ "$DASH_NW_NS" != ok ]; then t_r "tui.nw.name.$DASH_NW_NS"; DASH_NW_ERR="$T_OUT"; return 0; fi
    fi
    dash_nw_move 1
    return 0
  fi
  if [ "$DASH_NW_FRESH" -eq 1 ]; then
    case "$k" in
      left | right | home | end) DASH_NW_FRESH=0 ;;
      backspace | delete) DASH_BUF="" DASH_CUR=0 DASH_NW_FRESH=0; dash_nw_commit; return 0 ;;
      *)
        if [ "$k" = space ] || { [ "${#k}" -eq 1 ] && [[ "$k" != [[:cntrl:]] ]]; }; then DASH_BUF="" DASH_CUR=0 DASH_NW_FRESH=0; fi
        ;;
    esac
  fi
  DASH_NW_ERR=""
  dash_key_edit "$k"
  dash_nw_commit
}

# --- Drawing: the fields ---------------------------------------------------------------------------------------

# The wrapped lines of a text into the right pane, each one indented by $4 spaces (one by default).
dash_nw_note() { # text color width [indent]
  local l pre
  printf -v pre '%*s' "${4:-1}" ''
  dash_wrap "$1" "$3"
  for l in "${DASH_WRAP[@]}"; do DASH_NW_R+=("$pre$2$l$C_OFF"); done
}

# Is the field "kind:what" the one with the cursor, and does the pane have the keyboard?
dash_nw_active() { # kind what
  [ "$DASH_NW_FOCUS" = pane ] && [ "$DASH_NW_FK" = "$1" ] && [ "$DASH_NW_FR" = "$2" ]
}

# A text field: the mark of the field at the start of the line, an optional label and the value. The one with the cursor shows
# what the line editor holds, and its position is kept for the real cursor of the terminal.
dash_nw_textline() { # what [label] [label_width]
  local what="$1" lab="${2:-}" lw="${3:-0}" acc="${TH[accent]:-$C_CYN}" line off=3
  dash_nw_text_get "$what"
  if dash_nw_active text "$what"; then
    line=" $acc$UI_S_SEL$C_OFF "
    if [ -n "$lab" ]; then dash_runs_padr "$lab" "$lw"; line+="$C_BLD$DASH_PAD$C_OFF  "; off=$((off + lw + 2)); fi
    DASH_NW_CRI="${#DASH_NW_R[@]}" DASH_NW_CK=$((off + DASH_CUR))
    line+="$C_BLD$DASH_BUF$C_OFF"
  else
    line="   "
    if [ -n "$lab" ]; then dash_runs_padr "$lab" "$lw"; line+="$C_GRY$DASH_PAD$C_OFF  "; fi
    if [ -n "$DASH_NW_TV" ]; then line+="$DASH_NW_TV"; else t_r tui.nw.empty; line+="$C_DIM$T_OUT$C_OFF"; fi
  fi
  DASH_NW_R+=("$line")
}

# A check ([x] / [ ]) or a radio ((o) / ( )) row with its text.
dash_nw_choiceline() { # kind what checked text
  local kind="$1" what="$2" on="$3" txt="$4" acc="${TH[accent]:-$C_CYN}" mark="  " box
  if dash_nw_active "$kind" "$what"; then mark="$acc$UI_S_SEL$C_OFF "; fi
  if [ "$kind" = check ]; then
    if [ "$on" -eq 1 ]; then box="${acc}[x]$C_OFF"; else box="[ ]"; fi
  else
    if [ "$on" -eq 1 ]; then box="${acc}(o)$C_OFF"; else box="( )"; fi
  fi
  DASH_NW_R+=(" $mark$box $txt")
}

# --- Drawing: the sections -------------------------------------------------------------------------------------

dash_nw_pane_name() { # width
  local acc="${TH[accent]:-$C_CYN}"
  DASH_NW_R+=("")
  t_r tui.nw.name.help; dash_nw_note "$T_OUT" "$C_GRY" "$1"
  DASH_NW_R+=("")
  dash_nw_textline name
  DASH_NW_R+=("")
  dash_nw_name_state
  case "$DASH_NW_NS" in
    ok) t_r tui.nw.name.ok; DASH_NW_R+=(" ${DASH_SYM[ok]} $T_OUT") ;;
    empty) t_r tui.nw.name.empty; DASH_NW_R+=(" ${DASH_SYM[dim]} $C_GRY$T_OUT$C_OFF") ;;
    *) t_r "tui.nw.name.$DASH_NW_NS"; DASH_NW_R+=(" ${DASH_SYM[err]} $C_RED$T_OUT$C_OFF") ;;
  esac
  if [ "$DASH_NW_FRESH" -eq 1 ] && [ "$DASH_NW_FOCUS" = pane ]; then
    t_r tui.nw.proposed; dash_nw_note "$T_OUT" "$acc" "$1"
  fi
}

dash_nw_pane_services() { # width
  local s lab img row ok pend txt
  local -a tags=()
  DASH_NW_R+=("")
  t_r tui.nw.svc.help; dash_nw_note "$T_OUT" "$C_GRY" "$1"
  DASH_NW_R+=("")
  for s in "${KNOWN_SERVICES[@]}"; do
    dash_nw_svc_name "$s"
    img="${DASH_NW_IMG[$s]:-$(default_repo "$s")}"
    dash_runs_padr "$DASH_NW_SN" 5; lab="$DASH_PAD"
    dash_runs_padr "$img" 15; row="$s  $lab $DASH_PAD"
    dash_runs_padr ":${DASH_NW_PORT[$s]:-}" 6; row+=" $DASH_PAD"
    row+=" ${DASH_NW_MEM[$s]:-}"
    dash_nw_choiceline check "$s" "${DASH_NW_SEL[$s]:-0}" "$row"
  done
  t_r tui.nw.svc.pending "walle $UI_S_DOT robin $UI_S_DOT link"; DASH_NW_R+=("   $C_DIM$T_OUT$C_OFF")
  DASH_NW_R+=("")
  t_r tui.nw.svc.state; DASH_NW_R+=(" $C_BLD$T_OUT$C_OFF")
  for s in "${KNOWN_SERVICES[@]}"; do
    dash_nw_svc_name "$s"
    if [ "${DASH_NW_SEL[$s]:-0}" -ne 1 ]; then
      t_r tui.nw.svc.off; DASH_NW_R+=("   $s  $C_DIM$T_OUT$C_OFF")
      continue
    fi
    img="${DASH_NW_IMG[$s]:-$(default_repo "$s")}"
    dash_nw_tags_for "$img"
    if [ -n "$DASH_NW_TG" ]; then
      # The first tag, and how many more there are (a list of all of them does not fit the row).
      read -ra tags <<< "$DASH_NW_TG"
      txt="${tags[0]}"
      [ "${#tags[@]}" -le 1 ] || txt+=" +$((${#tags[@]} - 1))"
      t_r tui.nw.svc.img_ok "$txt"; ok="${DASH_SYM[ok]} $T_OUT"
    else t_r tui.nw.svc.img_none; ok="${DASH_SYM[warn]} $T_OUT"; fi
    if [ "${DASH_NW_PBUSY[$s]:-0}" -eq 1 ]; then t_r tui.nw.svc.port_busy "${DASH_NW_PORT[$s]:-}"; pend="${DASH_SYM[warn]} $T_OUT"
    else t_r tui.nw.svc.port_ok "${DASH_NW_PORT[$s]:-}"; pend="${DASH_SYM[ok]} $T_OUT"; fi
    DASH_NW_R+=("   $s  $ok")
    DASH_NW_R+=("       $pend")
  done
  dash_nw_sel_csv
  if [ -z "$DASH_NW_CSV" ]; then t_r tui.nw.svc.none; DASH_NW_R+=("" " $C_RED$T_OUT$C_OFF"); fi
}

dash_nw_pane_data() { # width
  DASH_NW_R+=("")
  t_r tui.nw.data.help; dash_nw_note "$T_OUT" "$C_GRY" "$1"
  DASH_NW_R+=("")
  t_r tui.nw.data.new; dash_nw_choiceline radio 0 $((1 - DASH_NW_DATA)) "$C_BLD$T_OUT$C_OFF"
  t_r tui.nw.data.new_note; dash_nw_note "$T_OUT" "$C_GRY" $(($1 - 6)) 7
  DASH_NW_R+=("")
  t_r tui.nw.data.existing; dash_nw_choiceline radio 1 "$DASH_NW_DATA" "$C_BLD$T_OUT$C_OFF"
  t_r new.existing_note; dash_nw_note "$T_OUT" "$C_GRY" $(($1 - 6)) 7
}

dash_nw_pane_images() { # width
  local s lw=8 lab
  DASH_NW_R+=("")
  t_r tui.nw.img.help; dash_nw_note "$T_OUT" "$C_GRY" "$1"
  dash_nw_sel_csv
  if [ -z "$DASH_NW_CSV" ]; then t_r tui.nw.svc.none; DASH_NW_R+=("" " $C_YEL$T_OUT$C_OFF"); return 0; fi
  for s in ${DASH_NW_CSV//,/ }; do
    dash_nw_svc_name "$s"
    DASH_NW_R+=("" " $C_BLD$s  $DASH_NW_SN$C_OFF")
    t_r tui.nw.img.image; dash_nw_textline "image:$s" "$T_OUT" "$lw"
    t_r tui.nw.img.tag; dash_nw_textline "tag:$s" "$T_OUT" "$lw"
    dash_nw_tags_for "${DASH_NW_IMG[$s]:-}"
    if [ -n "$DASH_NW_TG" ]; then t_r tui.nw.img.loaded "$DASH_NW_TG"; DASH_NW_R+=("   $C_GRY$T_OUT$C_OFF")
    elif [ -n "$DASH_NW_IMGLIST" ]; then t_r tui.nw.img.none; DASH_NW_R+=("   $C_YEL$T_OUT$C_OFF"); fi
  done
}

dash_nw_pane_access() { # width
  DASH_NW_R+=("")
  t_r tui.nw.acc.help; dash_nw_note "$T_OUT" "$C_GRY" "$1"
  DASH_NW_R+=("")
  t_r tui.nw.acc.url; dash_nw_textline ip "$T_OUT" 12
  t_r tui.nw.acc.url_note; DASH_NW_R+=("   $C_GRY$T_OUT$C_OFF")
  DASH_NW_R+=("")
  if dash_nw_gen_ok; then
    t_r tui.nw.acc.gen; dash_nw_choiceline check gen "$DASH_NW_GEN" "$T_OUT"
  elif [ "$DASH_NW_DATA" -eq 1 ]; then
    t_r tui.nw.acc.gen_data; DASH_NW_R+=("   $C_GRY$T_OUT$C_OFF")
  else
    t_r tui.nw.acc.gen_ssl; DASH_NW_R+=("   $C_YEL$T_OUT$C_OFF")
  fi
}

dash_nw_pane_summary() { # width
  local pending data secrets line acc="${TH[accent]:-$C_CYN}" mark="  " ok=0
  t_r new.pending_word; pending="$T_OUT"
  if [ "$DASH_NW_DATA" -eq 1 ]; then t_r new.data_existing; else t_r new.data_new; fi
  data="$T_OUT"
  if dash_nw_gen_ok && [ "$DASH_NW_GEN" -eq 1 ]; then t_r new.secrets_generated; else t_r new.secrets_manual; fi
  secrets="$T_OUT"
  dash_nw_sel_csv
  dash_nw_trim "$DASH_NW_IP"
  t_r new.summary "$DASH_NW_NAME" "$DASH_NW_CSV" "$data" "${DASH_NW_TAG[s0]:-$pending}" "${DASH_NW_TAG[s1]:-$pending}" "${DASH_NW_T:-$pending}" "$secrets"
  DASH_NW_R+=("")
  while IFS= read -r line; do DASH_NW_R+=("$line"); done <<< "$T_OUT"
  DASH_NW_R+=("")
  if dash_nw_ready; then ok=1; t_r tui.nw.sum.ready; DASH_NW_R+=(" ${DASH_SYM[ok]} $T_OUT")
  else t_r tui.nw.sum.blocked "$DASH_NW_WHY"; DASH_NW_R+=(" ${DASH_SYM[warn]} $C_YEL$T_OUT$C_OFF"); fi
  DASH_NW_R+=("")
  if dash_nw_active button create; then mark="$acc$UI_S_SEL$C_OFF "; fi
  t_r tui.nw.sum.create
  if [ "$ok" -eq 1 ]; then DASH_NW_R+=(" $mark${C_BLD}[ $T_OUT ]$C_OFF"); else DASH_NW_R+=(" $mark${C_DIM}[ $T_OUT ]$C_OFF"); fi
}

# --- Drawing: the panes ----------------------------------------------------------------------------------------

# Right pane: the lines of the current section into DASH_NW_R (and its title into DASH_NW_RT). The blank rows go first when the
# pane is not tall enough, keeping the row of the cursor.
dash_nw_right() { # width height
  local sec="${DASH_NW_SECS[$DASH_NW_SEC]}" i j=0 n
  local -a keep=()
  DASH_NW_R=() DASH_NW_CRI=-1 DASH_NW_CK=0
  t_r "tui.nw.sect.$sec"; DASH_NW_RT="$T_OUT"
  "dash_nw_pane_$sec" $(($1 - 6))
  if [ -n "$DASH_NW_ERR" ]; then
    DASH_NW_R+=("")
    dash_nw_note "$DASH_NW_ERR" "$C_YEL" $(($1 - 6))
  fi
  n=$(($2 - 2))
  if [ "${#DASH_NW_R[@]}" -gt "$n" ]; then
    for i in "${!DASH_NW_R[@]}"; do
      [ -n "${DASH_NW_R[$i]}" ] || continue
      keep+=("${DASH_NW_R[$i]}")
      if [ "$i" -eq "$DASH_NW_CRI" ]; then DASH_NW_CRI="$j"; fi
      j=$((j + 1))
    done
    DASH_NW_R=("${keep[@]}")
  fi
}

# Left pane: the sections with their state, and how many are ready.
dash_nw_left() { # width height
  local i row lab ready=0 total="${#DASH_NW_SECS[@]}"
  DASH_NW_L=()
  for i in "${!DASH_NW_SECS[@]}"; do
    dash_nw_status "$i"
    dash_nw_icon "$DASH_NW_ST"
    if [ "$DASH_NW_ST" = ok ]; then ready=$((ready + 1)); fi
    t_r "tui.nw.sec.${DASH_NW_SECS[$i]}"; dash_runs_padr "$T_OUT" 9; lab="$DASH_PAD"
    row="$DASH_NW_IC $((i + 1)) $lab $C_GRY${DASH_NW_VAL:0:$(($1 - 18))}$C_OFF"
    if [ "$i" -eq "$DASH_NW_SEC" ]; then DASH_NW_L+=("$TUI_SEL$row"); else DASH_NW_L+=("$row"); fi
  done
  DASH_NW_L+=("")
  t_r tui.nw.progress "$ready" "$total"; DASH_NW_L+=("$C_GRY$T_OUT$C_OFF")
  if ! dash_nw_ready; then
    t_r tui.nw.missing "$DASH_NW_WHY"
    dash_wrap "$T_OUT" $(($1 - 4))
    for row in "${DASH_WRAP[@]}"; do DASH_NW_L+=("$C_YEL$row$C_OFF"); done
  fi
}

dash_dialog_wizard() { # body_height
  local bh="$1" W H LW=0 RW top padw i title pad
  local -a lbox=() rbox=()
  dash_nw_wide
  dash_nw_cur
  H=20
  [ "$bh" -ge "$H" ] || H="$bh"
  W=$((TUI_COLS - 2))
  if [ "$DASH_NW_WIDE" -eq 1 ]; then
    [ "$W" -le 104 ] || W=104
    LW=34
  else
    [ "$W" -le 78 ] || W=78
  fi
  RW=$((W - LW))
  dash_nw_right "$RW" "$H"
  title="$DASH_NW_RT"
  if [ "$DASH_NW_WIDE" -eq 0 ]; then
    t_r tui.nw.title; title="$T_OUT $UI_S_DOT $((DASH_NW_SEC + 1))/${#DASH_NW_SECS[@]} $DASH_NW_RT"
  fi
  if [ "$DASH_NW_WIDE" -eq 1 ] && [ "$DASH_NW_FOCUS" = pane ]; then i=1; else i=0; fi
  if [ "$DASH_NW_WIDE" -eq 0 ]; then i=1; fi
  tui_box "$title" "$RW" "$H" DASH_NW_R "" "$i"
  rbox=("${TUI_BOX[@]}")
  if [ "$DASH_NW_WIDE" -eq 1 ]; then
    dash_nw_left "$LW" "$H"
    t_r tui.nw.title
    if [ "$DASH_NW_FOCUS" = list ]; then i=1; else i=0; fi
    tui_box "$T_OUT" "$LW" "$H" DASH_NW_L "" "$i"
    lbox=("${TUI_BOX[@]}")
  fi
  top=$(((bh - H) / 2))
  padw=$(((TUI_COLS - W) / 2))
  printf -v pad '%*s' "$padw" ''
  for ((i = 0; i < top; i++)); do TUI_FRAME+=(""); done
  for i in "${!rbox[@]}"; do
    if [ "$DASH_NW_WIDE" -eq 1 ]; then TUI_FRAME+=("$pad${lbox[$i]}${rbox[$i]}"); else TUI_FRAME+=("$pad${rbox[$i]}"); fi
  done
  # The real cursor of the terminal goes where the text field is (the body starts at the screen row 3 and the box has a border row).
  DASH_NW_CR=0 DASH_NW_CC=0
  if [ "$DASH_NW_CRI" -ge 0 ] && [ "$DASH_NW_CRI" -lt $((H - 2)) ]; then
    DASH_NW_CR=$((3 + top + 1 + DASH_NW_CRI))
    DASH_NW_CC=$((padw + LW + 3 + DASH_NW_CK))
  fi
}

# The last line while the form is open (result in DASH_KBV, like the key bars of the views), and the real cursor.
dash_nw_keys() { # width
  local ud="${DASH_UD:-Up/Dn}" tabw esc
  dash_nw_wide
  dash_nw_cur
  if [ "$DASH_NW_WIDE" -eq 1 ] && [ "$DASH_NW_FOCUS" = list ]; then
    t_r tui.nw.keys.list "$ud"
  else
    if [ "$DASH_NW_WIDE" -eq 1 ]; then t_r tui.nw.w.list; tabw="$T_OUT"; esc="$tabw"; else t_r tui.nw.w.section; tabw="$T_OUT"; t_r tui.nw.w.cancel; esc="$T_OUT"; fi
    case "$DASH_NW_FK" in
      check | radio) t_r tui.nw.keys.check "$ud" "$tabw" "$esc" ;;
      button) t_r tui.nw.keys.button "$ud" "$tabw" "$esc" ;;
      *) t_r tui.nw.keys.text "$ud" "$tabw" "$esc" ;;
    esac
  fi
  dash_keybar "$T_OUT" "$1"
  TUI_CURSOR=""
  if [ "$DASH_NW_FOCUS" = pane ] || [ "$DASH_NW_WIDE" -eq 0 ]; then
    if [ "$DASH_NW_CR" -gt 0 ]; then TUI_CURSOR="$DASH_NW_CR;$DASH_NW_CC"; fi
  fi
}

# --- The contract of lib/screens/registry.sh --------------------------------------------------------------------
scr_wizard_render() { dash_dialog_wizard "$2"; } # width height
scr_wizard_key() { dash_key_wizard "$1"; }
scr_wizard_keys() { dash_nw_keys "$1"; TUI_FRAME+=(" $DASH_KBV"); } # width
scr_wizard_sig() {
  [ "$DASH_MODE" != "wizard" ] || DASH_SIG+="|$DASH_NW_V|$DASH_NW_SEC|$DASH_NW_F|$DASH_NW_FOCUS|$DASH_BUF|$DASH_CUR|$DASH_NW_ERR"
}

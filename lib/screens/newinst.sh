#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_NZ_* variables are read by the step files and the tests; DASH_* belong to lib/cmd/dashboard.sh
# The new-instance wizard, version 2 (mode newinst). Loaded by lib/screens/registry.sh.
#
# It is a sequence of STEPS, each with one question, a proposed answer and a live check, under a progress bar (the stepper of the kit) and
# beside a live preview of what will be created (the files, the variables and the command that is equivalent). Enter always goes on with
# what is proposed; Esc goes back; PgUp / PgDn and a click on the bar move between steps already visited (the digits do too, in the steps
# where nothing is being typed); Tab shows the preview instead of the form on a narrow screen. Nothing is written until the instance is
# created: every answer lives in memory.
#
# THE ENGINE KNOWS NO STEP. A step is a file in lib/screens/newinst/<id>.sh with the hooks below (every one optional but render) and ONE
# line at the end of this file registers it, so adding the steps of the variables, the secrets, the access and the review is adding a
# file and a line, not changing this engine. "the step" is the one that is open; <i> its id; iw / ih the width and height of its box.
#   dash_nzs_<i>_render <iw> <ih>   (required) appends the lines of the form to DASH_NZ_B (the engine fits them: blank lines go first).
#   dash_nzs_<i>_key <key>          a key; return 0 when the step used it, 1 to leave it to the engine (enter, esc, tab, PgUp/PgDn, digits).
#   dash_nzs_<i>_enter              runs when the step is opened (load the fields from the answers).
#   dash_nzs_<i>_state              the state of the step into DASH_NZ_ST (ok | warn | err | pend) and a short value into DASH_NZ_VAL.
#   dash_nzs_<i>_gate               return 1 (with the reason in DASH_NZ_ERR) when Enter must not go past this step.
#   dash_nzs_<i>_typing             return 0 while a text is being typed: the digits are text then, not jumps.
#   dash_nzs_<i>_args               appends to DASH_NZ_ARGV the options this step adds to `new` (and so to the preview's command).
#   dash_nzs_<i>_preview <iw>       appends lines to DASH_NZ_P (the preview) after the ones the engine draws.
# The text of the step is the messages tui.nz.step.<i> (its name in the bar), tui.nz.help.<i> (what it asks, one sentence) and
# tui.nz.keys.<i> (the key bar); the texts of the footer and the common messages are tui.nz.*.
#
# At the end of the last step Enter runs dash_nz_finish: today it creates the instance (dash_nz_create starts `./deltactl new <name> ...`
# as a job of the panel, like the old form did), and the review step replaces that one function.
#
# It opens in place of the old form when the setting TUI_WIZARD=2 (or DELTACTL_WIZARD=2) is on; the old form stays until the new one
# creates, reviews and reports (the next tasks of the plan).

DASH_WIZARD=1                                  # TUI_WIZARD: 2 opens this wizard in place of lib/screens/wizard.sh
DASH_NZ_STEPS=()                               # ids of the steps, in order
DASH_NZ_I=0 DASH_NZ_MAX=0                      # the step that is open (0-based) and the furthest one reached
DASH_NZ_V=0 DASH_NZ_ERR="" DASH_NZ_PREVIEW=0 DASH_NZ_ESC=0
DASH_NZ_NAME="" DASH_NZ_PROPOSED="" DASH_NZ_DATA=0 DASH_NZ_GEN=1 DASH_NZ_SSL=0 DASH_NZ_DOCKER=0 DASH_NZ_ARCH=""
DASH_NZ_ST="" DASH_NZ_VAL="" DASH_NZ_T=""
DASH_NZ_B=() DASH_NZ_P=() DASH_NZ_S=() DASH_NZ_SL=() DASH_NZ_ARGV=()
DASH_NZ_KROW=0 DASH_NZ_KX=2                    # where the steps of the bar are on the screen (for a click)
declare -gA DASH_NZ_SEL=() DASH_NZ_TAG=() DASH_NZ_PORT=() DASH_NZ_PBUSY=() DASH_NZ_TX=() DASH_NZ_NOTE=()

# Registers a step: its id (also the name of its file) in order. Loads its file.
dash_nz_step_register() { # id
  DASH_NZ_STEPS+=("$1")
  # shellcheck source=/dev/null
  source "$ROOT/lib/screens/newinst/$1.sh"
}

# --- Calling the hooks of a step ------------------------------------------------------------------------------------------------

# Runs the hook $2 of the step with index $1 with the arguments that follow. Returns 127 when the step has none, else what the hook returned.
dash_nz_call() { # index hook args...
  local f="dash_nzs_${DASH_NZ_STEPS[$1]}_$2"
  shift 2
  declare -F "$f" > /dev/null || return 127
  "$f" "$@"
}

# The state of the step $1 into DASH_NZ_ST (ok | warn | err | pend) and DASH_NZ_VAL.
dash_nz_state() { # index
  DASH_NZ_ST=pend DASH_NZ_VAL=""
  dash_nz_call "$1" state || true
}

# May Enter go past the step $1? (return 1 with the reason in DASH_NZ_ERR when it must not)
dash_nz_gate_ok() { # index
  local rc=0
  dash_nz_call "$1" gate || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 127 ]
}

# --- Opening ----------------------------------------------------------------------------------------------------------------------

# What the wizard shows about the images, read once when it opens (and again with R): in a subshell, so the tables of the Images view are
# not touched. Prints the records the version picker needs for the image of every service.
dash_nz_images_dump() {
  local s grp rec
  local -a REC=()
  ic_load || { echo "nodocker"; return 0; }
  printf 'arch|%s\n' "$IC_SERVER_ARCH"
  for s in "${KNOWN_SERVICES[@]}"; do
    grp="$s|$(default_repo "$s")"
    REC=()
    ic_picker_rows "$grp" REC
    ic_note "$grp"
    printf 'note|%s|%s\n' "$s" "$IC_NOTE"
    for rec in "${REC[@]}"; do printf 'rec|%s|%s\n' "$s" "$rec"; done
  done
}

# Reads the answer of dash_nz_images_dump into DASH_NZ_ARCH, DASH_NZ_NOTE[service] and the array DASH_NZ_REC_<service> (one record per
# version, as the picker wants them). With no Docker the records are empty and DASH_NZ_DOCKER is 0.
dash_nz_images_apply() { # text
  local kind s rest
  DASH_NZ_ARCH="" DASH_NZ_NOTE=()
  for s in "${KNOWN_SERVICES[@]}"; do
    declare -ga "DASH_NZ_REC_$s"
    local -n _rec="DASH_NZ_REC_$s"
    _rec=()
    unset -n _rec
  done
  ic_picker_texts DASH_NZ_TX
  while IFS='|' read -r kind s rest; do
    case "$kind" in
      nodocker) DASH_NZ_DOCKER=0 ;;
      arch) DASH_NZ_ARCH="$s" ;;
      note) DASH_NZ_NOTE[$s]="$rest" ;;
      rec)
        local -n _r="DASH_NZ_REC_$s"
        [ -z "$rest" ] || _r+=("$rest")
        unset -n _r
        ;;
    esac
  done <<< "$1"
}

# Reads the images again (the key R of the step of the versions).
dash_nz_images_load() {
  local out
  DASH_NZ_DOCKER=1
  out="$(dash_nz_images_dump)"
  dash_nz_images_apply "$out"
}

# Opens the wizard (dash_open_new has already refused while a command runs and asked about the requirements of the server).
dash_nz_open() {
  local s n=1 base p
  if command -v openssl > /dev/null 2>&1; then DASH_NZ_SSL=1; else DASH_NZ_SSL=0; fi
  if inst_docker_names; then DASH_NZ_DOCKER=1; else DASH_NZ_DOCKER=0; fi
  # A name is proposed: the first instancia-N that is free (in the folder, in Compose and among the networks).
  while ! inst_name_clash "instancia-$n"; do n=$((n + 1)); done
  DASH_NZ_PROPOSED="instancia-$n" DASH_NZ_NAME="instancia-$n"
  DASH_NZ_DATA=0 DASH_NZ_GEN=1 DASH_NZ_ERR="" DASH_NZ_ESC=0 DASH_NZ_PREVIEW=0
  DASH_NZ_SEL=() DASH_NZ_TAG=() DASH_NZ_PORT=() DASH_NZ_PBUSY=()
  base="$(next_s0_port)"
  for s in "${KNOWN_SERVICES[@]}"; do
    DASH_NZ_SEL[$s]=1
    p=$((base + ${CAT_OFFSET[$s]:-0}))
    DASH_NZ_PORT[$s]="$p" DASH_NZ_PBUSY[$s]=0
    if [ -n "$(port_owner "$p" "")" ] || host_port_in_use "$p"; then DASH_NZ_PBUSY[$s]=1; fi
  done
  dash_nz_images_load
  DASH_PC_SIG[nzbar]="" DASH_PC_SIG[nzpv]="" DASH_PC_SIG[nzst]=""   # (what Docker said may differ from the last time: the boxes are built again)
  DASH_NZ_I=0 DASH_NZ_MAX=0
  dash_nz_call 0 enter || true
  DASH_MODE=newinst
}

dash_nz_cancel() {
  DASH_MODE=normal
  dash_msg info "$(t tui.msg.cancelled)"
}

# --- Moving ------------------------------------------------------------------------------------------------------------------------

# Opens the step $1 (a number between 0 and the last one).
dash_nz_goto() { # index
  local n="${#DASH_NZ_STEPS[@]}"
  [ "$1" -ge 0 ] && [ "$1" -lt "$n" ] || return 0
  DASH_NZ_I="$1" DASH_NZ_ERR="" DASH_NZ_ESC=0
  [ "$DASH_NZ_I" -le "$DASH_NZ_MAX" ] || DASH_NZ_MAX="$DASH_NZ_I"
  dash_nz_call "$DASH_NZ_I" enter || true
}

# Enter: on to the next step when this one lets it, and at the end of the last one the wizard finishes.
dash_nz_next() {
  DASH_NZ_ERR=""
  dash_nz_gate_ok "$DASH_NZ_I" || return 0
  if [ "$DASH_NZ_I" -lt $((${#DASH_NZ_STEPS[@]} - 1)) ]; then dash_nz_goto $((DASH_NZ_I + 1)); else dash_nz_finish; fi
}

# Has the person changed anything? (to ask before throwing it away)
dash_nz_dirty() { [ "$DASH_NZ_MAX" -gt 0 ] || [ "$DASH_NZ_NAME" != "$DASH_NZ_PROPOSED" ]; }

# Esc: back to the previous step; on the first one, cancel (asking once when something was chosen).
dash_nz_back() {
  DASH_NZ_ERR=""
  if [ "$DASH_NZ_I" -gt 0 ]; then dash_nz_goto $((DASH_NZ_I - 1)); return 0; fi
  if dash_nz_dirty && [ "$DASH_NZ_ESC" -eq 0 ]; then
    DASH_NZ_ESC=1
    t_r tui.nz.esc_again; DASH_NZ_ERR="$T_OUT"
    return 0
  fi
  dash_nz_cancel
}

# --- Creating ----------------------------------------------------------------------------------------------------------------------

# The selected services as "s0,s1" into DASH_NZ_CSV and as an array into DASH_NZ_SL.
DASH_NZ_CSV=""
dash_nz_sel_list() {
  local s
  DASH_NZ_CSV="" DASH_NZ_SL=()
  for s in "${KNOWN_SERVICES[@]}"; do
    [ "${DASH_NZ_SEL[$s]:-0}" -eq 1 ] || continue
    DASH_NZ_SL+=("$s")
    DASH_NZ_CSV+="${DASH_NZ_CSV:+,}$s"
  done
}

# Secrets can be generated for a new instance (an existing one keeps its own) and when openssl is there.
dash_nz_gen_ok() { [ "$DASH_NZ_DATA" -eq 0 ] && [ "$DASH_NZ_SSL" -eq 1 ]; }

# The command `new` that the answers are, into DASH_NZ_ARGV (the name goes in as it is: the preview shows a placeholder when it is empty).
dash_nz_argv() { # name
  local s
  dash_nz_sel_list
  DASH_NZ_ARGV=(new "$1")
  [ -z "$DASH_NZ_CSV" ] || DASH_NZ_ARGV+=(--services "$DASH_NZ_CSV")
  [ "$DASH_NZ_DATA" -eq 0 ] || DASH_NZ_ARGV+=(--existing)
  for s in "${DASH_NZ_SL[@]}"; do
    [ -z "${DASH_NZ_TAG[$s]:-}" ] || DASH_NZ_ARGV+=("--$s-tag" "${DASH_NZ_TAG[$s]}")
  done
  for ((s = 0; s < ${#DASH_NZ_STEPS[@]}; s++)); do dash_nz_call "$s" args || true; done
  if dash_nz_gen_ok && [ "$DASH_NZ_GEN" -eq 1 ]; then DASH_NZ_ARGV+=(--generate-secrets); fi
}

# Starts `new` with the answers as options, as a job of the panel (its output lands in the console like any other command).
dash_nz_create() {
  dash_nz_argv "$DASH_NZ_NAME"
  DASH_MODE=normal
  dash_start_job stay "${DASH_NZ_ARGV[@]}"
}

# The end of the last step: creates when every step lets it; if one does not, opens it (its gate says why).
dash_nz_finish() {
  local i
  if job_running; then DASH_NZ_ERR="$(t tui.msg.busy)"; return 0; fi
  for ((i = 0; i < ${#DASH_NZ_STEPS[@]}; i++)); do
    if ! dash_nz_gate_ok "$i"; then
      t_r tui.nz.blocked "$DASH_NZ_ERR"; dash_msg warn "$T_OUT"
      local why="$DASH_NZ_ERR"
      dash_nz_goto "$i"
      DASH_NZ_ERR="$why"
      return 0
    fi
  done
  dash_nz_create
}

# --- Keys --------------------------------------------------------------------------------------------------------------------------

scr_newinst_key() { # key
  local k="$1" n="${#DASH_NZ_STEPS[@]}"
  DASH_NZ_V=$((DASH_NZ_V + 1))
  [ "$k" = esc ] || DASH_NZ_ESC=0
  if dash_nz_call "$DASH_NZ_I" key "$k"; then return 0; fi
  case "$k" in
    enter | pgdn) dash_nz_next ;;
    pgup) [ "$DASH_NZ_I" -eq 0 ] || dash_nz_goto $((DASH_NZ_I - 1)) ;;
    esc) dash_nz_back ;;
    tab | btab) DASH_NZ_PREVIEW=$((1 - DASH_NZ_PREVIEW)) ;;
    [1-9])
      # (a step already visited; a step that is typing took the digit before)
      if [ "$k" -le "$n" ] && [ $((k - 1)) -le "$DASH_NZ_MAX" ]; then dash_nz_goto $((k - 1)); fi
      ;;
  esac
  return 0
}

# A left click in the bar of steps opens a step already visited.
scr_newinst_click() { # column row
  local i n="${#DASH_NZ_STEPS[@]}" cw="$DASH_NZ_KCW" col
  [ "$cw" -gt 0 ] || return 0
  [ "$2" -ge "$DASH_NZ_KROW" ] && [ "$2" -le $((DASH_NZ_KROW + 1)) ] || return 0
  col=$(($1 - DASH_NZ_KX))
  for ((i = n - 1; i >= 0; i--)); do
    [ "${DASH_NZ_KCOLS[$i]:-}" ] || continue
    if [ "$col" -ge "${DASH_NZ_KCOLS[$i]}" ]; then
      if [ "$i" -le "$DASH_NZ_MAX" ]; then DASH_NZ_V=$((DASH_NZ_V + 1)); dash_nz_goto "$i"; DASH_DIRTY=1; fi
      return 0
    fi
  done
}

# --- Drawing -----------------------------------------------------------------------------------------------------------------------

# The preview into DASH_NZ_P ($1 cells wide): the files that will be created, the variables the answers set and the equivalent command.
# DASH_NZ_PVV has the lines that are variables (they are the ones that go first when the box is short: the files and the command matter more).
DASH_NZ_PVV=()
dash_nz_preview() { # width
  local w="$1" s name="${DASH_NZ_NAME}" dim="${TH[dim]:-}" r="$TH_RESET" line tag
  DASH_NZ_P=() DASH_NZ_PVV=()
  dash_nz_sel_list
  [ -n "$name" ] || { t_r tui.nz.pv.noname; name="$T_OUT"; }
  DASH_NZ_P+=("${C_BLD}instances/$name/$r")
  DASH_NZ_P+=("  .env.instance")
  if [ -n "$DASH_NZ_CSV" ]; then DASH_NZ_PVV+=("${#DASH_NZ_P[@]}"); DASH_NZ_P+=("    ${dim}COMPOSE_PROFILES=$r$DASH_NZ_CSV"); fi
  for s in "${KNOWN_SERVICES[@]}"; do
    DASH_NZ_PVV+=("${#DASH_NZ_P[@]}"); DASH_NZ_P+=("    ${dim}${s^^}_PORT=$r${DASH_NZ_PORT[$s]:-}")
    [ "${DASH_NZ_SEL[$s]:-0}" -eq 1 ] || continue
    tag="${DASH_NZ_TAG[$s]:-}"
    if [ -n "$tag" ]; then line="    ${dim}${s^^}_TAG=$r$tag"; else t_r tui.nz.pv.notag; line="    ${dim}${s^^}_TAG=$T_OUT$r"; fi
    DASH_NZ_PVV+=("${#DASH_NZ_P[@]}"); DASH_NZ_P+=("$line")
  done
  line=" "
  for s in "${KNOWN_SERVICES[@]}"; do line+=" .env.$s"; done
  DASH_NZ_P+=("$line")
  DASH_NZ_P+=("  secrets/  data/")
  if [ "$DASH_NZ_DATA" -eq 1 ]; then t_r tui.nz.pv.existing; else t_r tui.nz.pv.empty; fi
  DASH_NZ_P+=("    $dim$T_OUT$r")
  for ((s = 0; s < ${#DASH_NZ_STEPS[@]}; s++)); do dash_nz_call "$s" preview "$w" || true; done
  DASH_NZ_P+=("")
  dash_nz_argv "$DASH_NZ_NAME"
  [ -n "$DASH_NZ_NAME" ] || DASH_NZ_ARGV[1]="<$name>"
  dash_nz_cmd_lines "$w"
}

# The equivalent command into DASH_NZ_P, wrapped at the options (an option and its value stay together): the first line has `new <name>`,
# the others are indented under it.
dash_nz_cmd_lines() { # width
  local w="$1" acc="${TH[accent]:-}" r="$TH_RESET" a grp="" line g approx="≈"
  [ "${UI_UTF8:-0}" -eq 1 ] || approx="~"
  local -a groups=()
  for a in "${DASH_NZ_ARGV[@]:2}"; do
    if [[ "$a" == --* ]]; then [ -z "$grp" ] || groups+=("$grp"); grp="$a"; else grp+=" $a"; fi
  done
  [ -z "$grp" ] || groups+=("$grp")
  DASH_NZ_P+=("$acc$approx ./deltactl ${DASH_NZ_ARGV[0]} ${DASH_NZ_ARGV[1]}$r")
  line="   "
  for g in "${groups[@]}"; do
    if [ "${#line}" -gt 3 ] && [ $((${#line} + 1 + ${#g})) -gt "$w" ]; then DASH_NZ_P+=("$acc$line$r"); line="   "; fi
    line+=" $g"
  done
  [ "${#line}" -le 3 ] || DASH_NZ_P+=("$acc$line$r")
}

# Fits the preview in $1 rows: the blank lines go first, then the variables (the files and the command stay), then what is left is cut.
dash_nz_pv_fit() { # rows
  local extra i keep=()
  local -A gone=()
  extra=$((${#DASH_NZ_P[@]} - $1))
  [ "$extra" -gt 0 ] || return 0
  for i in "${!DASH_NZ_P[@]}"; do
    [ "$extra" -gt 0 ] || break
    [ -n "${DASH_NZ_P[$i]}" ] || { gone[$i]=1; extra=$((extra - 1)); }
  done
  for i in "${DASH_NZ_PVV[@]}"; do
    [ "$extra" -gt 0 ] || break
    gone[$i]=1; extra=$((extra - 1))
  done
  for i in "${!DASH_NZ_P[@]}"; do [ -n "${gone[$i]:-}" ] || keep+=("${DASH_NZ_P[$i]}"); done
  DASH_NZ_P=("${keep[@]}")
  [ "${#DASH_NZ_P[@]}" -le "$1" ] || DASH_NZ_P=("${DASH_NZ_P[@]:0:$1}")
}

# The state of every step into DASH_NZ_S ($1 cells wide): an icon, its name and its value.
dash_nz_steps_lines() { # width
  local w="$1" i n="${#DASH_NZ_STEPS[@]}" lab val st row
  DASH_NZ_S=()
  for ((i = 0; i < n; i++)); do
    t_r "tui.nz.step.${DASH_NZ_STEPS[$i]}"; lab="$T_OUT"
    if [ "$i" -le "$DASH_NZ_MAX" ] || [ "$i" -eq "$DASH_NZ_I" ]; then dash_nz_state "$i"; st="$DASH_NZ_ST" val="$DASH_NZ_VAL"
    else st=pend val=""; fi
    if [ "$i" -eq "$DASH_NZ_I" ]; then kit_state_icon run; else kit_state_icon "$st"; fi
    printf -v row '%s %-11s %s' "$KIT_ICON" "$lab" "${TH[dim]:-}$val$TH_RESET"
    tui_fit "$row" "$w"
    if [ "$i" -eq "$DASH_NZ_I" ]; then DASH_NZ_S+=("$TUI_SEL$TUI_OUT"); else DASH_NZ_S+=("$TUI_OUT"); fi
  done
}

# Fits the lines of the form in $1 rows: the blank lines go first (the first ones), then what does not fit is cut.
dash_nz_fit() { # rows
  local i j keep=()
  if [ "${#DASH_NZ_B[@]}" -gt "$1" ]; then
    local extra=$((${#DASH_NZ_B[@]} - $1))
    for i in "${!DASH_NZ_B[@]}"; do
      if [ -z "${DASH_NZ_B[$i]}" ] && [ "$extra" -gt 0 ]; then extra=$((extra - 1)); continue; fi
      keep+=("${DASH_NZ_B[$i]}")
    done
    DASH_NZ_B=("${keep[@]}")
  fi
  j="${#DASH_NZ_B[@]}"
  [ "$j" -le "$1" ] || DASH_NZ_B=("${DASH_NZ_B[@]:0:$1}")
}

# What the answers are, as a string, for the signature of the boxes that depend on them (DASH_NZ_AS).
DASH_NZ_AS="" DASH_NZ_KCOLS=() DASH_NZ_KCW=0
DASH_PC_nzbar=() DASH_PC_nzpv=() DASH_PC_nzst=()   # the boxes of the bar, the preview and the steps, kept while their signature holds (dash_pc_get)
dash_nz_asig() {
  local s
  DASH_NZ_AS="$DASH_NZ_I|$DASH_NZ_MAX|$DASH_NZ_NAME|$DASH_NZ_DATA|$DASH_NZ_GEN|$DASH_NZ_DOCKER"
  for s in "${KNOWN_SERVICES[@]}"; do DASH_NZ_AS+="|${DASH_NZ_SEL[$s]:-0}:${DASH_NZ_TAG[$s]:-}"; done
}

# The bar of steps (a box of 4 rows) into TUI_BOX: the states of the steps already visited, the open one and the ones to come.
dash_nz_bar() { # width
  local w="$1" i n="${#DASH_NZ_STEPS[@]}" st lab title nm
  local -a items=() sa=()
  for ((i = 0; i < n; i++)); do
    t_r "tui.nz.step.${DASH_NZ_STEPS[$i]}"; lab="$T_OUT"
    if [ "$i" -eq "$DASH_NZ_I" ]; then st=active
    elif [ "$i" -le "$DASH_NZ_MAX" ]; then
      dash_nz_state "$i"
      case "$DASH_NZ_ST" in ok) st="done" ;; warn) st=warn ;; err) st=err ;; *) st=todo ;; esac
    else st=todo; fi
    items+=("$lab:$st")
  done
  t_r tui.nz.counter $((DASH_NZ_I + 1)) "$n"
  kit_stepper $((w - 3)) $((DASH_NZ_I + 1)) "counter=$T_OUT" "${items[@]}"
  DASH_NZ_KCOLS=("${KS_COLS[@]}") DASH_NZ_KCW="$KS_CW"
  sa=("${KS_LINES[@]}")
  t_r tui.nz.title; title="$T_OUT"
  nm="${DASH_NZ_NAME}"
  kit_box "$w" 4 sa "chips=$title" ${nm:+"status=$nm"}
  TUI_BOX=("${KIT_BOX[@]}")
}

scr_newinst_render() { # width height
  local w="$1" h="$2" n="${#DASH_NZ_STEPS[@]}" i st lab sh=4 hb lw=0 rw=0 wide=0 iw ih fw pbh=0 sbh=0 title foot back nxt line bsig
  local -a items=() left=() right=() out=() errl=() pv=() sb=()
  dash_nz_asig
  bsig="$w|$h|$DASH_LANG_N|${UI_UTF8:-0}|${TH_NAME:-}|$DASH_NZ_AS"
  if [ "$h" -ge 14 ]; then
    if ! dash_pc_get nzbar "$bsig"; then dash_nz_bar "$w"; dash_pc_put nzbar "$bsig"; fi
    out=("${TUI_BOX[@]}")
    DASH_NZ_KROW=4 DASH_NZ_KX=2
  else
    # (a short screen: the bar is two plain lines, not a box)
    sh=2
    for ((i = 0; i < n; i++)); do
      t_r "tui.nz.step.${DASH_NZ_STEPS[$i]}"; lab="$T_OUT"
      if [ "$i" -eq "$DASH_NZ_I" ]; then st=active
      elif [ "$i" -le "$DASH_NZ_MAX" ]; then
        dash_nz_state "$i"
        case "$DASH_NZ_ST" in ok) st="done" ;; warn) st=warn ;; err) st=err ;; *) st=todo ;; esac
      else st=todo; fi
      items+=("$lab:$st")
    done
    t_r tui.nz.counter $((DASH_NZ_I + 1)) "$n"
    kit_stepper $((w - 2)) $((DASH_NZ_I + 1)) "counter=$T_OUT" "${items[@]}"
    DASH_NZ_KCOLS=("${KS_COLS[@]}") DASH_NZ_KCW="$KS_CW"
    out=(" ${KS_LINES[0]}" " ${KS_LINES[1]}")
    DASH_NZ_KROW=3 DASH_NZ_KX=2
  fi
  hb=$((h - sh))
  if [ "$hb" -lt 4 ]; then
    while [ "${#out[@]}" -lt "$h" ]; do out+=(""); done
    TUI_FRAME+=("${out[@]:0:$h}")
    return 0
  fi
  # Two columns (the form and, at its right, the preview and the state of the steps) when there is room; else one, and Tab swaps.
  if [ "$w" -ge 100 ] && [ "$hb" -ge 12 ]; then wide=1; lw=$((w * 3 / 5)); rw=$((w - lw)); fi
  if [ "$wide" -eq 1 ]; then fw="$lw"; else fw="$w"; fi
  iw=$((fw - 3)) ih=$((hb - 2))
  if [ "$wide" -eq 1 ] || [ "$DASH_NZ_PREVIEW" -eq 0 ]; then
    DASH_NZ_B=()
    if [ -n "$DASH_NZ_ERR" ]; then
      dash_wrap "$DASH_NZ_ERR" "$iw"
      errl=("${DASH_WRAP[@]}")
      ih=$((ih - ${#errl[@]} - 1))
    fi
    dash_nz_call "$DASH_NZ_I" render "$iw" "$ih" || true
    dash_nz_fit "$ih"
    if [ "${#errl[@]}" -gt 0 ]; then
      DASH_NZ_B+=("")
      kit_state_icon warn
      for line in "${errl[@]}"; do DASH_NZ_B+=("${TH[warn]:-}$line$TH_RESET"); done
    fi
    t_r "tui.nz.step.${DASH_NZ_STEPS[$DASH_NZ_I]}"; title="$((DASH_NZ_I + 1)) $UI_S_DOT $T_OUT"
    t_r tui.nz.foot.back; back="$T_OUT"
    if [ "$DASH_NZ_I" -lt $((n - 1)) ]; then t_r tui.nz.foot.next; else t_r tui.nz.foot.create; fi
    nxt="$T_OUT"
    foot="{Esc} $back|{Enter} $nxt"
    if [ "$wide" -eq 0 ]; then t_r tui.nz.foot.preview; foot+="|{Tab} $T_OUT"; fi
    kit_box "$fw" "$hb" DASH_NZ_B "chips=$title" "footer=$foot" focus=1
    left=("${KIT_BOX[@]}")
  fi
  if [ "$wide" -eq 1 ] || [ "$DASH_NZ_PREVIEW" -eq 1 ]; then
    if [ "$wide" -eq 1 ]; then fw="$rw"; else fw="$w"; fi
    sbh=0 pbh="$hb"
    if [ "$wide" -eq 1 ] && [ $((hb - n - 2)) -ge 8 ]; then sbh=$((n + 2)) pbh=$((hb - sbh)); fi
    if dash_pc_get nzpv "$bsig|$wide|$pbh|$fw"; then right=("${TUI_BOX[@]}")
    else
      dash_nz_preview $((fw - 3))
      dash_nz_pv_fit $((pbh - 2))
      pv=("${DASH_NZ_P[@]}")
      t_r tui.nz.preview
      if [ "$wide" -eq 1 ]; then
        kit_box "$fw" "$pbh" pv "chips=$T_OUT"
      else
        title="$T_OUT"; t_r tui.nz.foot.back; back="$T_OUT"; t_r tui.nz.foot.form
        kit_box "$fw" "$pbh" pv "chips=$title" "footer={Tab} $T_OUT|{Esc} $back" focus=1
      fi
      right=("${KIT_BOX[@]}")
      TUI_BOX=("${right[@]}"); dash_pc_put nzpv "$bsig|$wide|$pbh|$fw"
    fi
    if [ "$sbh" -gt 0 ]; then
      if dash_pc_get nzst "$bsig|$sbh|$fw"; then right+=("${TUI_BOX[@]}")
      else
        dash_nz_steps_lines $((fw - 3))
        sb=("${DASH_NZ_S[@]}")
        t_r tui.nz.steps
        kit_box "$fw" "$sbh" sb "chips=$T_OUT"
        TUI_BOX=("${KIT_BOX[@]}"); dash_pc_put nzst "$bsig|$sbh|$fw"
        right+=("${KIT_BOX[@]}")
      fi
    fi
  fi
  if [ "$wide" -eq 1 ]; then
    for ((i = 0; i < hb; i++)); do out+=("${left[$i]:-}${right[$i]:-}"); done
  elif [ "$DASH_NZ_PREVIEW" -eq 1 ]; then out+=("${right[@]}")
  else out+=("${left[@]}"); fi
  while [ "${#out[@]}" -lt "$h" ]; do out+=(""); done
  TUI_FRAME+=("${out[@]:0:$h}")
}

# The key bar: the hints of the step that is open.
scr_newinst_keys() { # width
  t_r "tui.nz.keys.${DASH_NZ_STEPS[$DASH_NZ_I]}" "${DASH_UD:-Up/Dn}"
  dash_keybar "$T_OUT" "$1"
  TUI_FRAME+=(" $DASH_KBV")
  TUI_CURSOR=""
}

scr_newinst_sig() {
  [ "$DASH_MODE" != "newinst" ] || DASH_SIG+="|$DASH_NZ_V|$DASH_NZ_I|$DASH_NZ_MAX|$DASH_NZ_PREVIEW|$DASH_NZ_ERR"
}

# --- The steps: ONE line each, in order ---------------------------------------------------------------------------------------------
dash_nz_step_register name
dash_nz_step_register services
dash_nz_step_register versions
dash_nz_step_register data

#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # KEE_* are read by the screens that host the editor and by the tests
# UI kit: the editor of the environment variables of an instance. Sourced after lib/ui/kit/field.sh, state.sh, wrap.sh and box.sh, and after
# lib/core/envschema.sh and lib/core/envedit.sh (they say what each variable is and write it); pure Bash, no fork per frame or per key.
# It is ONE component for every place that edits variables: the Variables screen of the panel, the new-instance wizard (step 5) and the
# Variables tab of an instance workspace. The host gives it the keyboard (a mode of the panel: here the one-letter keys are the editor's,
# `d` is "default", not "diagnose") and a place to draw; the editor owns the rest.
#
# What it shows: the variables of the instance grouped by file (.env.instance, .env.s0, .env.s1...), each group collapsible, with how many are
# still to fill in and whether the file changed since the last deploy (↻); one row per variable (state icon, name, value, a note); the
# description of the variable under the cursor, to the right of the list when there is room and under it when there is not; the live
# validation of what is being typed. A secret is never drawn: its value is a fixed run of dots until `r` shows it for a few seconds.
# A `fixed` variable (the compose or the image sets it) is never listed, so it cannot be edited. Optional variables that are fine are the
# "advanced" ones: `a` shows them.
#
# What it never does: write a file while you type. Changes are STAGED (KEE_VAL against KEE_BASE) and written together by `s` (or `u`, which
# then asks the host to deploy), through lib/core/envedit.sh (atomic, comments and order kept, mode 600 for a secret); a value that does not
# pass its validator is refused before anything is written. Leaving with staged changes asks first. Nothing here prints a secret value.
#
# Opening it:
#   kee_open <instance>              the files of an instance that exists on disk (values read once)
#   kee_init <instance> <file>...    a model with no disk behind it (the wizard): empty values; kee_put <file> <key> <value> fills one
# Keys (the host calls it with the names tui_key produces; it returns 0 when it used the key, 1 when the host must handle it):
#   kee_key <key>        then read KEE_ACTION (leave | deploy | prev | next | "") and KEE_NOTE_KIND / KEE_NOTE (a message for the status line)
#   navigation: up down (k j) pgup pgdn home end · Enter / Space / right / left on a file fold it · Enter on a variable edits it
#   g  generate a value (asks first when there is one; the same value in every file that shares the variable)   d  its default value
#   r  show a secret for a few seconds   a  show / hide the advanced ones   s  save   u  save and deploy   [ ]  other instance   Esc  leave
#   while a value is typed (a MODAL over the list, with the variable's description and the live validation): the field keys (kit_field_key,
#   a paste included); Enter accepts it if it validates, Esc cancels, Tab shows or hides a secret, Ctrl+G generates one, Ctrl+U clears.
#   Opening the modal IS asking to see the value: it shows what the variable has now (a secret too; Tab hides it, for a shared screen).
# Drawing:
#   kee_render <width> <height> [option=value ...]   -> KEE_BOX (the lines, exactly <width> cells each, <height> lines)
#     chips=a|b   chips in the top border (default: the instance name)       focus=1   focused look
#     side=auto|0|1   the description card at the right (auto: from 100 columns)
#   kee_footer_chips -> KEE_FOOTER (the actions, as the box footer wants them)   kee_status -> KEE_STATUS (the chip at the right of the top)
#   kee_hint <width> -> KEE_HINT  the last line of the screen: the keys for what the editor is doing now
# Results to read: KEE_N_CHANGED (staged), KEE_N_TODO (to fill in), KEE_N_PENDING (files not deployed), KEE_REV (changes at every mutation:
# the host puts it in the signature of the frame).

declare -gA KEE_VAL=() KEE_BASE=() KEE_ST=() KEE_MSG=() KEE_FOLD=() KEE_FIDS=() KEE_DEPLOY=()
KEE_INST="" KEE_DISK=0 KEE_FILES=() KEE_ROWS=() KEE_SEL=0 KEE_SELROW="" KEE_TOP=0 KEE_ADV=0
KEE_EDIT=0 KEE_EDIT_ID="" KEE_EDIT_ST="pend" KEE_EDIT_MSG=""
KEE_EDIT_SHOW=1 KEE_EDIT_GEN="" KEE_MODAL=()   # (the modal: is the value of a secret shown, the value Ctrl+G made, its lines)
# The modal that asks for the path of a file of secrets/ (key `f` on a variable that points to /run/secrets/<name>): KEE_EDIT_KIND=file while it is
# open; Enter leaves KEE_ACTION=secfile with the name in KEE_FILE_NAME, the path in KEE_FILE_SRC and KEE_FILE_FORCE=1 when a file is there already.
# KEE_FST[id] is the state of the file of a variable (ok | missing | invalid) on a model with a disk; KEE_FILEWAIT waits for the command that loads it.
KEE_EDIT_KIND="" KEE_FILE_NAME="" KEE_FILE_SRC="" KEE_FILE_FORCE=0 KEE_FILEWAIT=0 KEE_FILE_CI=-1 KEE_SF_NAME=""
declare -gA KEE_FST=()
KEE_PROMPT="" KEE_PROMPT_ID="" KEE_PROMPT_KIND=""
KEE_REVEAL_ID="" KEE_REVEAL_UNTIL=0 KEE_REVEAL_SECONDS=10
KEE_N_CHANGED=0 KEE_N_TODO=0 KEE_N_PENDING=0 KEE_N_HIDDEN=0 KEE_N_VISIBLE=0 KEE_REV=0 KEE_N_SYNC=0
KEE_ACTION="" KEE_NOTE="" KEE_NOTE_KIND="" KEE_COMMIT_BAD=() KEE_COMMIT_FAIL="" KEE_COMMIT_N=0
KEE_BOX=() KEE_FOOTER="" KEE_STATUS="" KEE_HINT=""
# The lines of the variable rows, kept while nothing of what they show changes (the cursor moving does not): drawing a row costs more than
# everything else of a frame. KEE_GEN counts the changes of what rows show (a value, a state, a revealed secret); the key also holds what the
# drawing depends on (width, name column, language, glyphs and colours).
declare -gA KEE_LC=()
KEE_LC_KEY="" KEE_GEN=0
KEE_PAGE=10   # rows a PgUp / PgDn moves (the renderer updates it to the height it drew)
KEE_UD="↑↓"   # the arrows of the hint line (the host sets its own, with the ASCII fallback)

kee_touch() { KEE_REV=$((KEE_REV + 1)); }
kee_changed() { KEE_GEN=$((KEE_GEN + 1)); kee_touch; }   # what the rows show changed

kee_reset() {
  KEE_VAL=() KEE_BASE=() KEE_ST=() KEE_MSG=() KEE_FOLD=() KEE_FIDS=() KEE_DEPLOY=()
  KEE_INST="" KEE_DISK=0 KEE_FILES=() KEE_ROWS=() KEE_SEL=0 KEE_SELROW="" KEE_TOP=0 KEE_ADV=0
  KEE_EDIT=0 KEE_EDIT_ID="" KEE_PROMPT="" KEE_PROMPT_ID="" KEE_PROMPT_KIND="" KEE_REVEAL_ID="" KEE_REVEAL_UNTIL=0
  KEE_N_CHANGED=0 KEE_N_TODO=0 KEE_N_PENDING=0 KEE_N_HIDDEN=0 KEE_N_VISIBLE=0 KEE_N_SYNC=0
  KEE_ACTION="" KEE_NOTE="" KEE_NOTE_KIND="" KEE_COMMIT_BAD=() KEE_COMMIT_FAIL="" KEE_COMMIT_N=0
  KEE_LC=() KEE_LC_KEY=""
  KEE_EDIT_KIND="" KEE_FILE_FORCE=0 KEE_FILEWAIT=0 KEE_FST=()
  kee_changed
}

# Does the variable point to a file of secrets/ (the catalog lists it and its value is /run/secrets/<name>)? KEE_SF_NAME is the name of the file.
kee_secfile_of() { # id
  local id="$1" svc="${1%%|*}" key="${1#*|}"
  KEE_SF_NAME=""
  svc="${svc#.env.}"
  case " ${CAT_SECRET_FILES[$svc]:-} " in *" $key "*) ;; *) return 1 ;; esac
  [[ "${KEE_VAL[$id]:-}" == /run/secrets/?* ]] || return 1
  KEE_SF_NAME="${KEE_VAL[$id]#/run/secrets/}"
}

# The ids (<file>|<KEY>) of the variables of each file that the editor lists: all but the fixed ones.
kee_build() {
  local f id ids
  KEE_FIDS=()
  for f in "${KEE_FILES[@]}"; do
    ids=""
    for id in "${ENV_IDS[@]}"; do
      [ "${ENV_FILE[$id]}" = "$f" ] && [ "${ENV_TYPE[$id]}" != fixed ] && ids+="$id "
    done
    KEE_FIDS[$f]="${ids% }"
  done
}

# State and message of one variable from the value in the model (the state is what lib/core/envedit.sh says: ok warn invalid missing example
# default unset).
kee_eval() { # id
  local id="$1"
  envedit_state_value_r "$KEE_INST" "${id%%|*}" "${id#*|}" "${KEE_VAL[$id]:-}"
  KEE_ST[$id]="$ED_STATE"
  case "$ED_STATE" in
    invalid | warn) KEE_MSG[$id]="$EV_MSG" ;;
    *) KEE_MSG[$id]="" ;;
  esac
}

# Evaluates every variable, counts, and rebuilds the visible rows.
kee_refresh() {
  local f id
  local -a ids=()
  KEE_N_TODO=0 KEE_N_CHANGED=0
  for f in "${KEE_FILES[@]}"; do
    read -ra ids <<< "${KEE_FIDS[$f]:-}"
    for id in "${ids[@]}"; do
      kee_eval "$id"
      case "${KEE_ST[$id]}" in missing | invalid | example) KEE_N_TODO=$((KEE_N_TODO + 1)) ;; esac
      [ "${KEE_VAL[$id]:-}" = "${KEE_BASE[$id]:-}" ] || KEE_N_CHANGED=$((KEE_N_CHANGED + 1))
      # (the state of the file a variable points to: only where the folder of the instance exists)
      unset 'KEE_FST[$id]'
      if [ "$KEE_DISK" -eq 1 ] && kee_secfile_of "$id"; then
        sf_state_r "$KEE_INST" "$KEE_SF_NAME" || true
        KEE_FST[$id]="$SF_ST"
      fi
    done
  done
  kee_rows
  kee_changed
}

# Folds the files with nothing to fix when another one has something (the first look at a big instance is the part that needs you).
kee_autofold() {
  local f id any=0 has
  local -a ids=()
  for f in "${KEE_FILES[@]}"; do
    read -ra ids <<< "${KEE_FIDS[$f]:-}"
    for id in "${ids[@]}"; do case "${KEE_ST[$id]:-}" in missing | invalid | example | warn) any=1 ;; esac; done
  done
  [ "$any" -eq 1 ] || return 0
  for f in "${KEE_FILES[@]}"; do
    has=0
    read -ra ids <<< "${KEE_FIDS[$f]:-}"
    for id in "${ids[@]}"; do case "${KEE_ST[$id]:-}" in missing | invalid | example | warn) has=1 ;; esac; done
    [ "$has" -eq 1 ] || KEE_FOLD[$f]=1
  done
  kee_rows
}

# Is the variable listed now? Required ones always; optional ones that are fine are "advanced" (shown with `a`); anything that needs a look
# (not valid, a warning, still the template's CAMBIAR) or that is being changed always is.
kee_visible() { # id
  [ "$KEE_ADV" -eq 1 ] && return 0
  [ "${ENV_TYPE[$1]:-}" = req ] && return 0
  case "${KEE_ST[$1]:-}" in missing | invalid | warn | example) return 0 ;; esac
  [ "${KEE_VAL[$1]:-}" = "${KEE_BASE[$1]:-}" ] || return 0
  return 1
}

# The rows of the list: "F|<file>" for a file and "V|<id>" for a variable. The cursor stays on the same row when it is still there.
kee_rows() {
  local f id i sel="${KEE_ROWS[$KEE_SEL]:-$KEE_SELROW}"
  local -a ids=()
  KEE_ROWS=() KEE_N_HIDDEN=0 KEE_N_VISIBLE=0
  for f in "${KEE_FILES[@]}"; do
    KEE_ROWS+=("F|$f")
    read -ra ids <<< "${KEE_FIDS[$f]:-}"
    for id in "${ids[@]}"; do
      if kee_visible "$id"; then
        KEE_N_VISIBLE=$((KEE_N_VISIBLE + 1))
        [ "${KEE_FOLD[$f]:-0}" -eq 1 ] || KEE_ROWS+=("V|$id")
      else
        KEE_N_HIDDEN=$((KEE_N_HIDDEN + 1))
      fi
    done
  done
  KEE_N_PENDING=0
  for f in "${KEE_FILES[@]}"; do [ "${KEE_DEPLOY[$f]:-}" != pending ] || KEE_N_PENDING=$((KEE_N_PENDING + 1)); done
  for i in "${!KEE_ROWS[@]}"; do
    [ "${KEE_ROWS[$i]}" != "$sel" ] || { KEE_SEL="$i"; break; }
  done
  [ "$KEE_SEL" -lt "${#KEE_ROWS[@]}" ] || KEE_SEL=$((${#KEE_ROWS[@]} - 1))
  [ "$KEE_SEL" -ge 0 ] || KEE_SEL=0
  KEE_SELROW="${KEE_ROWS[$KEE_SEL]:-}"
}

# Opens the editor on an instance that exists on disk.
kee_open() { # instance
  local f id key line
  local -a ids=()
  local -A raw=()
  kee_reset
  KEE_INST="$1" KEE_DISK=1
  envschema_load
  envedit_files_r "$1"
  KEE_FILES=("${ENVEDIT_FILES[@]}")
  kee_build
  # Each file is read once (the last line of a key wins, as get_var_r reads it), not once per variable.
  for f in "${KEE_FILES[@]}"; do
    raw=()
    while IFS= read -r line || [ -n "$line" ]; do
      [[ "$line" == [A-Za-z_]*=* ]] || continue
      line="${line%$'\r'}"
      raw[${line%%=*}]="${line#*=}"
    done < "$INSTANCES_DIR/$1/$f"
    read -ra ids <<< "${KEE_FIDS[$f]:-}"
    for id in "${ids[@]}"; do
      key="${id#*|}"
      KEE_VAL[$id]="${raw[$key]:-}" KEE_BASE[$id]="${raw[$key]:-}"
    done
  done
  kee_refresh
  # variables the templates have and the files do not (an instance made before they existed): the chip says how many, A adds them
  envsync_files_r "$1" > /dev/null
  KEE_N_SYNC="$ENVSYNC_TOTAL"
  kee_autofold   # (it uses the states just evaluated and builds the rows again)
  kee_changed
}

# A model with no files on disk (the wizard): the files it will create, every value empty.
kee_init() { # instance file...
  local f id
  local -a ids=()
  kee_reset
  KEE_INST="$1" KEE_DISK=0
  shift
  envschema_load
  KEE_FILES=("$@")
  kee_build
  for f in "${KEE_FILES[@]}"; do
    read -ra ids <<< "${KEE_FIDS[$f]:-}"
    for id in "${ids[@]}"; do KEE_VAL[$id]="" KEE_BASE[$id]=""; done
  done
  kee_refresh
}

# Puts a value in the model (staged: it counts as changed against the base). Returns 1 when the file or the key is not in the editor.
kee_put() { # file key value
  local id="$1|$2"
  [ -n "${KEE_VAL[$id]+x}" ] || return 1
  KEE_VAL[$id]="$3"
  kee_refresh
}

# Is there anything staged?
kee_dirty() { [ "$KEE_N_CHANGED" -gt 0 ]; }

# Hides a revealed secret when its time is up. Returns 0 when something changed (the host redraws).
kee_tick() {
  local ch=1
  # The command that loads a file ended: what the files are is read again.
  if [ "$KEE_FILEWAIT" -eq 1 ] && declare -F job_running > /dev/null && ! job_running; then KEE_FILEWAIT=0; kee_refresh; ch=0; fi
  if [ -n "$KEE_REVEAL_ID" ] && [ "$SECONDS" -ge "$KEE_REVEAL_UNTIL" ]; then KEE_REVEAL_ID=""; kee_changed; ch=0; fi
  return "$ch"
}

# ---------- what a variable says about itself ----------

# The text of a key with {1} {2} {3} filled in, into KEE_T.
KEE_T=""
kee_t() { # key [a] [b] [c]
  t_r "$1" "${2:-}" "${3:-}" "${4:-}"
  KEE_T="$T_OUT"
}

# The icon state of a variable state (what the rows and the card draw).
kee_icon_state() { # state
  case "$1" in
    ok) printf 'ok' ;;
    invalid) printf 'err' ;;
    missing | example | warn) printf 'warn' ;;
    *) printf 'pend' ;;
  esac
}

# The note at the right of a row (what the state means) into KEE_NOTE_TXT and its colour state into KEE_NOTE_ST.
KEE_NOTE_TXT="" KEE_NOTE_ST=""
kee_row_note() { # id
  local id="$1" st="${KEE_ST[$1]:-}"
  KEE_NOTE_TXT="" KEE_NOTE_ST=dim
  case "$st" in
    missing) kee_t envview.note.required; KEE_NOTE_TXT="$KEE_T" KEE_NOTE_ST=warn ;;
    example) kee_t envview.note.example; KEE_NOTE_TXT="$KEE_T" KEE_NOTE_ST=warn ;;
    invalid) KEE_NOTE_TXT="${KEE_MSG[$id]}" KEE_NOTE_ST=err ;;
    warn) KEE_NOTE_TXT="${KEE_MSG[$id]}" KEE_NOTE_ST=warn ;;
    unset | default) kee_t envview.note.optional; KEE_NOTE_TXT="$KEE_T" ;;
  esac
  # A variable that points to a file of secrets/: whether the file is there (the key `f` loads it).
  case "${KEE_FST[$id]:-}" in
    missing) kee_t envview.note.file_missing; KEE_NOTE_TXT="$KEE_T" KEE_NOTE_ST=warn ;;
    invalid) kee_t envview.note.file_invalid; KEE_NOTE_TXT="$KEE_T" KEE_NOTE_ST=err ;;
    ok) kee_t envview.note.file_ok; KEE_NOTE_TXT="$KEE_T" KEE_NOTE_ST=ok ;;
  esac
  if [ "${KEE_VAL[$id]:-}" != "${KEE_BASE[$id]:-}" ] && [ "$st" != invalid ]; then
    kee_t envview.note.changed; KEE_NOTE_TXT="$KEE_T" KEE_NOTE_ST=info
  fi
}

# A Mongo URI with the password hidden (the scheme, the user, the host and the database stay readable) into KEE_URI. Returns 1 when the text
# is not a URI of Mongo or has no password in it: there is nothing to hide then.
KEE_URI=""
kee_uri_masked() { # value
  local v="$1" rest auth cred
  [[ "$v" == mongodb://* || "$v" == mongodb+srv://* ]] || return 1
  rest="${v#*://}"
  auth="${rest%%[/?]*}"                      # (the part before the first / or ?: a password may hold an @, so the host is after the LAST one)
  [[ "$auth" == *@* ]] || return 1
  cred="${auth%@*}"
  [[ "$cred" == *:* ]] || return 1
  KEE_URI="${v%%://*}://${cred%%:*}:${UI_S_MASK}${UI_S_MASK}${UI_S_MASK}${UI_S_MASK}@${auth##*@}${rest:${#auth}}"
}

# The value of a row as it is shown, into KEE_SHOWN (coloured): a secret is a fixed run of dots (its length says nothing) unless revealed. A
# Mongo URI shows everything but its password, and a URI with no password is not hidden at all.
KEE_SHOWN=""
kee_shown() { # id
  local id="$1" v="${KEE_VAL[$1]:-}" run
  if [ -z "$v" ]; then
    if [ "${KEE_ST[$id]:-}" = default ]; then kee_t envview.default_is "${ENV_DEFAULT[$id]}"; KEE_SHOWN="${TH[faint]:-}$KEE_T$TH_RESET"
    else kee_t envview.empty; KEE_SHOWN="${TH[faint]:-}$KEE_T$TH_RESET"; fi
    return 0
  fi
  if [ "${ENV_SECRET[$id]:-0}" = 1 ]; then
    if [ "$KEE_REVEAL_ID" = "$id" ]; then KEE_SHOWN="${TH[warn]:-}$UI_S_SECRET $v$TH_RESET"; return 0; fi
    if [ "${ENV_VALIDATOR[$id]:-}" = mongo-uri ]; then
      if kee_uri_masked "$v"; then KEE_SHOWN="${TH[dim]:-}$UI_S_SECRET$TH_RESET $KEE_URI"; else KEE_SHOWN="$v"; fi
      return 0
    fi
    printf -v run '%*s' 10 ''
    KEE_SHOWN="${TH[dim]:-}$UI_S_SECRET ${run// /$UI_S_MASK}$TH_RESET"
    return 0
  fi
  KEE_SHOWN="$v"
}

# ---------- keys ----------

# Moves the cursor by n rows (clamped).
kee_move() { # delta
  KEE_SEL=$((KEE_SEL + $1))
  [ "$KEE_SEL" -lt "${#KEE_ROWS[@]}" ] || KEE_SEL=$((${#KEE_ROWS[@]} - 1))
  [ "$KEE_SEL" -ge 0 ] || KEE_SEL=0
  KEE_SELROW="${KEE_ROWS[$KEE_SEL]:-}"
  kee_touch
}

# The id under the cursor ("" on a file row), and the file of the row.
KEE_CUR_ID="" KEE_CUR_FILE=""
kee_cur() {
  local r="${KEE_ROWS[$KEE_SEL]:-}"
  KEE_CUR_ID="" KEE_CUR_FILE=""
  case "$r" in
    F\|*) KEE_CUR_FILE="${r#F|}" ;;
    V\|*) KEE_CUR_ID="${r#V|}" KEE_CUR_FILE="${KEE_CUR_ID%%|*}" ;;
  esac
}

kee_note() { KEE_NOTE_KIND="$1" KEE_NOTE="$2"; }

# Opens the modal to type the value of the variable under the cursor. It starts with what the variable has now, a secret included (opening it is
# asking to see it; Tab hides it again). The template's CAMBIAR… is not a value to edit: it starts empty.
kee_edit_start() { # id
  local id="$1"
  KEE_EDIT=1 KEE_EDIT_ID="$id" KEE_EDIT_SHOW=1 KEE_EDIT_GEN="" KEE_EDIT_KIND=""
  if [[ "${KEE_VAL[$id]:-}" == *CAMBIAR* ]]; then KF_VALUE=""
  else KF_VALUE="${KEE_VAL[$id]:-}"; fi
  KF_CUR="${#KF_VALUE}"
  kee_edit_check
  kee_touch
}

# The live validation of the value being typed: KEE_EDIT_ST (ok warn err pend) and KEE_EDIT_MSG (what the validator says; never the value).
kee_edit_check() {
  local id="$KEE_EDIT_ID"
  envedit_state_value_r "$KEE_INST" "${id%%|*}" "${id#*|}" "$KF_VALUE"
  KEE_EDIT_MSG=""
  case "$ED_STATE" in
    invalid) KEE_EDIT_ST=err KEE_EDIT_MSG="$EV_MSG" ;;
    warn) KEE_EDIT_ST=warn KEE_EDIT_MSG="$EV_MSG" ;;
    missing) KEE_EDIT_ST=err; kee_t envview.note.required; KEE_EDIT_MSG="$KEE_T" ;;
    example) KEE_EDIT_ST=warn; kee_t envview.note.example; KEE_EDIT_MSG="$KEE_T" ;;
    ok) KEE_EDIT_ST=ok ;;
    *) KEE_EDIT_ST=pend ;;
  esac
}

# `f` on a variable that points to a file of secrets/: asks for the path of the file (a model with a disk) or hands the question to the host (the
# wizard has no folder yet: it is answered in its step of the files).
kee_file_open() {
  local id="$KEE_CUR_ID"
  [ -n "$id" ] || return 0
  if ! kee_secfile_of "$id"; then kee_t envview.not_file "${id#*|}"; kee_note info "$KEE_T"; return 0; fi
  KEE_FILE_NAME="$KEE_SF_NAME" KEE_FILE_SRC="" KEE_FILE_FORCE=0
  if [ "$KEE_DISK" -eq 0 ]; then KEE_ACTION=secfile; return 0; fi
  [ "${KEE_FST[$id]:-missing}" = missing ] || KEE_FILE_FORCE=1
  KEE_EDIT=1 KEE_EDIT_ID="$id" KEE_EDIT_KIND=file KEE_EDIT_GEN="" KEE_FILE_CI=-1 KF_VALUE="" KF_CUR=0
  kee_file_check
  kee_touch
}

# The live look at the path being typed: does a file exist there? (the content is checked when Enter is pressed)
kee_file_check() {
  local p
  KEE_EDIT_MSG=""
  if [ -z "$KF_VALUE" ]; then KEE_EDIT_ST=pend; return 0; fi
  sf_expand "$KF_VALUE"; p="$SF_PATH"
  if [ -f "$p" ]; then KEE_EDIT_ST=ok; kee_t envview.file.found; KEE_EDIT_MSG="$KEE_T"
  elif [ -d "$p" ]; then KEE_EDIT_ST=err; kee_t envview.file.isdir; KEE_EDIT_MSG="$KEE_T"
  else KEE_EDIT_ST=warn; kee_t envview.file.nofile; KEE_EDIT_MSG="$KEE_T"; fi
}

kee_key_file() { # key
  local k="$1" src n
  case "$k" in
    enter)
      sf_expand "$KF_VALUE"; src="$SF_PATH"
      if [ -z "$src" ]; then kee_t envview.file.empty; kee_note warn "$KEE_T"; return 0; fi
      if ! sf_check "$src"; then kee_t "tui.nz.sec.err_$SF_WHY" "$src"; kee_note err "$KEE_T"; return 0; fi
      KEE_FILE_SRC="$src" KEE_ACTION=secfile KEE_EDIT=0 KEE_EDIT_KIND=""
      kee_touch
      ;;
    esc) KEE_EDIT=0 KEE_EDIT_ID="" KEE_EDIT_KIND=""; kee_touch ;;
    tab)
      # (the files that look like a service account in the usual folders, one after the other)
      sf_candidates
      n="${#SF_CAND[@]}"
      if [ "$n" -eq 0 ]; then kee_t tui.nz.sec.nofound; kee_note info "$KEE_T"; return 0; fi
      KEE_FILE_CI=$(((KEE_FILE_CI + 1) % n))
      KF_VALUE="${SF_CAND[$KEE_FILE_CI]}" KF_CUR="${#KF_VALUE}"
      kee_file_check; kee_touch
      ;;
    *) if kit_field_key "$k"; then kee_file_check; kee_touch; fi ;;
  esac
}

kee_key_edit() { # key
  local id="$KEE_EDIT_ID" k="$1"
  if [ "$KEE_EDIT_KIND" = file ]; then kee_key_file "$k"; return 0; fi
  case "$k" in
    enter)
      kee_edit_check
      if [ "$KEE_EDIT_ST" = err ]; then
        kee_note warn "$(kee_refused_text "$id")"
        return 0
      fi
      KEE_EDIT=0
      if [ -n "$KEE_EDIT_GEN" ] && [ "$KF_VALUE" = "$KEE_EDIT_GEN" ]; then kee_generate_apply "$id" "$KF_VALUE"   # (a shared secret goes to every file)
      else KEE_VAL[$id]="$KF_VALUE"; kee_refresh; fi
      KEE_EDIT_GEN=""
      ;;
    esc) KEE_EDIT=0 KEE_EDIT_ID="" KEE_EDIT_GEN=""; kee_touch ;;
    tab) KEE_EDIT_SHOW=$((1 - KEE_EDIT_SHOW)); kee_touch ;;
    $'\007') kee_edit_generate ;;
    *)
      if kee_field_key_safe "$k"; then kee_edit_check; kee_touch; fi
      ;;
  esac
}

# kit_field_key, but a key it does not edit with (tab, up, down...) is only ignored.
kee_field_key_safe() { kit_field_key "$1"; }

# "<KEY>: <what the validator said>" for the status line, with no value in it.
kee_refused_text() { # id
  kee_t envview.refused "${1#*|}" "$KEE_EDIT_MSG"
  printf '%s' "$KEE_T"
}

# Ctrl+G in the modal: puts a generated value in the field (it is only the variable's when Enter accepts it).
kee_edit_generate() {
  local id="$KEE_EDIT_ID" kind v
  kind="${ENV_GEN[$id]:-}"
  if [ -z "$kind" ]; then kee_t env.no_generator "${id#*|}"; kee_note warn "$KEE_T"; return 0; fi
  v="$(envedit_random "$kind")" || v=""
  if [ -z "$v" ]; then kee_t env.openssl_missing; kee_note err "$KEE_T"; return 0; fi
  KF_VALUE="$v" KF_CUR="${#v}" KEE_EDIT_GEN="$v"
  v=""
  kee_edit_check
  kee_touch
}

# The staged value of a generated secret into every file of the editor that has the variable with the "shared" generator. A value may come in
# $2 (the one generated in the modal); without it a new one is made.
kee_generate_apply() { # id [value]
  local id="$1" key="${1#*|}" kind val f n=0
  kind="${ENV_GEN[$id]:-}"
  val="${2:-}"
  if [ -z "$val" ]; then val="$(envedit_random "$kind")" || val=""; fi
  [ -n "$val" ] || { kee_t env.openssl_missing; kee_note err "$KEE_T"; return 1; }
  if [ "$kind" = shared ]; then
    for f in "${KEE_FILES[@]}"; do
      [ "${ENV_GEN[$f|$key]:-}" = shared ] || continue
      [ -n "${KEE_VAL[$f|$key]+x}" ] || continue
      KEE_VAL[$f|$key]="$val"
      n=$((n + 1))
    done
  else
    KEE_VAL[$id]="$val"
    n=1
  fi
  val=""
  kee_refresh
  kee_t envview.generated "$key"
  kee_note ok "$KEE_T"
}

# `g` on the variable under the cursor.
kee_generate() {
  local id="$KEE_CUR_ID" kind v
  [ -n "$id" ] || return 0
  kind="${ENV_GEN[$id]:-}"
  if [ -z "$kind" ]; then kee_t env.no_generator "${id#*|}"; kee_note warn "$KEE_T"; return 0; fi
  if ! command -v openssl > /dev/null 2>&1; then kee_t env.openssl_missing; kee_note err "$KEE_T"; return 0; fi
  v="${KEE_VAL[$id]:-}"
  # A value that is there (and not the template's CAMBIAR…) is replaced only after asking: the consequence is said first.
  if [ -n "$v" ] && [[ "$v" != *CAMBIAR* ]]; then
    KEE_PROMPT=gen KEE_PROMPT_ID="$id"
    kee_touch
    return 0
  fi
  kee_generate_apply "$id"
}

# `d`: the default value of the variable under the cursor, when it has one.
kee_default() {
  local id="$KEE_CUR_ID"
  [ -n "$id" ] || return 0
  if [ "${ENV_HASDEF[$id]:-0}" = 1 ] && [ -n "${ENV_DEFAULT[$id]:-}" ]; then
    KEE_VAL[$id]="${ENV_DEFAULT[$id]}"
    kee_refresh
    kee_t envview.default_set "${id#*|}"; kee_note ok "$KEE_T"
  else
    kee_t envview.no_default "${id#*|}"; kee_note info "$KEE_T"
  fi
}

# `r`: shows a secret for a few seconds (or hides it).
kee_reveal() {
  local id="$KEE_CUR_ID"
  [ -n "$id" ] || return 0
  if [ "${ENV_SECRET[$id]:-0}" != 1 ]; then kee_t envview.not_secret "${id#*|}"; kee_note info "$KEE_T"; return 0; fi
  if [ "$KEE_REVEAL_ID" = "$id" ]; then KEE_REVEAL_ID=""
  else KEE_REVEAL_ID="$id" KEE_REVEAL_UNTIL=$((SECONDS + KEE_REVEAL_SECONDS)); fi
  kee_changed
}

# Writes what is staged (the disk mode). 0 all written (KEE_COMMIT_N values), 1 refused: a value does not validate and NOTHING was written
# (KEE_COMMIT_BAD has the ids), 2 a file could not be written (the ones written before stay; KEE_COMMIT_FAIL is the file), 3 nothing staged.
kee_commit() {
  local f id n=0 rc
  local -a ids=() changed=()
  KEE_COMMIT_BAD=() KEE_COMMIT_FAIL="" KEE_COMMIT_N=0
  for f in "${KEE_FILES[@]}"; do
    read -ra ids <<< "${KEE_FIDS[$f]:-}"
    for id in "${ids[@]}"; do [ "${KEE_VAL[$id]:-}" = "${KEE_BASE[$id]:-}" ] || changed+=("$id"); done
  done
  [ "${#changed[@]}" -gt 0 ] || return 3
  # Everything is checked first: one bad value stops the whole save, so a file is never left with half of what was asked.
  for id in "${changed[@]}"; do
    envschema_check_r "${id%%|*}" "${id#*|}" "${KEE_VAL[$id]}" "$KEE_INST"
    [ "$EV_RC" -ne 1 ] || KEE_COMMIT_BAD+=("$id")
  done
  [ "${#KEE_COMMIT_BAD[@]}" -eq 0 ] || return 1
  for id in "${changed[@]}"; do
    rc=0
    envedit_save "$KEE_INST" "${id%%|*}" "${id#*|}" "${KEE_VAL[$id]}" || rc=$?
    if [ "$rc" -ne 0 ]; then
      KEE_COMMIT_FAIL="${id%%|*}"
      [ "$rc" -eq 1 ] && KEE_COMMIT_BAD+=("$id")
      kee_refresh
      return 2
    fi
    KEE_BASE[$id]="${KEE_VAL[$id]}"
    n=$((n + 1))
    KEE_COMMIT_N="$n"
  done
  kee_refresh
  return 0
}

# `s` (and the first half of `u`): saves and says what happened. Returns 0 only when everything was written (or there was nothing).
kee_save() {
  local rc=0 names="" id
  kee_commit || rc=$?
  case "$rc" in
    0) kee_t envview.saved "$KEE_COMMIT_N" "$KEE_INST"; kee_note ok "$KEE_T"; return 0 ;;
    3) kee_t envview.nothing; kee_note info "$KEE_T"; return 0 ;;
    1)
      for id in "${KEE_COMMIT_BAD[@]}"; do names+="${names:+, }${id#*|}"; done
      kee_t envview.save_refused "${#KEE_COMMIT_BAD[@]}" "$names"; kee_note err "$KEE_T"
      ;;
    2) kee_t env.write_failed "$KEE_COMMIT_FAIL"; kee_note err "$KEE_T" ;;
  esac
  return 1
}

kee_key_prompt() { # key
  local k="$1" p="$KEE_PROMPT" id="$KEE_PROMPT_ID"
  case "$p" in
    gen)
      case "$k" in
        y | Y | s | S) KEE_PROMPT="" KEE_PROMPT_ID=""; kee_generate_apply "$id" ;;
        *) KEE_PROMPT="" KEE_PROMPT_ID=""; kee_t env.gen_cancelled; kee_note info "$KEE_T"; kee_touch ;;
      esac
      ;;
    leave)
      case "$k" in
        s | S | y | Y) KEE_PROMPT=""; if kee_save; then KEE_ACTION=leave; fi; kee_touch ;;
        d | D) KEE_PROMPT=""; kee_discard; KEE_ACTION=leave; kee_touch ;;
        *) KEE_PROMPT=""; kee_touch ;;
      esac
      ;;
    deploy)
      case "$k" in
        y | Y | s | S) KEE_PROMPT=""; if ! kee_dirty || kee_save; then KEE_ACTION=deploy; fi; kee_touch ;;
        *) KEE_PROMPT=""; kee_touch ;;
      esac
      ;;
  esac
}

# Forgets what is staged: every value goes back to what is saved.
kee_discard() {
  local id
  for id in "${!KEE_VAL[@]}"; do KEE_VAL[$id]="${KEE_BASE[$id]:-}"; done
  KEE_EDIT=0 KEE_EDIT_ID="" KEE_REVEAL_ID=""
  kee_refresh
}

kee_key_nav() { # key
  local k="$1"
  kee_cur
  case "$k" in
    up | k) kee_move -1 ;;
    down | j) kee_move 1 ;;
    pgup) kee_move "-$KEE_PAGE" ;;
    pgdn) kee_move "$KEE_PAGE" ;;
    home) KEE_SEL=0; kee_move 0 ;;
    end) KEE_SEL=$((${#KEE_ROWS[@]} - 1)); kee_move 0 ;;
    enter | space | right | left)
      if [ -n "$KEE_CUR_FILE" ] && [ -z "$KEE_CUR_ID" ]; then
        case "$k" in
          left) KEE_FOLD[$KEE_CUR_FILE]=1 ;;
          right) KEE_FOLD[$KEE_CUR_FILE]=0 ;;
          *) KEE_FOLD[$KEE_CUR_FILE]=$((1 - ${KEE_FOLD[$KEE_CUR_FILE]:-0})) ;;
        esac
        kee_rows; kee_touch
      elif [ -n "$KEE_CUR_ID" ]; then
        case "$k" in
          enter) kee_edit_start "$KEE_CUR_ID" ;;
          left) kee_file_row "$KEE_CUR_FILE"; KEE_SEL="$KEE_FROW"; kee_move 0 ;;
          *) return 1 ;;
        esac
      fi
      ;;
    g) kee_generate ;;
    A) if [ "$KEE_DISK" -eq 1 ] && [ "$KEE_N_SYNC" -gt 0 ]; then KEE_ACTION=sync; else return 1; fi ;;
    f) kee_file_open ;;
    d) kee_default ;;
    r) kee_reveal ;;
    a)
      KEE_ADV=$((1 - KEE_ADV))
      kee_rows
      kee_t envview.adv_"$KEE_ADV" "$KEE_N_HIDDEN"; kee_note info "$KEE_T"
      kee_touch
      ;;
    # (a model with no files behind it, the wizard's, is written by its host: saving and deploying are not the editor's to do)
    s) if [ "$KEE_DISK" -eq 1 ]; then kee_save || true; else return 1; fi ;;
    u) if [ "$KEE_DISK" -eq 1 ]; then KEE_PROMPT=deploy; kee_touch; else return 1; fi ;;   # (with nothing staged it still asks: a deploy restarts the services)
    '[') KEE_ACTION=prev ;;
    ']') KEE_ACTION=next ;;
    esc | q)
      if [ "$KEE_DISK" -eq 1 ] && kee_dirty; then KEE_PROMPT=leave; kee_touch
      elif [ "$k" = esc ]; then KEE_ACTION=leave
      else return 1; fi
      ;;
    *) return 1 ;;
  esac
  return 0
}

# The row index of a file's own row (for `left` on a variable: back to its file) into KEE_FROW.
KEE_FROW=0
kee_file_row() { # file
  local i
  KEE_FROW=0
  for i in "${!KEE_ROWS[@]}"; do [ "${KEE_ROWS[$i]}" != "F|$1" ] || { KEE_FROW="$i"; return 0; }; done
}

# A key for the editor: 0 when it used the key, 1 when the host must handle it.
kee_key() { # key
  KEE_ACTION="" KEE_NOTE="" KEE_NOTE_KIND=""
  if [ -n "$KEE_PROMPT" ]; then kee_key_prompt "$1"; return 0; fi
  if [ "$KEE_EDIT" -eq 1 ]; then kee_key_edit "$1"; return 0; fi
  kee_key_nav "$1"
}

# ---------- drawing ----------

# The chip at the right of the top border: what still needs you, in the colours of the states.
kee_status() {
  local s="" c
  KEE_STATUS=""
  if [ "$KEE_N_TODO" -gt 0 ]; then kee_t envview.status.todo "$KEE_N_TODO"; s="${TH[warn]:-}$KEE_T$TH_RESET"; fi
  if [ "$KEE_N_CHANGED" -gt 0 ]; then
    kee_t envview.status.changed "$KEE_N_CHANGED"; c="${TH[accent]:-}$KEE_T$TH_RESET"
    s+="${s:+ ${TH[dim]:-}$UI_S_DOT$TH_RESET }$c"
  fi
  if [ "$KEE_N_PENDING" -gt 0 ]; then
    kee_t envview.status.pending "$KEE_N_PENDING"; c="${TH[info]:-}$UI_S_SYNC $KEE_T$TH_RESET"
    s+="${s:+ ${TH[dim]:-}$UI_S_DOT$TH_RESET }$c"
  fi
  if [ "$KEE_N_SYNC" -gt 0 ]; then
    kee_t envview.status.sync "$KEE_N_SYNC"; c="${TH[info]:-}$KEE_T$TH_RESET"
    s+="${s:+ ${TH[dim]:-}$UI_S_DOT$TH_RESET }$c"
  fi
  if [ -z "$s" ]; then kee_t envview.status.ok; s="${TH[ok]:-}$UI_S_OK $KEE_T$TH_RESET"; fi
  KEE_STATUS="$s"
}

# The actions of the bottom border (kit_box footer chips).
kee_footer_chips() {
  kee_t envview.foot
  KEE_FOOTER="$KEE_T"
  # (while a value is typed the modal has the actions of its own)
  if [ "$KEE_EDIT" -eq 1 ] || [ -n "$KEE_PROMPT" ]; then KEE_FOOTER=""; fi
}

# The hint line (the keys) for what the editor is doing now, fitted to $1 cells, into KEE_HINT as plain text with " · " between items.
kee_hint() { # width
  local k=envview.keys
  if [ -n "$KEE_PROMPT" ]; then k="envview.keys_ask_$KEE_PROMPT"
  elif [ "$KEE_EDIT" -eq 1 ]; then
    k=envview.keys_edit
    [ "$KEE_EDIT_KIND" != file ] || k=envview.keys_file_edit
  fi
  kee_cur
  if [ "$k" = envview.keys ] && [ -z "$KEE_CUR_ID" ]; then k=envview.keys_file; fi
  kee_t "$k" "$KEE_UD"
  KEE_HINT="$KEE_T"
  if [ "$KEE_N_SYNC" -gt 0 ] && [ "$KEE_EDIT" -eq 0 ] && [ -z "$KEE_PROMPT" ]; then kee_t envview.keys_sync "$KEE_N_SYNC"; KEE_HINT+=" · $KEE_T"; fi
}

# One row of the list, $2 cells wide, into KEE_LINE. kw is the width of the name column, nw the room for a note.
KEE_LINE=""
kee_line_file() { # file width
  local f="$1" w="$2" mark counts pend left right n=0 todo=0 id
  local -a arr=()
  if [ "${UI_UTF8:-0}" -ne 1 ]; then mark="v"; [ "${KEE_FOLD[$f]:-0}" -ne 1 ] || mark=">"
  elif [ "${KEE_FOLD[$f]:-0}" -eq 1 ]; then mark="▸"
  else mark="▾"; fi
  read -ra arr <<< "${KEE_FIDS[$f]:-}"
  for id in "${arr[@]}"; do
    n=$((n + 1))
    case "${KEE_ST[$id]:-}" in missing | invalid | example) todo=$((todo + 1)) ;; esac
  done
  if [ "$todo" -gt 0 ]; then kee_t envview.file_todo "$n" "$todo"; counts="${TH[warn]:-}$KEE_T$TH_RESET"
  else kee_t envview.file_all "$n"; counts="${TH[dim]:-}$KEE_T$TH_RESET"; fi
  left="${TH[accent]:-}$C_BLD$mark $f$TH_RESET"
  right="$counts"
  case "${KEE_DEPLOY[$f]:-}" in
    pending) kee_t envview.file_pending; right+="  ${TH[info]:-}$UI_S_SYNC $KEE_T$TH_RESET" ;;
  esac
  tui_vlen "$left"; local lw="$TUI_VL"
  tui_vlen "$right"
  if [ $((lw + 2 + TUI_VL)) -le "$w" ]; then
    printf -v pend '%*s' $((w - lw - TUI_VL)) ''
    KEE_LINE="$left$pend$right"
  else
    tui_fit "$left" "$w"; KEE_LINE="$TUI_OUT"
  fi
}

kee_line_var() { # id width kw
  local id="$1" w="$2" kw="$3" icon key val nw vw note nt
  kee_state_icon_of "$id"; icon="$KEE_ICON_OUT"
  key="${id#*|}"
  [ "${#key}" -le "$kw" ] || key="${key:0:$((kw - 1))}$UI_S_ELL"
  printf -v key '%-*s' "$kw" "$key"
  if [ "${KEE_VAL[$id]:-}" != "${KEE_BASE[$id]:-}" ]; then key="${TH[accent]:-}$C_BLD$key$TH_RESET"; fi
  kee_row_note "$id"; note="$KEE_NOTE_TXT" nt="$KEE_NOTE_ST"
  kee_shown "$id"; val="$KEE_SHOWN"
  nw=0
  if [ -n "$note" ]; then
    nw=$((${#note} + 2))
    [ "$nw" -le 30 ] || { note="${note:0:27}$UI_S_ELL"; nw=30; }
  fi
  vw=$((w - 2 - kw - 2 - nw))
  if [ "$vw" -lt 12 ] && [ "$nw" -gt 0 ]; then note="" nw=0; vw=$((w - 2 - kw - 2)); fi
  [ "$vw" -ge 1 ] || vw=1
  tui_fit "$val" "$vw"; val="$TUI_OUT"
  if [ -n "$note" ]; then
    kit_state_color "$nt"
    KEE_LINE="$icon $key  $val  $KIT_COL$note$TH_RESET"
  else
    KEE_LINE="$icon $key  $val"
  fi
  tui_fit "$KEE_LINE" "$w"; KEE_LINE="$TUI_OUT"
}

KEE_ICON_OUT=""
kee_state_icon_of() { # id
  kit_state_icon "$(kee_icon_state "${KEE_ST[$1]:-}")"
  KEE_ICON_OUT="$KIT_ICON"
}

# The modal that edits a value (into KEE_MODAL, $1 cells of screen and $2 lines to work in): the name of the variable, what it is and what it
# says, the field with the value (a secret is shown unless Tab hid it) and what the validator says about what is typed.
kee_modal_build() { # width height
  local w="$1" h="$2" id="$KEE_EDIT_ID" mw type l dmax msg mask=0 body=()
  mw=$((w - 6)); [ "$mw" -le 76 ] || mw=76; [ "$mw" -ge 24 ] || mw="$w"
  if [ "$KEE_EDIT_KIND" = file ]; then kee_modal_build_file "$mw" "$h"; return 0; fi
  if [ "${ENV_TYPE[$id]:-}" = req ]; then kee_t envview.type.req; else kee_t envview.type.opt; fi
  type="$KEE_T"
  [ "${ENV_SECRET[$id]:-0}" != 1 ] || { kee_t envview.type.secret; type+=" $UI_S_DOT $KEE_T"; }
  body=("" "${TH[dim]:-}$type $UI_S_DOT ${id%%|*}$TH_RESET")
  dmax=$((h - 11)); [ "$dmax" -le 4 ] || dmax=4; [ "$dmax" -ge 0 ] || dmax=0
  kit_wrap "${ENV_DESC[$id]:-}" $((mw - 4))
  for l in "${KW_LINES[@]:0:$dmax}"; do body+=("$l"); done
  body+=("")
  { [ "${ENV_SECRET[$id]:-0}" = 1 ] && [ "$KEE_EDIT_SHOW" -eq 0 ]; } && mask=1
  kit_field_render "" "$KF_VALUE" "$KF_CUR" $((mw - 4)) label_width=0 focus=1 mask="$mask" state="$KEE_EDIT_ST"
  body+=("$KIT_OUT")
  msg="$KEE_EDIT_MSG"
  if [ -n "$msg" ]; then
    kit_state_color "$KEE_EDIT_ST"
    tui_fit "$KIT_COL$msg$TH_RESET" $((mw - 4)); body+=("$TUI_OUT")
  else
    body+=("")
  fi
  kee_t envview.foot_edit
  kit_box "$mw" $((${#body[@]} + 2)) body "chips=${id#*|}" "footer=$KEE_T" focus=1
  KEE_MODAL=("${KIT_BOX[@]}")
}

# The modal that asks for the path of a file of secrets/: what the file is for, the path, and what is known of it. $1 cells wide, $2 lines to work in.
kee_modal_build_file() { # width height
  local mw="$1" h="$2" id="$KEE_EDIT_ID" l dmax msg body=()
  kee_t envview.file.what "${id#*|}" "${id%%|*}"; body=("" "${TH[dim]:-}$KEE_T$TH_RESET")
  dmax=$((h - 9)); [ "$dmax" -le 4 ] || dmax=4; [ "$dmax" -ge 0 ] || dmax=0
  kee_t envview.file.text "$KEE_FILE_NAME"; kit_wrap "$KEE_T" $((mw - 4))
  for l in "${KW_LINES[@]:0:$dmax}"; do body+=("$l"); done
  if [ "$KEE_FILE_FORCE" -eq 1 ]; then kee_t envview.file.replace "$KEE_FILE_NAME"; tui_fit "${TH[warn]:-}$KEE_T$TH_RESET" $((mw - 4)); body+=("$TUI_OUT"); fi
  body+=("")
  kee_t envview.file.label
  kit_field_render "$KEE_T" "$KF_VALUE" "$KF_CUR" $((mw - 4)) label_width=7 focus=1 state="$KEE_EDIT_ST"
  body+=("$KIT_OUT")
  msg="$KEE_EDIT_MSG"
  if [ -n "$msg" ]; then kit_state_color "$KEE_EDIT_ST"; tui_fit "  $KIT_COL$msg$TH_RESET" $((mw - 4)); body+=("$TUI_OUT"); else body+=(""); fi
  kee_t envview.foot_file
  kit_box "$mw" $((${#body[@]} + 2)) body "chips=$KEE_FILE_NAME" "footer=$KEE_T" focus=1
  KEE_MODAL=("${KIT_BOX[@]}")
}

# Lays the modal over the lines of the array $1 (the drawing of the editor, $2 cells wide) while a value is being typed.
kee_modal_overlay() { # array width
  local -n _kmo="$1"
  local w="$2" i
  [ "$KEE_EDIT" -eq 1 ] || return 0
  kee_modal_build "$w" "${#_kmo[@]}"
  for ((i = 0; i < ${#_kmo[@]}; i++)); do
    _kmo[i]="${_kmo[$i]#"$TUI_SEL"}"   # (the marker of the selected row does not survive being cut: under a modal nothing is selected)
    tui_fit "${_kmo[$i]}" "$w"; _kmo[i]="$TUI_OUT"
  done
  kit_center "$1" KEE_MODAL
}

# The description of what is under the cursor, as lines of $1 cells, into KEE_CARD (plain text with colours): used by the card at the right
# and by the strip under the list.
KEE_CARD=() KEE_CARD_TITLE=""
kee_card() { # width
  local w="$1" id="$KEE_CUR_ID" f="$KEE_CUR_FILE" l st type="" extra="" first=1
  KEE_CARD=() KEE_CARD_TITLE=""
  if [ -z "$id" ]; then
    KEE_CARD_TITLE="$f"
    kee_card_file "$f" "$w"
    return 0
  fi
  KEE_CARD_TITLE="${id#*|}"
  st="${KEE_ST[$id]:-}"
  if [ "${ENV_TYPE[$id]}" = req ]; then kee_t envview.type.req; else kee_t envview.type.opt; fi
  type="$KEE_T"
  [ "${ENV_SECRET[$id]:-0}" != 1 ] || { kee_t envview.type.secret; type+=" $UI_S_DOT $KEE_T"; }
  tui_fit "${TH[dim]:-}$type $UI_S_DOT $f$TH_RESET" "$w"; KEE_CARD+=("$TUI_OUT" "")
  kit_wrap "${ENV_DESC[$id]:-}" "$w"
  for l in "${KW_LINES[@]}"; do tui_fit "$l" "$w"; KEE_CARD+=("$TUI_OUT"); done
  KEE_CARD+=("")
  if [ "${ENV_HASDEF[$id]:-0}" = 1 ] && [ -n "${ENV_DEFAULT[$id]:-}" ]; then
    kee_t envview.card.default "${ENV_DEFAULT[$id]}"; tui_fit "${TH[dim]:-}$KEE_T$TH_RESET" "$w"; KEE_CARD+=("$TUI_OUT")
  fi
  if [ "${ENV_SECRET[$id]:-0}" != 1 ] && [ -n "${ENV_EXAMPLE[$id]:-}" ] && [[ "${ENV_EXAMPLE[$id]}" != *CAMBIAR* ]]; then
    kee_t envview.card.example "${ENV_EXAMPLE[$id]}"; tui_fit "${TH[dim]:-}$KEE_T$TH_RESET" "$w"; KEE_CARD+=("$TUI_OUT")
  fi
  if [ -n "${ENV_GEN[$id]:-}" ]; then kee_t envview.card.gen; tui_fit "${TH[dim]:-}$KEE_T$TH_RESET" "$w"; KEE_CARD+=("$TUI_OUT"); fi
  # What the validator says about the value in the model (or being typed), with the icon of its state.
  extra=""
  if [ "$KEE_EDIT" -eq 1 ] && [ "$KEE_EDIT_ID" = "$id" ]; then extra="$KEE_EDIT_MSG"; st="$KEE_EDIT_ST"; kit_state_icon "$st"
  else
    case "$st" in invalid | warn) extra="${KEE_MSG[$id]}" ;; missing) kee_t envview.card.missing; extra="$KEE_T" ;; example) kee_t envview.card.example_left; extra="$KEE_T" ;; esac
    kit_state_icon "$(kee_icon_state "$st")"
  fi
  if [ -n "$extra" ]; then
    KEE_CARD+=("")
    kit_wrap "$extra" $((w - 2))
    for l in "${KW_LINES[@]}"; do
      if [ "$first" -eq 1 ]; then tui_fit "$KIT_ICON $l" "$w"; first=0; else tui_fit "  $l" "$w"; fi
      KEE_CARD+=("$TUI_OUT")
    done
  fi
}

kee_card_file() { # file width
  local f="$1" w="$2" l
  # A model with no disk behind it (the wizard's): the file does not exist yet, so there is no deploy to compare with.
  if [ "$KEE_DISK" -eq 0 ]; then
    kee_t envview.card.state_new; tui_fit "${TH[dim]:-}$KEE_T$TH_RESET" "$w"; KEE_CARD+=("$TUI_OUT" "")
    kee_t envview.card.file_new; kit_wrap "$KEE_T" "$w"
    for l in "${KW_LINES[@]}"; do tui_fit "${TH[dim]:-}$l$TH_RESET" "$w"; KEE_CARD+=("$TUI_OUT"); done
    return 0
  fi
  # (the first line is short, like the one of a variable's card: the strip under the list of a narrow screen shows it next to the title)
  case "${KEE_DEPLOY[$f]:-}" in
    pending) kee_t envview.card.state_pending; tui_fit "${TH[info]:-}$UI_S_SYNC $KEE_T$TH_RESET" "$w" ;;
    synced) kee_t envview.card.state_synced; tui_fit "${TH[dim]:-}$KEE_T$TH_RESET" "$w" ;;
    *) kee_t envview.card.state_unknown; tui_fit "${TH[dim]:-}$KEE_T$TH_RESET" "$w" ;;
  esac
  KEE_CARD+=("$TUI_OUT" "")
  case "${KEE_DEPLOY[$f]:-}" in
    pending) kee_t envview.card.file_pending ;;
    synced) kee_t envview.card.file_synced ;;
    *) kee_t envview.card.file_unknown ;;
  esac
  kit_wrap "$KEE_T" "$w"
  for l in "${KW_LINES[@]}"; do tui_fit "${TH[dim]:-}$l$TH_RESET" "$w"; KEE_CARD+=("$TUI_OUT"); done
  if [ "$KEE_N_HIDDEN" -gt 0 ] && [ "$KEE_ADV" -eq 0 ]; then
    KEE_CARD+=("")
    kee_t envview.card.hidden "$KEE_N_HIDDEN"; kit_wrap "$KEE_T" "$w"
    for l in "${KW_LINES[@]}"; do tui_fit "${TH[dim]:-}$l$TH_RESET" "$w"; KEE_CARD+=("$TUI_OUT"); done
  fi
}

# The lines the prompt shows (a question and what it costs), $1 cells wide, into KEE_ASK.
KEE_ASK=()
kee_ask_lines() { # width
  local w="$1" id="$KEE_PROMPT_ID" key="${KEE_PROMPT_ID#*|}" l files="" f
  KEE_ASK=()
  case "$KEE_PROMPT" in
    gen)
      kee_t env.gen_confirm "$key"
      tui_fit "${TH[warn]:-}$C_BLD$KEE_T$TH_RESET" "$w"; KEE_ASK+=("$TUI_OUT")
      if [ "${ENV_GEN[$id]:-}" = shared ]; then
        for f in "${KEE_FILES[@]}"; do [ "${ENV_GEN[$f|$key]:-}" != shared ] || files+="${files:+, }$f"; done
        kee_t env.gen_replace_shared "$files"; kit_wrap "$KEE_T" "$w"
        for l in "${KW_LINES[@]}"; do tui_fit "${TH[dim]:-}$l$TH_RESET" "$w"; KEE_ASK+=("$TUI_OUT"); done
      fi
      ;;
    leave)
      kee_t envview.ask.leave "$KEE_N_CHANGED"
      tui_fit "${TH[warn]:-}$C_BLD$KEE_T$TH_RESET" "$w"; KEE_ASK+=("$TUI_OUT")
      ;;
    deploy)
      if kee_dirty; then kee_t envview.ask.deploy "$KEE_N_CHANGED" "$KEE_INST"; else kee_t envview.ask.deploy_only "" "$KEE_INST"; fi
      tui_fit "${TH[warn]:-}$C_BLD$KEE_T$TH_RESET" "$w"; KEE_ASK+=("$TUI_OUT")
      kee_t envview.ask.deploy_note; kit_wrap "$KEE_T" "$w"
      for l in "${KW_LINES[@]}"; do tui_fit "${TH[dim]:-}$l$TH_RESET" "$w"; KEE_ASK+=("$TUI_OUT"); done
      ;;
  esac
}

# The list as lines of one box: $1 cells of content, $2 lines. Returns the lines in KEE_BODY and keeps the cursor row in view.
KEE_BODY=()
kee_body() { # width lines
  local w="$1" n="$2" i r kw=0 key id top a b sel line
  KEE_BODY=()
  for r in "${KEE_ROWS[@]}"; do
    case "$r" in V\|*) id="${r#V|}"; key="${id#*|}"; [ "${#key}" -le "$kw" ] || kw="${#key}" ;; esac
  done
  [ "$kw" -ge 10 ] || kw=10
  a=$((w * 2 / 5)); [ "$a" -ge 14 ] || a=14
  [ "$kw" -le "$a" ] || kw="$a"
  [ "$kw" -le 30 ] || kw=30
  local lck="$w|$kw|${DELTACTL_LANG_ACTIVE:-}|${UI_UTF8:-0}|${TH[accent]:-}|${TH[ok]:-}|${TH[warn]:-}|${TH[err]:-}|$KEE_GEN"
  if [ "$lck" != "$KEE_LC_KEY" ]; then KEE_LC=() KEE_LC_KEY="$lck"; fi
  top="$KEE_TOP"
  [ "$KEE_SEL" -ge "$top" ] || top="$KEE_SEL"
  [ "$KEE_SEL" -lt $((top + n)) ] || top=$((KEE_SEL - n + 1))
  # Showing the file's row when the cursor is on its first variable gives context.
  if [ "$KEE_SEL" -gt 0 ] && [ "$top" -eq "$KEE_SEL" ] && [ "${KEE_ROWS[$((KEE_SEL - 1))]:0:1}" = F ]; then top=$((top - 1)); fi
  [ $((top + n)) -le "${#KEE_ROWS[@]}" ] || top=$((${#KEE_ROWS[@]} - n))
  [ "$top" -ge 0 ] || top=0
  KEE_TOP="$top"
  sel="$KEE_SEL"
  for ((i = top; i < top + n && i < ${#KEE_ROWS[@]}; i++)); do
    r="${KEE_ROWS[$i]}"
    case "$r" in
      F\|*) kee_line_file "${r#F|}" "$w" ;;
      V\|*)
        id="${r#V|}"
        if [ -n "${KEE_LC[$id]+x}" ]; then KEE_LINE="${KEE_LC[$id]}"
        else kee_line_var "$id" "$w" "$kw"; KEE_LC[$id]="$KEE_LINE"; fi
        ;;
    esac
    line="$KEE_LINE"
    if [ "$i" -eq "$sel" ]; then line="$TUI_SEL$line"; fi
    KEE_BODY+=("$line")
  done
  if [ "${#KEE_ROWS[@]}" -eq 0 ]; then kee_t envview.empty_list; KEE_BODY+=("${TH[dim]:-}$KEE_T$TH_RESET"); fi
  while [ "${#KEE_BODY[@]}" -lt "$n" ]; do KEE_BODY+=(""); done
}

# The whole editor in a box of $1 x $2 cells into KEE_BOX.
kee_render() { # width height [option=value ...]
  local w="$1" h="$2" o chips="" foc=1 side=auto cardw=0 listw inner dl=0 i k cnt=0
  local -a body=() left=() right=() cardbody=()
  shift 2
  for o in "$@"; do
    case "$o" in chips=*) chips="${o#chips=}" ;; focus=*) foc="${o#focus=}" ;; side=*) side="${o#side=}" ;; esac
  done
  [ -n "$chips" ] || chips="$KEE_INST"
  if [ "$side" = auto ]; then if [ "$w" -ge 100 ]; then side=1; else side=0; fi; fi
  if [ "$side" -eq 1 ]; then cardw=34; [ "$w" -lt 140 ] || cardw=42; fi
  listw=$((w - cardw))
  inner=$((h - 2))
  kee_cur
  KEE_PAGE=$((inner - 2)); [ "$KEE_PAGE" -ge 1 ] || KEE_PAGE=1
  kee_status
  kee_footer_chips
  if [ "$side" -eq 1 ]; then
    # List at the left (the whole height), the card of what is under the cursor at the right.
    if [ -n "$KEE_PROMPT" ]; then
      kee_ask_lines $((listw - 4))
      dl=$(( ${#KEE_ASK[@]} + 1 ))
    fi
    kee_body $((listw - 4)) $((inner - dl))
    body=("${KEE_BODY[@]}")
    if [ "$dl" -gt 0 ]; then
      tui_rep "$UI_S_RULE" $((listw - 4)); body+=("${TH[faint]:-}$TUI_OUT$TH_RESET")
      body+=("${KEE_ASK[@]}")
    fi
    kit_box "$listw" "$h" body "chips=$chips" "status=$KEE_STATUS" "footer=$KEE_FOOTER" "focus=$foc"
    left=("${KIT_BOX[@]}")
    kee_card $((cardw - 4))
    cardbody=("${KEE_CARD[@]}")
    kit_box "$cardw" "$h" cardbody "chips=$KEE_CARD_TITLE" focus=0
    right=("${KIT_BOX[@]}")
    KEE_BOX=()
    for ((i = 0; i < h; i++)); do KEE_BOX+=("${left[$i]}${right[$i]}"); done
    kee_modal_overlay KEE_BOX "$w"
    return 0
  fi
  # Narrow: the description goes under the list (three lines when the height allows it, one line of context otherwise).
  if [ -n "$KEE_PROMPT" ]; then
    kee_ask_lines $((w - 4))
    dl=$(( ${#KEE_ASK[@]} + 1 ))
  elif [ "$inner" -ge 12 ]; then
    dl=4
  fi
  kee_body $((w - 4)) $((inner - dl))
  body=("${KEE_BODY[@]}")
  if [ "$dl" -gt 0 ]; then
    tui_rep "$UI_S_RULE" $((w - 4)); body+=("${TH[faint]:-}$TUI_OUT$TH_RESET")
    if [ -n "$KEE_PROMPT" ]; then body+=("${KEE_ASK[@]}")
    else
      kee_card $((w - 4))
      # One line with what the variable is, then the first lines of its description (the card's own lines carry the rest).
      tui_fit "${TH[accent]:-}$C_BLD$KEE_CARD_TITLE$TH_RESET  ${KEE_CARD[0]:-}" $((w - 4)); body+=("$TUI_OUT")
      for ((k = 2; k < ${#KEE_CARD[@]} && cnt < dl - 2; k++)); do
        [ -n "${KEE_CARD[$k]//[[:space:]]/}" ] || continue
        body+=("${KEE_CARD[$k]}"); cnt=$((cnt + 1))
      done
    fi
  fi
  while [ "${#body[@]}" -lt "$inner" ]; do body+=(""); done
  kit_box "$w" "$h" body "chips=$chips" "status=$KEE_STATUS" "footer=$KEE_FOOTER" "focus=$foc"
  KEE_BOX=("${KIT_BOX[@]}")
  kee_modal_overlay KEE_BOX "$w"
}

#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # DASH_NZ_* belong to lib/screens/newinst.sh; KEE_* to lib/ui/kit/env_editor.sh
# Step 5 of the new-instance wizard: the variables. The editor of the instance's variables (lib/ui/kit/env_editor.sh, the same component as the
# Variables view) is in this view, over a model with no disk behind it (kee_init): the files the instance will have (.env.instance and the
# .env.<service> of the chosen services), grouped, each variable with its description and its live check. What the wizard already knows is in
# it from the start (the name, the services, the ports and the versions of the earlier steps) and what the template already gives is its default;
# the secrets that are unique to an instance are GENERATED here (new instance with openssl) and never drawn: they are dots until `r` shows one
# for ten seconds. What is left is what only the person knows: the Mongo URIs, the address of the server...
#
# Nothing is written to the disk until the instance is created. What the person changed (and what was generated) goes to `new` as --env-file,
# a file of lines <file>:<KEY>=<value> that only exists from the moment `Crear` is pressed until the command ends (hook prepare). The ports and
# the versions edited here are also the answers of the earlier steps (they are copied back), so the preview and the proxy agree with them.
#
# Keys: those of the editor (Enter edits, g generates, r shows a secret, d default, a advanced, ↑↓ PgUp PgDn Home End). The editor owns Enter, so
# `s` goes on to the next step; with required variables still empty it says so first and goes on the second time (▲: the deploy will ask for them).

DASH_NZV_PRE="" DASH_NZV_BUILT=0 DASH_NZV_SIG="" DASH_NZV_ASK=-1 DASH_NZV_ACK=-1 DASH_NZV_IP="" DASH_NZV_GENN=0 DASH_NZV_GENIDN=0 DASH_NZV_GENNAMES=""
declare -gA DASH_NZV_KEEP=() DASH_NZV_GENID=() DASH_NZV_MONGO=()   # (DASH_NZV_MONGO: the URI composed with the user and password of Mongo, by id, as it was put in the model)

dash_nzs_variables_reset() {
  DASH_NZV_PRE="" DASH_NZV_BUILT=0 DASH_NZV_SIG="" DASH_NZV_ASK=-1 DASH_NZV_ACK=-1 DASH_NZV_IP="" DASH_NZV_GENN=0 DASH_NZV_GENIDN=0 DASH_NZV_GENNAMES=""
  DASH_NZV_KEEP=() DASH_NZV_GENID=() DASH_NZV_MONGO=() DASH_NZV_CREV=-1
  DASH_NZ_GENDONE=0
}

# --- The model --------------------------------------------------------------------------------------------------------------------

# A value that the wizard knows: it is in the model as what the file will already say (value and base are the same: it is not a change),
# unless the person changed it here (then only the base follows).
dash_nzv_known() { # file key value
  local id="$1|$2"
  [ -n "${KEE_VAL[$id]+x}" ] || return 0
  if [ "${KEE_VAL[$id]}" = "${KEE_BASE[$id]:-}" ]; then KEE_VAL[$id]="$3"; fi
  KEE_BASE[$id]="$3"
}

# What the earlier steps decided, put in the model.
dash_nzv_prefill() {
  local s
  dash_nz_sel_list
  dash_nzv_known .env.instance INSTANCE "$DASH_NZ_NAME"
  dash_nzv_known .env.instance COMPOSE_PROFILES "$DASH_NZ_CSV"
  for s in "${DASH_NZ_SL[@]}"; do
    dash_nzv_known .env.instance "${s^^}_PORT" "${DASH_NZ_PORT[$s]:-}"
    dash_nzv_known .env.instance "${s^^}_TAG" "${DASH_NZ_TAG[$s]:-}"
  done
}

# What the file will say before the person touches it: the template's line (ENV_EXAMPLE), as `new` writes it. For a new instance `new` also names
# the databases after it (CAMBIAR_<db>_INSTANCIA becomes <db>_<name>); a value that still has a CAMBIAR is not a value: it stays empty (missing).
dash_nzv_template() {
  local id v
  for id in "${!KEE_VAL[@]}"; do
    v="${ENV_EXAMPLE[$id]:-}"
    [ -n "$v" ] || continue
    if [ "$DASH_NZ_DATA" -eq 0 ]; then
      while [[ "$v" =~ CAMBIAR_([a-z]+)_INSTANCIA ]]; do v="${v/"${BASH_REMATCH[0]}"/"${BASH_REMATCH[1]}_$DASH_NZ_NAME"}"; done
    fi
    [[ "$v" != *CAMBIAR* ]] || continue
    [ -z "${KEE_VAL[$id]}" ] || continue
    KEE_VAL[$id]="$v" KEE_BASE[$id]="$v"
    # A new municipality has its own user of Mongo: its URIs carry it (the value differs from the template's, so it goes to `new` like any value
    # the person put; `init` creates the user from what the URIs say).
    if [ "$DASH_NZ_DATA" -eq 0 ] && [ "${ENV_VALIDATOR[$id]:-}" = mongo-uri ] && dash_nzm_compose "$v"; then
      KEE_VAL[$id]="$DASH_NZM_URI" DASH_NZV_MONGO[$id]="$DASH_NZM_URI"
    fi
  done
}

# The secrets that are unique to an instance, made here (not by `new`): a new instance and openssl. One value for what the services share.
dash_nzv_generate() {
  local s item var kind id val names=""
  local -A sh=()
  DASH_NZV_GENN=0 DASH_NZV_GENIDN=0 DASH_NZV_GENNAMES="" DASH_NZ_GENDONE=0
  dash_nz_gen_ok && [ "$DASH_NZ_GEN" -eq 1 ] || return 0
  for s in "${DASH_NZ_SL[@]}"; do
    for item in ${CAT_SECRETS[$s]:-}; do
      var="${item%%:*}" id=".env.$s|${item%%:*}"
      [ -z "${DASH_NZV_GENID[$id]:-}" ] || [ -z "${KEE_VAL[$id]:-}" ] || sh[$var]="${KEE_VAL[$id]}"
    done
  done
  for s in "${DASH_NZ_SL[@]}"; do
    for item in ${CAT_SECRETS[$s]:-}; do
      var="${item%%:*}" kind="${item#*:}" id=".env.$s|${item%%:*}"
      [ -n "${KEE_VAL[$id]+x}" ] || continue
      if [ -z "${KEE_VAL[$id]}" ]; then
        if [ "$kind" = shared ]; then
          [ -n "${sh[$var]:-}" ] || sh[$var]="$(envedit_random shared)"
          val="${sh[$var]}"
        else
          val="$(envedit_random "$kind")"
        fi
        [ -n "$val" ] || continue
        KEE_VAL[$id]="$val" DASH_NZV_GENID[$id]=1
        val=""
      fi
      if [ -n "${DASH_NZV_GENID[$id]:-}" ]; then
        DASH_NZV_GENIDN=$((DASH_NZV_GENIDN + 1))
        case ", $names, " in
          *", $var, "*) ;;
          *) names+="${names:+, }$var"; DASH_NZV_GENN=$((DASH_NZV_GENN + 1)) ;;   # (a shared secret is named and counted once)
        esac
      fi
    done
  done
  DASH_NZV_GENNAMES="$names"
  DASH_NZ_GENDONE=1
}

# Is the model what the earlier steps need? It is built the first time and again when the name, the services or the kind of data change
# (what the person edited stays: the ids that still exist keep their value, except a generated secret when generating is no longer asked).
dash_nzv_ensure() {
  local sig id s
  local -a files=(.env.instance)
  dash_nz_sel_list
  sig="$DASH_NZ_NAME|$DASH_NZ_CSV|$DASH_NZ_DATA|$DASH_NZ_SSL|$DASH_NZ_GEN|$DASH_NZM_USER|$DASH_NZM_PASS"
  if [ "$DASH_NZV_BUILT" -eq 1 ] && [ "$sig" = "$DASH_NZV_SIG" ]; then
    # (every variable is evaluated again only when what the earlier steps decided changed: a frame must not pay for it)
    local pre="$sig"
    for s in "${DASH_NZ_SL[@]}"; do pre+="|${DASH_NZ_PORT[$s]:-}:${DASH_NZ_TAG[$s]:-}"; done
    if [ "$pre" != "$DASH_NZV_PRE" ]; then
      DASH_NZV_PRE="$pre"
      dash_nzv_prefill
      kee_refresh
    fi
    return 0
  fi
  if [ "$DASH_NZV_BUILT" -eq 1 ]; then
    for id in "${!KEE_VAL[@]}"; do
      [ "${KEE_VAL[$id]}" = "${KEE_BASE[$id]:-}" ] && continue
      [ "${KEE_VAL[$id]}" != "${DASH_NZV_MONGO[$id]:-}" ] || continue   # (the URI composed with the user and password is not something the person typed)
      DASH_NZV_KEEP[$id]="${KEE_VAL[$id]}"
    done
    DASH_NZV_MONGO=()
  fi
  for s in "${DASH_NZ_SL[@]}"; do files+=(".env.$s"); done
  kee_init "$DASH_NZ_NAME" "${files[@]}"
  KEE_UD="${DASH_UD:-↑↓}"
  dash_nzv_template
  dash_nzv_prefill
  for id in "${!DASH_NZV_KEEP[@]}"; do
    [ -n "${KEE_VAL[$id]+x}" ] || continue
    if [ -n "${DASH_NZV_GENID[$id]:-}" ] && ! { dash_nz_gen_ok && [ "$DASH_NZ_GEN" -eq 1 ]; }; then continue; fi
    KEE_VAL[$id]="${DASH_NZV_KEEP[$id]}"
  done
  dash_nzv_generate
  DASH_NZV_SIG="$sig" DASH_NZV_BUILT=1 DASH_NZV_PRE=""
  kee_refresh
  kee_autofold
  DASH_NZV_IP=""
}

dash_nzs_variables_enter() {
  dash_nzv_ensure
  DASH_NZV_ASK=-1
}

# The ids that changed against what the files will already say (what `new` has to be told), in the order of the files.
DASH_NZV_CHANGED=() DASH_NZV_CREV=-1
dash_nzv_changed() {
  local f id
  local -a ids=()
  # (the bar, the preview and the form ask for it in every frame: it is made again only when the model changed)
  [ "$DASH_NZV_CREV" != "$KEE_REV" ] || return 0
  DASH_NZV_CREV="$KEE_REV"
  DASH_NZV_CHANGED=()
  for f in "${KEE_FILES[@]}"; do
    read -ra ids <<< "${KEE_FIDS[$f]:-}"
    for id in "${ids[@]}"; do
      [ "${KEE_VAL[$id]:-}" != "${KEE_BASE[$id]:-}" ] && [ -n "${KEE_VAL[$id]:-}" ] || continue
      DASH_NZV_CHANGED+=("$id")
    done
  done
}

# --- What the editor did ------------------------------------------------------------------------------------------------------------

# The ports and the versions edited here are the answers of the earlier steps too; and the address of the server, asked by both services,
# is one answer: the one that was just typed goes to the other file when that one is empty or still had the previous one.
dash_nzv_syncback() {
  local s v id new="" last="$DASH_NZV_IP"
  for s in "${DASH_NZ_SL[@]}"; do
    v="${KEE_VAL[.env.instance|${s^^}_PORT]:-}"
    if [[ "$v" =~ ^[0-9]{1,5}$ ]] && [ "$v" != "${DASH_NZ_PORT[$s]:-}" ]; then
      DASH_NZ_PORT[$s]="$v" DASH_NZ_PBUSY[$s]=0
      if [ -n "$(port_owner "$v" "")" ] || host_port_in_use "$v"; then DASH_NZ_PBUSY[$s]=1; fi
    fi
    v="${KEE_VAL[.env.instance|${s^^}_TAG]:-}"
    if [ -n "$v" ] && [ "$v" != "${DASH_NZ_TAG[$s]:-}" ]; then DASH_NZ_TAG[$s]="$v"; fi
    id=".env.$s|IP_SERVER"
    [ -n "${KEE_VAL[$id]+x}" ] || continue
    [ "${KEE_VAL[$id]}" = "$last" ] || new="${KEE_VAL[$id]}"
  done
  if [ "$new" != "$last" ] && [ -n "$new" ]; then
    for s in "${DASH_NZ_SL[@]}"; do
      id=".env.$s|IP_SERVER"
      [ -n "${KEE_VAL[$id]+x}" ] || continue
      if [ -z "${KEE_VAL[$id]}" ] || [ "${KEE_VAL[$id]}" = "$last" ]; then KEE_VAL[$id]="$new"; fi
    done
    DASH_NZV_IP="$new"
    kee_refresh
  fi
}

dash_nzv_after() {
  if [ -n "$KEE_NOTE" ]; then dash_msg "${KEE_NOTE_KIND:-info}" "$KEE_NOTE"; fi
  dash_nzv_syncback
  if [ "$KEE_ACTION" = leave ]; then KEE_ACTION=""; dash_nz_back; fi
  # `f` on a file of secrets/: the instance has no folder yet; the files are given in the step of the files.
  if [ "$KEE_ACTION" = secfile ]; then
    local i
    KEE_ACTION=""
    for i in "${!DASH_NZ_STEPS[@]}"; do [ "${DASH_NZ_STEPS[$i]}" != secrets ] || { dash_nz_goto "$i"; break; }; done
  fi
}

dash_nzs_variables_key() { # key
  local k="$1"
  [ "$DASH_NZV_BUILT" -eq 1 ] || return 1
  if [ "$KEE_EDIT" -eq 0 ] && [ -z "$KEE_PROMPT" ]; then
    case "$k" in
      s) dash_nz_next; return 0 ;;                         # (the second `s` is the one that goes on without the required ones)
      tab | btab | [0-9] | q) DASH_NZV_ASK=-1; return 1 ;;
      j | k) [ "${DASH_VIM:-1}" -eq 1 ] || return 0 ;;     # (with the vim keys off they are not moves)
    esac
  fi
  DASH_NZV_ASK=-1
  if kee_key "$k"; then dash_nzv_after; return 0; fi
  return 1
}

# --- State, gate and what it adds to the command --------------------------------------------------------------------------------------

dash_nzs_variables_state() {
  if [ "$DASH_NZV_BUILT" -ne 1 ]; then DASH_NZ_ST=pend DASH_NZ_VAL=""; return 0; fi
  dash_nzv_changed
  if [ "$KEE_N_TODO" -gt 0 ]; then
    DASH_NZ_ST=warn; t_r tui.nz.var.v_todo "$KEE_N_TODO"
  else
    DASH_NZ_ST=ok; t_r tui.nz.var.v_ok "$((${#DASH_NZV_CHANGED[@]} - DASH_NZV_GENIDN))"
  fi
  DASH_NZ_VAL="$T_OUT"
}

# Required variables empty: the first `s` says so (and how many), the second goes on (▲). It is asked again if the count changes.
dash_nzs_variables_gate() {
  dash_nzv_ensure
  [ "$KEE_N_TODO" -gt 0 ] || return 0
  if [ "$DASH_NZV_ASK" = "$KEE_N_TODO" ] || [ "$DASH_NZV_ACK" = "$KEE_N_TODO" ]; then DASH_NZV_ACK="$KEE_N_TODO"; DASH_NZV_ASK=-1; return 0; fi
  DASH_NZV_ASK="$KEE_N_TODO"
  t_r tui.nz.var.skip "$KEE_N_TODO"; DASH_NZ_ERR="$T_OUT"
  return 1
}

dash_nzs_variables_sig() {
  [ "$DASH_NZV_BUILT" -eq 1 ] || return 0
  DASH_NZ_AS+="|v${KEE_REV:-0}:$KEE_N_TODO:$DASH_NZV_GENN"
}

dash_nzs_variables_args() {
  local show
  [ "$DASH_NZV_BUILT" -eq 1 ] || return 0
  dash_nzv_changed
  [ "${#DASH_NZV_CHANGED[@]}" -gt 0 ] || return 0
  if [ -n "$DASH_NZ_ENVFILE" ]; then show="$DASH_NZ_ENVFILE"; else t_r tui.nz.pv.envfile; show="$T_OUT"; fi
  DASH_NZ_ARGV+=(--env-file "$show")
}

# The file of answers: <file>:<KEY>=<value>, mode 600 in a private folder, only while the command runs. Every value is checked once more with
# the rules of the variables, so what `new` receives is what it accepts.
dash_nzs_variables_prepare() {
  local id f word key tmp rc old
  dash_nzv_ensure
  dash_nzv_changed
  DASH_NZ_ENVFILE=""
  [ "${#DASH_NZV_CHANGED[@]}" -gt 0 ] || return 0
  for id in "${DASH_NZV_CHANGED[@]}"; do
    envschema_check_r "${id%%|*}" "${id#*|}" "${KEE_VAL[$id]}" "$DASH_NZ_NAME"
    if [ "$EV_RC" = 1 ]; then t_r tui.nz.var.bad "${id#*|}"; DASH_NZ_ERR="$T_OUT"; return 1; fi
  done
  old="$(umask)"
  umask 077
  tmp="$(mktemp "${TMPDIR:-/tmp}/deltactl-answers.XXXXXX")" || { umask "$old"; t_r tui.nz.var.tmp; DASH_NZ_ERR="$T_OUT"; return 1; }
  umask "$old"
  DASH_NZ_TMPS+=("$tmp")
  rc=0
  for id in "${DASH_NZV_CHANGED[@]}"; do
    f="${id%%|*}" key="${id#*|}" word="$(envedit_word "$f")"
    printf '%s:%s=%s\n' "$word" "$key" "${KEE_VAL[$id]}" >> "$tmp" || rc=1
  done
  chmod 600 "$tmp"
  if [ "$rc" -ne 0 ]; then t_r tui.nz.var.tmp; DASH_NZ_ERR="$T_OUT"; return 1; fi
  DASH_NZ_ENVFILE="$tmp"
  return 0
}

dash_nzs_variables_preview() { # width
  local n
  [ "$DASH_NZV_BUILT" -eq 1 ] || return 0
  dash_nzv_changed
  n="${#DASH_NZV_CHANGED[@]}"
  [ "$n" -gt 0 ] || return 0
  t_r tui.nz.pv.vars "$((n - DASH_NZV_GENIDN))" "$DASH_NZV_GENN"   # (put by the person, generated)
  DASH_NZ_P+=("  ${TH[dim]:-}$T_OUT$TH_RESET")
}

# --- Drawing --------------------------------------------------------------------------------------------------------------------------

dash_nzs_variables_render() { # width height
  local iw="$1" ih="$2" l dim="${TH[dim]:-}" r="$TH_RESET" n used=0 dl=0 col k cnt=0
  dash_nzv_ensure
  KEE_UD="${DASH_UD:-↑↓}"
  DASH_NZ_B=()
  # The count: what still has to be put, what changed and what was generated.
  dash_nzv_changed
  n=$((${#DASH_NZV_CHANGED[@]} - DASH_NZV_GENIDN))   # (the values the person put: the generated ones are counted apart)
  if [ "$KEE_N_TODO" -gt 0 ]; then col="${TH[warn]:-}"; t_r tui.nz.var.status "$KEE_N_TODO" "$n" "$DASH_NZV_GENN"
  else col="${TH[ok]:-}"; t_r tui.nz.var.status_ok "" "$n" "$DASH_NZV_GENN"; fi
  tui_fit "$col$C_BLD$T_OUT$r" "$iw"
  DASH_NZ_B+=("$TUI_OUT")
  used=1
  if [ "$ih" -ge 16 ]; then
    t_r tui.nz.help.variables; dash_wrap "$T_OUT" "$iw"
    for l in "${DASH_WRAP[@]}"; do DASH_NZ_B+=("$dim$l$r"); used=$((used + 1)); done
  fi
  # A question of the editor (generate over a value) takes the place of the description.
  if [ -n "$KEE_PROMPT" ]; then
    kee_ask_lines "$iw"
    dl=$((${#KEE_ASK[@]} + 1))
  elif [ $((ih - used)) -ge 8 ]; then
    dl=4
  fi
  n=$((ih - used - dl))
  [ "$n" -ge 2 ] || n=2
  kee_body "$iw" "$n"
  DASH_NZ_B+=("${KEE_BODY[@]}")
  if [ "$dl" -gt 0 ]; then
    tui_rep "$UI_S_RULE" "$iw"; DASH_NZ_B+=("${TH[faint]:-}$TUI_OUT$r")
    if [ -n "$KEE_PROMPT" ]; then
      DASH_NZ_B+=("${KEE_ASK[@]}")
    else
      kee_cur
      kee_card "$iw"
      tui_fit "${TH[accent]:-}$C_BLD$KEE_CARD_TITLE$r  ${KEE_CARD[0]:-}" "$iw"; DASH_NZ_B+=("$TUI_OUT")
      for ((k = 2; k < ${#KEE_CARD[@]} && cnt < dl - 2; k++)); do
        [ -n "${KEE_CARD[$k]//[[:space:]]/}" ] || continue
        DASH_NZ_B+=("${KEE_CARD[$k]}"); cnt=$((cnt + 1))
      done
    fi
  fi
  kee_modal_overlay DASH_NZ_B "$iw"   # (the value being typed is a modal over the list)
}

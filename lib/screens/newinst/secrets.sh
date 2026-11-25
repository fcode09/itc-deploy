#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # DASH_NZ_* belong to lib/screens/newinst.sh; KEE_* to lib/ui/kit/env_editor.sh
# Step 6 of the new-instance wizard: the files of secrets/. Some services read a file from instances/<name>/secrets/ (the Firebase JSON of the
# push notifications): the catalog says which variables point to one (CAT_SECRET_FILES) and the value of the variable says its name
# (/run/secrets/fcm.json is secrets/fcm.json). Here each one is given a file of this machine: the usual folders are searched for a name that looks
# like a service account (b goes through what was found), or the path is typed (e). The file is checked when it is chosen (it exists, can be
# read, is not too big and is a JSON object: lib/core/secretfile.sh; its content is never shown) and COPIED by `new` when the instance is
# created (--secret-file), with mode 600; nothing is copied before. A file that is not given is not an error: it can be copied later.
# This step also says which unique secrets are generated for the instance (names only, never values: the step of the variables made them).

DASH_NZS_SEL=0 DASH_NZS_EDIT=0 DASH_NZS_CI=-1 DASH_NZS_ROWS=() DASH_NZS_FOUND=-1
declare -gA DASH_NZS_SRC=() DASH_NZS_MSG=()

dash_nzs_secrets_reset() {
  DASH_NZS_SEL=0 DASH_NZS_EDIT=0 DASH_NZS_CI=-1 DASH_NZS_ROWS=() DASH_NZS_FOUND=-1
  DASH_NZS_SRC=() DASH_NZS_MSG=()
}

# The rows: "<service>|<variable>|<name in secrets/>" of the chosen services whose variable points into /run/secrets/. The value comes from the
# model of the variables (the person may have changed it) or, with no model yet, from the template's default.
dash_nzsec_rows() {
  local s var v id
  DASH_NZS_ROWS=()
  dash_nz_sel_list
  for s in "${DASH_NZ_SL[@]}"; do
    for var in ${CAT_SECRET_FILES[$s]:-}; do
      id=".env.$s|$var"
      v="${KEE_VAL[$id]:-}"
      [ -n "$v" ] || v="${ENV_EXAMPLE[$id]:-}"
      [[ "$v" == /run/secrets/* ]] || continue
      DASH_NZS_ROWS+=("$s|$var|${v#/run/secrets/}")
    done
  done
}

# A row into its parts: the service, the variable, the name in secrets/ and the key of the table of files (DASH_NZS_K).
DASH_NZS_S="" DASH_NZS_VAR="" DASH_NZS_NAME="" DASH_NZS_K=""
dash_nzsec_split() { # row
  IFS='|' read -r DASH_NZS_S DASH_NZS_VAR DASH_NZS_NAME <<< "$1"
  DASH_NZS_K="$DASH_NZS_S|$DASH_NZS_VAR"
}

# A path as the person types it: ~ is the home folder.
dash_nzsec_expand() { # path
  local p="$1"
  # shellcheck disable=SC2088  # (the tilde is the text the person types, not a path to expand)
  case "$p" in "~") p="${HOME:-}" ;; "~/"*) p="${HOME:-}/${p#\~/}" ;; esac
  printf '%s' "$p"
}

# A path as it is shown: the home folder is ~ (shorter, and the same on every machine).
DASH_NZS_SHORT=""
dash_nzsec_short() { # path
  DASH_NZS_SHORT="$1"
  # shellcheck disable=SC2088  # (the tilde is what is shown, not a path to expand)
  if [ -n "${HOME:-}" ] && [ "$HOME" != / ] && [[ "$1" == "$HOME"/* ]]; then DASH_NZS_SHORT="~/${1#"$HOME"/}"; fi
}

# Takes a file for a row: checks it and keeps it, or says why not (the row keeps what it had).
dash_nzsec_set() { # key path
  local key="$1" p
  p="$(dash_nzsec_expand "$2")"
  if sf_check "$p"; then
    DASH_NZS_SRC[$key]="$p" DASH_NZS_MSG[$key]=""
    DASH_NZ_ERR=""
    return 0
  fi
  dash_nzsec_short "$p"
  t_r "tui.nz.sec.err_$SF_WHY" "$DASH_NZS_SHORT"; DASH_NZ_ERR="$T_OUT"
  return 1
}

# The usual places, read when the step opens (and again with R): the names that look like a service account.
dash_nzsec_find() {
  sf_candidates
  DASH_NZS_FOUND="${#SF_CAND[@]}"
  DASH_NZS_CI=-1
}

dash_nzs_secrets_enter() {
  dash_nzsec_rows
  [ "$DASH_NZS_SEL" -lt "${#DASH_NZS_ROWS[@]}" ] || DASH_NZS_SEL=0
  DASH_NZS_EDIT=0
  dash_nzsec_find
}

dash_nzs_secrets_typing() { [ "$DASH_NZS_EDIT" -eq 1 ]; }

dash_nzs_secrets_key() { # key
  local k="$1" row key
  dash_nzsec_rows
  row="${DASH_NZS_ROWS[$DASH_NZS_SEL]:-}"
  dash_nzsec_split "$row"
  key="$DASH_NZS_K"
  if [ "$DASH_NZS_EDIT" -eq 1 ]; then
    case "$k" in
      enter)
        if [ -z "$KF_VALUE" ]; then DASH_NZS_EDIT=0; return 0; fi
        if dash_nzsec_set "$key" "$KF_VALUE"; then DASH_NZS_EDIT=0; fi
        return 0
        ;;
      esc) DASH_NZS_EDIT=0 DASH_NZ_ERR=""; return 0 ;;
      tab | btab | up | down | pgup | pgdn) return 0 ;;
    esac
    kit_field_key "$k" || return 0
    DASH_NZ_ERR=""
    return 0
  fi
  case "$k" in
    up | k) [ "$DASH_NZS_SEL" -le 0 ] || DASH_NZS_SEL=$((DASH_NZS_SEL - 1)) ;;
    down | j) [ "$DASH_NZS_SEL" -ge $((${#DASH_NZS_ROWS[@]} - 1)) ] || DASH_NZS_SEL=$((DASH_NZS_SEL + 1)) ;;
    e | space | right)
      [ -n "$row" ] || return 0
      KF_VALUE="${DASH_NZS_SRC[$key]:-}" KF_CUR="${#KF_VALUE}" DASH_NZS_EDIT=1 DASH_NZ_ERR=""
      ;;
    b)
      [ -n "$row" ] || return 0
      if [ "${DASH_NZS_FOUND:-0}" -le 0 ]; then t_r tui.nz.sec.nofound; DASH_NZ_ERR="$T_OUT"; return 0; fi
      DASH_NZS_CI=$(((DASH_NZS_CI + 1) % DASH_NZS_FOUND))
      dash_nzsec_set "$key" "${SF_CAND[$DASH_NZS_CI]}" || true
      ;;
    x | delete | backspace)
      unset 'DASH_NZS_SRC[$key]'
      DASH_NZ_ERR=""
      ;;
    R) dash_nzsec_find ;;
    *) return 1 ;;
  esac
  return 0
}

# --- State, what it adds to the command, the preview ---------------------------------------------------------------------------------------

dash_nzs_secrets_state() {
  local row key n=0 got=0
  dash_nzsec_rows
  for row in "${DASH_NZS_ROWS[@]}"; do
    n=$((n + 1))
    dash_nzsec_split "$row"
    [ -z "${DASH_NZS_SRC[$DASH_NZS_K]:-}" ] || got=$((got + 1))
  done
  if [ "$n" -eq 0 ]; then DASH_NZ_ST=ok; t_r tui.nz.sec.v_none; DASH_NZ_VAL="$T_OUT"; return 0; fi
  if [ "$got" -eq "$n" ]; then DASH_NZ_ST=ok; else DASH_NZ_ST=warn; fi
  t_r tui.nz.sec.v_n "$got" "$n"; DASH_NZ_VAL="$T_OUT"
}

dash_nzs_secrets_sig() {
  local k
  DASH_NZ_AS+="|sec"
  for k in "${!DASH_NZS_SRC[@]}"; do DASH_NZ_AS+=":$k"; done
}

dash_nzs_secrets_args() {
  local row s var name key src
  dash_nzsec_rows
  for row in "${DASH_NZS_ROWS[@]}"; do
    IFS='|' read -r s var name <<< "$row"
    key="$s|$var"
    [ -n "${DASH_NZS_SRC[$key]:-}" ] || continue
    src="${DASH_NZS_SRC[$key]}"
    # (the preview shows only the file: the folder is long and says nothing the row above did not; the command that runs has the whole path)
    if [ "$DASH_NZ_REAL" -ne 1 ]; then
      if [ "${UI_UTF8:-0}" -eq 1 ]; then src="…/${src##*/}"; else src=".../${src##*/}"; fi
    fi
    DASH_NZ_ARGV+=(--secret-file "$src:$name")
  done
}

# Last look before the command: a file that was chosen and is gone (or changed into something else) stops the creation here, not halfway.
dash_nzs_secrets_prepare() {
  local row s var key
  dash_nzsec_rows
  for row in "${DASH_NZS_ROWS[@]}"; do
    IFS='|' read -r s var _ <<< "$row"
    key="$s|$var"
    [ -n "${DASH_NZS_SRC[$key]:-}" ] || continue
    if ! sf_check "${DASH_NZS_SRC[$key]}"; then
      dash_nzsec_short "${DASH_NZS_SRC[$key]}"
      t_r "tui.nz.sec.err_$SF_WHY" "$DASH_NZS_SHORT"; DASH_NZ_ERR="$T_OUT"
      unset 'DASH_NZS_SRC[$key]'
      return 1
    fi
  done
  return 0
}

dash_nzs_secrets_preview() { # width
  local row s var name key list=""
  dash_nzsec_rows
  for row in "${DASH_NZS_ROWS[@]}"; do
    IFS='|' read -r s var name <<< "$row"
    key="$s|$var"
    [ -z "${DASH_NZS_SRC[$key]:-}" ] || list+="${list:+, }$name"
  done
  [ -n "$list" ] || return 0
  DASH_NZ_P+=("  secrets/ ${TH[dim]:-}$list${TH_RESET}")
}

# --- Drawing --------------------------------------------------------------------------------------------------------------------------

dash_nzs_secrets_render() { # width height
  local iw="$1" ih="$2" l dim="${TH[dim]:-}" r="$TH_RESET" row s var name key i icon src msg acc="${TH[accent]:-}" shown
  DASH_NZ_B=("")
  t_r tui.nz.help.secrets; dash_wrap "$T_OUT" "$iw"
  for l in "${DASH_WRAP[@]}"; do DASH_NZ_B+=("$dim$l$r"); done
  DASH_NZ_B+=("")
  dash_nzsec_rows
  if [ "${#DASH_NZS_ROWS[@]}" -eq 0 ]; then
    kit_state_icon ok; t_r tui.nz.sec.none; dash_wrap "$T_OUT" $((iw - 2))
    DASH_NZ_B+=("$KIT_ICON ${DASH_WRAP[0]}")
    for l in "${DASH_WRAP[@]:1}"; do DASH_NZ_B+=("  $l"); done
  fi
  i=0
  for row in "${DASH_NZS_ROWS[@]}"; do
    IFS='|' read -r s var name <<< "$row"
    key="$s|$var"
    src="${DASH_NZS_SRC[$key]:-}"
    if [ -n "$src" ]; then kit_state_icon ok; else kit_state_icon warn; fi
    icon="$KIT_ICON"
    if [ -n "$src" ]; then dash_nzsec_short "$src"; shown="$DASH_NZS_SHORT"; else t_r tui.nz.sec.missing; shown="$T_OUT"; fi
    if [ "$DASH_NZS_EDIT" -eq 1 ] && [ "$i" -eq "$DASH_NZS_SEL" ]; then
      DASH_NZ_B+=("$icon $acc$C_BLD$s $var$r  ${dim}→ secrets/$name$r")
      t_r tui.nz.sec.path
      kit_field_render "$T_OUT" "$KF_VALUE" "$KF_CUR" "$iw" label_width=8 focus=1 state=pend
      DASH_NZ_B+=("  $KIT_OUT")
    else
      printf -v msg '%s %s%s %s%s  %s→ secrets/%s%s' "$icon" "$C_BLD" "$s" "$var" "$r" "$dim" "$name" "$r"
      if [ "$i" -eq "$DASH_NZS_SEL" ]; then tui_fit "$msg" "$iw"; DASH_NZ_B+=("$TUI_SEL$TUI_OUT")
      else tui_fit "$msg" "$iw"; DASH_NZ_B+=("$TUI_OUT"); fi
      tui_fit "     $dim$shown$r" "$iw"; DASH_NZ_B+=("$TUI_OUT")
    fi
    i=$((i + 1))
  done
  # What was found in the usual folders.
  DASH_NZ_B+=("")
  if [ "${#DASH_NZS_ROWS[@]}" -gt 0 ]; then
    if [ "${DASH_NZS_FOUND:-0}" -gt 0 ]; then t_r tui.nz.sec.found "$DASH_NZS_FOUND"; DASH_NZ_B+=("$dim$T_OUT$r")
    else t_r tui.nz.sec.nofound; dash_wrap "$T_OUT" "$iw"; for l in "${DASH_WRAP[@]}"; do DASH_NZ_B+=("$dim$l$r"); done; fi
  fi
  # The unique secrets that are generated (names only: the values are in the file of answers and nowhere else).
  if [ "${DASH_NZV_GENN:-0}" -gt 0 ]; then
    DASH_NZ_B+=("")
    kit_state_icon ok; t_r tui.nz.sec.gen "$DASH_NZV_GENN" "$DASH_NZV_GENNAMES"; dash_wrap "$T_OUT" $((iw - 2))
    DASH_NZ_B+=("$KIT_ICON ${DASH_WRAP[0]}")
    for l in "${DASH_WRAP[@]:1}"; do DASH_NZ_B+=("  $l"); done
  elif [ "$DASH_NZ_DATA" -eq 1 ]; then
    DASH_NZ_B+=("")
    t_r tui.nz.sec.existing; dash_wrap "$T_OUT" "$iw"; for l in "${DASH_WRAP[@]}"; do DASH_NZ_B+=("$dim$l$r"); done
  elif [ "$DASH_NZ_SSL" -eq 0 ]; then
    DASH_NZ_B+=("")
    kit_state_icon warn; t_r tui.nz.sec.nossl; dash_wrap "$T_OUT" $((iw - 2))
    DASH_NZ_B+=("$KIT_ICON ${TH[warn]:-}${DASH_WRAP[0]}$r")
    for l in "${DASH_WRAP[@]:1}"; do DASH_NZ_B+=("  ${TH[warn]:-}$l$r"); done
  fi
}

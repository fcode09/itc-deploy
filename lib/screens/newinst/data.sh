#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # DASH_NZ_* belong to lib/screens/newinst.sh; KF_* to lib/ui/kit/field.sh
# Step 4 of the new-instance wizard: the data. Is it a municipality that starts empty (the first `init` seeds its databases) or one that
# already has data (it comes from PM2 or another deployment: the instance is marked as existing, `init` will refuse to seed it, and it
# reuses its databases and secrets)? Each option says in a sentence what it does and what it cannot undo. New is the proposed one.
#
# A NEW municipality also gets its own user of Mongo (one per instance, with access to the databases of that instance only): the user
# (`u`, the name of the instance by default) and the password (`c`; empty means one is generated, so it is optional). They are not variables of
# a file: the Variables step builds the Mongo URIs of the services with them (mongodb://user:password@host/db?authSource=admin, the password
# written as a URL needs it), and `init` creates the user in Mongo from what those URIs say.

DASH_NZM_USER="" DASH_NZM_PASS="" DASH_NZM_GEN="" DASH_NZM_EDIT=0 DASH_NZM_ERR=""   # typed user and password ("" = the default), the generated password, what is being typed (0 nothing, 1 user, 2 password)
DASH_NZM_U="" DASH_NZM_P="" DASH_NZM_URI=""                                           # the user and the password in use (as they go in a URI), the URI composed

dash_nzs_data_reset() {
  DASH_NZM_USER="" DASH_NZM_PASS="" DASH_NZM_GEN="" DASH_NZM_EDIT=0 DASH_NZM_ERR=""
}

dash_nzs_data_enter() { DASH_NZM_EDIT=0 DASH_NZM_ERR=""; }

dash_nzs_data_typing() { [ "$DASH_NZM_EDIT" -ne 0 ]; }

# A text as it goes inside a URI: everything but letters, digits and - . _ ~ as %XX (a password may hold @ : / ? # and the like).
DASH_NZM_ENC=""
dash_nzm_enc() { # text
  local s="$1" i c out="" hex
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z0-9._~-]) out+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  DASH_NZM_ENC="$out"
}

# The user and the password that the URIs carry, into DASH_NZM_U and DASH_NZM_P (encoded). The user is the name of the instance when none was typed;
# the password is the typed one or a generated one, made once and kept until the wizard closes. Returns 1 when there is no password to use
# (nothing typed and no way to generate one): the URIs then stay as the template has them.
dash_nzm_effective() {
  local u="${DASH_NZM_USER:-$DASH_NZ_NAME}" p="$DASH_NZM_PASS"
  DASH_NZM_U="" DASH_NZM_P=""
  [ -n "$u" ] || return 1
  if [ -z "$p" ]; then
    [ -n "$DASH_NZM_GEN" ] || DASH_NZM_GEN="$(envedit_random hex24 2> /dev/null || true)"
    p="$DASH_NZM_GEN"
  fi
  [ -n "$p" ] || return 1
  dash_nzm_enc "$u"; DASH_NZM_U="$DASH_NZM_ENC"
  dash_nzm_enc "$p"; DASH_NZM_P="$DASH_NZM_ENC"
}

# A URI of Mongo with the user and the password put in (and authSource=admin: the user lives in the admin database), into DASH_NZM_URI. Returns 1
# when the text is not a mongodb:// URI, already has credentials, or there is no password to put.
dash_nzm_compose() { # uri
  local rest sep="?"
  DASH_NZM_URI="$1"
  [[ "$1" == mongodb://* ]] || return 1
  rest="${1#mongodb://}"
  [[ "${rest%%[/?]*}" != *@* ]] || return 1
  dash_nzm_effective || return 1
  [[ "$rest" != *\?* ]] || sep="&"
  DASH_NZM_URI="mongodb://$DASH_NZM_U:$DASH_NZM_P@$rest${sep}authSource=admin"
}

# Is what was typed a name for a user of Mongo? Letters, digits, dot, hyphen and underscore, up to 64.
dash_nzm_user_ok() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; }

dash_nzs_data_key() { # key
  local k="$1" v
  if [ "$DASH_NZM_EDIT" -ne 0 ]; then
    case "$k" in
      enter)
        v="$KF_VALUE"
        if [ "$DASH_NZM_EDIT" -eq 1 ]; then
          if [ -n "$v" ] && ! dash_nzm_user_ok "$v"; then t_r tui.nz.data.m_bad_user; DASH_NZM_ERR="$T_OUT"; return 0; fi
          DASH_NZM_USER="$v"
        else
          DASH_NZM_PASS="$v"
        fi
        DASH_NZM_EDIT=0 DASH_NZM_ERR=""
        ;;
      esc) DASH_NZM_EDIT=0 DASH_NZM_ERR="" ;;
      tab | btab | up | down | pgup | pgdn) ;;
      *) kit_field_key "$k" || true; DASH_NZM_ERR="" ;;
    esac
    return 0
  fi
  case "$k" in
    up | k | left) DASH_NZ_DATA=0 DASH_NZ_ERR="" ;;
    down | j | right) DASH_NZ_DATA=1 DASH_NZ_ERR="" ;;
    space | x) DASH_NZ_DATA=$((1 - DASH_NZ_DATA)) DASH_NZ_ERR="" ;;
    n) DASH_NZ_DATA=0 DASH_NZ_ERR="" ;;
    e) DASH_NZ_DATA=1 DASH_NZ_ERR="" ;;
    u | c)
      [ "$DASH_NZ_DATA" -eq 0 ] || return 0
      if [ "$k" = u ]; then DASH_NZM_EDIT=1 KF_VALUE="$DASH_NZM_USER"; else DASH_NZM_EDIT=2 KF_VALUE="$DASH_NZM_PASS"; fi
      KF_CUR="${#KF_VALUE}" DASH_NZM_ERR="" DASH_NZ_ERR=""
      ;;
    *) return 1 ;;
  esac
  return 0
}

dash_nzs_data_state() {
  DASH_NZ_ST=ok
  if [ "$DASH_NZ_DATA" -eq 1 ]; then t_r tui.nz.data.v_existing; else t_r tui.nz.data.v_new; fi
  DASH_NZ_VAL="$T_OUT"
}

# The signature of what the step keeps (the model of the variables is built again when it changes).
dash_nzs_data_sig() { DASH_NZ_AS+="|d:$DASH_NZM_USER:${#DASH_NZM_PASS}:$DASH_NZM_EDIT"; }

# One option: the radio, its title and what it means (wrapped under it).
dash_nz_data_option() { # value title-key note-key width
  local on=0 radio acc="${TH[accent]:-}" dim="${TH[dim]:-}" r="$TH_RESET" l
  [ "$DASH_NZ_DATA" -ne "$1" ] || on=1
  if [ "$on" -eq 1 ]; then radio="$acc$UI_S_SEL (o)$r"; else radio="  ( )"; fi
  t_r "$2"
  if [ "$on" -eq 1 ]; then DASH_NZ_B+=("$TUI_SEL$radio $C_BLD$T_OUT$r"); else DASH_NZ_B+=("$radio $C_BLD$T_OUT$r"); fi
  t_r "$3"; dash_wrap "$T_OUT" $(($4 - 7))
  for l in "${DASH_WRAP[@]}"; do DASH_NZ_B+=("       $dim$l$r"); done
}

# The user and the password of Mongo (a new municipality): each one a row, or the field while it is typed.
dash_nz_data_mongo() { # width
  local iw="$1" dim="${TH[dim]:-}" r="$TH_RESET" l shown st=pend msg="" u
  t_r tui.nz.data.m_title; DASH_NZ_B+=("       ${C_BLD}$T_OUT$r")
  t_r tui.nz.data.m_note; dash_wrap "$T_OUT" $((iw - 7))
  for l in "${DASH_WRAP[@]}"; do DASH_NZ_B+=("       $dim$l$r"); done
  u="${DASH_NZM_USER:-$DASH_NZ_NAME}"
  if [ "$DASH_NZM_EDIT" -eq 1 ]; then
    t_r tui.nz.data.m_user
    [ -z "$KF_VALUE" ] || { if dash_nzm_user_ok "$KF_VALUE"; then st=ok; else st=err; t_r tui.nz.data.m_bad_user; msg="$T_OUT"; fi; }
    kit_field_render "$T_OUT" "$KF_VALUE" "$KF_CUR" $((iw - 7)) label_width=12 focus=1 state="$st" ${msg:+"msg=$msg"} placeholder="$u"
    DASH_NZ_B+=("       $KIT_OUT")
  else
    t_r tui.nz.data.m_user; printf -v shown '%-12s' "$T_OUT"
    t_r tui.nz.data.m_key_u
    DASH_NZ_B+=("       ${TH[accent]:-}$shown$r ${u:-…}  $dim$T_OUT$r")
  fi
  if [ "$DASH_NZM_EDIT" -eq 2 ]; then
    t_r tui.nz.data.m_pass
    kit_field_render "$T_OUT" "$KF_VALUE" "$KF_CUR" $((iw - 7)) label_width=12 focus=1 state=pend placeholder=""
    DASH_NZ_B+=("       $KIT_OUT")
  else
    t_r tui.nz.data.m_pass; printf -v shown '%-12s' "$T_OUT"
    if [ -n "$DASH_NZM_PASS" ]; then t_r tui.nz.data.m_typed; else t_r tui.nz.data.m_gen; fi
    l="$T_OUT"; t_r tui.nz.data.m_key_c
    DASH_NZ_B+=("       ${TH[accent]:-}$shown$r $l  $dim$T_OUT$r")
  fi
  [ -z "$DASH_NZM_ERR" ] || DASH_NZ_B+=("       ${TH[err]:-}$DASH_NZM_ERR$r")
}

dash_nzs_data_render() { # width height
  local iw="$1" l dim="${TH[dim]:-}" r="$TH_RESET"
  DASH_NZ_B=("")
  t_r tui.nz.help.data; dash_wrap "$T_OUT" "$iw"
  for l in "${DASH_WRAP[@]}"; do DASH_NZ_B+=("$dim$l$r"); done
  DASH_NZ_B+=("")
  dash_nz_data_option 0 tui.nz.data.new tui.nz.data.new_note "$iw"
  if [ "$DASH_NZ_DATA" -eq 0 ]; then
    DASH_NZ_B+=("")
    dash_nz_data_mongo "$iw"
  fi
  DASH_NZ_B+=("")
  dash_nz_data_option 1 tui.nz.data.existing tui.nz.data.existing_note "$iw"
  if [ "$DASH_NZ_DATA" -eq 1 ]; then
    DASH_NZ_B+=("")
    kit_state_icon warn; t_r tui.nz.data.warn; dash_wrap "$T_OUT" $((iw - 2))
    DASH_NZ_B+=("$KIT_ICON ${TH[warn]:-}${DASH_WRAP[0]}$r")
    for l in "${DASH_WRAP[@]:1}"; do DASH_NZ_B+=("  ${TH[warn]:-}$l$r"); done
  fi
}

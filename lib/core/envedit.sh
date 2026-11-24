#!/usr/bin/env bash
# shellcheck disable=SC2034  # results left in ED_* / ENVEDIT_* for the callers
# Safe reading and writing of the environment files of an instance. Sourced by lib/bootstrap.sh; requires ROOT.
#
#   - a value is written with an atomic rename: the file is rebuilt aside, so a failure halfway leaves the old one intact
#   - comments, blank lines and the order of the keys stay as they are; a value is kept byte by byte (`=`, quotes, spaces, `\`, empty)
#   - the file is rebuilt WITHOUT awk: awk -v would read `\n` and `\\` of a value as escapes
#   - a copy of the file (`<file>.bak`) is made before the first change of the session (the process); it has the same mode as the file
#   - a secret is never printed unless the caller asks for it: envedit_show masks it
#   - the "deployed" mark (the sum of each file when a deploy ends well) says which changes are not applied yet
# The validation of what is written is lib/core/envschema.sh; this file does not know what a variable means.

declare -gA ENVEDIT_BAKED=()   # files already copied in this session
ENVEDIT_MASK='********'

# Name of a variables file as a word: .env.s0 -> s0, .env.instance -> instance.
envedit_word() { printf '%s' "${1#.env.}"; }

# Files of variables that an instance has, in display order: leaves them in ENVEDIT_FILES (names, not paths).
ENVEDIT_FILES=()
envedit_files_r() { # instance
  local f dir="$INSTANCES_DIR/$1" s
  ENVEDIT_FILES=()
  [ ! -f "$dir/.env.instance" ] || ENVEDIT_FILES+=(.env.instance)
  for s in "${KNOWN_SERVICES[@]}"; do
    f=".env.$s"
    [ ! -f "$dir/$f" ] || ENVEDIT_FILES+=("$f")
  done
  return 0
}

# Writes to the standard output the content of $1 with KEY set to VALUE: every `KEY=` line is replaced, the key is added at the end
# when it was not there. A CRLF line keeps its CR. Nothing here starts a process.
# (A separate function so a test can make it fail halfway and prove that the file is not left half written.)
envedit_emit() { # file key value
  local line key="$2" val="$3" found=0 cr=""
  if [ -f "$1" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      cr=""
      if [[ "$line" == *$'\r' ]]; then cr=$'\r'; line="${line%$'\r'}"; fi
      if [[ "$line" == "$key="* ]]; then
        printf '%s=%s%s\n' "$key" "$val" "$cr"
        found=1
      else
        printf '%s%s\n' "$line" "$cr"
      fi
    done < "$1"
  fi
  [ "$found" = 1 ] || printf '%s=%s\n' "$key" "$val"
}

# Copy of the file before the first change of this session, once per file. Same mode as the original.
envedit_backup() { # file
  [ -f "$1" ] || return 0
  [ -z "${ENVEDIT_BAKED[$1]:-}" ] || return 0
  ( umask 077; cp -f "$1" "$1.bak" ) 2> /dev/null || return 1
  chmod --reference="$1" "$1.bak" 2> /dev/null || chmod 600 "$1.bak" 2> /dev/null || true
  ENVEDIT_BAKED[$1]=1
}

# Sets KEY=VALUE in a file, atomically. $4 = 1 when the variable is a secret: the file is then left readable only by its owner.
# No validation: that is envedit_save. Returns 1 when it could not write (the file is then exactly as it was).
envedit_set() { # file key value [secret]
  local file="$1" key="$2" val="$3" secret="${4:-0}" tmp
  tmp="$(umask 077; mktemp "$file.XXXXXX")" || return 1
  if ! envedit_emit "$file" "$key" "$val" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  envedit_backup "$file" || { rm -f "$tmp"; return 1; }
  if [ -f "$file" ]; then
    chmod --reference="$file" "$tmp" 2> /dev/null || chmod 600 "$tmp" 2> /dev/null || true
  fi
  [ "$secret" != 1 ] || chmod 600 "$tmp" 2> /dev/null || true
  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# Validated save of a variable of an instance. Leaves EV_RC / EV_MSG as the schema left them.
#   0 saved (EV_RC=2: with a warning in EV_MSG; EV_RC=1: written although invalid, only with force)
#   1 refused, nothing written (the value is not valid, the variable is fixed or unknown, a line break)
#   2 could not write (the file is as it was)
# $5 = 1 (the CLI's --force) writes a value that does not pass its validator and a key the glossary does not know. It never writes a
# fixed variable (the compose sets it) or a value with a line break.
envedit_save() { # instance file key value [force]
  local inst="$1" file="$2" key="$3" val="$4" force="${5:-0}" id="$2|$3" secret=0
  envschema_load
  EV_RC=0 EV_MSG=""
  if [[ "$val" == *$'\n'* || "$val" == *$'\r'* ]]; then ev_fail envschema.err.newline; return 1; fi
  if [ -z "${ENV_KEY[$id]+x}" ]; then
    if [ "$force" != 1 ]; then ev_fail envschema.err.unknown; return 1; fi
    envschema_classify "$file" "$key"
    secret="$ES_SECRET"
  else
    secret="${ENV_SECRET[$id]}"
    envschema_check_r "$file" "$key" "$val" "$inst"
    if [ "$EV_RC" = 1 ] && { [ "$force" != 1 ] || [ "${ENV_TYPE[$id]}" = fixed ]; }; then return 1; fi
  fi
  envedit_set "$INSTANCES_DIR/$inst/$file" "$key" "$val" "$secret" || return 2
  return 0
}

# What to show of a value: a secret is masked (an empty one is shown as empty: there is nothing to protect).
ED_SHOW=""
envedit_show() { # file key value   (the result is in ED_SHOW)
  envschema_load
  if [ "${ENV_SECRET[$1|$2]:-0}" = 1 ] && [ -n "$3" ]; then ED_SHOW="$ENVEDIT_MASK"; else ED_SHOW="$3"; fi
}

# Status of one variable of an instance: ED_STATE is
#   missing   required and empty          invalid   the value does not pass its validator      warn   valid with a warning
#   example   still has the CAMBIAR… of the template (deploy refuses it)
#   ok        has a valid value           default   not written, but it has a default          unset  optional and empty
#   fixed     set by the compose or the image
ED_STATE=""
ED_VALUE=""
envedit_state_r() { # instance file key
  local id="$2|$3" path="$INSTANCES_DIR/$1/$2"
  envschema_load
  get_var_r "$path" "$3"
  ED_VALUE="$GV"
  if [ "${ENV_TYPE[$id]:-}" = fixed ]; then ED_STATE=fixed; return 0; fi
  if [ -z "$ED_VALUE" ]; then
    if [ "${ENV_REQUIRED[$id]:-0}" = 1 ]; then ED_STATE=missing
    elif [ "${ENV_HASDEF[$id]:-0}" = 1 ] && [ -n "${ENV_DEFAULT[$id]:-}" ]; then ED_STATE=default
    else ED_STATE="unset"; fi
    return 0
  fi
  # The templates write CAMBIAR… where a value has to be put: deploy refuses it, so here it is not a value either.
  if [[ "$ED_VALUE" == *CAMBIAR* ]]; then ED_STATE=example; return 0; fi
  envschema_check_r "$2" "$3" "$ED_VALUE" "$1"
  case "$EV_RC" in 1) ED_STATE=invalid ;; 2) ED_STATE=warn ;; *) ED_STATE=ok ;; esac
}

# ---------- generated values ----------

# A random value of a kind (shared, hex32, hex24, b64-32) on the standard output. Fails when openssl is not there.
envedit_random() { # kind
  command -v openssl > /dev/null 2>&1 || return 1
  case "$1" in
    shared | hex32) openssl rand -hex 32 ;;
    hex24) openssl rand -hex 24 ;;
    b64-32) openssl rand -base64 32 ;;
    *) return 1 ;;
  esac
}

# Files of an instance that have this key with the "shared" generator (the same value in every service: a token signed by one has to
# be read by the others). Leaves them in ENVEDIT_SHARED.
ENVEDIT_SHARED=()
envedit_shared_files_r() { # instance key
  local f
  ENVEDIT_SHARED=()
  envschema_load
  envedit_files_r "$1"
  for f in "${ENVEDIT_FILES[@]}"; do
    [ "${ENV_GEN[$f|$2]:-}" = shared ] && ENVEDIT_SHARED+=("$f")
  done
  return 0
}

# Generates the value of a variable and writes it. A "shared" one is written in every file that has it, with the same value.
# Leaves the files written in ENVEDIT_WRITTEN. Returns 1 when the variable has no generator or openssl is missing, 2 when it could not
# write. The value is never printed.
ENVEDIT_WRITTEN=()
envedit_generate() { # instance file key
  local inst="$1" file="$2" key="$3" kind val f
  envschema_load
  kind="${ENV_GEN[$file|$key]:-}"
  [ -n "$kind" ] || return 1
  val="$(envedit_random "$kind")" || return 1
  [ -n "$val" ] || return 1
  ENVEDIT_WRITTEN=()
  if [ "$kind" = shared ]; then
    envedit_shared_files_r "$inst" "$key"
    for f in "${ENVEDIT_SHARED[@]}"; do
      envedit_set "$INSTANCES_DIR/$inst/$f" "$key" "$val" 1 || return 2
      ENVEDIT_WRITTEN+=("$f")
    done
  else
    envedit_set "$INSTANCES_DIR/$inst/$file" "$key" "$val" 1 || return 2
    ENVEDIT_WRITTEN+=("$file")
  fi
  return 0
}

# ---------- deployed mark ----------
# When a deploy ends well, the sum of each file it used is recorded in .deployed (ENV_SUM_<FILE>). A file whose sum no longer
# matches has changes that are not applied yet. It records the sum, never the content: nothing of a secret reaches .deployed.

ED_SUM=""
# Sum of a file (empty when it does not exist or there is no tool to sum it).
envedit_sum_r() { # path
  local h=""
  ED_SUM=""
  [ -f "$1" ] || return 0
  if command -v sha256sum > /dev/null 2>&1; then
    read -r h _ < <(sha256sum < "$1") || true
  elif command -v cksum > /dev/null 2>&1; then
    read -r h _ < <(cksum < "$1") || true
  fi
  ED_SUM="$h"
}

# Name of the key of a file's mark in .deployed: .env.s0 -> ENV_SUM_S0.
envedit_sum_key() { local w="${1#.env.}"; printf 'ENV_SUM_%s' "${w^^}"; }

# Records the sums of the files that a deploy used: the .env of each service given and, when `all` is 1 (the whole instance was
# deployed), .env.instance too. A file that is not there is skipped. Returns 1 when .deployed could not be written.
envedit_mark_deployed() { # instance all(0|1) service...
  local inst="$1" all="$2" dir f svc
  shift 2
  dir="$INSTANCES_DIR/$inst"
  local -a files=()
  [ "$all" != 1 ] || files+=(.env.instance)
  for svc in "$@"; do files+=(".env.$svc"); done
  for f in "${files[@]}"; do
    [ -f "$dir/$f" ] || continue
    envedit_sum_r "$dir/$f"
    [ -n "$ED_SUM" ] || continue
    set_var "$dir/.deployed" "$(envedit_sum_key "$f")" "$ED_SUM" || return 1
  done
}

# Is the file as it was when it was deployed? ED_DEPLOY is
#   synced    the same as at the last deploy       pending   it changed since           unknown   there is no mark (a deploy before this
#   existed, or never deployed): nothing is said about it
ED_DEPLOY=""
envedit_deploy_state_r() { # instance file
  local dir="$INSTANCES_DIR/$1" cur mark
  get_var_r "$dir/.deployed" "$(envedit_sum_key "$2")"
  mark="$GV"
  if [ -z "$mark" ]; then ED_DEPLOY=unknown; return 0; fi
  envedit_sum_r "$dir/$2"
  cur="$ED_SUM"
  if [ "$cur" = "$mark" ]; then ED_DEPLOY=synced; else ED_DEPLOY=pending; fi
}

# The files with changes not applied yet, one per line.
envedit_pending() { # instance
  local f
  envedit_files_r "$1"
  for f in "${ENVEDIT_FILES[@]}"; do
    envedit_deploy_state_r "$1" "$f"
    [ "$ED_DEPLOY" != pending ] || printf '%s\n' "$f"
  done
}

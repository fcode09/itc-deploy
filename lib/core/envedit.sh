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
  ENVEDIT_OFF_FOR=""
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

# Copy of the file before the first change of this session (the process: a new `deltactl env` run copies again, over the old one),
# once per file. It is ALWAYS readable only by its owner: what it holds is what the file held, secrets included, whatever its mode.
envedit_backup() { # file
  [ -f "$1" ] || return 0
  # (`new` writes the answers into files it has just made from the templates: there is nothing to go back to, so it asks for no copy)
  [ "${ENVEDIT_NOBACKUP:-0}" != 1 ] || return 0
  [ -z "${ENVEDIT_BAKED[$1]:-}" ] || return 0
  ( umask 077; cp -f "$1" "$1.bak" ) 2> /dev/null || return 1
  chmod 600 "$1.bak" 2> /dev/null || return 1   # cp keeps the mode of an old .bak that was already there
  ENVEDIT_BAKED[$1]=1
}

# Rebuilds a file aside (a temporary next to it) with KEY=VALUE set, without touching the file: the path is left in ED_TMP.
# $4 = 1 when the variable is a secret: the file is then left readable only by its owner. Returns 1 when it could not (nothing is left).
ED_TMP=""
envedit_stage() { # file key value [secret]
  local file="$1" key="$2" val="$3" secret="${4:-0}" tmp
  ED_TMP=""
  tmp="$(umask 077; mktemp "$file.XXXXXX" 2> /dev/null)" || return 1   # (no message: the panel draws on this terminal)
  if ! envedit_emit "$file" "$key" "$val" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if [ -f "$file" ]; then
    chmod --reference="$file" "$tmp" 2> /dev/null || chmod 600 "$tmp" 2> /dev/null || true
  fi
  [ "$secret" != 1 ] || chmod 600 "$tmp" 2> /dev/null || true
  ED_TMP="$tmp"
}

# Puts what envedit_stage prepared in place of the file (the copy first): one rename. Returns 1 when it could not (the temporary is removed).
envedit_commit() { # file tmp
  envedit_backup "$1" || { rm -f "$2"; return 1; }
  mv -f "$2" "$1" || { rm -f "$2"; return 1; }
}

# Sets KEY=VALUE in a file, atomically. $4 = 1 when the variable is a secret: the file is then left readable only by its owner.
# No validation: that is envedit_save. Returns 1 when it could not write (the file is then exactly as it was).
envedit_set() { # file key value [secret]
  envedit_stage "$1" "$2" "$3" "${4:-0}" || return 1
  envedit_commit "$1" "$ED_TMP"
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
  # Whatever calls this, a key that is not a variable name never goes into a file (a line break in it would add lines).
  if ! [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then ev_fail envschema.err.key; return 1; fi
  if envedit_is_secret "$file" "$key"; then secret=1; fi
  if [ -z "${ENV_KEY[$id]+x}" ]; then
    if [ "$force" != 1 ]; then ev_fail envschema.err.unknown; return 1; fi
  else
    envschema_check_r "$file" "$key" "$val" "$inst"
    # --force never writes a fixed variable, nor an INSTANCE that is not the folder's name (another compose project: duplicated containers)
    if [ "$EV_RC" = 1 ] && { [ "$force" != 1 ] || [ "${ENV_TYPE[$id]}" = fixed ] || [ "$id" = ".env.instance|INSTANCE" ]; }; then return 1; fi
  fi
  envedit_set "$INSTANCES_DIR/$inst/$file" "$key" "$val" "$secret" || return 2
  ENVEDIT_OFF_FOR=""   # (it may have been COMPOSE_PROFILES)
  return 0
}

# Is a variable of a file a secret? The one answer for everything that prints a value (list, get, set, the editor): the glossary's when
# it knows the variable, the rules by name (envschema_classify) when it does not, so DB_PASSWD or JWT_SECRET_OLD typed by hand are not
# printed either. Returns 0 for a secret. Nothing here starts a process.
envedit_is_secret() { # file key
  envschema_load
  if [ -n "${ENV_KEY[$1|$2]+x}" ]; then [ "${ENV_SECRET[$1|$2]:-0}" = 1 ]; return; fi
  envschema_classify "$1" "$2"
  [ "$ES_SECRET" = 1 ]
}

# What to show of a value: a secret is masked (an empty one is shown as empty: there is nothing to protect).
ED_SHOW=""
envedit_show() { # file key value   (the result is in ED_SHOW)
  if [ -n "$3" ] && envedit_is_secret "$1" "$2"; then ED_SHOW="$ENVEDIT_MASK"; else ED_SHOW="$3"; fi
}

# Status of one variable of an instance: ED_STATE is
#   missing   required and empty          invalid   the value does not pass its validator      warn   valid with a warning
#   example   still has the CAMBIAR… of the template (deploy refuses it)
#   ok        has a valid value           default   not written, but it has a default          unset  optional and empty
#   fixed     set by the compose or the image
ED_STATE=""
ED_VALUE=""
# The same for a value the caller already has (the editor of the panel keeps the values it is changing before they are written): nothing is
# read from the file. EV_MSG is the message of the validator for `invalid` and `warn`.
envedit_state_value_core_r() { # instance file key value
  local id="$2|$3" val="$4"
  envschema_load
  ED_VALUE="$val"
  EV_RC=0 EV_MSG=""
  if [ "${ENV_TYPE[$id]:-}" = fixed ]; then ED_STATE=fixed; return 0; fi
  if [ -z "$val" ]; then
    if [ "${ENV_REQUIRED[$id]:-0}" = 1 ]; then ED_STATE=missing
    elif [ "${ENV_HASDEF[$id]:-0}" = 1 ] && [ -n "${ENV_DEFAULT[$id]:-}" ]; then ED_STATE=default
    else ED_STATE="unset"; fi
    return 0
  fi
  # The templates write CAMBIAR… where a value has to be put: deploy refuses it, so here it is not a value either.
  if [[ "$val" == *CAMBIAR* ]]; then ED_STATE=example; return 0; fi
  envschema_check_r "$2" "$3" "$val" "$1"
  case "$EV_RC" in 1) ED_STATE=invalid ;; 2) ED_STATE=warn ;; *) ED_STATE=ok ;; esac
}

# The variables of a service the instance does not run (it is not in COMPOSE_PROFILES) are not asked for: `deploy` and `new` already skip
# them, so what the editor, `env list` and the summary count as "to fill in" has to skip them too (a new instance has the file of every
# service of the catalog, and the three variables of one it does not use would stay pending for ever). The set is read from .env.instance
# when it is needed and when the files of the instance are read again; a save drops it.
declare -gA ENVEDIT_OFF=()
ENVEDIT_OFF_FOR=""
envedit_off_load_r() { # instance
  local s a
  local -A on=()
  ENVEDIT_OFF=()
  ENVEDIT_OFF_FOR="$1"
  svc_active_r "$1"
  # No list (a model that is not on disk yet, or a broken COMPOSE_PROFILES): everything is asked for, as it always was.
  [ "${#SVC_ACTIVE[@]}" -gt 0 ] || return 0
  for a in "${SVC_ACTIVE[@]}"; do on[$a]=1; done
  for s in "${KNOWN_SERVICES[@]}"; do [ -n "${on[$s]:-}" ] || ENVEDIT_OFF[$s]=1; done
}

# The service a variable belongs to, into ED_OWNER: every variable of `.env.<service>`; in .env.instance those that start with its name
# (ROBIN_TAG, ROBIN_PORT...). Empty for the rest (INSTANCE, COMPOSE_PROFILES, REGISTRY, DATA_DIR).
ED_OWNER=""
envedit_owner() { # file key
  local s
  ED_OWNER=""
  case "$1" in
    .env.instance)
      for s in "${KNOWN_SERVICES[@]}"; do
        if [[ "$2" == "${s^^}_"* ]]; then ED_OWNER="$s"; return 0; fi
      done
      ;;
    .env.*) ED_OWNER="${1#.env.}" ;;
  esac
  return 0
}

envedit_state_value_r() { # instance file key value
  envedit_state_value_core_r "$@"
  case "$ED_STATE" in missing | example) ;; *) return 0 ;; esac
  [ "$ENVEDIT_OFF_FOR" = "$1" ] || envedit_off_load_r "$1"
  envedit_owner "$2" "$3"
  if [ -n "$ED_OWNER" ] && [ -n "${ENVEDIT_OFF[$ED_OWNER]:-}" ]; then ED_STATE="unset"; fi
  return 0
}

envedit_state_r() { # instance file key
  get_var_r "$INSTANCES_DIR/$1/$2" "$3"
  envedit_state_value_r "$1" "$2" "$3" "$GV"
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
  local inst="$1" file="$2" key="$3" kind val
  envschema_load
  kind="${ENV_GEN[$file|$key]:-}"
  [ -n "$kind" ] || return 1
  val="$(envedit_random "$kind")" || return 1
  [ -n "$val" ] || return 1
  ENVEDIT_WRITTEN=()
  local -a targets=() tmps=() origs=()
  local i path
  if [ "$kind" = shared ]; then
    envedit_shared_files_r "$inst" "$key"
    targets=("${ENVEDIT_SHARED[@]}")
  else
    targets=("$file")
  fi
  # All or nothing: every file is rebuilt aside, with a private copy of what it is now, and only then are they put in place. A
  # failure on the way leaves the files as they were (a shared secret with two different values would sign in one service what the
  # others cannot read).
  for i in "${!targets[@]}"; do
    path="$INSTANCES_DIR/$inst/${targets[$i]}"
    if envedit_stage "$path" "$key" "$val" 1; then
      tmps+=("$ED_TMP")
      if ( umask 077; cp -f "$path" "$ED_TMP.orig" ) 2> /dev/null; then origs+=("$ED_TMP.orig"); continue; fi
    fi
    rm -f ${tmps[@]+"${tmps[@]}"} ${origs[@]+"${origs[@]}"}
    return 2
  done
  for i in "${!targets[@]}"; do
    if ! envedit_backup "$INSTANCES_DIR/$inst/${targets[$i]}"; then
      rm -f "${tmps[@]}" "${origs[@]}"
      return 2
    fi
  done
  for i in "${!targets[@]}"; do
    if ! mv -f "${tmps[$i]}" "$INSTANCES_DIR/$inst/${targets[$i]}"; then
      # A rename that fails after another went through (almost never: the same folder): the earlier files go back to what they were.
      local j
      for ((j = 0; j < i; j++)); do mv -f "${origs[$j]}" "$INSTANCES_DIR/$inst/${targets[$j]}" 2> /dev/null || true; done
      rm -f "${tmps[@]}" "${origs[@]}"
      ENVEDIT_WRITTEN=()
      return 2
    fi
    ENVEDIT_WRITTEN+=("${targets[$i]}")
  done
  rm -f "${origs[@]}"
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
  # Only a real hash: a 32-bit CRC lets a change go unnoticed, and a mark that does not tell is better than a mark that lies. Without
  # sha256sum nothing is marked and `env pending` says it cannot know.
  if command -v sha256sum > /dev/null 2>&1; then
    read -r h _ < <(sha256sum < "$1") || true
  fi
  ED_SUM="$h"
}

# Name of the key of a file's mark in .deployed: .env.s0 -> ENV_SUM_S0.
envedit_sum_key() { local w="${1#.env.}"; printf 'ENV_SUM_%s' "${w^^}"; }

# The sums of the files that a deploy is about to use, taken BEFORE compose reads them (a deploy can take minutes, and a value changed
# meanwhile is not in the containers: it has to stay pending). Leaves them in ENVEDIT_SNAP (file -> sum).
declare -gA ENVEDIT_SNAP=()
envedit_snapshot() { # instance all(0|1) service...
  local inst="$1" all="$2" dir f svc
  shift 2
  dir="$INSTANCES_DIR/$inst"
  local -a files=()
  ENVEDIT_SNAP=()
  [ "$all" != 1 ] || files+=(.env.instance)
  for svc in "$@"; do files+=(".env.$svc"); done
  for f in "${files[@]}"; do
    [ -f "$dir/$f" ] || continue
    envedit_sum_r "$dir/$f"
    [ -n "$ED_SUM" ] || continue
    ENVEDIT_SNAP[$f]="$ED_SUM"
  done
  return 0
}

# Records the snapshot in .deployed (only when the deploy ended well). Returns 1 when .deployed could not be written.
envedit_mark_snapshot() { # instance
  local f dir="$INSTANCES_DIR/$1" rc=0
  for f in "${!ENVEDIT_SNAP[@]}"; do
    set_var "$dir/.deployed" "$(envedit_sum_key "$f")" "${ENVEDIT_SNAP[$f]}" || rc=1
  done
  ENVEDIT_SNAP=()
  return "$rc"
}

# Records the sums of the files that a deploy used: the .env of each service given and, when `all` is 1 (the whole instance was
# deployed), .env.instance too. A file that is not there is skipped. Returns 1 when .deployed could not be written.
# (A deploy takes the snapshot before it starts and marks it when it ends well; this is both at once.)
envedit_mark_deployed() { # instance all(0|1) service...
  envedit_snapshot "$@"
  envedit_mark_snapshot "$1"
}

# Is the file as it was when it was deployed? ED_DEPLOY is
#   synced    the same as at the last deploy       pending   it changed since           unknown   there is no mark (a deploy before this
#   existed, or never deployed): nothing is said about it
ED_DEPLOY=""
envedit_deploy_state_r() { # instance file
  local dir="$INSTANCES_DIR/$1" cur mark
  # The file of a service the instance does not run is never deployed: there is nothing to apply (and no mark to be missing).
  envedit_owner "$2" ""
  if [ -n "$ED_OWNER" ]; then
    [ "$ENVEDIT_OFF_FOR" = "$1" ] || envedit_off_load_r "$1"
    if [ -n "${ENVEDIT_OFF[$ED_OWNER]:-}" ]; then ED_DEPLOY=synced; return 0; fi
  fi
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

#!/usr/bin/env bash
# shellcheck disable=SC2034  # ENVSYNC_* are read by lib/cmd/env.sh, lib/cmd/check.sh and the panel
# The variables of a template that the .env file of an instance does not have yet. The templates are copied when a file is made, so an
# instance that already exists never receives what a template gets later (a new variable, a service's new setting): this finds it and
# writes it. Sourced by lib/bootstrap.sh after lib/core/envedit.sh.
#
# What it does and does not do:
#   - A variable is "new" when the template has it as `KEY=value` and the file has neither `KEY=` nor a commented `# KEY=` (a commented one is
#     a decision of the person: it stays as it is).
#   - It only ADDS: at the end of the file, each with the comment lines that sit right above it in the template and the template's example
#     value. It never changes a value that is there and never deletes. A variable the file has and neither the template nor the glossary know
#     is "obsolete": it is reported, not touched.
#   - The files of a service the instance does not run (it is not in COMPOSE_PROFILES) are left alone unless they are asked for by name.
#   - The write is the one of `env set` (a temporary next to the file, the copy `<file>.bak` readable only by its owner, one rename), so a
#     failure leaves the file as it was. The sums of the deploy marks change by themselves: the file shows as pending until the next deploy.
# Nothing here prints; the results are in the arrays below. Everything is read with `read` and parameter expansion.

ENVSYNC_NEW=()         # keys the template has and the file lacks, in the order of the template
ENVSYNC_OBSOLETE=()    # keys the file has and neither the template nor the glossary know
ENVSYNC_ADDED=()       # keys envsync_apply wrote
ENVSYNC_TPL=""         # the template of the file ("" when it has none)
declare -gA ENVSYNC_BLOCK=() ENVSYNC_VALUE=()   # by key: the comment lines above it (joined by newlines) and its example value
ENVSYNC_TKEYS=()       # the keys of the template written as KEY=value, in order
declare -gA ENVSYNC_TKNOWN=()   # every key the template mentions, also the commented-out ones

# The template of a file of the instance, into ENVSYNC_TPL ("" when it has none).
envsync_template_r() { # file
  local s
  ENVSYNC_TPL=""
  case "$1" in
    .env.instance) ENVSYNC_TPL="$ROOT/templates/.env.instance.example" ;;
    .env.*)
      s="${1#.env.}"
      [ -z "${CAT_TEMPLATE[$s]:-}" ] || ENVSYNC_TPL="$ROOT/templates/${CAT_TEMPLATE[$s]}"
      ;;
  esac
  [ -f "$ENVSYNC_TPL" ] || ENVSYNC_TPL=""
}

# Reads a template: ENVSYNC_TKEYS / ENVSYNC_VALUE / ENVSYNC_BLOCK / ENVSYNC_TKNOWN.
# The comment of a variable is the run of comment lines right above it (a blank line or a `# --- section ---` banner ends it).
envsync_scan_template() { # template
  local line key cm=""
  ENVSYNC_TKEYS=() ENVSYNC_VALUE=() ENVSYNC_BLOCK=() ENVSYNC_TKNOWN=()
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      ENVSYNC_TKEYS+=("$key") ENVSYNC_VALUE[$key]="${BASH_REMATCH[2]}" ENVSYNC_BLOCK[$key]="$cm" ENVSYNC_TKNOWN[$key]=1
      cm=""
    elif [[ "$line" =~ ^#[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]]; then
      ENVSYNC_TKNOWN[${BASH_REMATCH[1]}]=1
      cm=""
    elif [[ "$line" == "# ---"* ]]; then
      cm=""
    elif [[ "$line" == \#* ]]; then
      cm+="${cm:+$'\n'}$line"
    else
      cm=""
    fi
  done < "$1"
}

# Compares one file of an instance with its template: ENVSYNC_NEW and ENVSYNC_OBSOLETE. Returns 1 when it cannot compare (the file is not
# there, it has no template). A file of a service the instance does not run gives nothing unless $3 is "named".
envsync_r() { # instance file [named]
  local inst="$1" file="$2" path="$INSTANCES_DIR/$1/$2" line key
  local -A has=() commented=()
  ENVSYNC_NEW=() ENVSYNC_OBSOLETE=()
  [ -f "$path" ] || return 1
  envsync_template_r "$file"
  [ -n "$ENVSYNC_TPL" ] || return 1
  envedit_owner "$file" ""
  if [ -n "$ED_OWNER" ] && [ "${3:-}" != named ]; then
    [ "$ENVEDIT_OFF_FOR" = "$inst" ] || envedit_off_load_r "$inst"
    [ -z "${ENVEDIT_OFF[$ED_OWNER]:-}" ] || return 0
  fi
  envsync_scan_template "$ENVSYNC_TPL"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then has[${BASH_REMATCH[1]}]=1
    elif [[ "$line" =~ ^#[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]]; then commented[${BASH_REMATCH[1]}]=1; fi
  done < "$path"
  envschema_load
  for key in "${ENVSYNC_TKEYS[@]}"; do
    [ -z "${has[$key]:-}" ] && [ -z "${commented[$key]:-}" ] || continue
    # in .env.instance the settings of a service that is not run are not asked for either (ROBIN_TAG of an instance without robin)
    if [ "$file" = ".env.instance" ]; then
      envedit_owner "$file" "$key"
      if [ -n "$ED_OWNER" ]; then
        [ "$ENVEDIT_OFF_FOR" = "$inst" ] || envedit_off_load_r "$inst"
        [ -z "${ENVEDIT_OFF[$ED_OWNER]:-}" ] || continue
      fi
    fi
    ENVSYNC_NEW+=("$key")
  done
  for key in "${!has[@]}"; do
    [ -z "${ENVSYNC_TKNOWN[$key]:-}" ] && [ -z "${ENV_KEY[$file|$key]+x}" ] || continue
    ENVSYNC_OBSOLETE+=("$key")
  done
  # (an array in the order of the keys of an associative one is not stable)
  if [ "${#ENVSYNC_OBSOLETE[@]}" -gt 1 ]; then
    mapfile -t ENVSYNC_OBSOLETE < <(printf '%s\n' "${ENVSYNC_OBSOLETE[@]}" | sort)
  fi
  return 0
}

# The files of the instance that have something new to say, one per line: only the ones that are compared. Leaves the count in ENVSYNC_TOTAL.
ENVSYNC_TOTAL=0
envsync_files_r() { # instance
  local f
  ENVSYNC_TOTAL=0
  envedit_files_r "$1"
  for f in "${ENVEDIT_FILES[@]}"; do
    envsync_r "$1" "$f" || continue
    [ "${#ENVSYNC_NEW[@]}" -eq 0 ] || { ENVSYNC_TOTAL=$((ENVSYNC_TOTAL + ${#ENVSYNC_NEW[@]})); printf '%s\n' "$f"; }
  done
}

# The text a template value becomes in an instance: the markers CAMBIAR_<word>_INSTANCIA are the name of the instance (as `new` does).
envsync_value() { # instance value
  local v="$2" w
  while [[ "$v" =~ CAMBIAR_([a-z]+)_INSTANCIA ]]; do
    w="${BASH_REMATCH[1]}"
    v="${v//CAMBIAR_${w}_INSTANCIA/${w}_$1}"
  done
  printf '%s' "$v"
}

# Writes the new variables of a file (the ones envsync_r finds) at its end. Leaves what was written in ENVSYNC_ADDED. Returns 1 when it could
# not write (the file is then exactly as it was), 0 when it wrote or had nothing to write.
envsync_apply() { # instance file [named]
  local inst="$1" file="$2" path="$INSTANCES_DIR/$1/$2" tmp key val svc
  ENVSYNC_ADDED=()
  envsync_r "$inst" "$file" "${3:-}" || return 0
  [ "${#ENVSYNC_NEW[@]}" -gt 0 ] || return 0
  tmp="$(umask 077; mktemp "$path.XXXXXX" 2> /dev/null)" || return 1
  {
    cat "$path"
    # the last line of the file may have no line break
    [ -z "$(tail -c1 "$path" 2> /dev/null)" ] || printf '\n'
    printf '\n# --- Variables nuevas de la plantilla (./deltactl env %s sync) ---\n' "$inst"
    for key in "${ENVSYNC_NEW[@]}"; do
      [ -z "${ENVSYNC_BLOCK[$key]}" ] || printf '%s\n' "${ENVSYNC_BLOCK[$key]}"
      val="$(envsync_value "$inst" "${ENVSYNC_VALUE[$key]}")"
      # the port of a service: the first free one, not the template's example
      if [ "$file" = ".env.instance" ] && [[ "$key" == *_PORT ]]; then
        svc="${key%_PORT}"; svc="${svc,,}"
        if valid_service "$svc" && svc_free_port "$inst" "$svc"; then val="$SVC_PORT"; fi
      fi
      printf '%s=%s\n' "$key" "$val"
    done
  } > "$tmp" 2> /dev/null || { rm -f "$tmp"; return 1; }
  chmod --reference="$path" "$tmp" 2> /dev/null || chmod 600 "$tmp" 2> /dev/null || true
  envedit_commit "$path" "$tmp" || return 1
  ENVSYNC_ADDED=("${ENVSYNC_NEW[@]}")
  ENVEDIT_OFF_FOR=""
  return 0
}

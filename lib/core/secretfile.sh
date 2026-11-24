#!/usr/bin/env bash
# shellcheck disable=SC2034  # SF_* are read by lib/cmd/new.sh, the new-instance wizard of the panel and the tests
# Files that go to instances/<name>/secrets/ (the Firebase service-account JSON of the push notifications, for example): is a path a file that can
# go there, and which files on this machine look like one. Sourced by lib/bootstrap.sh; pure Bash, never prints what is inside a file.
#
#   sf_valid_name <name>        a name for a file of secrets/: letters, digits, dot, hyphen, underscore; no slash, no "..", no leading dot or hyphen
#   sf_check <path>             0 when <path> is a regular file that can be read, not empty, at most SF_MAX_BYTES and a JSON object.
#                               1 otherwise, with the reason in SF_WHY: missing | notfile | unreadable | empty | toobig | notjson
#                               (the content is never in a message: a service account is a secret)
#   sf_candidates               fills SF_CAND (at most 8 paths) with the *.json files of the usual folders (Downloads, the home folder, the
#                               current folder, the root of the repository) whose name looks like a service account; SF_DIRS (a list separated by
#                               ":") replaces the folders, and DELTACTL_SECRET_DIRS does the same inside the tests
#   sf_install <src> <instance dir> <name>   copies it to <dir>/secrets/<name> with mode 600 (the folder must exist)

SF_MAX_BYTES=131072
SF_WHY="" SF_CAND=()
SF_DIRS=""

sf_valid_name() { # name
  [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$ ]] && [[ "$1" != *..* ]]
}

# --- A small JSON reader: it only says whether the text is JSON (an object at the top). No fork; the files are small. -------------------------
SF_S="" SF_I=0 SF_D=0

sf_ws() {
  local c
  while :; do
    c="${SF_S:SF_I:1}"
    case "$c" in " " | $'\t' | $'\r' | $'\n') SF_I=$((SF_I + 1)) ;; *) return 0 ;; esac
  done
}

sf_string() { # at the opening quote
  local c rest pre
  SF_I=$((SF_I + 1))
  while :; do
    rest="${SF_S:SF_I}"
    [ -n "$rest" ] || return 1
    pre="${rest%%[\"\\]*}"
    [ "$pre" != "$rest" ] || return 1
    case "$pre" in *[[:cntrl:]]*) return 1 ;; esac
    SF_I=$((SF_I + ${#pre}))
    c="${SF_S:SF_I:1}"
    if [ "$c" = '"' ]; then SF_I=$((SF_I + 1)); return 0; fi
    # a backslash: one character after it, and four hex digits after a u
    c="${SF_S:SF_I + 1:1}"
    case "$c" in
      '"' | '\' | / | b | f | n | r | t) SF_I=$((SF_I + 2)) ;;
      u) [[ "${SF_S:SF_I + 2:4}" =~ ^[0-9A-Fa-f]{4}$ ]] || return 1; SF_I=$((SF_I + 6)) ;;
      *) return 1 ;;
    esac
  done
}

sf_value() {
  local c="${SF_S:SF_I:1}" rest
  SF_D=$((SF_D + 1))
  [ "$SF_D" -le 40 ] || return 1
  case "$c" in
    '{')
      SF_I=$((SF_I + 1)); sf_ws
      if [ "${SF_S:SF_I:1}" = "}" ]; then SF_I=$((SF_I + 1)); SF_D=$((SF_D - 1)); return 0; fi
      while :; do
        sf_ws; [ "${SF_S:SF_I:1}" = '"' ] || return 1
        sf_string || return 1
        sf_ws; [ "${SF_S:SF_I:1}" = ":" ] || return 1
        SF_I=$((SF_I + 1)); sf_ws
        sf_value || return 1
        sf_ws
        case "${SF_S:SF_I:1}" in
          ",") SF_I=$((SF_I + 1)) ;;
          "}") SF_I=$((SF_I + 1)); break ;;
          *) return 1 ;;
        esac
      done
      ;;
    '[')
      SF_I=$((SF_I + 1)); sf_ws
      if [ "${SF_S:SF_I:1}" = "]" ]; then SF_I=$((SF_I + 1)); SF_D=$((SF_D - 1)); return 0; fi
      while :; do
        sf_ws
        sf_value || return 1
        sf_ws
        case "${SF_S:SF_I:1}" in
          ",") SF_I=$((SF_I + 1)) ;;
          "]") SF_I=$((SF_I + 1)); break ;;
          *) return 1 ;;
        esac
      done
      ;;
    '"') sf_string || return 1 ;;
    t) [ "${SF_S:SF_I:4}" = true ] || return 1; SF_I=$((SF_I + 4)) ;;
    f) [ "${SF_S:SF_I:5}" = false ] || return 1; SF_I=$((SF_I + 5)) ;;
    n) [ "${SF_S:SF_I:4}" = null ] || return 1; SF_I=$((SF_I + 4)) ;;
    - | [0-9])
      rest="${SF_S:SF_I:40}"
      [[ "$rest" =~ ^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)? ]] || return 1
      SF_I=$((SF_I + ${#BASH_REMATCH[0]}))
      ;;
    *) return 1 ;;
  esac
  SF_D=$((SF_D - 1))
  return 0
}

# Is the text in SF_S a JSON object and nothing else?
sf_json_object() {
  SF_I=0 SF_D=0
  sf_ws
  [ "${SF_S:SF_I:1}" = "{" ] || return 1
  sf_value || return 1
  sf_ws
  [ "$SF_I" -ge "${#SF_S}" ]
}

sf_check() { # path
  local p="$1" size
  SF_WHY=""
  if [ ! -e "$p" ]; then SF_WHY=missing; return 1; fi
  if [ ! -f "$p" ]; then SF_WHY=notfile; return 1; fi
  if [ ! -r "$p" ]; then SF_WHY=unreadable; return 1; fi
  if [ ! -s "$p" ]; then SF_WHY=empty; return 1; fi
  size="$(wc -c < "$p")"
  size="${size//[[:space:]]/}"
  if [ "${size:-0}" -gt "$SF_MAX_BYTES" ]; then SF_WHY=toobig; return 1; fi
  SF_S=""
  IFS= read -r -d '' SF_S < "$p" || true
  if ! sf_json_object; then SF_S=""; SF_WHY=notjson; return 1; fi
  SF_S=""
  return 0
}

# --- Where such a file usually is ----------------------------------------------------------------------------------------------------------

sf_candidates() {
  local d f lower dirs had_nullglob=0
  local -a dirlist=()
  SF_CAND=()
  if [ -n "${DELTACTL_SECRET_DIRS:-}" ] && [ "${DELTACTL_TEST_ISOLATED:-0}" = 1 ]; then dirs="$DELTACTL_SECRET_DIRS"
  elif [ -n "$SF_DIRS" ]; then dirs="$SF_DIRS"
  else dirs="${HOME:-}/Downloads:${HOME:-}/Descargas:${HOME:-}:${PWD:-}:${ROOT:-}"; fi
  IFS=':' read -ra dirlist <<< "$dirs"
  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  for d in "${dirlist[@]}"; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    for f in "$d"/*.json "$d"/*.JSON; do
      [ -f "$f" ] || continue
      lower="${f##*/}"; lower="${lower,,}"
      case "$lower" in
        *firebase* | *adminsdk* | *service*account* | *fcm* | *keeper*) ;;
        *) continue ;;
      esac
      # (the same file reached through two folders counts once)
      case " ${SF_CAND[*]} " in *" $f "*) continue ;; esac
      SF_CAND+=("$f")
      [ "${#SF_CAND[@]}" -lt 8 ] || break 2
    done
  done
  [ "$had_nullglob" -eq 1 ] || shopt -u nullglob
  return 0
}

# Copies a file to secrets/: mode 600 from the start (the umask is closed while it is written), so the content is never readable by others.
sf_install() { # src instance-dir name
  local src="$1" dir="$2" name="$3" old
  sf_valid_name "$name" || return 1
  [ -d "$dir/secrets" ] || return 1
  old="$(umask)"
  umask 077
  if ! cat -- "$src" > "$dir/secrets/$name"; then umask "$old"; return 1; fi
  umask "$old"
  chmod 600 "$dir/secrets/$name"
}

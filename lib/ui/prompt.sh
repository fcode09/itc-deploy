#!/usr/bin/env bash
# Confirmation prompts and the --yes option. Sourced by lib/bootstrap.sh.

# Asks for confirmation. ASSUME_YES=1 (the --yes option) skips it. Accepts y/Y/s/S in any language.
confirm() { # message
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  [ -t 0 ] || die "$(t err.confirm_needed)"
  local ans
  read -r -p "$(t prompt.confirm "$1")" ans
  [[ "$ans" =~ ^[sSyY]$ ]]
}

# Removes --yes from the arguments and sets ASSUME_YES. The result is in the ARGS array.
parse_yes() {
  ASSUME_YES=0
  ARGS=()
  local a
  for a in "$@"; do
    if [ "$a" = "--yes" ] || [ "$a" = "-y" ]; then ASSUME_YES=1; else ARGS+=("$a"); fi
  done
}

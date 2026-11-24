#!/usr/bin/env bash
# Renders the panel views at several sizes against the simulated server (tests/tools/sim_env.sh; never the real Docker) and saves
# every last frame as text, plain and with colours, so an interface change can be looked at and compared before/after.
# usage: tests/tools/panel_frames.sh <out-dir> [theme]     (colours: truecolor; needs no terminal)
set -u
OUT="${1:?usage: panel_frames.sh <out-dir> [theme]}"
THEME="${2:-matrix}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/tools/sim_env.sh
source "$HERE/sim_env.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
sim_build "$TMP/sim" 12
mkdir -p "$OUT"
cd "$SIM_REPO" || exit 1
export LANG=C.UTF-8
for size in 80x24 120x30 160x40; do
  cols="${size%x*}" rows="${size#*x}"
  for view in 1 2 3 4 5 6; do
    printf '%s\n' "$view" q > "$TMP/keys"
    for mode in plain color; do
      if [ "$mode" = plain ]; then c=(DELTACTL_COLOR=never); else c=(DELTACTL_COLOR=always COLORTERM=truecolor); fi
      env "${c[@]}" DELTACTL_THEME="$THEME" DELTACTL_TUI_KEYS="$TMP/keys" DELTACTL_UI=rich COLUMNS="$cols" DELTACTL_TUI_ROWS="$rows" \
        bash ./deltactl 2>&1 | awk '/^=== frame /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' > "$OUT/view$view-$size-$mode.txt"
    done
  done
done
echo "frames in $OUT"

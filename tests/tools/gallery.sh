#!/usr/bin/env bash
# The gallery of the UI kit: every scene of tests/tools/kit_scenes.sh in each theme (matrix cyber amber nord dracula mono) at 80, 120 and
# 160 columns, drawn with colours. It needs no Docker and no terminal.
#   tests/tools/gallery.sh <out-dir>            writes <theme>-<width>.ansi (look at it with `less -R`) and <theme>-<width>.html (a browser),
#                                               plus index.html, in <out-dir>
#   tests/tools/gallery.sh --show <theme> <w>   prints that page to the terminal
# Honours DELTACTL_GRAPH=blocks and the usual colour variables. Nothing is installed or started.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export ROOT LANG="${LANG:-C.UTF-8}"
[[ "$LANG" == *UTF-8* ]] || export LANG=C.UTF-8
page() { # theme width
  DELTACTL_UI=rich DELTACTL_COLOR=always COLORTERM=truecolor DELTACTL_CONFIG=/nonexistent XDG_CONFIG_HOME=/nonexistent bash -c '
    source "$ROOT/lib/bootstrap.sh"; source "$ROOT/lib/ui/tui.sh"; theme_apply "$1"
    source "$ROOT/tests/tools/kit_scenes.sh"
    for s in "${KIT_SCENES[@]}" "${KIT_SCENES_GRAPHS[@]}" "${KIT_SCENES_FORMS[@]}"; do
      printf "\n%s== %s (%s, %s columns) ==%s\n" "${TH[title]:-}" "$s" "$1" "$2" "$TH_RESET"
      kit_scene "$s" "$2"
    done' _ "$1" "$2"
}
if [ "${1:-}" = "--show" ]; then page "${2:-matrix}" "${3:-120}"; exit 0; fi
OUT="${1:?usage: gallery.sh <out-dir> | --show <theme> <width>}"
mkdir -p "$OUT"
files=()
for theme in matrix cyber amber nord dracula mono; do
  for w in 80 120 160; do
    page "$theme" "$w" > "$OUT/$theme-$w.ansi"
    files+=("$OUT/$theme-$w.ansi")
    if command -v python3 > /dev/null 2>&1; then python3 -I "$HERE/ansi2html.py" "$OUT/$theme-$w.ansi" "$OUT/$theme-$w.html" "$theme $w"; fi
  done
done
if command -v python3 > /dev/null 2>&1; then
  { echo '<!doctype html><meta charset=utf-8><title>deltactl UI kit</title><body style="background:#101412;color:#c8c8c8;font:16px sans-serif;margin:24px"><h2>deltactl UI kit gallery</h2><ul>'
    for f in "${files[@]}"; do b="$(basename "$f" .ansi)"; echo "<li><a style=\"color:#7fbf8f\" href=\"$b.html\">$b</a></li>"; done
    echo '</ul>'; } > "$OUT/index.html"
fi
echo "gallery in $OUT (${#files[@]} pages)"

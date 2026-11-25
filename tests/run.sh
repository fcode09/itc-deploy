#!/usr/bin/env bash
# Ejecuta las suites de tests/ sobre una COPIA AISLADA del repo (con instances/ vacío), nunca sobre el árbol
# real: así ningún test puede tocar instancias reales (por ejemplo instances/colorado).
#
# Uso: tests/run.sh [suite...]      sin argumentos corre todas (tests/test-*.sh)
#      tests/run.sh test-ui test-help
set -u
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DST="$(mktemp -d)"
trap 'rm -rf "$DST"' EXIT

mkdir -p "$DST/instances"
for p in deltactl lib services templates examples docs tests compose.yaml README.md; do
  [ -e "$SRC/$p" ] && cp -r "$SRC/$p" "$DST/"
done
: > "$DST/instances/.gitkeep"
# Golden snapshots live in the real tree: test-golden reads them from here, or writes them when recording.
export DELTACTL_GOLDEN_DIR="$SRC/tests/golden"
# The UI language comes from the environment, never from the developer's own config file.
export DELTACTL_LANG="${DELTACTL_LANG:-es}"
# The panel opens on the Servidor view; the suites that exercise the other views start them from the Instancias view, as they were written
# (tests/test-server.sh unsets this to check the real start).
export DELTACTL_TUI_START="${DELTACTL_TUI_START:-instances}"
export DELTACTL_CONFIG="$DST/.deltactl-config-absent"
export DELTACTL_TEST_ISOLATED=1
find "$DST" -name '*.sh' -o -name deltactl | xargs sed -i 's/\r$//' 2>/dev/null || true

if [ "$#" -gt 0 ]; then
  suites=("$@")
else
  suites=()
  for f in "$SRC"/tests/test-*.sh; do suites+=("$(basename "$f" .sh)"); done
fi

echo "copia aislada en $DST (instances/ vacío; la real tiene: $(ls "$SRC/instances" 2>/dev/null | tr '\n' ' '))"
rc=0
for s in "${suites[@]}"; do
  echo "##### $s"
  (cd "$DST" && bash "tests/$s.sh" 2>&1) || rc=1
done
echo "--- carpeta real sin cambios: $(ls "$SRC/instances" 2>/dev/null | tr '\n' ' ')"
exit "$rc"

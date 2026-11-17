#!/usr/bin/env bash
# Utilidades comunes de las suites de tests. Se carga con `source` desde cada tests/test-*.sh.
# Las suites se ejecutan SIEMPRE sobre una copia aislada del repo (ver tests/run.sh), con instances/ vacío:
# nunca tocan las instancias reales.

# Refuse to run outside tests/run.sh: it is the only thing that guarantees the isolated copy with an empty instances/.
if [ -z "${DELTACTL_TEST_ISOLATED:-}" ]; then
  echo "ERROR: run the suites through tests/run.sh (it uses an isolated copy and never touches real instances)" >&2
  exit 2
fi

pass=0
fail=0

# check "descripción" 'comando evaluado con eval'
# Se evalúa en un subshell: un `exit` dentro de la comprobación solo la hace fallar, no aborta la suite.
check() {
  if ( eval "$2" ); then
    echo "  PASS $1"
    pass=$((pass + 1))
  else
    echo "  FAIL $1"
    fail=$((fail + 1))
  fi
}

section() { echo "== $*"; }

# Quita los códigos de color ANSI de la entrada estándar.
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# ¿La entrada estándar contiene algún código de escape?
has_ansi() { grep -q $'\033'; }

# Rellena los valores obligatorios de una instancia para que pase las validaciones previas.
fill_instance() { # carpeta s0_tag s1_tag
  local dir="$1" f
  sed -i -e "s/^S0_TAG=.*/S0_TAG=$2/" -e "s/^S1_TAG=.*/S1_TAG=$3/" "$dir/.env.instance"
  for f in "$dir/.env.s0" "$dir/.env.s1"; do
    sed -i -e 's/^JWT_SECRET=.*/JWT_SECRET=x/' -e 's#CAMBIAR[A-Za-z_]*#ok#g' \
      -e 's/^IP_SERVER=.*/IP_SERVER=http:\/\/h/' "$f"
  done
  sed -i -e 's/^DELTA_UNIVERSITY_HANDOFF_SECRET=.*/DELTA_UNIVERSITY_HANDOFF_SECRET=x/' \
    -e 's/^FEDERATION_ENCRYPTION_KEY=.*/FEDERATION_ENCRYPTION_KEY=x/' \
    -e 's/^DEEPGRAM_API_KEY=.*/DEEPGRAM_API_KEY=x/' "$dir/.env.s1"
  : > "$dir/secrets/fcm.json"
  : > "$dir/secrets/keeper-fcm.json"
}

# Imprime el resultado final y sale con error si algo falló.
finish() {
  echo "RESULT: pass=$pass fail=$fail"
  [ "$fail" -eq 0 ]
}

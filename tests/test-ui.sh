#!/usr/bin/env bash
# Tests de la capa visual (lib/ui/ui.sh): modo plano, colores, banner, tablas alineadas y renderizado.
# Se ejecuta desde la raíz de la copia aislada (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS

section "1. sintaxis"
for f in deltactl lib/bootstrap.sh lib/ui/ui.sh lib/cmd/*.sh lib/screens/*.sh; do
  bash -n "$f" || { echo "  SYNTAX ERROR $f"; fail=$((fail + 1)); }
done
check "todos los scripts compilan" 'true'

section "2. modo plano: sin códigos de escape fuera de una terminal"
check "help (stdout redirigido) no lleva escapes" '! bash ./deltactl help | has_ansi'
check "list sin instancias no lleva escapes" '! bash ./deltactl list | has_ansi'
check "DELTACTL_COLOR=never anula incluso DELTACTL_UI=rich" '! DELTACTL_UI=rich DELTACTL_COLOR=never bash ./deltactl list | has_ansi'
check "NO_COLOR anula los colores en modo rico" '! NO_COLOR=1 DELTACTL_UI=rich bash ./deltactl list | has_ansi'
check "TERM=dumb anula los colores" '! TERM=dumb DELTACTL_UI=rich bash ./deltactl list | has_ansi'

section "3. colores cuando se piden"
mkdir -p instances/ui-test
check "DELTACTL_COLOR=always colorea la cabecera de list" 'DELTACTL_COLOR=always bash ./deltactl list | has_ansi'
check "ERROR va en rojo a stderr con DELTACTL_COLOR=always" 'DELTACTL_COLOR=always bash ./deltactl deploy zz-no 2>&1 | has_ansi'
check "ERROR en plano no lleva escapes" '! bash ./deltactl deploy zz-no 2>&1 | has_ansi'
check "el texto del error se conserva" 'bash ./deltactl deploy zz-no 2>&1 | grep -q "no existe"'
rmdir instances/ui-test

section "4. funciones de ui.sh (con ROOT de la copia)"
ROOT="$PWD"
export ROOT
unit() { # código a ejecutar tras cargar ui.sh (los demás argumentos llegan como $1, $2...)
  local code="$1"
  shift
  bash -c "source '$ROOT/lib/ui/ui.sh'; $code" _ "$@"
}
# Longitud máxima (en caracteres) de las líneas de la entrada estándar.
maxlen() { local l m=0; while IFS= read -r l; do [ "${#l}" -le "$m" ] || m=${#l}; done; echo "$m"; }
# Columna (en caracteres) donde empieza la última palabra de cada línea; una por línea.
lastcol() { local l last; while IFS= read -r l; do last="${l##* }"; echo "$((${#l} - ${#last}))"; done; }
jin='a"b\c'
jexp='a\"b\\c'
jnl=$'x\ny'
jnlexp='x\ny'
check "ui_json_escape escapa comillas y barras" '[ "$(unit "ui_json_escape \"\$1\"" "$jin")" = "$jexp" ]'
check "ui_json_escape convierte saltos de línea" '[ "$(unit "ui_json_escape \"\$1\"" "$jnl")" = "$jnlexp" ]'
check "ui_cell rellena al ancho pedido" \
  '[ "$(unit "ui_cell 8 \"\" abc | wc -c")" -eq 8 ]'
check "ui_cell trunca con elipsis" \
  '[ "$(unit "ui_cell 5 \"\" abcdefgh")" = "abcd…" ]'
check "ui_cell no cuenta los códigos de color en el ancho" \
  '[ "$(DELTACTL_COLOR=always DELTACTL_UI=rich unit "ui_cell 8 ok abc" | strip_ansi | wc -c)" -eq 8 ]'
check "celda de estado en modo rico lleva símbolo" \
  'DELTACTL_UI=rich unit "ui_cell 12 st-ok sano" | strip_ansi | grep -q "● sano"'
check "celda de estado en modo plano es solo el texto" \
  '[ "$(DELTACTL_UI=plain unit "ui_cell 6 st-ok sano" | tr -d " ")" = "sano" ]'
check "DELTACTL_ASCII=1 usa símbolos ASCII" \
  'DELTACTL_UI=rich DELTACTL_ASCII=1 unit "ui_cell 12 st-warn sano" | strip_ansi | grep -q "! sano"'

section "5. tablas: las columnas no se descuadran con colores, símbolos ni acentos"
rows="$(DELTACTL_UI=rich DELTACTL_COLOR=always unit '
  ui_table_cols 10 12 8
  ui_th NOMBRE ESTADO PUERTO
  ui_tr "bold:colorado" "st-ok:arriba" 4100
  ui_tr "ñandú" "st-err:caído" 4101
  ui_tr "warn:x" "st-dim:detenida" 4102' | strip_ansi)"
check "las 4 filas empiezan la última columna en la misma posición" \
  '[ "$(printf "%s\n" "$rows" | lastcol | sort -u | wc -l)" -eq 1 ]'

section "6. banner"
check "modo rico muestra el banner grande con la versión" \
  'DELTACTL_UI=rich COLUMNS=100 unit "ui_banner" | grep -q "██╗" && DELTACTL_UI=rich COLUMNS=100 unit "ui_banner" | grep -q "v[0-9]"'
check "modo plano no imprime banner" '[ -z "$(DELTACTL_UI=plain unit "ui_banner")" ]'
check "terminal estrecha usa banner compacto" \
  'DELTACTL_UI=rich COLUMNS=60 unit "ui_banner" | grep -q "DELTACTL" && ! DELTACTL_UI=rich COLUMNS=60 unit "ui_banner" | grep -q "██╗"'
check "DELTACTL_ASCII=1 usa banner compacto" \
  'DELTACTL_UI=rich DELTACTL_ASCII=1 COLUMNS=100 unit "ui_banner" | grep -q "DELTACTL"'
check "el banner grande cabe en 80 columnas" \
  '[ "$(DELTACTL_UI=rich COLUMNS=100 unit "ui_banner" | maxlen)" -le 80 ]'

section "7. renderizado de páginas de ayuda"
cat > "$PWD/sample.txt" <<'EOF'
# Título de prueba
Texto con `código` en línea.
## Sección
$ ./deltactl deploy colorado
! cuidado con esto
> una nota
- una viñeta
EOF
plain_out="$(DELTACTL_UI=plain unit "ui_render_file '$PWD/sample.txt'")"
color_out="$(DELTACTL_COLOR=always DELTACTL_UI=rich unit "ui_render_file '$PWD/sample.txt'")"
check "plano: comando con prefijo \$" 'echo "$plain_out" | grep -q "^  \$ ./deltactl deploy colorado"'
check "plano: conserva los backticks" 'echo "$plain_out" | grep -q "Texto con \`código\` en línea"'
check "plano: sin escapes" '! echo "$plain_out" | has_ansi'
check "color: resalta el código sin dejar backticks" \
  'echo "$color_out" | has_ansi && ! echo "$color_out" | strip_ansi | grep -q "\`"'
check "color: la advertencia y la nota se muestran" \
  'echo "$color_out" | strip_ansi | grep -q "cuidado con esto" && echo "$color_out" | strip_ansi | grep -q "una nota"'
rm -f "$PWD/sample.txt"

section "8. list sigue alineada y compatible"
bash ./deltactl new ui-test >/dev/null 2>&1
fill_instance instances/ui-test tag-a tag-b
check "list muestra la instancia y sus etiquetas (plano)" \
  'bash ./deltactl list | grep "ui-test" | grep -q "tag-a" && bash ./deltactl list | grep "ui-test" | grep -q "tag-b"'
check "list muestra una columna por servicio conocido" \
  'bash ./deltactl list | head -n1 | grep -q "S0 .*S1 .*S0_TAG .*S1_TAG"'
check "list marca la instancia como sin sembrar" 'bash ./deltactl list | grep "ui-test" | grep -q "sin sembrar"'
rm -rf instances/ui-test

finish

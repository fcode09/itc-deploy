#!/usr/bin/env bash
# Tests del sistema de ayuda (./deltactl help) y, sobre todo, de su COHERENCIA con el código:
#   - todo comando del despachador tiene su página, y toda página corresponde a un comando
#   - todo tema listado tiene su guía
#   - todas las variables de las plantillas .env.*.example están en el glosario, y viceversa
#   - las variables "obligatorias" del glosario son exactamente las que valida deploy.sh
#   - ninguna página recomienda un comando, un tema o una variable que no exista
# Un comando, tema o variable nuevo sin documentar hace fallar esta suite.
# Se ejecuta desde la raíz de la copia aislada (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS
H=lib/help

# Contenido de un array definido por los scripts (por ejemplo HELP_COMMANDS).
arr() { ROOT="$PWD" bash -c 'source lib/bootstrap.sh; source lib/cmd/help.sh; source lib/cmd/deploy.sh; n="$1[@]"; printf "%s\n" "${!n}"' _ "$1"; }
# Claves del glosario: archivo [tipo]
gl_keys() { grep -E '^@ ' "$H/variables.txt" | sed 's/^@ //' | awk -F ' [|] ' -v f="$1" -v t="${2:-}" '$2 == f && (t == "" || $3 == t) { print $1 }' | sort; }
# Claves de una plantilla, incluidas las opcionales comentadas (# CLAVE=)
tpl_keys() { grep -oE '^(# )?[A-Z][A-Z0-9_]*=' "$1" | sed -E 's/^# //; s/=$//' | sort -u; }

section "1. sintaxis y archivos"
for f in lib/cmd/help.sh; do bash -n "$f" || { echo "  SYNTAX ERROR $f"; fail=$((fail + 1)); }; done
check "existe la pantalla principal y el glosario" '[ -f $H/overview.txt ] && [ -f $H/variables.txt ]'
missing=""
for c in $(arr HELP_COMMANDS); do [ -f "$H/cmd-$c.txt" ] || missing+=" cmd-$c"; done
for t in $(arr HELP_TOPICS); do [ -f "$H/topic-$t.txt" ] || missing+=" topic-$t"; done
check "cada comando y tema listado tiene su página (faltan:${missing:- ninguna})" '[ -z "$missing" ]'
orphans=""
for f in $H/cmd-*.txt; do n="$(basename "$f" .txt)"; arr HELP_COMMANDS | grep -qx "${n#cmd-}" || orphans+=" $n"; done
for f in $H/topic-*.txt; do n="$(basename "$f" .txt)"; arr HELP_TOPICS | grep -qx "${n#topic-}" || orphans+=" $n"; done
check "no hay páginas huérfanas (sobran:${orphans:- ninguna})" '[ -z "$orphans" ]'
badtitle=""
for f in $H/cmd-*.txt $H/topic-*.txt $H/overview.txt; do head -n1 "$f" | grep -q '^# ' || badtitle+=" $f"; done
check "todas las páginas empiezan con un título '# '" '[ -z "$badtitle" ]'

section "2. todo comando del despachador está documentado"
dispatched="$(grep -E '^  [a-z][a-z |-]*\)$' deltactl | tr -d ')' | tr '|' '\n' | tr -d ' ' | grep -vE '^(-h|--help|)$' | sort -u)"
documented="$(arr HELP_COMMANDS | sort -u)"
check "los comandos de ./deltactl coinciden con HELP_COMMANDS" '[ "$dispatched" = "$documented" ]'
if [ "$dispatched" != "$documented" ]; then echo "    despachador: $(echo $dispatched)"; echo "    ayuda:       $(echo $documented)"; fi

section "3. las páginas se muestran"
rc=0
for c in $(arr HELP_COMMANDS); do
  bash ./deltactl help "$c" >/dev/null 2>&1 || { rc=1; echo "    falla: ./deltactl help $c"; }
  bash ./deltactl "$c" --help >/dev/null 2>&1 || { rc=1; echo "    falla: ./deltactl $c --help"; }
done
check "./deltactl help <comando> y ./deltactl <comando> --help funcionan para todos" '[ "$rc" -eq 0 ]'
rc=0
for t in $(arr HELP_TOPICS); do bash ./deltactl help "$t" >/dev/null 2>&1 || { rc=1; echo "    falla: ./deltactl help $t"; }; done
check "./deltactl help <tema> funciona para todos los temas" '[ "$rc" -eq 0 ]'
check "la ayuda en un pipe no lleva escapes" '! bash ./deltactl help deploy | has_ansi && ! bash ./deltactl help | has_ansi'
check "DELTACTL_COLOR=always colorea la ayuda" 'DELTACTL_COLOR=always bash ./deltactl help deploy | has_ansi'
check "--help en un comando no ejecuta el comando" '! bash ./deltactl deploy zz-no --help 2>&1 | grep -q "no existe"'
check "versions muestra la ayuda de images" '[ "$(bash ./deltactl help versions 2>&1)" = "$(bash ./deltactl help images 2>&1)" ]'

section "4. pantalla principal"
out="$(bash ./deltactl help 2>&1)"
check "lista todos los comandos con su sintaxis" \
  'echo "$out" | grep -q "load <archivo" && echo "$out" | grep -q "images \[servicio\]" && echo "$out" | grep -q "init <instancia>" && echo "$out" | grep -q "adopt <instancia>" && echo "$out" | grep -q -- "--existing"'
check "la fila de un comando lleva su descripción en la misma línea" 'echo "$out" | grep "deploy <instancia> \[servicio\]" | grep -q "Valida"'
check "lista todos los temas de ayuda" 'for t in $(arr HELP_TOPICS); do echo "$out" | grep -q "$t" || exit 1; done'
check "explica cómo ver variables y buscar" 'echo "$out" | grep -q "help variable" && echo "$out" | grep -q "help buscar"'
check "-h y --help muestran lo mismo que help" '[ "$(bash ./deltactl --help 2>&1)" = "$out" ] && [ "$(bash ./deltactl -h 2>&1)" = "$out" ]'
check "un comando desconocido falla y orienta" \
  '! bash ./deltactl nada >/dev/null 2>&1 && bash ./deltactl nada 2>&1 | grep -q "comando desconocido" && bash ./deltactl nada 2>&1 | grep -q "./deltactl help"'

section "5. páginas desconocidas, sugerencias y búsqueda"
check "una página inexistente falla" '! bash ./deltactl help zzzz >/dev/null 2>&1'
check "sugiere páginas parecidas" 'bash ./deltactl help depl 2>&1 | grep -q "./deltactl help deploy"'
check "buscar encuentra las páginas que mencionan el texto" 'bash ./deltactl help buscar rollback 2>&1 | grep -q "./deltactl help rollback"'
check "buscar sin coincidencias falla" '! bash ./deltactl help buscar zzzzqqqq >/dev/null 2>&1'
check "buscar sin texto falla con uso" 'bash ./deltactl help buscar 2>&1 | grep -q "uso:"'
check "help temas lista las guías" 'for t in $(arr HELP_TOPICS); do bash ./deltactl help temas | grep -q "$t" || exit 1; done'

section "6. glosario de variables"
check "una variable muestra archivo, tipo y descripción" \
  'o="$(bash ./deltactl help variable S0_TAG 2>&1)"; echo "$o" | grep -q ".env.instance" && echo "$o" | grep -q "obligatoria" && echo "$o" | grep -q "Etiqueta"'
check "acepta minúsculas" 'bash ./deltactl help variable s0_tag 2>&1 | grep -q "S0_TAG"'
check "una variable en varios archivos muestra todos los bloques" \
  '[ "$(bash ./deltactl help variable JWT_SECRET 2>&1 | grep -c "(\.env\.s")" -eq 2 ]'
check "una variable desconocida falla con sugerencias" \
  '! bash ./deltactl help variable JWT_SECRTE >/dev/null 2>&1; bash ./deltactl help variable JWT_SECRTE 2>&1 | grep -q "Parecidas"'
check "sin nombre lista todas, agrupadas por archivo" \
  'o="$(bash ./deltactl help variable 2>&1)"; echo "$o" | grep -q "S0_TAG" && echo "$o" | grep -q "FCM_CERT" && echo "$o" | grep -q "PROFILE_SYNC_CONCURRENCY"'
check "explica lo que no es obvio (SHIFT_UPDATE_BASELINE_SECRET vacía)" \
  'bash ./deltactl help variable SHIFT_UPDATE_BASELINE_SECRET 2>&1 | grep -q "vacía"'

section "7. coherencia: glosario vs plantillas"
pairs=(".env.instance:templates/.env.instance.example")
for svc in $(arr KNOWN_SERVICES); do pairs+=(".env.$svc:templates/.env.$svc.example"); done
for pair in "${pairs[@]}"; do
  file="${pair%%:*}"; tpl="${pair#*:}"
  only_tpl="$(comm -23 <(tpl_keys "$tpl") <(gl_keys "$file") | tr '\n' ' ')"
  only_gl="$(comm -13 <(tpl_keys "$tpl") <(gl_keys "$file") | tr '\n' ' ')"
  check "$file: toda variable de la plantilla está en el glosario (faltan: ${only_tpl:-ninguna})" '[ -z "$only_tpl" ]'
  # Las "fijas" no van en el .env: solo se documentan.
  only_gl_nofix=""
  for k in $only_gl; do gl_keys "$file" fija | grep -qx "$k" || only_gl_nofix+="$k "; done
  check "$file: el glosario no inventa variables que la plantilla no tiene (sobran: ${only_gl_nofix:-ninguna})" '[ -z "$only_gl_nofix" ]'
done
dups="$(grep -E '^@ ' $H/variables.txt | awk -F ' [|] ' '{ print $1 "|" $2 }' | sort | uniq -d | tr '\n' ' ')"
check "no hay variables duplicadas en el glosario (${dups:-ninguna})" '[ -z "$dups" ]'
badtype="$(grep -E '^@ ' $H/variables.txt | awk -F ' [|] ' '$3 != "obligatoria" && $3 != "opcional" && $3 != "fija" { print $1 }' | tr '\n' ' ')"
check "todos los tipos son obligatoria, opcional o fija (${badtype:-ok})" '[ -z "$badtype" ]'

section "8. coherencia: 'obligatoria' en el glosario == lo que valida deploy"
exp_inst="$( { arr REQUIRED_INSTANCE; for s in $(arr KNOWN_SERVICES); do echo "${s^^}_TAG"; echo "${s^^}_PORT"; done; } | sort)"
check "obligatorias de .env.instance" '[ "$(gl_keys .env.instance obligatoria)" = "$exp_inst" ]'
for svc in $(arr KNOWN_SERVICES); do
  U="${svc^^}"
  check "obligatorias de .env.$svc (REQUIRED_$U)" '[ "$(gl_keys .env.'"$svc"' obligatoria)" = "$(arr REQUIRED_'"$U"' | sort)" ]'
done

section "9. coherencia: las páginas solo recomiendan lo que existe"
cmds="$(arr HELP_COMMANDS)"
topics="$(arr HELP_TOPICS)"
bad_cmd=""; bad_topic=""; bad_var=""
while IFS= read -r ref; do
  first="$(echo "$ref" | awk '{ print $2 }')"
  second="$(echo "$ref" | awk '{ print $3 }')"
  echo "$cmds" | grep -qx "$first" || { bad_cmd+="[$ref] "; continue; }
  if [ "$first" = "help" ] && [ -n "$second" ]; then
    case "$second" in
      variable | variables | buscar | temas | topics) ;;
      *) { echo "$cmds"; echo "$topics"; } | grep -qx "$second" || bad_topic+="[$ref] " ;;
    esac
  fi
done < <(grep -ohE '\./deltactl [a-z]+( [a-z-]+)?' $H/cmd-*.txt $H/topic-*.txt $H/overview.txt | sort -u)
check "ningún comando ni tema recomendado es inexistente (${bad_cmd}${bad_topic:-ok})" '[ -z "$bad_cmd" ] && [ -z "$bad_topic" ]'
allvars="$(grep -E '^@ ' $H/variables.txt | awk -F ' [|] ' '{ sub(/^@ /, "", $1); print $1 }' | sort -u)"
for v in $(grep -ohE 'help variable [A-Z][A-Z0-9_]+' $H/*.txt | awk '{ print $3 }' | sort -u); do
  echo "$allvars" | grep -qx "$v" || bad_var+="$v "
done
check "todas las variables recomendadas existen en el glosario (${bad_var:-ok})" '[ -z "$bad_var" ]'
check "las líneas de las páginas caben en 130 columnas" '! awk "length(\$0) > 130 { exit 1 }" $H/cmd-*.txt $H/topic-*.txt'

section "10. los errores apuntan a la ayuda"
# Toda pista $(see X) del código debe señalar un tema o comando que exista.
bad_see=""
while IFS= read -r t; do
  case "$t" in "variable "*) continue ;; esac
  # The code uses English topic ids; the page files are still named after the Spanish ids.
  page="$(ROOT="$PWD" bash -c 'source lib/i18n/i18n.sh; topic_file_id "$1"' _ "$t")"
  { echo "$cmds"; echo "$topics"; } | grep -qx "$page" || bad_see+="$t "
done < <(grep -ohE '\$\(see [^)]*\)' lib/bootstrap.sh lib/cmd/*.sh | sed -E 's/^\$\(see "?//; s/"?\)$//' | sort -u)
check "cada pista \$(see ...) del código señala una página existente (${bad_see:-ok})" '[ -z "$bad_see" ]'

# docker mínimo para llegar a las validaciones sin Docker real
FIX="$(mktemp -d)"; mkdir -p "$FIX/bin"
trap 'rm -rf "$FIX" instances/hp-*' EXIT
printf '#!/usr/bin/env bash\ncase "$*" in "compose version --short") echo v2.30.0 ;; esac\nexit 0\n' > "$FIX/bin/docker"
chmod +x "$FIX/bin/docker"
export PATH="$FIX/bin:$PATH"

check "instancia inexistente apunta a la guía de instancia nueva" \
  'bash ./deltactl deploy zz-no 2>&1 | grep -q "(ayuda: ./deltactl help nueva-instancia)"'
check "nombre inválido apunta a la ayuda de new" \
  'bash ./deltactl new Mal_Nombre 2>&1 | grep -q "(ayuda: ./deltactl help new)"'
bash ./deltactl new hp-test >/dev/null 2>&1
out="$(bash ./deltactl deploy hp-test 2>&1)"
check "una variable vacía apunta a su entrada del glosario" 'echo "$out" | grep "JWT_SECRET está vacía" | grep -q "(ayuda: ./deltactl help variable JWT_SECRET)"'
check "un valor de ejemplo apunta a su entrada del glosario" 'echo "$out" | grep "valor de ejemplo" | grep -q "(ayuda: ./deltactl help variable "'
check "el resumen de errores apunta a la guía" 'echo "$out" | grep -q "corrígelos y reintenta (ayuda: ./deltactl help nueva-instancia)"'
check "servicio desconocido apunta a la guía de servicios" 'bash ./deltactl stop hp-test s9 2>&1 | grep -q "(ayuda: ./deltactl help servicios)"'
check "servicio inactivo apunta a la guía de servicios" \
  'sed -i "s/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=s0/" instances/hp-test/.env.instance; bash ./deltactl deploy hp-test s1 2>&1 | grep -q "(ayuda: ./deltactl help servicios)"'
check "el aviso de imagen faltante nombra la guía de imágenes" \
  'sed -i "s/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=s0,s1/" instances/hp-test/.env.instance; grep -q "see imagenes" lib/cmd/deploy.sh'
check "los mensajes siguen mostrando su texto original" 'echo "$out" | grep -q "está vacía" && echo "$out" | grep -q "problema(s) en la configuración"'
check "las pistas también salen sin color" '! echo "$out" | has_ansi'
rm -rf instances/hp-test

finish

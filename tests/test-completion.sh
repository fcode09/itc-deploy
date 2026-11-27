#!/usr/bin/env bash
# Tests de ./deltactl completion bash: se carga el script generado, se simula lo que bash hace al pulsar Tab
# (COMP_WORDS / COMP_CWORD) y se comprueban las sugerencias. También comprueba que las opciones del
# autocompletado coincidan con las que documentan las páginas de ayuda de cada comando.
# Se ejecuta desde la raíz de la copia aislada (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS
trap 'rm -rf instances/cp-*' EXIT
rm -rf instances/cp-*

# Pulsa Tab con las palabras dadas (la última es la que se está escribiendo; "" si está vacía).
comp() {
  bash -c 'source <(bash ./deltactl completion bash); COMP_WORDS=("$@"); COMP_CWORD=$(( $# - 1 )); _deltactl_complete; printf "%s\n" "${COMPREPLY[@]}"' _ "$@" | sort | tr '\n' ' '
}
has() { case " $1" in *" $2 "*) return 0 ;; esac; return 1; }

bash ./deltactl new cp-uno >/dev/null 2>&1
bash ./deltactl new cp-dos --services s1 >/dev/null 2>&1

section "1. el script generado"
script="$(bash ./deltactl completion bash 2>&1)"
check "es un script de bash válido" 'echo "$script" | bash -n'
check "registra la función para deltactl, ./deltactl y la ruta absoluta" \
  'echo "$script" | grep -q "complete -F _deltactl_complete deltactl ./deltactl \"$PWD/deltactl\""'
check "incluye los comandos, temas y servicios del propio código" \
  'echo "$script" | grep -q "deploy" && echo "$script" | grep -q "nueva-instancia" && echo "$script" | grep -q "cmds=\".*s0 s1 robin\"\\|services=\"s0 s1 robin\""'
check "no deja marcadores @...@ sin sustituir" '! echo "$script" | grep -q "@[A-Z]*@"'
check "sin shell indicado da el uso" 'bash ./deltactl completion 2>&1 | grep -q "uso: ./deltactl completion bash"'
check "solo admite bash" 'bash ./deltactl completion zsh 2>&1 | grep -q "solo hay autocompletado para bash"'
check "la ayuda de completion funciona" 'bash ./deltactl completion --help 2>&1 | grep -q "autocompletado con Tab"'

section "2. comandos"
r="$(comp deltactl "")"
check "sin escribir nada sugiere todos los comandos" \
  'for c in new init adopt deploy rollback stop down load images versions list status ps logs check doctor env service menu completion help; do has "$r" "$c" || exit 1; done'
check "un prefijo se completa" '[ "$(comp deltactl dep)" = "deploy " ]'
check "un prefijo ambiguo da todas las opciones" 'r="$(comp deltactl d)"; has "$r" deploy && has "$r" down && has "$r" doctor'
check "un prefijo inexistente no sugiere nada" '[ -z "$(comp deltactl zzz | tr -d " ")" ]'

section "3. instancias y servicios"
check "tras un comando de instancia sugiere las instancias existentes" 'r="$(comp deltactl deploy "")"; has "$r" cp-uno && has "$r" cp-dos'
check "filtra las instancias por prefijo" '[ "$(comp deltactl deploy cp-u)" = "cp-uno " ]'
check "tras la instancia sugiere los servicios" '[ "$(comp deltactl deploy cp-uno "")" = "robin s0 s1 " ]'
for c in rollback stop logs check status; do
  check "$c completa instancias" 'has "$(comp deltactl '"$c"' "")" cp-uno'
done
for c in init adopt down ps; do
  check "$c completa instancias y nada más después" 'has "$(comp deltactl '"$c"' "")" cp-dos && [ -z "$(comp deltactl '"$c"' cp-uno "" | tr -d " ")" ]'
done
check "images completa los servicios" '[ "$(comp deltactl images "")" = "robin s0 s1 " ]'
check "una instancia nueva aparece sin regenerar el script" \
  'bash ./deltactl new cp-tres >/dev/null 2>&1; has "$(comp deltactl deploy "")" cp-tres'

section "4. opciones"
check "new sugiere sus opciones" '[ "$(comp deltactl new --)" = "--domain --env-file --existing --generate-secrets --host --ip --proxy --robin-image --robin-tag --s0-image --s0-tag --s1-image --s1-tag --secret-file --services --tls --wizard --www " ]'
check "status sugiere sus opciones" '[ "$(comp deltactl status --)" = "--json --stats --strict --watch " ]'
check "una opción parcial se completa" '[ "$(comp deltactl status --j)" = "--json " ]'
check "check sugiere --mongo" '[ "$(comp deltactl check cp-uno --)" = "--mongo " ]'
check "logs sugiere -f" '[ "$(comp deltactl logs cp-uno -)" = "-f " ]'
check "images sugiere --json" '[ "$(comp deltactl images --)" = "--json " ]'
check "un comando sin opciones no sugiere nada con --" '[ -z "$(comp deltactl deploy cp-uno -- | tr -d " ")" ]'

section "5. ayuda"
check "help completa comandos y temas" 'r="$(comp deltactl help "")"; has "$r" deploy && has "$r" nueva-instancia && has "$r" variable && has "$r" buscar'
check "help completa un tema por prefijo" '[ "$(comp deltactl help nue)" = "nueva-instancia " ]'
check "help variable completa las variables del glosario" '[ "$(comp deltactl help variable S0_)" = "S0_CPUS S0_IMAGE S0_MEM_LIMIT S0_PORT S0_TAG " ]'
check "las variables salen sin duplicados" '[ "$(comp deltactl help variable JWT)" = "JWT_EXPIRES_IN JWT_SECRET " ]'
check "completion completa bash" '[ "$(comp deltactl completion "")" = "bash " ]'

section "6. coherencia con la ayuda: opciones del autocompletado == opciones documentadas"
# Opciones que aparecen en las líneas de uso ("$ ./deltactl <comando> ...") de cada página de ayuda.
doc_flags() { # comando
  grep -E "^\\\$ \./deltactl $1( |\$)" "lib/help/cmd-$1.txt" 2>/dev/null | grep -oE '(^| |\[)-{1,2}[a-z][a-z0-9-]*' | tr -d ' [' | grep -vxE -- '--help|-h' | sort -u | tr '\n' ' '
}
# Opciones definidas en el autocompletado para un comando.
comp_flags() { # comando
  ROOT="$PWD" bash -c 'source lib/bootstrap.sh; source lib/cmd/completion.sh; for e in "${COMPLETION_FLAGS[@]}"; do [ "${e%%:*}" = "$1" ] && echo "${e#*:}"; done' _ "$1" | tr ' ' '\n' | sort -u | tr '\n' ' '
}
bad=""
for c in new init adopt deploy rollback stop down load images list status ps logs check doctor env service menu completion help; do
  d="$(doc_flags "$c")"; k="$(comp_flags "$c")"
  [ "$d" = "$k" ] || bad+="$c (doc: ${d:-ninguna} | autocompletado: ${k:-ninguna}) "
done
check "las opciones de cada comando coinciden con su página de ayuda (${bad:-ok})" '[ -z "$bad" ]'
check "versions comparte las opciones de images" '[ "$(comp_flags versions)" = "$(comp_flags images)" ]'

finish

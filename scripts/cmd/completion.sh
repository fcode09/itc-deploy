#!/usr/bin/env bash
# ./itc completion bash: imprime el autocompletado de bash (Tab) para ./itc.
# Completa comandos, instancias, servicios, opciones, temas de ayuda y variables del glosario.
#
# Activarlo en la sesión actual:     source <(./itc completion bash)
# Dejarlo permanente (una vez):      ./itc completion bash > ~/.itc-completion.bash
#                                    echo 'source ~/.itc-completion.bash' >> ~/.bashrc
# Los nombres de comandos, temas, servicios y variables se toman del propio código en el momento de
# generarlo, así que no se desactualizan; las instancias se leen en cada Tab.

# help.sh aporta HELP_COMMANDS y HELP_TOPICS
source "$ROOT/scripts/cmd/help.sh"

# Opciones de cada comando (tests/test-completion.sh comprueba que figuren en su página de ayuda).
COMPLETION_FLAGS=(
  "new:--services --existing --wizard"
  "init:--yes"
  "rollback:--yes"
  "down:--yes"
  "status:--json --stats --strict --watch"
  "images:--json"
  "versions:--json"
  "check:--mongo"
  "logs:-f"
)

cmd_completion() {
  local shell="${1:-}" tmpl flags f vars
  [ -n "$shell" ] || die "uso: ./itc completion bash   (ver ./itc help completion)"
  [ "$shell" = "bash" ] || die "solo hay autocompletado para bash (recibido: '$shell')"

  flags=""
  for f in "${COMPLETION_FLAGS[@]}"; do flags+="    ${f%%:*}) flags=\"${f#*:}\" ;;"$'\n'; done
  vars="$(grep -E '^@ ' "$ROOT/scripts/help/variables.txt" | sed 's/^@ //; s/ .*//' | sort -u | tr '\n' ' ')"

  IFS= read -r -d '' tmpl <<'EOF' || true
# itc: autocompletado para bash (generado por ./itc completion bash)
_itc_complete() {
  local cur="${COMP_WORDS[COMP_CWORD]}" cmd="${COMP_WORDS[1]:-}" prev="${COMP_WORDS[COMP_CWORD-1]}"
  local cmds="@COMMANDS@" topics="@TOPICS@" services="@SERVICES@" vars="@VARS@"
  local insts="" f flags=""
  for f in "@ROOT@"/instances/*/.env.instance; do
    [ -f "$f" ] && insts+="$(basename "$(dirname "$f")") "
  done
  COMPREPLY=()

  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=($(compgen -W "$cmds menu completion" -- "$cur"))
    return 0
  fi

  case "$cmd" in
@FLAGS@  esac
  if [[ "$cur" == -* ]]; then
    COMPREPLY=($(compgen -W "$flags" -- "$cur"))
    return 0
  fi

  case "$cmd" in
    help)
      if [ "$prev" = "variable" ] || [ "$prev" = "variables" ]; then
        COMPREPLY=($(compgen -W "$vars" -- "$cur"))
      elif [ "$COMP_CWORD" -eq 2 ]; then
        COMPREPLY=($(compgen -W "$cmds $topics variable buscar temas" -- "$cur"))
      fi ;;
    deploy | rollback | stop | logs | check | status)
      if [ "$COMP_CWORD" -eq 2 ]; then COMPREPLY=($(compgen -W "$insts" -- "$cur"))
      elif [ "$COMP_CWORD" -eq 3 ]; then COMPREPLY=($(compgen -W "$services" -- "$cur")); fi ;;
    init | adopt | down | ps)
      [ "$COMP_CWORD" -eq 2 ] && COMPREPLY=($(compgen -W "$insts" -- "$cur")) ;;
    images | versions)
      [ "$COMP_CWORD" -eq 2 ] && COMPREPLY=($(compgen -W "$services" -- "$cur")) ;;
    load)
      COMPREPLY=($(compgen -f -- "$cur")) ;;
    completion)
      [ "$COMP_CWORD" -eq 2 ] && COMPREPLY=($(compgen -W "bash" -- "$cur")) ;;
  esac
  return 0
}
complete -F _itc_complete itc ./itc "@ROOT@/itc"
EOF
  tmpl="${tmpl//@COMMANDS@/${HELP_COMMANDS[*]}}"
  tmpl="${tmpl//@TOPICS@/${HELP_TOPICS[*]}}"
  tmpl="${tmpl//@SERVICES@/${KNOWN_SERVICES[*]}}"
  tmpl="${tmpl//@VARS@/$vars}"
  tmpl="${tmpl//@ROOT@/$ROOT}"
  tmpl="${tmpl//@FLAGS@/$flags}"
  printf '%s\n' "$tmpl"
}

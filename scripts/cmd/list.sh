#!/usr/bin/env bash
# ./itc list: instancias, puertos, etiquetas y estado.

cmd_list() {
  local found=0 f name state n
  printf '%-18s %-6s %-6s %-14s %-14s %s\n' INSTANCIA S0 S1 S0_TAG S1_TAG ESTADO
  for f in "$INSTANCES_DIR"/*/instance.env; do
    [ -f "$f" ] || continue
    found=1
    name="$(basename "$(dirname "$f")")"
    state="(docker no disponible)"
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      n="$(docker ps -q --filter "label=com.docker.compose.project=$name" | wc -l | tr -d ' ')"
      if [ "$n" -gt 0 ]; then state="arriba ($n contenedores)"; else state="detenida"; fi
    fi
    printf '%-18s %-6s %-6s %-14s %-14s %s\n' "$name" \
      "$(get_var "$f" S0_PORT)" "$(get_var "$f" S1_PORT)" \
      "$(get_var "$f" S0_TAG)" "$(get_var "$f" S1_TAG)" "$state"
  done
  if [ "$found" -eq 0 ]; then
    info "(no hay instancias; crea una con ./itc new <instancia>)"
  fi
}

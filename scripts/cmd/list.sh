#!/usr/bin/env bash
# ./itc list: instancias, servicios activos, puertos, etiquetas y estado.

cmd_list() {
  local found=0 f name state n
  printf '%-16s %-9s %-6s %-6s %-12s %-12s %s\n' INSTANCIA SERVICIOS S0 S1 S0_TAG S1_TAG ESTADO
  for f in "$INSTANCES_DIR"/*/instance.env; do
    [ -f "$f" ] || continue
    found=1
    name="$(basename "$(dirname "$f")")"
    state="(docker no disponible)"
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      n="$(docker ps -q --filter "label=com.docker.compose.project=$name" | wc -l | tr -d ' ')"
      if [ "$n" -gt 0 ]; then state="arriba ($n contenedores)"; else state="detenida"; fi
    fi
    printf '%-16s %-9s %-6s %-6s %-12s %-12s %s\n' "$name" \
      "$(get_var "$f" COMPOSE_PROFILES)" \
      "$(get_var "$f" S0_PORT)" "$(get_var "$f" S1_PORT)" \
      "$(get_var "$f" S0_TAG)" "$(get_var "$f" S1_TAG)" "$state"
  done
  if [ "$found" -eq 0 ]; then
    info "(no hay instancias; crea una con ./itc new <instancia>)"
  fi
}

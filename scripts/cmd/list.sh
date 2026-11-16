#!/usr/bin/env bash
# ./itc list: instancias, servicios activos, puertos, etiquetas y estado.
# Las columnas de puerto y etiqueta salen de KNOWN_SERVICES: un servicio nuevo aparece solo.

cmd_list() {
  local found=0 f name state n data svc st
  local -a widths=(16 9) head=(INSTANCIA SERVICIOS) row=()

  for svc in "${KNOWN_SERVICES[@]}"; do widths+=(6); head+=("${svc^^}"); done
  for svc in "${KNOWN_SERVICES[@]}"; do widths+=(12); head+=("${svc^^}_TAG"); done
  widths+=(12 20)
  head+=(DATOS ESTADO)

  ui_table_cols "${widths[@]}"
  ui_th "${head[@]}"
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    found=1
    name="$(basename "$(dirname "$f")")"
    state="(docker no disponible)"
    st="st-warn"
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      n="$(docker ps -q --filter "label=com.docker.compose.project=$name" | wc -l | tr -d ' ')"
      if [ "$n" -gt 0 ]; then
        state="arriba ($n contenedores)"
        st="st-ok"
      else
        state="detenida"
        st="st-dim"
      fi
    fi
    # DATOS: init = sembrada con ./itc init; existente = ya tenía datos; sin sembrar = falta ./itc init
    if [ -f "$(marker_file "$name")" ]; then
      data="$(get_var "$(marker_file "$name")" SOURCE)"
      [ "$data" != "existing" ] || data="existente"
    else
      data="sin sembrar"
    fi
    row=("bold:$name" "$(get_var "$f" COMPOSE_PROFILES)")
    for svc in "${KNOWN_SERVICES[@]}"; do row+=("$(get_var "$f" "${svc^^}_PORT")"); done
    for svc in "${KNOWN_SERVICES[@]}"; do row+=("$(get_var "$f" "$(tag_var "$svc")")"); done
    if [ "$data" = "sin sembrar" ]; then row+=("warn:$data"); else row+=("$data"); fi
    row+=("$st:$state")
    ui_tr "${row[@]}"
  done
  if [ "$found" -eq 0 ]; then
    info "(no hay instancias; crea una con ./itc new <instancia>)"
  fi
}

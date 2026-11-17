#!/usr/bin/env bash
# ./deltactl list: instances, active services, ports, tags and state.
# The port and tag columns come from KNOWN_SERVICES: a new service shows up by itself.

cmd_list() {
  local found=0 f name state n data label svc st
  local -a widths=(16 9) head=("$(t list.col.instance)" "$(t list.col.services)") row=()

  for svc in "${KNOWN_SERVICES[@]}"; do widths+=(6); head+=("${svc^^}"); done
  for svc in "${KNOWN_SERVICES[@]}"; do widths+=(12); head+=("${svc^^}_TAG"); done
  widths+=(12 20)
  head+=("$(t list.col.data)" "$(t list.col.state)")

  ui_table_cols "${widths[@]}"
  ui_th "${head[@]}"
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    found=1
    name="$(basename "$(dirname "$f")")"
    state="$(t list.docker_unavailable)"
    st="st-warn"
    if dk_ready; then
      n="$(dk_project_running_count "$name")"
      if [ "$n" -gt 0 ]; then
        state="$(t list.up "$n")"
        st="st-ok"
      else
        state="$(t list.stopped)"
        st="st-dim"
      fi
    fi
    # DATA: init = seeded with ./deltactl init; existing = already had data; unseeded = ./deltactl init missing
    data="$(data_state "$name")"
    label="$(data_label "$data")"
    row=("bold:$name" "$(get_var "$f" COMPOSE_PROFILES)")
    for svc in "${KNOWN_SERVICES[@]}"; do row+=("$(get_var "$f" "${svc^^}_PORT")"); done
    for svc in "${KNOWN_SERVICES[@]}"; do row+=("$(get_var "$f" "$(tag_var "$svc")")"); done
    if [ "$data" = "unseeded" ]; then row+=("warn:$label"); else row+=("$label"); fi
    row+=("$st:$state")
    ui_tr "${row[@]}"
  done
  if [ "$found" -eq 0 ]; then
    info "$(t list.none)"
  fi
}

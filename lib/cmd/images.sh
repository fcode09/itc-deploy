#!/usr/bin/env bash
# ./deltactl images [service] [--json]  (alias: ./deltactl versions)
# Image versions loaded in this Docker and which instances use them.
# If an instance uses a custom name (<SN>_IMAGE in .env.instance), it is listed too.
# It only lists: it never deletes images.
#
# Reads the catalog of lib/core/imagecat.sh: the versions come newest first (by creation date), the most recent one you may choose has a star,
# a tag that moves (latest, or not a version) has a warning mark, an image of another architecture is marked as an error.
#
# The "current" and "previous" markers of the used-by column are text in the UI language, both in the
# table and in the used_by field of --json.

cmd_images() {
  local only="" json=0 a svc repo found
  while [ "$#" -gt 0 ]; do
    a="$1"
    case "$a" in
      --json) json=1 ;;
      -*) die "$(t images.unknown_option "$a")" ;;
      *)
        [ -z "$only" ] || die "$(t images.extra_arg "$a")"
        only="$a"
        ;;
    esac
    shift
  done
  if [ -n "$only" ]; then
    valid_service "$only" || die "$(t err.service_unknown "$only" "${KNOWN_SERVICES[*]}")"
  fi
  check_docker

  # The catalog (lib/core/imagecat.sh): the versions of every image, newest first, with the star, the architecture check and who uses each.
  ic_load || die "$(t err.docker_daemon)"
  # The codes (current)/(previous) are language neutral: they go to --json as they are and are translated for the table.
  local use_current use_previous
  use_current="$(t images.use_current)"
  use_previous="$(t images.use_previous)"

  local g i total=0 unused=0 first_json=1 stars=0 mutable=0 foreign=0 label use kind mark archcell
  if [ "$json" -eq 1 ]; then
    printf '[\n'
  else
    ui_h1 "$(t images.title)"
    info "$(t images.server_arch "$IC_SERVER_ARCH")"
    ui_table_cols 18 13 8 14 9
  fi

  for g in "${IC_GROUPS[@]}"; do
    svc="${g%%|*}" repo="${g#*|}"
    if [ -n "$only" ] && [ "$svc" != "$only" ]; then continue; fi
    found=0
    if [ "$json" -eq 0 ]; then
      # Stable format: "<sN> = <repo>" on its own line, preceded by a blank line.
      printf '\n%s%s%s\n' "$C_BLD" "$svc = $repo" "$C_OFF"
    fi
    for i in ${IC_ORDER[$g]}; do
      use="${IC_USE[$i]% }"
      total=$((total + 1))
      if [ -z "$use" ]; then
        kind=dim
        unused=$((unused + 1))
      elif [[ "$use" == *"(current)"* ]]; then
        kind=ok
      else
        kind=warn
      fi
      if [ "$json" -eq 1 ]; then
        [ "$first_json" -eq 1 ] || printf ',\n'
        first_json=0
        ic_iso "${IC_EPOCH[$i]}" || IC_S=""
        printf '  {"service":"%s","repository":"%s","tag":"%s","id":"%s","architecture":"%s","created":"%s","created_at":"%s","size":"%s","used_by":"%s","in_use":%s,"latest":%s,"compatible":%s,"kind":"%s"}' \
          "$svc" "$(ui_json_escape "$repo")" "$(ui_json_escape "${IC_TAG[$i]}")" "$(short_id "${IC_ID[$i]}")" "$(ui_json_escape "${IC_ARCH[$i]}")" \
          "$(ui_json_escape "${IC_SINCE[$i]}")" "$IC_S" "$(ui_json_escape "${IC_SIZE[$i]}")" "$(ui_json_escape "$use")" \
          "$([ -n "$use" ] && echo true || echo false)" "$([ "${IC_STAR[$i]}" -eq 1 ] && echo true || echo false)" \
          "$([ "${IC_OK[$i]}" -eq 1 ] && echo true || echo false)" \
          "$(case "${IC_KIND[$i]}" in ver) echo version ;; *) echo "${IC_KIND[$i]}" ;; esac)"
      else
        if [ "$found" -eq 0 ]; then
          ui_th "$(t images.col.tag)" "$(t images.col.id)" "$(t images.col.arch)" "$(t images.col.created)" \
            "$(t images.col.size)" "$(t images.col.used_by)"
        fi
        label="$use"
        label="${label//(current)/($use_current)}"
        label="${label//(previous)/($use_previous)}"
        # The tag carries its mark: the star is the most recent you may choose, ▲ a tag that moves (latest, or not a version).
        mark=""
        if [ "${IC_STAR[$i]}" -eq 1 ]; then mark=" $UI_S_STAR" stars=$((stars + 1))
        elif [ "${IC_KIND[$i]}" != ver ]; then mark=" $UI_S_WARN" mutable=$((mutable + 1)); fi
        archcell="${IC_ARCH[$i]}"
        if [ "${IC_OK[$i]}" -eq 0 ]; then archcell="err:$archcell $UI_S_ERR" foreign=$((foreign + 1)); fi
        ui_tr "bold:${IC_TAG[$i]}$mark" "$(short_id "${IC_ID[$i]}")" "$archcell" "${IC_SINCE[$i]}" "${IC_SIZE[$i]}" "$kind:${label:-$(t images.unused)}"
      fi
      found=1
    done
    if [ "$json" -eq 0 ] && [ "$found" -eq 0 ]; then
      info "$(t images.none_loaded)"
    fi
    if [ "$json" -eq 0 ] && [ -n "${IC_DISC[$g]:-}" ]; then
      warn "$(t images.disc "${IC_DISC[$g]%%|*}" "${IC_DISC[$g]#*|}")"
    fi
  done

  if [ "$json" -eq 1 ]; then
    printf '\n]\n'
    return 0
  fi
  printf '\n'
  info "$(t images.note_unused)"
  info "$(t images.note_listing)"
  if [ "$stars" -gt 0 ]; then info "$(t images.note_star "$UI_S_STAR")"; fi
  if [ "$mutable" -gt 0 ]; then info "$(t images.note_mutable "$UI_S_WARN")"; fi
  if [ "$foreign" -gt 0 ]; then info "$(t images.note_foreign "$UI_S_ERR" "$IC_SERVER_ARCH")"; fi
  if [ "$unused" -gt 0 ]; then
    ui_hint "$(t images.hint_delete "$unused" "$total")"
  fi
}

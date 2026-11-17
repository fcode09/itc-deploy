#!/usr/bin/env bash
# ./deltactl images [service] [--json]  (alias: ./deltactl versions)
# Image versions loaded in this Docker and which instances use them.
# If an instance uses a custom name (<SN>_IMAGE in .env.instance), it is listed too.
# It only lists: it never deletes images.
#
# The "current" and "previous" markers of the used-by column are text in the UI language, both in the
# table and in the used_by field of --json.

cmd_images() {
  local only="" json=0 a svc repo f name cur prev found r
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

  # Usage per image and tag: "<name>:<tag>" -> instances that have it as current or as previous (rollback).
  # Names in use per service: the default one plus each instance's own.
  # The codes (current)/(previous) are language neutral: they go to --json as they are and are translated for the table.
  local use_current use_previous
  use_current="$(t images.use_current)"
  use_previous="$(t images.use_previous)"
  local -A used=() repos=()
  for svc in "${KNOWN_SERVICES[@]}"; do repos[$svc]="$(service_repo "$svc")"; done
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    name="$(basename "$(dirname "$f")")"
    for svc in "${KNOWN_SERVICES[@]}"; do
      r="$(service_repo "$svc" "$name")"
      case " ${repos[$svc]} " in *" $r "*) ;; *) repos[$svc]+=" $r" ;; esac
      cur="$(get_var "$f" "$(tag_var "$svc")")"
      prev="$(get_var "$(dirname "$f")/.previous" "$(tag_var "$svc")")"
      [ -z "$cur" ] || used["$r:$cur"]+="$name(current) "
      if [ -n "$prev" ] && [ "$prev" != "$cur" ]; then used["$r:$prev"]+="$name(previous) "; fi
    done
  done

  local full tag id created size arch use kind total=0 unused=0 first_json=1
  if [ "$json" -eq 1 ]; then
    printf '[\n'
  else
    ui_h1 "$(t images.title)"
    info "$(t images.server_arch "$(server_arch)")"
    ui_table_cols 18 13 8 14 9
  fi

  for svc in "${KNOWN_SERVICES[@]}"; do
    if [ -n "$only" ] && [ "$svc" != "$only" ]; then continue; fi
    for repo in ${repos[$svc]}; do
      found=0
      if [ "$json" -eq 0 ]; then
        # Stable format: "<sN> = <repo>" on its own line, preceded by a blank line.
        printf '\n%s%s%s\n' "$C_BLD" "$svc = $repo" "$C_OFF"
      fi
      while IFS='|' read -r full tag id created size; do
        [ -n "$tag" ] && [ "$tag" != "<none>" ] || continue
        arch="$(dk_image_arch "$full:$tag")"
        [ -n "$arch" ] || arch='?'
        use="${used["$repo:$tag"]:-}"
        use="${use% }"
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
          printf '  {"service":"%s","repository":"%s","tag":"%s","id":"%s","architecture":"%s","created":"%s","size":"%s","used_by":"%s","in_use":%s}' \
            "$svc" "$(ui_json_escape "$repo")" "$(ui_json_escape "$tag")" "$(short_id "$id")" "$(ui_json_escape "$arch")" \
            "$(ui_json_escape "$created")" "$(ui_json_escape "$size")" "$(ui_json_escape "$use")" \
            "$([ -n "$use" ] && echo true || echo false)"
        else
          if [ "$found" -eq 0 ]; then
            ui_th "$(t images.col.tag)" "$(t images.col.id)" "$(t images.col.arch)" "$(t images.col.created)" \
              "$(t images.col.size)" "$(t images.col.used_by)"
          fi
          local label="$use"
          label="${label//(current)/($use_current)}"
          label="${label//(previous)/($use_previous)}"
          ui_tr "bold:$tag" "$(short_id "$id")" "$arch" "$created" "$size" "$kind:${label:-$(t images.unused)}"
        fi
        found=1
      done < <(dk_images_detail \
        | awk -F'|' -v r="$repo" '$1 == r || (length($1) > length(r) && substr($1, length($1) - length(r)) == "/" r)')
      if [ "$json" -eq 0 ] && [ "$found" -eq 0 ]; then
        info "$(t images.none_loaded)"
      fi
    done
  done

  if [ "$json" -eq 1 ]; then
    printf '\n]\n'
    return 0
  fi
  printf '\n'
  info "$(t images.note_unused)"
  info "$(t images.note_listing)"
  if [ "$unused" -gt 0 ]; then
    ui_hint "$(t images.hint_delete "$unused" "$total")"
  fi
}

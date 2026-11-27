#!/usr/bin/env bash
# ./deltactl images [service] [--json]  (alias: ./deltactl versions)
# Image versions loaded in this Docker and which instances use them.
# If an instance uses a custom name (<SN>_IMAGE in .env.instance), it is listed too.
# It lists; `images rm` and `images prune` remove the versions nobody uses (see below).
#
# Reads the catalog of lib/core/imagecat.sh: the versions come newest first (by creation date), the most recent one you may choose has a star,
# a tag that moves (latest, or not a version) has a warning mark, an image of another architecture is marked as an error.
#
# The "current" and "previous" markers of the used-by column are text in the UI language, both in the
# table and in the used_by field of --json.

# ---------- rm / prune ----------
# Removing versions that nobody uses. Both ask first (--yes skips it), and `prune --dry-run` only says what it would do. The rules of what can go are in
# lib/core/imagecat.sh (ic_removable): never the version an instance runs, the one kept for its rollback, or one a container uses; Docker is asked
# without force, so its own refusal is the last safety net.

# Shows what is going to be removed and, unless it is a dry run, asks and removes it. $1 = 1 for a dry run; then the indexes.
images_remove_flow() { # dry i...
  local dry="$1" i n ok_n=0 fail_n=0 note ref
  shift
  n="$#"
  info "$(t images.rm.title "$n")"
  for i in "$@"; do
    note=""
    ic_removable "$i"
    [ "$IC_RM_SHARED" -eq 0 ] || note="  $(t images.rm.shared)"
    [ "${IC_STAR[$i]}" -ne 1 ] || note+="  $(t images.rm.newest "${IC_SVC[$i]}")"
    info "  $(printf '%-8s' "${IC_SVC[$i]}") $(printf '%-14s' "${IC_TAG[$i]}") $(printf '%8s' "${IC_SIZE[$i]}")$note"
  done
  ic_frees_bytes "$@"
  ic_fmt_bytes "$IC_FREES"
  info "$(t images.rm.total "$IC_BYTES_H")"
  if [ "$dry" -eq 1 ]; then
    info ""
    info "$(t images.rm.dry_hint)"
    return 0
  fi
  confirm "$(t images.rm.confirm "$n" "$IC_BYTES_H")" || die "$(t err.cancelled)"
  for i in "$@"; do
    ref="${IC_FULL[$i]}:${IC_TAG[$i]}"
    if dk_image_rm "$ref"; then
      ok "$(t images.rm.done_one "$ref")"
      ok_n=$((ok_n + 1))
    else
      warn "$(t images.rm.failed "$ref" "$(printf '%s' "$DK_RM_ERR" | head -n1)")"
      fail_n=$((fail_n + 1))
    fi
  done
  info ""
  info "$(t images.rm.summary "$ok_n" "$fail_n" "$IC_BYTES_H")"
  [ "$fail_n" -eq 0 ] || return 1
}

images_prepare() {
  check_docker
  ic_load || die "$(t err.docker_daemon)"
  ic_containers_load
}

images_rm() { # <service>:<version>... [--yes]
  local a t svc tag i found refused=0 g
  local -a want=() sel=()
  parse_yes "$@"
  set -- ${ARGS[@]+"${ARGS[@]}"}
  for a in "$@"; do
    case "$a" in
      -*) die "$(t images.unknown_option "$a")" ;;
      *:*) want+=("$a") ;;
      *) die "$(t images.rm.bad_target "$a")" ;;
    esac
  done
  [ "${#want[@]}" -gt 0 ] || die "$(t images.rm.usage)"
  for t in "${want[@]}"; do
    svc="${t%%:*}" tag="${t#*:}"
    valid_service "$svc" || die "$(t err.service_unknown "$svc" "${KNOWN_SERVICES[*]}")"
    [ -n "$tag" ] || die "$(t images.rm.bad_target "$t")"
  done
  images_prepare
  for t in "${want[@]}"; do
    svc="${t%%:*}" tag="${t#*:}"
    found=0
    for g in "${IC_GROUPS[@]}"; do
      [ "${g%%|*}" = "$svc" ] || continue
      for i in ${IC_ORDER[$g]}; do
        [ "${IC_TAG[$i]}" = "$tag" ] || continue
        found=1
        ic_removable "$i"
        if [ "$IC_RM_WHY" = ok ]; then sel+=("$i")
        else warn "$(ic_why_text "$i")"; refused=$((refused + 1)); fi
      done
    done
    [ "$found" -eq 1 ] || die "$(t images.rm.notfound "$svc" "$tag")"
  done
  if [ "${#sel[@]}" -eq 0 ]; then die "$(t images.rm.nothing)"; fi
  images_remove_flow 0 "${sel[@]}"
}

images_prune() { # [service] [--keep N] [--dry-run] [--yes]
  local a only="" keep=0 dry=0
  parse_yes "$@"
  set -- ${ARGS[@]+"${ARGS[@]}"}
  while [ "$#" -gt 0 ]; do
    a="$1"
    shift
    case "$a" in
      --dry-run) dry=1 ;;
      --keep)
        [ "$#" -gt 0 ] || die "$(t images.opt_value "$a")"
        keep="$1"
        shift
        [[ "$keep" =~ ^[0-9]+$ ]] || die "$(t images.prune.keep_bad "$keep")"
        ;;
      -*) die "$(t images.unknown_option "$a")" ;;
      *)
        [ -z "$only" ] || die "$(t images.extra_arg "$a")"
        only="$a"
        ;;
    esac
  done
  if [ -n "$only" ]; then valid_service "$only" || die "$(t err.service_unknown "$only" "${KNOWN_SERVICES[*]}")"; fi
  images_prepare
  ic_prune_plan "$only" "$keep"
  if [ "${#IC_PLAN[@]}" -eq 0 ]; then info "$(t images.rm.none)"; return 0; fi
  images_remove_flow "$dry" "${IC_PLAN[@]}"
}

cmd_images() {
  case "${1:-}" in
    rm) shift; images_rm "$@"; return $? ;;
    prune) shift; images_prune "$@"; return $? ;;
  esac
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

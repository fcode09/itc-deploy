#!/usr/bin/env bash
# ./deltactl rollback <instance> [service] [--yes]: goes back to the tags of the previous deploy.
# Without a service, it reverts every active one whose previous tag differs from the current one.
# With local images, the previous image must still be loaded in this Docker.

# deploy_up comes from deploy.sh
source "$ROOT/lib/cmd/deploy.sh"

cmd_rollback() {
  parse_yes "$@"
  local name="${ARGS[0]:-}" only="${ARGS[1]:-}"
  require_instance "$name"
  select_services "$name" "$only"

  local dir svc tag_name cur prev prev_id ref_prev missing=0
  local -a roll=()
  local -A prevs=() deployed=() deployed_ids=()
  dir="$(instance_dir "$name")"

  check_docker

  info "$(t rollback.instance "$name")"
  for svc in "${SELECTED[@]}"; do
    tag_name="$(tag_var "$svc")"
    cur="$(get_var "$dir/.env.instance" "$tag_name")"
    prev="$(get_var "$dir/.previous" "$tag_name")"
    if [ -z "$prev" ] || [ "$prev" = "$cur" ]; then
      [ -z "$only" ] || die "$(t rollback.no_prev_tag "$svc" "$name")$(see update)"
      continue
    fi

    # With local images there is nowhere to pull it from: it must still be loaded, with the same ID.
    if uses_local_images "$name"; then
      ref_prev="$(service_repo "$svc" "$name"):$prev"
      if ! dk_image_exists "$ref_prev"; then
        warn "$(t rollback.prev_missing "$ref_prev" "$svc")"
        missing=$((missing + 1))
        continue
      fi
      prev_id="$(get_var "$dir/.previous" "${svc^^}_IMAGE_ID")"
      if [ -n "$prev_id" ] && [ "$(dk_image_id "$ref_prev")" != "$prev_id" ]; then
        warn "$(t rollback.prev_changed "$svc" "$prev" "$(short_id "$(dk_image_id "$ref_prev")")" "$(short_id "$prev_id")")"
      fi
    fi

    roll+=("$svc")
    prevs[$svc]="$prev"
    deployed[$svc]="$(get_var "$dir/.deployed" "$tag_name")"
    deployed_ids[$svc]="$(get_var "$dir/.deployed" "${svc^^}_IMAGE_ID")"
    info "  $svc: $cur -> $prev"
  done

  [ "$missing" -eq 0 ] || die "$(t rollback.missing_images)$(see update)"
  [ "${#roll[@]}" -gt 0 ] || die "$(t rollback.nothing "$name")"

  confirm "$(t rollback.confirm)" || die "$(t err.cancelled)"

  for svc in "${roll[@]}"; do
    set_var "$dir/.env.instance" "$(tag_var "$svc")" "${prevs[$svc]}"
  done

  deploy_up 1 "$name" "${roll[@]}" || die "$(t rollback.not_healthy "$name")"

  # What was deployed becomes "previous", so a second rollback restores it.
  for svc in "${roll[@]}"; do
    if [ -n "${deployed[$svc]}" ]; then
      set_var "$dir/.previous" "$(tag_var "$svc")" "${deployed[$svc]}"
      set_var "$dir/.previous" "${svc^^}_IMAGE_ID" "${deployed_ids[$svc]}"
    fi
  done
  ok "$(t rollback.done "$name" "${roll[*]}")"
}

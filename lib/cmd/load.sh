#!/usr/bin/env bash
# ./deltactl load <file.tar|file.tar.gz>: loads images into this server's Docker.
# A shortcut for `docker load`; the file is only used to load and can be deleted afterwards.

cmd_load() {
  local file="${1:-}" out ref
  [ -n "$file" ] || die "$(t load.usage)"
  [ -f "$file" ] || die "$(t load.no_file "$file")"
  check_docker

  info "$(t load.loading "$file")"
  # `docker load` reads tar; .gz files are decompressed on the fly.
  out="$(dk_load "$file")" || { printf '%s\n' "$out" >&2; die "$(t load.failed "$file")"; }

  local -a loaded=()
  while IFS= read -r ref; do
    [ -z "$ref" ] || loaded+=("$ref")
  done < <(printf '%s\n' "$out" | sed -n 's/^Loaded image: //p')
  [ "${#loaded[@]}" -gt 0 ] || die "$(t load.no_images)$(see local-images)"

  info "$(t load.loaded_title)"
  for ref in "${loaded[@]}"; do
    info "  $ref"
    warn_arch_mismatch "$ref"
  done
  ok "$(t load.done "${#loaded[@]}")"
}

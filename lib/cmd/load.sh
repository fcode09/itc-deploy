#!/usr/bin/env bash
# ./deltactl load <archivo.tar|archivo.tar.gz>: carga imágenes en el Docker de este servidor.
# Es un atajo de `docker load`; el archivo solo se usa para cargar y luego se puede borrar.

cmd_load() {
  local file="${1:-}" out ref
  [ -n "$file" ] || die "uso: ./deltactl load <archivo.tar|archivo.tar.gz>"
  [ -f "$file" ] || die "no existe el archivo: $file"
  check_docker

  info "Cargando $file ..."
  # `docker load` lee tar; los .gz se descomprimen al vuelo.
  out="$(dk_load "$file")" || { printf '%s\n' "$out" >&2; die "no se pudo cargar $file"; }

  local -a loaded=()
  while IFS= read -r ref; do
    [ -z "$ref" ] || loaded+=("$ref")
  done < <(printf '%s\n' "$out" | sed -n 's/^Loaded image: //p')
  [ "${#loaded[@]}" -gt 0 ] || die "el archivo no contiene imágenes con nombre (¿es un archivo de docker save?)$(see imagenes)"

  info "Imágenes cargadas:"
  for ref in "${loaded[@]}"; do
    info "  $ref"
    warn_arch_mismatch "$ref"
  done
  ok "${#loaded[@]} imagen(es) disponibles. Usa estas etiquetas en S0_TAG / S1_TAG y revisa con ./deltactl images"
}

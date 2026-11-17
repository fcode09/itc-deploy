#!/usr/bin/env bash
# State adapter: everything the tool keeps on disk for an instance (instances/<name>/).
#   .env.instance, .env.<sN>   configuration (never executed, only read)
#   .deployed, .previous       tags and image ids of the last deploys
#   .initialized               marker of "initial data seeded"
# Sourced by lib/bootstrap.sh; requires INSTANCES_DIR (lib/core/config.sh).

instance_dir() { printf '%s/%s' "$INSTANCES_DIR" "$1"; }

# Reads the value of a key from a .env file without executing it (tolerates CRLF).
get_var() { # file key
  local line
  line="$(grep -E "^$2=" "$1" 2>/dev/null | tail -n1 || true)"
  line="${line#*=}"
  printf '%s' "${line%$'\r'}"
}

# Replaces (or appends) KEY=value in a .env file.
set_var() { # file key value
  local file="$1" key="$2" val="$3" tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$val" 'BEGIN { FS = OFS = "=" }
    $1 == k { print k "=" v; found = 1; next }
    { print }
    END { if (!found) print k "=" v }' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# Marker of "initial data already seeded, or instance with existing data". While it exists,
# `./deltactl init` refuses to run: the seeds delete data (collection drops).
marker_file() { printf '%s/.initialized' "$(instance_dir "$1")"; }

write_marker() { # instance source(init|existing)
  local dir f
  dir="$(instance_dir "$1")"
  f="$(marker_file "$1")"
  {
    printf 'SOURCE=%s\n' "$2"
    printf 'INITIALIZED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'S0_TAG=%s\n' "$(get_var "$dir/.env.instance" S0_TAG)"
    printf 'S1_TAG=%s\n' "$(get_var "$dir/.env.instance" S1_TAG)"
  } > "$f"
  chmod 600 "$f"
}

# Does the instance use images already loaded in this Docker? (empty REGISTRY in .env.instance)
uses_local_images() { # instance
  [ -z "$(get_var "$(instance_dir "$1")/.env.instance" REGISTRY)" ]
}

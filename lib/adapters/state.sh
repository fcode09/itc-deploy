#!/usr/bin/env bash
# State adapter: everything the tool keeps on disk for an instance (instances/<name>/).
#   .env.instance, .env.<sN>   configuration (never executed, only read)
#   .deployed, .previous       tags and image ids of the last deploys
#   .initialized               marker of "initial data seeded"
# Sourced by lib/bootstrap.sh; requires INSTANCES_DIR (lib/core/config.sh).

instance_dir() { printf '%s/%s' "$INSTANCES_DIR" "$1"; }

# Reads the value of a key from a .env file without executing it (tolerates CRLF; the last line of the key wins).
# get_var_r leaves it in GV without starting any process: the state refresh reads hundreds of values, and every `$(...)` is a
# fork of the whole program. A missing or unreadable file gives an empty value.
GV=""
get_var_r() { # file key
  local line
  GV=""
  [ -f "$1" ] && [ -r "$1" ] || return 0
  # (a file removed between the test and the read gives an empty value, never an error under errexit)
  { while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" == "$2="* ]] && GV="${line#*=}"
  done < "$1"; } 2> /dev/null || true
  GV="${GV%$'\r'}"
}
get_var() { # file key
  get_var_r "$1" "$2"
  printf '%s' "$GV"
}

# Replaces (or appends) KEY=value in a .env file.
set_var() { # file key value
  local file="$1" key="$2" val="$3" tmp src="$1"
  # The new content is built in a temporary file next to the target and swapped in with a rename: the old file is never
  # truncated, so a failure while building it (full disk, awk error) leaves the previous content intact.
  tmp="$(mktemp "$file.XXXXXX")" || return 1
  [ -f "$file" ] || src=/dev/null
  if ! awk -v k="$key" -v v="$val" 'BEGIN { FS = OFS = "=" }
    $1 == k { print k "=" v; found = 1; next }
    { print }
    END { if (!found) print k "=" v }' "$src" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if [ -f "$file" ]; then
    chmod --reference="$file" "$tmp" 2>/dev/null || true
  else
    chmod "$(printf '%o' $((0666 & ~$(umask))))" "$tmp" 2>/dev/null || true   # a new file gets the usual umask mode
  fi
  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# Marker of "initial data already seeded, or instance with existing data". While it exists,
# `./deltactl init` refuses to run: the seeds delete data (collection drops).
marker_file() { printf '%s/.initialized' "$(instance_dir "$1")"; }

write_marker() { # instance source(init|existing|init-incomplete)
  local dir f tmp
  dir="$(instance_dir "$1")"
  f="$(marker_file "$1")"
  # Written aside and renamed: the marker is the protection against repeating the seeds, so it must never be half-written.
  tmp="$(mktemp "$f.XXXXXX")" || return 1
  {
    printf 'SOURCE=%s\n' "$2"
    printf 'INITIALIZED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'S0_TAG=%s\n' "$(get_var "$dir/.env.instance" S0_TAG)"
    printf 'S1_TAG=%s\n' "$(get_var "$dir/.env.instance" S1_TAG)"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp"
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# Does the instance use images already loaded in this Docker? (empty REGISTRY in .env.instance)
uses_local_images() { # instance
  get_var_r "$INSTANCES_DIR/$1/.env.instance" REGISTRY
  [ -z "$GV" ]
}

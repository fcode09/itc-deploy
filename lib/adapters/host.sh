#!/usr/bin/env bash
# Host adapter: what the tool asks the operating system of the server (listening ports, file owners and
# modes, free disk). Commands call these functions instead of running ss/stat/df themselves.
# Sourced by lib/bootstrap.sh.

host_has() { command -v "$1" >/dev/null 2>&1; } # program

# Is something listening on TCP port $1 on this server? False when `ss` is not available.
host_port_in_use() { # port
  host_has ss && ss -ltn 2>/dev/null | grep -qE "[:.]$1[[:space:]]"
}

# Numeric owner of a file or directory; $2 is returned when it cannot be read.
host_owner_uid() { # path default
  stat -c %u "$1" 2>/dev/null || echo "$2"
}

# Octal permission mode of a file; $2 is returned when it cannot be read.
host_file_mode() { # path default
  stat -c %a "$1" 2>/dev/null || echo "$2"
}

# Filesystem type of a directory ("unknown" when it cannot be read). DELTACTL_FSTYPE overrides it (tests).
host_fs_type() { # dir
  printf '%s' "${DELTACTL_FSTYPE:-$(stat -f -c %T "$1" 2>/dev/null || echo unknown)}"
}

# Free space, in KB, of the filesystem that holds a path (empty when it cannot be read).
host_free_kb() { # path
  df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

# Numeric id of the user running the tool.
host_uid() { id -u; }

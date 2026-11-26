#!/usr/bin/env bash
# ./deltactl doctor [--json]
# Server diagnosis, READ-ONLY: what the server needs to run deltactl (Docker and Compose, disk, memory, Mongo, helper tools and
# the recommended extras), listed in lib/core/prereqs.data and checked by lib/core/prereqs.sh, plus the permissions of the
# instances. Every failure says how to fix it and, when the package manager is known, the command to install it (it never installs).
# With --json it prints the whole report as JSON (the same data the panel's Server screen shows). Exit code 1 if there are errors.

# ck (report with symbols) comes from check.sh
source "$ROOT/lib/cmd/check.sh"

# Prints the results of the check that just ran (PR_RES_*) as report lines. A result that is not fine also says how to install
# what is missing, when there is a command for this server's package manager.
dr_render() { # id
  local id="$1" i st hint line cmd=""
  local -a hints
  if prereq_install_r "$id"; then cmd="$(t prereq.install_hint "$PR_MANAGER" "$PR_INSTALL")"; fi
  for i in "${!PR_RES_ST[@]}"; do
    [ "${PR_RES_QUIET[$i]}" = 0 ] || continue
    st="${PR_RES_ST[$i]}"
    hints=()
    hint="${PR_RES_HINT[$i]}"
    while IFS= read -r line; do [ -z "$line" ] || hints+=("$line"); done <<< "$hint"
    case "$st" in ok) ;; *) [ -z "$cmd" ] || hints+=("$cmd") ;; esac
    ck "$st" "${PR_RES_MSG[$i]}" ${hints[@]+"${hints[@]}"}
  done
}

# The requirements of one section of the report, in the order of the catalog.
dr_section() { # section
  local id
  ui_h2 "$(t "doctor.sec.$1")"
  for id in "${PR_IDS[@]}"; do
    [ "${PR_SECTION[$id]}" = "$1" ] || continue
    prereq_run "$id"
    dr_render "$id"
  done
}

dr_instances() {
  local v f name dir bad uid fstype p n=0
  ui_h2 "$(t doctor.sec.instances)"
  for f in "$INSTANCES_DIR"/*/.env.instance; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    dir="$(dirname "$f")"
    name="$(basename "$dir")"
    bad=""
    # Windows mounted in WSL (/mnt/c...) and other systems without Unix permissions show everything as 777:
    # nothing can be checked and warning would be a false positive. DELTACTL_FSTYPE lets tests force it.
    fstype="$(host_fs_type "$dir")"
    case "$fstype" in
      9p | drvfs | ntfs | fuseblk | vfat | msdos | exfat)
        ck info "$(t doctor.fs_noperm "$name" "$fstype")"
        continue
        ;;
    esac
    for v in .env.instance "${KNOWN_SERVICES[@]/#/.env.}"; do
      [ -f "$dir/$v" ] || continue
      p="$(host_file_mode "$dir/$v" 600)"
      case "$p" in *00) ;; *) bad+="$v ($p) " ;; esac
    done
    uid="$(host_owner_uid "$dir/data" "$RUNTIME_UID")"
    if [ -n "$bad" ]; then
      ck warn "$(t doctor.secrets_readable "$name" "$bad")" "$(t doctor.secrets_readable_hint "$dir")"
    elif [ -d "$dir/secrets" ] && [ "$(host_owner_uid "$dir/secrets" "$RUNTIME_UID")" != "$RUNTIME_UID" ]; then
      ck warn "$(t doctor.secrets_uid "$name" "$(host_owner_uid "$dir/secrets" "$RUNTIME_UID")" "$RUNTIME_UID")" "$(t doctor.secrets_uid_hint "$RUNTIME_UID" "$dir")"
    elif [ "$uid" != "$RUNTIME_UID" ]; then
      ck warn "$(t doctor.data_uid "$name" "$uid" "$RUNTIME_UID")" \
        "$(t doctor.data_uid_hint "$RUNTIME_UID" "$dir")"
    else
      ck ok "$(t doctor.perms_ok "$name")"
    fi
  done
  [ "$n" -gt 0 ] || ck info "$(t doctor.no_instances)"
}

cmd_doctor() {
  local json=0
  case "${1:-}" in
    "") ;;
    --json) json=1; shift ;;
    *) die "$(t doctor.no_args)" ;;
  esac
  [ "$#" -eq 0 ] || die "$(t doctor.no_args)"
  prereq_reset
  prereq_distro

  if [ "$json" -eq 1 ]; then
    prereq_run_all
    prereq_json
    [ "$PR_N_ERR" -eq 0 ]
    return
  fi

  ui_h1 "$(t doctor.title)"
  dr_section docker
  dr_section resources
  dr_section mongo
  dr_instances
  dr_section tools
  dr_section recommended

  printf '\n'
  if [ "$CK_ERR" -gt 0 ]; then
    printf '  %s %s%s%s\n' "$(ui_sym err)" "$C_RED" "$(t doctor.summary_err "$CK_ERR" "$CK_WARN")" "$C_OFF"
    return 1
  fi
  if [ "$CK_WARN" -gt 0 ]; then
    printf '  %s %s%s%s\n' "$(ui_sym warn)" "$C_YEL" "$(t doctor.summary_warn "$CK_WARN")" "$C_OFF"
  else
    printf '  %s %s%s%s\n' "$(ui_sym ok)" "$C_GRN" "$(t doctor.summary_ok)" "$C_OFF"
  fi
}

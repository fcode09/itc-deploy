#!/usr/bin/env bash
# shellcheck disable=SC2034  # INST_* are read by the new-instance wizard of the panel and the tests
# Is a name free for a new instance? The folder is not enough: Docker Compose names its project after the instance, so a project that
# still has containers, or a network called "<name>_default", belongs to something that is not in instances/ (an instance whose folder
# was removed by hand, another stack on the same server) and the new instance would collide with it at the first `deploy`.
# Sourced by lib/bootstrap.sh after lib/core/instance.sh; pure Bash.
#
#   inst_docker_names            reads Docker once: INST_PROJECTS and INST_NETWORKS ("|a|b|", every name between bars). Returns 1 when
#                                Docker does not answer (then only the folder can clash).
#   inst_name_clash <name>       leaves in INST_CLASH what the name collides with: "" (free), folder, project or network. It runs no
#                                process: it compares with what inst_docker_names read, so it can be asked at every key typed.

INST_PROJECTS="|" INST_NETWORKS="|" INST_CLASH=""

inst_docker_names() {
  local n
  INST_PROJECTS="|" INST_NETWORKS="|"
  dk_ready || return 1
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    [[ "$INST_PROJECTS" == *"|$n|"* ]] || INST_PROJECTS+="$n|"
  done < <(dk_compose_projects)
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    [[ "$INST_NETWORKS" == *"|$n|"* ]] || INST_NETWORKS+="$n|"
  done < <(dk_network_names)
  return 0
}

inst_name_clash() { # name
  local n="$1"
  INST_CLASH=""
  if [ -e "$INSTANCES_DIR/$n" ]; then INST_CLASH=folder
  elif [[ "$INST_PROJECTS" == *"|$n|"* ]]; then INST_CLASH=project
  elif [[ "$INST_NETWORKS" == *"|${n}_"* ]]; then INST_CLASH=network; fi
  [ -z "$INST_CLASH" ]
}

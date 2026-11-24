#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_*, DASH_NZ_* and IC_* tables are read by the panel that draws them
# Scenes of the new-instance wizard (lib/screens/newinst.sh) with fixed data: each one opens the wizard against the simulated docker of the test that
# calls it (tests/fake-docker.sh with the images of tests/tools/images_scenes.sh), fixes the clock (IC_NOW) so "2 days ago" is always the same, presses
# the keys of the scene and draws the whole panel frame at the size of the environment (COLUMNS, DELTACTL_TUI_ROWS). They are the golden snapshots of
# tests/test-newinst.sh (tests/golden/newinst/) and the source of the PNG captures. Sourced, never executed: it needs lib/bootstrap.sh and
# lib/cmd/dashboard.sh already loaded, the simulated docker first in the PATH and the environment of the panel (DELTACTL_UI=rich, DELTACTL_TUI_KEYS=...).
#
#   newinst_scene <name>     name: name | taken | services | versions | typing | data | preview | existing

NEWINST_SCENES=(name taken services versions typing data preview existing)
NEWINST_NOW=1795521600   # 2026-11-24 12:00:00 UTC

newinst_scene() { # name
  local name="$1" k
  local -a keys=()
  tui_size
  dash_init
  DASH_HOST=testhost
  DASH_DOCKER_VER=27.0.0
  MT_HOST_PCT=48 MT_HOST_TOTAL_KB=12058624 MT_HOST_USED_KB=5892096 MT_HOST_LOAD=3.18 MT_HOST_HIST=""
  IC_NOW="$NEWINST_NOW"
  DASH_NAMES=()
  DASH_SVCS=()
  DASH_WIZARD=2
  case "$name" in
    name) keys=() ;;
    taken) keys=(backspace c o l o r a d o) ;;                       # a project that Docker still has containers of
    services) keys=(enter space) ;;                                  # the first service unmarked: s1 warns that it uses s0
    versions) keys=(enter enter) ;;
    typing) keys=(enter enter down down down down enter 2 . 1 5) ;;   # "write another version" being typed
    data) keys=(enter enter enter enter) ;;
    existing) keys=(enter enter enter enter down) ;;
    preview) keys=(tab) ;;
    *) echo "unknown scene $name" >&2; return 1 ;;
  esac
  dash_nz_open
  # (the ports of the machine are not part of a snapshot)
  for k in "${KNOWN_SERVICES[@]}"; do DASH_NZ_PBUSY["$k"]=0; done
  for k in "${keys[@]}"; do scr_newinst_key "$k"; done
  dash_render
}

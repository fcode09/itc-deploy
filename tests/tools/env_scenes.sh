#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the KEE_* and DASH_* tables are read by the panel that draws them
# Scenes of the Variables view with fixed data: each one opens the editor on an instance of the isolated copy that the test that calls it has
# made (instances ix-colorado, which still has everything to fill in, and ix-lima, which is complete; tests/test-envview.sh), moves the cursor
# and types with the same functions the keys call, and draws the whole panel frame at the size of the environment (COLUMNS, DELTACTL_TUI_ROWS).
# They are the golden snapshots of tests/test-envview.sh (tests/golden/envview/) and the source of the PNG captures. Sourced, never executed:
# it needs lib/bootstrap.sh and lib/cmd/dashboard.sh already loaded and the environment of the panel (DELTACTL_UI=rich, DELTACTL_TUI_KEYS=...).
#
#   env_scene <name>     name: todo | row | edit | invalid | secret | gen | leave | deploy | pending | ok | advanced | folded | none

ENV_SCENES=(todo row edit invalid secret gen leave deploy pending ok advanced folded none)

# Presses keys in the editor as the panel would (the names tui_key produces).
env_press() { local k; for k in "$@"; do kee_key "$k"; done; }

# Puts the cursor on a variable (file and key) without pressing keys: the scene does not depend on how many rows are above it.
env_goto() { # file key
  local i
  for i in "${!KEE_ROWS[@]}"; do
    [ "${KEE_ROWS[$i]}" != "V|$1|$2" ] || { KEE_SEL="$i"; kee_move 0; return 0; }
  done
  return 1
}

# Types a text into the field being edited (one key per character; a space is the key `space`).
env_type() { # text
  local t="$1" i c
  for ((i = 0; i < ${#t}; i++)); do
    c="${t:i:1}"
    if [ "$c" = " " ]; then c=space; fi
    kee_key "$c"
  done
}

env_scene() { # name
  local name="$1" inst=ix-colorado
  tui_size
  dash_init
  DASH_HOST=testhost
  DASH_DOCKER_VER=27.0.0
  MT_HOST_PCT=48 MT_HOST_TOTAL_KB=12058624 MT_HOST_USED_KB=5892096 MT_HOST_LOAD=3.18 MT_HOST_HIST=""
  DASH_NAMES=(ix-colorado ix-lima)
  DASH_SVCS=([ix-colorado]="s0 s1" [ix-lima]="s0 s1")
  DASH_SEL=0
  DASH_VIEW="env"
  case "$name" in
    ok | deploy | leave | gen | pending | secret) inst=ix-lima ;;
  esac
  if [ "$name" = none ]; then
    DASH_NAMES=() DASH_SVCS=()
    DASH_ENV_INST=""
  else
    dash_env_load "$inst"
    DASH_MODE=envedit
  fi
  case "$name" in
    todo | none) ;;
    row) env_goto .env.s0 IP_SERVER ;;                                       # required, still the template's
    edit) env_goto .env.s0 IP_SERVER; env_press enter; env_type "https://colorado.itc.pe" ;;   # a value that validates
    invalid) env_goto .env.s0 IP_SERVER; env_press enter; env_type "colorado" ;;               # one that does not
    secret) env_goto .env.s0 MONGO_URI ;;                                    # a secret: drawn as dots
    gen) env_goto .env.s0 JWT_SECRET; env_press g ;;                         # it already has a value: asks before replacing it
    leave) env_goto .env.s0 IP_SERVER; env_press enter $'\025'; env_type "https://x.itc.pe"; env_press enter esc ;;   # a change is staged and Esc asks what to do
    deploy) env_press u ;;                                                   # asks to deploy with nothing staged
    pending) ;;                                                              # (the test marked .env.s0 as changed since the last deploy)
    ok) ;;
    advanced) env_press a right; env_goto .env.instance S0_MEM_LIMIT ;;
    folded) env_press down enter ;;                                          # folds .env.s0
  esac
  dash_render
}

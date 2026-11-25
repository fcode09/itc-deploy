#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the JOB_* and DASH_* variables are read by the panel that draws them
# Scenes of the Output view with fixed data: each one puts the output a command printed (tests/golden/outsum/in/<file>-<lang>.txt, captured by
# tests/tools/outsum_capture.sh) in the place of the panel's job, with its title, its exit code and a fixed clock, and draws the whole panel frame
# at the size of the environment (COLUMNS, DELTACTL_TUI_ROWS). They are the golden snapshots of tests/test-outsum.sh (tests/golden/outsum/) and the
# source of the PNG captures. Sourced, never executed: it needs lib/bootstrap.sh and lib/cmd/dashboard.sh already loaded and the environment of
# the panel (DELTACTL_UI=rich, DELTACTL_TUI_KEYS=...). The language of the input is DELTACTL_LANG.
#
#   outsum_scene <name>      name: new | check-ok | check-fail | deploy | deploy-fail | deploy-running | init | doctor | images | env | raw | unknown

OUTSUM_SCENES=(new check-ok check-fail deploy deploy-fail deploy-running init doctor images env raw unknown)

outsum_scene() { # name [keys...]
  local name="$1" base="" cmd="" rc=0 running=0 head=0 raw=0 lang="${DELTACTL_LANG:-es}" k
  shift
  case "$name" in
    new) base=new cmd="new colorado" ;;
    check-ok) base=check-ok cmd="check sim-01" ;;
    check-fail) base=check-fail cmd="check sim-01" rc=1 ;;
    deploy) base=deploy cmd="deploy sim-01" ;;
    deploy-fail) base=deploy-fail cmd="deploy sim-01" rc=1 ;;
    deploy-running) base=deploy cmd="deploy sim-01" running=1 head=2 ;;
    init) base=init cmd="init sim-01" rc=1 ;;
    doctor) base=doctor cmd="doctor" ;;
    images) base=images cmd="images" ;;
    env) base=env cmd="env sim-01 list" ;;
    raw) base=doctor cmd="doctor" raw=1 ;;       # the same output as `doctor`, in the person's choice of the raw text
    unknown) base=check-ok cmd="status sim-01" ;; # a command that is not recognised: it is raw, as always
    *) echo "unknown scene $name" >&2; return 1 ;;
  esac
  tui_size
  dash_init
  DASH_HOST=testhost
  DASH_DOCKER_VER=27.0.0
  MT_HOST_PCT=48 MT_HOST_TOTAL_KB=12058624 MT_HOST_USED_KB=5892096 MT_HOST_LOAD=3.18 MT_HOST_HIST=""
  DASH_NAMES=(sim-01 sim-02 sim-03)
  DASH_SVCS=([sim-01]="s0 s1" [sim-02]="s0 s1" [sim-03]="s0 s1")
  mapfile -t JOB_LINES < "tests/golden/outsum/in/$base-$lang.txt"
  [ "$head" -eq 0 ] || JOB_LINES=("${JOB_LINES[@]:0:$head}")
  JOB_PID=4242 JOB_TITLE="$cmd" JOB_SEQ=1 JOB_TOTAL="${#JOB_LINES[@]}" JOB_CANCELLED=0 JOB_KILLED=0
  JOB_START_US=1000000
  if [ "$running" -eq 1 ]; then JOB_RC="" JOB_END_US=0; HOST_FAKE_NOW_US=4000000
  else JOB_RC="$rc" JOB_END_US=43000000; fi
  DASH_OUT_RAW="$raw" DASH_OUT_STOP=0 DASH_OUT_SCROLL=0 DASH_OUT_ERRORS=0
  DASH_VIEW=output
  # The keys go to the view after it has drawn once (it learns there whether it shows the summary and how long it is).
  if [ "$#" -gt 0 ]; then
    dash_render > /dev/null
    for k in "$@"; do scr_output_key "$k"; done
  fi
  dash_render
}

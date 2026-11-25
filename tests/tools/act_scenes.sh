#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_*, JOB_* and RUN tables are read by the panel that draws them
# Scenes of the Activity view (lib/screens/activity.sh) with fixed data: five recorded runs in a folder of their own (a deploy with its figures
# and an earlier one to compare with, a check that failed, a deploy of another instance and a rollback whose output has no shape) and, in some
# scenes, the last command of the panel finished with a known duration. Each scene draws the whole panel frame at the size of the environment
# (COLUMNS, DELTACTL_TUI_ROWS). They are the golden snapshots of tests/test-activity.sh (tests/golden/activity/) and the source of the PNG captures.
# Sourced, never executed: it needs lib/bootstrap.sh and lib/cmd/dashboard.sh already loaded and the environment of the panel
# (DELTACTL_UI=rich, DELTACTL_TUI_KEYS=...).
#
#   act_scene <name>   name: resumen | resumensel | salida | consumo | stats | procesos | jobsum | jobout | jobcost | vacia

ACT_SCENES=(resumen resumensel salida consumo stats procesos jobsum jobout jobcost vacia)

# The runs, in a temporary folder (ACT_TMP) that the scene removes when it has drawn.
act_data() {
  local d lang="${DELTACTL_LANG:-es}"
  d="$(mktemp -d)"
  ACT_TMP="$d"
  INSTANCES_DIR="$d"
  mkdir -p "$d/.deltactl/runs"
  act_run() { # id op args instance state rc started ms output-file [extra lines of the metadata]
    mkdir -p "$d/.deltactl/runs/$1"
    printf 'RUN_ID=%s\nOP=%s\nARGS=%s\nINSTANCE=%s\nSTATE=%s\nRC=%s\nSTARTED_AT=%s\nENDED_AT=%s\nDURATION_MS=%s\nUSER=ana\nHOST=testhost\n%s\n' \
      "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$7" "$8" "${10:-}" > "$d/.deltactl/runs/$1/meta"
    cp "$9" "$d/.deltactl/runs/$1/out.log"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$7" "$2" "$4" "$5" "$6" "$8" >> "$d/.deltactl/runs.idx"
  }
  printf 'Rolling back auth-backend to 2.13.0\nDone\n' > "$d/plain.txt"
  act_run 20261030T100000Z-0 deploy ix-colorado ix-colorado succeeded 0 2026-10-30T10:00:00Z 38000 "tests/golden/outsum/in/deploy-$lang.txt" \
    $'CPU_MS=8000\nDOCKER_MS=28000\nDOCKER_CALLS=12\nPEAK_RSS_KB=40000\nPEAK_PROCS=5\nOUT_BYTES=2100\nOUT_LINES=38'
  act_run 20261031T150000Z-3 rollback "ix-colorado s0" ix-colorado succeeded 0 2026-10-31T15:00:00Z 5300 "$d/plain.txt"
  act_run 20261101T090000Z-2 check ix-colorado ix-colorado failed 1 2026-11-01T09:00:00Z 2100 "tests/golden/outsum/in/check-fail-$lang.txt"
  act_run 20261101T095000Z-4 deploy ix-lima ix-lima succeeded 0 2026-11-01T09:50:00Z 30100 "tests/golden/outsum/in/deploy-$lang.txt"
  act_run 20261101T100000Z-1 deploy ix-colorado ix-colorado succeeded 0 2026-11-01T10:00:00Z 41200 "tests/golden/outsum/in/deploy-$lang.txt" \
    $'CPU_MS=9100\nDOCKER_MS=30500\nDOCKER_CALLS=14\nPEAK_RSS_KB=48200\nPEAK_PROCS=6\nOUT_BYTES=2300\nOUT_LINES=40'
}

# The last command of the panel, finished: `images`, 7 s, with its output as the Output view's scenes have it.
act_job() {
  local lang="${DELTACTL_LANG:-es}"
  mapfile -t JOB_LINES < "tests/golden/outsum/in/images-$lang.txt"
  JOB_PID=999 JOB_TITLE="images" JOB_RC=0 JOB_CANCELLED=0 JOB_START_US=1000000000 JOB_END_US=1007000000 JOB_SEQ=1 JOB_TOTAL="${#JOB_LINES[@]}"
}

act_scene() { # name
  local name="$1"
  tui_size
  dash_init
  DASH_HOST=testhost
  DASH_DOCKER_VER=27.0.0
  case "$name" in
    vacia) ACT_TMP="$(mktemp -d)"; INSTANCES_DIR="$ACT_TMP" ;;
    *) act_data ;;
  esac
  case "$name" in
    jobsum | jobout | jobcost) act_job ;;
  esac
  DASH_VIEW=activity
  dash_runs_load
  scr_activity_enter
  case "$name" in jobsum | jobout | jobcost) DASH_ACT_ON_JOB=1 ;; esac   # (the fixed job is an old one: the cursor is put on it)
  case "$name" in
    resumen | vacia | jobsum) ;;
    resumensel) dash_act_select 2 ;;
    salida | jobout) dash_act_tab_go salida ;;
    consumo | jobcost) [ "$name" = consumo ] && dash_act_select 0; dash_act_tab_go consumo ;;
    stats) dash_act_tab_go consumo; DASH_ACT_STATS=1; dash_runs_stats_load ;;
    procesos) DASH_SELF_PID=200 DASH_PS_RSS=7800 DASH_PS_NOW="2.5%" DASH_PS_AVG="1.0%"; dash_act_tab_go procesos ;;   # (the panel's own figures, fixed)
    *) echo "unknown scene $name" >&2; return 1 ;;
  esac
  dash_host_build
  dash_render
  [ -z "${ACT_TMP:-}" ] || rm -rf "$ACT_TMP"
}

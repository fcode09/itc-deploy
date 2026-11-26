#!/usr/bin/env bash
# Times the panel's frame builders against the simulated server (never the real Docker): one frame per view at 80x24, 120x30 and 160x40
# (average of N, default 40; the Server view against a simulated host, tests/tools/sim_env.sh), and the Server view alone at 200x55 and
# 250x70 (the sizes of a big monitor). Used for the before/after numbers of the redesign. usage: tests/tools/bench_frames.sh [N] [theme]
# BENCH_ONLY=server times only the Server view (and the sampler), at every size; BENCH_SIZES="80x24 160x40" picks the sizes; BENCH_INSTANCES=4
# builds fewer simulated instances (12 by default; each one takes seconds to create where processes are slow).
set -u
N="${1:-40}" THEME="${2:-matrix}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/tools/sim_env.sh
source "$HERE/sim_env.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
sim_build "$TMP/sim" "${BENCH_INSTANCES:-12}"
sim_host "$TMP/host"
# The Images view needs something to list: 14 versions of the image of s0 (one for another architecture, one latest) and 6 of s1, with dates.
for _i in $(seq 1 12); do
  printf 'backend-s0:2.%d.0|sha256:%012d|amd64\n' "$_i" "$_i" >> "$SIM_FIX/images.txt"
  printf 'backend-s0:2.%d.0|%s\n' "$_i" "$(date -u -d "$((_i + 1)) days ago" '+%Y-%m-%d %H:%M:%S +0000 UTC')" >> "$SIM_FIX/image_dates.txt"
done
printf 'backend-s0:3.0.0-rc1|sha256:%012d|arm64\nbackend-s0:latest|sha256:%012d|amd64\n' 91 92 >> "$SIM_FIX/images.txt"
printf 'backend-s0:3.0.0-rc1|%s\nbackend-s0:latest|%s\n' "$(date -u '+%Y-%m-%d %H:%M:%S +0000 UTC')" "$(date -u -d '3 days ago' '+%Y-%m-%d %H:%M:%S +0000 UTC')" >> "$SIM_FIX/image_dates.txt"
for _i in 1 2 3 4 5 6; do
  printf 'backend-s1:1.%d.0|sha256:%012d|amd64\n' "$_i" $((100 + _i)) >> "$SIM_FIX/images.txt"
  printf 'backend-s1:1.%d.0|%s\n' "$_i" "$(date -u -d "$((_i * 3)) days ago" '+%Y-%m-%d %H:%M:%S +0000 UTC')" >> "$SIM_FIX/image_dates.txt"
done
cd "$SIM_REPO" || exit 1
ms() { # label n command...
  local label="$1" n="$2" i t0 t1
  shift 2
  t0="${EPOCHREALTIME/./}"
  for ((i = 0; i < n; i++)); do "$@" > /dev/null; done
  t1="${EPOCHREALTIME/./}"
  printf '%-36s %8.1f ms\n' "$label" "$(awk -v a="$t0" -v b="$t1" -v n="$n" 'BEGIN { printf "%.1f", (b - a) / n / 1000 }')"
}
ONLY="${BENCH_ONLY:-}"
for size in ${BENCH_SIZES:-80x24 120x30 160x40 200x55 250x70}; do
  SRV_ONLY=0
  { [ "$ONLY" = server ] || [ "${size%x*}" -gt 160 ]; } && SRV_ONLY=1
  (
    export ROOT="$PWD" LANG=C.UTF-8 DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=always COLORTERM=truecolor \
      COLUMNS="${size%x*}" DELTACTL_TUI_ROWS="${size#*x}" DELTACTL_THEME="$THEME"
    # shellcheck source=/dev/null
    source lib/bootstrap.sh; source lib/cmd/dashboard.sh
    set +e
    tui_size; dash_init
    dash_refresh > /dev/null 2>&1; mt_sample; sleep 0.3; mt_sample
    # The Server view reads the figures of the host as well (MT_HOST_DETAIL): a full history (240 readings, one second apart on a fake clock)
    # of the simulated host, whose counters move.
    for _t in $(seq 1 250); do sim_host_tick "$_t"; HOST_FAKE_NOW_US=$((_t * 1000000)) MT_HOST_DETAIL=1 mt_sample; done; MT_HOST_DETAIL=0
    dash_srv_apply "$(dash_srv_dump)" > /dev/null 2>&1
    dash_img_apply "$(dash_img_dump)" > /dev/null 2>&1
    dash_host_build
    dash_env_load sim-01 > /dev/null 2>&1   # (the Variables view: an instance of the simulated server, its deploy marks read at once in the test mode)
    echo "== $size"
    if [ "$SRV_ONLY" -eq 0 ]; then
    for v in instances resources output runs procs console server images env; do
      DASH_VIEW="$v"
      ms "dash_render $v (cached/hot)" "$N" dash_render
    done
    DASH_VIEW=instances
    # shellcheck disable=SC2329  # called through ms
    cold() { DASH_PC_SIG=(); dash_render; }
    ms "dash_render instances, cold" 10 cold
    # The workspace of an instance with rows to resolve (the cursor in "Para desplegar", the files of the instance read as the panel reads them in
    # the background) and one key that moves its cursor (the box of the summary is built again, the list and the logs are not).
    # shellcheck disable=SC2329,SC2034  # called through ms
    ws_key() { DASH_TODO_SEL=$(((DASH_TODO_SEL + 1) % (DASH_TODO_N > 0 ? DASH_TODO_N : 1))); dash_render; }
    DASH_SEL=1; dash_ws_apply "${DASH_NAMES[1]}" "$(dash_ws_dump "${DASH_NAMES[1]}")" > /dev/null 2>&1; DASH_FOCUS=todo
    ms "instances, a key in the to-do rows" "$N" ws_key
    DASH_FOCUS=list DASH_SEL=0
    fi
    # The Server view at every sample (what it costs every 2 s while it is on screen). "idle": the figures do not move (the boxes are reused);
    # "busy": the simulated host moves, so every box is built again (the sampling of the host is part of it).
    # shellcheck disable=SC2329  # called through ms
    fresh_idle() { MT_SAMPLES=$((MT_SAMPLES + 1)); dash_render; }
    # shellcheck disable=SC2329,SC2034  # called through ms; the variables are read by the panel
    fresh_busy() { _t=$((_t + 1)); sim_host_tick "$_t"; HOST_FAKE_NOW_US=$((_t * 1000000)) MT_HOST_DETAIL=1 mt_sample; MT_HOST_DETAIL=0; dash_render; }
    DASH_VIEW=server
    ms "dash_render server, idle sample" "$N" fresh_idle
    ms "server: sample + render, busy" "$N" fresh_busy
    if [ "$SRV_ONLY" -eq 0 ]; then
    # The Images view: a new answer builds the lists again (cold); the cursor moving only marks another line (the frame is built again, the
    # lists are not). Reading the catalog (a few processes: the query to Docker) runs in the background in the panel, so it is shown apart.
    # shellcheck disable=SC2329,SC2034  # called through ms; DASH_IMG_KEY is read by the panel
    img_cold() { DASH_IMG_KEY=""; DASH_IMG_SEL=$(((DASH_IMG_SEL + 1) % ${#DASH_IMG_ITEMS[@]})); dash_render; }
    # shellcheck disable=SC2329  # called through ms
    img_move() { DASH_IMG_SEL=$(((DASH_IMG_SEL + 1) % ${#DASH_IMG_ITEMS[@]})); DASH_PC_SIG=(); dash_render; }
    # shellcheck disable=SC2329  # called through ms
    img_read() { dash_img_apply "$(dash_img_dump)"; }
    DASH_VIEW=images
    ms "images: a new answer (lists built again)" 10 img_cold
    ms "images: cursor moves (frame built again)" "$N" img_move
    ms "images: read the catalog (background in the panel)" 10 img_read
    DASH_VIEW=instances
    # The new-instance wizard (mode newinst): a key moves the cursor of the step that is open (the whole frame is built again: the form, the
    # preview and the list of the steps), once per step; opening it reads Docker once (names and images), shown apart.
    # shellcheck disable=SC2329,SC2034  # called through ms
    nz_open() { dash_nz_open; DASH_MODE=normal; }
    # shellcheck disable=SC2329,SC2034  # called through ms
    nz_key() { scr_newinst_key down; scr_newinst_key up; dash_render; }
    # shellcheck disable=SC2329  # called through ms
    nz_cold() { DASH_PC_SIG=(); scr_newinst_key down; scr_newinst_key up; dash_render; }
    ms "wizard: open (reads Docker once)" 10 nz_open
    dash_nz_open
    for _s in 0 1 2 3 4 5 6 7; do
      dash_nz_goto "$_s"
      ms "wizard: step $((_s + 1)), a key and a frame" "$N" nz_key
      ms "wizard: step $((_s + 1)), every box built again" "$N" nz_cold
    done
    DASH_MODE=normal
    # The Variables view: opening an instance (its files are read and every variable evaluated: a few ms, once), a key that moves the cursor (the
    # editor draws its box again) and a character typed in a field (the validation runs and the box is drawn again).
    # shellcheck disable=SC2329  # called through ms
    env_open() { kee_open sim-01; DASH_PC_SIG=(); dash_render; }
    # shellcheck disable=SC2329  # called through ms
    env_move() { kee_key down; [ "$KEE_SEL" -lt $((${#KEE_ROWS[@]} - 1)) ] || kee_key home; dash_render; }
    # shellcheck disable=SC2329  # called through ms
    env_char() { kee_key a; dash_render; }
    DASH_VIEW=env DASH_MODE=envedit
    ms "env: open an instance (files read)" 10 env_open
    ms "env: cursor moves (box drawn again)" "$N" env_move
    kee_key home; kee_key down; kee_key down; kee_key enter
    ms "env: a character typed in a field" "$N" env_char
    kee_key esc
    DASH_VIEW=instances DASH_MODE=normal
    # The Output view with a command that has a shape (the output of `doctor`, 37 lines, summarised: lib/core/outparse.sh + lib/ui/outsummary.sh). "hot":
    # the frame of a summary that is already built (what a frame costs while the output does not change); "a key": the window moves (the frame is
    # built again from the summary); "new output": the output is parsed and the summary built again (once per output and size, never per frame);
    # "raw": the same lines drawn as the plain text (v), for comparison.
    mapfile -t JOB_LINES < tests/golden/outsum/in/doctor-es.txt
    JOB_PID=4242 JOB_TITLE="doctor" JOB_RC=0 JOB_SEQ=1 JOB_TOTAL="${#JOB_LINES[@]}" JOB_START_US=1000000 JOB_END_US=43000000
    DASH_VIEW=output DASH_OUT_RAW=0 DASH_OUT_STOP=0
    # shellcheck disable=SC2329,SC2034  # called through ms
    out_key() { DASH_OUT_STOP=$(((DASH_OUT_STOP + 1) % 15)); dash_render; }
    # shellcheck disable=SC2329,SC2034  # called through ms
    out_cold() { OUTSUM_KEY=""; DASH_PC_SIG=(); dash_render; }
    # shellcheck disable=SC2329,SC2034  # called through ms
    out_parse_only() { OUTSUM_KEY=""; outsum_for JOB_LINES doctor 0 0 $((${size%x*} - 4)) k; }
    dash_render > /dev/null
    ms "output (summary): hot frame" "$N" dash_render
    ms "output (summary): a key moves the window" "$N" out_key
    ms "output (summary): new output, parse + build" "$N" out_parse_only
    ms "output (summary): new output, whole frame" "$N" out_cold
    DASH_OUT_RAW=1
    ms "output (raw): hot frame" "$N" dash_render
    # shellcheck disable=SC2034  # read by the Output view
    DASH_OUT_RAW=0 DASH_VIEW=instances
    # The Activity view (lib/screens/activity.sh) over the five runs of tests/tools/act_scenes.sh and the command above as the last one of the
    # panel. "hot": the frame of a selection that is already built; "a key": the cursor moves to another run (its detail is built again, once);
    # "a page": the saved output is open in the tab Salida and a page is asked for; "processes": the tab Procesos (the tree is read by the tick).
    # shellcheck source=tests/tools/act_scenes.sh
    source tests/tools/act_scenes.sh
    act_data; act_job
    JOB_LINES=(); mapfile -t JOB_LINES < tests/golden/outsum/in/doctor-es.txt
    JOB_TITLE=doctor JOB_END_US=43000000 JOB_TOTAL="${#JOB_LINES[@]}"
    DASH_VIEW=activity; dash_runs_load; scr_activity_enter
    dash_act_select 1
    # shellcheck disable=SC2329,SC2034  # called through ms
    act_key() { DASH_ACT_SWAP=$((1 - ${DASH_ACT_SWAP:-0})); dash_act_select $((1 + DASH_ACT_SWAP * 2)); dash_render; }
    # shellcheck disable=SC2329,SC2034  # called through ms
    act_page() { if [ "$((DASH_ACT_SWAP = 1 - ${DASH_ACT_SWAP:-0}))" -eq 1 ]; then dash_act_pane_key pgup; else dash_act_pane_key end; fi; dash_render; }
    dash_render > /dev/null
    ms "activity: hot frame (the summary of a run)" "$N" dash_render
    ms "activity: a key moves to another run" "$N" act_key
    dash_act_select 3; dash_act_tab_go salida; dash_render > /dev/null
    ms "activity: a page of the saved output" "$N" act_page
    dash_act_tab_go consumo; dash_render > /dev/null
    ms "activity: Consumo, hot frame" "$N" dash_render
    dash_act_tab_go procesos; dash_render > /dev/null
    ms "activity: Procesos, hot frame" "$N" dash_render
    dash_act_tab_go resumen; dash_act_select 0; dash_render > /dev/null
    ms "activity: the command of the panel, hot" "$N" dash_render
    rm -rf "${ACT_TMP:-/nonexistent}"
    fi
    DASH_VIEW=instances
    ms "mt_sample" "$N" mt_sample
    # shellcheck disable=SC2329,SC2034  # called through ms; MT_HOST_DETAIL is read by mt_sample
    mt_detail() { MT_HOST_DETAIL=1 mt_sample; MT_HOST_DETAIL=0; }
    ms "mt_sample, with the host figures" "$N" mt_detail
  )
done

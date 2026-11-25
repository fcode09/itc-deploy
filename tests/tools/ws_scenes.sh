#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_*, DSV_*, MT_*, IC_* and ST_* tables are read by the panel that draws them
# Scenes of the Instances view (the list and the workspace of the instance) with fixed data: each one fills the tables the view reads with
# deterministic values (four instances in four states, their services, the figures and histories of the running ones, what `status` suggests,
# what the files of the instance and the catalog of images say) and draws the whole panel frame at the size of the environment (COLUMNS,
# DELTACTL_TUI_ROWS). They are the golden snapshots of tests/test-workspace.sh (tests/golden/workspace/) and the source of the PNG captures.
# Sourced, never executed: it needs lib/bootstrap.sh and lib/cmd/dashboard.sh already loaded and the environment of the panel
# (DELTACTL_UI=rich, DELTACTL_TUI_KEYS=...).
#
#   ws_scene <name>      name: cards | todo | todofocus | ok | stopped | logs | none | filter | sort | new | servicios | serviciosoff | askremove | asktag | askport

WS_SCENES=(cards todo todofocus ok stopped logs none filter sort new acceso accesocaddy accesonodom accesoedit accesobad historial historialsel historialempty servicios serviciosoff askremove asktag askport)

# The runs of the History tab: three of ix-colorado (a deploy and a check whose output has a shape, a rollback whose output has none) and one of
# ix-lima, in a folder of their own that the scene removes when it has drawn (WS_TMP). The inputs are the captured outputs of the Output view's scenes.
ws_historial_data() {
  local d lang="${DELTACTL_LANG:-es}" id
  d="$(mktemp -d)"
  WS_TMP="$d"
  INSTANCES_DIR="$d"
  mkdir -p "$d/.deltactl/runs"
  ws_run() { # id op args instance state rc started ms output-file
    mkdir -p "$d/.deltactl/runs/$1"
    printf 'RUN_ID=%s\nOP=%s\nARGS=%s\nINSTANCE=%s\nSTATE=%s\nRC=%s\nSTARTED_AT=%s\nENDED_AT=%s\nDURATION_MS=%s\nUSER=ana\nHOST=testhost\n' \
      "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$7" "$8" > "$d/.deltactl/runs/$1/meta"
    cp "$9" "$d/.deltactl/runs/$1/out.log"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$7" "$2" "$4" "$5" "$6" "$8" >> "$d/.deltactl/runs.idx"
  }
  printf 'Rolling back auth-backend to 2.13.0\nDone\n' > "$d/plain.txt"
  ws_run 20261031T150000Z-3 rollback "ix-colorado s0" ix-colorado succeeded 0 2026-10-31T15:00:00Z 5300 "$d/plain.txt"
  ws_run 20261101T090000Z-2 check ix-colorado ix-colorado failed 1 2026-11-01T09:00:00Z 2100 "tests/golden/outsum/in/check-fail-$lang.txt"
  ws_run 20261101T095000Z-4 deploy ix-lima ix-lima succeeded 0 2026-11-01T09:50:00Z 30100 "tests/golden/outsum/in/deploy-$lang.txt"
  ws_run 20261101T100000Z-1 deploy ix-colorado ix-colorado succeeded 0 2026-11-01T10:00:00Z 41200 "tests/golden/outsum/in/deploy-$lang.txt"
  unset -f ws_run
  DASH_WS_TAB=historial DASH_FOCUS=tab DASH_SEL=0
  DASH_RUNS_AT=-1000 DASH_HIS_AT=-1000 DASH_HIS_INST="" DASH_HIS_ID="" DASH_HIS_SEL=0 DASH_HIS_OFF=0 DASH_HIS_DET_KEY=""
  dash_runs_load
  dash_his_filter "${1:-ix-colorado}"
}

# The data of the Access tab of ix-colorado: its ports, what answers on this server and what the instance remembers (nothing is read from disk:
# the instance of the scene does not exist).
ws_acceso_data() { # domain flavor tls
  DASH_ACC_DET=nginx DASH_ACC_DET_SET=1
  DASH_ACC_LOADED=([ix-colorado]=1)
  DASH_ACC_DOM=([ix-colorado]="$1") DASH_ACC_FL=([ix-colorado]="$2") DASH_ACC_TLS=([ix-colorado]="$3")
  DASH_ACC_PORT=([ix-colorado/s0]=4100 [ix-colorado/s1]=4101)
  DASH_ACC_REACH=([ix-colorado/s0]=up [ix-colorado/s1]=down)
  DASH_ACC_SIGM="" DASH_ACC_SCROLL=0 DASH_ACC_N=$((DASH_ACC_N + 1))
  DASH_WS_TAB=acceso DASH_FOCUS=tab DASH_SEL=0
}

# A deterministic series of N samples between 0 and $3 (a wave with bursts), oldest first, into WSS.
WSS=""
ws_series() { # count seed max
  local n="$1" seed="${2:-7}" max="${3:-100}" i v out=""
  for ((i = 0; i < n; i++)); do
    v=$(((i * 37 + seed * 11 + (i % 7) * 9 + (i / 5) * 3) % 70))
    if [ $((i % 23)) -ge 18 ]; then v=$((v + 25)); fi
    out+="${out:+ }$((v * max / 100))"
  done
  WSS="$out"
}

ws_fill() {
  local i key
  ST_DOCKER=1
  DASH_NAMES=(ix-colorado ix-lima ix-piura ix-sullana)
  DASH_SVCS=([ix-colorado]="s0 s1" [ix-lima]="s0 s1" [ix-piura]="s0 s1" [ix-sullana]="s0 s1")
  DASH_KIND=([ix-colorado]=ok [ix-lima]=warn [ix-piura]=err [ix-sullana]=dim)
  DASH_NM=([ix-colorado]=2/2 [ix-lima]=1/2 [ix-piura]=0/2 [ix-sullana]=0/2)
  DASH_DATA=([ix-colorado]=init [ix-lima]=init [ix-piura]=unseeded [ix-sullana]=existing)
  DSV_KIND=([ix-colorado/s0]=ok [ix-colorado/s1]=ok [ix-lima/s0]=ok [ix-lima/s1]=err [ix-piura/s0]=err [ix-piura/s1]=err [ix-sullana/s0]=dim [ix-sullana/s1]=dim)
  DSV_TEXT=([ix-colorado/s0]=healthy [ix-colorado/s1]=healthy [ix-lima/s0]=healthy [ix-lima/s1]=exited [ix-piura/s0]=exited [ix-piura/s1]=exited [ix-sullana/s0]="no creado" [ix-sullana/s1]="no creado")
  for key in ix-colorado ix-lima ix-piura ix-sullana; do
    DSV_REF[$key/s0]="auth-backend:2.14.1" DSV_REF[$key/s1]="gueo-back-end:2.9.0"
  done
  DSV_UP=([ix-colorado/s0]=2d04h [ix-colorado/s1]=2d04h [ix-lima/s0]=6h12m)
  DSV_PORT=([ix-colorado/s0]=4100 [ix-colorado/s1]=4101 [ix-lima/s0]=4110 [ix-lima/s1]=4111 [ix-piura/s0]=4120 [ix-piura/s1]=4121 [ix-sullana/s0]=4130 [ix-sullana/s1]=4131)
  ST_STATE=([ix-colorado/s0]=running [ix-colorado/s1]=running [ix-lima/s0]=running [ix-lima/s1]=exited)
  ST_RESTARTS=([ix-colorado/s1]=3)
  # The running ones: memory against the limit, CPU and the history of both.
  MT_MEM=([ix-colorado/s0]=205520896 [ix-colorado/s1]=1288490188 [ix-lima/s0]=188743680)
  MT_LIM=([ix-colorado/s0]=536870912 [ix-colorado/s1]=2147483648 [ix-lima/s0]=536870912)
  MT_CPU=([ix-colorado/s0]=37 [ix-colorado/s1]=214 [ix-lima/s0]=12)
  for key in ix-colorado/s0 ix-colorado/s1 ix-lima/s0; do
    ws_series 60 "$((${#key} + 3))" "${MT_LIM[$key]}"; MT_HMEM[$key]="$WSS"
    ws_series 60 "$((${#key} + 1))" 400; MT_HCPU[$key]="$WSS"
  done
  MT_HOST_PCT=48 MT_HOST_TOTAL_KB=12058624 MT_HOST_USED_KB=5892096 MT_HOST_LOAD=3.18 MT_HOST_HIST=""
  ws_series 40 5 100; MT_HOST_HIST="$WSS"
  HINTS=() HINT_SEEN=()
  DASH_ERRS=() DASH_ERRS_AT=()
}

# What `status` suggests for ix-lima and ix-piura, the files of ix-lima, the most recent version of an image and what the server lacks.
ws_todo_data() {
  st_hint_t "./deltactl deploy ix-lima s1" status.hint.stopped ix-lima s1
  st_hint_t "./deltactl init ix-piura" status.hint.no_data ix-piura
  DASH_WS_ENVPEND=([ix-lima]="s0 instance") DASH_WS_ENVMISS=([ix-lima]="s1: 2") DASH_WS_ENVMISSN=([ix-lima]=2)
  DASH_IMG_STATE=ready
  IC_N=2 IC_GROUPS=("s0|auth-backend")
  IC_TAG=(2.14.1 2.15.0) IC_ID=(aaaa bbbb) IC_EPOCH=(1700000000 1710000000) IC_KIND=(ver ver) IC_VNUM=(2.14.1 2.15.0) IC_VPRE=("" "") IC_OK=(1 1) IC_STAR=(0 1)
  IC_USE=("ix-lima(current) ix-colorado(current) " "")
  IC_ORDER=(["s0|auth-backend"]="1 0") IC_STARIDX=(["s0|auth-backend"]=1) IC_DISC=()
  DASH_SRV_STATE=ready DASH_SRV_BAD=1 DASH_SRV_BAD_NAMES="docker compose"
}

# The .env.instance of the first instance (what the Services tab reads), in a folder of its own so the scene never depends on instances/.
ws_svc_files() {
  INSTANCES_DIR="$(mktemp -d)"
  mkdir -p "$INSTANCES_DIR/ix-colorado" "$INSTANCES_DIR/ix-lima"
  printf 'COMPOSE_PROFILES=s0,s1\nS0_TAG=2.14.1\nS0_PORT=4100\nS1_TAG=2.9.0\nS1_PORT=4101\nS1_MEM_LIMIT=2g\n' > "$INSTANCES_DIR/ix-colorado/.env.instance"
  printf 'COMPOSE_PROFILES=s0\nS0_TAG=2.14.1\nS0_PORT=4110\n' > "$INSTANCES_DIR/ix-lima/.env.instance"
}

ws_scene() { # name
  local name="$1"
  tui_size
  dash_init
  DASH_HOST=testhost
  DASH_DOCKER_VER=27.0.0
  ws_fill
  DASH_VIEW=instances DASH_SEL=0 DASH_ON_NEW=0 DASH_FOCUS=list
  case "$name" in
    cards) ;;
    ok) ;;
    todo) ws_todo_data; DASH_SEL=1 ;;
    todofocus) ws_todo_data; DASH_SEL=1 DASH_FOCUS=todo DASH_TODO_SEL=1 ;;
    stopped) DASH_SEL=3 ;;
    logs)
      DASH_SEL=0 DASH_WS_TAB=logs DASH_FOCUS=logs
      DASH_LOGS=([ix-colorado/s0]="$(printf 'linea %s ok\n' 1 2 3 4 5 6 7 8; echo 'ERROR de prueba'; echo 'linea final ok')")
      DASH_LOGS_AT=([ix-colorado/s0]=1)
      ;;
    none) DASH_NAMES=() DASH_SVCS=() DASH_ON_NEW=1 ;;
    filter) DASH_LIST_FILTER="ix-s" DASH_SEL=3 ;;
    sort) DASH_LIST_SORT=state DASH_SEL=1 ;;
    new) DASH_ON_NEW=1 ;;
    acceso) ws_acceso_data ejemplo.pe nginx 1 ;;
    accesocaddy) ws_acceso_data ejemplo.pe caddy 1 ;;
    accesonodom) ws_acceso_data "" nginx 1 ;;
    accesoedit) ws_acceso_data ejemplo.pe nginx 1; DASH_MODE=accdom DASH_BUF="otro.example.org" DASH_CUR=16 ;;
    accesobad) ws_acceso_data ejemplo.pe nginx 0; DASH_ACC_PORT=([ix-colorado/s0]=4100) DASH_ACC_REACH=([ix-colorado/s0]=up) ;;
    historial) ws_historial_data ;;
    historialsel) ws_historial_data; dash_his_select 2 ;;
    historialempty) ws_historial_data ix-piura; DASH_SEL=2 ;;
    servicios | askremove | asktag | askport) ws_svc_files; DASH_SEL=0 DASH_WS_TAB=servicios DASH_FOCUS=tab DASH_WSV_NAME=ix-colorado DASH_WSV_SEL=1 ;;
    serviciosoff) ws_svc_files; DASH_SEL=1 DASH_SVCS[ix-lima]="s0" DASH_WS_TAB=servicios DASH_FOCUS=tab DASH_WSV_NAME=ix-lima DASH_WSV_SEL=1 ;;
    *) echo "unknown scene $name" >&2; return 1 ;;
  esac
  case "$name" in
    askremove) DASH_MODE=svcask DASH_SA_KIND=remove DASH_SA_INST=ix-colorado DASH_SA_SVC=s1 DASH_BUF="s" DASH_CUR=1 ;;
    asktag) DASH_MODE=svcask DASH_SA_KIND=tag DASH_SA_INST=ix-colorado DASH_SA_SVC=s1 DASH_SA_CUR=2.9.0 DASH_SA_STAR=2.15.0 DASH_SA_TAGS="2.15.0* 2.14.1 2.9.0" DASH_BUF="2.10" DASH_CUR=4 ;;
    askport) DASH_MODE=svcask DASH_SA_KIND=port DASH_SA_INST=ix-colorado DASH_SA_SVC=s1 DASH_SA_CUR=4101 DASH_BUF="80" DASH_CUR=2 ;;
  esac
  dash_host_build
  dash_render
  [ -z "${WS_TMP:-}" ] || rm -rf "$WS_TMP"
}

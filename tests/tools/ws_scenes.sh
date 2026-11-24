#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_*, DSV_*, MT_*, IC_* and ST_* tables are read by the panel that draws them
# Scenes of the Instances view (the list and the workspace of the instance) with fixed data: each one fills the tables the view reads with
# deterministic values (four instances in four states, their services, the figures and histories of the running ones, what `status` suggests,
# what the files of the instance and the catalog of images say) and draws the whole panel frame at the size of the environment (COLUMNS,
# DELTACTL_TUI_ROWS). They are the golden snapshots of tests/test-workspace.sh (tests/golden/workspace/) and the source of the PNG captures.
# Sourced, never executed: it needs lib/bootstrap.sh and lib/cmd/dashboard.sh already loaded and the environment of the panel
# (DELTACTL_UI=rich, DELTACTL_TUI_KEYS=...).
#
#   ws_scene <name>      name: cards | todo | todofocus | ok | stopped | logs | none | filter | sort | new

WS_SCENES=(cards todo todofocus ok stopped logs none filter sort new)

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
    *) echo "unknown scene $name" >&2; return 1 ;;
  esac
  dash_host_build
  dash_render
}

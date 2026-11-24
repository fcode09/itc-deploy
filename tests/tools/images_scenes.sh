#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the IC_*, KF_* and DASH_* tables are read by the panel that draws them
# Scenes of the Images view with fixed data: each one reads the catalog from the simulated docker of the test that calls it (tests/fake-docker.sh
# with fixed images and dates, see tests/test-imgview.sh), fixes the clock (IC_NOW) so "2 days ago" is always the same, and draws the whole panel
# frame at the size of the environment (COLUMNS, DELTACTL_TUI_ROWS). They are the golden snapshots of tests/test-imgview.sh
# (tests/golden/images/) and the source of the PNG captures. Sourced, never executed: it needs lib/bootstrap.sh and lib/cmd/dashboard.sh already
# loaded, the simulated docker first in the PATH, and the environment of the panel (DELTACTL_UI=rich, DELTACTL_TUI_KEYS=...).
#
#   images_scene <name>     name: ok | detail | foreign | star2 | empty | nodocker | loading | load | use | confirm

IMAGES_SCENES=(ok detail foreign star2 empty nodocker loading load use confirm)
IMAGES_NOW=1795521600   # 2026-11-24 12:00:00 UTC

# What the simulated docker has: two images of s0 with several versions (one for another architecture, one that is `latest`) and one of s1.
images_fixture() { # dir
  local d="$1"
  printf '%s\n' "auth-backend:2.14.1|sha256:a1aaaaaaaaaaaa|amd64" "auth-backend:2.14.0|sha256:a2aaaaaaaaaaaa|amd64" "auth-backend:2.13.2|sha256:a3aaaaaaaaaaaa|amd64" \
    "auth-backend:3.0.0-rc1|sha256:a4aaaaaaaaaaaa|arm64" "auth-backend:latest|sha256:a5aaaaaaaaaaaa|amd64" "gueo-back-end:2.9.0|sha256:g1aaaaaaaaaaaa|amd64" > "$d/images.txt"
  printf '%s\n' "auth-backend:2.14.1|2026-11-22 12:00:00 +0000 UTC" "auth-backend:2.14.0|2026-11-15 12:00:00 +0000 UTC" "auth-backend:2.13.2|2026-10-10 12:00:00 +0000 UTC" \
    "auth-backend:3.0.0-rc1|2026-11-24 11:00:00 +0000 UTC" "auth-backend:latest|2026-11-19 12:00:00 +0000 UTC" "gueo-back-end:2.9.0|2026-11-19 12:00:00 +0000 UTC" > "$d/image_dates.txt"
}

images_scene() { # name
  local name="$1"
  tui_size
  dash_init
  DASH_HOST=testhost
  DASH_DOCKER_VER=27.0.0
  MT_HOST_PCT=48 MT_HOST_TOTAL_KB=12058624 MT_HOST_USED_KB=5892096 MT_HOST_LOAD=3.18 MT_HOST_HIST=""
  IC_NOW="$IMAGES_NOW"
  DASH_NAMES=(ix-colorado ix-lima)
  DASH_SVCS=([ix-colorado]="s0 s1" [ix-lima]="s0 s1")
  case "$name" in
    nodocker) DASH_IMG_STATE=nodocker IC_N=0 IC_GROUPS=() ;;
    loading) DASH_IMG_STATE=loading DASH_IMG_BUSY=1 ;;
    *) dash_img_apply "$(dash_img_dump)" ;;
  esac
  DASH_VIEW=images
  case "$name" in
    ok | nodocker | loading | empty) ;;
    detail) DASH_IMG_OPEN=1 ;;
    foreign) DASH_IMG_SEL=0 ;;                       # the arm64 image of s0: it cannot be used, and says why
    star2) DASH_IMG_SEL=$((${#DASH_IMG_ITEMS[@]} - 1)) ;;   # the star of the second image
    load) DASH_IMG_LOADING="app.tar" ;;
    use) DASH_IMG_SEL=1; dash_img_use ;;
    confirm) DASH_IMG_SEL=1; dash_img_use; DASH_IU_STEP=confirm ;;
    *) echo "unknown scene $name" >&2; return 1 ;;
  esac
  dash_render
}

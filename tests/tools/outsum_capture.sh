#!/usr/bin/env bash
# Captures the output of the commands the Output view summarises (new, check, deploy, init, doctor, images, env), in Spanish and in English, from a
# simulated server (tests/tools/sim_env.sh: a copy of the repository, the fake docker, three instances), as the panel's jobs get it (the rich
# UI, no colour), and writes them to tests/golden/outsum/in/<scene>-<lang>.txt with what changes from one machine to another fixed (the folder
# of the repository, the free disk, the memory). They are the INPUT of tests/test-outsum.sh: the golden frames are the Output view drawn over them.
# Run it by hand only when a command changes what it prints:   bash tests/tools/outsum_capture.sh
# It never touches a real Docker or a real instance.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$HERE" || exit 1
# shellcheck source=tests/tools/sim_env.sh
source tests/tools/sim_env.sh
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
sim_build "$TMP/sim" 3
OUT="$HERE/tests/golden/outsum/in"
mkdir -p "$OUT"

# The images of the three instances (1.0 of each service) and one newer of s0 that nobody uses.
printf 'backend-s0:1.0|sha256:aaa111|amd64\nbackend-s1:1.0|sha256:bbb222|amd64\nbackend-s0:1.1|sha256:aaa112|amd64\n' > "$SIM_FIX/images.txt"

norm() { # stdin -> stdout: the machine-dependent parts fixed
  sed -e "s#$SIM_REPO#/srv/deltactl#g" \
    -e 's/Disco libre en \(.*\): [0-9.]* GB/Disco libre en \1: 5.1 GB/' -e 's/Free disk in \(.*\): [0-9.]* GB/Free disk in \1: 5.1 GB/' \
    -e 's/Memoria: [0-9]* MB en total, [0-9]* MB disponibles/Memoria: 8192 MB en total, 3072 MB disponibles/' \
    -e 's/Memory: [0-9]* MB in total, [0-9]* MB available/Memory: 8192 MB in total, 3072 MB available/' \
    -e 's/suman [0-9]* MB/suman 10240 MB/' -e 's/add up to [0-9]* MB/add up to 10240 MB/' \
    -e 's/(pacman): sudo pacman -S --needed /(apt): sudo apt-get install -y /'
}

cap() { # scene lang args...
  local scene="$1" lang="$2"
  shift 2
  (
    cd "$SIM_REPO" || exit 1
    DELTACTL_LANG="$lang" DELTACTL_UI=rich DELTACTL_COLOR=never LANG=C.UTF-8 COLUMNS=100 bash ./deltactl "$@" 2>&1 | norm > "$OUT/$scene-$lang.txt"
  )
}

for lang in es en; do
  cap check-ok "$lang" check sim-01
  cap deploy "$lang" deploy sim-01
  cap init "$lang" init sim-01
  cap images "$lang" images
  cap env "$lang" env sim-01 list
  cap doctor "$lang" doctor
  cap new "$lang" new colorado
  rm -rf "$SIM_REPO/instances/colorado"   # (the next language creates it again)
done
# check with problems: the images of the instance are not loaded
: > "$SIM_FIX/images.txt"
for lang in es en; do
  cap check-fail "$lang" check sim-01
  cap deploy-fail "$lang" deploy sim-01
done
wc -l "$OUT"/*.txt | tail -1

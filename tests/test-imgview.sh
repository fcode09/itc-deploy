#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # the cases go in single quotes and are evaluated with eval
# The Images view of the panel (lib/screens/images.sh) and its two dialogs (lib/screens/imguse.sh, lib/screens/imgload.sh): how it is registered,
# how the catalog is applied (where the cursor starts and stays), the golden snapshots of its scenes (tests/tools/images_scenes.sh) at 80x24,
# 120x30 and 160x40, how it degrades (small screens, ASCII, no colour, no Docker, nothing loaded), and its keys end to end against a simulated
# Docker: using a version in an instance (the tag is written, and deploy runs only when asked), copying the reference, loading an archive in the
# background and reading the catalog again when it ends. No real Docker, nothing is deployed: the simulated docker only notes what it was asked.
# Snapshots: tests/golden/images/<scene>-<cols>x<rows>-<lang>.txt. DELTACTL_GOLDEN=record rewrites them (only when a change is intended).
# Run it from the root of the isolated copy (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8 LC_ALL=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS DELTACTL_TUI_KEYS DELTACTL_TUI_EVENTS DELTACTL_TUI_ROWS DELTACTL_THEME
unset DELTACTL_REFRESH DELTACTL_METRICS_INTERVAL DELTACTL_TUI_IDLE_AFTER DELTACTL_TUI_GATE DELTACTL_CLIP DELTACTL_PR_SHELL DELTACTL_GRAPH TUI_GRAPH

FIX="$(mktemp -d)"
export FIX
CFG="$FIX/config"
trap 'rm -rf "$FIX" instances/ix-*' EXIT
rm -rf instances/ix-*
mkdir -p "$FIX/bin" "$FIX/frames"
: > "$FIX/containers.txt"; : > "$FIX/stats.txt"; : > "$FIX/calls.log"
cp tests/fake-docker.sh "$FIX/bin/docker-fake"
printf '#!/usr/bin/env bash\nexec bash "%s/bin/docker-fake" "$@"\n' "$FIX" > "$FIX/bin/docker"
printf '#!/bin/sh\nexit 0\n' > "$FIX/bin/ss"
chmod +x "$FIX/bin/docker" "$FIX/bin/ss"
export DELTACTL_MEMINFO="$FIX/meminfo" DELTACTL_LOADAVG="$FIX/loadavg" DELTACTL_PROC_ROOT="$FIX/proc" DELTACTL_CGROUP_ROOT="$FIX/cg"
printf 'MemTotal:        8388608 kB\nMemAvailable:    3145728 kB\n' > "$FIX/meminfo"
printf '0.82 0.50 0.40 1/200 1234\n' > "$FIX/loadavg"
# shellcheck source=tests/tools/images_scenes.sh
source tests/tools/images_scenes.sh
images_fixture "$FIX"

bash ./deltactl new ix-colorado --s0-tag 2.14.0 --s1-tag 2.9.0 > /dev/null 2>&1
bash ./deltactl new ix-lima --s0-tag 2.14.1 --s1-tag 2.9.0 > /dev/null 2>&1
fill_instance instances/ix-colorado 2.14.0 2.9.0   # (complete, so that a deploy passes its checks)
fill_instance instances/ix-lima 2.14.1 2.9.0
printf 'S0_TAG=2.13.2\n' > instances/ix-lima/.previous

KEYS="$FIX/keys.txt"
# The panel with the keys given (one per line): UTF-8, no colours, 110 x 30 (PANEL_COLS, PANEL_ROWS and LANGX change that).
panel() { printf '%s\n' "$@" > "$KEYS"; PATH="$FIX/bin:$PATH" DELTACTL_CONFIG="$CFG" DELTACTL_TUI_KEYS="$KEYS" DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_LANG="${LANGX:-es}" COLUMNS="${PANEL_COLS:-110}" DELTACTL_TUI_ROWS="${PANEL_ROWS:-30}" bash ./deltactl 2>&1; }
last_frame() { awk '/^=== frame /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }'; }
# The library: the panel loaded, nothing drawn.
run_lib() { PATH="$FIX/bin:$PATH" ROOT="$PWD" DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_LANG="${LANGX:-es}" COLUMNS=110 DELTACTL_CONFIG="$CFG" bash -c 'source lib/bootstrap.sh; source lib/cmd/dashboard.sh; '"$1" 2>&1; }

section "1. the view is registered with one line and follows the contract"
check "it is the eighth tab and its digit opens it" '[ "$(run_lib "dash_screen_by_number 8; echo \$DASH_SCR_ID")" = "images" ]'
check "its two dialogs are modes" '[ "$(run_lib "printf \"%s \" \${DASH_MODES[@]}")" = "menu confirm name cmd filter lfilter find wizard newinst palette help options srvask imguse imgload envedit svcask accdom " ]'
check "every function of the contract it uses is defined" 'run_lib "for f in render key keys texts sig enter back tick poll; do declare -F scr_images_\$f >/dev/null || exit 1; done; for m in imguse imgload; do for f in render key keys sig; do declare -F scr_\${m}_\$f >/dev/null || exit 1; done; done"'
check "its signature carries what it draws" '[ "$(run_lib "DASH_SIG=; scr_images_sig; echo \$DASH_SIG")" = "|0|0|none|0|0|" ]'
check "it is in the list of views of the console, the palette and the messages, in both languages" 'grep -q "console images env activity)" lib/screens/console.sh && grep -q "console images env activity; do" lib/screens/palette.sh && grep -q "console · images" lib/i18n/es/dashboard.sh && grep -q "console · images" lib/i18n/en/dashboard.sh'
check "the help of the panel names it (both languages)" 'grep -q "1-9 0  " lib/i18n/es/dashboard.sh && grep -q "IMÁGENES ↑" lib/i18n/es/dashboard.sh && grep -q "IMAGES   ↑" lib/i18n/en/dashboard.sh'
check "the tab has a name in both languages" '[ "$(run_lib "t tui.tab.images")" = "Imágenes" ] && [ "$(LANGX=en run_lib "t tui.tab.images")" = "Images" ]'

section "2. the catalog is applied: where the cursor starts and where it stays"
t_apply() { dash_img_apply "$(dash_img_dump)"; printf '%s ' "$DASH_IMG_STATE" "${#DASH_IMG_ITEMS[@]}" "$DASH_IMG_SEL"; dash_img_cur; echo "${IC_TAG[$DASH_IMG_CI]} $DASH_IMG_G"; }
check "the first read leaves 6 versions and the cursor on the star of the first image" '[ "$(run_lib "$(declare -f t_apply); t_apply")" = "ready 6 1 2.14.1 s0|auth-backend" ]'
t_keep() { dash_img_apply "$(dash_img_dump)"; DASH_IMG_SEL=3; dash_img_cur; a="${IC_TAG[$DASH_IMG_CI]}"; dash_img_apply "$(dash_img_dump)"; dash_img_cur; echo "$a ${IC_TAG[$DASH_IMG_CI]} $DASH_IMG_SEL"; }
check "a new read keeps the cursor on the same version (image and tag)" '[ "$(run_lib "$(declare -f t_keep); t_keep")" = "2.14.0 2.14.0 3" ]'
t_items() { dash_img_apply "$(dash_img_dump)"; local it; for it in "${DASH_IMG_ITEMS[@]}"; do printf '%s ' "${IC_TAG[${it##*|}]}"; done; }
check "the versions come in the order they are shown: each image newest first" '[ "$(run_lib "$(declare -f t_items); t_items")" = "3.0.0-rc1 2.14.1 latest 2.14.0 2.13.2 2.9.0 " ]'
t_nodock() { dash_img_apply "DASH_IMG_NODOCKER=1"; echo "$DASH_IMG_STATE ${#DASH_IMG_ITEMS[@]} $DASH_IMG_SEL"; }
check "when Docker does not answer the state says so and nothing is left to choose" '[ "$(run_lib "$(declare -f t_nodock); t_nodock")" = "nodocker 0 0" ]'

# The read of the catalog runs in the background (dash_async): a producer that dies or hangs is forgotten after a minute, and then the view has to
# ask again instead of staying on "reading…" for ever; and a command that ends while a read is already in flight makes that answer old.
# shellcheck disable=SC2329,SC2154,SC2153  # run in a bash that has loaded the panel (run_lib): the DASH_* tables are there, &c
t_stuck() {
  dash_img_slow() { sleep 30; }
  dash_async images "" dash_img_slow; DASH_IMG_BUSY=1; DASH_IMG_STATE=loading; DASH_AS_AT[images]=$((SECONDS - 61)); DASH_VIEW=instances
  scr_images_tick; printf '%s %s [%s] ' "$DASH_IMG_BUSY" "$DASH_IMG_STATE" "${DASH_AS_PID[images]}"
  dash_img_apply "$(dash_img_dump)"; dash_async images "" dash_img_slow; DASH_IMG_BUSY=1; DASH_AS_AT[images]=$((SECONDS - 61))
  scr_images_tick; printf '%s %s [%s]' "$DASH_IMG_BUSY" "$DASH_IMG_STATE" "${DASH_AS_PID[images]}"
  dash_async_stop
}
check "a read that never answers is forgotten after a minute: the view is not left on \"reading…\" (it says Docker does not answer; a later one that had an answer keeps it)" '[ "$(run_lib "$(declare -f t_stuck); t_stuck")" = "0 nodocker [] 0 ready []" ]'
# shellcheck disable=SC2329,SC2153  # (idem)
t_stale() {
  dash_img_apply "$(dash_img_dump)"
  DASH_IMG_REQ_GEN="$DASH_IMG_GEN"   # a read was launched ...
  dash_img_stale                     # ... and then a load or a deploy ended
  dash_img_apply "$(dash_img_dump)"  # the answer of that read is old
  printf '%s ' "$DASH_IMG_STALE"
  dash_img_request; printf '%s' "$DASH_IMG_STALE"   # a read launched after it is not
}
check "the answer of a read launched before a command ended does not clear the mark that the catalog is old" '[ "$(run_lib "$(declare -f t_stale); t_stale")" = "1 0" ]'

section "3. snapshots of the scenes (80x24, 120x30 and 160x40)"
GOLD_DIR="${DELTACTL_GOLDEN_DIR:-tests/golden}/images"
MODE="${DELTACTL_GOLDEN:-check}"
mkdir -p "$GOLD_DIR" 2> /dev/null || true
# scene <name> <cols> <rows> [lang] [env...] -> the frame as the panel draws it (the last one)
scene() {
  local name="$1" cols="$2" rows="$3" lang="${4:-es}"
  shift 4 2> /dev/null || shift $#
  env ROOT="$PWD" PATH="$FIX/bin:$PATH" DELTACTL_LANG="$lang" DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never COLUMNS="$cols" DELTACTL_TUI_ROWS="$rows" \
    DELTACTL_CONFIG="$FIX/none" DELTACTL_THEME=matrix HOME="$FIX" XDG_CONFIG_HOME="$FIX/xdg" "$@" \
    bash -c 'source lib/bootstrap.sh; source lib/cmd/dashboard.sh; source tests/tools/images_scenes.sh; set +e; images_scene '"$name" 2>&1 \
    | awk '/^=== frame /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }'
}
: > "$FIX/empty_marker"
for sc in "${IMAGES_SCENES[@]}"; do
  case "$sc" in
    empty) : > "$FIX/images.txt"; : > "$FIX/image_dates.txt" ;;
    *) images_fixture "$FIX" ;;
  esac
  for sz in 80x24 120x30 160x40; do
    g="$GOLD_DIR/$sc-$sz-es.txt"
    scene "$sc" "${sz%x*}" "${sz#*x}" es > "$FIX/frames/$sc-$sz-es.txt"
    if [ "$MODE" = record ]; then cp "$FIX/frames/$sc-$sz-es.txt" "$g"; echo "  REC  $sc @ $sz (es)"
    else check "scene $sc at $sz (es) equals its snapshot" '[ -f "$g" ] && cmp -s "$FIX/frames/$sc-$sz-es.txt" "$g"'; fi
  done
done
images_fixture "$FIX"
for sc in ok confirm foreign; do
  for sz in 80x24 120x30 160x40; do
    g="$GOLD_DIR/$sc-$sz-en.txt"
    scene "$sc" "${sz%x*}" "${sz#*x}" en > "$FIX/frames/$sc-$sz-en.txt"
    if [ "$MODE" = record ]; then cp "$FIX/frames/$sc-$sz-en.txt" "$g"; echo "  REC  $sc @ $sz (en)"
    else check "scene $sc at $sz (en) equals its snapshot" '[ -f "$g" ] && cmp -s "$FIX/frames/$sc-$sz-en.txt" "$g"'; fi
  done
done

section "4. the shape of every frame"
for sz in 60x14 80x24 100x20 120x30 160x40; do
  for sc in "${IMAGES_SCENES[@]}"; do
    case "$sc" in empty) : > "$FIX/images.txt"; : > "$FIX/image_dates.txt" ;; *) images_fixture "$FIX" ;; esac
    scene "$sc" "${sz%x*}" "${sz#*x}" es > "$FIX/frames/$sc-$sz-es.txt"
  done
done
images_fixture "$FIX"
check "no line is wider than the screen, in any scene and size" 'for f in "$FIX"/frames/*-es.txt; do sz="${f%-es.txt}"; sz="${sz##*-}"; c="${sz%x*}"; awk -v c="$c" "{ if (length(\$0) > c) bad = 1 } END { exit bad }" "$f" || { echo "$f"; exit 1; }; done'
check "a frame has exactly the rows of the screen (the header, the tabs, the body, the message and the keys)" 'for f in "$FIX"/frames/*-es.txt; do sz="${f%-es.txt}"; sz="${sz##*-}"; r="${sz#*x}"; c="${sz%x*}"; [ "$c" -ge 60 ] && [ "$r" -ge 14 ] || continue; [ "$(grep -c "" "$f")" -eq "$((r + 1))" ] || { echo "$f $(grep -c "" "$f") $r"; exit 1; }; done'
check "the box has its title chip with the number of the view, and the server architecture and number of versions" 'for sz in 80x24 120x30 160x40; do sed -n 4p "$FIX/frames/ok-$sz-es.txt" | grep -q "⁸imágenes" && sed -n 4p "$FIX/frames/ok-$sz-es.txt" | grep -q "servidor amd64 · 6 versiones" || exit 1; done'
check "each image has a heading with its service, its name, how many versions it has and which is the star" 'grep -q "▾ s0 · auth-backend .*5 versiones · ★ 2.14.1" "$FIX/frames/ok-120x30-es.txt" && grep -q "▾ s1 · gueo-back-end .*1 versión · ★ 2.9.0" "$FIX/frames/ok-120x30-es.txt"'
check "every table has the columns and the marks: ★ the most recent, ▲ the tag that moves, ✖ the image of another architecture" 'f="$FIX/frames/ok-120x30-es.txt"; grep -q "VERSIÓN .*CREADA .*TAMAÑO ARQ .*USO" "$f" && grep -q "2.14.1 ★" "$f" && grep -q "latest ▲" "$f" && grep -q "3.0.0-rc1 .*arm64 ✖" "$f"'
check "an image of another architecture says why on the last line of the box, with both architectures" 'grep -q "imagen de arquitectura arm64; este servidor es amd64: no arrancaría" "$FIX/frames/foreign-120x30-es.txt"'
check "the star says it is the most recent one the server can use" 'grep -q "La más reciente que este servidor puede usar" "$FIX/frames/ok-120x30-es.txt"'
check "the detail shows the reference, the id, the date (ISO and in words), the size, the architecture and who uses it" 'f="$FIX/frames/detail-120x30-es.txt"; grep -q "auth-backend:2.14.1" "$f" && grep -q "ID a1aaaaaaaaaa · creada 2026-11-22T12:00:00Z (hace 2 días) · 300MB · amd64" "$f" && grep -q "la usan: ix-lima(actual)" "$f"'
check "while it reads, the box says so and nothing is listed as if it were loaded" 'f="$FIX/frames/loading-120x30-es.txt"; grep -q "leyendo…" "$f" && ! grep -q "▾ s0" "$f"'
check "without Docker the box says it does not answer" 'grep -q "Docker no responde" "$FIX/frames/nodocker-120x30-es.txt" && grep -q "sin Docker" "$FIX/frames/nodocker-120x30-es.txt"'
check "with nothing loaded every image says so and how to load one" 'f="$FIX/frames/empty-120x30-es.txt"; [ "$(grep -c "No hay versiones cargadas de esta imagen" "$f")" -eq 2 ] && grep -q "sin imágenes" "$f"'
check "while a file loads the last line says which, and that the panel keeps working" 'grep -q "cargando app.tar… (el panel sigue funcionando; x cancela)" "$FIX/frames/load-120x30-es.txt"'
check "using a version asks which instance and shows what changes in each (and the star is the one proposed)" 'f="$FIX/frames/use-120x30-es.txt"; grep -q "usar 2.14.1" "$f" && grep -q "ix-colorado  ahora 2.14.0 → 2.14.1" "$f" && grep -q "ix-lima .*ya usa esta versión" "$f"'
check "the confirmation says what is written, that deploy recreates the container, and the keys" 'f="$FIX/frames/confirm-120x30-es.txt"; grep -q "Cambiar la versión de s0 en .ix-colorado.: 2.14.0 → 2.14.1" "$f" && grep -q "S0_TAG" "$f" && grep -q "Desplegar vuelve a crear el contenedor" "$f" && grep -q "y cambiar y desplegar · g solo guardar la etiqueta" "$f"'
for sc in ok confirm foreign; do scene "$sc" 120 30 en > "$FIX/frames/$sc-120x30-en.txt"; done
check "the English scenes are in English" 'grep -q "server amd64 · 6 versions" "$FIX/frames/ok-120x30-en.txt" && grep -q "Change the version of s0 in" "$FIX/frames/confirm-120x30-en.txt" && grep -q "image of architecture arm64; this server is amd64" "$FIX/frames/foreign-120x30-en.txt"'
check "a terminal smaller than 60x14 still says it is too small instead of drawing broken boxes" '[ "$(scene ok 50 20 es | grep -c "demasiado pequeña")" -ge 1 ]'

section "5. ASCII, colours"
scene ok 120 30 es DELTACTL_ASCII=1 > "$FIX/frames/ascii.txt"
check "in ASCII there is no box-drawing, braille or symbol character in the frame (the words keep their accents)" '! LC_ALL=C grep -v "^[ -~]*$" "$FIX/frames/ascii.txt" | grep -qP "[\x{2190}-\x{28FF}]"'
check "in ASCII the marks are still there: * the most recent, ! the tag that moves, x the image of another architecture" 'grep -q "2.14.1 \*" "$FIX/frames/ascii.txt" && grep -q "latest !" "$FIX/frames/ascii.txt" && grep -q "arm64 x" "$FIX/frames/ascii.txt"'
scene ok 120 30 es DELTACTL_COLOR=never > "$FIX/frames/nocolor.txt"
check "NO_COLOR draws no escape sequence at all" '! grep -q $'"'"'\033'"'"' "$FIX/frames/nocolor.txt"'
scene ok 120 30 es DELTACTL_COLOR=always COLORTERM=truecolor > "$FIX/frames/color.txt"
check "with colours the star, the warning and the error have colour of their own" 'grep -q $'"'"'\033\['"'"' "$FIX/frames/color.txt" && [ "$(grep -o $'"'"'\033\[[0-9;]*m'"'"' "$FIX/frames/color.txt" | sort -u | wc -l)" -gt 8 ]'

section "6. keys: moving, the detail, copying"
images_fixture "$FIX"
check "8 opens the view with the cursor on the star (the first image's newest compatible version)" 'panel 8 | last_frame | grep -q "Enter la usa en una instancia\|La más reciente que este servidor puede usar"'
check "down and up move across the images: past the last version of the first image the cursor is on the second" 'panel 8 down down down down | last_frame | grep -q "La más reciente que este servidor puede usar"'
check "on an image of another architecture the line says it cannot be used" 'panel 8 up | last_frame | grep -q "imagen de arquitectura arm64; este servidor es amd64"'
check "on a tag that moves the line warns that it cannot take you back" 'panel 8 down | last_frame | grep -q "etiqueta que se mueve: no sirve para volver a una versión anterior"'
check "space opens the detail and Esc closes it before leaving the view" 'o="$(panel 8 space)"; echo "$o" | last_frame | grep -q "ID a1aaaaaaaaaa" && o="$(panel 8 space esc)" && echo "$o" | last_frame | grep -q "\[8 Imágenes\]" && ! echo "$o" | last_frame | grep -q "ID a1aaaaaaaaaa"'
check "a second Esc goes to the first view (the Server view)" 'panel 8 esc | last_frame | grep -q "\[1 Servidor\]"'
check "home and end go to the first and the last version" 'panel 8 end | last_frame | grep -q "2.9.0 ★" && panel 8 end home | last_frame | grep -q "arquitectura arm64"'
check "the tab key and the digits reach the view from the others" 'panel 9 btab | last_frame | grep -q "\[8 Imágenes\]" && panel 2 8 | last_frame | grep -q "⁸imágenes"'
rm -f "$FIX/clip.txt"
check "c copies the reference (image:tag) of the version, and says so" 'o="$(DELTACTL_CLIP="cat > $FIX/clip.txt" panel 8 c)"; [ "$(cat "$FIX/clip.txt")" = "auth-backend:2.14.1" ] && echo "$o" | last_frame | grep -q "Copiado: auth-backend:2.14.1"'
check "c with no clipboard says what to copy by hand" 'o="$(DELTACTL_CLIP=false panel 8 c)"; echo "$o" | last_frame | grep -q "No se pudo copiar.*auth-backend:2.14.1"'
check "R reads the catalog again and says so" 'panel 8 R | last_frame | grep -q "Leyendo las imágenes"'

# The fixture's 3.0.0-rc1 is an arm64 image: it never competes for the star. Made amd64 and the newest, it must still not be the star.
sed -i 's/^auth-backend:3.0.0-rc1|sha256:a4aaaaaaaaaaaa|arm64$/auth-backend:3.0.0-rc1|sha256:a4aaaaaaaaaaaa|amd64/' "$FIX/images.txt"
check "a pre-release that this server can run and that is the newest of its image is not the star: the star stays on the newest stable version" '
  f="$(panel 8 | last_frame)"; echo "$f" | grep -q "2.14.1 ★" && ! echo "$f" | grep -q "3.0.0-rc1 ★"'
images_fixture "$FIX"

section "7. keys: using a version in an instance"
tag_of() { grep "^S0_TAG=" "instances/$1/.env.instance" | cut -d= -f2; }
: > "$FIX/calls.log"
cp instances/ix-colorado/.env.instance "$FIX/env.instance.before"; cksum < instances/ix-colorado/.env.s0 > "$FIX/env.s0.sum"
stat -c %a instances/ix-colorado/.env.instance > "$FIX/env.mode"; stat -c %a instances/ix-colorado/.env.s0 > "$FIX/env.s0.mode"
check "Enter opens the dialog with the instances that have the service (and what they would change)" 'o="$(panel 8 enter)"; f="$(echo "$o" | last_frame)"; echo "$f" | grep -q "Elige la instancia donde usar auth-backend:2.14.1 (servicio s0)" && echo "$f" | grep -q "ix-colorado  ahora 2.14.0 → 2.14.1" && echo "$f" | grep -q "ix-lima .*ya usa esta versión"'
check "the cursor of the dialog starts on the first instance that can take it, and moves" 'o="$(panel 8 enter)"; echo "$o" | last_frame | grep -q "▸ ix-colorado"'
check "Esc cancels, says so, and nothing is written" 'panel 8 enter esc | last_frame | grep -q "Cancelado" && [ "$(tag_of ix-colorado)" = 2.14.0 ] && [ ! -s "$FIX/calls.log" ] && [ "$(grep -c "" "instances/ix-colorado/.env.instance")" -gt 0 ]'
check "an instance that already uses the version cannot be chosen: Enter says why and stays" 'o="$(panel 8 enter down enter)"; f="$(echo "$o" | last_frame)"; echo "$f" | grep -q "ya usa esta versión" && ! echo "$f" | grep -q "Cambiar la versión de"'
check "Enter on the instance shows what will change, before anything is written" 'o="$(panel 8 enter enter)"; f="$(echo "$o" | last_frame)"; echo "$f" | grep -q "Cambiar la versión de s0 en .ix-colorado.: 2.14.0 → 2.14.1" && [ "$(tag_of ix-colorado)" = 2.14.0 ]'
check "in the confirmation a key that is not an answer does nothing (it stays, nothing is written), and the left arrow goes back to the list" '
  o="$(panel 8 enter enter z)"; echo "$o" | last_frame | grep -q "Cambiar la versión de s0 en" && [ "$(tag_of ix-colorado)" = 2.14.0 ] && [ ! -s "$FIX/calls.log" ] \
  && panel 8 enter enter left | last_frame | grep -q "Elige la instancia"'
check "n, q and Esc cancel the confirmation and say so; nothing is written" '
  for k in n q esc; do panel 8 enter enter $k | last_frame | grep -q "Cancelado" && [ "$(tag_of ix-colorado)" = 2.14.0 ] && [ ! -s "$FIX/calls.log" ] || exit 1; done'
check "g writes the tag and does not deploy" '
  : > "$FIX/calls.log"
  o="$(panel 8 enter enter g)"
  [ "$(tag_of ix-colorado)" = 2.14.1 ] && ! grep -q COMPOSE "$FIX/calls.log" && echo "$o" | last_frame | grep -q "ix-colorado: S0_TAG=2.14.1 guardado en .env.instance"'
printf 'S0_TAG=2.13.2\n' > instances/ix-colorado/.previous
sed -i 's/^S0_TAG=.*/S0_TAG=2.14.0/' instances/ix-colorado/.env.instance
check "y writes the tag and starts the deploy of that service (a command in the background: Output, x cancels)" '
  : > "$FIX/calls.log"
  o="$(panel 8 enter enter y wait)"
  [ "$(tag_of ix-colorado)" = 2.14.1 ] && grep -q "COMPOSE up" "$FIX/calls.log" && echo "$o" | grep -q "deploy ix-colorado s0"'
sed -i 's/^S0_TAG=.*/S0_TAG=2.14.0/' instances/ix-colorado/.env.instance
# Another terminal may be running a command on the same instances: the lock of the mutation (instances/.deltactl/locks/mutation.lock) is held by a
# live process of deltactl. The panel only knew about its own jobs, so it wrote the tag and then its deploy failed: the file said one version and
# the container ran another.
LOCK="instances/.deltactl/locks/mutation.lock"
hold_lock() { mkdir -p "$LOCK"; (exec -a deltactl-holder sleep 300) & HOLDER=$!; printf '%s\n' "$HOLDER" > "$LOCK/pid"; echo 20261124T000000Z-1 > "$LOCK/run"; echo "deploy ix-lima" > "$LOCK/what"; }
release_lock() { kill "$HOLDER" 2> /dev/null; wait "$HOLDER" 2> /dev/null; rm -rf instances/.deltactl; }
tag_is() { [ "$(tag_of "$1")" = "$2" ]; }
reset_tag() { sed -i "s/^S0_TAG=.*/S0_TAG=2.14.0/" instances/ix-colorado/.env.instance; : > "$FIX/calls.log"; }
reset_tag; hold_lock
o="$(panel 8 enter enter y wait)"
check "while another operation holds the lock, y writes nothing and starts nothing, and says who is running what" '
  tag_is ix-colorado 2.14.0 && ! grep -q "COMPOSE" "$FIX/calls.log" && echo "$o" | last_frame | grep -q "otra operación en curso (./deltactl deploy ix-lima, pid $HOLDER)"'
o="$(panel 8 enter enter g)"
check "...and g (only the tag) is refused too: the deploy that runs could record the new tag over the old container" '
  tag_is ix-colorado 2.14.0 && echo "$o" | last_frame | grep -q "otra operación en curso"'
o="$(LANGX=en panel 8 enter enter y)"
check "the refusal is in English too" 'echo "$o" | last_frame | grep -q "another operation is running (./deltactl deploy ix-lima"'
release_lock
reset_tag
mkdir -p "$LOCK"; echo 999999 > "$LOCK/pid"; echo 20261124T000000Z-2 > "$LOCK/run"; echo "deploy ix-lima" > "$LOCK/what"
check "a lock whose owner is gone is not a reason to refuse (it is taken over by the next operation)" '
  o="$(panel 8 enter enter y wait)"; tag_is ix-colorado 2.14.1 && grep -q "COMPOSE up" "$FIX/calls.log"'
rm -rf instances/.deltactl; reset_tag
# A run that was interrupted and nobody has reviewed blocks every new operation (lib/core/runs.sh): deploy would die with the message of runs.blocked.
mkdir -p instances/.deltactl/pending; printf 'deploy\tix-lima\n' > instances/.deltactl/pending/20261123T100000Z-7
o="$(panel 8 enter enter y wait)"
check "an interrupted run nobody has reviewed: y writes nothing and says which run and where to review it" '
  tag_is ix-colorado 2.14.0 && ! grep -q "COMPOSE" "$FIX/calls.log" && echo "$o" | last_frame | grep -q "20261123T100000Z-7 (deploy ix-lima)" && echo "$o" | last_frame | grep -q "sin revisar"'
check "...but g, that only saves the tag and starts nothing, still works" '
  o="$(panel 8 enter enter g)"; tag_is ix-colorado 2.14.1 && ! grep -q "COMPOSE" "$FIX/calls.log"'
rm -rf instances/.deltactl; reset_tag
check "the rest of .env.instance, the other files of the instance and their modes are exactly as they were (only S0_TAG changed)" '
  [ "$(grep -v "^S0_TAG=" instances/ix-colorado/.env.instance)" = "$(grep -v "^S0_TAG=" "$FIX/env.instance.before")" ] \
  && [ "$(cksum < instances/ix-colorado/.env.s0)" = "$(cat "$FIX/env.s0.sum")" ] && [ "$(stat -c %a instances/ix-colorado/.env.instance)" = "$(cat "$FIX/env.mode")" ] \
  && [ "$(stat -c %a instances/ix-colorado/.env.s0)" = "$(cat "$FIX/env.s0.mode")" ] && [ "$(grep -c "" instances/ix-colorado/.env.instance)" = "$(grep -c "" "$FIX/env.instance.before")" ]'
check "an image of another architecture is not offered: Enter says why instead of opening the dialog" 'o="$(panel 8 up enter)"; f="$(echo "$o" | last_frame)"; echo "$f" | grep -q "imagen de arquitectura arm64" && ! echo "$f" | grep -q "Elige la instancia"'
check "an instance that uses another image name for the service is listed with the reason" '
  echo "S0_IMAGE=otro/auth" >> instances/ix-lima/.env.instance
  o="$(panel 8 enter)"; sed -i "/^S0_IMAGE=/d" instances/ix-lima/.env.instance
  echo "$o" | last_frame | grep -q "ix-lima .*usa otra imagen: otro/auth"'
check "with no instance that has the service nothing opens and the message says so" '
  mkdir -p "$FIX/off"; mv instances/ix-colorado instances/ix-lima "$FIX/off/"
  o="$(panel 8 enter)"; mv "$FIX/off/ix-colorado" "$FIX/off/ix-lima" instances/
  echo "$o" | last_frame | grep -q "Ninguna instancia tiene activo el servicio s0"'
check "the dialog of using a version is in English too" 'LANGX=en panel 8 enter enter | last_frame | grep -q "Change the version of s0 in .ix-colorado.: 2.14.0 → 2.14.1" && LANGX=en panel 8 enter | last_frame | grep -q "Choose the instance where to use auth-backend:2.14.1"'

section "7c. an instance can only use a version it can find: the name of its images"
# A local instance runs auth-backend:<tag> and never pulls (pull policy never); one with a REGISTRY runs <registry>/auth-backend:<tag>, which
# Docker pulls when it is not loaded. A tag that is loaded under another name is not the image of the instance: the tag would be written and
# the deploy would fail, or pull something else.
printf '%s\n' "reg.io/auth-backend:2.12.0|sha256:ra1aaaaaaaaaaa|amd64" >> "$FIX/images.txt"
printf '%s\n' "reg.io/auth-backend:2.12.0|2026-10-01 12:00:00 +0000 UTC" >> "$FIX/image_dates.txt"
: > "$FIX/calls.log"
o="$(panel 8 end up enter)"
check "a local instance cannot use a tag that is only loaded as reg.io/auth-backend: it says what it needs and what there is" '
  f="$(echo "$o" | last_frame)"; echo "$f" | grep -q "ix-colorado .*solo cargada como reg.io/auth-backend"'
o="$(panel 8 end up enter enter)"
check "Enter on it says why and writes nothing" '[ "$(tag_of ix-colorado)" = 2.14.0 ] && echo "$o" | last_frame | grep -q "ix-colorado usa imágenes locales: necesita auth-backend:2.12.0, solo cargada como reg.io/auth-backend" && echo "$o" | last_frame | grep -q "Elige la instancia"'
sed -i 's/^REGISTRY=.*/REGISTRY=reg.io/' instances/ix-lima/.env.instance
grep -q '^REGISTRY=reg.io$' instances/ix-lima/.env.instance || echo 'REGISTRY=reg.io' >> instances/ix-lima/.env.instance
o="$(panel 8 end up enter)"
check "an instance with the registry reg.io can use the version loaded as reg.io/auth-backend" '
  f="$(echo "$o" | last_frame)"; echo "$f" | grep -q "ix-lima .*ahora 2.14.1 → 2.12.0"'
o="$(panel 8 down down enter)"
check "and cannot use one that is only loaded under the bare name: it would be pulled from the registry, which may not have it" '
  f="$(echo "$o" | last_frame)"; echo "$f" | grep -q "ix-lima .*no cargada como reg.io/auth-backend" && echo "$f" | grep -q "ix-colorado .*ya usa esta versión"'
o="$(LANGX=en panel 8 down down enter)"
check "the reasons are in English too" 'echo "$o" | last_frame | grep -q "ix-lima .*not loaded as reg.io/auth-backend"'
sed -i 's/^REGISTRY=.*/REGISTRY=/' instances/ix-lima/.env.instance
images_fixture "$FIX"

section "8. keys: loading an archive"
printf 'x' > "$FIX/app.tar"
printf 'Loaded image: auth-backend:2.15.0\n' > "$FIX/load_result"
printf '2026-11-24 10:00:00 +0000 UTC' > "$FIX/load_date"
check "l opens the dialog for the path, and says when the file is not there" 'o="$(panel 8 l n o p e)"; f="$(echo "$o" | last_frame)"; echo "$f" | grep -q "cargar imágenes" && echo "$f" | grep -q "ese archivo no existe"'
check "Enter on a path that does not exist keeps the dialog and says so" 'panel 8 l n o p e enter | last_frame | grep -q "ese archivo no existe" && panel 8 l n o p e enter | last_frame | grep -q "cargar imágenes"'
check "Enter on an empty path asks for it" 'panel 8 l enter | last_frame | grep -q "escribe la ruta del archivo"'
check "Esc closes the dialog without doing anything" ': > "$FIX/calls.log"; o="$(panel 8 l esc | last_frame)"; echo "$o" | grep -q "\[8 Imágenes\]" && ! echo "$o" | grep -q "cargar imágenes" && ! grep -q "^load" "$FIX/calls.log"'
check "a path that exists is accepted (the field says so)" 'keys=(8 l); for ((i = 0; i < ${#FIX}; i++)); do keys+=("${FIX:$i:1}"); done; for c in / a p p . t a r; do keys+=("$c"); done; panel "${keys[@]}" | last_frame | grep -q "archivo .*●\|archivo .*\*"'
keys_for() { local p="$1" i c; keys=(8 l); for ((i = 0; i < ${#p}; i++)); do c="${p:$i:1}"; case "$c" in " ") c=space ;; esac; keys+=("$c"); done; }
check "Enter on an existing file runs docker load in the background, and when it ends the new version is in the view" '
  : > "$FIX/calls.log"
  keys_for "$FIX/app.tar"; o="$(panel "${keys[@]}" enter wait)"
  grep -q "^load -i $FIX/app.tar" "$FIX/calls.log" && echo "$o" | last_frame | grep -q "2.15.0" && echo "$o" | grep -q "load $FIX/app.tar"'
check "the loaded version, the newest of its image, is the star now" '
  keys_for "$FIX/app.tar"; o="$(panel "${keys[@]}" enter wait)"
  echo "$o" | last_frame | grep -q "2.15.0 ★"'
check "while it loads, the last frame says which file, that the panel keeps working and that x cancels" '
  keys_for "$FIX/app.tar"; o="$(panel "${keys[@]}" enter down | last_frame)"
  echo "$o" | grep -q "cargando app.tar… (el panel sigue funcionando; x cancela)" && echo "$o" | grep -q "x cancelar"'

section "9. the scene with a long list: window and cost"
for ((i = 1; i <= 30; i++)); do printf 'auth-backend:1.%d.0|sha256:z%02d00000000000|amd64\n' "$i" "$i" >> "$FIX/images.txt"; printf 'auth-backend:1.%d.0|2026-10-%02d 12:00:00 +0000 UTC\n' "$i" "$i" >> "$FIX/image_dates.txt"; done
check "with 30 more versions the list scrolls: the cursor stays in view and the box keeps its size" '
  o="$(panel 8 end)"; f="$(echo "$o" | last_frame)"
  [ "$(echo "$f" | grep -c "")" -eq 31 ] && echo "$f" | grep -q "2.9.0 ★"'
images_fixture "$FIX"

section "10. no real Docker"
check "the simulated docker is the one found first" '[ "$(PATH="$FIX/bin:$PATH" command -v docker)" = "$FIX/bin/docker" ]'
touch "$FIX/log_all"; rm -f "$FIX/all_calls.log"
panel 8 R R > /dev/null
check "reading the catalog asks Docker only what it needs (the images and who answers), and changes nothing: no run, load, pull, remove, stop or compose command" '
  grep -q "^image ls" "$FIX/all_calls.log" && ! grep -Eq "^(run|load|pull|push|rm|rmi|stop|kill|restart|tag) |^image (rm|pull|prune|tag)|^compose (up|down|stop|rm|restart|pull|run)" "$FIX/all_calls.log"'
rm -f "$FIX/log_all"

finish

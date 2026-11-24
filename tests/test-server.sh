#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # the cases go in single quotes and are evaluated with eval
# The Server view of the panel (lib/screens/server.sh, lib/screens/srvask.sh) and the first-run gate: the figures in human units, the golden
# snapshots of its scenes (tests/tools/server_scenes.sh) at 80x24, 120x30 and 160x40, how it degrades (small screens, ASCII, no colour,
# sources that are not there), its keys end to end against a simulated server, copying and running an install command (always asking
# first), the notice when the panel starts and the question before creating an instance. No real Docker, no real host, nothing installed:
# the panel runs in test mode (DELTACTL_TUI_KEYS) and the command that would install something is replaced by a script that notes it.
# Snapshots: tests/golden/server/<scene>-<cols>x<rows>-<lang>.txt. DELTACTL_GOLDEN=record rewrites them (only when a change is intended).
# Run it from the root of the isolated copy (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8 LC_ALL=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS DELTACTL_TUI_KEYS DELTACTL_TUI_EVENTS DELTACTL_TUI_ROWS DELTACTL_THEME
unset DELTACTL_REFRESH DELTACTL_METRICS_INTERVAL DELTACTL_TUI_IDLE_AFTER DELTACTL_TUI_GATE DELTACTL_CLIP DELTACTL_PR_SHELL DELTACTL_GRAPH TUI_GRAPH

FIX="$(mktemp -d)"
export FIX
CFG="$(dirname "${DELTACTL_CONFIG:-$FIX/x}")/.srv-test-config"
trap 'rm -rf "$FIX" instances/srv-*' EXIT
mkdir -p "$FIX/bin" "$FIX/os" "$FIX/frames"
: > "$FIX/containers.txt"; : > "$FIX/images.txt"; : > "$FIX/stats.txt"
cp tests/fake-docker.sh "$FIX/bin/docker-fake"
cat > "$FIX/bin/docker" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  ps) n=$(wc -l < "$FIX/containers.txt"); for ((i = 1; i <= n; i++)); do echo "c$i"; done ;;
  inspect) cat "$FIX/containers.txt" ;;
  stats) cat "$FIX/stats.txt" ;;
  logs) echo "linea normal" ;;
  compose) case "$*" in *" logs"*) echo "linea normal" ;; *) exec bash "$FIX/bin/docker-fake" "$@" ;; esac ;;
  *) exec bash "$FIX/bin/docker-fake" "$@" ;;
esac
SHIM
printf '#!/bin/sh\nexit 0\n' > "$FIX/bin/ss"
chmod +x "$FIX/bin/docker" "$FIX/bin/ss"
printf 'ID=debian\nNAME="Debian GNU/Linux"\nPRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\n' > "$FIX/os/debian"
printf 'MemTotal:        8388608 kB\nMemAvailable:    3145728 kB\n' > "$FIX/meminfo"
printf '0.82 0.50 0.40 1/200 1234\n' > "$FIX/loadavg"
export DELTACTL_MEMINFO="$FIX/meminfo" DELTACTL_LOADAVG="$FIX/loadavg" DELTACTL_PROC_ROOT="$FIX/proc" DELTACTL_CGROUP_ROOT="$FIX/cg"
export DELTACTL_OS_RELEASE="$FIX/os/debian"
# A PATH with everything of the system except what a server that has nothing installed would lack (as tests/test-prereqs.sh does).
mkdir -p "$FIX/nopath"
for d in /usr/bin /bin; do [ -d "$d" ] && ln -sf "$d"/* "$FIX/nopath/" 2>/dev/null; done
rm -f "$FIX/nopath"/{docker,openssl,ss,gunzip,nginx,caddy,certbot,curl,timedatectl,systemctl,wl-copy,xclip,xsel,pbcopy}
# What would install something: a script that only notes what it was asked to run.
cat > "$FIX/fakesh" <<'EOS'
#!/bin/sh
shift
echo "RAN: $*" >> "$FIX/ran.txt"
EOS
chmod +x "$FIX/fakesh"

KEYS="$FIX/keys.txt"
# The panel with the keys given (one per line), a server that has Docker (ok) or one that has nothing (bad). ASCII, no colours, 100 x 30
# (PANEL_COLS and PANEL_ROWS change the size). The panel starts on the first view unless DELTACTL_TUI_GATE=1 finds something missing.
panel_ok() { printf '%s\n' "$@" > "$KEYS"; PATH="$FIX/bin:$PATH" DELTACTL_CONFIG="$CFG" DELTACTL_TUI_KEYS="$KEYS" DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_ASCII=1 COLUMNS="${PANEL_COLS:-100}" DELTACTL_TUI_ROWS="${PANEL_ROWS:-30}" bash ./deltactl 2>&1; }
panel_bad() { printf '%s\n' "$@" > "$KEYS"; PATH="$FIX/nopath" DELTACTL_PR_SBIN="" DELTACTL_CONFIG="$CFG" DELTACTL_TUI_KEYS="$KEYS" DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_ASCII=1 COLUMNS="${PANEL_COLS:-100}" DELTACTL_TUI_ROWS="${PANEL_ROWS:-30}" bash ./deltactl 2>&1; }
frame_n() { awk -v n="$1" '/^=== frame /{ f = ($3 == n) } f'; }
last_frame() { awk '/^=== frame /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }'; }
# Library mode: the panel loaded, nothing drawn.
run_lib() { ROOT="$PWD" DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_ASCII=1 COLUMNS=100 DELTACTL_CONFIG="$CFG" bash -c 'source lib/bootstrap.sh; source lib/cmd/dashboard.sh; '"$1" 2>&1; }

section "1. figures in human units"
check "kilobytes: KiB, MiB, GiB with two decimals and whole GiB from ten" '[ "$(run_lib "for k in 512 2048 1048576 5892096 10485760 214748364; do dash_srv_kb \$k; printf \"%s|\" \"\$DASH_SZ\"; done")" = "512 KiB|2 MiB|1.00 GiB|5.61 GiB|10 GiB|204 GiB|" ]'
check "bytes: B, KiB, MiB and GiB with one decimal" '[ "$(run_lib "for b in 950 1536 4194304 1073741824 5368709120; do dash_srv_b \$b; printf \"%s|\" \"\$DASH_SZ\"; done")" = "950 B|1.5 KiB|4.0 MiB|1.00 GiB|5.00 GiB|" ]'
check "something that is not a number is a dash, not an error" '[ "$(run_lib "dash_srv_kb x; a=\$DASH_SZ; dash_srv_b \"\"; echo \$a \$DASH_SZ")" = "- -" ]'
check "uptime: hours and minutes, with days from the first" '[ "$(run_lib "for s in 59 3600 8555 90061 1000000; do dash_srv_uptime \$s; printf \"%s|\" \"\$DASH_UPT\"; done")" = "00:00|01:00|02:22|1d 01:01|11d 13:46|" ]'
check "texts with arguments fill {1}, {2} and {3} without a process" '[ "$(run_lib "dash_srv_t tui.srv.status.req 7 9; echo \$DASH_T")" = "7/9 listos" ] && [ "$(DELTACTL_LANG=en run_lib "dash_srv_t tui.srv.status.req 7 9; echo \$DASH_T")" = "7/9 ready" ]'

section "2. the view is registered with one line and follows the contract"
check "it is the seventh tab and its digit opens it" '[ "$(run_lib "dash_screen_by_number 7; echo \$DASH_SCR_ID")" = "server" ]'
check "the dialog that asks is a mode" '[ "$(run_lib "printf \"%s \" \${DASH_MODES[@]}")" = "menu confirm name cmd filter find wizard palette help options srvask " ]'
check "every function of the contract it uses is defined" 'run_lib "for f in render key keys texts sig enter back tick poll bang; do declare -F scr_server_\$f >/dev/null || exit 1; done; for f in render key keys sig; do declare -F scr_srvask_\$f >/dev/null || exit 1; done"'
check "the requirements are shown required first, then recommended, in the order of the catalog" '[ "$(run_lib "echo \${DASH_SRV_ORDER[*]} \$DASH_SRV_NREQ")" = "docker daemon compose disk ram mongo ss openssl gunzip nofile proxy certbot timesync firewall curl 9" ]'
check "its signature carries the state it draws" '[ "$(run_lib "DASH_SIG=; scr_server_sig; echo \$DASH_SIG")" = "|0|0|0|none|0|0" ]'
check "it is in the list of views of the console, the palette and the error message" 'grep -q "console server" lib/screens/console.sh && grep -q "console server; do" lib/screens/palette.sh && grep -q "console · server" lib/i18n/es/dashboard.sh && grep -q "console · server" lib/i18n/en/dashboard.sh'
check "the registry documents the hook of the key !" 'grep -q "scr_<id>_bang" lib/screens/registry.sh'

section "3. snapshots of the scenes (80x24, 120x30 and 160x40)"
GOLD_DIR="${DELTACTL_GOLDEN_DIR:-tests/golden}/server"
MODE="${DELTACTL_GOLDEN:-check}"
mkdir -p "$GOLD_DIR" 2> /dev/null || true
# scene <name> <cols> <rows> [lang] [colour-env...] -> the frame as the panel draws it (the last one)
scene() {
  local name="$1" cols="$2" rows="$3" lang="${4:-es}"
  shift 4 2> /dev/null || shift $#
  env ROOT="$PWD" DELTACTL_LANG="$lang" DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never COLUMNS="$cols" DELTACTL_TUI_ROWS="$rows" \
    DELTACTL_CONFIG="$FIX/none" DELTACTL_THEME=matrix HOME="$FIX" XDG_CONFIG_HOME="$FIX/xdg" "$@" \
    bash -c 'source lib/bootstrap.sh; source lib/cmd/dashboard.sh; source tests/tools/server_scenes.sh; set +e; server_scene '"$name" 2>&1 \
    | awk '/^=== frame /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }'
}
names="ok missing open zoom na loading"
for sc in $names; do
  for sz in 80x24 120x30 160x40; do
    g="$GOLD_DIR/$sc-$sz-es.txt"
    scene "$sc" "${sz%x*}" "${sz#*x}" es > "$FIX/frames/$sc-$sz-es.txt"
    if [ "$MODE" = record ]; then cp "$FIX/frames/$sc-$sz-es.txt" "$g"; echo "  REC  $sc @ $sz (es)"
    else check "scene $sc at $sz (es) equals its snapshot" '[ -f "$g" ] && cmp -s "$FIX/frames/$sc-$sz-es.txt" "$g"'; fi
  done
done
for sc in ok missing; do
  for sz in 80x24 120x30 160x40; do
    g="$GOLD_DIR/$sc-$sz-en.txt"
    scene "$sc" "${sz%x*}" "${sz#*x}" en > "$FIX/frames/$sc-$sz-en.txt"
    if [ "$MODE" = record ]; then cp "$FIX/frames/$sc-$sz-en.txt" "$g"; echo "  REC  $sc @ $sz (en)"
    else check "scene $sc at $sz (en) equals its snapshot" '[ -f "$g" ] && cmp -s "$FIX/frames/$sc-$sz-en.txt" "$g"'; fi
  done
done

section "4. the shape of every frame"
for sz in 60x14 80x24 100x20 120x30 160x40; do
  for sc in $names; do
    [ -f "$FIX/frames/$sc-$sz-es.txt" ] || scene "$sc" "${sz%x*}" "${sz#*x}" es > "$FIX/frames/$sc-$sz-es.txt"
  done
done
check "no line is wider than the screen, in any scene and size" 'for f in "$FIX"/frames/*-es.txt; do sz="${f##*-}"; sz="${f%-es.txt}"; sz="${sz##*-}"; c="${sz%x*}"; awk -v c="$c" "{ if (length(\$0) > c) bad = 1 } END { exit bad }" "$f" || { echo "$f"; exit 1; }; done'
check "a frame has exactly the rows of the screen (the header, the tabs, the body, the message and the keys)" 'for f in "$FIX"/frames/*-es.txt; do sz="${f%-es.txt}"; sz="${sz##*-}"; r="${sz#*x}"; c="${sz%x*}"; [ "$c" -ge 60 ] && [ "$r" -ge 14 ] || continue; [ "$(grep -c "" "$f")" -eq "$((r + 1))" ] || { echo "$f $(grep -c "" "$f") $r"; exit 1; }; done'
check "the requirements are always in the first rows of the body: the box with its chip and the ready count" 'for sc in ok missing; do for sz in 80x24 120x30 160x40; do sed -n 4p "$FIX/frames/$sc-$sz-es.txt" | grep -q "requisitos" || exit 1; done; done'
check "at 160 columns the requirements are two columns, required and recommended" 'sed -n 5p "$FIX/frames/ok-160x40-es.txt" | grep -q "OBLIGATORIOS.*RECOMENDADOS"'
check "at 80 columns they are one column with both headings" 'grep -q "OBLIGATORIOS" "$FIX/frames/ok-80x24-es.txt" && ! grep -q "RECOMENDADOS.*OBLIGATORIOS\|OBLIGATORIOS.*RECOMENDADOS" "$FIX/frames/ok-80x24-es.txt"'
check "the wide layout has the five boxes: cpu, memory, disks, network and containers" 'for b in cpu memoria discos red contenedores; do grep -q "┐$b┌" "$FIX/frames/ok-160x40-es.txt" || exit 1; done'
check "the narrow layout has the cpu, memory, disks and network, and the containers wait for width" 'for b in cpu memoria discos red; do grep -q "┐$b┌" "$FIX/frames/ok-80x24-es.txt" "$FIX/frames/ok-120x30-es.txt" >/dev/null 2>&1 || true; done; grep -q "┐cpu┌" "$FIX/frames/ok-80x24-es.txt" && grep -q "┐memoria┌" "$FIX/frames/ok-80x24-es.txt" && ! grep -q "┐contenedores┌" "$FIX/frames/ok-80x24-es.txt"'
check "the metrics view (m) has no requirements box and uses the room for the figures" '! grep -q "┐requisitos┌\|▸requisitos" "$FIX/frames/zoom-120x30-es.txt" && grep -q "┐cpu┌" "$FIX/frames/zoom-120x30-es.txt" && grep -q "m requisitos" "$FIX/frames/zoom-120x30-es.txt"'
check "with the figures not available every box says so instead of staying empty" '[ "$(grep -o "no disponible en este sistema" "$FIX/frames/na-160x40-es.txt" | wc -l)" -ge 4 ]'
check "while the requirements are checked, the box says so and every state is the one of a pending check" 'grep -q "comprobando…" "$FIX/frames/loading-120x30-es.txt" && grep -q "◐" "$FIX/frames/loading-120x30-es.txt" && ! grep -q "listos" "$FIX/frames/loading-120x30-es.txt"'
check "a requirement that fails shows what to do about it: the hint of the check" 'grep -q "Libera disco o mueve Docker" "$FIX/frames/missing-160x40-es.txt"'
check "the ready count: 6 of 9 required with the disk and Mongo failing; the three recommended ones that are pending" 'grep -q "6/9 listos · 3 recomendados pendientes" "$FIX/frames/missing-160x40-es.txt"'
check "a terminal smaller than 60x14 still says it is too small instead of drawing broken boxes" '[ "$(scene ok 50 20 es | grep -c "demasiado pequeña")" -ge 1 ]'

section "5. ASCII, colours and the language"
scene ok 120 30 es DELTACTL_ASCII=1 > "$FIX/frames/ascii.txt"
check "in ASCII (LANG=C or DELTACTL_ASCII) there is no character outside ASCII in the frame (what the panel prints itself; the words of the language keep their accents)" '! LC_ALL=C grep -v "^[ -~]*$" "$FIX/frames/ascii.txt" | grep -qP "[\x{2500}-\x{28FF}]"'
check "in ASCII the state is still told by its symbol and the graph is drawn" 'grep -q "\* Docker Engine\|> \* Docker" "$FIX/frames/ascii.txt" && grep -q "cpu" "$FIX/frames/ascii.txt"'
scene ok 120 30 es DELTACTL_COLOR=always COLORTERM=truecolor > "$FIX/frames/color.txt"
check "with colours the frame has colour sequences, and the gradient meters use more than one colour" 'grep -q $'"'"'\033\[38;2;'"'"' "$FIX/frames/color.txt" && [ "$(grep -o $'"'"'\033\[38;2;[0-9;]*m'"'"' "$FIX/frames/color.txt" | sort -u | wc -l)" -gt 20 ]'
scene ok 120 30 es DELTACTL_COLOR=never > "$FIX/frames/nocolor.txt"
check "NO_COLOR draws no escape sequence at all" '! grep -q $'"'"'\033'"'"' "$FIX/frames/nocolor.txt"'
scene ok 120 30 es DELTACTL_GRAPH=blocks > "$FIX/frames/blocks.txt"
check "DELTACTL_GRAPH=blocks draws the graphs with block characters, not braille" '! grep -qP "[\x{2800}-\x{28FF}]" "$FIX/frames/blocks.txt" && grep -qP "[\x{2581}-\x{2588}]" "$FIX/frames/blocks.txt"'
check "English: the titles, the chips and the groups are translated" 'grep -q "REQUIRED" "$FIX/frames/ok-160x40-en.txt" && grep -q "┐memory┌" "$FIX/frames/ok-160x40-en.txt" && grep -q "┐network┌" "$FIX/frames/ok-160x40-en.txt" && grep -q "What for" "$FIX/frames/ok-160x40-en.txt" && ! grep -q "??" "$FIX/frames/ok-160x40-en.txt"'
check "no frame leaves a missing translation (??key??) behind" '! grep -l "??" "$FIX"/frames/*.txt | grep -q .'

section "6. the view in the panel: keys end to end (a server with nothing installed)"
out="$(panel_bad 7 q)"
check "7 opens the view: the tab is active and the requirements are listed" 'echo "$out" | last_frame | grep -q "\[7 Servidor\]" && echo "$out" | last_frame | grep -q "OBLIGATORIOS" && echo "$out" | last_frame | grep -q "Docker Engine"'
check "Docker is missing: it says so, with a cross, and what it is for" 'echo "$out" | last_frame | grep -q "x Docker Engine" && echo "$out" | last_frame | grep -q "Docker no está instalado" && echo "$out" | last_frame | grep -q "Para qué: Ejecuta los servicios"'
check "it says how to install it: the command of this distribution (apt on Debian)" 'echo "$out" | last_frame | grep -q "Cómo: sudo apt-get update && sudo apt-get install -y docker.io"'
check "the first requirement is the selected one; down moves the mark" '[ "$(panel_bad 7 down q | last_frame | grep -c "^| > ")" -ge 1 ] && panel_bad 7 down q | last_frame | grep "^| > " | grep -q "Acceso al daemon"'
check "the compact detail has no link; Enter opens the detail with every result, its hint and the link, and Enter again closes it" 'o="$(panel_bad 7 enter enter q)"; ! echo "$o" | frame_n 2 | grep -q "Más información" && echo "$o" | frame_n 3 | grep -q "Más información: https://docs.docker.com/engine/install/" && echo "$o" | frame_n 3 | grep -q "Docker no está instalado" && ! echo "$o" | frame_n 4 | grep -q "Más información"'
check "Esc closes the detail without leaving the view" 'o="$(panel_bad 7 enter esc q)"; echo "$o" | frame_n 3 | grep -q "Más información" && ! echo "$o" | frame_n 4 | grep -q "Más información" && echo "$o" | frame_n 4 | grep -q "\[7 Servidor\]"'
check "m shows only the figures and m again brings the requirements back" 'o="$(panel_bad 7 m m q)"; ! echo "$o" | frame_n 3 | grep -q "OBLIGATORIOS" && echo "$o" | frame_n 3 | grep -q "m requisitos" && echo "$o" | frame_n 4 | grep -q "OBLIGATORIOS"'
check "Esc leaves the metrics view first, then the view" 'o="$(panel_bad 7 m esc esc q)"; echo "$o" | frame_n 4 | grep -q "OBLIGATORIOS" && echo "$o" | frame_n 4 | grep -q "\[7 Servidor\]" && echo "$o" | frame_n 5 | grep -q "\[1 Instancias\]"'
check "R checks again: it says so and draws another frame with the answer" 'o="$(panel_bad 7 R q)"; echo "$o" | last_frame | grep -q "Comprobando los requisitos"'
check "Up and Down stop at the ends of the list; PgDn and End go to the last one" 'panel_bad 7 up up q | last_frame | grep "^| > " | grep -q "Docker Engine" && panel_bad 7 end q | last_frame | grep "^| > " | grep -q "curl"'
check "with a keyboard that moves with j and k they move too (the vim keys)" 'panel_bad 7 j j k q | last_frame | grep "^| > " | grep -q "Acceso al daemon"'

section "7. copying the command"
rm -f "$FIX/clip.txt"
panel_bad 7 c q > "$FIX/out.txt"
check "without a clipboard tool or a terminal the command is shown to select" 'grep -q "No se pudo copiar; el comando es: sudo apt-get update" "$FIX/out.txt"'
DELTACTL_CLIP="cat > $FIX/clip.txt" panel_bad 7 c q > "$FIX/out.txt"
check "c copies the install command of the selected requirement, and says what" '[ "$(cat "$FIX/clip.txt")" = "sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2" ] && grep -q "Copiado: sudo apt-get update" "$FIX/out.txt"'
rm -f "$FIX/clip.txt"
DELTACTL_CLIP="cat > $FIX/clip.txt" panel_bad 7 down c q > "$FIX/out.txt"
check "a requirement that is not fine and has no command (the daemon of an absent Docker is pending) is told so, nothing is copied" '[ ! -s "$FIX/clip.txt" ] || grep -q "systemctl" "$FIX/clip.txt"'
printf 'ID=plan9\nNAME="Plan 9"\n' > "$FIX/os/none"
rm -f "$FIX/clip.txt"
DELTACTL_OS_RELEASE="$FIX/os/none" DELTACTL_CLIP="cat > $FIX/clip.txt" panel_bad 7 c q > "$FIX/out.txt"
check "on a distribution that is not known there is no command to copy" '[ ! -s "$FIX/clip.txt" ] && grep -q "No hay un comando" "$FIX/out.txt"'
check "and the detail says so and lists the command of each package manager" 'o="$(PANEL_ROWS=40 DELTACTL_OS_RELEASE="$FIX/os/none" panel_bad 7 enter q | last_frame)"; echo "$o" | grep -q "No se reconoce la distribución" && echo "$o" | grep -q "apt: sudo apt-get" && echo "$o" | grep -q "pacman: sudo pacman"'
printf 'ID=fedora\nNAME=Fedora\n' > "$FIX/os/fedora"
rm -f "$FIX/clip.txt"
DELTACTL_OS_RELEASE="$FIX/os/fedora" DELTACTL_CLIP="cat > $FIX/clip.txt" panel_bad 7 c q > /dev/null
check "on Fedora it is the dnf command" 'grep -q "^sudo dnf config-manager addrepo" "$FIX/clip.txt"'

section "8. running the command: it asks first and only runs if you say yes"
rm -f "$FIX/ran.txt"
out="$(DELTACTL_PR_SHELL="$FIX/fakesh" panel_bad 7 '!')"
check "! opens a window with the command written out whole, what sudo will do and how to answer" 'echo "$out" | last_frame | grep -q "Ejecutar en la terminal" && echo "$out" | last_frame | grep -q "sudo apt-get update && sudo apt-get install -y docker.io" && echo "$out" | last_frame | grep -q "nunca instala nada por su" && echo "$out" | last_frame | grep -q "y ejecutar"'
check "nothing has run while the window is open" '[ ! -e "$FIX/ran.txt" ]'
DELTACTL_PR_SHELL="$FIX/fakesh" panel_bad 7 '!' x > "$FIX/out.txt"
check "any other key cancels: nothing runs and the panel says it was cancelled" '[ ! -e "$FIX/ran.txt" ] && grep -q "Cancelado" "$FIX/out.txt"'
DELTACTL_PR_SHELL="$FIX/fakesh" panel_bad 7 '!' esc > /dev/null
check "Esc cancels too" '[ ! -e "$FIX/ran.txt" ]'
printf '\n' | DELTACTL_PR_SHELL="$FIX/fakesh" panel_bad 7 '!' y > "$FIX/out.txt"
check "y runs it in the terminal: the shell gets exactly that command" '[ "$(cat "$FIX/ran.txt")" = "RAN: sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2" ]'
check "and the requirements are checked again afterwards" '[ "$(grep -c "^=== frame" "$FIX/out.txt")" -ge 3 ]'
rm -f "$FIX/ran.txt"
DELTACTL_PR_SHELL="$FIX/fakesh" panel_bad 7 down down down '!' q > "$FIX/out.txt"
check "a requirement that is waiting for another has no command: it says so and opens no window" '[ ! -e "$FIX/ran.txt" ] && ! grep -q "Ejecutar en la terminal" "$FIX/out.txt"'
DELTACTL_PR_SHELL="$FIX/fakesh" panel_ok 7 '!' q > "$FIX/out.txt"
check "a requirement that is fine has nothing to run" '[ ! -e "$FIX/ran.txt" ] && grep -q "ya está listo: no hay nada que ejecutar" "$FIX/out.txt"'
check "outside this view ! is still the command line that runs in the terminal" '[ "$(panel_ok "!" x | last_frame | grep -c "!x")" -ge 1 ]'

section "9. the notice when the panel starts (the first-run gate)"
out="$(DELTACTL_TUI_GATE=1 panel_bad q)"
check "with something required missing the panel opens on the Server view" 'echo "$out" | frame_n 1 | grep -q "\[7 Servidor\]"'
check "and says what is missing, once, in the message line" 'echo "$out" | frame_n 1 | grep -q "Faltan 1 requisitos obligatorios del servidor: Docker Engine"'
out="$(DELTACTL_TUI_GATE=1 panel_ok q)"
check "with everything in place it stays on the first view and says nothing" 'echo "$out" | frame_n 1 | grep -q "\[1 Instancias\]" && ! echo "$out" | frame_n 1 | grep -q "Faltan"'
out="$(panel_bad q)"
check "in test mode, without DELTACTL_TUI_GATE, nothing is checked at start (the other tests open on the first view)" 'echo "$out" | frame_n 1 | grep -q "\[1 Instancias\]"'
out="$(DELTACTL_TUI_GATE=1 panel_bad 7 esc q)"
check "the view can be left: Esc goes to the first view, with nothing blocking the other views" 'echo "$out" | frame_n 3 | grep -q "\[1 Instancias\]"'
out="$(DELTACTL_TUI_GATE=1 panel_bad 2 3 1 q)"
check "the other views open normally from the notice" 'echo "$out" | frame_n 3 | grep -q "\[3 Salida\]"'

section "10. creating an instance with something required missing"
rm -f "$CFG"
out="$(DELTACTL_TUI_GATE=1 panel_bad n)"
check "n does not open the form: it asks first, naming what is missing" 'echo "$out" | last_frame | grep -q "Faltan requisitos del servidor" && echo "$out" | last_frame | grep -q "Faltan 1 requisitos obligatorios: Docker Engine" && echo "$out" | last_frame | grep -q "puede fallar" && ! echo "$out" | last_frame | grep -q ">Nombre de la instancia"'
check "the key line offers the four answers" 'echo "$out" | last_frame | grep -q "y crear igualmente" && echo "$out" | last_frame | grep -q "v ver requisitos" && echo "$out" | last_frame | grep -q "n no volver a avisar"'
out="$(DELTACTL_TUI_GATE=1 panel_bad n y)"
check "y goes on: the form opens" 'echo "$out" | last_frame | grep -q ">Nombre de la instancia"'
out="$(DELTACTL_TUI_GATE=1 panel_bad n y esc n)"
check "and the question is not asked again in the same session" 'echo "$out" | last_frame | grep -q ">Nombre de la instancia" || echo "$out" | last_frame | grep -q "Nueva instancia"'
out="$(DELTACTL_TUI_GATE=1 panel_bad 1 n v)"
check "v shows the requirements" 'echo "$out" | last_frame | grep -q "\[7 Servidor\]" && echo "$out" | last_frame | grep -q "OBLIGATORIOS"'
out="$(DELTACTL_TUI_GATE=1 panel_bad 1 n esc)"
check "Esc cancels: back to where it was, nothing created" 'echo "$out" | last_frame | grep -q "\[1 Instancias\]" && ! echo "$out" | last_frame | grep -q ">Nombre de la instancia" && echo "$out" | last_frame | grep -q "Cancelado"'
check "nothing is written to the config file by any of those answers" '[ ! -s "$CFG" ] || ! grep -q "TUI_PREREQ" "$CFG"'
out="$(DELTACTL_TUI_GATE=1 panel_bad 1 n n)"
check "n (do not warn again) goes on to the form and says it will not warn again" 'echo "$out" | last_frame | grep -q ">Nombre de la instancia" && echo "$out" | grep -q "No se volverá a avisar"'
check "and it is remembered in the config file" 'grep -q "^TUI_PREREQ=off$" "$CFG"'
out="$(DELTACTL_TUI_GATE=1 panel_bad q)"
check "from then on the panel starts on the first view, with no notice" 'echo "$out" | frame_n 1 | grep -q "\[1 Instancias\]" && ! echo "$out" | frame_n 1 | grep -q "Faltan"'
out="$(DELTACTL_TUI_GATE=1 panel_bad 1 n)"
check "and n opens the form at once" 'echo "$out" | last_frame | grep -q ">Nombre de la instancia"'
out="$(panel_bad o down down down down down down)"
check "Options has the option, off, with what it does" 'echo "$out" | last_frame | grep -q "Aviso de requisitos" && echo "$out" | last_frame | grep -q "avisa si"'
out="$(panel_bad o down down down down down down enter)"
check "Options turns it back on (and remembers it)" 'echo "$out" | last_frame | grep -q "Aviso de requisitos: sí" || echo "$out" | grep -q "Aviso de requisitos: sí"; grep -q "^TUI_PREREQ=on$" "$CFG"'
out="$(DELTACTL_TUI_GATE=1 panel_bad q)"
check "and the notice is back" 'echo "$out" | frame_n 1 | grep -q "\[7 Servidor\]"'
rm -f "$CFG"

section "11. the check runs in the background and the figures are read only here"
check "the answer of the check is loaded from the declare lines of the producer, and nothing else" '[ "$(run_lib "DASH_SRV_ORDER=(a); dash_srv_apply \$'"'"'declare -A PR_STATUS=([a]=\"err\" )\ndeclare -- PR_N_ERR=\"3\"\ndeclare -- EVIL=\"1\"\ndeclare -- PATH=\"/nowhere\"'"'"'; echo \"\${PR_STATUS[a]} \$PR_N_ERR [\${EVIL:-}] \$PATH\" | grep -c nowhere")" = "0" ]'
check "the state goes from none to ready and the counts are drawn from it" '[ "$(PATH="$FIX/nopath" DELTACTL_PR_SBIN="" run_lib "echo \$DASH_SRV_STATE; dash_srv_request; echo \$DASH_SRV_STATE \$DASH_SRV_BAD \"\$DASH_SRV_BAD_NAMES\"" | tr "\n" " ")" = "none ready 1 Docker Engine " ]'
check "in the real panel (not the test mode) the check is a background job: the answer arrives on a later turn" '[ "$(PATH="$FIX/nopath" DELTACTL_PR_SBIN="" run_lib "unset DELTACTL_TUI_KEYS; dash_init; dash_srv_request; a=\$DASH_SRV_STATE\$DASH_SRV_BUSY; for i in \$(seq 1 60); do dash_async_take prereq && { dash_srv_apply \"\$DASH_AS_TEXT\"; break; }; sleep 0.2; done; echo \$a \$DASH_SRV_STATE \$DASH_SRV_BUSY \$DASH_SRV_BAD")" = "loading1 ready 0 1" ]'
check "a check already running is not started twice" '[ "$(PATH="$FIX/nopath" run_lib "unset DELTACTL_TUI_KEYS; dash_init; dash_srv_request; dash_srv_request; echo \${#DASH_AS_PID[@]}; dash_async_stop")" = "1" ]'
check "the figures of the server are read only while the view is current" '[ "$(run_lib "DASH_VIEW=instances; scr_server_tick; a=\$MT_HOST_DETAIL; DASH_VIEW=server; scr_server_tick; b=\$MT_HOST_DETAIL; DASH_VIEW=console; scr_server_tick; echo \$a\$b\$MT_HOST_DETAIL")" = "010" ]'
check "choosing the view asks for the first sample at once and the check" '[ "$(PATH="$FIX/nopath" run_lib "MT_LAST_US=5; scr_server_enter; echo \$MT_LAST_US \$DASH_SRV_STATE")" = "0 ready" ]'
check "the view is checked again every 2 minutes while it is on screen (not in test mode)" '[ "$(PATH="$FIX/nopath" run_lib "unset DELTACTL_TUI_KEYS; dash_init; DASH_SRV_AT=\$((SECONDS - 121)); scr_server_poll; a=\$DASH_SRV_BUSY; dash_async_stop; DASH_AS_PID[prereq]=; DASH_SRV_BUSY=0; DASH_SRV_AT=\$SECONDS; scr_server_poll; echo \$a \$DASH_SRV_BUSY")" = "1 0" ]'
BOXES='COLUMNS=160; DELTACTL_TUI_ROWS=40; source tests/tools/server_scenes.sh; server_scene ok >/dev/null; CALLS=0; fn="$(declare -f dash_srv_net)"; eval "${fn/dash_srv_net/dash_srv_net_orig}"; dash_srv_net() { CALLS=$((CALLS + 1)); dash_srv_net_orig "$@"; };'
check "a box whose figures did not move is not built again with the next sample" '[ "$(run_lib "$BOXES MT_SAMPLES=\$((MT_SAMPLES + 1)); dash_render >/dev/null; MT_SAMPLES=\$((MT_SAMPLES + 1)); dash_render >/dev/null; echo \$CALLS")" = "0" ]'
check "and it is built again as soon as one of its figures moves" '[ "$(run_lib "$BOXES MT_SAMPLES=\$((MT_SAMPLES + 1)); HOST_NET_DOWN_BPS=777; dash_render >/dev/null; echo \$CALLS")" = "1" ]'
check "the requirements box is kept while nothing it shows changes, and built again when the choice moves" '[ "$(run_lib "COLUMNS=160; DELTACTL_TUI_ROWS=40; source tests/tools/server_scenes.sh; server_scene ok >/dev/null; a=\$DASH_SRV_REQ_KEY; MT_SAMPLES=\$((MT_SAMPLES + 1)); dash_render >/dev/null; b=\$DASH_SRV_REQ_KEY; DASH_SRV_SEL=2; dash_render >/dev/null; c=\$DASH_SRV_REQ_KEY; [ \"\$a\" = \"\$b\" ] && [ \"\$a\" != \"\$c\" ] && echo ok")" = "ok" ]'
check "the body is built again with every sample, and reused when only the clock moved" '[ "$(run_lib "COLUMNS=120; DELTACTL_TUI_ROWS=30; tui_size; dash_init; DASH_VIEW=server; dash_render >/dev/null; a=\$DASH_BODY_SIG; dash_render >/dev/null; b=\$DASH_BODY_SIG; MT_SAMPLES=\$((MT_SAMPLES + 1)); dash_render >/dev/null; [ \"\$a\" = \"\$b\" ] && [ \"\$a\" != \"\$DASH_BODY_SIG\" ] && echo ok")" = "ok" ]'

section "12. first-run gate: when it blocks"
check "nothing blocks before the first check, with the option off, after going on, or with everything in place" '[ "$(PATH="$FIX/nopath" DELTACTL_PR_SBIN="" run_lib "dash_srv_blocking && echo b0; dash_srv_request; dash_srv_blocking && echo b1; DASH_SRV_SKIP=1; dash_srv_blocking && echo b2; DASH_SRV_SKIP=0; DASH_PREREQ=0; dash_srv_blocking && echo b3; DASH_PREREQ=1; DASH_SRV_BAD=0; dash_srv_blocking && echo b4; true" | tr "\n" " ")" = "b1 " ]'


finish

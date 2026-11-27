#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # the cases go in single quotes and are evaluated with eval
# The Server view of the panel (lib/screens/server*.sh, lib/screens/srvask.sh) and the first-run gate: the figures in human units, the golden
# snapshots of its scenes (tests/tools/server_scenes.sh) from 80x24 to 250x70, the strip and the list of requirements, the warnings, the focus,
# the zoom, the containers, the mouse, the processes and the ports, how it degrades (small screens, ASCII, no colour,
# sources that are not there), its keys end to end against a simulated server, copying and running an install command (always asking
# first), the notice when the panel starts and the question before creating an instance. No real Docker, no real host, nothing installed:
# the panel runs in test mode (DELTACTL_TUI_KEYS) and the command that would install something is replaced by a script that notes it.
# Snapshots: tests/golden/server/<scene>-<cols>x<rows>-<lang>.txt. DELTACTL_GOLDEN=record rewrites them (only when a change is intended).
# Run it from the root of the isolated copy (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8 LC_ALL=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS DELTACTL_TUI_KEYS DELTACTL_TUI_EVENTS DELTACTL_TUI_ROWS DELTACTL_THEME DELTACTL_TUI_START
unset DELTACTL_REFRESH DELTACTL_METRICS_INTERVAL DELTACTL_TUI_IDLE_AFTER DELTACTL_TUI_GATE DELTACTL_CLIP DELTACTL_PR_SHELL DELTACTL_GRAPH TUI_GRAPH
unset DELTACTL_ALERT_DISK_WARN DELTACTL_ALERT_DISK_ERR DELTACTL_ALERT_MEM_AVAIL DELTACTL_ALERT_SWAP DELTACTL_ALERT_LOAD_PCT DELTACTL_ALERT_TEMP_MARGIN DELTACTL_PS DELTACTL_SS DELTACTL_PS_TTL DELTACTL_SS_TTL

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
# (PANEL_COLS and PANEL_ROWS change the size). The panel starts on the first view, the Server view (DELTACTL_TUI_START is unset here).
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
check "it is the first tab and its digit opens it" '[ "$(run_lib "dash_screen_by_number 1; echo \$DASH_SCR_ID")" = "server" ]'
check "the dialog that asks is a mode" '[ "$(run_lib "printf \"%s \" \${DASH_MODES[@]}")" = "menu confirm name cmd filter lfilter find wizard newinst palette help options srvask imguse imgload envedit svcask accdom " ]'
check "every function of the contract it uses is defined" 'run_lib "for f in render key keys texts sig enter back tick poll bang tab click wheel; do declare -F scr_server_\$f >/dev/null || exit 1; done; for f in render key keys sig; do declare -F scr_srvask_\$f >/dev/null || exit 1; done"'
check "the requirements are shown required first, then recommended, in the order of the catalog" '[ "$(run_lib "echo \${DASH_SRV_ORDER[*]} \$DASH_SRV_NREQ")" = "docker daemon compose disk ram mongo ss openssl gunzip nofile proxy certbot timesync firewall curl 9" ]'
check "its signature carries the state it draws" '[ "$(run_lib "DASH_SIG=; scr_server_sig; echo \$DASH_SIG")" = "|0|0|0|0||none|0|0|req|0|0|0|name|0|0|none|none" ]'
check "it is first in the list of views of the console, the palette and the error message" 'grep -q "pool=(server images instances" lib/screens/console.sh && grep -q "for v in server images instances resources output runs procs console env activity; do" lib/screens/palette.sh && grep -q "Vistas: server · images" lib/i18n/es/dashboard.sh && grep -q "Views: server · images" lib/i18n/en/dashboard.sh'
check "the registry documents the hook of the key !" 'grep -q "scr_<id>_bang" lib/screens/registry.sh'

section "3. snapshots of the scenes (from 80x24 to 250x70)"
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
# The scenes and the sizes each one is kept at (the big ones where what they show needs them).
declare -A SIZES=(
  [ok]="80x24 120x30 160x40 200x55 250x70" [missing]="80x24 120x30 160x40 200x55" [modal]="80x24 120x30 160x40" [open]="80x24 120x30 160x40" [zoom]="80x24 120x30 160x40"
  [na]="80x24 120x30 160x40" [loading]="80x24 120x30 160x40" [alert]="120x30 160x40 240x50" [ok-open]="120x30 160x40" [focus-containers]="160x40"
  [zoom-cpu]="120x30 160x40" [many-cores]="160x40 200x55" [many-containers]="120x30 160x40 250x70" [wide]="250x70"
)
names="ok missing modal open zoom na loading alert ok-open focus-containers zoom-cpu many-cores many-containers wide"
for sc in $names; do
  for sz in ${SIZES[$sc]}; do
    g="$GOLD_DIR/$sc-$sz-es.txt"
    scene "$sc" "${sz%x*}" "${sz#*x}" es > "$FIX/frames/$sc-$sz-es.txt"
    if [ "$MODE" = record ]; then cp "$FIX/frames/$sc-$sz-es.txt" "$g"; echo "  REC  $sc @ $sz (es)"
    else check "scene $sc at $sz (es) equals its snapshot" '[ -f "$g" ] && cmp -s "$FIX/frames/$sc-$sz-es.txt" "$g"'; fi
  done
done
for sc in ok missing modal; do
  for sz in 80x24 120x30 160x40; do
    g="$GOLD_DIR/$sc-$sz-en.txt"
    scene "$sc" "${sz%x*}" "${sz#*x}" en > "$FIX/frames/$sc-$sz-en.txt"
    if [ "$MODE" = record ]; then cp "$FIX/frames/$sc-$sz-en.txt" "$g"; echo "  REC  $sc @ $sz (en)"
    else check "scene $sc at $sz (en) equals its snapshot" '[ -f "$g" ] && cmp -s "$FIX/frames/$sc-$sz-en.txt" "$g"'; fi
  done
done

section "4. the shape of every frame"
for sz in 60x14 100x20; do
  for sc in ok missing modal open zoom na loading; do
    [ -f "$FIX/frames/$sc-$sz-es.txt" ] || scene "$sc" "${sz%x*}" "${sz#*x}" es > "$FIX/frames/$sc-$sz-es.txt"
  done
done
check "no line is wider than the screen, in any scene and size" 'for f in "$FIX"/frames/*-es.txt; do sz="${f%-es.txt}"; sz="${sz##*-}"; c="${sz%x*}"; awk -v c="$c" "{ if (length(\$0) > c) bad = 1 } END { exit bad }" "$f" || { echo "$f"; exit 1; }; done'
check "a frame has exactly the rows of the screen (the header, the tabs, the body, the message and the keys)" 'for f in "$FIX"/frames/*-es.txt; do sz="${f%-es.txt}"; sz="${sz##*-}"; r="${sz#*x}"; c="${sz%x*}"; [ "$c" -ge 60 ] && [ "$r" -ge 14 ] || continue; [ "$(grep -c "" "$f")" -eq "$((r + 1))" ] || { echo "$f $(grep -c "" "$f") $r"; exit 1; }; done'
check "the strip is always in the first rows of the body: the box with its chip and the ready count" 'for sc in ok missing; do for sz in 80x24 120x30 160x40; do sed -n 4p "$FIX/frames/$sc-$sz-es.txt" | grep -q "requisitos" || exit 1; done; done'
check "with everything required fine the requirements are a strip of three rows: the count, the vital signs and the warnings, no list" 'f="$FIX/frames/ok-160x40-es.txt"; sed -n 4p "$f" | grep -q "9/9 listos" && sed -n 5p "$f" | grep -q "disco /.*carga.*núcleos.*activo.*▼.*▲" && sed -n 6p "$f" | grep -q "^╰.*Enter requisitos" && ! grep -q "OBLIGATORIOS" "$f"'
check "when something required fails the strip stays three rows: it turns into a warning that names what fails, and nothing opens by itself" 'for sz in 120x30 160x40; do f="$FIX/frames/missing-$sz-es.txt"; sed -n 4p "$f" | grep -q "6/9 listos" && sed -n 5p "$f" | grep -q "2 requisitos obligatorios fallan: Disco libre, MongoDB alcanzable" && sed -n 6p "$f" | grep -q "^╰" && ! grep -q "OBLIGATORIOS" "$f" || exit 1; done'
check "the modal is the list: required and recommended side by side from 120 columns, laid over the figures" 'grep -q "OBLIGATORIOS.*RECOMENDADOS" "$FIX/frames/modal-160x40-es.txt" && grep -q "OBLIGATORIOS.*RECOMENDADOS" "$FIX/frames/modal-120x30-es.txt" && grep -q "┐cpu┌" "$FIX/frames/modal-160x40-es.txt" && grep -qE "Enter detalle.*Esc cerrar" "$FIX/frames/modal-160x40-es.txt"'
scene modal 80 40 es > "$FIX/frames/modal-80x40-es.txt"
check "at 80 columns they are one column: the two headings are on lines of their own" 'f="$FIX/frames/modal-80x40-es.txt"; grep -q "OBLIGATORIOS" "$f" && grep -q "RECOMENDADOS" "$f" && ! grep -q "RECOMENDADOS.*OBLIGATORIOS\|OBLIGATORIOS.*RECOMENDADOS" "$f"'
check "the failing ones come first and the detail of the selected one has a zone of its own under a line that names it: what for, the result, how, where to read more" 'f="$FIX/frames/modal-160x40-es.txt"; grep -qE "│ ▸ ✖ Disco libre" "$f" && grep -qE "│ ─ ✖ Disco libre ─+ │" "$f" && grep -qE "Para qué +Las imágenes" "$f" && grep -qE "Resultado +Poco disco libre" "$f" && grep -qE "Cómo +Las imágenes y los logs" "$f"'
check "nothing is cut without saying so: a row that does not fit ends in … and its whole text is in the detail" 'f="$FIX/frames/open-160x40-es.txt"; grep -q "127.0.0.1:27017 no responde …" "$f" && grep -qE "Resultado +127.0.0.1:27017 no responde por TCP" "$f"'
check "the wide layout has the five boxes: cpu, memory, disks, network and containers" 'for b in cpu memoria discos red contenedores; do grep -q "┐$b┌" "$FIX/frames/ok-160x40-es.txt" || exit 1; done'
check "from 200 columns the cpu, the memory, the disks and the network are four boxes in one row and the containers take the whole width under them" 'f="$FIX/frames/ok-200x55-es.txt"; grep -q "┐cpu┌.*┐memoria┌.*┐discos┌.*┐red┌" "$f" && grep -q "^╭─┐contenedores┌.*┐4/4┌─╮$" "$f"'
check "under 200 columns the network shares a row with the containers" 'grep -q "┐red┌.*┐contenedores┌" "$FIX/frames/ok-160x40-es.txt" && grep -q "┐red┌.*┐contenedores┌" "$FIX/frames/ok-120x30-es.txt"'
check "the narrow layout is the strip, the cpu and the memory, and the containers: the network and the disks wait for a tall screen" 'f="$FIX/frames/ok-80x24-es.txt"; grep -q "┐cpu┌" "$f" && grep -q "┐memoria┌" "$f" && grep -q "┐contenedores┌" "$f" && ! grep -q "┐red┌" "$f" && ! grep -q "┐discos┌" "$f"'
check "the containers table has the columns that fit: from 160 columns the port and the trend of the CPU, from 200 the uptime and the restarts too" 'grep -q "PUERTO .*CPU TENDENCIA" "$FIX/frames/ok-160x40-es.txt" && grep -q "ACTIVO .*REINIC.*PUERTO" "$FIX/frames/ok-200x55-es.txt" && ! grep -q "PUERTO" "$FIX/frames/ok-80x24-es.txt"'
check "the services that were never created are one line (+N no creados), not N rows" 'f="$FIX/frames/many-containers-250x70-es.txt"; grep -q "┐39/40┌" "$f" && ! grep -q "not created" "$f" && ! grep -q "s3   inst09" "$f"'
check "the table keeps the cursor in view: the 18th container of 40 is on screen" 'grep -q "s1   inst05" "$FIX/frames/many-containers-160x40-es.txt"'
check "64 cores do not cover the graph: the grid says how many it leaves out (+N más) and the graph keeps its axis" 'f="$FIX/frames/many-cores-160x40-es.txt"; grep -qE "\+[0-9]+ más" "$f" && grep -q "mín .*media .*máx" "$f" && grep -q "ahora" "$f"'
check "a wide screen draws the graphs with their time axis and their minimum, mean and maximum" 'f="$FIX/frames/ok-200x55-es.txt"; grep -q "─ ahora" "$f" && grep -q "mín 0% · media" "$f"'
check "from 32 rows of body (36 of terminal) there is a row with the busiest processes and the ports that listen (the only boxes that start a program), and the figures stay compact to make room" 'for f in "$FIX/frames/ok-160x40-es.txt" "$FIX/frames/ok-200x55-es.txt" "$FIX/frames/wide-250x70-es.txt"; do grep -q "┐procesos┌" "$f" && grep -q "┐puertos┌" "$f" && grep -q "mongod" "$f" && grep -q "27017" "$f" || exit 1; done; ! grep -q "┐procesos┌" "$FIX/frames/ok-120x30-es.txt"; f="$FIX/frames/ok-200x55-es.txt"; [ "$(awk "/┐cpu┌/{a=NR} /┐contenedores┌/{b=NR} END{print b-a}" "$f")" -le 18 ]'
check "the ports of the instances say whose they are (4100 is colorado/s0)" 'grep -qE "4100 +0.0.0.0 +docker-proxy +12 +colorado/s0" "$FIX/frames/wide-250x70-es.txt"'
check "the warnings: the strip says how many there are and the first, and the boxes they are about carry them" 'f="$FIX/frames/alert-160x40-es.txt"; sed -n 5p "$f" | grep -qE "✖ [0-9]+ avisos: disco / al 96%" && grep -q "┐discos┌" "$f"'
check "the modal with everything fine is the list, with the detail of the selected one" 'f="$FIX/frames/ok-open-160x40-es.txt"; grep -q "OBLIGATORIOS.*RECOMENDADOS" "$f" && grep -qE "Para qué +" "$f"'
check "with the focus on the containers their box is the focused one (its chip is marked) and the cursor is on a row" 'f="$FIX/frames/focus-containers-160x40-es.txt"; grep -q "▸contenedores" "$f" && ! grep -q "▸requisitos" "$f" && grep -q "s0   piura" "$f"'
check "zoomed (z) a box is the whole body: the cpu with all its cores, its load graph and no other box" 'f="$FIX/frames/zoom-cpu-160x40-es.txt"; grep -q "▸cpu" "$f" && ! grep -q "┐memoria┌" "$f" && ! grep -q "┐requisitos┌" "$f" && grep -q "C7" "$f" && grep -q "z/Esc reducir" "$f" && [ "$(grep -c "ahora" "$f")" -ge 2 ]'
check "the metrics view (m) has no requirements box and uses the room for the figures" '! grep -q "┐requisitos┌\|▸requisitos" "$FIX/frames/zoom-120x30-es.txt" && grep -q "▸cpu" "$FIX/frames/zoom-120x30-es.txt" && grep -q "m requisitos" "$FIX/frames/zoom-120x30-es.txt"'
check "with the figures not available every box says so instead of staying empty" '[ "$(grep -o "no disponible en este sistema" "$FIX/frames/na-160x40-es.txt" | wc -l)" -ge 4 ]'
check "while the requirements are checked, the box says so and every state is the one of a pending check" 'grep -q "comprobando…" "$FIX/frames/loading-120x30-es.txt" && grep -q "◐" "$FIX/frames/loading-120x30-es.txt" && ! grep -q "listos" "$FIX/frames/loading-120x30-es.txt"'
check "a requirement that fails shows what to do about it: the hint of the check" 'grep -q "Libera disco o mueve Docker" "$FIX/frames/modal-160x40-es.txt"'
check "the ready count: 6 of 9 required with the disk and Mongo failing; the three recommended ones that are pending" 'grep -q "6/9 listos · 3 recomendados pendientes" "$FIX/frames/missing-160x40-es.txt"'
check "a terminal smaller than 60x14 still says it is too small instead of drawing broken boxes" '[ "$(scene ok 50 20 es | grep -c "demasiado pequeña")" -ge 1 ]'

section "5. ASCII, colours and the language"
scene ok 120 30 es DELTACTL_ASCII=1 > "$FIX/frames/ascii.txt"
check "in ASCII (LANG=C or DELTACTL_ASCII) there is no character outside ASCII in the frame (what the panel prints itself; the words of the language keep their accents)" '! LC_ALL=C grep -v "^[ -~]*$" "$FIX/frames/ascii.txt" | grep -qP "[\x{2500}-\x{28FF}]"'
scene modal 120 30 es DELTACTL_ASCII=1 > "$FIX/frames/ascii-missing.txt"
check "in ASCII the state is still told by its symbol and the graph is drawn" 'grep -q "x Disco libre" "$FIX/frames/ascii-missing.txt" && grep -q "! certbot" "$FIX/frames/ascii-missing.txt" && grep -q "cpu" "$FIX/frames/ascii.txt" && grep -qE "[#=.]{5}" "$FIX/frames/ascii.txt"'
scene ok 120 30 es DELTACTL_COLOR=always COLORTERM=truecolor > "$FIX/frames/color.txt"
check "with colours the frame has colour sequences, and the gradient meters use more than one colour" 'grep -q $'"'"'\033\[38;2;'"'"' "$FIX/frames/color.txt" && [ "$(grep -o $'"'"'\033\[38;2;[0-9;]*m'"'"' "$FIX/frames/color.txt" | sort -u | wc -l)" -gt 20 ]'
scene ok 120 30 es DELTACTL_COLOR=never > "$FIX/frames/nocolor.txt"
check "NO_COLOR draws no escape sequence at all" '! grep -q $'"'"'\033'"'"' "$FIX/frames/nocolor.txt"'
scene ok 120 30 es DELTACTL_GRAPH=blocks > "$FIX/frames/blocks.txt"
check "DELTACTL_GRAPH=blocks draws the graphs with block characters, not braille" '! grep -qP "[\x{2800}-\x{28FF}]" "$FIX/frames/blocks.txt" && grep -qP "[\x{2581}-\x{2588}]" "$FIX/frames/blocks.txt"'
check "English: the titles, the chips, the strip, the groups and the detail are translated" 'grep -q "9/9 ready" "$FIX/frames/ok-160x40-en.txt" && grep -q "┐memory┌" "$FIX/frames/ok-160x40-en.txt" && grep -q "┐network┌" "$FIX/frames/ok-160x40-en.txt" && grep -q "┐containers┌" "$FIX/frames/ok-160x40-en.txt" && grep -q "min .* avg .* max" "$FIX/frames/ok-160x40-en.txt" && grep -q "REQUIRED" "$FIX/frames/modal-160x40-en.txt" && grep -q "What for" "$FIX/frames/modal-160x40-en.txt" && ! grep -q "??" "$FIX/frames/ok-160x40-en.txt"'
check "no frame leaves a missing translation (??key??) behind" '! grep -l "??" "$FIX"/frames/*.txt | grep -q .'

section "6. the view in the panel: keys end to end (a server with nothing installed)"
out="$(panel_bad 1 enter q)"
check "the panel starts on it (key 1 is the same view): the tab is active and Enter lists the requirements in the modal, required first" 'echo "$out" | frame_n 1 | grep -q "\[1 Servidor\]" && echo "$out" | last_frame | grep -q "\[1 Servidor\]" && echo "$out" | last_frame | grep -q "OBLIGATORIOS" && echo "$out" | last_frame | grep -q "Docker Engine"'
check "Docker is missing: it says so, with a cross, and what it is for in the detail zone" 'echo "$out" | last_frame | grep -q "x Docker Engine" && echo "$out" | last_frame | grep -q "Docker no está instalado" && echo "$out" | last_frame | grep -qE "Para qué +Ejecuta los servicios"'
check "it says how to install it: the command of this distribution (apt on Debian)" 'echo "$out" | last_frame | grep -qE "Cómo +sudo apt-get update && sudo apt-get install -y docker.io"'
check "what fails comes first, then what warns, then what is pending: after Docker (fails) the first warning is ss, and the daemon that waits for Docker is below them" 'echo "$out" | last_frame | grep "| > " | grep -q "Docker Engine" && panel_bad 1 enter down q | last_frame | grep "| > " | grep -q "ss (iproute2)" && panel_bad 1 enter down down down down q | last_frame | grep "| > " | grep -q "Acceso al daemon"'
check "the compact detail has what it is for, the result, how to fix it and where to read more; Enter opens it with every result and its hint, and Enter again closes it" 'o="$(panel_bad 1 enter enter enter q)"; ! echo "$o" | frame_n 3 | grep -q "Instálalo: https" && echo "$o" | frame_n 3 | grep -qE "Más información +https://docs.docker.com/engine/install/" && echo "$o" | frame_n 4 | grep -q "Instálalo: https://docs.docker.com/engine/install/" && echo "$o" | frame_n 4 | grep -q "Docker no está instalado" && ! echo "$o" | frame_n 5 | grep -q "Instálalo: https"'
check "Esc closes the detail, then the modal, without leaving the view" 'o="$(panel_bad 1 enter enter esc esc q)"; echo "$o" | frame_n 4 | grep -q "Instálalo: https" && ! echo "$o" | frame_n 5 | grep -q "Instálalo: https" && echo "$o" | frame_n 5 | grep -q "OBLIGATORIOS" && ! echo "$o" | frame_n 6 | grep -q "OBLIGATORIOS" && echo "$o" | frame_n 6 | grep -q "\[1 Servidor\]"'
check "m shows only the figures and m again brings the requirements back" 'o="$(panel_bad 1 m m q)"; ! echo "$o" | frame_n 3 | grep -q "▸requisitos\|┐requisitos┌" && echo "$o" | frame_n 3 | grep -q "m requisitos" && echo "$o" | frame_n 4 | grep -q "listos"'
check "Esc leaves the metrics view first; the next one leaves the panel (this is the first view: there is nowhere to go back to)" 'o="$(panel_bad 1 m esc esc)"; echo "$o" | frame_n 4 | grep -q "listos" && echo "$o" | frame_n 4 | grep -q "\[1 Servidor\]" && ! echo "$o" | grep -q "^=== frame 6 ==="'
check "from another view Esc comes back to this one" 'panel_bad 3 esc q | frame_n 3 | grep -q "\[1 Servidor\]"'
check "R checks again: it says so and draws another frame with the answer" 'o="$(panel_bad 1 R q)"; echo "$o" | last_frame | grep -q "Comprobando los requisitos"'
check "Up and Down stop at the ends of the list; PgDn and End go to the last one" 'panel_bad 1 enter up up q | last_frame | grep "| > " | grep -q "Docker Engine" && panel_bad 1 enter end q | last_frame | grep "| > " | grep -q "curl"'
check "with a keyboard that moves with j and k they move too (the vim keys)" 'panel_bad 1 enter j j k q | last_frame | grep "| > " | grep -q "ss (iproute2)"'

section "7. copying the command"
rm -f "$FIX/clip.txt"
panel_bad 1 enter c q > "$FIX/out.txt"
check "without a clipboard tool or a terminal the command is shown to select" 'grep -q "No se pudo copiar; el comando es: sudo apt-get update" "$FIX/out.txt"'
DELTACTL_CLIP="cat > $FIX/clip.txt" panel_bad 1 enter c q > "$FIX/out.txt"
check "c copies the install command of the selected requirement, and says what" '[ "$(cat "$FIX/clip.txt")" = "sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2" ] && grep -q "Copiado: sudo apt-get update" "$FIX/out.txt"'
rm -f "$FIX/clip.txt"
DELTACTL_CLIP="cat > $FIX/clip.txt" panel_bad 1 enter down down down down c q > "$FIX/out.txt"
check "a requirement that waits for another (the daemon of an absent Docker is pending) copies nothing and says what it waits for" \
  '[ ! -e "$FIX/clip.txt" ] && grep -q "espera a otro" "$FIX/out.txt" && ! grep -q "Copiado" "$FIX/out.txt"'
rm -f "$FIX/clip.txt"
DELTACTL_CLIP="cat > $FIX/clip.txt" panel_bad 1 enter down down down down down down down c q > "$FIX/out.txt"
check "a requirement with no command at all (the disk) copies nothing and says there is no command" '[ ! -e "$FIX/clip.txt" ] && grep -q "No hay un comando" "$FIX/out.txt"'
printf 'ID=plan9\nNAME="Plan 9"\n' > "$FIX/os/none"
rm -f "$FIX/clip.txt"
DELTACTL_OS_RELEASE="$FIX/os/none" DELTACTL_CLIP="cat > $FIX/clip.txt" panel_bad 1 enter c q > "$FIX/out.txt"
check "on a distribution that is not known there is no command to copy" '[ ! -s "$FIX/clip.txt" ] && grep -q "No hay un comando" "$FIX/out.txt"'
check "and the detail says so and lists the command of each package manager" 'o="$(PANEL_ROWS=40 DELTACTL_OS_RELEASE="$FIX/os/none" panel_bad 1 enter enter q | last_frame)"; echo "$o" | grep -q "No se reconoce la distribución" && echo "$o" | grep -qE "apt: +sudo apt-get" && echo "$o" | grep -qE "pacman: +sudo pacman"'
printf 'ID=fedora\nNAME=Fedora\n' > "$FIX/os/fedora"
rm -f "$FIX/clip.txt"
DELTACTL_OS_RELEASE="$FIX/os/fedora" DELTACTL_CLIP="cat > $FIX/clip.txt" panel_bad 1 enter c q > /dev/null
check "on Fedora it is the dnf command" 'grep -q "^sudo dnf config-manager addrepo" "$FIX/clip.txt"'

section "8. running the command: it asks first and only runs if you say yes"
rm -f "$FIX/ran.txt"
out="$(DELTACTL_PR_SHELL="$FIX/fakesh" panel_bad 1 enter '!')"
check "! opens a window with the command written out whole, what sudo will do and how to answer" 'echo "$out" | last_frame | grep -q "Ejecutar en la terminal" && echo "$out" | last_frame | grep -q "sudo apt-get update && sudo apt-get install -y docker.io" && echo "$out" | last_frame | grep -q "nunca instala nada por su" && echo "$out" | last_frame | grep -q "y ejecutar"'
check "nothing has run while the window is open" '[ ! -e "$FIX/ran.txt" ]'
DELTACTL_PR_SHELL="$FIX/fakesh" panel_bad 1 enter '!' x > "$FIX/out.txt"
check "any other key cancels: nothing runs and the panel says it was cancelled" '[ ! -e "$FIX/ran.txt" ] && grep -q "Cancelado" "$FIX/out.txt"'
DELTACTL_PR_SHELL="$FIX/fakesh" panel_bad 1 enter '!' esc > /dev/null
check "Esc cancels too" '[ ! -e "$FIX/ran.txt" ]'
printf '\n' | DELTACTL_PR_SHELL="$FIX/fakesh" panel_bad 1 enter '!' y > "$FIX/out.txt"
check "y runs it in the terminal: the shell gets exactly that command" '[ "$(cat "$FIX/ran.txt")" = "RAN: sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2" ]'
check "and the requirements are checked again afterwards" '[ "$(grep -c "^=== frame" "$FIX/out.txt")" -ge 3 ]'
rm -f "$FIX/ran.txt"
DELTACTL_PR_SHELL="$FIX/fakesh" panel_bad 1 enter down down down down '!' q > "$FIX/out.txt"
check "a requirement that is waiting for another (the daemon of an absent Docker) offers nothing to run: no window, says what it waits for" \
  '[ ! -e "$FIX/ran.txt" ] && ! grep -q "Ejecutar en la terminal" "$FIX/out.txt" && grep -q "espera a otro" "$FIX/out.txt"'
DELTACTL_PR_SHELL="$FIX/fakesh" panel_bad 1 enter down down down down down down '!' q > "$FIX/out.txt"
check "a requirement with no command at all (Mongo) opens no window and says there is no command" \
  '[ ! -e "$FIX/ran.txt" ] && ! grep -q "Ejecutar en la terminal" "$FIX/out.txt" && grep -q "No hay un comando" "$FIX/out.txt"'
DELTACTL_PR_SHELL="$FIX/fakesh" panel_bad 1 m '!' q > "$FIX/out.txt"
check "with only the metrics on screen ! does nothing: it must not run the command of a requirement that is not shown" \
  '[ ! -e "$FIX/ran.txt" ] && ! grep -q "Ejecutar en la terminal" "$FIX/out.txt"'
# The command is shown whole or not at all: on a terminal where it does not fit y is not offered, it never runs what could not be read.
printf '\n' | DELTACTL_PR_SHELL="$FIX/fakesh" PANEL_COLS=60 PANEL_ROWS=14 panel_bad 1 enter '!' y > "$FIX/out.txt"
check "on a small terminal (60x14) where the command does not fit, y runs nothing" '[ ! -e "$FIX/ran.txt" ]'
check "and the window says to enlarge the terminal and does not show half a command" \
  'o="$(DELTACTL_PR_SHELL="$FIX/fakesh" PANEL_COLS=60 PANEL_ROWS=14 panel_bad 1 enter "!" | last_frame)"; echo "$o" | grep -q "Agranda la terminal" && ! echo "$o" | grep -q "apt-get install"'
printf '\n' | DELTACTL_OS_RELEASE="$FIX/os/fedora" DELTACTL_PR_SHELL="$FIX/fakesh" PANEL_COLS=60 PANEL_ROWS=14 panel_bad 1 enter '!' y > "$FIX/out.txt"
check "a long command with a URL that does not fit in the width is not offered either (Fedora at 60 columns)" '[ ! -e "$FIX/ran.txt" ]'
printf '\n' | DELTACTL_OS_RELEASE="$FIX/os/fedora" DELTACTL_PR_SHELL="$FIX/fakesh" PANEL_ROWS=40 panel_bad 1 enter '!' y > "$FIX/out.txt"
check "the same command on a terminal where it fits is offered and runs" 'grep -q "^RAN: sudo dnf config-manager addrepo" "$FIX/ran.txt"'
rm -f "$FIX/ran.txt"
DELTACTL_PR_SHELL="$FIX/fakesh" panel_ok 1 enter '!' q > "$FIX/out.txt"
check "a requirement that is fine has nothing to run (the list is opened first: with the strip there is no requirement to run)" '[ ! -e "$FIX/ran.txt" ] && grep -q "ya está listo: no hay nada que ejecutar" "$FIX/out.txt"'
check "outside this view ! is still the command line that runs in the terminal, and so it is here when the strip has the focus (no requirement is shown to run)" '[ "$(panel_ok 3 "!" x | last_frame | grep -c "!x")" -ge 1 ] && [ "$(panel_ok "!" x | last_frame | grep -c "!x")" -ge 1 ]'

section "9. the notice when the panel starts (the first-run gate)"
out="$(DELTACTL_TUI_GATE=1 panel_bad q)"
check "with something required missing the panel is on the Server view" 'echo "$out" | frame_n 1 | grep -q "\[1 Servidor\]"'
check "and says what is missing, once, in the message line" 'echo "$out" | frame_n 1 | grep -q "Faltan 1 requisitos obligatorios del servidor: Docker Engine"'
out="$(DELTACTL_TUI_GATE=1 panel_ok q)"
check "with everything in place it is on the Server view too and says nothing" 'echo "$out" | frame_n 1 | grep -q "\[1 Servidor\]" && ! echo "$out" | frame_n 1 | grep -q "Faltan"'
out="$(panel_bad q)"
check "in test mode, without DELTACTL_TUI_GATE, the panel starts on this view without a notice (the other suites start from Instancias with DELTACTL_TUI_START)" 'echo "$out" | frame_n 1 | grep -q "\[1 Servidor\]" && ! echo "$out" | frame_n 1 | grep -q "Faltan" && [ "$(DELTACTL_TUI_START=instances panel_bad q | frame_n 1 | grep -c "\[3 Instancias\]")" = 1 ]'
out="$(DELTACTL_TUI_GATE=1 panel_bad 3 esc q)"
check "the view can be left, with nothing blocking the other views, and Esc comes back to it" 'echo "$out" | frame_n 2 | grep -q "\[3 Instancias\]" && echo "$out" | frame_n 3 | grep -q "\[1 Servidor\]"'
out="$(DELTACTL_TUI_GATE=1 panel_bad 4 5 1 q)"
check "the other views open normally from the notice" 'echo "$out" | frame_n 3 | grep -q "\[5 Salida\]"'

section "10. creating an instance with something required missing"
rm -f "$CFG"
out="$(DELTACTL_TUI_GATE=1 panel_bad n)"
check "n does not open the form: it asks first, naming what is missing" 'echo "$out" | last_frame | grep -q "Faltan requisitos del servidor" && echo "$out" | last_frame | grep -q "Faltan 1 requisitos obligatorios: Docker Engine" && echo "$out" | last_frame | grep -q "puede fallar" && ! echo "$out" | last_frame | grep -q "\[nueva instancia\]"'
check "the key line offers the four answers" 'echo "$out" | last_frame | grep -q "y crear igualmente" && echo "$out" | last_frame | grep -q "v ver requisitos" && echo "$out" | last_frame | grep -q "n no volver a avisar"'
out="$(DELTACTL_TUI_GATE=1 panel_bad n y)"
check "y goes on: the form opens" 'echo "$out" | last_frame | grep -q "\[nueva instancia\]"'
out="$(DELTACTL_TUI_GATE=1 panel_bad n y esc n)"
check "and the question is not asked again in the same session" 'echo "$out" | last_frame | grep -q "\[nueva instancia\]" || echo "$out" | last_frame | grep -q "Nueva instancia"'
out="$(DELTACTL_TUI_GATE=1 panel_bad 3 n v)"
check "v shows the requirements" 'echo "$out" | last_frame | grep -q "\[1 Servidor\]" && echo "$out" | last_frame | grep -q "OBLIGATORIOS"'
out="$(DELTACTL_TUI_GATE=1 panel_bad 3 n esc)"
check "Esc cancels: back to where it was, nothing created" 'echo "$out" | last_frame | grep -q "\[3 Instancias\]" && ! echo "$out" | last_frame | grep -q "\[nueva instancia\]" && echo "$out" | last_frame | grep -q "Cancelado"'
check "nothing is written to the config file by any of those answers" '[ ! -s "$CFG" ] || ! grep -q "TUI_PREREQ" "$CFG"'
out="$(DELTACTL_TUI_GATE=1 panel_bad 3 n n)"
check "n (do not warn again) goes on to the form and says it will not warn again" 'echo "$out" | last_frame | grep -q "\[nueva instancia\]" && echo "$out" | grep -q "No se volverá a avisar"'
check "and it is remembered in the config file" 'grep -q "^TUI_PREREQ=off$" "$CFG"'
out="$(DELTACTL_TUI_GATE=1 panel_bad q)"
check "from then on the panel starts with no notice" 'echo "$out" | frame_n 1 | grep -q "\[1 Servidor\]" && ! echo "$out" | frame_n 1 | grep -q "Faltan"'
out="$(DELTACTL_TUI_GATE=1 panel_bad 3 n)"
check "and n opens the form at once" 'echo "$out" | last_frame | grep -q "\[nueva instancia\]"'
out="$(panel_bad o down down down down down down)"
check "Options has the option, off, with what it does" 'echo "$out" | last_frame | grep -q "Aviso de requisitos" && echo "$out" | last_frame | grep -q "avisa si"'
out="$(panel_bad o down down down down down down enter)"
check "Options turns it back on (and remembers it)" 'echo "$out" | last_frame | grep -q "Aviso de requisitos: sí" || echo "$out" | grep -q "Aviso de requisitos: sí"; grep -q "^TUI_PREREQ=on$" "$CFG"'
out="$(DELTACTL_TUI_GATE=1 panel_bad q)"
check "and the notice is back" 'echo "$out" | frame_n 1 | grep -q "Faltan 1 requisitos obligatorios"'
rm -f "$CFG"

section "11. the check runs in the background and the figures are read only here"
check "the answer of the check is loaded from the declare lines of the producer, and nothing else" '[ "$(run_lib "DASH_SRV_ORDER=(a); dash_srv_apply \$'"'"'declare -A PR_STATUS=([a]=\"err\" )\ndeclare -- PR_N_ERR=\"3\"\ndeclare -- EVIL=\"1\"\ndeclare -- PATH=\"/nowhere\"'"'"'; echo \"\${PR_STATUS[a]} \$PR_N_ERR [\${EVIL:-}] \$PATH\" | grep -c nowhere")" = "0" ]'
check "the state goes from none to ready and the counts are drawn from it" '[ "$(PATH="$FIX/nopath" DELTACTL_PR_SBIN="" run_lib "echo \$DASH_SRV_STATE; dash_srv_request; echo \$DASH_SRV_STATE \$DASH_SRV_BAD \"\$DASH_SRV_BAD_NAMES\"" | tr "\n" " ")" = "none ready 1 Docker Engine " ]'
check "in the real panel (not the test mode) the check is a background job: the answer arrives on a later turn" '[ "$(PATH="$FIX/nopath" DELTACTL_PR_SBIN="" run_lib "unset DELTACTL_TUI_KEYS; dash_init; dash_srv_request; a=\$DASH_SRV_STATE\$DASH_SRV_BUSY; for i in \$(seq 1 60); do dash_async_take prereq && { dash_srv_apply \"\$DASH_AS_TEXT\"; break; }; sleep 0.2; done; echo \$a \$DASH_SRV_STATE \$DASH_SRV_BUSY \$DASH_SRV_BAD")" = "loading1 ready 0 1" ]'
check "a check already running is not started twice" '[ "$(PATH="$FIX/nopath" run_lib "unset DELTACTL_TUI_KEYS; dash_init; dash_srv_request; dash_srv_request; echo \${#DASH_AS_PID[@]}; dash_async_stop")" = "1" ]'
check "the figures of the server are read only while the view is current" '[ "$(run_lib "DASH_VIEW=instances; scr_server_tick; a=\$MT_HOST_DETAIL; DASH_VIEW=server; scr_server_tick; b=\$MT_HOST_DETAIL; DASH_VIEW=console; scr_server_tick; echo \$a\$b\$MT_HOST_DETAIL")" = "010" ]'
check "choosing the view asks for the first sample and the check on the next tick (in the test mode there is no wait)" '[ "$(PATH="$FIX/nopath" run_lib "MT_LAST_US=5; DASH_VIEW=server; scr_server_enter; scr_server_tick; echo \$MT_LAST_US \$DASH_SRV_STATE")" = "0 ready" ]'
check "the view is checked again every 2 minutes while it is on screen (not in test mode)" '[ "$(PATH="$FIX/nopath" run_lib "unset DELTACTL_TUI_KEYS; dash_init; DASH_SRV_AT=\$((SECONDS - 121)); scr_server_poll; a=\$DASH_SRV_BUSY; dash_async_stop; DASH_AS_PID[prereq]=; DASH_SRV_BUSY=0; DASH_SRV_AT=\$SECONDS; scr_server_poll; echo \$a \$DASH_SRV_BUSY")" = "1 0" ]'
BOXES='COLUMNS=160; DELTACTL_TUI_ROWS=40; source tests/tools/server_scenes.sh; server_scene ok >/dev/null; CALLS=0; fn="$(declare -f dash_srv_net)"; eval "${fn/dash_srv_net/dash_srv_net_orig}"; dash_srv_net() { CALLS=$((CALLS + 1)); dash_srv_net_orig "$@"; };'
check "a box whose figures did not move is not built again with the next sample" '[ "$(run_lib "$BOXES MT_SAMPLES=\$((MT_SAMPLES + 1)); dash_render >/dev/null; MT_SAMPLES=\$((MT_SAMPLES + 1)); dash_render >/dev/null; echo \$CALLS")" = "0" ]'
check "and it is built again as soon as one of its figures moves" '[ "$(run_lib "$BOXES MT_SAMPLES=\$((MT_SAMPLES + 1)); HOST_NET_DOWN_BPS=777; dash_render >/dev/null; echo \$CALLS")" = "1" ]'
check "the requirements box is kept while nothing it shows changes (the strip does not show the choice), and built again when the choice moves in the zoomed list" '[ "$(run_lib "COLUMNS=160; DELTACTL_TUI_ROWS=40; source tests/tools/server_scenes.sh; server_scene ok >/dev/null; a=\$DASH_SRV_REQ_KEY; MT_SAMPLES=\$((MT_SAMPLES + 1)); dash_render >/dev/null; b=\$DASH_SRV_REQ_KEY; DASH_SRV_SEL=2; dash_render >/dev/null; c=\$DASH_SRV_REQ_KEY; DASH_SRV_PZ=req DASH_SRV_SEL=3; dash_render >/dev/null; d=\$DASH_SRV_REQ_KEY; [ \"\$a\" = \"\$b\" ] && [ \"\$a\" = \"\$c\" ] && [ \"\$a\" != \"\$d\" ] && echo ok")" = "ok" ]'
check "the body is built again with every sample, and reused when only the clock moved" '[ "$(run_lib "COLUMNS=120; DELTACTL_TUI_ROWS=30; tui_size; dash_init; DASH_VIEW=server; dash_render >/dev/null; a=\$DASH_BODY_SIG; dash_render >/dev/null; b=\$DASH_BODY_SIG; MT_SAMPLES=\$((MT_SAMPLES + 1)); dash_render >/dev/null; [ \"\$a\" = \"\$b\" ] && [ \"\$a\" != \"\$DASH_BODY_SIG\" ] && echo ok")" = "ok" ]'

section "12. first-run gate: when it blocks"
check "nothing blocks before the first check, with the option off, after going on, or with everything in place" '[ "$(PATH="$FIX/nopath" DELTACTL_PR_SBIN="" run_lib "dash_srv_blocking && echo b0; dash_srv_request; dash_srv_blocking && echo b1; DASH_SRV_SKIP=1; dash_srv_blocking && echo b2; DASH_SRV_SKIP=0; DASH_PREREQ=0; dash_srv_blocking && echo b3; DASH_PREREQ=1; DASH_SRV_BAD=0; dash_srv_blocking && echo b4; true" | tr "\n" " ")" = "b1 " ]'


section "13. fixes of the independent review"
printf '#!/bin/sh\nexit 3\n' > "$FIX/failsh"; chmod +x "$FIX/failsh"
printf '\n' | DELTACTL_PR_SHELL="$FIX/failsh" panel_bad 1 enter '!' y > "$FIX/out.txt"
check "when the command fails the message gives its real exit code (3), not 0" 'grep -q "terminó con errores (código 3)" "$FIX/out.txt"'
check "a text with & in its argument keeps it (Bash 5.2 replaces & by the matched text unless the replacement is quoted)" \
  '[ "$(run_lib "dash_srv_t tui.srv.status.req \"a && b\" 2; echo \$DASH_T")" = "a && b/2 listos" ]'
# The hooks that run a program only work inside the tests: an environment inherited by chance must not change what a confirmed command is.
check "DELTACTL_CLIP is only honoured inside the tests" \
  'rm -f "$FIX/clip13.txt"; env -u DELTACTL_TEST_ISOLATED DELTACTL_CLIP="cat > $FIX/clip13.txt" bash -c "ROOT=\$PWD DELTACTL_TUI_KEYS=/dev/null DELTACTL_CONFIG=$CFG; source lib/bootstrap.sh; source lib/cmd/dashboard.sh; dash_srv_copy x" >/dev/null 2>&1; [ ! -e "$FIX/clip13.txt" ] && run_lib "DELTACTL_CLIP=\"cat > $FIX/clip13.txt\"; dash_srv_copy x" && [ -e "$FIX/clip13.txt" ]'
check "DELTACTL_PR_SHELL is only honoured inside the tests (the shell that runs a confirmed command is bash)" \
  '[ "$(env -u DELTACTL_TEST_ISOLATED DELTACTL_PR_SHELL=/bin/false bash -c "ROOT=\$PWD DELTACTL_TUI_KEYS=/dev/null DELTACTL_CONFIG=$CFG; source lib/bootstrap.sh; source lib/cmd/dashboard.sh; dash_srv_shell" 2>&1)" = bash ] && [ "$(run_lib "DELTACTL_PR_SHELL=/bin/false; dash_srv_shell")" = /bin/false ]'
mkdir -p "$FIX/proc"; printf '/dev/sda2 / ext4 rw 0 0\n' > "$FIX/proc/mounts"
printf '#!/bin/sh\necho x >> "$FIX/df.calls"\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/sda2 100 40 60 40%% /"\n' > "$FIX/fake-df"; chmod +x "$FIX/fake-df"
check "DELTACTL_DF is only honoured inside the tests (and it does run in them)" \
  'rm -f "$FIX/df.calls"; DELTACTL_DF="$FIX/fake-df" HOST_FAKE_NOW_US=1000000 run_lib "host_disks_read; host_disk_usage_read" >/dev/null; [ -e "$FIX/df.calls" ]; rm -f "$FIX/df.calls"; env -u DELTACTL_TEST_ISOLATED DELTACTL_DF="$FIX/fake-df" HOST_FAKE_NOW_US=1000000 bash -c "ROOT=\$PWD; source lib/bootstrap.sh; host_disks_read; host_disk_usage_read" >/dev/null 2>&1; [ ! -e "$FIX/df.calls" ]'
# A panel with no result of a check yet (still checking) has nothing to run or copy, and none of its functions fail under set -u.
check "nothing is offered to run before the first answer arrives" \
  '[ "$(run_lib "DASH_VIEW=server; DASH_SRV_STATE=loading; PR_STATUS=(); scr_server_bang; echo \$DASH_MODE")" = "normal" ]'
check "the hint and the detail of a requirement without results do not fail under set -u" \
  'run_lib "set -u; PR_RECORDS=(); dash_srv_hint docker; dash_srv_detail 60 8; echo done" | grep -q "^done$"'
# A check that is cut after a minute (the daemon is stuck) must not leave the view on "checking" for good: the periodic one and R go on.
check "a check that was cut or died frees the view: it can be asked for again (it used to stay busy for ever)" \
  '[ "$(run_lib "dash_srv_slow() { sleep 30; }; dash_async prereq \"\" dash_srv_slow; DASH_SRV_BUSY=1; DASH_SRV_STATE=loading; DASH_AS_AT[prereq]=\$((SECONDS - 61)); DASH_VIEW=instances; scr_server_tick; echo \$DASH_SRV_BUSY [\${DASH_AS_PID[prereq]}]; dash_async_stop")" = "0 []" ]'
check "and the periodic check asks again once the time has passed" \
  '[ "$(run_lib "unset DELTACTL_TUI_KEYS; dash_init; DASH_SRV_BUSY=0; DASH_SRV_STATE=loading; DASH_SRV_AT=\$((SECONDS - 121)); dash_srv_request() { echo asked; }; scr_server_poll")" = "asked" ]'
# docker that never answers: the checks cut each call (PR_DOCKER_TIMEOUT) instead of waiting for it.
mkdir -p "$FIX/hang"
printf '#!/bin/sh\nsleep 20\n' > "$FIX/hang/docker"; chmod +x "$FIX/hang/docker"
check "a docker that does not answer does not hang the checks: every call is cut by PR_DOCKER_TIMEOUT" \
  's=$SECONDS; PATH="$FIX/hang:$PATH" run_lib "PR_DOCKER_TIMEOUT=1; prereq_distro; prereq_run_all; echo \${PR_STATUS[daemon]}" | grep -q "^err$"; [ $((SECONDS - s)) -le 8 ]'

section "14. the warnings: thresholds that an environment variable moves"
# A fine server (the scene "ok" with its disk, a container and the temperature put right) to move one figure at a time.
FINE='COLUMNS=160; DELTACTL_TUI_ROWS=40; source tests/tools/server_scenes.sh; server_scene ok >/dev/null; HOST_DISK_PCT=(50 22 25); DSV_KIND[piura/s1]=ok; '
check "a fine server has no warnings, and says so (no warnings)" '[ "$(run_lib "$FINE dash_srv_alerts; echo \${#DASH_SRV_ALERTS[@]}")" = "0" ] && run_lib "$FINE dash_srv_alerts; dash_srv_vitals 140; echo \"\$DASH_SRV_VIT\"" | grep -q "sin avisos"'
check "disk: 85 % warns and 95 % is an error, with the mount and the figure" '[ "$(run_lib "$FINE HOST_DISK_PCT=(85 22 25); dash_srv_alerts; echo \"\${DASH_SRV_ALERTS[*]}\"")" = "warn|disks|disco / al 85%" ] && [ "$(run_lib "$FINE HOST_DISK_PCT=(50 22 96); dash_srv_alerts; echo \"\${DASH_SRV_ALERTS[*]}\"")" = "err|disks|disco /var/backups al 96%" ]'
check "disk: DELTACTL_ALERT_DISK_WARN and DELTACTL_ALERT_DISK_ERR move the thresholds" '[ "$(DELTACTL_ALERT_DISK_WARN=90 run_lib "$FINE HOST_DISK_PCT=(86 22 25); dash_srv_alerts; echo \${#DASH_SRV_ALERTS[@]}")" = "0" ] && [ "$(DELTACTL_ALERT_DISK_ERR=80 run_lib "$FINE HOST_DISK_PCT=(86 22 25); dash_srv_alerts; echo \"\${DASH_SRV_ALERTS[0]%%|*}\"")" = "err" ]'
check "a threshold that is not a number is ignored (the default stays)" '[ "$(DELTACTL_ALERT_DISK_WARN=abc run_lib "$FINE HOST_DISK_PCT=(86 22 25); dash_srv_alerts; echo \${#DASH_SRV_ALERTS[@]}")" = "1" ]'
check "memory: what is AVAILABLE under 10 % warns and under 5 % is an error (the cache is not a problem)" '[ "$(run_lib "$FINE HOST_MEMD_AVAIL=1000000; dash_srv_alerts; echo \"\${DASH_SRV_ALERTS[*]}\"")" = "warn|mem|memoria disponible 8%" ] && [ "$(run_lib "$FINE HOST_MEMD_AVAIL=400000; dash_srv_alerts; echo \"\${DASH_SRV_ALERTS[0]%%|*}\"")" = "err" ] && [ "$(DELTACTL_ALERT_MEM_AVAIL=60 run_lib "$FINE dash_srv_alerts; echo \${#DASH_SRV_ALERTS[@]}")" = "1" ]'
check "swap: from 50 % in use it warns (DELTACTL_ALERT_SWAP)" '[ "$(run_lib "$FINE HOST_MEMD_SWAP_USED=2300000; dash_srv_alerts; echo \"\${DASH_SRV_ALERTS[*]}\"")" = "warn|mem|swap al 54%" ] && [ "$(DELTACTL_ALERT_SWAP=60 run_lib "$FINE HOST_MEMD_SWAP_USED=2300000; dash_srv_alerts; echo \${#DASH_SRV_ALERTS[@]}")" = "0" ]'
check "load: the load of one minute over the cores warns (DELTACTL_ALERT_LOAD_PCT is a percent of the cores)" '[ "$(run_lib "$FINE HOST_LOAD1=9.50; dash_srv_alerts; echo \"\${DASH_SRV_ALERTS[*]}\"")" = "warn|cpu|carga 9.50 con 8 núcleos" ] && [ "$(run_lib "$FINE HOST_LOAD1=8.00; dash_srv_alerts; echo \${#DASH_SRV_ALERTS[@]}")" = "0" ] && [ "$(DELTACTL_ALERT_LOAD_PCT=30 run_lib "$FINE dash_srv_alerts; echo \${#DASH_SRV_ALERTS[@]}")" = "1" ]'
check "temperature: near the limit its sensor reports warns, at the limit it is an error, and with no limit there is nothing to compare with" '[ "$(run_lib "$FINE HOST_TEMP_CPU_C=92 HOST_TEMP_CPU_CRIT=100; dash_srv_alerts; echo \"\${DASH_SRV_ALERTS[*]}\"")" = "warn|cpu|CPU a 92°C (límite 100°C)" ] && [ "$(run_lib "$FINE HOST_TEMP_CPU_C=100 HOST_TEMP_CPU_CRIT=100; dash_srv_alerts; echo \"\${DASH_SRV_ALERTS[0]%%|*}\"")" = "err" ] && [ "$(run_lib "$FINE HOST_TEMP_CPU_C=99 HOST_TEMP_CPU_CRIT=; dash_srv_alerts; echo \${#DASH_SRV_ALERTS[@]}")" = "0" ]'
check "containers: one that fails or warns is a warning; one that was never created is not" '[ "$(run_lib "$FINE DSV_KIND[colorado/s1]=err DSV_TEXT[colorado/s1]=exited; dash_srv_alerts; echo \"\${DASH_SRV_ALERTS[*]}\"")" = "err|containers|contenedor colorado/s1: exited" ] && [ "$(run_lib "$FINE DSV_KIND[colorado/s1]=dim DSV_CODES[colorado/s1]=not-created; dash_srv_alerts; echo \${#DASH_SRV_ALERTS[@]}")" = "0" ]'
check "requirements: a required one that fails or warns is a warning, and so is a clock that is not synchronised" '[ "$(run_lib "$FINE DASH_SRV_BAD=2 DASH_SRV_BAD_NAMES=\"Docker Engine, Disco libre\"; dash_srv_alerts; echo \"\${DASH_SRV_ALERTS[*]}\"")" = "err|req|2 requisitos obligatorios fallan: Docker Engine, Disco libre" ] && [ "$(run_lib "$FINE PR_STATUS[timesync]=info PR_SUMMARY[timesync]=\"\$(t prereq.time_off)\"; dash_srv_alerts; echo \"\${DASH_SRV_ALERTS[*]}\"")" = "warn|req|la hora no está sincronizada" ]'
check "the errors come first, the border of each box takes the worst colour of its warnings, and the vital signs line shows the first one and how many there are" '[ "$(run_lib "$FINE HOST_DISK_PCT=(86 22 97); HOST_LOAD1=9.5; dash_srv_alerts; echo \"\${DASH_SRV_ALERTS[0]%%|*} \${DASH_SRV_AL[disks]} \${DASH_SRV_AL[cpu]}\"")" = "err 2 1" ] && run_lib "$FINE HOST_DISK_PCT=(86 22 97); dash_srv_alerts; dash_srv_vitals 150; echo \"\$DASH_SRV_VIT\"" | grep -q "2 avisos: disco /var/backups al 97%"'
check "the vital signs line is never wider than its box: what does not fit is dropped from the right and the warnings are cut with …" 'for w in 40 60 80 120; do [ "$(run_lib "$FINE HOST_DISK_PCT=(86 22 97); dash_srv_alerts; dash_srv_vitals $w; tui_vlen \"\$DASH_SRV_VIT\"; echo \$TUI_VL")" = "$w" ] || exit 1; done'

section "15. the strip and the list of requirements"
check "the requirements are a strip; Enter opens the modal and Esc closes it" '[ "$(run_lib "$FINE dash_srv_listed && echo open0; scr_server_key enter; dash_srv_listed && echo open1; scr_server_back && echo back; dash_srv_listed && echo open2" | tr "\n" " ")" = "open1 back " ]'
check "it never opens by itself, whatever fails or warns: the strip keeps its three rows" '[ "$(run_lib "$FINE DASH_SRV_BAD=1; dash_srv_listed && echo a; DASH_SRV_BAD=0 DASH_SRV_RWARN=1; dash_srv_listed && echo b; DASH_SRV_RWARN=0 DASH_SRV_REC_PEND=3; dash_srv_listed && echo c; echo end" | tr "\n" " ")" = "end " ]'
check "with the strip, up and down do nothing (no requirement is shown) and ! is the command line; with the list open they move and ! asks first" '[ "$(run_lib "$FINE scr_server_key down; echo \$DASH_SRV_SEL; scr_server_bang; echo \$?; scr_server_key enter; scr_server_key down; echo \$DASH_SRV_SEL" | tr "\n" " ")" = "0 1 1 " ]'
check "Esc steps back one thing at a time: the zoom, the detail, the modal, the metrics view, and then it is not taken (the panel leaves)" '[ "$(run_lib "$FINE DASH_SRV_PZ=cpu DASH_SRV_OPEN=1 DASH_SRV_MODAL=1 DASH_SRV_ZOOM=1; for i in 1 2 3 4 5; do scr_server_back && echo \"\$DASH_SRV_PZ|\$DASH_SRV_OPEN|\$DASH_SRV_MODAL|\$DASH_SRV_ZOOM\" || echo leave; done" | tr "\n" " ")" = "|1|1|1 |0|1|1 |0|0|1 |0|0|0 leave " ]'
check "the box of the requirements in a zoom is the list, even with everything fine" 'run_lib "$FINE DASH_SRV_PZ=req; dash_render" | grep -q "OBLIGATORIOS"'

section "16. the focus, the zoom and the keys of each box"
RENDER160='COLUMNS=160; DELTACTL_TUI_ROWS=40; source tests/tools/server_scenes.sh; server_scene ok >/dev/null; '
check "the boxes on screen are the ring of Tab, in order, and Shift+Tab goes the other way" '[ "$(run_lib "$RENDER160 echo \${DASH_SRV_VIS[*]}; scr_server_tab 1; echo \$DASH_SRV_FOCUS; scr_server_tab 1; scr_server_tab 1; scr_server_tab 1; scr_server_tab 1; echo \$DASH_SRV_FOCUS; scr_server_tab 1; echo \$DASH_SRV_FOCUS; scr_server_tab -1; echo \$DASH_SRV_FOCUS" | tr "\n" " ")" = "req cpu mem disks net containers inst procs ports cpu containers inst containers " ]'
check "Tab walks the boxes in the panel too (it is not the next view here), and the focused box is the one with the marked chip" 'o="$(panel_ok 1 tab q)"; echo "$o" | frame_n 3 | grep -q "\\[1 Servidor\\]" && echo "$o" | frame_n 3 | grep -q ">cpu" && ! echo "$o" | frame_n 3 | grep -q ">requisitos"'
check "when the box that had the focus is not on screen the focus goes to the first one" '[ "$(run_lib "COLUMNS=160; DELTACTL_TUI_ROWS=30; source tests/tools/server_scenes.sh; server_scene ok >/dev/null; DASH_SRV_FOCUS=procs; dash_render >/dev/null; echo \$DASH_SRV_FOCUS")" = "req" ]'
check "the keys of the last line are those of the box that has the focus" 'for f in cpu mem disks net containers inst procs ports; do DELTACTL_LANG=es run_lib "$RENDER160 DASH_SRV_FOCUS=$f; scr_server_texts; DASH_KEYS_T=\"\${DASH_KEYS[server_$f]}\"; [ -n \"\$DASH_KEYS_T\" ] && ! echo \"\$DASH_KEYS_T\" | grep -q \"??\"" || exit 1; done; run_lib "$RENDER160 DASH_SRV_FOCUS=containers; scr_server_texts; echo \"\${DASH_KEYS[server_containers]}\"" | grep -q "l logs · s orden · h no creados"'
check "z zooms the box that has the focus (every other box goes) and Esc or z brings them back" '[ "$(run_lib "$RENDER160 DASH_SRV_FOCUS=net; scr_server_key z; echo \$DASH_SRV_PZ; dash_render >/dev/null; echo \${DASH_SRV_VIS[*]}; scr_server_back; echo [\$DASH_SRV_PZ]; scr_server_key z; scr_server_key z; echo [\$DASH_SRV_PZ]" | tr "\n" " ")" = "net net [] [] " ]'
check "the zoom shows what the box does not have room for: every interface and the sockets (net), every disk and its busy time (disks), the pids of each container (containers)" 'f1="$FIX/frames/zoom-net.txt"; run_lib "$RENDER160 DASH_SRV_FOCUS=net DASH_SRV_PZ=net; dash_render" > "$f1"; grep -q "wlan0" "$f1" && grep -q "enp3s0 " "$f1"; ! run_lib "$RENDER160 dash_render" | grep -q "wlan0" && run_lib "$RENDER160 DASH_SRV_FOCUS=containers DASH_SRV_PZ=containers; dash_render" | grep -q "PIDS" && run_lib "$RENDER160 DASH_SRV_FOCUS=disks DASH_SRV_PZ=disks; dash_render" | grep -q "sdb "'
check "m (only the figures) drops the zoom and z drops the detail of a requirement" '[ "$(run_lib "$RENDER160 DASH_SRV_PZ=cpu; scr_server_key m; echo [\$DASH_SRV_PZ]\$DASH_SRV_ZOOM; DASH_SRV_OPEN=1; scr_server_key z; echo \$DASH_SRV_OPEN" | tr "\n" " ")" = "[]1 0 " ]'
check "the signature of the view carries the state of every box (a missing value is a stale screen)" 'for v in "DASH_SRV_FOCUS=cpu" "DASH_SRV_PZ=cpu" "DASH_SRV_CSEL=3" "DASH_SRV_SHOW_NC=1" "DASH_RES_SORT=mem" "DASH_SRV_PSEL=2" "DASH_SRV_TSEL=2" "DASH_SRV_PS_STATE=ready" "DASH_SRV_SS_STATE=ready" "DASH_SRV_MODAL=1" "DASH_SRV_SEL=4"; do [ "$(run_lib "DASH_SIG=; scr_server_sig; a=\$DASH_SIG; $v; DASH_SIG=; scr_server_sig; [ \"\$a\" != \"\$DASH_SIG\" ] && echo diff")" = "diff" ] || { echo "$v"; exit 1; }; done'
check "every box has its key (what it draws) and its function, and a box is kept while its key is the same" 'run_lib "for b in req cpu mem disks net containers inst procs ports; do declare -F dash_srv_key_\$b >/dev/null && declare -F dash_srv_\$b >/dev/null || [ \$b = req ] || exit 1; done; declare -F dash_srv_key_req >/dev/null"'
check "a graph is the cached one: a new sample moves it a cell (kit_graph_cached), and the history of the server holds 240 samples" 'grep -c "kit_graph_cached" lib/screens/server_boxes.sh | grep -qE "^[3-9]" && ! grep -qE "kit_graph [a-z\$]" lib/screens/server_boxes.sh && [ "$(run_lib "echo \$MT_HOST_HIST_LEN")" = "240" ]'

section "17. the containers: cursor, Enter, logs, sort, the ones not created"
MANY='COLUMNS=160; DELTACTL_TUI_ROWS=40; source tests/tools/server_scenes.sh; server_scene many-containers >/dev/null; '
check "the cursor moves, stops at the ends and the window follows it (the 40th container is on screen at the end)" '[ "$(run_lib "$MANY scr_server_key end; dash_render >/dev/null; echo \$DASH_SRV_CSEL \$DASH_SRV_CTOP; scr_server_key home; dash_render >/dev/null; echo \$DASH_SRV_CSEL \$DASH_SRV_CTOP; scr_server_key up; echo \$DASH_SRV_CSEL" | tr "\n" " ")" = "38 21 0 0 0 " ] || [ "$(run_lib "$MANY scr_server_key end; echo \$DASH_SRV_CSEL")" = "38" ]'
check "the services that were never created are folded (+1 no creados) and h lists them" '[ "$(run_lib "$MANY dash_srv_crows; echo \${#DASH_SRV_CK[@]} \$DASH_SRV_NC; scr_server_key h; dash_srv_crows; echo \${#DASH_SRV_CK[@]}" | tr "\n" " ")" = "39 1 40 " ]'
check "Enter opens the instance with the cursor on that service (the Instances view, as the Resources view does)" '[ "$(run_lib "$MANY DASH_SRV_CSEL=6; dash_srv_crows; scr_server_key enter; echo \$DASH_VIEW \$DASH_SEL \$DASH_SVC \$DASH_FOCUS" | tr "\n" " ")" = "instances 1 2 svc " ]'
check "l goes on to the logs of the service (the panel of the instance that has them), and the zoom is left" 'run_lib "$MANY DASH_SRV_PZ=containers; dash_srv_crows; scr_server_key l; echo \$DASH_VIEW [\$DASH_SRV_PZ]" | grep -q "instances \[\]"'
check "the shared function is the one the Resources view uses (one place decides what opening a service means)" 'grep -q "dash_res_open_key" lib/screens/resources.sh && grep -q "dash_res_open_key" lib/screens/server_view.sh && [ "$(run_lib "$MANY DASH_NAMES=(a b); DASH_SVCS[a]=\"s0 s1\"; DASH_SVCS[b]=\"s0 s1\"; dash_res_open_key b/s1; echo \$DASH_SEL \$DASH_SVC \$DASH_VIEW; dash_res_open_key nothing/s9; echo \$?")" = "$(printf "1 1 instances\n0")" ]'
check "s sorts the containers like the Resources view (name, memory, CPU): by memory the biggest is first" '[ "$(run_lib "COLUMNS=160; DELTACTL_TUI_ROWS=40; source tests/tools/server_scenes.sh; server_scene focus-containers >/dev/null; scr_server_key s; dash_srv_crows; echo \$DASH_RES_SORT \${DASH_SRV_CK[0]}; scr_server_key s; scr_server_key s; echo \$DASH_RES_SORT" | tr "\n" " ")" = "mem piura/s1 name " ]'
check "only the rows in view are built (the spark of 40 containers is drawn for the 17 on screen, not for all)" '[ "$(run_lib "$MANY n=0; fn=\"\$(declare -f mt_spark_v)\"; eval \"\${fn/mt_spark_v/mt_spark_v_orig}\"; mt_spark_v() { n=\$((n + 1)); mt_spark_v_orig \"\$@\"; }; dash_render >/dev/null; [ \$n -le 40 ] && echo few")" = "few" ]'
check "the cursor is marked (it is seen with no colours too) only while the box has the focus" 'run_lib "$MANY DASH_SRV_FOCUS=containers DASH_SRV_CSEL=3; dash_render" | grep -q "> s[0-3] " && ! run_lib "$MANY DASH_SRV_FOCUS=req; dash_render" | grep -q "> s[0-3] "'

section "18. the mouse (off by default): focus, rows and the wheel"
check "a click gives the box under it the focus; a click on the strip opens the modal of requirements" '[ "$(run_lib "$RENDER160 read -r x y w h <<< \"\${DASH_SRV_RECT[cpu]}\"; scr_server_click \$((x + 3)) \$((y + 3)); echo \$DASH_SRV_FOCUS; read -r x y w h <<< \"\${DASH_SRV_RECT[req]}\"; scr_server_click \$((x + 3)) \$((y + 1)); echo \$DASH_SRV_FOCUS \$DASH_SRV_MODAL; scr_server_click \$((x + 3)) \$((y + 1)); echo \$DASH_SRV_MODAL" | tr "\n" " ")" = "cpu req 0 1 " ]'
check "a click on a container puts the cursor on it and a second click on it does what Enter does" '[ "$(run_lib "$MANY DASH_SRV_CSEL=0 DASH_SRV_CTOP=0; dash_render >/dev/null; DASH_SRV_FOCUS=containers; read -r x y w h <<< \"\${DASH_SRV_RECT[containers]}\"; scr_server_click \$((x + 5)) \$((y + 2 + 4)); echo \$DASH_SRV_CSEL \$DASH_VIEW; scr_server_click \$((x + 5)) \$((y + 2 + 4)); echo \$DASH_VIEW" | tr "\n" " ")" = "4 server instances " ]'
check "a click on a requirement of the list selects it, and on the selected one opens its detail" '[ "$(run_lib "COLUMNS=160; DELTACTL_TUI_ROWS=40; source tests/tools/server_scenes.sh; server_scene modal >/dev/null; DASH_SRV_FOCUS=req; read -r x y w h <<< \"\${DASH_SRV_RECT[req]}\"; scr_server_click \$((x + 4)) \$((y + 6)); echo \$DASH_SRV_SEL \$DASH_SRV_OPEN; scr_server_click \$((x + 4)) \$((y + 6)); echo \$DASH_SRV_OPEN" | tr "\n" " ")" = "2 0 1 " ]'
check "the wheel moves the cursor of the box that has the focus (the box under the pointer takes the focus first), like the arrows" '[ "$(run_lib "$MANY DASH_SRV_CSEL=0 DASH_SRV_CTOP=0; dash_render >/dev/null; read -r x y w h <<< \"\${DASH_SRV_RECT[containers]}\"; scr_server_wheel 65 \$((x + 5)) \$((y + 3)); scr_server_wheel 65 \$((x + 5)) \$((y + 3)); scr_server_wheel 64 \$((x + 5)) \$((y + 3)); echo \$DASH_SRV_FOCUS \$DASH_SRV_CSEL")" = "containers 1" ]'
check "the click and the wheel are the screen hooks of the registry (a view with them handles the mouse itself)" 'run_lib "declare -F scr_server_click >/dev/null && declare -F scr_server_wheel >/dev/null"'

section "19. the busiest processes and the ports that listen: in the background, only while their box is on screen"
cat > "$FIX/fake-ps" <<'EOS'
#!/bin/sh
echo x >> "$FIX/ps.calls"
printf '  1412 mongodb   14.2  8.1 mongod\n  2231 root      11.8  3.4 node\n     1 root       0.0  0.0 systemd\n'
EOS
cat > "$FIX/fake-ss" <<'EOS'
#!/bin/sh
echo x >> "$FIX/ss.calls"
cat <<'TXT'
State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0      4096         0.0.0.0:80        0.0.0.0:*     users:(("nginx",pid=907,fd=6))
LISTEN 0      4096            [::]:80           [::]:*     users:(("nginx",pid=907,fd=7))
LISTEN 0      128        127.0.0.1:27017     0.0.0.0:*     users:(("mongod",pid=1412,fd=14))
LISTEN 0      4096         0.0.0.0:4100      0.0.0.0:*
TXT
EOS
printf '#!/bin/sh\nsleep 20\n' > "$FIX/slow-ps"
chmod +x "$FIX/fake-ps" "$FIX/fake-ss" "$FIX/slow-ps"
check "ps: the producer prints the busiest processes as lines (pid user cpu mem command)" '[ "$(DELTACTL_PS="$FIX/fake-ps" run_lib "dash_srv_ps_dump | head -1")" = "  1412 mongodb   14.2  8.1 mongod" ] && [ "$(DELTACTL_PS="$FIX/fake-ps" run_lib "dash_srv_ps_dump | wc -l")" = "3" ]'
check "ss: the producer prints the ports that listen once each, in order, with the process that owns them" '[ "$(DELTACTL_SS="$FIX/fake-ss" run_lib "dash_srv_ss_dump" | tr "\n" " ")" = "80|0.0.0.0|nginx|0 4100|0.0.0.0||0 27017|127.0.0.1|mongod|0 " ]'
check "without ps or ss (a server that has neither) the producer says NA and the box says it is not available" '[ "$(DELTACTL_PS="$FIX/none" run_lib "dash_srv_ps_dump")" = "NA" ] && [ "$(DELTACTL_SS="$FIX/none" run_lib "dash_srv_ss_dump")" = "NA" ] && DELTACTL_PS="$FIX/none" run_lib "$RENDER160 DASH_SRV_PS_STATE=none; dash_srv_ps_apply NA; DASH_SRV_FOCUS=procs DASH_SRV_PZ=procs; dash_render" | grep -q "no disponible en este sistema"'
check "a ps that hangs is cut by the time limit and the answer is NA (it never freezes the panel)" 's=$SECONDS; r="$(DELTACTL_PS="$FIX/slow-ps" run_lib "dash_srv_ps_dump")"; [ "$r" = "NA" ] && [ $((SECONDS - s)) -le 8 ]'
check "the processes box lists them with the cursor; the ports box says which port is an instance's (the ports of DSV_PORT)" 'run_lib "$RENDER160 dash_srv_ps_apply \"\$(DELTACTL_PS=$FIX/fake-ps dash_srv_ps_dump)\"; DASH_SRV_FOCUS=procs DASH_SRV_PZ=procs; dash_render" | grep -q "mongodb .*mongod" && run_lib "$RENDER160 DASH_SRV_SS_STATE=ready DASH_SRV_SS_RAW=\"\$(DELTACTL_SS=$FIX/fake-ss dash_srv_ss_dump)\"; DASH_SRV_FOCUS=ports DASH_SRV_PZ=ports; dash_render" | grep -qE "4100 +0.0.0.0 +- +0 +colorado/s0"'
rm -f "$FIX/ps.calls" "$FIX/ss.calls"
check "the producer is asked only while its box is on screen and the view is the current one" '[ "$(DELTACTL_PS="$FIX/fake-ps" DELTACTL_SS="$FIX/fake-ss" run_lib "DASH_VIEW=server; DASH_SRV_VIS=(cpu mem); scr_server_tick; DASH_VIEW=instances; DASH_SRV_VIS=(procs ports); scr_server_tick; echo \$DASH_SRV_PS_STATE \$DASH_SRV_SS_STATE; ls $FIX/ps.calls $FIX/ss.calls 2>/dev/null | wc -l")" = "$(printf "none none\n0")" ]'
check "with the boxes on screen they are asked at once, and not again before the time limit (5 s for ps, 15 s for ss)" 'rm -f "$FIX/ps.calls" "$FIX/ss.calls"; DELTACTL_PS="$FIX/fake-ps" DELTACTL_SS="$FIX/fake-ss" run_lib "DASH_VIEW=server; DASH_SRV_VIS=(procs ports); scr_server_tick; scr_server_tick; scr_server_tick; DASH_SRV_PS_AT=\$((SECONDS - 6)); DASH_SRV_SS_AT=\$((SECONDS - 6)); scr_server_tick" >/dev/null; [ "$(wc -l < "$FIX/ps.calls")" = "2" ] && [ "$(wc -l < "$FIX/ss.calls")" = "2" ]'
check "the interval is DELTACTL_PS_TTL / DELTACTL_SS_TTL, kept between 5 and 60 seconds (anything else is the default)" '[ "$(for v in 1 30 99 abc ""; do DELTACTL_PS_TTL="$v" run_lib "dash_srv_ttl DELTACTL_PS_TTL 5; echo \$DASH_THR"; done | tr "\n" " ")" = "5 30 5 5 5 " ] && [ "$(DELTACTL_SS_TTL=60 run_lib "dash_srv_ttl DELTACTL_SS_TTL 15; echo \$DASH_THR")" = "60" ]'
check "the producers are the only programs of the Server view: the boxes and the screen start no process" '! grep -vE "^\s*#" lib/screens/server_boxes.sh lib/screens/server_view.sh | grep -qE "\\$\(\s*(ps|ss|df|awk|sed|grep|cut|tr|cat|date|sort|head)\b|\| *(sort|head|awk|sed)\b"'
check "in the real panel the answer arrives on a later turn (a background job), and with the box off screen nothing runs" '[ "$(DELTACTL_PS="$FIX/fake-ps" run_lib "unset DELTACTL_TUI_KEYS; dash_init; DASH_VIEW=server; DASH_SRV_VIS=(procs); scr_server_tick; a=\$DASH_SRV_PS_STATE; for i in \$(seq 1 40); do scr_server_tick; [ \$DASH_SRV_PS_STATE = ready ] && break; sleep 0.2; done; echo \$a \$DASH_SRV_PS_STATE; dash_async_stop")" = "none ready" ]'

section "20. the instances: what each one costs the server (their services added up), the limits that hurt and the size of their folder"
RENDER200='COLUMNS=200; DELTACTL_TUI_ROWS=55; source tests/tools/server_scenes.sh; server_scene ok >/dev/null; '
check "the instances box is in the third row from 32 rows of body, with each instance's services running, CPU and memory added up" 'f="$FIX/frames/ok-200x55-es.txt"; grep -q "┐instancias┌" "$f" && grep -qE "colorado +2/2 +44.9% .*1.3G/2.5G" "$f" && grep -qE "piura +1/2 +89.8% .*1.9G/2.5G" "$f" && ! grep -q "┐instancias┌" "$FIX/frames/ok-120x30-es.txt"'
scene alert 240 50 es > "$FIX/frames/alert-240x50-es.txt"
check "wide, the box adds the disk and the network of each instance, the size of its folder, its limits (CPU held back, memory kills) and the service that weighs most" 'f="$FIX/frames/alert-240x50-es.txt"; grep -qE "DISCO +DATOS +RED +LÍMITES +MAYOR" "$f" && grep -qE "piura .* 4.00 GiB .* cpu 40% oom 2 +s1" "$f" && grep -qE "colorado .* 12 GiB .* -  +s1" "$f"'
check "a container held back by its CPU limit (25 % of the periods, DELTACTL_ALERT_THROTTLE) or with processes killed for lack of memory is a warning of the instances box" '[ "$(run_lib "$FINE MT_THR[piura/s1]=40 MT_OOM[piura/s1]=2; dash_srv_alerts; printf \"%s\n\" \"\${DASH_SRV_ALERTS[@]}\" | grep -c \"|inst|\"")" = "2" ] && run_lib "$FINE MT_THR[piura/s1]=40; dash_srv_alerts; printf \"%s\n\" \"\${DASH_SRV_ALERTS[@]}\"" | grep -q "warn|inst|piura/s1 limitado de CPU: 40% de los periodos" && run_lib "$FINE MT_OOM[piura/s1]=2; dash_srv_alerts; printf \"%s\n\" \"\${DASH_SRV_ALERTS[@]}\"" | grep -q "warn|inst|piura/s1: 2 procesos matados por falta de memoria" && [ "$(DELTACTL_ALERT_THROTTLE=50 run_lib "$FINE MT_THR[piura/s1]=40; dash_srv_alerts; printf \"%s\n\" \"\${DASH_SRV_ALERTS[@]}\" | grep -c \"|inst|\"")" = "0" ]'
check "the cursor moves in the instances (it stops at the ends) and Enter opens the instance on its first service" '[ "$(run_lib "$RENDER200 DASH_SRV_FOCUS=inst; scr_server_key up; echo \$DASH_SRV_ISEL; scr_server_key down; scr_server_key down; echo \$DASH_SRV_ISEL; scr_server_key enter; echo \$DASH_VIEW \$DASH_SEL \$DASH_SVC" | tr "\n" " ")" = "0 1 instances 1 0 " ]'
check "a click on an instance puts the cursor on it and a second click opens it" '[ "$(run_lib "$RENDER200 DASH_SRV_FOCUS=inst; read -r x y w h <<< \"\${DASH_SRV_RECT[inst]}\"; scr_server_click \$((x + 5)) \$((y + 3)); echo \$DASH_SRV_ISEL \$DASH_VIEW; scr_server_click \$((x + 5)) \$((y + 3)); echo \$DASH_VIEW" | tr "\n" " ")" = "1 server instances " ]'
check "the containers table adds the disk and the network of each container from 150 cells (the whole row: 200 columns and more)" 'grep -qE "DISCO +RED" "$FIX/frames/ok-200x55-es.txt" && grep -qE "s1 +colorado .* 1M/512K +256K/128K" "$FIX/frames/ok-200x55-es.txt" && ! grep -q "DISCO" "$FIX/frames/ok-120x30-es.txt"'
mkdir -p "$FIX/inst/alfa" "$FIX/inst/beta"
printf '#!/bin/sh\necho x >> "$FIX/du.calls"\nprintf "123\\t%%s\\n" "$2"\n' > "$FIX/fake-du"; chmod +x "$FIX/fake-du"
check "du: the producer prints the size in kilobytes of the folder of each instance (a du that fails leaves that instance out); the answer is read into DASH_SRV_DU" '[ "$(DELTACTL_DU="$FIX/fake-du" run_lib "INSTANCES_DIR=$FIX/inst; dash_srv_du_dump" | tr "\n" " ")" = "alfa|123 beta|123 " ] && [ "$(DELTACTL_DU="$FIX/none" run_lib "INSTANCES_DIR=$FIX/inst; dash_srv_du_dump" | wc -l)" = "0" ] && [ "$(run_lib "dash_srv_du_apply \"\$(printf \"alfa|123\nbeta|x\n\")\"; echo \${DASH_SRV_DU[alfa]} [\${DASH_SRV_DU[beta]:-}]")" = "123 []" ]'
rm -f "$FIX/du.calls"
check "du runs only while the instances box is on screen, at once and not again before DELTACTL_DU_TTL (300 s by default, from 60 to 3600)" '[ "$(DELTACTL_DU="$FIX/fake-du" run_lib "INSTANCES_DIR=$FIX/inst; DASH_VIEW=server; DASH_SRV_VIS=(cpu); scr_server_tick; ls $FIX/du.calls 2>/dev/null | wc -l; DASH_SRV_VIS=(inst); scr_server_tick; scr_server_tick; wc -l < $FIX/du.calls | tr -d \" \"" | tr "\n" " ")" = "0 2 " ] && [ "$(for v in 10 600 9999 abc; do DELTACTL_DU_TTL="$v" run_lib "dash_srv_ttl DELTACTL_DU_TTL 300 60 3600; echo \$DASH_THR"; done | tr "\n" " ")" = "300 600 300 300 " ]'
printf '#!/bin/sh\ncase "$*" in\n  *established*) printf "0 0 10.0.0.1:4100 9.9.9.9:1000\\n0 0 10.0.0.1:4100 9.9.9.9:1001\\n0 0 10.0.0.1:80 9.9.9.9:1002\\n" ;;\n  *) printf "State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\\nLISTEN 0 4096 0.0.0.0:80 0.0.0.0:* users:((\\"nginx\\",pid=907,fd=6))\\nLISTEN 0 4096 0.0.0.0:4100 0.0.0.0:*\\n" ;;\nesac\n' > "$FIX/fake-ss2"; chmod +x "$FIX/fake-ss2"
check "ports: the producer adds the connections open on each port (a second ss call, established ones only); the box shows them in a CONEX column" '[ "$(DELTACTL_SS="$FIX/fake-ss2" run_lib "dash_srv_ss_dump" | tr "\n" " ")" = "80|0.0.0.0|nginx|1 4100|0.0.0.0||2 " ] && grep -qE "4100 +0.0.0.0 +docker-proxy +12 +colorado/s0" "$FIX/frames/wide-250x70-es.txt" && grep -qE "PUERTO +DIRECCIÓN +PROCESO +CONEX +SERVICIO" "$FIX/frames/wide-250x70-es.txt"'
mkdir -p "$FIX/proc/1412" "$FIX/cg/system.slice/docker-abc.scope"
echo "0::/system.slice/docker-abc.scope" > "$FIX/proc/1412/cgroup"
check "processes: a process that runs in the cgroup of a container says which one (instance/service); the others are the server's own" 'o="$(DELTACTL_PS="$FIX/fake-ps" run_lib "$RENDER160 dash_srv_ps_apply \"\$(DELTACTL_PS=$FIX/fake-ps dash_srv_ps_dump)\"; MT_CG_MEMDIR[colorado/s0]=$FIX/cg/system.slice/docker-abc.scope; DASH_SRV_FOCUS=procs DASH_SRV_PZ=procs; dash_render")"; echo "$o" | grep -qE "1412 +mongodb .* colorado/s0 +mongod" && echo "$o" | grep -qE "2231 +root .* servidor +node" && echo "$o" | grep -q "ORIGEN"'

section "21. keys in a burst and work that waits for the view to settle"
check "tui_pending only looks at the input: true with a key waiting, false with none, and the key is still there to be read" '[ "$(ROOT="$PWD" DELTACTL_CONFIG="$CFG" bash -c "source lib/bootstrap.sh; source lib/cmd/dashboard.sh; tui_pending && echo yes; IFS= read -rsn1 k; echo \$k" < <(printf x) 2>&1 | tr "\n" " ")" = "yes x " ] && [ "$(ROOT="$PWD" DELTACTL_CONFIG="$CFG" bash -c "source lib/bootstrap.sh; source lib/cmd/dashboard.sh; tui_pending && echo yes || echo no" < <(sleep 1) 2>&1)" = "no" ]'
SKIP='source lib/bootstrap.sh; source lib/cmd/dashboard.sh; HOST_FAKE_NOW_US=1000000;'
check "a key that comes while another is waiting is handled before drawing, unless the last drawing was 100 ms ago or more, or DELTACTL_COALESCE=0" '[ "$(env -u DELTACTL_TUI_KEYS ROOT="$PWD" DELTACTL_CONFIG="$CFG" bash -c "$SKIP DASH_DRAW_US=950000; dash_skip_draw && echo skip || echo draw; DASH_DRAW_US=800000; dash_skip_draw && echo skip2 || echo draw2" < <(printf xx) 2>&1 | tr "\n" " ")" = "skip draw2 " ] && [ "$(env -u DELTACTL_TUI_KEYS ROOT="$PWD" DELTACTL_CONFIG="$CFG" DELTACTL_COALESCE=0 bash -c "$SKIP DASH_DRAW_US=950000; dash_skip_draw && echo skip || echo draw" < <(printf xx) 2>&1)" = "draw" ]'
check "with nothing waiting a key is drawn at once (a single key never waits), and in the test mode nothing is skipped" '[ "$(env -u DELTACTL_TUI_KEYS ROOT="$PWD" DELTACTL_CONFIG="$CFG" bash -c "$SKIP DASH_DRAW_US=950000; dash_skip_draw && echo skip || echo draw" < <(sleep 1) 2>&1)" = "draw" ] && [ "$(run_lib "HOST_FAKE_NOW_US=1000000; DASH_DRAW_US=950000; dash_skip_draw && echo skip || echo draw" < <(printf xx))" = "draw" ]'
check "a view counts as settled after DELTACTL_DWELL_MS (500 by default) as the current one; changing view starts the count again" '[ "$(DELTACTL_DWELL_MS=500 run_lib "HOST_FAKE_NOW_US=1000000; DASH_VIEW=server; dash_dwell_update; HOST_FAKE_NOW_US=1200000; dash_dwelled && echo a || echo b; HOST_FAKE_NOW_US=1600000; dash_dwelled && echo c || echo d; DASH_VIEW=images; HOST_FAKE_NOW_US=1700000; dash_dwell_update; HOST_FAKE_NOW_US=1800000; dash_dwelled && echo e || echo f" | tr "\n" " ")" = "b c f " ]'
check "0 turns the wait off, a value that is not a number is the default, and the test mode has no wait unless the variable is set" '[ "$(DELTACTL_DWELL_MS=0 run_lib "HOST_FAKE_NOW_US=1000000; DASH_VIEW=server; dash_dwell_update; dash_dwelled && echo a || echo b")" = "a" ] && [ "$(DELTACTL_DWELL_MS=abc run_lib "HOST_FAKE_NOW_US=1000000; DASH_VIEW=server; dash_dwell_update; HOST_FAKE_NOW_US=1100000; dash_dwelled && echo a || echo b")" = "b" ] && [ "$(run_lib "HOST_FAKE_NOW_US=1000000; DASH_VIEW=server; dash_dwell_update; dash_dwelled && echo a || echo b")" = "a" ]'
check "the Server view starts nothing while it has not settled (no detailed readings, no check) and starts it all once it has; leaving stops the readings at once" '[ "$(PATH="$FIX/nopath" DELTACTL_DWELL_MS=500 run_lib "HOST_FAKE_NOW_US=1000000; DASH_VIEW=server; dash_dwell_update; scr_server_enter; scr_server_tick; echo \$MT_HOST_DETAIL \$DASH_SRV_STATE; HOST_FAKE_NOW_US=1600000; scr_server_tick; echo \$MT_HOST_DETAIL \$DASH_SRV_STATE; DASH_VIEW=images; scr_server_tick; echo \$MT_HOST_DETAIL" | tr "\n" " ")" = "0 none 1 ready 0 " ]'
rm -f "$FIX/ps.calls" "$FIX/ss.calls" "$FIX/du.calls"
check "the processes, the ports and the folders are not asked for until the view has settled" '[ "$(DELTACTL_DWELL_MS=500 DELTACTL_PS="$FIX/fake-ps" DELTACTL_SS="$FIX/fake-ss" DELTACTL_DU="$FIX/fake-du" run_lib "INSTANCES_DIR=$FIX/inst; HOST_FAKE_NOW_US=1000000; DASH_VIEW=server; dash_dwell_update; DASH_SRV_VIS=(procs ports inst); scr_server_tick; ls $FIX/ps.calls $FIX/ss.calls $FIX/du.calls 2>/dev/null | wc -l; HOST_FAKE_NOW_US=1600000; scr_server_tick; ls $FIX/ps.calls $FIX/ss.calls $FIX/du.calls 2>/dev/null | wc -l" | tr "\n" " ")" = "0 3 " ]'
check "the Images view reads the catalog on the first tick after it has settled, not when it is chosen" '[ "$(PATH="$FIX/bin:$PATH" DELTACTL_DWELL_MS=500 run_lib "HOST_FAKE_NOW_US=1000000; DASH_VIEW=images; dash_dwell_update; scr_images_enter; scr_images_tick; echo \$DASH_IMG_STATE; HOST_FAKE_NOW_US=1600000; scr_images_tick; echo \$DASH_IMG_STATE" | tr "\n" " ")" = "none ready " ] || [ "$(PATH="$FIX/bin:$PATH" DELTACTL_DWELL_MS=500 run_lib "HOST_FAKE_NOW_US=1000000; DASH_VIEW=images; dash_dwell_update; scr_images_enter; scr_images_tick; echo \$DASH_IMG_STATE; HOST_FAKE_NOW_US=1600000; scr_images_tick; [ \$DASH_IMG_STATE != none ] && echo started" | tr "\n" " ")" = "none started " ]'

section "22. walking the requirements list is cheap: what does not change is built once"
check "the modal is laid over the body with slices of the base kept by row (the same state twice draws the same lines, another selection draws other ones, and the slices were kept)" '[ "$(run_lib "$RENDER160 DASH_SRV_MODAL=1; dash_render > $FIX/m1.txt; DASH_SRV_SEL=5; dash_render > $FIX/m2.txt; DASH_SRV_SEL=0; dash_render > $FIX/m3.txt; cmp -s <(tail -n +2 $FIX/m1.txt) <(tail -n +2 $FIX/m3.txt) && ! cmp -s <(tail -n +2 $FIX/m1.txt) <(tail -n +2 $FIX/m2.txt) && [ \${#DASH_SRV_OVW[@]} -gt 0 ] && echo ok")" = "ok" ]'
check "the rows that are not selected and the detail of each requirement are built once: moving the cursor and coming back draws exactly the same, and a new answer builds the rows again" '[ "$(run_lib "$RENDER160 DASH_SRV_MODAL=1 DASH_SRV_SEL=3; dash_render > $FIX/d1.txt; n1=\${#DASH_SRV_ROWC[@]} m1=\${#DASH_SRV_DETC[@]}; DASH_SRV_SEL=4; dash_render >/dev/null; DASH_SRV_SEL=3; dash_render > $FIX/d2.txt; cmp -s <(tail -n +2 $FIX/d1.txt) <(tail -n +2 $FIX/d2.txt) && echo same; echo \$((\${#DASH_SRV_ROWC[@]} >= n1 && n1 > 0)) \$((\${#DASH_SRV_DETC[@]} >= m1 && m1 > 0)); DASH_SRV_N=\$((DASH_SRV_N + 1)); k=\${#DASH_SRV_ROWC[@]}; dash_render >/dev/null; echo \$((\${#DASH_SRV_ROWC[@]} > k))" | tr "\n" " ")" = "same 1 1 1 " ]'
check "the strip box does not depend on which requirement is selected (it is kept while the cursor moves in the modal), but the zoomed list does" '[ "$(run_lib "$RENDER160 DASH_SRV_SEL=1; dash_srv_key_req; a=\$DASH_SRV_KEYV; DASH_SRV_SEL=4; dash_srv_key_req; b=\$DASH_SRV_KEYV; DASH_SRV_PZ=req; dash_srv_key_req; c=\$DASH_SRV_KEYV; DASH_SRV_SEL=1; dash_srv_key_req; [ \"\$a\" = \"\$b\" ] && [ \"\$c\" != \"\$DASH_SRV_KEYV\" ] && echo ok")" = "ok" ]'

finish

#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2046  # the cases go in single quotes and are evaluated with eval
# The interpreter of what a command printed (lib/core/outparse.sh) and the summary the Output view draws with it (lib/ui/outsummary.sh,
# lib/screens/output.sh): what is recognised (new, check, deploy, init, doctor, images, env) in Spanish and in English, what is not (it stays raw,
# without an error), that nothing is added to what the command printed, that the raw text is untouched and one key away, that the summary is built once
# per output and size, the keys of the view and the golden snapshots of its scenes (tests/tools/outsum_scenes.sh) at 80x24, 120x30 and 160x40.
# The outputs are real ones, captured from the simulated docker by tests/tools/outsum_capture.sh (tests/golden/outsum/in/<scene>-<lang>.txt).
# Snapshots: tests/golden/outsum/<scene>-<cols>x<rows>-<lang>.txt. DELTACTL_GOLDEN=record rewrites them (only when a change is intended).
# No real Docker: the simulated docker answers, and nothing is deployed. Run it from the root of the isolated copy (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8 LC_ALL=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS DELTACTL_TUI_KEYS DELTACTL_TUI_EVENTS DELTACTL_TUI_ROWS DELTACTL_THEME DELTACTL_WIZARD
unset DELTACTL_REFRESH DELTACTL_METRICS_INTERVAL DELTACTL_TUI_IDLE_AFTER DELTACTL_TUI_GATE DELTACTL_CLIP DELTACTL_PR_SHELL DELTACTL_GRAPH TUI_GRAPH

FIX="$(mktemp -d)"
export FIX
CFG="$FIX/config"
trap 'rm -rf "$FIX" instances/os-*' EXIT
rm -rf instances/os-*
mkdir -p "$FIX/bin" "$FIX/frames"
: > "$FIX/containers.txt"; : > "$FIX/stats.txt"; : > "$FIX/calls.log"
cp tests/fake-docker.sh "$FIX/bin/docker-fake"
printf '#!/usr/bin/env bash\nexec bash "%s/bin/docker-fake" "$@"\n' "$FIX" > "$FIX/bin/docker"
printf '#!/bin/sh\nexit 0\n' > "$FIX/bin/ss"
chmod +x "$FIX/bin/docker" "$FIX/bin/ss"
export DELTACTL_MEMINFO="$FIX/meminfo" DELTACTL_LOADAVG="$FIX/loadavg" DELTACTL_PROC_ROOT="$FIX/proc" DELTACTL_CGROUP_ROOT="$FIX/cg"
printf 'MemTotal:        8388608 kB\nMemAvailable:    3145728 kB\n' > "$FIX/meminfo"
printf '0.82 0.50 0.40 1/200 1234\n' > "$FIX/loadavg"
printf 'auth-backend:1.0|sha256:aaa111|amd64\ngueo-back-end:1.0|sha256:bbb222|amd64\n' > "$FIX/images.txt"
# shellcheck source=tests/tools/outsum_scenes.sh
source tests/tools/outsum_scenes.sh

IN=tests/golden/outsum/in
KEYS="$FIX/keys.txt"
panel() { printf '%s\n' "$@" > "$KEYS"; PATH="$FIX/bin:$PATH" DELTACTL_CONFIG="$CFG" DELTACTL_TUI_KEYS="$KEYS" DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_LANG="${LANGX:-es}" COLUMNS="${PANEL_COLS:-110}" DELTACTL_TUI_ROWS="${PANEL_ROWS:-34}" bash ./deltactl 2>&1; }
last_frame() { awk '/^=== frame /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }'; }
typed() { local s="$1" i c; for ((i = 0; i < ${#s}; i++)); do c="${s:i:1}"; if [ "$c" = " " ]; then echo space; else echo "$c"; fi; done; }
# The library: the panel loaded, nothing drawn. $1 runs after `parse <file> <command-line> [running] [rc]` is defined.
run_lib() {
  PATH="$FIX/bin:$PATH" ROOT="$PWD" DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_LANG="${LANGX:-es}" COLUMNS=110 DELTACTL_CONFIG="$CFG" \
    bash -c 'source lib/bootstrap.sh; source lib/cmd/dashboard.sh; parse() { mapfile -t L < "'"$IN"'/$1"; out_parse L "$2" "${3:-0}" "${4-}"; }; rows() { local t=$1 i n=0; for i in "${!OUT_R_TYPE[@]}"; do [ "${OUT_R_TYPE[i]}" = "$t" ] && n=$((n + 1)); done; echo $n; }; '"$1" 2>&1
}

section "1. what is recognised: every command that has a shape, in both languages"
for lang in es en; do
  for k in "new:new colorado" "check-ok:check sim-01" "check-fail:check sim-01" "deploy:deploy sim-01" "deploy-fail:deploy sim-01" "init:init sim-01" "doctor:doctor" "images:images" "env:env sim-01 list"; do
    f="${k%%:*}" c="${k#*:}"
    check "$f ($lang) is recognised as the output of ${c%% *}" '[ "$(LANGX='"$lang"' run_lib "parse '"$f-$lang"'.txt \"'"$c"'\" && echo \$OUT_OK \$OUT_KIND")" = "1 '"${c%% *}"'" ]'
  done
done
check "new: the result, the 4 things to complete, the 5 steps and what they are under" '[ "$(run_lib "parse new-es.txt \"new colorado\"; echo \"\$OUT_HEAD_STATE|\$OUT_CNT_WARN|\$(rows num)|\$(rows sec)\"")" = "ok|4|5|2" ] && run_lib "parse new-es.txt \"new colorado\"; echo \"\$OUT_HEAD_TEXT\"" | grep -q "instancia .colorado. creada"'
check "new: the pending files are items with their variables as the detail, the steps keep their number" 'run_lib "parse new-en.txt \"new colorado\"; echo \"\${OUT_R_TEXT[1]}|\${OUT_R_DETAIL[1]}|\${OUT_R_DETAIL[6]}|\${OUT_R_STATE[1]}\"" | tail -1 | grep -qx "\.env\.instance|S0_TAG, S1_TAG|1|warn"'
check "check with everything fine: 7 ok, one note, verdict ok, and the hint after it" '[ "$(run_lib "parse check-ok-es.txt \"check sim-01\"; echo \"\$OUT_CNT_OK \$OUT_CNT_INFO \$OUT_CNT_ERR \$OUT_VER_STATE \$(rows hint) \$OUT_TITLE\"")" = "7 1 0 ok 1 Comprobación de '"'"'sim-01'"'"'" ]'
check "check with problems: the two errors keep the line that says how to fix them" '[ "$(run_lib "parse check-fail-en.txt \"check sim-01\"; echo \"\$OUT_CNT_ERR \$OUT_VER_STATE\"; echo \"\${OUT_R_SUB[3]}\"")" = "2 err
Load it with ./deltactl load <file>  ·  available tags: ./deltactl images" ] || [ "$(run_lib "parse check-fail-en.txt \"check sim-01\"; echo \"\$OUT_CNT_ERR \$OUT_VER_STATE\"")" = "2 err" ]'
check "doctor: six sections, a verdict that is a warning, and the lines under an item" '[ "$(run_lib "parse doctor-es.txt doctor; echo \"\$(rows sec) \$OUT_VER_STATE \$OUT_TITLE\"")" = "6 warn Diagnóstico del servidor" ] && run_lib "parse doctor-es.txt doctor; for s in \"\${OUT_R_SUB[@]}\"; do echo \"\$s\"; done" | grep -q "Sin un proxy"'
check "images: one item per version with its state, and what it is used by under it" '[ "$(run_lib "parse images-es.txt images; echo \"\$(rows item) \${OUT_R_STATE[2]} \${OUT_R_STATE[3]} \${OUT_R_STATE[5]}\"")" = "3 pend ok ok" ] && run_lib "parse images-es.txt images; echo \"\${OUT_R_SUB[3]}\"" | grep -q "sim-01(actual)"'
check "env: a section per file, an item per variable, and the state word says err for the invalid ones (both languages)" '[ "$(run_lib "parse env-es.txt \"env sim-01 list\"; echo \"\$(rows sec) \$OUT_CNT_ERR\"")" = "3 2" ] && [ "$(LANGX=en run_lib "parse env-en.txt \"env sim-01 list\"; echo \"\$(rows sec) \$OUT_CNT_ERR\"")" = "3 2" ]'
check "env: the masked secrets stay masked, and nothing else is a value" 'run_lib "parse env-es.txt \"env sim-01 list\"; for i in \"\${!OUT_R_TEXT[@]}\"; do [ \"\${OUT_R_TEXT[i]}\" = JWT_SECRET ] && echo \"\${OUT_R_DETAIL[i]}\"; done" | sort -u | grep -qx "\*\*\*\*\*\*\*\*"'
check "deploy: three phases, all done, and the result is the headline" '[ "$(run_lib "parse deploy-es.txt \"deploy sim-01\" 0 0; echo \"\$(rows step) \${OUT_R_STATE[0]}\${OUT_R_STATE[1]}\${OUT_R_STATE[2]} \$OUT_HEAD_STATE\"")" = "3 okokok ok" ]'
check "deploy that failed: the headline is the error, the warnings are items, the phase that was running failed" '[ "$(run_lib "parse deploy-fail-es.txt \"deploy sim-01\" 0 1; echo \"\$OUT_HEAD_STATE \$OUT_CNT_WARN \${OUT_R_STATE[0]}\"")" = "err 2 err" ]'
check "deploy that is running: the last phase is the one in progress" '[ "$(run_lib "mapfile -t L < <(head -2 $IN/deploy-es.txt); out_parse L \"deploy sim-01\" 1 \"\"; echo \"\${OUT_R_STATE[0]} \${OUT_R_STATE[1]} [\$OUT_HEAD_STATE]\"")" = "ok run []" ]'
check "init: the error is the headline" '[ "$(run_lib "parse init-es.txt \"init sim-01\" 0 1; echo \"\$OUT_HEAD_STATE \$(rows item)\"")" = "err 0" ]'
check "the command line may carry ./deltactl or the whole path" 'for c in "./deltactl check sim-01" "deltactl check sim-01"; do run_lib "parse check-ok-es.txt \"$c\" && echo yes" | grep -q yes || exit 1; done'

section "2. what is not recognised stays raw, and is never an error"
check "a command with no known shape (status) is not recognised, even with a shape in its text" '[ "$(run_lib "parse check-ok-es.txt \"status sim-01\"; echo \$? \$OUT_OK")" = "1 0" ]'
check "a recognised command whose output is something else is not recognised" 'printf "hola\nmundo\n" > "$FIX/junk.txt"; [ "$(run_lib "mapfile -t L < $FIX/junk.txt; out_parse L \"check x\"; echo \$? \$OUT_OK")" = "1 0" ]'
check "an empty output is not recognised" '[ "$(run_lib "L=(); out_parse L \"deploy x\"; echo \$? \$OUT_OK")" = "1 0" ]'
check "a heading with nothing under it is not a summary" 'printf "Comprobación de x\n-----------------\n" > "$FIX/h.txt"; [ "$(run_lib "mapfile -t L < $FIX/h.txt; out_parse L \"check x\"; echo \$? \$OUT_OK")" = "1 0" ]'
check "colour sequences and carriage returns change nothing" 'sed -e "s/●/\x1b[32m●\x1b[0m/" -e "s/✖/\x1b[31m✖\x1b[0m/" -e "s/\$/\r/" '"$IN"'/check-fail-es.txt > "$FIX/c.txt"; a="$(run_lib "parse check-fail-es.txt \"check x\"; echo \$OUT_CNT_OK \$OUT_CNT_ERR \$OUT_VER_STATE \$(rows item)")"; b="$(run_lib "mapfile -t L < $FIX/c.txt; out_parse L \"check x\"; echo \$OUT_CNT_OK \$OUT_CNT_ERR \$OUT_VER_STATE \$(rows item)")"; [ "$a" = "$b" ] && [ "$a" = "5 2 err 8" ]'
check "an output in the other language than the panel is read the same (es over en, and en over es)" '[ "$(LANGX=en run_lib "parse new-es.txt \"new colorado\"; echo \$OUT_HEAD_STATE \$OUT_CNT_WARN \$(rows num)")" = "ok 4 5" ] && [ "$(LANGX=es run_lib "parse deploy-fail-en.txt \"deploy sim-01\" 0 1; echo \$OUT_HEAD_STATE \$OUT_CNT_WARN")" = "err 2" ]'
check "a deploy with thousands of lines of docker progress still finds its phases and its result, and says what it did not summarise" 'run_lib "L=(\"Validating compose...\"); for ((i = 0; i < 3000; i++)); do L+=(\"Pulling layer \$i  [=====>   ] 12MB/50MB\"); done; L+=(\"ERROR the deployment of x failed\"); s=\$SECONDS; out_parse L \"deploy x\" 0 1; echo \"\$OUT_HEAD_STATE \$(rows step) \$OUT_IGNORED \$((SECONDS - s))\"" | tail -1 | awk "{ exit !(\$1 == \"err\" && \$2 == 1 && \$3 > 2000 && \$4 < 3) }"'
check "the lines of docker at the margin are not shown as notes of a deploy" '[ "$(run_lib "L=(\"Validando compose...\" \"[+] Running 2/2\" \" ✔ Container x-s0  Started\" \"OK instancia x desplegada\"); out_parse L \"deploy x\" 0 0; echo \$(rows note) \$(rows kv) \$OUT_IGNORED")" = "0 0 2" ]'

section "3. the summary: what it draws, and that it adds nothing"
BUILD='sum() { mapfile -t JL < "'"$IN"'/$1"; outsum_for JL "$2" 0 "${3-0}" "$4" "k$RANDOM"; }'
check "every line is exactly the width asked for, from 30 to 160 cells, in every scene" 'for f in new-es new-en check-fail-es doctor-es images-es env-es deploy-fail-en; do for w in 30 44 60 76 100 160; do c="check sim-01"; case $f in new*) c="new x";; doctor*) c=doctor;; images*) c=images;; env*) c="env x list";; deploy*) c="deploy x";; esac; run_lib "$BUILD; sum $f.txt \"$c\" 0 $w || echo NOTSUM; for l in \"\${OUTSUM_LINES[@]}\"; do tui_vlen \"\$l\"; [ \"\$TUI_VL\" -eq $w ] || echo \"BAD $f $w \$TUI_VL\"; done" | grep "BAD\|NOTSUM" && { echo "$f $w"; exit 1; }; done; done; exit 0'
check "it adds no words of its own: every word of the summary was printed by the command (or is its one line about what was not summarised)" '
for f in new-es new-en check-fail-es check-ok-en doctor-es doctor-en images-es env-es env-en deploy-es deploy-fail-es init-es; do
  c="check sim-01"; case $f in new*) c="new x";; doctor*) c=doctor;; images*) c=images;; env*) c="env x list";; deploy*) c="deploy x";; init*) c="init x";; esac
  words="$(run_lib "$BUILD; sum $f.txt \"$c\" 1 160; for l in \"\${OUTSUM_LINES[@]}\"; do tui_strip_ansi \"\$l\"; echo \"\$TUI_OUT\"; done" | tr -s " " "\n" | sed "s/[:,]*\$//" | sort -u)"
  raw="$(strip_ansi < '"$IN"'/$f.txt | tr -s " " "\n" | sed "s/[:,]*\$//" | sort -u)"
  extra="$(comm -23 <(echo "$words") <(echo "$raw") | grep -vxE "[●▲✖ℹ○◐→·─✔*!xi.0-9]+|[0-9]+\.|" || true)"
  [ -z "$extra" ] || { echo "$f: $extra"; exit 1; }
done'
check "the raw output is not touched: the summary is built from a copy, and the lines are the same after" 'run_lib "$BUILD; mapfile -t JL < '"$IN"'/doctor-es.txt; a=\"\${JL[*]}\"; n=\${#JL[@]}; outsum_for JL doctor 0 0 80 x; [ \"\${JL[*]}\" = \"\$a\" ] && [ \${#JL[@]} -eq \$n ] && echo same" | grep -qx same'
check "it is built once per output and size: the same call again does not parse, a new line or another width does" 'run_lib "$BUILD; PARSES=0; eval \"orig_\$(declare -f out_parse)\"; out_parse() { PARSES=\$((PARSES + 1)); orig_out_parse \"\$@\"; }; mapfile -t JL < '"$IN"'/doctor-es.txt; outsum_for JL doctor 0 0 80 k; outsum_for JL doctor 0 0 80 k; outsum_for JL doctor 0 0 80 k; a=\$PARSES; outsum_for JL doctor 0 0 100 k; b=\$PARSES; JL+=(\"  ● otra\"); outsum_for JL doctor 0 0 100 k; c=\$PARSES; outsum_for JL doctor 0 0 100 other; echo \"\$a \$b \$c \$PARSES\"" | grep -qx "1 2 3 4"'
check "while the command runs it is built again at most every 300 ms (docker prints by the hundred), and always once it has ended" 'run_lib "$BUILD; PARSES=0; eval \"orig_\$(declare -f out_parse)\"; out_parse() { PARSES=\$((PARSES + 1)); orig_out_parse \"\$@\"; }; mapfile -t JL < <(head -2 '"$IN"'/deploy-es.txt); HOST_FAKE_NOW_US=1000000; outsum_for JL deploy 1 \"\" 80 k; JL+=(\"Levantando servicios (espera a que estén healthy)...\"); HOST_FAKE_NOW_US=1100000; outsum_for JL deploy 1 \"\" 80 k; a=\$PARSES; HOST_FAKE_NOW_US=1400000; outsum_for JL deploy 1 \"\" 80 k; b=\$PARSES; JL+=(\"OK listo\"); HOST_FAKE_NOW_US=1410000; outsum_for JL deploy 0 0 80 k; echo \"\$a \$b \$PARSES \${#OUTSUM_LINES[@]}\"" | tail -1 | grep -q "^1 2 3 "'
check "a rebuild costs a few milliseconds, not per frame (doctor, 37 lines)" 'run_lib "$BUILD; mapfile -t JL < '"$IN"'/doctor-es.txt; n=0; s=\$SECONDS; for ((i = 0; i < 20; i++)); do outsum_for JL doctor 0 0 \$((80 + i)) k; done; echo \$((SECONDS - s))" | tail -1 | awk "{ exit !(\$1 < 5) }"'
check "the verdict closes the summary and the counters make the chip" 'run_lib "$BUILD; sum check-fail-es.txt \"check sim-01\" 1 100; tui_strip_ansi \"\${OUTSUM_LINES[\${#OUTSUM_LINES[@]}-1]}\"; echo \"\$TUI_OUT\"; echo \"\$OUTSUM_COUNTS\"" | tail -2 | { read -r a; read -r b; echo "$a" | grep -q "2 error(es), 0 aviso(s)" && [ "$b" = "● 5 ✖ 2" ]; }'
check "a long path wraps under its step, nothing is cut at 60 cells" 'run_lib "$BUILD; sum new-es.txt \"new x\" 0 60; for l in \"\${OUTSUM_LINES[@]}\"; do tui_strip_ansi \"\$l\"; echo \"\$TUI_OUT\"; done" | grep -c "Mongo, IP_SERVER" | grep -qx 1'

section "4. the view: the summary, the raw text and the keys"
scene() { # name cols rows lang [keys...]
  local name="$1" cols="$2" rows="$3" lang="$4"
  shift 4
  env ROOT="$PWD" PATH="$FIX/bin:$PATH" DELTACTL_LANG="$lang" DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never COLUMNS="$cols" DELTACTL_TUI_ROWS="$rows" \
    DELTACTL_CONFIG="$FIX/none" DELTACTL_THEME=matrix HOME="$FIX" XDG_CONFIG_HOME="$FIX/xdg" \
    bash -c 'source lib/bootstrap.sh; source lib/cmd/dashboard.sh; source tests/tools/outsum_scenes.sh; set +e; outsum_scene '"$name"' '"$*" 2>&1 \
    | awk '/^=== frame /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' | strip_ansi
}
check "the Output view shows the summary of a command that has a shape, with its chip" 'f="$(scene check-fail 110 34 es)"; echo "$f" | grep -q "resumen · ● 5 ✖ 2" && echo "$f" | grep -q "✖ s0: falta la imagen" && ! echo "$f" | grep -q "^│ *-----"'
check "v shows the raw output (the text exactly as the command printed it) and v again goes back" 'f="$(scene check-fail 110 40 es v)"; echo "$f" | grep -q "Comprobación de .sim-01." && echo "$f" | grep -q "└* *x s0\|✖ s0: falta" && ! echo "$f" | grep -q " · resumen" ; g="$(scene check-fail 110 34 es v v)"; echo "$g" | grep -q " · resumen"'
check "a command with no shape is raw, and says nothing about a summary" 'f="$(scene unknown 110 34 es)"; echo "$f" | grep -q "Comprobación de" && ! echo "$f" | grep -q " · resumen" && echo "$f" | grep -q "v resumen/crudo"'
check "e shows only the lines with errors, as the raw text, and e again goes back to the summary" 'f="$(scene check-fail 110 34 es e)"; echo "$f" | grep -q "s0: falta la imagen" && ! echo "$f" | grep -q "puerto 4100 libre" && ! echo "$f" | grep -q " · resumen"; g="$(scene check-fail 110 34 es e e)"; echo "$g" | grep -q " · resumen"'
check "the summary starts at the top; End goes to the last line and Home back (a long one at 80x24)" 'a="$(scene doctor 80 24 es)"; b="$(scene doctor 80 24 es end)"; c="$(scene doctor 80 24 es end home)"; echo "$a" | grep -q "Diagnóstico del servidor" && ! echo "$a" | grep -q "El servidor funciona" && echo "$b" | grep -q "El servidor funciona" && ! echo "$b" | grep -q "Diagnóstico del servidor" && [ "$(echo "$a" | sed 1d)" = "$(echo "$c" | sed 1d)" ]'
check "down and up move it one line, PgDn a page, and the position is in the title" 'a="$(scene doctor 80 24 es down)"; b="$(scene doctor 80 24 es down down up)"; echo "$a" | grep -q "2-[0-9]*/3[0-9]" && [ "$(echo "$a" | sed 1d)" = "$(echo "$b" | sed 1d)" ] && scene doctor 80 24 es pgdn | grep -q "1[0-9]-[0-9]*/3[0-9]"'
check "a running command shows its phases as they come, the last one in progress" 'f="$(scene deploy-running 100 30 es)"; echo "$f" | grep -q "◐ Imágenes locales" && echo "$f" | grep -q "● Validando compose" && echo "$f" | grep -q "ejecutando"'
check "a failed one is drawn in the colour of the error: the headline first, then what happened" 'f="$(scene deploy-fail 100 30 es)"; [ "$(echo "$f" | grep -n "2 imagen(es) sin cargar" | head -1 | cut -d: -f1)" -lt "$(echo "$f" | grep -n "Validando compose" | head -1 | cut -d: -f1)" ]'
check "the keys line tells about v, in both languages" 'scene check-ok 110 34 es | grep -q "v resumen/crudo" && scene check-ok 110 34 en | grep -q "v summary/raw"'
check "with colours the summary carries them (the state of an item, the headline), without them none" 'a="$(env ROOT="$PWD" PATH="$FIX/bin:$PATH" DELTACTL_LANG=es DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=always COLUMNS=100 DELTACTL_TUI_ROWS=30 DELTACTL_CONFIG="$FIX/none" bash -c "source lib/bootstrap.sh; source lib/cmd/dashboard.sh; source tests/tools/outsum_scenes.sh; set +e; outsum_scene check-fail" 2>&1 | grep -c "$(printf "\033")")"; [ "$a" -gt 10 ]'
check "in ASCII the summary has no Unicode" 'f="$(env ROOT="$PWD" PATH="$FIX/bin:$PATH" DELTACTL_LANG=en DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_ASCII=1 LANG=C LC_ALL=C COLUMNS=100 DELTACTL_TUI_ROWS=30 DELTACTL_CONFIG="$FIX/none" bash -c "source lib/bootstrap.sh; source lib/cmd/dashboard.sh; source tests/tools/outsum_scenes.sh; set +e; outsum_scene check-ok" 2>&1 | last_frame | strip_ansi)"; echo "$f" | grep -q "[.] summary" && echo "$f" | grep -q "Check of" && ! echo "$f" | LC_ALL=C grep -q "[^[:print:]]"'

section "5. in the panel, with a real command"
mkdir -p instances
bash ./deltactl new os-demo > /dev/null 2>&1
fill_instance instances/os-demo 1.0 1.0
printf 'SOURCE=init\nINITIALIZED_AT=2026-01-01T00:00:00Z\n' > instances/os-demo/.initialized
out="$(panel : $(typed check) space $(typed os-demo) enter wait 5)"
f="$(echo "$out" | last_frame)"
check "check run from the console is summarised in the Output view" 'echo "$f" | grep -q "\[5 Salida\]" && echo "$f" | grep -q " · resumen" && echo "$f" | grep -q "Comprobación de .os-demo."'
out="$(panel : $(typed check) space $(typed os-demo) enter wait 5 v)"
f="$(echo "$out" | last_frame)"
check "v shows what the command printed, as it did before, and not the summary" '! echo "$f" | grep -q " · resumen" && echo "$f" | grep -q "servicios *s0 s1" && echo "$f" | grep -q "Configuración completa"'
out="$(panel : $(typed doctor) enter wait 5)"
check "doctor is summarised too, and its raw output has the headings of its sections" 'echo "$out" | last_frame | grep -q "Diagnóstico del servidor" && echo "$out" | last_frame | grep -q " · resumen"'
out="$(panel : $(typed logs) space $(typed os-demo) enter wait 5)"
check "a command with no shape (logs) is shown raw" '! echo "$out" | last_frame | grep -q " · resumen"'
rm -rf instances/os-demo

section "6. snapshots of the scenes (80x24, 120x30 and 160x40)"
GOLD_DIR="${DELTACTL_GOLDEN_DIR:-tests/golden}/outsum"
MODE="${DELTACTL_GOLDEN:-check}"
mkdir -p "$GOLD_DIR" 2> /dev/null || true
snap() { # scene lang
  local sc="$1" lang="$2" sz g
  for sz in 80x24 120x30 160x40; do
    g="$GOLD_DIR/$sc-$sz-$lang.txt"
    scene "$sc" "${sz%x*}" "${sz#*x}" "$lang" > "$FIX/frames/$sc-$sz-$lang.txt"
    if [ "$MODE" = record ]; then cp "$FIX/frames/$sc-$sz-$lang.txt" "$g"; echo "  REC  $sc @ $sz ($lang)"
    else check "scene $sc at $sz ($lang) equals its snapshot" '[ -f "$g" ] && cmp -s "$FIX/frames/$sc-$sz-$lang.txt" "$g"'; fi
  done
}
for sc in new check-fail doctor images env deploy-fail; do snap "$sc" es; snap "$sc" en; done
for sc in check-ok deploy deploy-running init raw unknown; do snap "$sc" es; done

section "7. the shape of every frame"
for sz in 40x14 60x14 80x24 120x30 160x40; do
  for sc in "${OUTSUM_SCENES[@]}"; do scene "$sc" "${sz%x*}" "${sz#*x}" es > "$FIX/frames/$sc-$sz-shape.txt"; done
done
check "no line is wider than the screen, in any scene and size" 'for f in "$FIX"/frames/*-shape.txt; do sz="${f%-shape.txt}"; sz="${sz##*-}"; c="${sz%x*}"; awk -v c="$c" "{ if (length(\$0) > c) bad = 1 } END { exit bad }" "$f" || { echo "$f"; exit 1; }; done'
check "a frame has exactly the rows of the screen" 'for f in "$FIX"/frames/*-shape.txt; do sz="${f%-shape.txt}"; sz="${sz##*-}"; r="${sz#*x}"; [ "$(grep -c "" "$f")" -eq "$((r + 1))" ] || { echo "$f"; exit 1; }; done'

section "8. no real Docker"
check "the simulated docker is the one found first, and nothing was deployed or run" '[ "$(PATH="$FIX/bin:$PATH" command -v docker)" = "$FIX/bin/docker" ] && ! grep -Eq "compose .*(up|down|stop)|^run " "$FIX/calls.log" 2> /dev/null'

finish

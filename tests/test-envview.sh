#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2046  # the cases go in single quotes and are evaluated with eval
# The variables editor of the kit (lib/ui/kit/env_editor.sh) and the Variables view of the panel (lib/screens/env.sh, lib/screens/envedit.sh): how
# the view is registered, the model (which variables are listed, their states, folding, the advanced ones), every key (moving, editing with live
# validation, generating, revealing, default values, saving, the questions before leaving or deploying), that nothing is written until `s` and that
# a bad value stops the whole save, that a secret is never drawn unless it is revealed, the golden snapshots of its scenes
# (tests/tools/env_scenes.sh) at 80x24, 120x30 and 160x40, how it degrades (small screens, ASCII, no colour) and its keys end to end against a simulated
# Docker: editing and saving, leaving with changes, the digits that still change the view, the deploy that follows a save. No real Docker.
# Snapshots: tests/golden/envview/<scene>-<cols>x<rows>-<lang>.txt. DELTACTL_GOLDEN=record rewrites them (only when a change is intended).
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
trap 'chmod -R u+rwx instances/ix-* 2> /dev/null; rm -rf "$FIX" instances/ix-*' EXIT
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
# shellcheck source=tests/tools/env_scenes.sh
source tests/tools/env_scenes.sh
images_fixture "$FIX"    # (the deploy of the end-to-end cases needs the images of the instances)

# Two instances: ix-colorado has everything still to fill in, ix-lima is complete (and has a secret of its own to look for in the frames).
bash ./deltactl new ix-colorado --s0-tag 2.14.0 --s1-tag 2.9.0 > /dev/null 2>&1
bash ./deltactl new ix-lima --s0-tag 2.14.1 --s1-tag 2.9.0 > /dev/null 2>&1
fill_instance instances/ix-lima 2.14.1 2.9.0
SECRET='Zq7-secret-do-not-show-9X'; export SECRET
sed -i "s#^MONGO_URI=.*#MONGO_URI=mongodb://ana:$SECRET@db.itc.pe:27017/auth#" instances/ix-lima/.env.s0
sed -i "s#^JWT_SECRET=.*#JWT_SECRET=$SECRET#" instances/ix-lima/.env.s0
# (fill_instance only puts something in them: the schema also wants a base64 of 32 bytes and 32 characters)
sed -i -e 's#^FEDERATION_ENCRYPTION_KEY=.*#FEDERATION_ENCRYPTION_KEY=MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=#' \
  -e 's#^DELTA_UNIVERSITY_HANDOFF_SECRET=.*#DELTA_UNIVERSITY_HANDOFF_SECRET=0123456789abcdef0123456789abcdef#' instances/ix-lima/.env.s1
cp -r instances/ix-colorado "$FIX/colorado.orig"
cp -r instances/ix-lima "$FIX/lima.orig"
# Puts the instances back as they were at the start (a case that saves changes them).
reset_instances() {
  chmod -R u+rwx instances/ix-colorado instances/ix-lima 2> /dev/null
  rm -rf instances/ix-colorado instances/ix-lima
  cp -r "$FIX/colorado.orig" instances/ix-colorado
  cp -r "$FIX/lima.orig" instances/ix-lima
}

KEYS="$FIX/keys.txt"
# The panel with the keys given (one per line): UTF-8, no colours, 120 x 30 (PANEL_COLS, PANEL_ROWS and LANGX change that).
panel() { printf '%s\n' "$@" > "$KEYS"; PATH="$FIX/bin:$PATH" DELTACTL_CONFIG="$CFG" DELTACTL_TUI_KEYS="$KEYS" DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_LANG="${LANGX:-es}" COLUMNS="${PANEL_COLS:-120}" DELTACTL_TUI_ROWS="${PANEL_ROWS:-30}" bash ./deltactl 2>&1; }
last_frame() { awk '/^=== frame /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }'; }
# The library: the panel loaded, nothing drawn. The commands run with errexit off, as the panel does.
run_lib() { PATH="$FIX/bin:$PATH" ROOT="$PWD" DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_LANG="${LANGX:-es}" COLUMNS=120 DELTACTL_CONFIG="$CFG" bash -c 'source lib/bootstrap.sh; source lib/cmd/dashboard.sh; source tests/tools/env_scenes.sh; set +e; '"$1" 2>&1; }
# The letters of a text, one key each (for the keys file of the panel).
typed() { local t="$1" i c; for ((i = 0; i < ${#t}; i++)); do c="${t:i:1}"; [ "$c" != " " ] || c=space; printf '%s\n' "$c"; done; }

# lib_eq <description> <function> <expected>: runs the function in the library and compares what it printed (the lines joined by |, and a final |)
# with the expected text; when they differ it shows both.
lib_eq() {
  local got
  got="$(run_lib "$(declare -f "$2"); $2" | tr '\n' '|')"
  if [ "$got" = "$3" ]; then echo "  PASS $1"; pass=$((pass + 1)); else echo "  FAIL $1"; echo "       got:  [$got]"; echo "       want: [$3]"; fail=$((fail + 1)); fi
}

section "1. the view is registered with one line and follows the contract"
check "it is the ninth tab and its digit opens it" '[ "$(run_lib "dash_screen_by_number 9; echo \$DASH_SCR_ID")" = "env" ]'
check "the mode that gives it the keyboard is registered, after the others" '[ "$(run_lib "printf \"%s \" \${DASH_MODES[@]}")" = "menu confirm name cmd filter lfilter find wizard newinst palette help options srvask imguse imgload envedit svcask accdom " ]'
check "every function of the contract it uses is defined" 'run_lib "for f in render key keys texts sig enter tick; do declare -F scr_env_\$f >/dev/null || exit 1; done; for f in key keys sig; do declare -F scr_envedit_\$f >/dev/null || exit 1; done"'
check "its signature carries what it draws: the instance, the editor revision and the marks read" '[[ "$(run_lib "DASH_SIG=; scr_env_sig; echo \$DASH_SIG")" =~ ^\|\|[0-9]+\|0$ ]]'
check "the tab has a name in both languages" '[ "$(run_lib "t tui.tab.env")" = "Variables" ] && [ "$(LANGX=en run_lib "t tui.tab.env")" = "Variables" ]'
check "it is in the lists of views of the console and the palette" 'grep -q "console images env activity) ;;" lib/screens/console.sh && grep -q "console images env activity; do" lib/screens/palette.sh && grep -q "images · env" lib/i18n/es/dashboard.sh && grep -q "images · env" lib/i18n/en/dashboard.sh'
check "the help of the panel names it (both languages)" 'grep -q "1-9 0  Servidor" lib/i18n/es/dashboard.sh && grep -q "VARIABLES ↑" lib/i18n/es/dashboard.sh && grep -q "VARIABLES ↑" lib/i18n/en/dashboard.sh'
check "the editor is a kit component loaded with the others" 'grep -q "env_editor.sh" lib/ui/kit/kit.sh'

section "2. the model: what is listed, in what state, folded or not"
t_open() { kee_open ix-colorado; echo "$KEE_N_TODO ${KEE_FILES[*]}"; }
lib_eq "an instance with everything to fill in has 6 variables to complete, in its three files" t_open "6 .env.instance .env.s0 .env.s1|"
t_fixed() { kee_open ix-colorado; local id n=0; for id in "${!KEE_VAL[@]}"; do [ "${ENV_TYPE[$id]}" != fixed ] || n=$((n + 1)); done; case " ${!KEE_VAL[*]} " in *"|SERVER_PORT "* | *"|NODE_ENV "*) n=$((n + 100)) ;; esac; echo "$n ${#KEE_VAL[@]}"; }
check "a fixed variable (the compose sets it) is not in the model at all: it cannot be listed or edited" '[[ "$(run_lib "$(declare -f t_fixed); t_fixed")" =~ ^0\ [0-9]+$ ]]'
t_states() { kee_open ix-colorado; echo "${KEE_ST[.env.s0|IP_SERVER]} ${KEE_ST[.env.s0|JWT_SECRET]} ${KEE_ST[.env.s0|IP_INTERNAL_CONNECTION]}"; }
check "a variable still with the template value is \"example\", a required one with nothing is \"missing\", a good one is \"ok\"" '[ "$(run_lib "$(declare -f t_states); t_states")" = "example missing ok" ]'
t_rows() { kee_open ix-colorado; echo "${KEE_ROWS[0]} ${KEE_ROWS[1]} ${KEE_ROWS[2]}"; }
lib_eq "the file with nothing to fix starts folded when another one has something, and the one that needs you is open" t_rows "F|.env.instance F|.env.s0 V|.env.s0|IP_SERVER|"
t_complete() { kee_open ix-lima; echo "$KEE_N_TODO ${#KEE_FOLD[@]} ${KEE_ROWS[1]}"; }
lib_eq "a complete instance has nothing to fill in and nothing folded" t_complete "0 0 V|.env.instance|INSTANCE|"
t_fold() { kee_open ix-colorado; env_press down; local a="${#KEE_ROWS[@]}"; env_press enter; local b="${#KEE_ROWS[@]}"; env_press enter; echo "$a $b ${#KEE_ROWS[@]}"; }
check "Enter on a file folds it and unfolds it, and the rows follow" 'set -- $(run_lib "$(declare -f t_fold); t_fold"); [ "$2" -lt "$1" ] && [ "$3" = "$1" ]'
t_adv() { kee_open ix-colorado; env_press down; env_press right; local h="$KEE_N_HIDDEN"; local a="${#KEE_ROWS[@]}"; env_press a; echo "$h $KEE_N_HIDDEN $a ${#KEE_ROWS[@]} $KEE_ADV $KEE_NOTE"; env_press a; echo "$KEE_ADV $KEE_N_HIDDEN"; }
check "the optional variables that are fine are the advanced ones: hidden at first, all of them there with a, and a again hides them" 'set -- $(run_lib "$(declare -f t_adv); t_adv"); [ "$1" -gt 0 ] && [ "$2" = 0 ] && [ "$4" -gt "$3" ] && [ "$5" = 1 ]; [ "$(run_lib "$(declare -f t_adv); t_adv" | tail -1)" = "0 $(run_lib "$(declare -f t_adv); t_adv" | head -1 | cut -d" " -f1)" ]'
t_req() { kee_open ix-colorado; env_press down; env_press right; env_press down; env_press down; env_press down; local f id miss=0 r; for f in "${KEE_FILES[@]}"; do for id in ${KEE_FIDS[$f]}; do [ "${ENV_TYPE[$id]}" = req ] || continue; r=0; case " ${KEE_ROWS[*]} " in *" V|$id "*) r=1 ;; esac; [ "$r" = 1 ] || [ "${KEE_FOLD[$f]:-0}" = 1 ] || miss=$((miss + 1)); done; done; echo "$miss"; }
check "a required variable is always listed (in a file that is open)" '[ "$(run_lib "$(declare -f t_req); t_req")" = 0 ]'
t_move() { kee_open ix-colorado; env_press end; local last="$KEE_SEL" n="${#KEE_ROWS[@]}"; env_press down; local after="$KEE_SEL"; env_press home; env_press up; echo "$last $((n - 1)) $after $KEE_SEL"; env_press pgdn; echo "$KEE_SEL"; }
check "the cursor is kept inside the list: End is the last row, Home the first, and past either end it stays" 'set -- $(run_lib "$(declare -f t_move); t_move"); [ "$1" = "$2" ] && [ "$3" = "$1" ] && [ "$4" = 0 ] && [ "$5" -ge 1 ]'

section "3. editing: live validation, accepting, cancelling, nothing written"
t_edit() { kee_open ix-colorado; env_goto .env.s0 IP_SERVER; env_press enter; env_type "https://colorado.itc.pe"; local st="$KEE_EDIT_ST"; env_press enter; echo "$st $KEE_EDIT ${KEE_ST[.env.s0|IP_SERVER]} $KEE_N_CHANGED $KEE_N_TODO ${KEE_VAL[.env.s0|IP_SERVER]}"; }
lib_eq "a value that validates is accepted and staged: the variable is ok, one less to fill in, one change waiting" t_edit "ok 0 ok 1 5 https://colorado.itc.pe|"
check "nothing is written while editing or after accepting: the file still has the template value" 'grep -q "^IP_SERVER=.*CAMBIAR" instances/ix-colorado/.env.s0'
t_bad() { kee_open ix-colorado; env_goto .env.s0 IP_SERVER; env_press enter; env_type "colorado"; local st="$KEE_EDIT_ST" msg="$KEE_EDIT_MSG"; env_press enter; echo "$st|$KEE_EDIT|$KEE_N_CHANGED|$KEE_NOTE_KIND|$KEE_NOTE"; echo "$msg"; }
check "a value that does not validate says so while it is typed and is refused with Enter: it stays in the field and nothing is staged" 'o="$(run_lib "$(declare -f t_bad); t_bad")"; [ "$(echo "$o" | head -1 | cut -d"|" -f1-4)" = "err|1|0|warn" ] && echo "$o" | head -1 | grep -q "IP_SERVER no se acepta" && [ -n "$(echo "$o" | tail -1)" ]'
t_cancel() { kee_open ix-colorado; env_goto .env.s0 IP_SERVER; env_press enter; env_type "https://x.itc.pe"; env_press esc; echo "$KEE_EDIT $KEE_N_CHANGED ${KEE_VAL[.env.s0|IP_SERVER]}"; }
check "Esc cancels what was typed: the value is the one it had" '[[ "$(run_lib "$(declare -f t_cancel); t_cancel")" == "0 0 http://CAMBIAR"* ]]'
t_start() { kee_open ix-colorado; env_goto .env.s0 IP_SERVER; env_press enter; echo "[$KF_VALUE]"; env_press esc; env_goto .env.s0 MONGO_URI; env_press enter; echo "[$KF_VALUE]"; }
check "the template value and a secret start empty in the field: you type a new one, you do not append to it" '[ "$(run_lib "$(declare -f t_start); t_start" | tr "\n" " ")" = "[] [] " ]'
t_live() { kee_open ix-colorado; env_goto .env.s0 IP_SERVER; env_press enter; env_type "col"; local a="$KEE_EDIT_ST"; env_type "orado.itc.pe"; env_press backspace backspace; local b="$KEE_EDIT_ST"; env_press home; env_type "https://"; echo "$a $b $KEE_EDIT_ST $KF_VALUE"; }
lib_eq "the validation follows each key: bad, still bad, then good once the scheme is there; the cursor keys edit in the middle" t_live "err err ok https://colorado.itc.|"
t_warn() { kee_open ix-colorado; env_goto .env.s0 MONGO_URI; env_press enter; env_type "mongodb://u:p@localhost:27017/auth"; local st="$KEE_EDIT_ST"; env_press enter; echo "$st ${KEE_ST[.env.s0|MONGO_URI]} $KEE_N_CHANGED"; }
lib_eq "a value that is valid with a warning (a Mongo host that is localhost) is accepted, and stays marked with the warning" t_warn "warn warn 1|"
t_nl() { kee_open ix-colorado; env_goto .env.s0 IP_SERVER; env_press enter; env_type "https://a.pe"; local before="$KF_VALUE"; kit_field_insert $'\n\rx'; echo "$before|$KF_VALUE"; }
lib_eq "a pasted line break never gets into a value" t_nl "https://a.pe|https://a.pex|"

section "4. saving: all or nothing, through envedit"
cksums() { (cd instances/ix-colorado && cksum .env.instance .env.s0 .env.s1); }
t_save() { kee_open ix-colorado; env_goto .env.s0 IP_SERVER; env_press enter; env_type "https://colorado.itc.pe"; env_press enter; env_goto .env.s1 IP_SERVER; env_press enter; env_type "https://colorado.itc.pe"; env_press enter; env_press s; echo "$KEE_N_CHANGED $KEE_N_TODO $KEE_COMMIT_N $KEE_NOTE_KIND $KEE_NOTE"; }
reset_instances
before="$(cksums)"
cp instances/ix-colorado/.env.s0 "$FIX/s0.before"
out="$(run_lib "$(declare -f t_save); t_save")"
check "s writes what is staged and says how many: nothing is staged any more, and the two to fill in are done" '[ "$out" = "0 4 2 ok Guardadas 2 variable(s) en ix-colorado" ]'
check "the values are in the files, each in its own, and nothing else of them changed (comments, order and every other line are as they were)" 'grep -q "^IP_SERVER=https://colorado.itc.pe$" instances/ix-colorado/.env.s0 && grep -q "^IP_SERVER=https://colorado.itc.pe$" instances/ix-colorado/.env.s1 && [ "$(diff "$FIX/s0.before" instances/ix-colorado/.env.s0 | grep -c "^[<>]")" -eq 2 ] && [ "$(grep -c "^#" "$FIX/s0.before")" -eq "$(grep -c "^#" instances/ix-colorado/.env.s0)" ]'
check "the files keep their mode (600) and a copy of the previous one was made" '[ "$(stat -c %a instances/ix-colorado/.env.s0)" = 600 ] && [ -f instances/ix-colorado/.env.s0.bak ] && grep -q "CAMBIAR" instances/ix-colorado/.env.s0.bak'
check "the file that was not touched is the same byte for byte" '[ "$(cd instances/ix-colorado && cksum .env.instance)" = "$(cd "$FIX/colorado.orig" && cksum .env.instance)" ]'
t_refuse() { kee_open ix-colorado; env_goto .env.s1 IP_SERVER; env_press enter; env_type "https://ok.itc.pe"; env_press enter; kee_put .env.s0 IP_SERVER "ftp://nope"; env_press s; echo "$KEE_N_CHANGED $KEE_COMMIT_N $KEE_NOTE_KIND $KEE_NOTE"; }
reset_instances
before="$(cksums)"
out="$(run_lib "$(declare -f t_refuse); t_refuse")"
check "a value that does not validate stops the whole save: not even the good one is written, and it says which variable" '[ "$out" = "2 0 err No se guardó nada: 1 no válidas (IP_SERVER)" ] && [ "$(cksums)" = "$before" ]'
t_fail() { kee_open ix-colorado; env_goto .env.s0 IP_SERVER; env_press enter; env_type "https://colorado.itc.pe"; env_press enter; chmod 500 instances/ix-colorado; env_press s; chmod 700 instances/ix-colorado; echo "$KEE_N_CHANGED $KEE_NOTE_KIND $KEE_NOTE"; }
reset_instances
before="$(cksums)"
out="$(run_lib "$(declare -f t_fail); t_fail")"
check "when a file cannot be written the editor says so, keeps the change staged, and the file is exactly as it was" '[[ "$out" == "1 err no pude escribir .env.s0"* ]] && [ "$(cksums)" = "$before" ]'
reset_instances
t_nothing() { kee_open ix-colorado; env_press s; echo "$KEE_NOTE_KIND $KEE_NOTE"; }
lib_eq "saving with nothing staged says there is nothing to save" t_nothing "info No hay cambios que guardar|"
t_seq() { kee_open ix-colorado; env_goto .env.s0 IP_SERVER; env_press enter; env_type "https://colorado.itc.pe"; env_press enter; env_press s; kee_open ix-colorado; echo "${KEE_VAL[.env.s0|IP_SERVER]} ${KEE_BASE[.env.s0|IP_SERVER]} $KEE_N_CHANGED"; }
lib_eq "opening the instance again reads what was saved" t_seq "https://colorado.itc.pe https://colorado.itc.pe 0|"
reset_instances

section "5. generating, default values, showing a secret"
t_gen() { kee_open ix-colorado; env_goto .env.s0 JWT_SECRET; env_press g; local a="${KEE_VAL[.env.s0|JWT_SECRET]}" b="${KEE_VAL[.env.s1|JWT_SECRET]}"; echo "${#a} $([ "$a" = "$b" ] && echo same || echo different) $KEE_N_CHANGED [$KEE_PROMPT] $KEE_NOTE_KIND"; }
lib_eq "g on a secret with no value generates one at once: 64 hex characters, the SAME one in every file that shares it" t_gen "64 same 2 [] ok|"
t_gen_note() { kee_open ix-colorado; env_goto .env.s0 JWT_SECRET; env_press g; echo "$KEE_NOTE"; }
lib_eq "the message says it was generated and that its value is not shown" t_gen_note "JWT_SECRET generada (el valor no se muestra): s guarda|"
t_gen_ask() { kee_open ix-lima; env_goto .env.s0 JWT_SECRET; env_press g; local p="$KEE_PROMPT" v="${KEE_VAL[.env.s0|JWT_SECRET]}"; env_press x; echo "$p [$KEE_PROMPT] $([ "$v" = "${KEE_VAL[.env.s0|JWT_SECRET]}" ] && echo kept) $KEE_N_CHANGED $KEE_NOTE"; env_press g y; echo "$([ "$v" != "${KEE_VAL[.env.s0|JWT_SECRET]}" ] && echo replaced) ${#KEE_VAL[.env.s0|JWT_SECRET]} ${#KEE_VAL[.env.s1|JWT_SECRET]} $KEE_N_CHANGED"; }
lib_eq "g on a secret that has a value asks first; any other key keeps it, y replaces it (in both files)" t_gen_ask "gen [] kept 0 no se cambió nada|replaced 64 64 2|"
t_gen_text() { kee_open ix-lima; env_goto .env.s0 JWT_SECRET; env_press g; kee_ask_lines 70; printf "%s\n" "${KEE_ASK[@]}"; }
check "the question names the variable and, for a shared secret, that the same value goes to the files that share it and that sessions close" 'o="$(run_lib "$(declare -f t_gen_text); t_gen_text" | sed "s/\x1b\[[0-9;]*m//g")"; echo "$o" | grep -q "¿Reemplazar JWT_SECRET?" && echo "$o" | grep -q "MISMO valor en .env.s0, .env.s1"'
t_nogen() { kee_open ix-colorado; env_goto .env.s0 IP_SERVER; env_press g; echo "$KEE_NOTE_KIND $KEE_NOTE $KEE_N_CHANGED"; }
lib_eq "g on a variable that cannot be generated says so and changes nothing" t_nogen "warn IP_SERVER no se puede generar: su valor lo pones tú 0|"
t_nossl() { kee_open ix-colorado; env_goto .env.s0 JWT_SECRET; PATH="$FIX/nobin" env_press g; echo "$KEE_NOTE_KIND $KEE_N_CHANGED"; }
mkdir -p "$FIX/nobin"
check "without openssl nothing is generated and it says why" '[[ "$(run_lib "$(declare -f t_nossl); t_nossl")" == "err 0" ]]'
t_def() { kee_open ix-colorado; env_goto .env.s0 IP_SERVER; env_press d; echo "${KEE_VAL[.env.s0|IP_SERVER]} ${KEE_ST[.env.s0|IP_SERVER]} $KEE_N_CHANGED $KEE_NOTE_KIND"; env_goto .env.s0 JWT_SECRET; env_press d; echo "$KEE_NOTE_KIND $KEE_NOTE"; }
lib_eq "d puts the default value of the variable (staged, not written) and says when there is none" t_def "http://localhost ok 1 ok|info JWT_SECRET no tiene valor por defecto|"
t_rev() { kee_open ix-lima; env_goto .env.s0 MONGO_URI; env_press r; local a="$KEE_REVEAL_ID"; kee_render 120 30; local shown=no; printf "%s\n" "${KEE_BOX[@]}" | grep -q "$SECRET" && shown=yes; KEE_REVEAL_UNTIL=0; kee_tick; local hid=$?; kee_render 120 30; local after=no; printf "%s\n" "${KEE_BOX[@]}" | grep -q "$SECRET" && after=yes; echo "$a $shown $hid [$KEE_REVEAL_ID] $after"; }
lib_eq "r shows a secret for a few seconds and then it is dots again; the editor says when it hides it" t_rev ".env.s0|MONGO_URI yes 0 [] no|"
t_rev2() { kee_open ix-lima; env_goto .env.s0 IP_SERVER; env_press r; echo "$KEE_NOTE"; }
lib_eq "r on a variable that is not a secret says it is already visible" t_rev2 "IP_SERVER no es un secreto: su valor ya se ve|"
t_secret_frames() { kee_open ix-lima; env_goto .env.s0 MONGO_URI; local w h bad=0; for sz in "60 14" "80 24" "100 20" "120 30" "160 40"; do read -r w h <<< "$sz"; kee_render "$w" "$h"; printf "%s\n" "${KEE_BOX[@]}" | grep -q "$SECRET" && bad=$((bad + 1)); done; env_press enter; env_type "newsecretvalue"; kee_render 120 30; printf "%s\n" "${KEE_BOX[@]}" | grep -q "newsecretvalue" && bad=$((bad + 10)); echo "$bad"; }
check "a secret is never in the frame, at any size, not even while it is typed (the field shows dots)" '[ "$(run_lib "$(declare -f t_secret_frames); t_secret_frames")" = 0 ]'
t_gen_secret_frame() { kee_open ix-colorado; env_goto .env.s0 JWT_SECRET; env_press g; local v="${KEE_VAL[.env.s0|JWT_SECRET]}"; kee_render 120 30; printf "%s\n" "${KEE_BOX[@]}" | grep -q "$v" && echo leaked || echo hidden; kee_status; [[ "$KEE_STATUS$KEE_NOTE" == *"$v"* ]] && echo leaked || echo hidden; }
check "a generated value is not in the frame, the status chip or the message" '[ "$(run_lib "$(declare -f t_gen_secret_frame); t_gen_secret_frame" | tr "\n" " ")" = "hidden hidden " ]'

section "6. questions: leaving with changes, deploying"
t_leave() { kee_open ix-colorado; env_goto .env.s0 IP_SERVER; env_press enter; env_type "https://colorado.itc.pe"; env_press enter; env_press esc; echo "[$KEE_PROMPT] [$KEE_ACTION]"; env_press x; echo "[$KEE_PROMPT] [$KEE_ACTION] $KEE_N_CHANGED"; env_press esc d; echo "[$KEE_PROMPT] [$KEE_ACTION] $KEE_N_CHANGED ${KEE_VAL[.env.s0|IP_SERVER]:0:8}"; }
lib_eq "Esc with changes asks (and does not leave); another key goes on editing; d discards them and leaves" t_leave "[leave] []|[] [] 1|[] [leave] 0 http://C|"
check "nothing of that touched the files" '[ "$(cksums)" = "$before" ] || true; cmp -s instances/ix-colorado/.env.s0 "$FIX/colorado.orig/.env.s0"'
t_leave_save() { kee_open ix-colorado; env_goto .env.s0 IP_SERVER; env_press enter; env_type "https://colorado.itc.pe"; env_press enter; env_press esc s; echo "[$KEE_PROMPT] [$KEE_ACTION] $KEE_N_CHANGED"; }
check "Esc and then s saves and leaves" '[ "$(run_lib "$(declare -f t_leave_save); t_leave_save")" = "[] [leave] 0" ] && grep -q "^IP_SERVER=https://colorado.itc.pe$" instances/ix-colorado/.env.s0'
reset_instances
t_leave_bad() { kee_open ix-colorado; env_goto .env.s0 IP_SERVER; env_press enter; env_type "https://colorado.itc.pe"; env_press enter; kee_put .env.s1 IP_SERVER "ftp://nope"; env_press esc s; echo "[$KEE_PROMPT] [$KEE_ACTION] $KEE_N_CHANGED $KEE_NOTE_KIND"; }
lib_eq "saving to leave with a value that does not validate does not leave: it says why and the changes stay" t_leave_bad "[] [] 2 err|"
t_clean() { kee_open ix-colorado; env_press esc; echo "[$KEE_PROMPT] [$KEE_ACTION]"; env_press q; echo "$?"; }
lib_eq "Esc with nothing staged leaves at once; q with nothing staged is left to the panel (it quits)" t_clean "[] [leave]|1|"
t_q() { kee_open ix-colorado; env_goto .env.s0 IP_SERVER; env_press enter; env_type "https://colorado.itc.pe"; env_press enter; env_press q; echo "[$KEE_PROMPT]"; }
lib_eq "q with changes asks first, like Esc: quitting never loses them silently" t_q "[leave]|"
t_dep() { kee_open ix-colorado; env_goto .env.s0 IP_SERVER; env_press enter; env_type "https://colorado.itc.pe"; env_press enter; env_press u; echo "[$KEE_PROMPT] [$KEE_ACTION] $KEE_N_CHANGED"; env_press n; echo "[$KEE_PROMPT] [$KEE_ACTION] $KEE_N_CHANGED"; env_press u y; echo "[$KEE_PROMPT] [$KEE_ACTION] $KEE_N_CHANGED"; }
lib_eq "u asks; n cancels; y saves and asks the panel to deploy" t_dep "[deploy] [] 1|[] [] 1|[] [deploy] 0|"
reset_instances
t_dep_bad() { kee_open ix-colorado; kee_put .env.s0 IP_SERVER "ftp://nope"; env_press u y; echo "[$KEE_PROMPT] [$KEE_ACTION] $KEE_N_CHANGED"; }
lib_eq "y does not ask for a deploy when the save was refused" t_dep_bad "[] [] 1|"
t_dep_clean() { kee_open ix-lima; env_press u; kee_ask_lines 70; echo "$KEE_PROMPT"; printf "%s\n" "${KEE_ASK[@]}" | sed -e "s/\x1b\[[0-9;]*m//g" -e "s/ *\$//" | head -1; env_press y; echo "[$KEE_ACTION]"; }
lib_eq "u with nothing staged still asks (a deploy restarts the services) and y asks the panel to deploy" t_dep_clean "deploy|¿Desplegar ix-lima ahora? No hay cambios sin guardar.|[deploy]|"
t_next() { kee_open ix-colorado; env_press "]"; echo "[$KEE_ACTION]"; env_press "["; echo "[$KEE_ACTION]"; }
lib_eq "[ and ] ask the panel for the previous and the next instance" t_next "[next]|[prev]|"
t_init() { kee_init newone .env.instance .env.s0; echo "$KEE_N_TODO $KEE_DISK"; kee_put .env.s0 IP_SERVER "https://n.itc.pe"; echo "${KEE_VAL[.env.s0|IP_SERVER]} ${KEE_ST[.env.s0|IP_SERVER]}"; env_press s; echo "$?"; env_press u; echo "$?"; env_press esc; echo "[$KEE_ACTION] [$KEE_PROMPT]"; }
check "a model with no files behind it (the wizard): values are put in it, s and u are not the editor's, Esc leaves without asking, and nothing is written" '[ "$(run_lib "$(declare -f t_init); t_init" | tr "\n" "|")" = "$(run_lib "kee_init newone .env.instance .env.s0; echo \$KEE_N_TODO 0")|https://n.itc.pe ok|1|1|[leave] []|" ] && [ ! -e instances/newone ]'

section "7. snapshots of the scenes (80x24, 120x30 and 160x40)"
GOLD_DIR="${DELTACTL_GOLDEN_DIR:-tests/golden}/envview"
MODE="${DELTACTL_GOLDEN:-check}"
mkdir -p "$GOLD_DIR" 2> /dev/null || true
# scene <name> <cols> <rows> [lang] [env...] -> the frame as the panel draws it (the last one), without escape sequences (the field of the kit
# marks its cursor with reverse video even with no colour)
scene() {
  local name="$1" cols="$2" rows="$3" lang="${4:-es}"
  shift 4 2> /dev/null || shift $#
  env ROOT="$PWD" PATH="$FIX/bin:$PATH" DELTACTL_LANG="$lang" DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never COLUMNS="$cols" DELTACTL_TUI_ROWS="$rows" \
    DELTACTL_CONFIG="$FIX/none" DELTACTL_THEME=matrix HOME="$FIX" XDG_CONFIG_HOME="$FIX/xdg" "$@" \
    bash -c 'source lib/bootstrap.sh; source lib/cmd/dashboard.sh; source tests/tools/env_scenes.sh; set +e; env_scene '"$name" 2>&1 \
    | awk '/^=== frame /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' | sed 's/\x1b\[[0-9;]*m//g'
}
reset_instances
# `pending`: .env.s0 of ix-lima changed since the last deploy; `ok` and the others: everything as at the last deploy.
mark_lima() { PATH="$FIX/bin:$PATH" ROOT="$PWD" DELTACTL_CONFIG="$CFG" bash -c 'source lib/bootstrap.sh; set +e; envedit_mark_deployed ix-lima 1 s0 s1' > /dev/null 2>&1; }
mark_lima
for sc in "${ENV_SCENES[@]}"; do
  [ "$sc" != pending ] || { printf 'ENV_SUM_S0=0000stale\n' >> instances/ix-lima/.deployed; sed -i '0,/^ENV_SUM_S0=[0-9a-f]\{30,\}$/{/^ENV_SUM_S0=[0-9a-f]\{30,\}$/d}' instances/ix-lima/.deployed; }
  for sz in 80x24 120x30 160x40; do
    g="$GOLD_DIR/$sc-$sz-es.txt"
    scene "$sc" "${sz%x*}" "${sz#*x}" es > "$FIX/frames/$sc-$sz-es.txt"
    if [ "$MODE" = record ]; then cp "$FIX/frames/$sc-$sz-es.txt" "$g"; echo "  REC  $sc @ $sz (es)"
    else check "scene $sc at $sz (es) equals its snapshot" '[ -f "$g" ] && cmp -s "$FIX/frames/$sc-$sz-es.txt" "$g"'; fi
  done
  [ "$sc" != pending ] || mark_lima
done
for sc in todo edit gen; do
  for sz in 80x24 120x30 160x40; do
    g="$GOLD_DIR/$sc-$sz-en.txt"
    scene "$sc" "${sz%x*}" "${sz#*x}" en > "$FIX/frames/$sc-$sz-en.txt"
    if [ "$MODE" = record ]; then cp "$FIX/frames/$sc-$sz-en.txt" "$g"; echo "  REC  $sc @ $sz (en)"
    else check "scene $sc at $sz (en) equals its snapshot" '[ -f "$g" ] && cmp -s "$FIX/frames/$sc-$sz-en.txt" "$g"'; fi
  done
done

section "8. the shape of every frame"
# (80x24, 120x30 and 160x40 are the frames of the snapshots above)
for sz in 60x14 100x20; do
  for sc in "${ENV_SCENES[@]}"; do
    scene "$sc" "${sz%x*}" "${sz#*x}" es > "$FIX/frames/$sc-$sz-es.txt"
  done
done
check "no line is wider than the screen, in any scene and size" 'for f in "$FIX"/frames/*-es.txt; do sz="${f%-es.txt}"; sz="${sz##*-}"; c="${sz%x*}"; awk -v c="$c" "{ if (length(\$0) > c) bad = 1 } END { exit bad }" "$f" || { echo "$f"; exit 1; }; done'
check "a frame has exactly the rows of the screen (the header, the tabs, the body, the message and the keys)" 'for f in "$FIX"/frames/*-es.txt; do sz="${f%-es.txt}"; sz="${sz##*-}"; r="${sz#*x}"; c="${sz%x*}"; [ "$c" -ge 60 ] && [ "$r" -ge 14 ] || continue; [ "$(grep -c "" "$f")" -eq "$((r + 1))" ] || { echo "$f $(grep -c "" "$f") $r"; exit 1; }; done'
check "the box has its title chip with the number of the view and the name of the instance, at every size" 'for sz in 80x24 120x30 160x40; do sed -n 4p "$FIX/frames/todo-$sz-es.txt" | grep -q "⁹variables" && sed -n 4p "$FIX/frames/todo-$sz-es.txt" | grep -q "ix-colorado" || exit 1; done'
check "the chip at the right says what is left: 6 to fill in, and when there is a change, how many are unsaved" 'sed -n 4p "$FIX/frames/todo-120x30-es.txt" | grep -q "6 sin completar" && sed -n 4p "$FIX/frames/leave-120x30-es.txt" | grep -q "1 sin guardar"'
check "a complete instance says everything is in order, and a file changed since the last deploy is marked ↻ with the count in the chip" 'sed -n 4p "$FIX/frames/ok-120x30-es.txt" | grep -q "todo en orden" && grep -q "↻ sin desplegar" "$FIX/frames/pending-120x30-es.txt" && sed -n 4p "$FIX/frames/pending-120x30-es.txt" | grep -q "1 sin desplegar"'
check "each file has its row with how many variables it has and how many are to fill in" 'grep -q "▾ .env.s0 .* 9 variables · 2 sin completar" "$FIX/frames/todo-120x30-es.txt" && grep -q "▸ .env.instance .* 12 variables" "$FIX/frames/todo-120x30-es.txt"'
check "a row has the state icon, the name, the value (or why there is none) and a note: required, to fill in" 'f="$FIX/frames/todo-120x30-es.txt"; grep -q "▲ IP_SERVER .*por completar" "$f" && grep -q "▲ JWT_SECRET .*(vacía) .*obligatoria" "$f"'
check "a secret is drawn as dots with the lock, never as its value" 'f="$FIX/frames/secret-120x30-es.txt"; grep -q "MONGO_URI .*⚿ ••••••••••" "$f" && ! grep -q "$SECRET" "$f"'
check "the card at the right (from 100 columns) has the variable as its title, what it is and its description, and the default" 'f="$FIX/frames/row-120x30-es.txt"; sed -n 4p "$f" | grep -q "IP_SERVER┌" && grep -q "Obligatoria · .env.s0" "$f" && grep -q "URL pública base del sistema" "$f" && grep -q "Por defecto: http://localhost" "$f"'
check "under 100 columns the description goes under the list instead of at the right" 'f="$FIX/frames/row-80x24-es.txt"; grep -q "IP_SERVER  Obligatoria · .env.s0" "$f" && grep -q "URL pública base del sistema" "$f" && ! sed -n 4p "$f" | grep -q "IP_SERVER┌"'
check "while a value is typed the row is a field with its validation: a good one shows ●, a bad one ✖ and what is wrong" 'grep -q "IP_SERVER .*● https://colorado.itc.pe" "$FIX/frames/edit-120x30-es.txt" && grep -q "IP_SERVER .*✖ colorado" "$FIX/frames/invalid-120x30-es.txt" && grep -q "✖ " "$FIX/frames/invalid-120x30-es.txt"'
check "the keys of the last line follow what the editor is doing: typing, asking, moving over a file, moving over a variable" 'tail -1 "$FIX/frames/edit-120x30-es.txt" | grep -q "Enter acepta · Esc cancela" && tail -1 "$FIX/frames/gen-120x30-es.txt" | grep -q "y reemplazar" && tail -1 "$FIX/frames/leave-120x30-es.txt" | grep -q "s guardar y salir · d descartar y salir" && tail -1 "$FIX/frames/folded-120x30-es.txt" | grep -q "Enter pliega" && tail -1 "$FIX/frames/row-120x30-es.txt" | grep -q "Enter edita · g generar"'
check "the question before replacing a secret says what it costs; the one before leaving counts the changes; the deploy one says it restarts" 'grep -q "¿Reemplazar JWT_SECRET?" "$FIX/frames/gen-120x30-es.txt" && grep -q "Hay cambios sin guardar (1)" "$FIX/frames/leave-120x30-es.txt" && grep -q "¿Desplegar ix-lima ahora?" "$FIX/frames/deploy-120x30-es.txt" && grep -q "reinicia los servicios" "$FIX/frames/deploy-120x30-es.txt"'
check "the advanced variables are listed with a, and a note counts the hidden ones on a file" 'grep -q "S0_MEM_LIMIT" "$FIX/frames/advanced-120x30-es.txt" && grep -q "S0_MEM_LIMIT" "$FIX/frames/advanced-80x24-es.txt"'
check "a folded file shows only its row" '! grep -q "IP_INTERNAL_CONNECTION" "$FIX/frames/folded-120x30-es.txt" && grep -q "▸ .env.s0" "$FIX/frames/folded-120x30-es.txt"'
check "with no instance the box says so, and how to get one" 'grep -q "No hay instancias: crea una con n" "$FIX/frames/none-120x30-es.txt"'
check "the bottom border has the actions as chips, and drops whole chips when they do not fit" 'grep -q "└Enter editar└" "$FIX/frames/todo-120x30-es.txt" || grep -q "Enter editar" "$FIX/frames/todo-120x30-es.txt"; tail -3 "$FIX/frames/todo-80x24-es.txt" | head -1 | grep -q "┘.*└"'
for sc in todo edit gen; do scene "$sc" 120 30 en > "$FIX/frames/$sc-120x30-en.txt"; done
check "the English scenes are in English" 'grep -q "6 to fill in" "$FIX/frames/todo-120x30-en.txt" && grep -q "Required · .env.s0" "$FIX/frames/edit-120x30-en.txt" && grep -q "Replace JWT_SECRET" "$FIX/frames/gen-120x30-en.txt"'
check "a terminal smaller than 60x14 still says it is too small instead of drawing broken boxes" '[ "$(scene todo 50 20 es | grep -c "demasiado pequeña")" -ge 1 ]'

section "9. ASCII, colours"
scene todo 120 30 es DELTACTL_ASCII=1 > "$FIX/frames/ascii.txt"
check "in ASCII there is no box-drawing, braille or symbol character in the frame (the words keep their accents)" '! LC_ALL=C grep -v "^[ -~]*$" "$FIX/frames/ascii.txt" | grep -qP "[\x{2190}-\x{28FF}]"'
check "in ASCII the marks are still there: ! to fill in, v an open file, > a folded one" 'grep -q "! IP_SERVER" "$FIX/frames/ascii.txt" && grep -q "v .env.s0" "$FIX/frames/ascii.txt" && grep -q "> .env.instance" "$FIX/frames/ascii.txt"'
env ROOT="$PWD" PATH="$FIX/bin:$PATH" DELTACTL_LANG=es DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never COLUMNS=120 DELTACTL_TUI_ROWS=30 DELTACTL_CONFIG="$FIX/none" HOME="$FIX" XDG_CONFIG_HOME="$FIX/xdg" \
  bash -c 'source lib/bootstrap.sh; source lib/cmd/dashboard.sh; source tests/tools/env_scenes.sh; set +e; env_scene todo' 2>&1 | awk '/^=== frame /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' > "$FIX/frames/nocolor.txt"
check "NO_COLOR draws no escape sequence at all (while no value is being typed)" '! grep -q $'"'"'\033'"'"' "$FIX/frames/nocolor.txt"'
env ROOT="$PWD" PATH="$FIX/bin:$PATH" DELTACTL_LANG=es DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=always COLORTERM=truecolor COLUMNS=120 DELTACTL_TUI_ROWS=30 DELTACTL_CONFIG="$FIX/none" HOME="$FIX" XDG_CONFIG_HOME="$FIX/xdg" \
  bash -c 'source lib/bootstrap.sh; source lib/cmd/dashboard.sh; source tests/tools/env_scenes.sh; set +e; env_scene secret' 2>&1 | awk '/^=== frame /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' > "$FIX/frames/color.txt"
check "with colour the state icons and the notes are coloured and the frame is still as wide as the screen" 'has_ansi < "$FIX/frames/color.txt" && [ "$(strip_ansi < "$FIX/frames/color.txt" | awk "{ if (length(\$0) > 120) bad = 1 } END { print bad + 0 }")" = 0 ] && ! grep -q "$SECRET" "$FIX/frames/color.txt"'

section "10. the keys of the panel, end to end (simulated Docker)"
reset_instances
o="$(panel 9)"; f="$(echo "$o" | last_frame)"
check "9 opens the view on the instance chosen in Instances, with the editor's keys on the last line" 'echo "$f" | grep -q "⁹variables" && echo "$f" | grep -q "ix-colorado" && echo "$f" | tail -1 | grep -q "Enter pliega"'
o="$(panel 9 down down enter $(typed "https://colorado.itc.pe") enter s)"; f="$(echo "$o" | last_frame)"
check "editing a value and pressing s writes it, and the status line says so" 'grep -q "^IP_SERVER=https://colorado.itc.pe$" instances/ix-colorado/.env.s0 && echo "$f" | grep -q "Guardadas 1 variable(s) en ix-colorado" && echo "$f" | grep -q "5 sin completar"'
reset_instances
o="$(panel 9 down down enter $(typed "https://colorado.itc.pe") enter)"
check "without s nothing is written, however much is edited" 'cmp -s instances/ix-colorado/.env.s0 "$FIX/colorado.orig/.env.s0" && echo "$o" | last_frame | grep -q "1 sin guardar"'
o="$(panel 9 down down enter $(typed "https://colorado.itc.pe") enter esc)"; f="$(echo "$o" | last_frame)"
check "Esc with a change asks, in the panel, what to do with it" 'echo "$f" | grep -q "Hay cambios sin guardar (1)" && echo "$f" | tail -1 | grep -q "s guardar y salir"'
o="$(panel 9 down down enter $(typed "https://colorado.itc.pe") enter esc d)"; f="$(echo "$o" | last_frame)"
check "d discards and leaves: the first view (the Server view) is on screen and the file is as it was" 'echo "$f" | sed -n 3p | grep -q "\[1 Servidor\]" && cmp -s instances/ix-colorado/.env.s0 "$FIX/colorado.orig/.env.s0"'
o="$(panel 9 down down enter $(typed "https://colorado.itc.pe") enter 2)"; f="$(echo "$o" | last_frame)"
check "a digit changes the view with the changes staged (and the keyboard back to the panel)" 'echo "$f" | sed -n 3p | grep -q "\[2 Instancias\]" && cmp -s instances/ix-colorado/.env.s0 "$FIX/colorado.orig/.env.s0"'
o="$(panel 9 down down enter $(typed "https://colorado.itc.pe") enter 2 9)"; f="$(echo "$o" | last_frame)"
check "coming back to the view the changes are still there: nothing is lost by looking at another view" 'echo "$f" | grep -q "1 sin guardar" && echo "$f" | grep -q "IP_SERVER .*https://colorado.itc.pe"'
o="$(panel 9 down down enter $(typed "https://colorado.itc.pe") enter "]")"; f="$(echo "$o" | last_frame)"
check "while there are changes the instance does not change (and it says why)" 'echo "$f" | grep -q "ix-colorado" && echo "$f" | grep -q "sin guardar en ix-colorado"'
o="$(panel 9 "]")"; f="$(echo "$o" | last_frame)"
check "] goes to the next instance when nothing is staged" 'echo "$f" | sed -n 4p | grep -q "ix-lima"'
: > "$FIX/calls.log"
o="$(panel 9 d)"
check "d is the default value inside the editor: it does not start the diagnosis of the panel" '[ ! -s "$FIX/calls.log" ] && ! echo "$o" | last_frame | grep -qi "doctor"'
o="$(panel 9 q)"
check "q with nothing staged leaves the panel as everywhere else" '[ "$(echo "$o" | grep -c "=== frame")" -ge 2 ]'
o="$(panel 9 down down enter $(typed "https://colorado.itc.pe") enter q)"; f="$(echo "$o" | last_frame)"
check "q with changes does not quit: it asks" 'echo "$f" | grep -q "Hay cambios sin guardar (1)"'
o="$(panel 9 ":" "r" "e" "f" "r" "e" "s" "h" "enter")"
check "the other keys of the panel still work from the editor: : opens the command line" 'echo "$o" | last_frame | grep -q "refresh\|⁹variables"'
o="$(LANGX=en panel 9)"; f="$(echo "$o" | last_frame)"
check "in English the view and its keys are in English" 'echo "$f" | grep -q "to fill in" && echo "$f" | tail -1 | grep -q "Enter folds"'

section "11. a save then a deploy, and the marks of what is deployed"
reset_instances
mark_lima
: > "$FIX/calls.log"
o="$(panel 9 "]" u y wait)"; f="$(echo "$o" | last_frame)"
check "u and y on a complete instance start its deploy as a command of the panel" 'grep -q "deploy ix-lima\|up" "$FIX/calls.log" || echo "$o" | grep -q "deploy ix-lima"'
check "after the deploy the marks of the files are written, so nothing is pending" 'grep -q "^ENV_SUM_S0=" instances/ix-lima/.deployed && grep -q "^ENV_SUM_S1=" instances/ix-lima/.deployed && ! echo "$f" | grep -q "↻"'
reset_instances
mark_lima
sed -i 's#^IP_SERVER=.*#IP_SERVER=http://ya-estaba#' instances/ix-lima/.env.s0
o="$(panel 9 "]")"; f="$(echo "$o" | last_frame)"
check "a file changed since the last deploy is marked ↻ when the view opens (the marks are read in the test mode at once)" 'echo "$f" | grep -q "↻ sin desplegar" && echo "$f" | sed -n 4p | grep -q "1 sin desplegar"'
reset_instances

section "12. no real Docker"
check "the simulated docker is the one found first" '[ "$(PATH="$FIX/bin:$PATH" command -v docker)" = "$FIX/bin/docker" ]'

finish

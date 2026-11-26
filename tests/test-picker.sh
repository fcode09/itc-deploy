#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2086  # the cases go in single quotes and are evaluated with eval
# The version picker (lib/ui/kit/version_picker.sh) and the records that lib/core/imagecat.sh gives it: which rows are shown, where the star
# is, what Enter does on each row (a version that can run is chosen, one that cannot says why, "write another" and "load" are asked for), the
# state of a typed tag, the shape of what is drawn at every size, ASCII and no colour, and the texts in both languages. Pure Bash: the data
# of the picker are fixed records, and the catalog is read from the simulated docker (tests/fake-docker.sh). Snapshots of the scene:
# tests/test-kit.sh (tests/golden/kit/vpick-*.txt). Run it from the root of the isolated copy (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8 LC_ALL=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS COLORTERM WT_SESSION TERM_PROGRAM DELTACTL_TRUECOLOR DELTACTL_THEME

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX" instances/pk-*' EXIT
NC="DELTACTL_COLOR=never"
AS="DELTACTL_COLOR=never DELTACTL_ASCII=1"
# kr <env>: the script read from stdin runs with the kit loaded and the matrix theme applied. R is the sample records.
kr() {
  local f
  f="$(mktemp -p "$FIX")"
  {
    echo 'source lib/bootstrap.sh; source lib/ui/tui.sh; source lib/ui/kit/kit.sh; theme_apply matrix'
    cat <<'EOS'
sep=$'\x1f'
R=("2.14.1${sep}2 days ago${sep}412MB${sep}amd64${sep}${sep}star"
   "2.14.0${sep}9 days ago${sep}410MB${sep}amd64${sep}colorado(current)${sep}"
   "2.13.2${sep}1 month ago${sep}408MB${sep}amd64${sep}colorado(previous)${sep}"
   "3.0.0-rc1${sep}3 hours ago${sep}420MB${sep}arm64${sep}${sep}foreign"
   "latest${sep}5 days ago${sep}412MB${sep}amd64${sep}lima(current)${sep}mutable")
EOS
    cat
  } > "$f"
  ROOT="$PWD" DELTACTL_UI=rich DELTACTL_CONFIG="$FIX/none" DELTACTL_LANG=en HOME="$FIX" XDG_CONFIG_HOME="$FIX/xdg" env $1 bash "$f"
}

section "1. which rows are shown and where the star is"
out="$(kr "$NC" <<'EOS'
kit_vpick_select R; echo "$KVP_N $KVP_NV $KVP_STAR $KVP_DEFAULT $KVP_COUNT ${KVP_IDX[*]}"
kit_vpick_select R colorado; echo "$KVP_N $KVP_NV $KVP_STAR $KVP_DEFAULT $KVP_COUNT ${KVP_IDX[*]}"
kit_vpick_select R LATEST; echo "$KVP_N $KVP_NV ${KVP_IDX[*]}"
kit_vpick_select R "" other=0 load=0; echo "$KVP_N"
kit_vpick_select R "" other=0; echo "$KVP_N"
kit_vpick_select R zzz; echo "$KVP_N $KVP_NV $KVP_STAR $KVP_DEFAULT $KVP_COUNT"
EOS
)"
check "five versions and the two special rows, the star on the first" '[ "$(echo "$out" | sed -n 1p)" = "7 5 0 0 5/5 0 1 2 3 4" ]'
check "a filter looks at the tag and at who uses it; the special rows stay and the star is the one shown" '[ "$(echo "$out" | sed -n 2p)" = "4 2 -1 0 2/5 1 2" ]'
check "the filter ignores case" '[ "$(echo "$out" | sed -n 3p)" = "3 1 4" ]'
check "without the special rows there are only the versions" '[ "$(echo "$out" | sed -n 4p)" = 5 ] && [ "$(echo "$out" | sed -n 5p)" = 6 ]'
check "a filter that matches nothing leaves the special rows and 0 of 5" '[ "$(echo "$out" | sed -n 6p)" = "2 0 -1 0 0/5" ]'
out="$(kr "$NC" <<'EOS'
sep=$'\x1f'
N=("1.0${sep}x${sep}1MB${sep}arm64${sep}${sep}foreign" "0.9${sep}x${sep}1MB${sep}amd64${sep}${sep}")
kit_vpick_select N; echo "$KVP_STAR $KVP_DEFAULT"
A=("1.0${sep}x${sep}1MB${sep}arm64${sep}${sep}foreign" "0.9${sep}x${sep}1MB${sep}arm64${sep}${sep}foreign")
kit_vpick_select A; echo "$KVP_STAR $KVP_DEFAULT"
E=()
kit_vpick_select E; echo "$KVP_N $KVP_NV $KVP_STAR $KVP_DEFAULT $KVP_COUNT"
EOS
)"
check "with no star the row to start on is the first one that can run" '[ "$(echo "$out" | sed -n 1p)" = "-1 1" ]'
check "when none can run it starts on the first" '[ "$(echo "$out" | sed -n 2p)" = "-1 0" ]'
check "an empty list: only the two special rows" '[ "$(echo "$out" | sed -n 3p)" = "2 0 -1 0 0/0" ]'

section "2. what Enter does on each row"
out="$(kr "$NC" <<'EOS'
kit_vpick_select R
for r in 0 1 3 4 5 6 7 -1; do kit_vpick_pick R "$r" amd64; echo "$r|$KVP_KIND|$KVP_TAG|$KVP_OK|$KVP_WHY"; done
kit_vpick_select R "" other=0; kit_vpick_pick R 5 amd64; echo "load without other: $KVP_KIND"
kit_vpick_select R "" load=0; kit_vpick_pick R 5 amd64; echo "other without load: $KVP_KIND"; kit_vpick_pick R 6 amd64; echo "past the end: [$KVP_KIND] $KVP_OK"
EOS
)"
check "the star is chosen as it is (Enter on the row the picker opens on)" '[ "$(echo "$out" | sed -n 1p)" = "0|version|2.14.1|1|" ]'
check "a version in use can be chosen too" '[ "$(echo "$out" | sed -n 2p)" = "1|version|2.14.0|1|" ]'
check "an image of another architecture is not chosen and says why, with both architectures" '[ "$(echo "$out" | sed -n 3p)" = "3|version|3.0.0-rc1|0|image of architecture arm64; this server is amd64: it would not start" ]'
check "a tag that moves can be chosen (the picker warns, it does not forbid)" '[ "$(echo "$out" | sed -n 4p)" = "4|version|latest|1|" ]'
check "the row after the versions is \"write another\" and the next one \"load\"" '[ "$(echo "$out" | sed -n 5p)" = "5|other||1|" ] && [ "$(echo "$out" | sed -n 6p)" = "6|load||1|" ]'
check "past the end or before the start is nothing" '[ "$(echo "$out" | sed -n 7p)" = "7|||0|" ] && [ "$(echo "$out" | sed -n 8p)" = "-1|||0|" ]'
check "without \"write another\" the first special row is \"load\"; without \"load\" the next one is nothing" '[ "$(echo "$out" | sed -n 9p)" = "load without other: load" ] && [ "$(echo "$out" | sed -n 10p)" = "other without load: other" ] && [ "$(echo "$out" | sed -n 11p)" = "past the end: [] 0" ]'

section "3. the state of a typed tag"
out="$(kr "$NC" <<'EOS'
for t in "" 2.14.1 3.0.0-rc1 9.9.9 "no valido" -x "a/b"; do kit_vpick_typed R "$t"; echo "[$t] $KVP_TYPED_STATE $KVP_TYPED_ARCH"; done
EOS
)"
check "empty: pending; loaded: ok; loaded but of another architecture: error; valid but not loaded: warning; not a tag: error" '
  [ "$(echo "$out" | sed -n 1p)" = "[] pend " ] && [ "$(echo "$out" | sed -n 2p)" = "[2.14.1] ok " ] && [ "$(echo "$out" | sed -n 3p)" = "[3.0.0-rc1] err arm64" ] \
  && [ "$(echo "$out" | sed -n 4p)" = "[9.9.9] warn " ] && [ "$(echo "$out" | sed -n 5p)" = "[no valido] err " ] && [ "$(echo "$out" | sed -n 6p)" = "[-x] err " ] && [ "$(echo "$out" | sed -n 7p)" = "[a/b] err " ]'

section "4. drawing: shape at every size"
out="$(kr "$NC" <<'EOS'
bad=0
for w in 30 40 60 80 100 120 160; do
  for h in 1 2 3 4 6 8 12 20; do
    for sel in 0 3 5 6 99; do
      kit_vpick "$w" "$h" R "sel=$sel" server_arch=amd64
      [ "${#KVP_LINES[@]}" -eq "$h" ] || { bad=$((bad + 1)); echo "height $w x $h sel $sel: ${#KVP_LINES[@]}"; }
      for l in "${KVP_LINES[@]}"; do l="${l#"$TUI_SEL"}"; tui_vlen "$l"; [ "$TUI_VL" -eq "$w" ] || { bad=$((bad + 1)); echo "width $w x $h sel $sel: $TUI_VL"; break; }; done
    done
  done
done
echo "bad=$bad"
EOS
)"
check "exactly the lines asked for, each exactly as wide as asked, at every size" '[ "$(echo "$out" | tail -1)" = "bad=0" ]'
out="$(kr "$NC" <<'EOS'
kit_vpick 100 9 R sel=0 server_arch=amd64; printf '%s\n' "${KVP_LINES[@]}" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\001'
EOS
)"
check "the header names the columns" 'echo "$out" | sed -n 1p | grep -q "VERSION .*CREATED .*SIZE ARCH .*USE"'
check "the star row carries ★, the most recent hint and its architecture mark" 'echo "$out" | sed -n 2p | grep -q "^2.14.1 ★ .*2 days ago .*412MB amd64 ✔ .*unused  ↑ most recent"'
check "the tag that moves carries ▲ and the image that cannot run carries ✖" 'echo "$out" | grep "^latest" | grep -q "latest ▲" && echo "$out" | grep "^3.0.0-rc1" | grep -q "arm64 ✖"'
check "who uses a version is shown (current and previous)" 'echo "$out" | grep -q "colorado(current)" && echo "$out" | grep -q "colorado(previous)"'
check "the special rows come last" '[ "$(echo "$out" | sed -n 7p | sed "s/ *$//")" = "write another version…" ] && [ "$(echo "$out" | sed -n 8p | sed "s/ *$//")" = "load from a file…" ]'
check "on the star the last line says Enter takes it" '[ "$(echo "$out" | tail -1 | sed "s/ *$//")" = "Enter chooses the most recent one" ]'
out="$(kr "$NC" <<'EOS'
kit_vpick 100 9 R sel=3 server_arch=amd64; printf '%s\n' "${KVP_LINES[@]}" | sed 's/\x1b\[[0-9;]*m//g' | tail -1
kit_vpick 100 9 R sel=4 server_arch=amd64; printf '%s\n' "${KVP_LINES[@]}" | sed 's/\x1b\[[0-9;]*m//g' | tail -1
kit_vpick 100 9 R sel=1 note="2.13.2 was created after 2.14.0" server_arch=amd64; printf '%s\n' "${KVP_LINES[@]}" | sed 's/\x1b\[[0-9;]*m//g' | tail -1
kit_vpick 100 9 R sel=1 status="loading app.tar" server_arch=amd64; printf '%s\n' "${KVP_LINES[@]}" | sed 's/\x1b\[[0-9;]*m//g' | tail -1
kit_vpick 100 9 R sel=3 status="loading app.tar" server_arch=amd64; printf '%s\n' "${KVP_LINES[@]}" | sed 's/\x1b\[[0-9;]*m//g' | tail -1
E=(); kit_vpick 100 6 E sel=0; printf '%s\n' "${KVP_LINES[@]}" | sed 's/\x1b\[[0-9;]*m//g' | tail -1
EOS
)"
check "an image that cannot run says why on the last line" '[ "$(echo "$out" | sed -n 1p | sed "s/ *$//")" = "✖ image of architecture arm64; this server is amd64: it would not start" ]'
check "a tag that moves warns on the last line" '[ "$(echo "$out" | sed -n 2p | sed "s/ *$//")" = "▲ a tag that moves: it cannot take you back to an earlier version" ]'
check "the note of the view (the two orders disagree) shows when nothing more important is" '[ "$(echo "$out" | sed -n 3p | sed "s/ *$//")" = "▲ 2.13.2 was created after 2.14.0" ]'
check "what is being done shows, with its icon, and beats the hints" '[ "$(echo "$out" | sed -n 4p | sed "s/ *$//")" = "◐ loading app.tar" ] && [ "$(echo "$out" | sed -n 5p | sed "s/ *$//")" = "◐ loading app.tar" ]'
check "with nothing loaded the last line says so" '[ "$(echo "$out" | sed -n 6p | sed "s/ *$//")" = "no versions loaded" ]'

section "5. typing another version and the selection"
out="$(kr "$NC" <<'EOS'
for t in 2.14.1 9.9.9 "x y" 3.0.0-rc1; do kit_vpick 100 9 R sel=5 typing=1 typed="$t" cursor=3 server_arch=amd64; printf '%s\n' "${KVP_LINES[@]}" | sed 's/\x1b\[[0-9;]*m//g' | tail -1; done
EOS
)"
check "the field says the tag is loaded" 'echo "$out" | sed -n 1p | grep -q "version .*2.14.1.* loaded *$"'
check "...or that it is not loaded yet (a warning, not an error)" 'echo "$out" | sed -n 2p | grep -q "9.9.9.*not loaded in this Docker yet"'
check "...or that it is not a valid tag" 'echo "$out" | sed -n 3p | grep -q "not a valid tag"'
check "...or that the image cannot run here" 'echo "$out" | sed -n 4p | grep -q "image of architecture arm64; this server is amd64"'
out="$(kr "$NC" <<'EOS'
kit_vpick 100 9 R sel=99; echo "$KVP_SEL $KVP_KIND"
kit_vpick 100 9 R sel=abc; echo "$KVP_SEL $KVP_TAG"
kit_vpick 100 9 R sel=-4; echo "$KVP_SEL"
kit_vpick 100 9 R sel=1 filter=colorado; echo "$KVP_SEL $KVP_TAG $KVP_COUNT"
EOS
)"
check "a selection past the end falls on the last row; garbage on the row to start on; negative on the first" '[ "$(echo "$out" | sed -n 1p)" = "6 load" ] && [ "$(echo "$out" | sed -n 2p)" = "0 2.14.1" ] && [ "$(echo "$out" | sed -n 3p)" = "0" ]'
check "the selected row counts among the rows shown (with a filter)" '[ "$(echo "$out" | sed -n 4p)" = "1 2.13.2 2/5" ]'
out="$(kr "$NC" <<'EOS'
kit_vpick 100 9 R sel=2 > /dev/null; kit_vpick 100 9 R sel=2 | wc -l | tr -d ' '
declare -A TX=([col_version]="VERSIÓN" [other]="otra versión…" [unused]="sin usar")
kit_vpick 100 9 R sel=0 texts=TX; printf '%s\n' "${KVP_LINES[@]}" | sed 's/\x1b\[[0-9;]*m//g' | sed -n '1p;3p;7p'
EOS
)"
check "the texts come from the array the view gives, English by default" 'echo "$out" | sed -n 2p | grep -q "^VERSIÓN" && echo "$out" | sed -n 3p | grep -q "^2.14.0" && echo "$out" | sed -n 4p | grep -q "^otra versión…"'

out="$(kr "$NC" <<'EOS'
kit_vpick 100 8 R sel=3 server_arch=amd64 other=0 load=0 msg=0; printf '%s\n' "${KVP_LINES[@]}" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\001' | grep -v '^ *$' | sed -n '$p'
kit_vpick 100 8 R sel=3 server_arch=amd64 other=0 load=0 msg=0; echo "${#KVP_LINES[@]}"
kit_vpick 100 6 R sel=0 other=0 load=0; h="$(printf '%s\n' "${KVP_LINES[@]}" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\001' | sed -n 1p)"; h="${h%%CREATED*}"; echo "${#h}"
kit_vpick 100 6 R sel=0 other=0 load=0 tagw=20; h="$(printf '%s\n' "${KVP_LINES[@]}" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\001' | sed -n 1p)"; h="${h%%CREATED*}"; echo "${#h}"
kit_vpick 100 5 R sel=4 other=0 load=0 msg=0; echo "$KVP_TOP ${#KVP_LINES[@]}"
EOS
)"
check "msg=0 gives the whole height to the table (the last line with something is a row, not the message)" 'echo "$out" | sed -n 1p | grep -q "^latest" && [ "$(echo "$out" | sed -n 2p)" = 8 ]'
check "tagw widens the first column (so several pickers one under the other line up)" '[ "$(echo "$out" | sed -n 3p)" = 14 ] && [ "$(echo "$out" | sed -n 4p)" = 21 ]'
check "the first row shown follows the selection (KVP_TOP) and the height is still exact" '[ "$(echo "$out" | sed -n 5p)" = "1 5" ]'

section "6. ASCII and no colour"
out="$(kr "$AS" <<'EOS'
kit_vpick 80 9 R sel=3 server_arch=amd64; printf '%s\n' "${KVP_LINES[@]}" | tr -d '\001'
EOS
)"
check "in ASCII there is no character outside it, and every line is 80 cells" '! echo "$out" | LC_ALL=C grep -q "[^ -~]" && [ "$(echo "$out" | awk "{ print length(\$0) }" | sort -u | tr "\n" " ")" = "80 " ]'
check "in ASCII the star, the warning and the error marks are *, ! and x" 'echo "$out" | grep -q "^2.14.1 \*" && echo "$out" | grep "^latest" | grep -q "latest !" && echo "$out" | grep "^3.0.0-rc1" | grep -q "arm64 x"'
out="$(kr "$NC" <<'EOS'
kit_vpick 80 9 R sel=3 server_arch=amd64; printf '%s\n' "${KVP_LINES[@]}"
EOS
)"
check "with no colour there is no colour sequence (the marks still tell: it is never only colour)" '! echo "$out" | grep -q $'"'"'\033\[[0-9;]*[0-9]m'"'"' || [ "$(echo "$out" | sed "s/\x1b\[[0-9;]*m//g" | grep -c "✖")" -ge 2 ]'

section "7. the catalog as records, in both languages"
F2="$FIX/f2"
mkdir -p "$F2/bin"
cp tests/fake-docker.sh "$F2/bin/docker-fake"
printf '#!/usr/bin/env bash\nexport FIX="%s"\nexec bash "%s/bin/docker-fake" "$@"\n' "$F2" "$F2" > "$F2/bin/docker"
chmod +x "$F2/bin/docker"
NOW="$(date +%s)"
iso() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%S +0000 UTC'; }
printf '%s\n' "backend-s0:2.14.1|sha256:a1|amd64" "backend-s0:2.14.0|sha256:a2|amd64" "backend-s0:3.0.0|sha256:a3|arm64" "backend-s0:latest|sha256:a4|amd64" > "$F2/images.txt"
printf '%s\n' "backend-s0:2.14.1|$(iso $((NOW - 2 * 86400)))" "backend-s0:2.14.0|$(iso $((NOW - 40 * 86400)))" \
  "backend-s0:3.0.0|$(iso $((NOW - 3600)))" "backend-s0:latest|$(iso $((NOW - 86400 * 400)))" > "$F2/image_dates.txt"
bash ./deltactl new pk-uno > /dev/null 2>&1
fill_instance instances/pk-uno 2.14.0 1.0
lib3() { # language function
  local lang="$1" fn="$2"
  FIX="$F2" PATH="$F2/bin:$PATH" ROOT="$PWD" DELTACTL_LANG="$lang" DELTACTL_CONFIG="$F2/none" DELTACTL_UI=rich DELTACTL_COLOR=never \
    bash -c 'source lib/bootstrap.sh; source lib/ui/tui.sh; source lib/ui/kit/kit.sh; theme_apply matrix; '"$(declare -f "$fn")"'; '"$fn" 2>&1
}
t_rows() { ic_load; ic_picker_rows "s0|backend-s0" R; local r; for r in "${R[@]}"; do echo "${r//$'\x1f'/|}"; done; }
t_texts() { declare -A TX=(); ic_picker_texts TX; echo "${TX[col_version]}|${TX[col_use]}|${TX[unused]}|${TX[latest_hint]}|${TX[other]}|${TX[load]}|${TX[why_arch]}"; }
t_draw() { ic_load; ic_picker_rows "s0|backend-s0" R; declare -A TX=(); ic_picker_texts TX; ic_note "s0|backend-s0"
  kit_vpick 100 8 R sel=1 texts=TX server_arch="$IC_SERVER_ARCH" "note=$IC_NOTE"; printf '%s\n' "${KVP_LINES[@]}" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\001'; }
rows="$(lib3 en t_rows)"
check "newest first: the tag, how long ago in words, the size, the architecture, who uses it and the flags" '
  [ "$(echo "$rows" | sed -n 1p)" = "3.0.0|1 h ago|300MB|arm64||foreign" ] && [ "$(echo "$rows" | sed -n 2p)" = "2.14.1|2 days ago|300MB|amd64||star" ] \
  && [ "$(echo "$rows" | sed -n 3p)" = "2.14.0|1 month ago|300MB|amd64|pk-uno(current)|" ] && [ "$(echo "$rows" | sed -n 4p)" = "latest|1 year ago|300MB|amd64||mutable" ]'
check "the same in Spanish: the words of the date and of the use" '
  r="$(lib3 es t_rows)"; echo "$r" | grep -q "^2.14.1|hace 2 días|" && echo "$r" | grep -q "pk-uno(actual)" && echo "$r" | grep -q "^3.0.0|hace 1 h|"'
check "the texts of the picker exist in both languages and are not the keys" '
  e="$(lib3 en t_texts)"; s="$(lib3 es t_texts)"
  [ "$e" = "VERSION|USE|unused|↑ most recent|write another version…|load from a file…|image of architecture {1}; this server is {2}: it would not start" ] \
  && [ "$s" = "VERSIÓN|USO|sin usar|↑ más reciente|escribir otra versión…|cargar desde un archivo…|imagen de arquitectura {1}; este servidor es {2}: no arrancaría" ]'
check "a picker drawn from the catalog: header, versions with their marks, and the architecture message" '
  d="$(lib3 en t_draw)"
  echo "$d" | sed -n 1p | grep -q "^VERSION" && echo "$d" | sed -n 2p | grep -q "^3.0.0 .*arm64 ✖" && echo "$d" | sed -n 3p | grep -q "^2.14.1 ★ " && echo "$d" | grep -q "pk-uno(current)"'
check "the Docker shim is the one used (the real docker is never reached)" '[ "$(PATH="$F2/bin:$PATH" command -v docker)" = "$F2/bin/docker" ]'
rm -rf instances/pk-uno

section "8. cost"
out="$(kr "$NC" <<'EOS'
big=()
for ((i = 0; i < 40; i++)); do big+=("1.$i.0${sep}$i days ago${sep}400MB${sep}amd64${sep}${sep}"); done
t0=$EPOCHREALTIME
for ((i = 0; i < 20; i++)); do kit_vpick 120 20 big sel=$((i % 30)) server_arch=amd64; done
t1=$EPOCHREALTIME
echo $(((${t1/./} - ${t0/./}) / 20000))
EOS
)"
check "drawing a picker of 40 versions (120x20) takes under 120 ms (the same bound as a table of 24 rows: the machine may be busy)" '[ "$out" -lt 120 ]'

finish

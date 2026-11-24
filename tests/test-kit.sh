#!/usr/bin/env bash
# UI kit of the redesign (lib/ui/kit/*.sh): the box with chips in its border, the shortcut markup, overlays, and the golden
# snapshots of the kit scenes (tests/tools/kit_scenes.sh) at 80, 120 and 160 columns. Pure Bash: no Docker, no terminal.
# Snapshots: tests/golden/kit/<scene>-<width>.txt, plain text. DELTACTL_GOLDEN=record rewrites them (only when a change is intended).
# Run it from the root of the isolated copy (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8 LC_ALL=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS COLORTERM WT_SESSION TERM_PROGRAM DELTACTL_TRUECOLOR DELTACTL_THEME

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
TC="DELTACTL_COLOR=always COLORTERM=truecolor"
NC="DELTACTL_COLOR=never"
AS="DELTACTL_COLOR=never DELTACTL_ASCII=1"
# kr <env>: runs the script read from stdin with the kit loaded and the matrix theme applied
kr() {
  local f
  f="$(mktemp -p "$FIX")"
  { echo 'source lib/bootstrap.sh; source lib/ui/tui.sh; source lib/ui/kit/kit.sh; theme_apply matrix'; cat; } > "$f"
  ROOT="$PWD" DELTACTL_UI=rich DELTACTL_CONFIG="$FIX/none" HOME="$FIX" XDG_CONFIG_HOME="$FIX/xdg" env $1 bash "$f"
}

section "1. shortcut markup"
out="$(kr "$NC" <<'EOS'
kit_plain 'a^bc {Enter} x'; echo "[$KIT_OUT]"
kit_plain 'a^^b {{c'; echo "[$KIT_OUT]"
kit_plain 'end^'; echo "[$KIT_OUT]"
kit_plain '{open'; echo "[$KIT_OUT]"
EOS
)"
check "kit_plain removes ^x and {key} and keeps ^^ and {{ as the character" '[ "$out" = "$(printf "[abc Enter x]\n[a^b {c]\n[end^]\n[{open]")" ]'
out="$(kr "$TC" <<'EOS'
kit_hotkey 'a^bc'; printf '%q\n' "$KIT_OUT"
kit_hotkey 'a^bc' "X"; case "$KIT_OUT" in *b*"X"c) echo returns-to-base ;; esac
EOS
)"
check "kit_hotkey draws the letter in the hotkey colour, bold, and returns to the base colour after it" '[[ "$out" == *"[1m"*"b"* ]] && [[ "$out" == *returns-to-base* ]] && [[ "$(echo "$out" | head -1)" == *"38;2;0;255;102"* ]]'
out="$(kr "$NC" <<'EOS'
kit_hotkey 'a^bc {Enter} z'; echo "[$KIT_OUT]"
EOS
)"
check "without colour the highlighted text is the plain text (no markup left behind)" '[ "$out" = "[abc Enter z]" ]'
out="$(kr "$NC" <<'EOS'
kit_sup 12; echo "$KIT_OUT"; kit_chip_label '3:net' ''; echo "$KIT_OUT"; kit_chip_label '12:net' ''; echo "$KIT_OUT"
EOS
)"
check "N: before a chip label is a superscript digit; only one digit counts as a number" '[ "$out" = "$(printf "¹²\n³net\n12:net")" ]'
out="$(kr "$AS" <<'EOS'
kit_chip_label '3:net' ''; echo "$KIT_OUT"
EOS
)"
check "in ASCII the number is a plain digit" '[ "$out" = "3net" ]'

section "2. box: size, chips, status, footer"
out="$(kr "$NC" <<'EOS'
bad=0
body=(one two)
for w in 12 20 26 40 60 80 120 160; do
  for opt in 'chips=1:cpu|^menu|^preset *' 'chips=1:a|b|c|d|e|f|g|h|i|j|k' 'chips=4:proc status=2000ms' 'footer={Enter} abrir|^n nueva|^x salir' 'chips=1:s0 status=ok footer=^a|^b|^c|^d|^e|^f' ''; do
    for h in 3 6; do
      kit_box "$w" "$h" body $opt focus=0
      [ "${#KIT_BOX[@]}" -eq "$h" ] || bad=$((bad + 1))
      for l in "${KIT_BOX[@]}"; do tui_vlen "$l"; [ "$TUI_VL" -eq "$w" ] || { bad=$((bad + 1)); echo "w=$w h=$h opt=$opt got $TUI_VL: $l" >&2; }; done
    done
  done
done
echo "$bad"
EOS
)"
check "a box is always exactly <width> x <height> cells, with any chips, status and footer (widths 12..160)" '[ "$out" = "0" ]'
out="$(kr "$NC" <<'EOS'
body=(one)
kit_box 40 3 body 'chips=1:cpu|menu'
echo "${KIT_BOX[0]}"
EOS
)"
check "the title chips sit in the top border between the corner and the line" '[ "$out" = "╭─┐¹cpu┌─┐menu┌────────────────────────╮" ]'
out="$(kr "$NC" <<'EOS'
body=(one)
kit_box 40 3 body 'chips=1:cpu' 'status=21%'
echo "${KIT_BOX[0]}"
EOS
)"
check "the status chip sits at the right of the top border" '[ "$out" = "╭─┐¹cpu┌─────────────────────────┐21%┌─╮" ]'
out="$(kr "$NC" <<'EOS'
body=(one)
kit_box 40 3 body 'footer={Enter} abrir|^n nueva'
echo "${KIT_BOX[2]}"
EOS
)"
check "the footer chips sit in the bottom border with the mirrored delimiters" '[ "$out" = "╰─┘Enter abrir└─┘n nueva└──────────────╯" ]'
out="$(kr "$NC" <<'EOS'
body=(one)
kit_box 18 3 body 'chips=1:cpu' 'status=a long status'
echo "${KIT_BOX[0]}"
EOS
)"
check "when it does not fit, the status goes before any title chip" '[ "$out" = "╭─┐¹cpu┌─────────╮" ]'
out="$(kr "$NC" <<'EOS'
body=(one)
kit_box 40 3 body 'chips=1:aa|bb|cc|dd|ee|ff|gg|hh|ii|jj'
echo "${KIT_BOX[0]}"
EOS
)"
check "title chips that do not fit are dropped from the end (the first ones stay)" '[[ "$out" == *"¹aa"* ]] && [[ "$out" == *"bb"* ]] && [[ "$out" != *"jj"* ]] && [[ "$out" != *"ii"* ]]'
out="$(kr "$NC" <<'EOS'
body=(one)
kit_box 36 3 body 'footer=^a first|^b second|^c third|^d fourth|^e fifth|^f sixth'
echo "${KIT_BOX[2]}"
EOS
)"
check "footer items that do not fit are dropped whole: the first ones and the last two stay" '[[ "$out" == *"a first"* ]] && [[ "$out" == *"e fifth"* ]] && [[ "$out" == *"f sixth"* ]] && [[ "$out" != *"c third"* ]] && [[ "$out" != *"d fourth"* ]]'
out="$(kr "$NC" <<'EOS'
body=(one)
kit_box 16 3 body 'footer=^a first item|^b second item'
echo "${KIT_BOX[2]}"
EOS
)"
check "a single chip wider than the box is cut, never wider than the box" '[ "$(printf "%s" "$out" | wc -m)" -eq 16 ]'
out="$(kr "$NC" <<'EOS'
body=(one)
kit_box 20 3 body
echo "${KIT_BOX[0]}${KIT_BOX[2]}"
EOS
)"
check "no chips: a plain rounded border" '[ "$out" = "╭──────────────────╮╰──────────────────╯" ]'

section "3. box: focus, selection, colour, ASCII"
out="$(kr "$NC" <<'EOS'
body=(one)
kit_box 30 3 body 'chips=1:lista|filtro' focus=1
echo "${KIT_BOX[0]}"
kit_box 30 3 body 'chips=1:lista|filtro' focus=0
echo "${KIT_BOX[0]}"
EOS
)"
check "focus without colour is marked with the selection symbol in front of the first chip" '[ "$(echo "$out" | head -1)" = "╭─┐ ▸¹lista ┌─┐filtro┌───────╮" ] && [ "$(echo "$out" | tail -1)" = "╭─┐¹lista┌─┐filtro┌──────────╮" ]'
out="$(kr "$TC" <<'EOS'
body=(one)
kit_box 30 3 body 'chips=1:lista' focus=1
a="${KIT_BOX[0]}"
kit_box 30 3 body 'chips=1:lista' focus=0
b="${KIT_BOX[0]}"
[[ "$a" == *"${TH[border_focus]}"* ]] && [[ "$a" == *"${TH[badge]}"* ]] && echo focus-colours
[[ "$b" == *"${TH[border]}"* ]] && [[ "$b" != *"${TH[badge]}"* ]] && echo normal-colours
EOS
)"
check "focus uses the focus border colour and a badge for the first chip; an unfocused box uses the plain border" '[ "$out" = "$(printf "focus-colours\nnormal-colours")" ]'
out="$(kr "$TC" <<'EOS'
body=("${TUI_SEL}picked" "other")
kit_box 20 4 body
[[ "${KIT_BOX[1]}" == *"${TH[sel]}"* ]] && [[ "${KIT_BOX[2]}" != *"${TH[sel]}"* ]] && echo sel
printf '%s' "${KIT_BOX[1]}" | grep -c $'\001'
EOS
)"
check "a body line that starts with the selection marker is drawn as the selected row (and the marker never shows)" '[ "$out" = "$(printf "sel\n0")" ]'
out="$(kr "$TC" <<'EOS'
body=(one)
kit_box 20 3 body "color=$(printf '\033')[31m"
case "${KIT_BOX[0]}" in $'\033[31m'*) echo own-colour ;; esac
EOS
)"
check "color= overrides the border colour" '[ "$out" = "own-colour" ]'
out="$(kr "$AS" <<'EOS'
body=(one)
kit_box 30 4 body 'chips=1:cpu|^menu' 'status=ok' 'footer={Enter} go|^q quit'
printf '%s\n' "${KIT_BOX[@]}"
EOS
)"
check "ASCII: +-| borders and [ ] chip delimiters, same widths" '[ "$out" = "$(printf "%s\n%s\n%s\n%s" "+-[1cpu]-[menu]---------[ok]-+" "| one                        |" "|                            |" "+-[Enter go]-[q quit]--------+")" ]'

section "4. slice and overlay"
out="$(kr "$TC" <<'EOS'
line="${TH[err]}red${TH_RESET}${TH[ok]}green${TH_RESET}"
kit_slice "$line" 2 5; piece="$KIT_OUT"
tui_vlen "$piece"; echo "$TUI_VL"
tui_strip_ansi "$piece"; echo "$TUI_OUT"
[[ "$piece" == "${TH[err]}"* ]] && echo keeps-colour-before-cut
EOS
)"
check "kit_slice cuts by visible cells, keeps the colour that was active, and pads to the width" '[ "$out" = "$(printf "5\ndgree\nkeeps-colour-before-cut")" ]'
out="$(kr "$NC" <<'EOS'
kit_slice "abc" 1 6; echo "[$KIT_OUT]"
kit_slice "abcdef" 0 3; echo "[$KIT_OUT]"
kit_slice "abcdef" 3 3; echo "[$KIT_OUT]"
EOS
)"
check "kit_slice pads short text, takes the head and the tail of a line" '[ "$out" = "$(printf "[bc    ]\n[abc]\n[def]")" ]'
out="$(kr "$NC" <<'EOS'
base=("0123456789" "abcdefghij" "ABCDEFGHIJ")
ins=("XX" "YY")
kit_overlay base 1 ins 3
printf '%s\n' "${base[@]}"
EOS
)"
check "kit_overlay lays an inset over the base at the given row and column and keeps the rest" '[ "$out" = "$(printf "0123456789\nabcXXfghij\nABCYYFGHIJ")" ]'
out="$(kr "$NC" <<'EOS'
base=("0123456789" "abcdefghij")
ins=("XXXX" "YYYY" "ZZZZ")
kit_overlay base 1 ins 8
kit_overlay base 5 ins 0
kit_overlay base -1 ins 20
printf '%s\n' "${base[@]}"
EOS
)"
check "an inset that sticks out of the base is cut; rows or columns outside it are ignored" '[ "$out" = "$(printf "0123456789\nabcdefghXX")" ]'
out="$(kr "$TC" <<'EOS'
base=("${TH[ok]}0123456789${TH_RESET}" "${TH[ok]}abcdefghij${TH_RESET}")
body=(q)
kit_box 4 3 body
box=("${KIT_BOX[@]}")
kit_overlay base 0 box 3
bad=0
for l in "${base[@]}"; do tui_vlen "$l"; [ "$TUI_VL" -eq 10 ] || bad=1; done
echo $bad
EOS
)"
check "overlaying on coloured lines keeps every line the same width" '[ "$out" = "0" ]'

section "5. cost"
out="$(kr "$NC" <<'EOS'
body=(); for i in $(seq 1 18); do body+=("line $i of the body"); done
t0="${EPOCHREALTIME/./}"
for i in $(seq 1 20); do kit_box 160 20 body 'chips=1:cpu|^menu|^preset *' 'status=2000ms' 'footer={↑} select|{↓} info|{Enter} ^terminate|^kill|^signals|^Nice|^Follow' focus=1; done
t1="${EPOCHREALTIME/./}"
echo $(((t1 - t0) / 20000))
EOS
)"
check "drawing a 160x20 box with chips, status and footer takes under 15 ms (no processes)" '[ "$out" -lt 15 ]'

section "6. golden snapshots of the scenes (80, 120 and 160 columns)"
GOLD_DIR="${DELTACTL_GOLDEN_DIR:-tests/golden}/kit"
MODE="${DELTACTL_GOLDEN:-check}"
mkdir -p "$GOLD_DIR" 2> /dev/null || true
scene_text() { # scene width
  kr "$NC" <<EOS
source tests/tools/kit_scenes.sh
kit_scene $1 $2
EOS
}
names="$(kr "$NC" <<'EOS'
source tests/tools/kit_scenes.sh
echo "${KIT_SCENES[*]}"
EOS
)"
for sc in $names; do
  for w in 80 120 160; do
    g="$GOLD_DIR/$sc-$w.txt"
    if [ "$MODE" = record ]; then
      scene_text "$sc" "$w" > "$g"
      echo "  REC  $sc @ $w"
    else
      check "scene $sc at $w columns equals its snapshot" '[ -f "$g" ] && [ "$(scene_text "$sc" "$w")" = "$(cat "$g")" ]'
    fi
  done
done

finish

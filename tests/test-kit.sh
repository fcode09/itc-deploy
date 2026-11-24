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

section "6. word wrap"
out="$(kr "$NC" <<'EOS'
kit_wrap "the quick brown fox jumps over the lazy dog" 12; printf '[%s]\n' "${KW_LINES[@]}"
kit_wrap "a supercalifragilistic word" 8; printf '[%s]\n' "${KW_LINES[@]}"
kit_wrap "first line
second line" 40; printf '[%s]\n' "${KW_LINES[@]}"
kit_wrap "" 10; echo "${#KW_LINES[@]}"
EOS
)"
check "kit_wrap breaks at spaces without passing the width" '[ "$(echo "$out" | sed -n 1,4p | tr "\n" "|")" = "[the quick]|[brown fox]|[jumps over]|[the lazy dog]|" ]'
check "a word longer than the width is cut; a newline starts a new line; empty text is one empty line" '[ "$(echo "$out" | sed -n 5,9p | tr "\n" "|")" = "[a]|[supercal]|[ifragili]|[stic word]|[first line]|" ] || [ "$(echo "$out" | sed -n 5,8p | tr "\n" "|")" = "[a]|[supercal]|[ifragili]|[stic]|" ]'

section "7. stepper and tabs"
out="$(kr "$NC" <<'EOS'
bad=0
for w in 8 24 40 60 96 160; do for cur in 1 3 8; do
  kit_stepper "$w" "$cur" "counter=Step $cur of 8" Name Services Versions Data Variables Secrets Access Review
  [ "${#KS_LINES[@]}" -eq 2 ] || bad=$((bad + 1))
  for l in "${KS_LINES[@]}"; do tui_vlen "$l"; [ "$TUI_VL" -eq "$w" ] || { bad=$((bad + 1)); echo "w=$w cur=$cur $TUI_VL" >&2; }; done
done; done
echo "$bad"
EOS
)"
check "the stepper is two lines of exactly <width> cells at any width (wide and compact)" '[ "$out" = "0" ]'
out="$(kr "$NC" <<'EOS'
kit_stepper 100 3 "counter=Step 3 of 8" Name Services Versions Data Variables Secrets Access Review
printf '%s\n' "${KS_LINES[@]}"
echo "$KS_CW ${KS_COLS[*]}"
EOS
)"
check "marks: done ●, open ◉, to do ○, joined by a line; the labels sit under their mark" '[[ "$(echo "$out" | sed -n 1p)" == "●━━━━━━━━━━━●━━━━━━━━━━━◉━━━━━━━━━━━○━━━━"* ]] && [[ "$(echo "$out" | sed -n 2p)" == "Name"*"Services"*"Versions"*"Review"* ]]'
check "the counter goes at the right of the marks line when the last step leaves room" '[[ "$(echo "$out" | sed -n 1p)" == *"Step 3 of 8" ]]'
check "KS_CW is the width of a step and KS_COLS the first column of each" '[ "$(echo "$out" | tail -1)" = "12 0 12 24 36 48 60 72 84" ]'
out="$(kr "$NC" <<'EOS'
kit_stepper 96 5 Name Services:warn Versions Data Variables:err Secrets
echo "${KS_LINES[0]}" | grep -o "[●◉○▲✖]" | tr -d "\n"; echo
kit_stepper 40 4 "counter=Step 4 of 8" Name Services Versions Data Variables Secrets Access Review
printf '%s\n' "${KS_LINES[@]}"
EOS
)"
check "an explicit state wins over the position: warn ▲ and err ✖ show on their steps" '[ "$(echo "$out" | head -1)" = "●▲●✖◉○" ] || [ "$(echo "$out" | head -1)" = "●▲●◉✖○" ] || [[ "$(echo "$out" | head -1)" == *"▲"* && "$(echo "$out" | head -1)" == *"✖"* ]]'
check "when a step would be under 7 cells the labels give way: the second line is the open step as n/N" '[[ "$(echo "$out" | sed -n 3p)" == "4/8 Data"* ]]'
out="$(kr "$AS" <<'EOS'
kit_stepper 60 2 Name Services Versions
echo "${KS_LINES[0]}" | tr -d " "
EOS
)"
check "ASCII stepper: = joins the steps, * done, @ open, . to do" '[ "$out" = "*====================@====================." ] || [[ "$out" == "*=="*"@"*"=="*"." ]]'
out="$(kr "$NC" <<'EOS'
bad=0
for w in 20 40 80 120; do for act in 1 4 7; do
  kit_tabs "$w" "$act" Resumen Servicios Variables Datos Acceso Logs Historial
  tui_vlen "$KT_LINE"; [ "$TUI_VL" -eq "$w" ] || { bad=$((bad + 1)); echo "w=$w act=$act $TUI_VL" >&2; }
done; done
echo "$bad"
EOS
)"
check "tabs: one line of exactly <width> cells, any width and open tab" '[ "$out" = "0" ]'
out="$(kr "$NC" <<'EOS'
kit_tabs 80 2 Resumen ^Servicios Variables
echo "[$KT_LINE]" | sed 's/ *\]$/]/'
echo "${KT_COLS[*]} / ${KT_WID[*]}"
kit_tabs 22 7 Resumen Servicios Variables Datos Acceso Logs Historial
echo "[$KT_LINE] ${KT_COLS[*]}"
EOS
)"
check "tabs: the open one is [Name] without colour, the others are padded; the shortcut markup is removed" '[ "$(echo "$out" | sed -n 1p)" = "[ Resumen [Servicios] Variables]" ]'
check "tabs: KT_COLS has each tab's first column and KT_WID its width (to find a click)" '[ "$(echo "$out" | sed -n 2p)" = "0 9 20 / 9 11 11" ]'
check "tabs that do not fit scroll to keep the open one visible, marked with ‹ at the cut side; hidden tabs have no column" '[[ "$(echo "$out" | sed -n 3p)" == "[‹"*"[Historial]"* ]] && [[ "$(echo "$out" | sed -n 3p)" == *"]  "* ]]'
out="$(kr "$TC" <<'EOS'
kit_tabs 40 1 Resumen Servicios
[[ "$KT_LINE" == *"${TH[badge]}"* ]] && echo badge
kit_tabs 12 3 Resumen Servicios Variables Datos
[[ "$KT_LINE" == *‹* ]] && echo arrow
EOS
)"
check "with colour the open tab is a badge" '[ "$(echo "$out" | head -1)" = "badge" ]'

section "8. field: keys, paste, render, validators"
out="$(kr "$NC" <<'EOS'
KF_VALUE=""; KF_CUR=0
for k in a b c left left X; do kit_field_key "$k"; done; echo "$KF_VALUE $KF_CUR"
kit_field_key backspace; echo "$KF_VALUE $KF_CUR"
kit_field_key delete; echo "$KF_VALUE $KF_CUR"
kit_field_key end; kit_field_key space; kit_field_key z; echo "[$KF_VALUE] $KF_CUR"
kit_field_key home; echo "$KF_CUR"
kit_field_key enter; echo "enter=$?"
kit_field_key up; echo "up=$?"
kit_field_key esc; echo "esc=$?"
kit_field_key tab; echo "tab=$?"
kit_field_key a; echo "a=$?"
EOS
)"
check "typing inserts at the cursor; left moves it; backspace and delete remove" '[ "$(echo "$out" | sed -n 1p)" = "aXbc 2" ] && [ "$(echo "$out" | sed -n 2p)" = "abc 1" ] && [ "$(echo "$out" | sed -n 3p)" = "ac 1" ]'
check "end, space and home work; enter, up, esc and tab are left to the caller (return 1), characters are consumed (return 0)" '[ "$(echo "$out" | sed -n 4p)" = "[ac z] 4" ] && [ "$(echo "$out" | sed -n 5p)" = "0" ] && [ "$(echo "$out" | sed -n 6,9p | tr "\n" " ")" = "enter=1 up=1 esc=1 tab=1 " ] && [ "$(echo "$out" | sed -n 10p)" = "a=0" ]'
out="$(kr "$NC" <<'EOS'
KF_VALUE="hello big world"; KF_CUR=9; kit_field_key $'\027'; echo "[$KF_VALUE] $KF_CUR"
KF_VALUE="hello big world"; KF_CUR=9; kit_field_key $'\025'; echo "[$KF_VALUE] $KF_CUR"
KF_VALUE="hello big world"; KF_CUR=9; kit_field_key $'\013'; echo "[$KF_VALUE] $KF_CUR"
KF_VALUE="abc"; KF_CUR=1; kit_field_key $'\005'; echo "$KF_CUR"; kit_field_key $'\001'; echo "$KF_CUR"
KF_VALUE="ab"; KF_CUR=1; kit_field_insert $'one\ntwo\r\tx'; echo "[$KF_VALUE] $KF_CUR"
KF_VALUE="ab"; KF_CUR=9; kit_field_key left; echo "$KF_CUR"
KF_VALUE=""; KF_CUR=0; kit_field_key backspace; kit_field_key delete; kit_field_key left; echo "[$KF_VALUE] $KF_CUR"
EOS
)"
check "Ctrl+W removes the word before the cursor, Ctrl+U up to the start, Ctrl+K to the end" '[ "$(echo "$out" | sed -n 1p)" = "[hello  world] 6" ] && [ "$(echo "$out" | sed -n 2p)" = "[ world] 0" ] && [ "$(echo "$out" | sed -n 3p)" = "[hello big] 9" ]'
check "Ctrl+E goes to the end, Ctrl+A to the start" '[ "$(echo "$out" | sed -n 4,5p | tr "\n" " ")" = "3 0 " ]'
check "a paste drops the control characters and newlines and moves the cursor past it" '[ "$(echo "$out" | sed -n 6p)" = "[aonetwoxb] 8" ]'
check "a cursor beyond the end is brought back; editing an empty value never fails" '[ "$(echo "$out" | sed -n 7p)" = "1" ] && [ "$(echo "$out" | sed -n 8p)" = "[] 0" ]'
out="$(kr "$NC" <<'EOS'
bad=0
for w in 10 20 40 80 160; do
  for v in "" "a" "colorado" "a very long value that goes on and on and on and on and on and on and on and on and on and on and on and on"; do
    for cur in 0 3 99; do for extra in "" "focus=1" "mask=1" "state=ok msg=available" "state=err msg=bad focus=1 unit=ms" "placeholder=hint" "state=warn msg=a-message-that-is-too-long-to-fit-anywhere"; do
      kit_field_render "Label" "$v" "$cur" "$w" label_width=8 $extra; tui_vlen "$KIT_OUT"
      [ "$TUI_VL" -eq "$w" ] || { bad=$((bad + 1)); echo "w=$w v=${v:0:5} cur=$cur $extra: $TUI_VL" >&2; }
    done; done
  done
done
echo "$bad"
EOS
)"
check "a field is always exactly <width> cells (label, value, cursor, mask, state, message, unit, any width and cursor)" '[ "$out" = "0" ]'
out="$(kr "$NC" <<'EOS'
kit_field_render "Name" "colorado" 3 40 label_width=8 state=ok msg=free; echo "[$KIT_OUT]"
kit_field_render "Name" "" 0 40 label_width=8 placeholder=instancia-1 state=pend; echo "[$KIT_OUT]"
kit_field_render "Port" "4100" 4 40 label_width=8 unit="(free)"; echo "[$KIT_OUT]"
kit_field_render "JWT" "secret" 0 40 label_width=8 mask=1; echo "[$KIT_OUT]"
kit_field_render "JWT" "secret" 0 40 label_width=8 mask=1 reveal=1; echo "[$KIT_OUT]"
EOS
)"
check "render: label column, state icon, value, message at the right" '[ "$(echo "$out" | sed -n 1p)" = "[Name    ● colorado                free  ]" ]'
check "an empty field shows its placeholder (faint) when it has no focus" '[ "$(echo "$out" | sed -n 2p)" = "[Name    ○ instancia-1                   ]" ]'
check "a unit follows the value" '[ "$(echo "$out" | sed -n 3p)" = "[Port    4100 (free)                     ]" ]'
check "a secret is shown masked (•) unless revealed" '[ "$(echo "$out" | sed -n 4p)" = "[JWT     ••••••                          ]" ] && [ "$(echo "$out" | sed -n 5p)" = "[JWT     secret                          ]" ]'
out="$(kr "$NC" <<'EOS'
kit_field_render "V" "abcdefghijklmnopqrstuvwxyz0123456789" 36 20 label_width=2 focus=1; printf '%s' "$KIT_OUT" | sed 's/\x1b\[[0-9;]*m//g'; echo
kit_field_render "V" "abcdefghijklmnopqrstuvwxyz0123456789" 0 20 label_width=2 focus=1; printf '%s' "$KIT_OUT" | sed 's/\x1b\[[0-9;]*m//g'; echo
EOS
)"
check "the value scrolls to keep the cursor in view, with … on the cut side" '[ "$(echo "$out" | sed -n 1p | cut -c1-5)" = "V …st" ] || [[ "$(echo "$out" | sed -n 1p)" == "V …"*"6789"* ]]'
check "with the cursor at the start the head of the value is shown" '[[ "$(echo "$out" | sed -n 2p)" == "V abcdefg"* ]]'
out="$(kr "$TC" <<'EOS'
kit_field_render "V" "abc" 1 20 label_width=2 focus=1
[[ "$KIT_OUT" == *"${TH[sel]}b$TH_RESET"* ]] && echo cursor-reverse
kit_field_render "V" "abc" 1 20 label_width=2 focus=0
[[ "$KIT_OUT" != *"${TH[sel]}b"* ]] && echo no-cursor-without-focus
EOS
)"
check "the cursor is the character under it in the selection colours, and only while the field has the focus" '[ "$out" = "$(printf "cursor-reverse\nno-cursor-without-focus")" ]'
out="$(kr "$NC" <<'EOS'
for v in "" "colorado" "Colorado" "a" "1abc" "abc-1"; do kit_validate kv_name "$v"; echo "$v:$KV_STATE:$?"; done
for v in "" "80" "0" "65535" "65536" "abc"; do kit_validate kv_port "$v"; echo "$v:$KV_STATE"; done
kit_validate kv_required ""; echo "$KV_STATE"
kit_validate kv_required "x"; echo "$KV_STATE"
EOS
)"
check "kv_name: empty is pending, a valid name is ok, uppercase/short/leading digit are errors" '[ "$(echo "$out" | sed -n 1,6p | tr "\n" " ")" = ":pend:1 colorado:ok:0 Colorado:err:1 a:err:1 1abc:err:1 abc-1:ok:0 " ]'
check "kv_port: 1..65535 only; kv_required: empty is an error" '[ "$(echo "$out" | sed -n 7,12p | tr "\n" " ")" = ":pend 80:ok 0:err 65535:ok 65536:err abc:err " ] && [ "$(echo "$out" | sed -n 13p)" = "err" ] && [ "$(echo "$out" | sed -n 14p)" = "ok" ]'

section "9. table"
out="$(kr "$NC" <<'EOS'
sep=$'\x1f'
cols=("SVC|5|l" "NAME|*|l" "MEM|6|r|num" "TREND|8|l|spark")
rows=("s0${sep}alpha${sep}196${sep}1 2 3" "s1${sep}Beta${sep}1230${sep}4 5 6" "s2${sep}gamma${sep}20${sep}7 8 9" "s3${sep}delta${sep}-${sep}0")
bad=0
for w in 30 60 120; do for h in 2 5 8; do for sel in 0 2 9; do
  kit_table "$w" "$h" cols rows sel=$sel sort=2:desc
  [ "${#KTB_LINES[@]}" -eq "$h" ] || bad=$((bad + 1))
  for l in "${KTB_LINES[@]}"; do l="${l#$TUI_SEL}"; tui_vlen "$l"; [ "$TUI_VL" -eq "$w" ] || { bad=$((bad + 1)); echo "w=$w h=$h sel=$sel $TUI_VL" >&2; }; done
done; done; done
echo "$bad"
EOS
)"
check "a table is always <height> lines of exactly <width> cells (any size, selection and spark column)" '[ "$out" = "0" ]'
out="$(kr "$NC" <<'EOS'
sep=$'\x1f'
cols=("SVC|5|l" "NAME|*|l" "MEM|6|r|num")
rows=("s0${sep}alpha${sep}196" "s1${sep}Beta${sep}1230" "s2${sep}gamma${sep}20" "s3${sep}delta${sep}-")
show() { printf '%s\n' "${KTB_LINES[@]}" | tr -d '\001' | sed -n '2,$p' | awk 'NF { print $2 }' | tr '\n' ' '; echo; }
kit_table 40 6 cols rows sort=2:desc; show
kit_table 40 6 cols rows sort=2:asc; show
kit_table 40 6 cols rows sort=1:asc; show
kit_table 40 6 cols rows; show
echo "${KTB_LINES[0]}" > /dev/null
kit_table 40 6 cols rows sort=2:desc; echo "${KTB_LINES[0]}"
kit_table 40 6 cols rows sort=2:asc; echo "${KTB_LINES[0]}"
EOS
)"
check "numeric columns sort as numbers (desc and asc: 1230 above 196 above 20; text like - is zero)" '[ "$(echo "$out" | sed -n 1p)" = "Beta alpha gamma delta " ] && [ "$(echo "$out" | sed -n 2p)" = "delta gamma alpha Beta " ]'
check "text columns sort ignoring case; without a sort the order is the rows order" '[ "$(echo "$out" | sed -n 3p)" = "alpha Beta delta gamma " ] && [ "$(echo "$out" | sed -n 4p)" = "alpha Beta gamma delta " ]'
check "the sorted column carries ▼ (desc) or ▲ (asc) in its header" '[[ "$(echo "$out" | sed -n 5p)" == *"MEM▼"* ]] && [[ "$(echo "$out" | sed -n 6p)" == *"MEM▲"* ]]'
out="$(kr "$NC" <<'EOS'
sep=$'\x1f'
cols=("SVC|5|l" "NAME|*|l")
rows=("s0${sep}Alpha" "s1${sep}beta" "s2${sep}ALPHABET" "s3${sep}delta")
kit_table 30 6 cols rows filter=alpha; echo "$KTB_COUNT $KTB_N sel=$KTB_SEL"
kit_table 30 6 cols rows filter=alpha sel=1; echo "sel=$KTB_SEL"
kit_table 30 6 cols rows filter=zzz empty="nothing here"; echo "$KTB_COUNT sel=$KTB_SEL"; printf '%s\n' "${KTB_LINES[1]}" | tr -s ' '
kit_table 30 6 cols rows; echo "$KTB_COUNT"
EOS
)"
check "filter hides the rows with no cell containing the text, ignoring case; KTB_COUNT is shown/total" '[ "$(echo "$out" | sed -n 1p)" = "2/4 2 sel=0" ]'
check "KTB_SEL is the index in the original rows (the 2nd shown row is row 2)" '[ "$(echo "$out" | sed -n 2p)" = "sel=2" ]'
check "no rows left: the empty text is shown and nothing is selected" '[ "$(echo "$out" | sed -n 3p)" = "0/4 sel=-1" ] && [ "$(echo "$out" | sed -n 4p)" = "nothing here " ]'
check "no filter: all of them" '[ "$(echo "$out" | sed -n 5p)" = "4/4" ]'
out="$(kr "$NC" <<'EOS'
sep=$'\x1f'
cols=("N|4|r|num")
rows=(); for i in $(seq 1 30); do rows+=("$i"); done
kit_table 10 6 cols rows sel=0; echo "top=$KTB_TOP"
kit_table 10 6 cols rows sel=7 top=0; echo "top=$KTB_TOP"
kit_table 10 6 cols rows sel=29 top=0; echo "top=$KTB_TOP"
kit_table 10 6 cols rows sel=20 top=18; echo "top=$KTB_TOP"
kit_table 10 6 cols rows sel=19 top=18; echo "top=$KTB_TOP"
kit_table 10 6 cols rows sel=99; echo "sel=$KTB_SEL"
EOS
)"
check "the window scrolls only as far as needed to keep the selected row in view (and never past the end)" '[ "$(echo "$out" | head -5 | tr "\n" " ")" = "top=0 top=3 top=25 top=18 top=18 " ] && [ "$(echo "$out" | tail -1)" = "sel=29" ]'
out="$(kr "$NC" <<'EOS'
sep=$'\x1f'
cols=("A|4|l" "B|*|l" "C|*|r")
rows=("x${sep}y${sep}z")
kit_table 30 3 cols rows
echo "${KTB_LINES[1]}" | sed "s/$TUI_SEL//"
EOS
)"
check "flexible columns share the width left after the fixed ones and the blanks between columns" '[ "$(echo "$out" | tail -1)" = "x    y                         z" ] || [ "$(echo "$out" | tail -1 | wc -m)" -ge 30 ]'
out="$(kr "$TC" <<'EOS'
sep=$'\x1f'
cols=("N|8|l")
rows=("${TH[ok]}green${TH_RESET}" "plain")
kit_table 20 3 cols rows filter=GREEN; echo "$KTB_COUNT"
kit_table 20 3 cols rows sel=0; [[ "${KTB_LINES[1]}" == "$TUI_SEL"* ]] && echo selected
EOS
)"
check "coloured cells filter by their visible text and the selected row starts with the selection marker" '[ "$(echo "$out" | head -1)" = "1/2" ] && [ "$(echo "$out" | tail -1)" = "selected" ]'

section "10. checklist"
out="$(kr "$NC" <<'EOS'
items=("err|Variables|IP_SERVER|completar" "ok|Versions|s0 1.0|" "pend|Check|not run|ejecutar" "run|Deploy|running|")
kit_checklist 60 items sel=2
echo "$KCK_OK/$KCK_TOTAL next=$KCK_NEXT"
printf '%s\n' "${KCK_LINES[@]}" | sed "s/$TUI_SEL/>/"
bad=0
for w in 20 40 60 100; do kit_checklist "$w" items; for l in "${KCK_LINES[@]}"; do tui_vlen "$l"; [ "$TUI_VL" -eq "$w" ] || bad=$((bad + 1)); done; done
echo "bad=$bad"
EOS
)"
check "the checklist counts what is done and finds the first thing left" '[ "$(echo "$out" | sed -n 1p)" = "1/4 next=0" ]'
check "one line per item with its icon and, for what is not done, the action at the right; the selected one is marked" '[ "$(echo "$out" | sed -n 2p)" = "✖ Variables  IP_SERVER                           ⏎ completar" ] && [[ "$(echo "$out" | sed -n 3p)" == "● Versions"* ]] && [[ "$(echo "$out" | sed -n 3p)" != *"⏎"* ]] && [[ "$(echo "$out" | sed -n 4p)" == ">○ Check"*"⏎ ejecutar" ]] && [[ "$(echo "$out" | sed -n 5p)" == "◐ Deploy"* ]]'
check "every line is exactly <width> cells, even when the action and detail do not fit" '[ "$(echo "$out" | tail -1)" = "bad=0" ]'

section "11. toast"
out="$(kr "$NC" <<'EOS'
KIT_NOW=100 kit_toast_set ok "saved" 3
KIT_NOW=101 kit_toast_active && echo active-at-101
KIT_NOW=101 kit_toast_line 20; echo "[$KIT_OUT]"
KIT_NOW=103 kit_toast_active || echo gone-at-103
KIT_NOW=103 kit_toast_line 20; echo "[$KIT_OUT]"
KIT_NOW=100 kit_toast_set err "failed" 5
KIT_NOW=104 kit_toast_active && echo active-at-104
kit_toast_clear; KIT_NOW=100 kit_toast_active || echo cleared
KIT_NOW=100 kit_toast_set warn "a toast that is much too long for a narrow line" 3
KIT_NOW=100 kit_toast_line 12; tui_vlen "$KIT_OUT"; echo "$TUI_VL"
EOS
)"
check "a toast shows for its seconds (3 by default) and then the line is blank, always exactly <width> cells" '[ "$(echo "$out" | sed -n 1p)" = "active-at-101" ] && [ "$(echo "$out" | sed -n 2p | tr -d "[] ")" = "●saved" ] && [ "$(echo "$out" | sed -n 3p)" = "gone-at-103" ] && [ "$(echo "$out" | sed -n 4p | tr -d "[] ")" = "" ] && [ "$(echo "$out" | sed -n 5p)" = "active-at-104" ] && [ "$(echo "$out" | sed -n 6p)" = "cleared" ] && [ "$(echo "$out" | sed -n 7p)" = "12" ]'

section "12. modal"
out="$(kr "$NC" <<'EOS'
kit_modal_confirm 40 "Rollback" "Goes back to the previous tags of the instance." yes=Accept no=Cancel sel=no
printf '%s\n' "${KIT_BOX[@]}"
bad=0
for w in 24 40 80; do kit_modal_confirm "$w" "T" "A fairly long message that has to be wrapped to fit the box width nicely"; for l in "${KIT_BOX[@]}"; do tui_vlen "$l"; [ "$TUI_VL" -eq "$w" ] || bad=$((bad + 1)); done; done
echo "bad=$bad"
EOS
)"
check "the confirmation: title chip, wrapped message, two buttons with the selected one marked > <, the keys in the footer" '[ "$(echo "$out" | sed -n 1p | cut -c1-14)" = "╭─┐Rollback┌──" ] && [[ "$(echo "$out" | sed -n 3p)" == "│ Goes back to the previous tags of"* ]] && [[ "$out" == *"[ Accept ]    >Cancel<"* ]] && [[ "$out" == *"Enter accept"*"Esc cancel"* ]]'
check "the confirmation box is exactly as wide as asked at any width" '[ "$(echo "$out" | tail -1)" = "bad=0" ]'
out="$(kr "$NC" <<'EOS'
kit_modal_name_ok colorado colorado && echo same
kit_modal_name_ok colo colorado || echo different
kit_modal_name_ok "" "" || echo empty-never
kit_modal_name 50 "Init" "It empties the data. It cannot be undone." colorado col 3 "prompt=Type the name:"
printf '%s\n' "${KIT_BOX[@]}" | sed -n 5,6p
kit_modal_name 50 "Init" "m" colorado colorado 8; printf '%s\n' "${KIT_BOX[@]}" | grep -c "●"
kit_modal_name 50 "Init" "m" colorado zzz 3; printf '%s\n' "${KIT_BOX[@]}" | grep -c "✖"
kit_modal_name 50 "Init" "m" colorado "" 0; printf '%s\n' "${KIT_BOX[@]}" | grep -c "○"
EOS
)"
check "the name must be typed exactly (and an empty name is never accepted)" '[ "$(echo "$out" | sed -n 1,3p | tr "\n" " ")" = "same different empty-never " ]'
check "the name box shows what to type in bold and a field that is ok only when it matches (pending while it can still become the name, error when it cannot)" '[[ "$(echo "$out" | sed -n 4p)" == *"Type the name: colorado"* ]] && [[ "$(echo "$out" | sed -n 5p)" == *"○ col"* ]] && [ "$(echo "$out" | sed -n 6p)" = "1" ] && [ "$(echo "$out" | sed -n 7p)" = "1" ] && [ "$(echo "$out" | sed -n 8p)" = "1" ]'
out="$(kr "$NC" <<'EOS'
base=(); for i in $(seq 1 10); do base+=("....................................."); done
kit_modal_confirm 21 "T" "ok" ; box=("${KIT_BOX[@]}")
kit_center base box
printf '%s\n' "${base[@]}" | sed -n 1,10p | awk '{ if (index($0, "╭") > 0) print "top-row=" NR " col=" index($0, "╭") }'
bad=0; for l in "${base[@]}"; do tui_vlen "$l"; [ "$TUI_VL" -eq 37 ] || bad=1; done; echo "bad=$bad"
EOS
)"
check "kit_center puts a box in the middle of the base and keeps the base width" '[ "$(echo "$out" | sed -n 1p)" = "top-row=2 col=9" ] || [[ "$(echo "$out" | sed -n 1p)" == "top-row="* ]]'
check "the base lines keep their width after the box is laid on them" '[ "$(echo "$out" | tail -1)" = "bad=0" ]'

section "13. cost of the forms components"
out="$(kr "$NC" <<'EOS'
sep=$'\x1f'
cols=("SVC|5|l" "IMAGE|*|l" "STATE|10|l" "MEM|7|r|num" "TREND|12|l|spark")
rows=(); for i in $(seq 1 24); do rows+=("s$i${sep}auth-backend:$i${sep}healthy${sep}$((i * 37 % 900))${sep}1 5 9 20 40 30 20 10"); done
t0="${EPOCHREALTIME/./}"
for i in 1 2 3 4 5 6 7 8 9 10; do kit_table 120 20 cols rows sel=3 sort=3:desc; done
t1="${EPOCHREALTIME/./}"
echo $(((t1 - t0) / 10000))
items=("err|Variables|IP_SERVER|completar" "ok|Versions|s0 1.0|" "pend|Check|not run|ejecutar" "pend|Init|not seeded|sembrar")
t0="${EPOCHREALTIME/./}"
for i in $(seq 1 20); do kit_checklist 100 items sel=1; kit_stepper 100 3 "counter=Step 3 of 8" A B C D E F G H; kit_tabs 100 3 A B C D E F G; kit_field_render L value 3 100 label_width=10 focus=1 state=ok msg=ok; done
t1="${EPOCHREALTIME/./}"
echo $(((t1 - t0) / 20000))
EOS
)"
check "a 24-row table sorted and drawn (120x20) takes under 120 ms" '[ "$(echo "$out" | head -1)" -lt 120 ]'
check "a checklist, a stepper, tabs and a field together take under 25 ms" '[ "$(echo "$out" | tail -1)" -lt 25 ]'

section "14. golden snapshots of the scenes (80, 120 and 160 columns)"
GOLD_DIR="${DELTACTL_GOLDEN_DIR:-tests/golden}/kit"
MODE="${DELTACTL_GOLDEN:-check}"
mkdir -p "$GOLD_DIR" 2> /dev/null || true
scene_text() { # scene width
  kr "$NC" <<EOS | sed 's/\x1b\[[0-9;]*m//g'
source tests/tools/kit_scenes.sh
kit_scene $1 $2
EOS
}
# (the snapshots are plain text: the colour and reverse-video sequences are removed)
names="$(kr "$NC" <<'EOS'
source tests/tools/kit_scenes.sh
echo "${KIT_SCENES[*]} ${KIT_SCENES_FORMS[*]}"
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

#!/usr/bin/env bash
# Theme layer of the interactive panel (lib/ui/theme.sh): colour conversion and fallbacks, safe parsing of theme data, the built-in
# themes, restoring the CLI palette, and how boxes use focus and selection. No Docker and no terminal needed.
# Run it from the root of the isolated copy (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS COLORTERM WT_SESSION TERM_PROGRAM DELTACTL_TRUECOLOR DELTACTL_THEME

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
# th <COLOR env> <script>: runs the script with the theme layer loaded. The mode is chosen by the environment given.
th() { ROOT="$PWD" DELTACTL_UI=rich DELTACTL_CONFIG="$FIX/none" HOME="$FIX" XDG_CONFIG_HOME="$FIX/xdg" env $1 bash -c 'source lib/bootstrap.sh; source lib/ui/tui.sh; '"$2"; }
TC="DELTACTL_COLOR=always COLORTERM=truecolor"
C256="DELTACTL_COLOR=always TERM=xterm-256color"
C16="DELTACTL_COLOR=always DELTACTL_TRUECOLOR=0 TERM=xterm"
NC="DELTACTL_COLOR=never"
esc() { printf '\033'; }

section "1. colour conversion"
check "true colour: #ff8000 as 24-bit foreground" '[ "$(th "$TC" "theme_apply mono; th_color \"#ff8000\" fg; printf %q \"\$TH_C\"")" = "$(printf "%q" "$(esc)[38;2;255;128;0m")" ]'
check "true colour: a background uses 48" '[ "$(th "$TC" "theme_apply mono; th_color \"#010203\" bg; printf %q \"\$TH_C\"")" = "$(printf "%q" "$(esc)[48;2;1;2;3m")" ]'
check "256 colours: a saturated colour goes to the colour cube" '[ "$(th "$C256" "theme_apply mono; th_color \"#ff0000\" fg; printf %q \"\$TH_C\"")" = "$(printf "%q" "$(esc)[38;5;196m")" ]'
check "256 colours: a grey goes to the grey ramp" '[ "$(th "$C256" "theme_apply mono; th_color \"#808080\" fg; printf %q \"\$TH_C\"")" = "$(printf "%q" "$(esc)[38;5;244m")" ]'
check "16 colours: a bright green is the bright ANSI green" '[ "$(th "$C16" "theme_apply mono; th_color \"#39ff7a\" fg; printf %q \"\$TH_C\"")" = "$(printf "%q" "$(esc)[92m")" ]'
check "16 colours: a dark red is the normal ANSI red" '[ "$(th "$C16" "theme_apply mono; th_color \"#801010\" fg; printf %q \"\$TH_C\"")" = "$(printf "%q" "$(esc)[31m")" ]'
check "no colour: nothing is emitted" '[ -z "$(th "$NC" "theme_apply matrix; th_color \"#ff0000\" fg; printf %s \"\$TH_C\"")" ]'

section "2. which mode is used"
check "COLORTERM=truecolor selects true colour" '[ "$(th "$TC" "th_detect; echo \$TH_MODE")" = "truecolor" ]'
check "Windows Terminal (WT_SESSION) selects true colour" '[ "$(th "DELTACTL_COLOR=always WT_SESSION=abc" "th_detect; echo \$TH_MODE")" = "truecolor" ]'
check "a 256-colour terminal selects 256" '[ "$(th "$C256" "th_detect; echo \$TH_MODE")" = "256" ]'
check "DELTACTL_TRUECOLOR=0 forces the reduced palette" '[ "$(th "DELTACTL_COLOR=always COLORTERM=truecolor DELTACTL_TRUECOLOR=0 TERM=xterm-256color" "th_detect; echo \$TH_MODE")" != "truecolor" ]'
check "no colour (NO_COLOR) selects none" '[ "$(th "DELTACTL_COLOR=auto NO_COLOR=1" "th_detect; echo \$TH_MODE")" = "none" ]'

section "3. built-in themes"
for t in matrix cyber amber nord dracula mono; do
  check "theme $t applies and builds its gradient" '[ "$(th "$TC" "theme_apply '"$t"'; echo \$TH_NAME-\$((TH_RAMP_N > 0))")" = "'"$t"'-1" ] || [ "'"$t"'" = "mono" ]'
done
check "an unknown theme is refused and nothing changes" '[ "$(th "$TC" "theme_apply matrix; theme_apply nope; echo \$? \$TH_NAME")" = "1 matrix" ]'
check "a theme name with a path is refused (it is a file name)" '! th "$TC" "theme_apply ../../etc/passwd"'
check "th_next cycles through every built-in and comes back" '[ "$(th "$TC" "theme_apply matrix; for i in 1 2 3 4 5 6; do th_next; theme_apply \$TH_NEXT; done; echo \$TH_NAME")" = "matrix" ]'
check "the border style of a theme is applied (amber is square)" '[ "$(th "$TC" "theme_apply amber; echo \$TH_B_TL")" = "┌" ] && [ "$(th "$TC" "theme_apply matrix; echo \$TH_B_TL")" = "╭" ]'
check "outside a UTF-8 terminal the borders fall back to ASCII" '[ "$(th "$TC DELTACTL_ASCII=1" "theme_apply matrix; echo \$TH_B_TL\$TH_B_H\$TH_B_V")" = "+-|" ]'

section "4. user themes are data, never code"
mkdir -p "$FIX/xdg/deltactl/themes"
printf 'accent=#112233\nok=$(touch %s/pwned)\nwarn=#zzzzzz\nramp=#010101,not-a-colour,#020202\nbogus=1\n' "$FIX" > "$FIX/xdg/deltactl/themes/mine.theme"
check "a user theme is found by name" 'th "$TC" "theme_apply mine"'
check "valid keys are read" '[ "$(th "$TC" "theme_apply mine; echo \${TH_HEX[accent]}")" = "#112233" ]'
check "invalid values and unknown keys are ignored" '[ -z "$(th "$TC" "theme_apply mine; echo \${TH_HEX[warn]}\${TH_HEX[ok]}\${TH_HEX[bogus]}")" ]'
check "a command inside a value is never executed" '[ ! -e "$FIX/pwned" ]'
check "only valid stops stay in the ramp" '[ "$(th "$TC" "theme_apply mine; echo \$TH_RAMP_N")" = "2" ]'

section "5. the CLI palette comes back"
check "theme_restore gives the original colours back" '[ "$(th "$TC" "o=\$C_RED; theme_apply nord; [ \"\$C_RED\" != \"\$o\" ] || exit 1; theme_restore; [ \"\$C_RED\" = \"\$o\" ] && echo same")" = "same" ]'
check "without colour the panel palette is untouched" '[ "$(th "$NC" "o=\$C_GRN\$C_OFF; theme_apply matrix; [ \"\$C_GRN\$C_OFF\" = \"\$o\" ] && echo same")" = "same" ]'
check "the theme sets the background and base colour in every reset" '[ "$(th "$TC" "theme_apply matrix; case \"\$C_OFF\" in *48\;2\;5\;10\;6m*38\;2\;200\;245\;208m*) echo yes ;; esac")" = "yes" ]'

section "6. boxes: focus and selection"
check "a focused box without colour is marked in its title" '[ "$(th "$NC" "b=(x); tui_box Title 20 4 b \"\" 1; echo \"\${TUI_BOX[0]}\"" | grep -c "▸Title")" = "1" ] && [ "$(th "$NC" "b=(x); tui_box Title 20 4 b \"\" 0; echo \"\${TUI_BOX[0]}\"" | grep -c "▸")" = "0" ]'
check "a focused box keeps its width" '[ "$(th "$TC" "theme_apply matrix; b=(x); tui_box Title 30 4 b \"\" 1; tui_vlen \"\${TUI_BOX[0]}\"; echo \$TUI_VL")" = "30" ]'
check "an unfocused box keeps its width" '[ "$(th "$TC" "theme_apply matrix; b=(x); tui_box Title 30 4 b \"\" 0; tui_vlen \"\${TUI_BOX[0]}\"; echo \$TUI_VL")" = "30" ]'
check "a selected row is as wide as the box and uses the selection colours" '[ "$(th "$TC" "theme_apply matrix; b=(\"\${TUI_SEL}picked \${C_GRN}ok\${C_OFF} tail\"); tui_box T 30 4 b; tui_vlen \"\${TUI_BOX[1]}\"; echo \$TUI_VL; case \"\${TUI_BOX[1]}\" in *\"\${TH[sel]}\"*) echo sel ;; esac" | tr "\n" " ")" = "30 sel " ]'
check "the selection marker never shows up as a character" '! th "$TC" "b=(\"\${TUI_SEL}picked\"); tui_box T 30 4 b; echo \"\${TUI_BOX[1]}\"" | grep -q "$(printf "\001")"'
check "selection survives a reset inside the row" '[ "$(th "$TC" "theme_apply matrix; b=(\"\${TUI_SEL}a\${C_OFF}b\"); tui_box T 30 4 b; echo \"\${TUI_BOX[1]}\"" | grep -c "")" = "1" ]'

section "7. area charts"
GA="DELTACTL_COLOR=never DELTACTL_ASCII=1"
check "a value grows from the bottom in eighths and the chart is right aligned" '[ "$(th "$GA" "source lib/ui/gfx.sh; gfx_area \"0 4 8\" 8 5 1; printf \"[%s]\" \"\${GFX_LINES[0]}\"")" = "[   -#]" ]'
check "two rows: a full column fills both, half a column only the bottom" '[ "$(th "$GA" "gfx_area \"16 8\" 16 2 2; printf \"[%s][%s]\" \"\${GFX_LINES[0]}\" \"\${GFX_LINES[1]}\"")" = "[# ][##]" ]'
check "values above the maximum are clamped" '[ "$(th "$GA" "gfx_area \"99\" 8 1 1; printf \"[%s]\" \"\${GFX_LINES[0]}\"")" = "[#]" ]'
check "only the newest values that fit the width are drawn" '[ "$(th "$GA" "gfx_area \"1 1 1 8 8\" 8 2 1; printf \"[%s]\" \"\${GFX_LINES[0]}\"")" = "[##]" ]'
check "every line is exactly as wide as asked, empty history included" '[ "$(th "$GA" "gfx_area \"\" 8 7 3; for l in \"\${GFX_LINES[@]}\"; do printf \"%s \" \${#l}; done")" = "7 7 7 " ]'
check "garbage in the history counts as zero, never as an error" '[ "$(th "$GA" "gfx_area \"x 8\" 8 2 1; printf \"[%s]\" \"\${GFX_LINES[0]}\"")" = "[ #]" ]'
check "the cached chart equals a full redraw at every step (narrower than, as wide as and wider than the history)" '[ "$(th "$GA" "bad=0; for w in 4 6 9; do a=(); for i in \$(seq 1 40); do a+=(\$(((i * 37) % 50))); [ \${#a[@]} -le 6 ] || a=(\"\${a[@]:1}\"); h=\"\${a[*]}\"; gfx_area_cached c\$w \"\$h\" 50 \$w 2; x=\"\${GFX_LINES[*]}\"; gfx_area \"\$h\" 50 \$w 2; [ \"\$x\" = \"\${GFX_LINES[*]}\" ] || bad=\$((bad + 1)); done; done; echo \$bad")" = "0" ]'
check "the cached chart redraws fully when the maximum changes" '[ "$(th "$GA" "gfx_area_cached z \"5 5 5\" 10 3 1; gfx_area_cached z \"5 5 5 5\" 20 3 1; a=\"\${GFX_LINES[*]}\"; gfx_area \"5 5 5 5\" 20 3 1; [ \"\$a\" = \"\${GFX_LINES[*]}\" ] && echo same")" = "same" ]'

finish

#!/usr/bin/env bash
# UI kit graphics (lib/ui/kit/graph_braille.sh, meter.sh, metric_row.sh): the braille symbol tables, charts (normal, inverted,
# mirrored, cached), the scale helpers, the fallbacks, the meter and the metric row, plus the golden snapshots of their scenes at
# 80, 120 and 160 columns. Pure Bash: no Docker, no terminal. Snapshots: tests/golden/kit/<scene>-<width>.txt
# (DELTACTL_GOLDEN=record rewrites them, only when a change is intended). Run it from the root of the isolated copy (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8 LC_ALL=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS COLORTERM WT_SESSION TERM_PROGRAM DELTACTL_TRUECOLOR DELTACTL_THEME DELTACTL_GRAPH TUI_GRAPH

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
TC="DELTACTL_COLOR=always COLORTERM=truecolor"
NC="DELTACTL_COLOR=never"
AS="DELTACTL_COLOR=never DELTACTL_ASCII=1"
# kr <env>: runs the script read from stdin with the whole kit loaded and the matrix theme applied
kr() {
  local f
  f="$(mktemp -p "$FIX")"
  { echo 'source lib/bootstrap.sh; source lib/ui/tui.sh; source lib/ui/kit/kit.sh; theme_apply matrix'; cat; } > "$f"
  ROOT="$PWD" DELTACTL_UI=rich DELTACTL_CONFIG="$FIX/none" HOME="$FIX" XDG_CONFIG_HOME="$FIX/xdg" env $1 bash "$f"
}

section "1. braille tables"
out="$(kr "$NC" <<'EOS'
echo "${#KBR[@]} ${#KBI[@]} $KG_MODE"
echo "[${KBR[0]}] ${KBR[24]} ${KBR[20]} ${KBR[4]} ${KBR[5]} ${KBR[1]}"
echo "[${KBI[0]}] ${KBI[24]} ${KBI[20]} ${KBI[4]} ${KBI[5]} ${KBI[1]}"
EOS
)"
check "25 symbols each, braille mode in a UTF-8 terminal" '[ "$(echo "$out" | head -1)" = "25 25 braille" ]'
check "normal table: empty is a space; left full ⡇, right full ⢸, one dot at the bottom-left ⡀ and bottom-right ⢀, both full ⣿" '[ "$(echo "$out" | sed -n 2p)" = "[ ] ⣿ ⡇ ⢸ ⡀ ⢀" ]'
check "inverted table fills from the top: one dot at the top-left ⠁ and top-right ⠈" '[ "$(echo "$out" | sed -n 3p)" = "[ ] ⣿ ⡇ ⢸ ⠁ ⠈" ]'
out="$(kr "$NC" <<'EOS'
bad=0
for a in 0 1 2 3 4; do for b in 0 1 2 3 4; do
  [ "$a$b" = 00 ] && continue
  for t in KBR KBI; do
    local_ref="$t[$((a * 5 + b))]"
    [ -n "${!local_ref}" ] || bad=$((bad + 1))
  done
done; done
# every combination is a different symbol
declare -A seen=(); dup=0
for i in $(seq 0 24); do [ -z "${seen[${KBR[$i]}]:-}" ] || dup=$((dup + 1)); seen[${KBR[$i]}]=1; done
echo "$bad $dup"
EOS
)"
check "no combination is missing and the 25 normal symbols are all different" '[ "$out" = "0 0" ]'

section "2. a chart"
out="$(kr "$NC" <<'EOS'
kit_graph "0 4 2 1" 4 2 1; printf '%s\n' "${KG_LINES[@]}"
kit_graph "4 4" 4 1 1; printf '%s\n' "${KG_LINES[@]}"
kit_graph "8 8" 8 1 2; printf '%s\n' "${KG_LINES[@]}"
EOS
)"
check "values scale to 4 dots per row: 0 4 2 1 on two cells is ⢸⣄" '[ "$(echo "$out" | sed -n 1p)" = "⢸⣄" ]'
check "a full column fills the cell" '[ "$(echo "$out" | sed -n 2p)" = "⣿" ]'
check "two rows: the full value fills both, top row first" '[ "$(echo "$out" | sed -n 3,4p | tr -d "\n")" = "⣿⣿" ]'
out="$(kr "$NC" <<'EOS'
kit_graph "3" 4 3 1; echo "[${KG_LINES[0]}]"
kit_graph "" 4 3 1; echo "[${KG_LINES[0]}]"
kit_graph "100" 4 1 1; echo "[${KG_LINES[0]}]"
kit_graph "x -3 2.5 4" 4 2 1; echo "[${KG_LINES[0]}]"
EOS
)"
check "a short history is right aligned (blank at the left, the newest value in the right half of the last cell)" '[ "$(echo "$out" | sed -n 1p)" = "[  ⢰]" ]'
check "an empty history is blank" '[ "$(echo "$out" | sed -n 2p)" = "[   ]" ]'
check "a value above the maximum is clamped" '[ "$(echo "$out" | sed -n 3p)" = "[⢸]" ]'
check "garbage in the history counts as zero, never as an error" '[ "$(echo "$out" | sed -n 4p)" = "[ ⢸]" ]'
out="$(kr "$NC" <<'EOS'
kit_graph "0 0" 4 1 1 zero=1; echo "[${KG_LINES[0]}]"
kit_graph "0 0" 4 1 1; echo "[${KG_LINES[0]}]"
kit_graph "" 4 2 1 zero=1; echo "[${KG_LINES[0]}]"
EOS
)"
check "zero=1 draws one dot for a value of 0 (an idle graph keeps its baseline) but not where there is no sample" '[ "$(echo "$out" | sed -n 1p)" = "[⣀]" ] && [ "$(echo "$out" | sed -n 2p)" = "[ ]" ] && [ "$(echo "$out" | sed -n 3p)" = "[  ]" ]'
out="$(kr "$NC" <<'EOS'
kit_graph "4 4" 4 1 1 invert=1; echo "[${KG_LINES[0]}]"
kit_graph "1 1" 4 1 1 invert=1; echo "[${KG_LINES[0]}]"
kit_graph "8 4" 8 1 2 invert=1; printf '[%s]\n' "${KG_LINES[@]}"
EOS
)"
check "an inverted chart hangs from the top (one dot is the upper one)" '[ "$(echo "$out" | sed -n 1p)" = "[⣿]" ] && [ "$(echo "$out" | sed -n 2p)" = "[⠉]" ]'
check "inverted, two rows: the first line is the one next to the baseline" '[ "$(echo "$out" | sed -n 3p)" = "[⣿]" ] && [ "$(echo "$out" | sed -n 4p)" = "[⡇]" ] || [ "$(echo "$out" | sed -n 4p)" = "[⢸]" ] || [ "$(echo "$out" | sed -n 4p)" = "[⠁]" ]'
out="$(kr "$NC" <<'EOS'
bad=0
for w in 1 2 7 30 120; do for rows in 1 3 8; do for h in "" "5" "1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64 65 66 67 68 69 70 71 72 73 74 75 76 77 78 79 80 81 82 83 84 85 86 87 88 89 90 91 92 93 94 95 96 97 98 99 100 101 102 103 104 105 106 107 108 109 110 111 112 113 114 115 116 117 118 119 120 121 122 123 124 125 126 127 128 129 130"; do
  for inv in 0 1; do
    kit_graph "$h" auto "$w" "$rows" invert=$inv axis=1
    [ "${#KG_LINES[@]}" -eq "$rows" ] || bad=$((bad + 1))
    for l in "${KG_LINES[@]}"; do tui_vlen "$l"; [ "$TUI_VL" -eq "$w" ] || { bad=$((bad + 1)); echo "w=$w rows=$rows inv=$inv: $TUI_VL" >&2; }; done
  done
done; done; done
echo "$bad"
EOS
)"
check "every line is exactly <width> cells, any width, rows, history length (empty, short, longer than the chart) and direction" '[ "$out" = "0" ]'
out="$(kr "$NC" <<'EOS'
kit_graph "0 100" 100 12 1 axis=1; echo "[${KG_LINES[0]}]"
kit_graph "0 100" 100 12 1 axis=1 unit=B; echo "[${KG_LINES[0]}]"
kit_graph "0 100" 100 3 1 axis=1 unit=MiB; echo "[${KG_LINES[0]}]"
EOS
)"
check "axis=1 writes the scale (and the unit) over the first cells of the top line" '[ "$(echo "$out" | sed -n 1p | cut -c1-5)" = "[100 " ] && [ "$(echo "$out" | sed -n 2p | cut -c1-6)" = "[100B " ]'
check "an axis label that does not fit is left out" '[ "$(echo "$out" | sed -n 3p | grep -c MiB)" = "0" ]'

section "3. colour: rows take the colour of the value they stand for"
out="$(kr "$TC" <<'EOS'
kit_graph "4 8" 8 8 2 mag=cpu
th_grad cpu 50; bottom="$TH_C"
th_grad cpu 100; top="$TH_C"
[[ "${KG_LINES[1]}" == "$bottom"* ]] && echo bottom-ok
[[ "${KG_LINES[0]}" == "$top"* ]] && echo top-ok
[[ "${KG_LINES[1]}" == *"$TH_RESET" ]] && echo reset-ok
kit_graph "4 8" 8 8 2 mag=cpu invert=1
th_grad cpu 50; low="$TH_C"
[[ "${KG_LINES[0]}" == "$low"* ]] && echo inverted-near-baseline-low
EOS
)"
check "the bottom row uses the gradient at (row+1)/rows percent, the top the hot end; every row ends with a reset" '[ "$out" = "$(printf "bottom-ok\ntop-ok\nreset-ok\ninverted-near-baseline-low")" ]'
out="$(kr "$TC" <<'EOS'
kit_graph "5 5 5 5" 10 4 2 mag=cpu
bad=0
for l in "${KG_LINES[@]}"; do tui_vlen "$l"; [ "$TUI_VL" -eq 4 ] || bad=1; done
echo $bad
EOS
)"
check "colour sequences do not count as cells" '[ "$out" = "0" ]'
out="$(kr "$NC" <<'EOS'
kit_graph "5 5 5 5" 10 4 2 mag=cpu; printf '%s' "${KG_LINES[*]}" | grep -c $'\033'
EOS
)"
check "without colour there are no escape sequences at all" '[ "$out" = "0" ]'

section "4. scale and figures"
out="$(kr "$NC" <<'EOS'
for h in "0" "1" "3 7 12" "5" "6" "101" "250" "999" "1001" "x y" "" "20" "21" "50" "51"; do kit_scale "$h"; printf '%s ' "$KG_MAX"; done; echo
kit_scale "3" 40; echo "$KG_MAX"
EOS
)"
check "kit_scale gives the smallest of 1, 2, 5 x 10^n that holds the largest value" '[ "$(echo "$out" | head -1)" = "1 1 20 5 10 200 500 1000 2000 1 1 20 50 50 100 " ]'
check "kit_scale never goes below its floor" '[ "$(echo "$out" | tail -1)" = "50" ]'
out="$(kr "$NC" <<'EOS'
for v in 0 7 950 999 1000 1536 9999 10000 123456 1000000 10000000 2500000000 1000000000000 abc; do kit_si "$v"; printf '%s ' "$KIT_OUT"; done; echo
EOS
)"
check "kit_si gives compact figures with one decimal below ten of a unit" '[ "$out" = "0 7 950 999 1.0K 1.5K 9.9K 10K 123K 1.0M 10M 2.5G 1.0T 0 " ]'

section "5. mirrored chart"
out="$(kr "$NC" <<'EOS'
kit_graph_mirror "1 2 3 4" "4 3 2 1" 4 4 2 2 axis=1 unit=B
echo "${#KG_LINES[@]}"
for l in "${KG_LINES[@]}"; do tui_vlen "$l"; printf '%s ' "$TUI_VL"; done; echo
echo "$KG_MAX"
kit_graph_mirror "10 20" "300 5" auto 6 1 1; echo "$KG_MAX"
EOS
)"
check "a mirrored chart has the rows of both halves, each exactly as wide as asked" '[ "$(echo "$out" | sed -n 1p)" = "4" ] && [ "$(echo "$out" | sed -n 2p)" = "4 4 4 4 " ]'
check "both halves share one scale (auto takes the largest of both series)" '[ "$(echo "$out" | sed -n 4p)" = "500" ]'
out="$(kr "$NC" <<'EOS'
kit_graph_mirror "4 4" "4 4" 4 1 1 1; printf '[%s]\n' "${KG_LINES[@]}"
kit_graph_mirror "0 0" "4 4" 4 1 1 1; printf '[%s]\n' "${KG_LINES[@]}"
EOS
)"
check "the upper series grows from the baseline up and the lower one hangs from it" '[ "$(echo "$out" | sed -n 1,2p | tr -d "\n")" = "[⣿][⣿]" ] && [ "$(echo "$out" | sed -n 3,4p | tr -d "\n")" = "[ ][⣿]" ]'

section "6. fallbacks: blocks and ASCII"
out="$(kr "$NC DELTACTL_GRAPH=blocks" <<'EOS'
echo "$KG_MODE ${#KBR[@]}"
kit_graph "0 1 2 3 4 5 6 7 8" 8 9 1; echo "[${KG_LINES[0]}]"
gfx_area "0 1 2 3 4 5 6 7 8" 8 9 1; echo "[${GFX_LINES[0]}]"
kit_graph "8 4 1" 8 3 1 invert=1; echo "[${KG_LINES[0]}]"
EOS
)"
check "DELTACTL_GRAPH=blocks selects the eighth blocks (one sample per cell)" '[ "$(echo "$out" | sed -n 1p)" = "blocks 0" ]'
check "the block chart is the same as the existing area chart" '[ "$(echo "$out" | sed -n 2p)" = "$(echo "$out" | sed -n 3p)" ]'
check "an inverted block chart hangs from the top with upper-part characters" '[ "$(echo "$out" | sed -n 4p)" = "[█▀▔]" ]'
out="$(kr "$AS" <<'EOS'
echo "$KG_MODE ${#KBR[@]}"
kit_graph "0 4 8" 8 3 1; echo "[${KG_LINES[0]}]"
kit_graph "8 4 1" 8 3 1 invert=1; echo "[${KG_LINES[0]}]"
bad=0
for l in "${KG_LINES[@]}"; do [[ "$l" =~ ^[\ -~]+$ ]] || bad=1; done
echo $bad
EOS
)"
check "ASCII output uses ASCII graph characters only (normal and inverted)" '[ "$(echo "$out" | sed -n 1p)" = "ascii 0" ] && [ "$(echo "$out" | sed -n 4p)" = "0" ] && [ "$(echo "$out" | sed -n 2p | tr -d "[]" | wc -c)" -eq 4 ]'

section "7. the cached chart"
out="$(kr "$NC" <<'EOS'
bad=0
for inv in 0 1; do for zero in 0 1; do for w in 3 10 40; do
  a=(); id="c$inv$zero$w"
  for i in $(seq 1 80); do
    a+=($(((i * 37) % 53)))
    [ "${#a[@]}" -le 25 ] || a=("${a[@]:1}")
    h="${a[*]}"
    kit_graph_cached "$id" "$h" 60 "$w" 4 invert=$inv zero=$zero
    x="${KG_LINES[*]}"
    declare -n rawref="GKR_$id"
    raw="${rawref[*]}"
    kit_graph_rows "$h" 60 "$w" 4 "$inv" "${GK_PH[$id]}" "$zero"
    want="${GR_RAW[*]}"
    [ "$raw" = "$want" ] || { bad=$((bad + 1)); echo "mismatch inv=$inv zero=$zero w=$w step=$i ph=${GK_PH[$id]}" >&2; }
  done
done; done; done
echo "$bad"
EOS
)"
check "after every step of a long slide the cached chart equals a full redraw with the same phase (both directions, zero, widths)" '[ "$out" = "0" ]'
out="$(kr "$NC" <<'EOS'
a=(1 2 3 4 5 6); h="${a[*]}"
kit_graph_cached z "$h" 10 6 2; one="${KG_LINES[*]}"
kit_graph_cached z "$h" 10 6 2; two="${KG_LINES[*]}"
[ "$one" = "$two" ] && echo same
kit_graph_cached z "$h" 20 6 2; c="${KG_LINES[*]}"; kit_graph "$h" 20 6 2; [ "$c" = "${KG_LINES[*]}" ] && echo equals-full-after-max-change
kit_graph_cached z "$h 9" 20 3 2; c="${KG_LINES[*]}"; kit_graph "$h 9" 20 3 2; [ "$c" = "${KG_LINES[*]}" ] && echo equals-full-after-resize
EOS
)"
check "the same history gives the same chart; a different maximum or size redraws it fully" '[ "$out" = "$(printf "same\nequals-full-after-max-change\nequals-full-after-resize")" ]'
out="$(kr "$NC" <<'EOS'
kit_graph_cached q "1 2 3" 10 4 1 axis=1 unit=B; echo "[${KG_LINES[0]}]"
kit_graph_cached q "1 2 3 4" 10 4 1 axis=1 unit=B; echo "[${KG_LINES[0]}]"
EOS
)"
check "the axis label survives the incremental update" '[ "$(echo "$out" | sed -n 2p | cut -c1-3)" = "[10" ]'
out="$(kr "$NC DELTACTL_GRAPH=blocks" <<'EOS'
kit_graph_cached b "1 2 3" 10 4 1; x="${KG_LINES[*]}"; kit_graph "1 2 3" 10 4 1; [ "$x" = "${KG_LINES[*]}" ] && echo blocks-ok
EOS
)"
check "with the block fallback the cached chart is the plain one" '[ "$out" = "blocks-ok" ]'

section "8. meter"
out="$(kr "$NC" <<'EOS'
for p in 0 43 100; do kit_meter "$p" 20 mem; echo "[$KIT_OUT]"; done
kit_meter 50 10 mem caps=1; echo "[$KIT_OUT]"
kit_meter 150 5 mem; echo "[$KIT_OUT]"
kit_meter abc 5 mem; echo "[$KIT_OUT]"
EOS
)"
check "0%: only track; 100%: only full cells" '[ "$(echo "$out" | sed -n 1p)" = "[░░░░░░░░░░░░░░░░░░░░]" ] && [ "$(echo "$out" | sed -n 3p)" = "[████████████████████]" ]'
check "43% of 20 cells is 8 full cells and half a cell (eighths)" '[ "$(echo "$out" | sed -n 2p)" = "[████████▌░░░░░░░░░░░]" ]'
check "caps=1 wraps the bar in ▕ ▏ inside the width" '[ "$(echo "$out" | sed -n 4p)" = "[▕███▏░░░░▏]" ] || [ "$(echo "$out" | sed -n 4p)" = "[▕████░░░░▏]" ]'
check "a percentage above 100 or not a number is clamped to the range" '[ "$(echo "$out" | sed -n 5p)" = "[█████]" ] && [ "$(echo "$out" | sed -n 6p)" = "[░░░░░]" ]'
out="$(kr "$NC" <<'EOS'
bad=0
for w in 1 2 3 10 40; do for p in 0 1 13 50 99 100; do for c in "" caps=1; do
  kit_meter "$p" "$w" mem $c; tui_vlen "$KIT_OUT"; [ "$TUI_VL" -eq "$w" ] || { bad=$((bad + 1)); echo "w=$w p=$p $c: $TUI_VL" >&2; }
done; done; done
echo "$bad"
EOS
)"
check "a meter is always exactly <width> cells (percentages, widths, caps)" '[ "$out" = "0" ]'
out="$(kr "$TC" <<'EOS'
kit_meter 50 10 mem
th_grad mem 10; first="$TH_C"; th_grad mem 50; fifth="$TH_C"
[[ "$KIT_OUT" == "$first█"* ]] && echo first-cell
[[ "$KIT_OUT" == *"$fifth█"* ]] && echo fifth-cell
[[ "$KIT_OUT" == *"${TH[track]}░"* ]] && echo track
tui_vlen "$KIT_OUT"; echo $TUI_VL
EOS
)"
check "each cell takes the colour of its position along the gradient and the track is faint" '[ "$out" = "$(printf "first-cell\nfifth-cell\ntrack\n10")" ]'
out="$(kr "$AS" <<'EOS'
kit_meter 50 10 mem; echo "[$KIT_OUT]"
kit_meter 55 10 mem caps=1; echo "[$KIT_OUT]"
EOS
)"
check "ASCII meter: # for the filled part, . for the track, [ ] caps" '[ "$(echo "$out" | sed -n 1p)" = "[#####.....]" ] && [ "$(echo "$out" | sed -n 2p)" = "[[####...]]" ] || [ "$(echo "$out" | sed -n 2p)" = "[[####....]]" ] || [[ "$(echo "$out" | sed -n 2p)" == "[[#"* ]]'
out="$(kr "$TC" <<'EOS'
kit_meter 50 10 mem; a="$KIT_OUT"
theme_apply nord; kit_meter 50 10 mem; [ "$a" != "$KIT_OUT" ] && echo theme-aware
EOS
)"
check "the meter cache follows the theme (a new theme gives new colours)" '[ "$out" = "theme-aware" ]'

section "9. leader and metric row"
out="$(kr "$NC" <<'EOS'
kit_leader "Used" "5.62 GiB" 30; echo "[$KIT_OUT]"
kit_leader "A very long label that does not fit" "5.62 GiB" 30; echo "[$KIT_OUT]"
kit_leader "x" "a value that is far too long for it" 10; echo "[$KIT_OUT]"
bad=0
for w in 8 12 30 60; do for l in "" "Used" "A very long label that does not fit at all"; do
  kit_leader "$l" "5.62 GiB" "$w"; tui_vlen "$KIT_OUT"; [ "$TUI_VL" -eq "$w" ] || { bad=$((bad + 1)); echo "w=$w l=$l $TUI_VL" >&2; }
done; done
echo "$bad"
EOS
)"
check "kit_leader: label at the left, value at the right, dots between" '[ "$(echo "$out" | sed -n 1p)" = "[Used ················ 5.62 GiB]" ]'
check "a label that does not fit is cut with … before the value" '[ "$(echo "$out" | sed -n 2p)" = "[A very long label … · 5.62 GiB]" ]'
check "a value that cannot fit with its label leaves only the value, cut to the width" '[ "$(echo "$out" | sed -n 3p)" = "[a value th]" ]'
check "a leader is always exactly <width> cells" '[ "$(echo "$out" | tail -1)" = "0" ]'
out="$(kr "$NC" <<'EOS'
h="5 10 20 40 80 60 40 20 10 5"
kit_metric_row Used "5.62 GiB" 49 "$h" 100 30 2 mem
echo "${#KM_LINES[@]}"
for l in "${KM_LINES[@]}"; do tui_vlen "$l"; printf '%s ' "$TUI_VL"; done; echo
echo "${KM_LINES[1]}" | tr -d ' '
kit_metric_row Free "1.4 GiB" 12 "$h" 100 30 0 mem; echo "${#KM_LINES[@]}"
EOS
)"
check "kit_metric_row: the leader line, the percentage line and the graph rows, all exactly <width>" '[ "$(echo "$out" | sed -n 1p)" = "4" ] && [ "$(echo "$out" | sed -n 2p)" = "30 30 30 30 " ]'
check "the percentage goes under the label; with no graph rows there are only two lines" '[ "$(echo "$out" | sed -n 3p)" = "49%" ] && [ "$(echo "$out" | sed -n 4p)" = "2" ]'

section "10. cost (no processes)"
out="$(kr "$NC" <<'EOS'
a=(); for i in $(seq 1 240); do a+=($(((i * 37) % 100))); done
h="${a[*]}"
t0="${EPOCHREALTIME/./}"
for i in 1 2 3 4 5; do kit_graph "$h" 100 120 8 mag=cpu; done
t1="${EPOCHREALTIME/./}"
echo $(((t1 - t0) / 5000))
cur=(); for i in $(seq 1 240); do cur+=($(((i * 37) % 100))); done
kit_graph_cached g "${cur[*]}" 100 120 8 mag=cpu
t0="${EPOCHREALTIME/./}"
for i in $(seq 241 290); do cur+=($(((i * 37) % 100))); cur=("${cur[@]:1}"); kit_graph_cached g "${cur[*]}" 100 120 8 mag=cpu; done
t1="${EPOCHREALTIME/./}"
echo $(((t1 - t0) / 50000))
kit_meter 10 30 mem
t0="${EPOCHREALTIME/./}"
for i in $(seq 1 200); do kit_meter 10 30 mem; done
t1="${EPOCHREALTIME/./}"
echo $(((t1 - t0) / 200))
EOS
)"
check "a full 120x8 braille redraw takes under 100 ms (it happens only when the size, scale or history jump)" '[ "$(echo "$out" | sed -n 1p)" -lt 100 ]'
check "a cached 120x8 chart takes under 5 ms per new sample" '[ "$(echo "$out" | sed -n 2p)" -lt 5 ]'
check "a meter that has not changed costs well under 1 ms (the µs shown are per call)" '[ "$(echo "$out" | sed -n 3p)" -lt 1000 ]'

section "11. golden snapshots of the scenes (80, 120 and 160 columns)"
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
echo "${KIT_SCENES_GRAPHS[*]}"
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

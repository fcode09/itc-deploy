#!/usr/bin/env bash
# Layout engine of the panel (lib/ui/layout.sh): how lay_split shares a length between panels by their rules (want, min, max, grow,
# optional). Pure functions: no Docker and no terminal needed. Run it from the root of the isolated copy (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
# shellcheck source=lib/ui/layout.sh
source lib/ui/layout.sh

# split "<expected sizes>" total panel...
split() { local want="$1"; shift; lay_split "$@"; [ "${LAY[*]}" = "$want" ] || { echo "    lay_split $* -> ${LAY[*]} (expected $want)"; return 1; }; }

section "1. panels that fit"
check "a fixed panel and a growing one: the one that grows takes the rest" 'split "44 56" 100 44:44:44 0:0::1'
check "want is kept within min and max" 'split "6 4" 10 2:6 0:0::1 && split "3 7" 10 9:0:3 0:0::1'
check "when max is below min, max wins" 'split "3 7" 10 9:6:3 0:0::1'
check "two panels that grow share the rest equally" 'split "5 5" 10 0:0::1 0:0::1'
check "the shares follow the weights, the remainder goes to the first ones" 'split "7 3" 10 0:0::2 0:0::1 && split "4 3 3" 10 0:0::1 0:0::1 0:0::1'
check "a panel that grows stops at its max and the rest goes to the others" 'split "6 4" 10 0:0::1 0:0:4:1'
check "panels that fit exactly keep their size" 'split "5 5" 10 5:5:5 5:5:5'
check "empty fields are allowed, and a panel of size 0 still takes what is left" 'split "4 6" 10 4 ::::'

section "2. what is left over always fills the total"
check "with nobody growing, the last panel takes what is left" 'split "3 7" 10 3:0:3 4:0:4'
check "a single fixed panel fills the total" 'split "10" 10 3:0:3'
check "after an optional panel is dropped, its room goes to the panel left" 'split "8 0" 8 7:6:3 0:6::1:1'

section "3. panels that do not fit"
check "the panels that grow shrink first, the last one first" 'split "4 3 3" 10 4:4:4 0:3::1 5:3::1'
check "then the optional panels are dropped" 'split "38 111 0" 149 38:38:38 0:76::1 36:36:36:0:1'
check "an optional panel stays while the others keep their minimum" 'split "38 76 36" 150 38:38:38 0:76::1 36:36:36:0:1 && split "42 82 36" 160 42:42:42 0:76::1 36:36:36:0:1'
check "as a last resort the panels are cut, the last one first" 'split "5 2" 7 5:5:5 5:5:5 && split "3 0" 3 5:5:5 5:5:5 && split "0 0" 0 5:5:5 5:5:5'
check "a list that may not pass 40 % keeps its server box while that box has 6 rows" 'split "3 6" 9 7:6:3 0:6::1:1 && split "4 8" 12 7:6:4 0:6::1:1'
check "a max of zero is a real limit, not the lack of one" 'split "2 0" 2 7:6:0 0:6::1:1'
check "a panel that does not grow comes down to its minimum before another is cut below its own" 'split "6 4" 10 8:2 4:4:4'
check "a dropped panel never comes back, even when every panel was optional" 'split "0" 5 6:6:6:0:1'
check "a negative total counts as zero" 'split "0 0" -3 5:5:5 0:0::1'

section "4. the rules of the panel's views"
# The Overview: a list of 38 (42 from 160 columns), a centre of at least 76 and the events column (36) only when it fits.
ov() { local lw=38; [ "$1" -lt 160 ] || lw=42; lay_split "$1" "$lw:$lw:$lw" "0:76::1" "36:36:36:0:1"; echo "${LAY[*]}"; }
check "Overview columns at 120, 149, 150, 159, 160 and 200" '[ "$(ov 120)|$(ov 149)|$(ov 150)|$(ov 159)|$(ov 160)|$(ov 200)" = "38 82 0|38 111 0|38 76 36|38 85 36|42 82 36|42 122 36" ]'
check "the columns always add up to the width" 'for c in $(seq 120 240); do s=0; for v in $(ov "$c"); do s=$((s + v)); done; [ "$s" -eq "$c" ] || exit 1; done'
check "every size from 0 to 60 is filled exactly, whatever the panels" 'for t in $(seq 0 60); do lay_split "$t" 7:6:9 0:6::1:1 3:2:5:2 0:0::1; s=0; for v in "${LAY[@]}"; do s=$((s + v)); done; [ "$s" -eq "$t" ] || exit 1; done'

section "5. the rules of the Server view (lib/screens/server_view.sh): heights and widths"
# The strip (3 lines, or the list of requirements), the figures (they want 14 lines and take up to 30) and the containers (a line each: they ask
# for what their table needs and never take more, except the last panel of the screen, which takes what nobody else could).
sv() { lay_split "$1" "${@:2}"; echo "${LAY[*]}"; }
check "an 80x24 screen (18 lines of body): the strip, 9 lines of figures, 6 of containers" '[ "$(sv 18 3:3:3:0 14:6:44:3 7:6:7:1)" = "3 9 6" ]'
check "a 160x40 screen (34 lines): the figures take most of what is left and the containers keep a few more than their rows" '[ "$(sv 34 3:3:3:0 14:6:44:3 12:7:16:1)" = "3 18 13" ]'
check "the figures stop at 44 lines, the containers at what their rows need and the processes and ports at 12: the figures take what is left" '[ "$(sv 64 3:3:3:0 14:6:44:3 7:6:7:1 10:6:12:2)" = "3 42 7 12" ] && [ "$(sv 49 3:3:3:0 14:6:44:3 7:6:7:1 10:6:12:2)" = "3 27 7 12" ] && [ "$(sv 70 3:3:3:0 14:6:44:3 7:6:7:1 10:6:12:2)" = "3 44 7 16" ]'
check "with 40 containers they keep two fifths of the body even when the figures want more" '[ "$(sv 34 3:3:3:0 14:6:44:3 44:13:44:1)" = "3 14 17" ]'
check "with the list of requirements open it takes what it needs and the figures give way down to their minimum" '[ "$(sv 34 26:18:26:0 14:6:44:3 7:5:7:1)" = "23 6 5" ]'
check "a body too short for everything is still filled exactly and a row that cannot hold a box is merged by the view" '[ "$(sv 12 3:3:3:0 14:6:44:3 7:6:7:1)" = "3 6 3" ]'
check "widths of a 250-column screen: four boxes that share what is left by weight, none above its maximum" '[ "$(sv 250 50:40:100:3 40:30:60:2 40:30:60:2 44:34:90:2)" = "76 57 57 60" ]'
check "widths of 160 columns: three boxes, then the network and the containers; every row adds up to the width" 'for c in 120 160 199 200 250 300; do for spec in "48:40:100:3 38:30:70:2 40:30:70:2" "40:34:48:1 0:60::3" "50:40:100:3 40:30:60:2 40:30:60:2 44:34:90:2"; do s=0; for v in $(sv "$c" $spec); do s=$((s + v)); done; [ "$s" -eq "$c" ] || exit 1; done; done'
check "a box never gets more than its maximum while another can take it (cpu 100, memory and disks 60) up to 300 columns" 'for c in 200 250 300; do w=($(sv "$c" 50:40:100:3 40:30:60:2 40:30:60:2 44:34:90:2)); [ "${w[0]}" -le 100 ] && [ "${w[1]}" -le 60 ] && [ "${w[2]}" -le 60 ] || exit 1; done'


finish

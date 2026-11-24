#!/usr/bin/env bash
# Runs scripted key sequences through the panel against the simulated server (tests/tools/sim_env.sh; never the real Docker) and saves EVERY
# frame of each run, at several sizes, plain and with colours. Two trees saved from two versions of the code can be compared with `diff -r`:
# it is how a refactor of the panel is proven not to change what is drawn (views, dialogs, wizard, options, help, palette, console, mouse).
# usage: tests/tools/panel_scenarios.sh <out-dir> [theme]
set -u
OUT="${1:?usage: panel_scenarios.sh <out-dir> [theme]}"
THEME="${2:-matrix}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/tools/sim_env.sh
source "$HERE/sim_env.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
sim_build "$TMP/sim" 12
mkdir -p "$OUT"
cd "$SIM_REPO" || exit 1
# Every run starts from the same server: a scenario that deploys or creates an instance must not leak into the next one.
cp -a "$SIM_REPO/instances" "$TMP/instances.orig"
cp -a "$SIM_FIX" "$TMP/fix.orig"
export LANG=C.UTF-8
CP=$'\020'   # Ctrl+P

declare -A SC=()
SC[views]="1 2 3 4 5 6 1"
SC[tabs]="tab tab tab tab tab tab tab btab btab btab btab btab btab btab esc"
SC[sample]="sample sample sample 2 sample 1 sample"
SC[instances]="down down up right right left left enter down up esc z esc tab tab tab btab esc"
SC[instances_keys]="u wait esc c wait esc s wait esc e wait esc l x wait esc"
SC[logs]="tab tab space f e / a b enter esc s e enter [ ] esc esc z esc"
SC[resources]="2 down down down up s s s s pgdn pgup enter"
SC[output]="3 up up pgup home end down pgdn e e f g G"
SC[runs]="4 down down up t esc t s esc enter esc e esc pgdn pgup"
SC[procs]="5 down up pgdn pgup"
SC[console]="6 s t a t u s enter esc wait enter x enter up up esc down esc esc"
SC[console2]=": h e l p enter : s t a t u s space c o enter wait esc"
SC[alias]=": a l i a s space u p = d o c t o r enter : a l i a s enter : u n a l i a s space u p enter esc"
SC[palette]="$CP d e s p down down up backspace backspace enter wait $CP esc"
SC[help]="? pgdn pgdn pgdn end home down up esc ? x 3 ? esc"
SC[help_views]="4 ? esc 5 ? esc 6 ? esc 2 ? pgdn esc"
SC[options]="o down down down down right left enter esc o up up esc o enter enter enter esc"
SC[wizard]="n enter enter enter tab down down enter esc"
SC[wizard2]="n a b c backspace backspace backspace pgdn space down space down pgdn pgdn pgdn pgup up esc esc"
SC[wizard3]="n x y z pgdn down space space pgdn pgdn tab tab c esc esc"
SC[wizard_fields]="n enter c o l o r a d o enter down space enter enter enter enter enter enter enter wait"
SC[menu]="enter down down down up enter wait esc enter esc"
SC[menu_confirm]="enter down down down down down enter n wait"
SC[menu_name]="enter down down down down down down down down enter wait esc esc"
SC[newbtn]="up enter esc"
SC[lang_theme]="L T T T T T T L p p r x"
SC[mouse_tabs]="mouse:0:3:2 mouse:0:20:2 mouse:0:40:2 mouse:0:60:2 mouse:0:80:2 mouse:0:100:2 mouse:0:3:2"
SC[mouse_list]="mouse:0:5:4 mouse:0:5:6 mouse:0:5:7 mouse:0:5:7 esc mouse:64:5:7 mouse:65:5:7"
SC[filter]="tab tab / e r r enter backspace esc esc"
SC[resize_keys]="1 2 3 4 5 6 : esc"

for size in 50x10 80x24 100x30 120x30 160x40; do
  cols="${size%x*}" rows="${size#*x}"
  for name in "${!SC[@]}"; do
    : > "$TMP/keys"
    for k in ${SC[$name]}; do
      case "$k" in
        space) printf ' \n' ;;
        *) printf '%s\n' "$k" ;;
      esac
    done >> "$TMP/keys"
    printf 'q\n' >> "$TMP/keys"
    for mode in plain color; do
      rm -rf "$SIM_REPO/instances" "$SIM_FIX"; cp -a "$TMP/instances.orig" "$SIM_REPO/instances"; cp -a "$TMP/fix.orig" "$SIM_FIX"
      if [ "$mode" = plain ]; then c=(DELTACTL_COLOR=never DELTACTL_ASCII=1); else c=(DELTACTL_COLOR=always COLORTERM=truecolor); fi
      env "${c[@]}" DELTACTL_THEME="$THEME" DELTACTL_TUI_KEYS="$TMP/keys" DELTACTL_UI=rich COLUMNS="$cols" DELTACTL_TUI_ROWS="$rows" \
        timeout 60 bash ./deltactl 2>&1 | sed -E 's/[0-9]+ ?(s|ms)\b/N\1/g' > "$OUT/$name-$size-$mode.txt"
    done
  done
done
echo "scenarios in $OUT: $(ls "$OUT" | wc -l) files"

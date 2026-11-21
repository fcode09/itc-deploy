#!/usr/bin/env bash
# shellcheck disable=SC2034  # LAY is read by the views that use this layer
# Layout engine of the panel: splits a length (the columns or the rows a view has) between its panels by rules, instead of each view
# working out its own arithmetic. Sourced by lib/cmd/dashboard.sh; pure Bash, no fork.
#
#   lay_split <total> <panel>...      one size per panel into the array LAY, in the same order
#
# Each panel is "want:min:max:grow[:opt]" (empty fields allowed):
#   want   the size it asks for (0 or empty: nothing in particular)
#   min    it never gets less, unless the total cannot hold the panels that must be there
#   max    it never gets more (empty: no limit), except the last panel when nobody else can take what is left; when max is below
#          min, max wins
#   grow   its share of what is left over (0 or empty: it does not grow)
#   opt    1: an optional panel, dropped (size 0) when the others would have to shrink below their minimum to make room for it
#
# The rules, in order:
#   1. every panel starts at its want, kept within min and max;
#   2. if they do not fit, the panels that grow shrink back towards their minimum (the last one first), then the optional ones are
#      dropped (the last one first), then the other panels come down to their minimum (the last one first), and as a last resort
#      the panels are cut, the last one first;
#   3. what is left over goes to the panels that grow, in proportion to their weight and up to their max; whatever nobody can take
#      goes to the last panel that was not dropped, so the panels always fill the total exactly (unless every panel was optional
#      and dropped). A negative total counts as 0.
#
# Examples: three columns, a fixed list, a flexible centre of at least 76 and an optional events column of 36:
#   lay_split 160 "42:42:42" "0:76::1" "36:36:36:0:1"   ->  42 82 36
#   lay_split 140 "38:38:38" "0:76::1" "36:36:36:0:1"   ->  38 102 0     (the events column does not fit next to 76)

LAY=()

lay_split() { # total panel...
  local total="$1" n i spec want min max grow opt free take wsum add given f0
  shift
  [ "$total" -ge 0 ] || total=0
  local -a mn=() mx=() gw=() op=() dr=()
  LAY=()
  n=$#
  i=0
  for spec in "$@"; do
    # Up to five fields separated by ':'; missing ones are empty.
    spec+="::::"
    want="${spec%%:*}"; spec="${spec#*:}"
    min="${spec%%:*}"; spec="${spec#*:}"
    max="${spec%%:*}"; spec="${spec#*:}"
    grow="${spec%%:*}"; spec="${spec#*:}"
    opt="${spec%%:*}"
    want="${want:-0}" min="${min:-0}" grow="${grow:-0}" opt="${opt:-0}"
    [ "$want" -ge "$min" ] || want="$min"
    [ -z "$max" ] || [ "$want" -le "$max" ] || want="$max"
    LAY[i]="$want" mn[i]="$min" mx[i]="$max" gw[i]="$grow" op[i]="$opt" dr[i]=0
    i=$((i + 1))
  done
  free="$total"
  for ((i = 0; i < n; i++)); do free=$((free - LAY[i])); done

  if [ "$free" -lt 0 ]; then
    # 2a. the panels that grow give back what they have above their minimum
    for ((i = n - 1; i >= 0 && free < 0; i--)); do
      [ "${gw[i]}" -gt 0 ] || continue
      take=$((LAY[i] - mn[i]))
      [ "$take" -gt 0 ] || continue
      [ "$take" -le $((-free)) ] || take=$((-free))
      LAY[i]=$((LAY[i] - take)) free=$((free + take))
    done
    # 2b. the optional panels are dropped
    for ((i = n - 1; i >= 0 && free < 0; i--)); do
      [ "${op[i]}" -eq 1 ] && [ "${LAY[i]}" -gt 0 ] || continue
      free=$((free + LAY[i])) LAY[i]=0 gw[i]=0 dr[i]=1
    done
    # 2c. the other panels come down to their minimum
    for ((i = n - 1; i >= 0 && free < 0; i--)); do
      take=$((LAY[i] - mn[i]))
      [ "$take" -gt 0 ] || continue
      [ "$take" -le $((-free)) ] || take=$((-free))
      LAY[i]=$((LAY[i] - take)) free=$((free + take))
    done
    # 2d. the panels are cut, the last one first
    for ((i = n - 1; i >= 0 && free < 0; i--)); do
      take="${LAY[i]}"
      [ "$take" -le $((-free)) ] || take=$((-free))
      LAY[i]=$((LAY[i] - take)) free=$((free + take))
    done
  fi

  # 3. what is left over: to the panels that grow, by weight and up to their max
  while [ "$free" -gt 0 ]; do
    wsum=0
    for ((i = 0; i < n; i++)); do
      [ "${gw[i]}" -gt 0 ] || continue
      [ -z "${mx[i]}" ] || [ "${LAY[i]}" -lt "${mx[i]}" ] || continue
      wsum=$((wsum + gw[i]))
    done
    [ "$wsum" -gt 0 ] || break
    given=0 f0="$free"   # (the shares come from what was left at the start of the round)
    for ((i = 0; i < n && free > 0; i++)); do
      [ "${gw[i]}" -gt 0 ] || continue
      [ -z "${mx[i]}" ] || [ "${LAY[i]}" -lt "${mx[i]}" ] || continue
      add=$((f0 * gw[i] / wsum))
      [ "$add" -ge 1 ] || add=1
      [ -z "${mx[i]}" ] || [ "$add" -le $((mx[i] - LAY[i])) ] || add=$((mx[i] - LAY[i]))
      [ "$add" -le "$free" ] || add="$free"
      LAY[i]=$((LAY[i] + add)) free=$((free - add)) given=$((given + add))
    done
    [ "$given" -gt 0 ] || break
  done
  # ... and what nobody could take, to the last panel that was not dropped (the panels always fill the total).
  if [ "$free" -gt 0 ]; then
    for ((i = n - 1; i >= 0; i--)); do
      if [ "${dr[i]}" -eq 0 ]; then LAY[i]=$((LAY[i] + free)); break; fi
    done
  fi
}

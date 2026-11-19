#!/usr/bin/env bash
# shellcheck disable=SC2034  # GFX_LINES is read by the panel views
# Small text graphics for the panel: multi-row area charts made of the eight vertical block heights. Sourced by lib/bootstrap.sh.
#
# gfx_area <history> <max> <width> <rows>   history = space separated integers, oldest first
# Leaves GFX_LINES: <rows> strings of exactly <width> cells, TOP row first. The newest value is at the right edge; when there
# are fewer values than cells the chart starts blank at the left, so it scrolls in as samples arrive.
# One column holds one value and grows from the bottom: a value of v/max fills v*rows*8/max eighths of the height.
GFX_LINES=()

# The same chart, remembered under an id. Between two frames a chart usually only slides one column to the left and gets a new
# value on the right: then every row is shifted and only the new column is computed (a few operations instead of one per cell).
# Any other change (a different maximum, width, rows or history) draws the whole chart again.
declare -gA GFX_C_HIST=() GFX_C_KEY=() GFX_C_TEXT=()
gfx_area_cached() { # id history max width rows
  local id="$1" hist="$2" max="${3:-1}" w="${4:-1}" rows="$5" key prev x r base k ch joined="" lv slide pad sp
  local -a old=()
  key="$max|$w|$rows"
  prev="${GFX_C_HIST[$id]-}"
  if [ "${GFX_C_KEY[$id]-}" = "$key" ] && [ -n "$prev" ] && [ -n "$hist" ]; then
    if [ "$hist" = "$prev" ]; then
      mapfile -t GFX_LINES <<< "${GFX_C_TEXT[$id]}"
      return 0
    fi
    slide=-1
    if [ "${hist% *}" = "$prev" ]; then slide=0          # one more value than before
    elif [ "${hist% *}" = "${prev#* }" ]; then slide=1   # same number of values: the oldest one dropped out
    fi
    if [ "$slide" -ge 0 ]; then
      pad=0
      if [ "$slide" -eq 1 ]; then
        # The blank left part (history shorter than the chart) keeps its width: the oldest COLUMN is the one that goes.
        sp="${prev//[^ ]/}"
        pad=$((w - ${#sp} - 1))
        [ "$pad" -ge 0 ] || pad=0
      fi
      x="${hist##* }"
      [[ "$x" =~ ^[0-9]+$ ]] || x=0
      [ "$max" -gt 0 ] || max=1
      [ "$x" -le "$max" ] || x="$max"
      lv=$((x * rows * 8 / max))
      mapfile -t old <<< "${GFX_C_TEXT[$id]}"
      GFX_LINES=()
      for ((k = 0; k < rows; k++)); do
        r=$((rows - 1 - k))
        base=$((r * 8))
        if [ "$lv" -ge $((base + 8)) ]; then ch="${UI_SPARK[7]}"; elif [ "$lv" -gt "$base" ]; then ch="${UI_SPARK[$((lv - base - 1))]}"; else ch=" "; fi
        if [ "$slide" -eq 1 ]; then GFX_LINES+=("${old[$k]:0:$pad}${old[$k]:$((pad + 1))}$ch"); else GFX_LINES+=("${old[$k]:1}$ch"); fi
      done
      GFX_C_HIST[$id]="$hist"
      printf -v joined '%s\n' "${GFX_LINES[@]}"
      GFX_C_TEXT[$id]="${joined%$'\n'}"
      return 0
    fi
  fi
  gfx_area "$hist" "$max" "$w" "$rows"
  GFX_C_HIST[$id]="$hist" GFX_C_KEY[$id]="$key"
  printf -v joined '%s\n' "${GFX_LINES[@]}"
  GFX_C_TEXT[$id]="${joined%$'\n'}"
}

gfx_area() {
  local -a v=() lv=()
  local n i x r base l line max="${2:-1}" w="${3:-1}" rows="${4:-1}" levels pad
  GFX_LINES=()
  [ "$w" -gt 0 ] && [ "$rows" -gt 0 ] || return 0
  [ "$max" -gt 0 ] || max=1
  v=($1)
  n="${#v[@]}"
  if [ "$n" -gt "$w" ]; then v=("${v[@]:$((n - w))}"); n="$w"; fi
  levels=$((rows * 8))
  for ((i = 0; i < n; i++)); do
    x="${v[$i]}"
    [[ "$x" =~ ^[0-9]+$ ]] || x=0
    [ "$x" -le "$max" ] || x="$max"
    lv[i]=$((x * levels / max))
  done
  printf -v pad '%*s' $((w - n)) ''
  for ((r = rows - 1; r >= 0; r--)); do
    base=$((r * 8))
    line=""
    for ((i = 0; i < n; i++)); do
      l="${lv[$i]}"
      if [ "$l" -ge $((base + 8)) ]; then
        line+="${UI_SPARK[7]}"
      elif [ "$l" -gt "$base" ]; then
        line+="${UI_SPARK[$((l - base - 1))]}"
      else
        line+=" "
      fi
    done
    GFX_LINES+=("$pad$line")
  done
}

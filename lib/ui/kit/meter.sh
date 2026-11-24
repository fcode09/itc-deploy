#!/usr/bin/env bash
# shellcheck disable=SC2034  # KIT_OUT is read by the callers
# UI kit: the meter (a bar with the gradient of its magnitude along the filled part and a faint track behind), as btop's disk and
# memory bars. Sourced after lib/ui/tui.sh and lib/ui/tokens.sh; pure Bash, no fork.
#
#   kit_meter <percent 0-100> <width> [magnitude] [caps=1]   -> KIT_OUT, exactly <width> cells
#
# The filled part is drawn in eighths of a cell, so 43% of 20 cells is 8 full cells and 5 eighths. Each cell takes the colour of its
# position along the gradient (a bar at 50% shows the first half of the gradient), so the length AND the colour tell how full it is.
# The empty part is the faint track. caps=1 puts ▕ ▏ at the ends (they count inside the width). Without colour the filled part is █
# and the track ░; in ASCII # and . . The result is remembered per (magnitude, percent, width, theme): a meter that does not
# change costs one lookup.

declare -gA KM_CACHE=()
KM_CACHED=0

kit_meter() { # percent width [magnitude] [caps=1]
  local p="$1" w="$2" mag="${3:-ramp}" caps=0 inner e full part i key out="" pos on off cl cr
  [ "${4:-}" != "caps=1" ] || caps=1
  [[ "$p" =~ ^[0-9]+$ ]] || p=0
  [ "$p" -le 100 ] || p=100
  [ "$w" -gt 0 ] || { KIT_OUT=""; return 0; }
  key="$mag|$p|$w|$caps|$TH_GR_GEN|${UI_UTF8:-0}"
  if [[ -n "${KM_CACHE[$key]+x}" ]]; then KIT_OUT="${KM_CACHE[$key]}"; return 0; fi
  if [ "${UI_UTF8:-0}" -eq 1 ] && [ "${UI_RICH:-0}" -eq 1 ]; then on="█" off="░" cl="▕" cr="▏"; else on="#" off="." cl="[" cr="]"; fi
  inner="$w"
  if [ "$caps" -eq 1 ] && [ "$w" -ge 3 ]; then inner=$((w - 2)); else caps=0; fi
  e=$((p * inner * 8 / 100))
  full=$((e / 8)) part=$((e % 8))
  for ((i = 0; i < full; i++)); do
    th_grad "$mag" $(((i + 1) * 100 / inner))
    out+="$TH_C$on"
  done
  if [ "$part" -gt 0 ] && [ "$full" -lt "$inner" ]; then
    th_grad "$mag" $(((full + 1) * 100 / inner))
    pos="${UI_EIGHTHS[$part]}"
    # (ASCII has no eighths: a part of a cell is drawn as a full one only from the half on)
    [ -n "$pos" ] || { if [ "$part" -ge 4 ]; then pos="$on"; else pos="$off"; fi; }
    out+="$TH_C$pos"
    full=$((full + 1))
  fi
  if [ "$full" -lt "$inner" ]; then
    printf -v off_run '%*s' $((inner - full)) ''
    out+="${TH[track]:-}${off_run// /$off}"
  fi
  out+="$TH_RESET"
  if [ "$caps" -eq 1 ]; then out="${TH[border]:-}$cl$TH_RESET$out${TH[border]:-}$cr$TH_RESET"; fi
  if [ "$KM_CACHED" -ge 2048 ]; then KM_CACHE=() KM_CACHED=0; fi
  KM_CACHE[$key]="$out"
  KM_CACHED=$((KM_CACHED + 1))
  KIT_OUT="$out"
}

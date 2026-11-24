#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2206,SC2059  # KG_* results are read by the panel views; histories are split on purpose; \U needs a built format
# UI kit: graphs. Braille charts (2 samples x 4 levels per cell, btop's look), their mirrored version (one series up, one down), a
# readable scale and the fallbacks (eighth blocks, then ASCII). Sourced after lib/ui/tui.sh, lib/ui/tokens.sh and lib/ui/gfx.sh;
# pure Bash, no fork.
#
#   kit_graph <hist> <max|auto> <width> <rows> [option=value ...]      -> KG_LINES (top row first), KG_MAX
#   kit_graph_cached <id> <hist> <max|auto> <width> <rows> [option ...]  the same, remembered under an id (see below)
#   kit_graph_mirror <up-hist> <down-hist> <max|auto> <width> <rows-up> <rows-down> [option ...]   -> KG_LINES
#   kit_scale <hist> [floor]  -> KG_MAX: the smallest of 1, 2, 5 x 10^n that holds the largest value (and the floor)
#   kit_si <value>            -> KIT_OUT: a compact figure (950, 1.5K, 10M)
#
# <hist> is space separated integers, oldest first; the newest value is at the right edge, a short history starts blank at the left.
# Options: mag=<magnitude> (the gradient: cpu mem disk net_down net_up health ramp, default ramp), invert=1 (it hangs from the top),
#   zero=1 (a value of 0 still draws one dot, so an idle graph keeps its baseline), axis=1 (the scale, KG_MAX, written over the first
#   cell(s) of the top row), unit=<text> (appended to the axis label), mode=braille|blocks|ascii (default: KG_MODE).
# Every line is exactly <width> cells. Rows are coloured by the value they stand for (low rows with the low end of the gradient,
# high rows with the hot end), so a quiet series never looks like an alarm; with no colour the height says it.
#
# The braille symbols hold two samples side by side (the left and the right dot column), each with 0..4 dots filled from the bottom
# (or from the top when inverted): the 25 combinations are built once in KBR / KBI, indexed left*5+right.

KG_LINES=() KG_MAX=1 KG_MODE="braille"
declare -ga KBR=() KBI=() KCL=()
# KCL[v + 128] is v clamped to 0..4 (a level of a sample relative to the row being drawn): one array lookup instead of a comparison.
for ((KCL_I = -128; KCL_I < 256; KCL_I++)); do KCL[KCL_I + 128]=$((KCL_I < 0 ? 0 : (KCL_I > 4 ? 4 : KCL_I))); done
unset KCL_I

# Chooses the symbol set (braille where the terminal is UTF-8 and rich; DELTACTL_GRAPH=blocks forces eighth blocks) and builds the
# braille tables. Called when the kit is loaded and again after ui_init changes the terminal facts.
kit_graph_init() {
  local a b h ch want="${DELTACTL_GRAPH:-${TUI_GRAPH:-auto}}"
  local -a L=(0 64 68 70 71) R=(0 128 160 176 184) IL=(0 1 3 7 71) IR=(0 8 24 56 184)
  KBR=() KBI=()
  if [ "${UI_UTF8:-0}" -ne 1 ] || [ "${UI_RICH:-0}" -ne 1 ]; then KG_MODE=ascii; return 0; fi
  case "$want" in blocks) KG_MODE=blocks; return 0 ;; esac
  KG_MODE=braille
  for ((a = 0; a <= 4; a++)); do
    for ((b = 0; b <= 4; b++)); do
      if [ $((a + b)) -eq 0 ]; then KBR[a * 5 + b]=" " KBI[a * 5 + b]=" "; continue; fi
      printf -v h '%08x' $((0x2800 + L[a] + R[b])); printf -v ch "\\U$h"; KBR[a * 5 + b]="$ch"
      printf -v h '%08x' $((0x2800 + IL[a] + IR[b])); printf -v ch "\\U$h"; KBI[a * 5 + b]="$ch"
    done
  done
}

# The smallest of 1, 2, 5 x 10^n that is not below the largest value of the history (and not below the floor, default 1) into KG_MAX.
kit_scale() { # hist [floor]
  local m="${2:-1}" x p
  for x in $1; do [[ "$x" =~ ^[0-9]+$ ]] && [ "$x" -gt "$m" ] && m="$x"; done
  p=1
  while [ $((p * 10)) -le "$m" ]; do p=$((p * 10)); done
  if [ "$m" -le "$p" ]; then KG_MAX="$p"
  elif [ "$m" -le $((p * 2)) ]; then KG_MAX=$((p * 2))
  elif [ "$m" -le $((p * 5)) ]; then KG_MAX=$((p * 5))
  else KG_MAX=$((p * 10)); fi
}

# A compact figure into KIT_OUT: 950, 1.5K, 10M, 1.0G (decimal units; one decimal below ten).
kit_si() { # value
  local v="$1" u=0 t
  local -a U=("" K M G T)
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  t=$((v * 10))
  while [ "$v" -ge 1000 ] && [ "$u" -lt 4 ]; do v=$((v / 1000)); t=$((t / 1000)); u=$((u + 1)); done
  if [ "$u" -eq 0 ]; then KIT_OUT="$v"
  elif [ "$v" -lt 10 ]; then KIT_OUT="$((t / 10)).$((t % 10))${U[u]}"
  else KIT_OUT="$v${U[u]}"; fi
}

# The levels (0..levels) of the samples, right aligned to column $last of $cols columns, into the array LV.
kit_graph_levels() { # hist max cols last levels zero
  local -a v=()
  local n i j x max="$2" cols="$3" last="$4" levels="$5" zero="$6"
  LV=()
  for ((j = 0; j < cols; j++)); do LV[j]=0; done
  v=($1)
  n="${#v[@]}"
  for ((i = n - 1, j = last; i >= 0 && j >= 0; i--, j--)); do
    x="${v[$i]}"
    [[ "$x" =~ ^[0-9]+$ ]] || x=0
    [ "$x" -le "$max" ] || x="$max"
    LV[j]=$((x * levels / max))
    if [ "$zero" -eq 1 ] && [ "${LV[$j]}" -eq 0 ]; then LV[j]=1; fi
  done
}

# Raw rows (no colour) of a braille graph into GR_RAW, bottom row first (row r stands for the levels 4r..4r+4).
kit_graph_rows() { # hist max width rows invert phase zero
  local w="$3" rows="$4" inv="$5" phase="$6" zero="$7" r i a b line base tn=KBR
  local -a LV=()
  [ "$inv" -eq 0 ] || tn=KBI
  local -n T="$tn"
  GR_RAW=()
  kit_graph_levels "$1" "$2" $((w * 2)) $(( (phase == 2) ? w * 2 - 1 : w * 2 - 2)) $((rows * 4)) "$zero"
  for ((r = 0; r < rows; r++)); do
    base=$((4 * r))
    line=""
    base=$((128 - 4 * r))
    for ((i = 0; i < w; i++)); do
      line+="${T[KCL[LV[2 * i] + base] * 5 + KCL[LV[2 * i + 1] + base]]}"
    done
    GR_RAW[r]="$line"
  done
}

# One cell (left and right level 0..4 already clamped by the caller) of a braille row.
# Raw rows of the one-sample-per-cell fallbacks (eighth blocks, ASCII) into GR_RAW, bottom row first.
kit_graph_rows_blocks() { # hist max width rows invert zero ascii
  local w="$3" rows="$4" inv="$5" zero="$6" asc="$7" r i l base line ch
  local -a LV=()
  local -a S=("${UI_SPARK[@]}")
  GR_RAW=()
  kit_graph_levels "$1" "$2" "$w" $((w - 1)) $((rows * 8)) "$zero"
  for ((r = 0; r < rows; r++)); do
    base=$((8 * r))
    line=""
    for ((i = 0; i < w; i++)); do
      l=$((LV[i] - base))
      if [ "$l" -le 0 ]; then ch=" "
      elif [ "$inv" -eq 0 ]; then
        if [ "$l" -ge 8 ]; then ch="${S[7]}"; else ch="${S[$((l - 1))]}"; fi
      elif [ "$asc" -eq 1 ]; then
        if [ "$l" -ge 8 ]; then ch="#"; elif [ "$l" -ge 4 ]; then ch='"'; else ch="'"; fi
      else
        # (blocks hang from the top with the upper-part characters: full, upper half, upper eighth)
        if [ "$l" -ge 8 ]; then ch="█"; elif [ "$l" -ge 4 ]; then ch="▀"; else ch="▔"; fi
      fi
      line+="$ch"
    done
    GR_RAW[r]="$line"
  done
}

# Paints GR_RAW (bottom row first) into KG_LINES (top row first), each row in the colour of the value it stands for.
declare -gA KG_COL=()
kit_graph_paint() { # mag rows invert
  local mag="$1" rows="$2" inv="$3" r k key col
  KG_LINES=()
  for ((k = 0; k < rows; k++)); do
    if [ "$inv" -eq 0 ]; then r=$((rows - 1 - k)); else r="$k"; fi
    key="$mag|$rows|$r|$TH_GR_GEN"
    if [[ -z "${KG_COL[$key]+x}" ]]; then
      th_grad "$mag" $(( (r + 1) * 100 / rows ))
      KG_COL[$key]="$TH_C"
    fi
    col="${KG_COL[$key]}"
    if [ -n "$col" ]; then KG_LINES+=("$col${GR_RAW[$r]}$TH_RESET"); else KG_LINES+=("${GR_RAW[$r]}"); fi
  done
}

# The scale label over the first cells of the top line (faint), when asked.
kit_graph_axis() { # unit width
  local lab rest w="$2"
  kit_si "$KG_MAX"; lab="$KIT_OUT$1"
  [ "${#lab}" -lt "$w" ] || return 0
  kit_slice "${KG_LINES[0]}" "${#lab}" $((w - ${#lab})); rest="$KIT_OUT"
  KG_LINES[0]="${TH[dim]:-}$lab$TH_RESET$rest"
}

kit_graph() { # hist max width rows [option=value ...]
  local hist="$1" max="$2" w="$3" rows="$4" o mag=ramp inv=0 zero=0 axis=0 unit="" mode="$KG_MODE" asc
  shift 4
  for o in "$@"; do
    case "$o" in
      mag=*) mag="${o#mag=}" ;; invert=*) inv="${o#invert=}" ;; zero=*) zero="${o#zero=}" ;; axis=*) axis="${o#axis=}" ;;
      unit=*) unit="${o#unit=}" ;; mode=*) mode="${o#mode=}" ;;
    esac
  done
  KG_LINES=()
  [ "$w" -gt 0 ] && [ "$rows" -gt 0 ] || return 0
  if [ "$max" = auto ]; then kit_scale "$hist"; max="$KG_MAX"; else [ "$max" -gt 0 ] 2> /dev/null || max=1; KG_MAX="$max"; fi
  if [ "$mode" = braille ] && [ "${#KBR[@]}" -gt 0 ]; then kit_graph_rows "$hist" "$max" "$w" "$rows" "$inv" 2 "$zero"
  else
    asc=0
    [ "$mode" != ascii ] || asc=1
    kit_graph_rows_blocks "$hist" "$max" "$w" "$rows" "$inv" "$zero" "$asc"
  fi
  kit_graph_paint "$mag" "$rows" "$inv"
  [ "$axis" -eq 0 ] || kit_graph_axis "$unit" "$w"
}

# --- The cached braille chart ----------------------------------------------------------------------------------------------
# Between two frames a chart usually gets one new sample. A cell holds two samples, so the cells are paired in time and the chart
# moves one CELL every second sample: with a new sample either the right half of the last cell gets filled (only that cell changes
# in each row) or the chart slides one cell to the left and a new cell starts with the sample on its left half. Any other change
# (a different maximum, size, options or history) draws the whole chart again, aligned with the newest sample at the right edge.
declare -gA GK_HIST=() GK_KEY=() GK_PH=()
# (the raw rows of a chart are the array GKR_<id>, bottom row first: the id must be made of letters, digits and _)
kit_graph_cached() { # id hist max width rows [option=value ...]
  local id="$1" hist="$2" max="$3" w="$4" rows="$5" o mag=ramp inv=0 zero=0 axis=0 unit="" key prev ph x pv lx lp r tn=KBR
  local -a v=() old=()
  shift 5
  [[ "$id" =~ ^[A-Za-z0-9_]+$ ]] || id=default
  for o in "$@"; do
    case "$o" in
      mag=*) mag="${o#mag=}" ;; invert=*) inv="${o#invert=}" ;; zero=*) zero="${o#zero=}" ;; axis=*) axis="${o#axis=}" ;; unit=*) unit="${o#unit=}" ;;
    esac
  done
  if [ "$max" = auto ]; then kit_scale "$hist"; max="$KG_MAX"; else case "$max" in '' | *[!0-9]* | 0) max=1 ;; esac; KG_MAX="$max"; fi
  if [ "$KG_MODE" != braille ] || [ "${#KBR[@]}" -eq 0 ] || [ "$w" -le 0 ] || [ "$rows" -le 0 ]; then
    kit_graph "$hist" "$max" "$w" "$rows" "mag=$mag" "invert=$inv" "zero=$zero" "axis=$axis" "unit=$unit"
    return 0
  fi
  local -n RAW="GKR_$id"
  [ "$inv" -eq 0 ] || tn=KBI
  local -n T="$tn"
  key="$max|$w|$rows|$inv|$zero"
  prev="${GK_HIST[$id]-}"
  ph="${GK_PH[$id]:-2}"
  if [ "${GK_KEY[$id]-}" = "$key" ] && [ -n "$prev" ] && [ -n "$hist" ]; then
    if [ "$hist" = "$prev" ]; then
      GR_RAW=("${RAW[@]}")
      kit_graph_paint "$mag" "$rows" "$inv"
      [ "$axis" -eq 0 ] || kit_graph_axis "$unit" "$w"
      return 0
    fi
    # One more sample (the history is still growing), or the same number with the oldest gone. The second only when the history
    # fills the chart: otherwise the cells would still show samples that have already left it and would differ from a redraw.
    v=($hist)
    if [ "${hist% *}" = "$prev" ] || { [ "${hist% *}" = "${prev#* }" ] && [ "${#v[@]}" -ge $((w * 2)) ]; }; then
      x="${v[$((${#v[@]} - 1))]}"; pv="${v[$((${#v[@]} - 2))]:-0}"
      case "$x" in '' | *[!0-9]*) x=0 ;; esac
      case "$pv" in '' | *[!0-9]*) pv=0 ;; esac
      [ "$x" -le "$max" ] || x="$max"
      [ "$pv" -le "$max" ] || pv="$max"
      lx=$((x * rows * 4 / max)); lp=$((pv * rows * 4 / max))
      if [ "$zero" -eq 1 ]; then [ "$lx" -gt 0 ] || lx=1; [ "$lp" -gt 0 ] || lp=1; fi
      GR_RAW=()
      for ((r = 0; r < rows; r++)); do
        if [ "$ph" -eq 2 ]; then
          # A new cell: the chart slides one cell left, the sample is the left half of the new last cell.
          GR_RAW[r]="${RAW[r]:1}${T[KCL[lx - 4 * r + 128] * 5]}"
        else
          # The right half of the last cell gets the sample (its left half is the previous sample).
          GR_RAW[r]="${RAW[r]:0:$((w - 1))}${T[KCL[lp - 4 * r + 128] * 5 + KCL[lx - 4 * r + 128]]}"
        fi
      done
      if [ "$ph" -eq 2 ]; then GK_PH[$id]=1; else GK_PH[$id]=2; fi
      GK_HIST[$id]="$hist"
      RAW=("${GR_RAW[@]}")
      kit_graph_paint "$mag" "$rows" "$inv"
      [ "$axis" -eq 0 ] || kit_graph_axis "$unit" "$w"
      return 0
    fi
  fi
  kit_graph_rows "$hist" "$max" "$w" "$rows" "$inv" 2 "$zero"
  GK_HIST[$id]="$hist" GK_KEY[$id]="$key" GK_PH[$id]=2
  RAW=("${GR_RAW[@]}")
  kit_graph_paint "$mag" "$rows" "$inv"
  [ "$axis" -eq 0 ] || kit_graph_axis "$unit" "$w"
}

# One series up and another down from a shared baseline (download above, upload below), sharing one scale. Rows: $5 up, $6 down.
# Options as kit_graph (mag= applies to the upper series, magdown= to the lower one, default net_up).
kit_graph_mirror() { # up-hist down-hist max width rows-up rows-down [option ...]
  local up="$1" down="$2" max="$3" w="$4" ru="$5" rd="$6" o magdown=net_up axis=0 unit="" mag=net_down
  local -a top=() opts=()
  shift 6
  for o in "$@"; do
    case "$o" in
      magdown=*) magdown="${o#magdown=}" ;; mag=*) mag="${o#mag=}" ;; axis=*) axis="${o#axis=}" ;; unit=*) unit="${o#unit=}" ;;
      *) opts+=("$o") ;;
    esac
  done
  if [ "$max" = auto ]; then kit_scale "$up $down"; max="$KG_MAX"; fi
  kit_graph "$up" "$max" "$w" "$ru" "mag=$mag" "axis=$axis" "unit=$unit" "${opts[@]}"
  top=("${KG_LINES[@]}")
  kit_graph "$down" "$max" "$w" "$rd" "mag=$magdown" invert=1 "${opts[@]}"
  if [ "$axis" -eq 1 ] && [ "${#KG_LINES[@]}" -gt 0 ]; then
    local last=$((${#KG_LINES[@]} - 1)) lab rest
    kit_si "$max"; lab="$KIT_OUT$unit"
    if [ "${#lab}" -lt "$w" ]; then
      kit_slice "${KG_LINES[$last]}" "${#lab}" $((w - ${#lab})); rest="$KIT_OUT"
      KG_LINES[last]="${TH[dim]:-}$lab$TH_RESET$rest"
    fi
  fi
  KG_LINES=("${top[@]}" "${KG_LINES[@]}")
  KG_MAX="$max"
}

kit_graph_init

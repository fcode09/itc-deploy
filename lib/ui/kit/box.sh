#!/usr/bin/env bash
# shellcheck disable=SC2034  # KIT_* results are read by the panel views and the tests
# UI kit: the box of the redesign (a frame whose title and actions live IN the border, as chips) and the text helpers it needs.
# Sourced after lib/ui/tui.sh and lib/ui/tokens.sh; pure Bash, no fork. Every function leaves its result in a KIT_* variable and
# depends only on its arguments (and the theme), so a view can keep the result in its per-panel cache (dash_pc_get/dash_pc_put).
#
# Label markup (chips, footers, any text passed to kit_hotkey):
#   ^p      the letter p is the shortcut: drawn in the theme's hotkey colour, in bold
#   {Enter} a whole key name drawn the same way (for keys longer than one letter)
#   ^^ {{   a literal ^ or {
# A chip may start with "N:" (one digit): the number of the key that focuses the box, drawn as a superscript (btop's ¹cpu).
#
# kit_box <width> <height> <array-name> [option=value ...]
#   chips=a|b|c   chips in the top border, left to right
#   status=text   one chip at the right of the top border (already styled if you want colours)
#   footer=a|b|c  chips in the bottom border (actions); items that do not fit are dropped whole: the first ones and the last two stay
#   focus=1       focused box: focus colour for the border and the first chip as a badge
#   color=<esc>   border colour (an escape sequence), instead of the theme's
# The lines go to KIT_BOX (one element per line, exactly <width> cells each, <height> lines). The body is the lines of the array
# (the same rules as tui_box: missing lines are blank, a line that starts with TUI_SEL is a selected row).

KIT_OUT="" KIT_BOX=()

# Text with the markup removed into KIT_OUT.
kit_plain() { # text
  local s="$1" out="" k
  while [ -n "$s" ]; do
    case "$s" in
      '^^'*) out+='^'; s="${s:2}" ;;
      '{{'*) out+='{'; s="${s:2}" ;;
      '^'?*) out+="${s:1:1}"; s="${s:2}" ;;
      '{'*'}'*) k="${s#\{}"; out+="${k%%\}*}"; s="${s#*\}}" ;;
      *) out+="${s:0:1}"; s="${s:1}" ;;
    esac
  done
  KIT_OUT="$out"
}

# Text with the shortcuts highlighted into KIT_OUT; $2 is the colour to return to after each one (default: none).
kit_hotkey() { # text [base]
  local s="$1" base="${2-}" out="" hk k chunk
  hk="${TH[hotkey]:-}$C_BLD"
  while [ -n "$s" ]; do
    case "$s" in
      '^^'*) out+='^'; s="${s:2}" ;;
      '{{'*) out+='{'; s="${s:2}" ;;
      '^'?*) out+="$hk${s:1:1}$C_OFF$base"; s="${s:2}" ;;
      '{'*'}'*) k="${s#\{}"; out+="$hk${k%%\}*}$C_OFF$base"; s="${s#*\}}" ;;
      '^'* | '{'*) out+="${s:0:1}"; s="${s:1}" ;;   # a lone ^ or { with nothing to mark
      *)
        chunk="${s%%[\^\{]*}"
        out+="$chunk"
        s="${s:${#chunk}}"
        ;;
    esac
  done
  KIT_OUT="$out"
}

# The digits of $1 as superscripts (plain digits in ASCII) into KIT_OUT.
kit_sup() { # digits
  local d="$1" i out=""
  for ((i = 0; i < ${#d}; i++)); do out+="${UI_SUP[${d:i:1}]}"; done
  KIT_OUT="$out"
}

# One chip label (plain: no colour of its own besides the shortcuts) into KIT_OUT: "N:label" -> "¹label", markup resolved.
# $2 is the colour of the text (the base the shortcuts return to).
kit_chip_label() { # chip base
  local c="$1" num=""
  if [[ "$c" =~ ^([0-9]):(.*)$ ]]; then num="${BASH_REMATCH[1]}" c="${BASH_REMATCH[2]}"; kit_sup "$num"; num="$KIT_OUT"; fi
  kit_hotkey "$c" "$2"
  KIT_OUT="$num$KIT_OUT"
}

# The same chip without any colour at all (for a badge, which has its own) into KIT_OUT.
kit_chip_plain() { # chip
  local c="$1" num=""
  if [[ "$c" =~ ^([0-9]):(.*)$ ]]; then num="${BASH_REMATCH[1]}" c="${BASH_REMATCH[2]}"; kit_sup "$num"; num="$KIT_OUT"; fi
  kit_plain "$c"
  KIT_OUT="$num$KIT_OUT"
}

# A border line of $2 cells with chips (see kit_box) into KIT_OUT. kind: top | bottom. $3 border colour, $4 focus (0|1),
# $5 chips separated by |, $6 status chip (top only).
kit_edge() { # kind width col focus chips status
  local kind="$1" w="$2" col="$3" foc="$4" chips="$5" status="$6"
  local inner=$((w - 2)) tl tr cl cr base used=0 i n fill st="" stw=0 plain
  local -a items=() txt=() len=()
  if [ "$kind" = top ]; then
    tl="$TH_B_TL" tr="$TH_B_TR" cl="$UI_S_CHIP_L" cr="$UI_S_CHIP_R" base="${TH[title]:-}$C_BLD"
  else
    tl="$TH_B_BL" tr="$TH_B_BR" cl="$UI_S_FCHIP_L" cr="$UI_S_FCHIP_R" base=""
  fi
  [ -z "$chips" ] || IFS='|' read -ra items <<< "$chips"
  n="${#items[@]}"
  if [ "$n" -eq 0 ] && [ -z "$status" ]; then
    tui_rep "$TH_B_H" "$inner"
    KIT_OUT="$col$tl$TUI_OUT$tr$C_OFF"
    return 0
  fi
  # Render every chip, then drop whole chips until the row fits.
  for ((i = 0; i < n; i++)); do
    if [ "$i" -eq 0 ] && [ "$foc" -eq 1 ] && [ "$kind" = top ]; then
      kit_chip_plain "${items[$i]}"
      plain="$KIT_OUT"
      [ -n "${TH[badge]:-}" ] || plain="$UI_S_SEL$plain"
      txt[i]="${TH[badge]:-$C_BLD} $plain $C_OFF"
    else
      kit_chip_label "${items[$i]}" "$base"
      txt[i]="$base$KIT_OUT$C_OFF"
    fi
  done
  if [ "$kind" = top ] && [ -n "$status" ]; then
    st="$status"; tui_vlen "$st"; stw=$((TUI_VL + 2 + 1))   # chip delimiters + the dash before the corner
  fi
  while :; do
    used=1   # the dash after the corner
    for ((i = 0; i < ${#txt[@]}; i++)); do
      tui_vlen "${txt[$i]}"; len[i]=$((TUI_VL + 2))
      used=$((used + len[i] + (i > 0 ? 1 : 0)))
    done
    [ $((used + stw)) -le "$inner" ] && break
    if [ "$stw" -gt 0 ] && [ "${#txt[@]}" -gt 0 ]; then st="" stw=0; continue; fi
    [ "${#txt[@]}" -gt 1 ] || break
    # A title keeps its first chips (the last ones go); the actions in the bottom border keep the first ones and the last two
    # (how to move, and help/quit): the ones just before the last two go first.
    if [ "$kind" = top ]; then i=$((${#txt[@]} - 1))
    elif [ "${#txt[@]}" -gt 3 ]; then i=$((${#txt[@]} - 3))
    else i=0; fi
    txt=("${txt[@]:0:i}" "${txt[@]:$((i + 1))}")
  done
  # Still too wide: the only chip is clipped.
  if [ "${#txt[@]}" -eq 1 ] && [ $((used + stw)) -gt "$inner" ]; then
    tui_clip "${txt[0]}" $((inner - 3 - stw)); txt[0]="$TUI_OUT"; len[0]=$((inner - 1 - stw))
    used=$((1 + len[0]))
  fi
  local line="$col$tl$TH_B_H$C_OFF"
  for ((i = 0; i < ${#txt[@]}; i++)); do
    [ "$i" -eq 0 ] || line+="$col$TH_B_H$C_OFF"
    line+="$col$cl$C_OFF${txt[$i]}$col$cr$C_OFF"
  done
  fill=$((inner - used - stw))
  tui_rep "$TH_B_H" "$fill"
  line+="$col$TUI_OUT$C_OFF"
  [ "$stw" -eq 0 ] || line+="$col$cl$C_OFF$st$col$cr$TH_B_H$C_OFF"
  KIT_OUT="$line$col$tr$C_OFF"
}

kit_box() { # width height array [option=value ...]
  local w="$1" h="$2" arr="$3" o chips="" status="" footer="" foc=0 col="" top bottom
  shift 3
  for o in "$@"; do
    case "$o" in
      chips=*) chips="${o#chips=}" ;;
      status=*) status="${o#status=}" ;;
      footer=*) footer="${o#footer=}" ;;
      focus=*) foc="${o#focus=}" ;;
      color=*) col="${o#color=}" ;;
    esac
  done
  if [ -z "$col" ]; then
    if [ "$foc" -eq 1 ]; then col="${TH[border_focus]:-$C_CYN}"; else col="${TH[border]:-$C_GRY}"; fi
  fi
  # The body and the side borders come from tui_box (selected rows included); the two edges are replaced.
  tui_box "" "$w" "$h" "$arr" "$col" 0
  kit_edge top "$w" "$col" "$foc" "$chips" "$status"; top="$KIT_OUT"
  kit_edge bottom "$w" "$col" 0 "$footer" ""; bottom="$KIT_OUT"
  KIT_BOX=("$top" "${TUI_BOX[@]:1:$((h - 2))}" "$bottom")
}

# --- Overlays (a box floating over a drawing, as btop's CPU box over its graph) ---------------------------------------------------

# The visible cells [from, from+width) of a text that may carry colour sequences into KIT_OUT: the colours seen before `from` are
# replayed so the piece keeps its look; shorter text is padded with spaces. Ends with a reset.
kit_slice() { # text from width
  local s="$1" from="$2" w="$3" end pos=0 pre="" out="" chunk rest seq final full len a b shown
  end=$((from + w))
  while [ -n "$s" ] && [ "$pos" -lt "$end" ]; do
    if [[ "$s" == $'\033['* ]]; then
      rest="${s#$'\033['}"
      seq="${rest%%[A-Za-z]*}"
      final="${rest:${#seq}:1}"
      full=$'\033['"$seq$final"
      s="${rest:$((${#seq} + 1))}"
      if [ "$pos" -lt "$from" ]; then
        if [ "$final" = m ] && { [ -z "$seq" ] || [ "$seq" = 0 ]; }; then pre=""; else pre+="$full"; fi
      else
        out+="$full"
      fi
    else
      chunk="${s%%$'\033'*}"
      s="${s:${#chunk}}"
      len="${#chunk}"
      if [ $((pos + len)) -gt "$from" ]; then
        a=$((from > pos ? from - pos : 0))
        b=$((end - pos < len ? end - pos : len))
        out+="${chunk:a:b-a}"
      fi
      pos=$((pos + len))
    fi
  done
  shown=$((pos < end ? pos : end))
  shown=$((shown - from))
  [ "$shown" -ge 0 ] || shown=0
  [ "$shown" -ge "$w" ] || out+="${TUI_SPACES:0:$((w - shown))}"
  KIT_OUT="$pre$out$TH_RESET"
}

# Lays the lines of the array $3 (an inset box) over the lines of the array $1 (the base), with its top-left cell at row $2 and
# column $4 (0-based). The base array is changed in place; lines outside it are ignored.
kit_overlay() { # base-array top inset-array left
  local -n _base="$1"
  local -n _ins="$3"
  local top="$2" left="$4" j r iw bw head tail
  for ((j = 0; j < ${#_ins[@]}; j++)); do
    r=$((top + j))
    [ "$r" -ge 0 ] && [ "$r" -lt "${#_base[@]}" ] || continue
    tui_vlen "${_ins[$j]}"; iw="$TUI_VL"
    tui_vlen "${_base[$r]}"; bw="$TUI_VL"
    [ "$left" -lt "$bw" ] || continue
    [ $((left + iw)) -le "$bw" ] || iw=$((bw - left))
    kit_slice "${_base[$r]}" 0 "$left"; head="$KIT_OUT"
    kit_slice "${_base[$r]}" $((left + iw)) $((bw - left - iw)); tail="$KIT_OUT"
    tui_fit "${_ins[$j]}" "$iw"
    _base[r]="$head$TUI_OUT$TH_RESET$tail"
  done
}

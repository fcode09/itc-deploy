#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153  # OUTSUM_* are read by the panel views and the tests; the OUT_* come from lib/core/outparse.sh
# The summary of what a command printed, drawn with the kit: a headline with its icon, sections, items with their state, aligned columns,
# numbered steps, phases and the verdict. It draws what lib/core/outparse.sh read; it never adds text of its own besides the line that says how
# many lines were not summarised. Sourced after lib/ui/tui.sh, lib/ui/tokens.sh, lib/ui/kit/state.sh and lib/ui/kit/wrap.sh, and after
# lib/core/outparse.sh; pure Bash, no fork.
#
#   outsum_for <lines-array> <command-line> <running> <rc> <width> [key]   -> 0 when the output is recognised: OUTSUM_LINES (one per line, exactly
#                                                                            <width> cells), OUTSUM_COUNTS ("● 7 ▲ 2 ✖ 0" for a chip). The result is
#                                                                            kept until the output, the size, the language or the theme change, so a
#                                                                            frame costs nothing: the parsing happens once per output, not per frame.
#   outsum_build <width>                                                    -> OUTSUM_LINES from the OUT_* of the last out_parse
# The raw output is never touched: the view keeps showing it when this returns 1 (a command that is not recognised) or when the person asks for it.

OUTSUM_LINES=() OUTSUM_COUNTS="" OUTSUM_OK=0 OUTSUM_KEY="" OUTSUM_W=80

# The line of the summary: fitted to the width.
outsum_push() { # line
  tui_fit "$1" "$OUTSUM_W"
  OUTSUM_LINES+=("$TUI_OUT")
}

# A blank line, unless the summary is empty or already ends with one.
outsum_gap() {
  local n="${#OUTSUM_LINES[@]}"
  [ "$n" -gt 0 ] || return 0
  [ -n "${OUTSUM_LINES[n - 1]//[[:space:]]/}" ] || return 0
  tui_fit "" "$OUTSUM_W"
  OUTSUM_LINES+=("$TUI_OUT")
}

# The text wrapped under a prefix: the first line starts with $1, the next ones with $2; $3 is the width of the prefixes in cells; $4 the text; $5 the style.
outsum_wrap() { # first_prefix next_prefix prefix_cells text [style]
  local fp="$1" np="$2" pc="$3" text="$4" sty="${5-}" i room=$((OUTSUM_W - $3))
  [ "$room" -ge 8 ] || room=8
  kit_wrap "$text" "$room"
  [ "${#KW_LINES[@]}" -gt 0 ] || KW_LINES=("")
  for i in "${!KW_LINES[@]}"; do
    if [ "$i" -eq 0 ]; then outsum_push "$fp$sty${KW_LINES[i]}$TH_RESET"; else outsum_push "$np$sty${KW_LINES[i]}$TH_RESET"; fi
  done
}

# The colour of a state's text (the verdict and the headline are coloured by it).
outsum_col() { # state -> OUTSUM_C
  kit_state_color "$1"
  OUTSUM_C="$KIT_COL"
}
OUTSUM_C=""

outsum_build() { # width
  local w="$1" n="${#OUT_R_TYPE[@]}" i j k type st text detail tag sub run_end tw tagw dw ind icon line first ml
  local -a subs=()
  OUTSUM_W="$w"
  OUTSUM_LINES=()
  local dim="${TH[dim]:-}" acc="${TH[accent]:-}" bold="${C_BLD:-}"

  # --- the heading and the headline ----------------------------------------------------------------------------------------------------
  if [ -n "$OUT_TITLE" ]; then outsum_wrap "" "" 0 "$OUT_TITLE" "$acc$bold"; fi
  if [ -n "$OUT_HEAD_STATE" ]; then
    kit_state_icon "$OUT_HEAD_STATE"; icon="$KIT_ICON"
    outsum_col "$OUT_HEAD_STATE"
    outsum_wrap "$icon " "  " 2 "$OUT_HEAD_TEXT" "$OUTSUM_C$bold"
  fi
  outsum_gap

  # --- the rows ----------------------------------------------------------------------------------------------------------------------------
  i=0
  while [ "$i" -lt "$n" ]; do
    type="${OUT_R_TYPE[i]}"
    case "$type" in
      gone) i=$((i + 1)); continue ;;
      sec)
        outsum_gap
        text="${OUT_R_TEXT[i]}"
        ml=$((OUTSUM_W - ${#text} - 4))
        local rule=""
        if [ "$ml" -gt 0 ]; then printf -v rule '%*s' "$ml" ''; rule="${rule// /$UI_S_H}"; fi
        outsum_push "$dim$UI_S_H$UI_S_H $TH_RESET$bold$text$TH_RESET $dim$rule$TH_RESET"
        i=$((i + 1))
        ;;
      item)
        # A run of items that have columns (a detail on the same line, or a tag): the title column is as wide as the longest title.
        if [ -n "${OUT_R_DETAIL[i]}" ] || [ -n "${OUT_R_TAG[i]}" ]; then
          run_end="$i"
          tw=0 tagw=0
          for ((j = i; j < n; j++)); do
            [ "${OUT_R_TYPE[j]}" = item ] || break
            [ -n "${OUT_R_DETAIL[j]}" ] || [ -n "${OUT_R_TAG[j]}" ] || break
            [ "${#OUT_R_TEXT[j]}" -le "$tw" ] || tw="${#OUT_R_TEXT[j]}"
            [ "${#OUT_R_TAG[j]}" -le "$tagw" ] || tagw="${#OUT_R_TAG[j]}"
            run_end="$j"
          done
          [ "$tw" -le $((OUTSUM_W * 2 / 5)) ] || tw=$((OUTSUM_W * 2 / 5))
          [ "$tagw" -le $((OUTSUM_W / 4)) ] || tagw=$((OUTSUM_W / 4))
          dw=$((OUTSUM_W - 4 - tw - 2 - (tagw > 0 ? tagw + 2 : 0)))
          [ "$dw" -ge 6 ] || dw=6
          for ((j = i; j <= run_end; j++)); do
            [ "${OUT_R_PB[j]}" != 1 ] || [ "$j" -eq "$i" ] || outsum_gap
            kit_state_icon "${OUT_R_STATE[j]}"; icon="$KIT_ICON"
            tui_fit "${OUT_R_TEXT[j]}" "$tw"; text="$TUI_OUT"
            ind="  $icon $text  "
            tag=""
            if [ "$tagw" -gt 0 ]; then
              kit_state_color "${OUT_R_STATE[j]}"
              tui_fit "${OUT_R_TAG[j]}" "$tagw"
              tag="  $KIT_COL$TUI_OUT$TH_RESET"
            fi
            if [ -z "${OUT_R_TAG[j]}" ]; then
              # no tag: a long detail goes on under the first line, aligned with it
              local pad=""
              printf -v pad '%*s' $((4 + tw + 2)) ''
              outsum_wrap "$ind" "$pad" $((4 + tw + 2)) "${OUT_R_DETAIL[j]}" "$dim"
            else
              tui_fit "$dim${OUT_R_DETAIL[j]}$TH_RESET" "$dw"
              outsum_push "$ind$TUI_OUT$tag"
            fi
            if [ -n "${OUT_R_SUB[j]}" ]; then outsum_wrap "      " "      " 6 "${OUT_R_SUB[j]}" "$dim"; fi
          done
          i=$((run_end + 1))
        else
          [ "${OUT_R_PB[i]}" != 1 ] || outsum_gap
          kit_state_icon "${OUT_R_STATE[i]}"; icon="$KIT_ICON"
          outsum_wrap "  $icon " "    " 4 "${OUT_R_TEXT[i]}"
          if [ -n "${OUT_R_SUB[i]}" ]; then
            # (the lines under an item keep their line breaks: each is wrapped on its own)
            local sl
            while IFS= read -r sl; do outsum_wrap "      " "      " 6 "$sl" "$dim"; done <<< "${OUT_R_SUB[i]}"
          fi
          i=$((i + 1))
        fi
        ;;
      kv)
        run_end="$i"; tw=0
        for ((j = i; j < n; j++)); do
          [ "${OUT_R_TYPE[j]}" = kv ] || break
          [ "${#OUT_R_TEXT[j]}" -le "$tw" ] || tw="${#OUT_R_TEXT[j]}"
          run_end="$j"
        done
        [ "$tw" -le $((OUTSUM_W / 3)) ] || tw=$((OUTSUM_W / 3))
        for ((j = i; j <= run_end; j++)); do
          tui_fit "${OUT_R_TEXT[j]}" "$tw"
          local pad2=""
          printf -v pad2 '%*s' $((2 + tw + 2)) ''
          outsum_wrap "  $dim$TUI_OUT$TH_RESET  " "$pad2" $((2 + tw + 2)) "${OUT_R_DETAIL[j]}"
        done
        i=$((run_end + 1))
        ;;
      step)
        kit_state_icon "${OUT_R_STATE[i]}"; icon="$KIT_ICON"
        outsum_wrap "  $icon " "    " 4 "${OUT_R_TEXT[i]}"
        i=$((i + 1))
        ;;
      num)
        [ "${OUT_R_PB[i]}" != 1 ] || outsum_gap
        outsum_wrap "  $acc$bold${OUT_R_DETAIL[i]}.$TH_RESET " "     " $((3 + ${#OUT_R_DETAIL[i]})) "${OUT_R_TEXT[i]}"
        i=$((i + 1))
        ;;
      hint)
        outsum_wrap "  $acc$UI_S_ARROW$TH_RESET " "    " $((3 + ${#UI_S_ARROW})) "${OUT_R_TEXT[i]}" "$acc"
        i=$((i + 1))
        ;;
      note)
        [ "${OUT_R_PB[i]}" != 1 ] || outsum_gap
        outsum_wrap "" "" 0 "${OUT_R_TEXT[i]}" "$dim"
        i=$((i + 1))
        ;;
      *) i=$((i + 1)) ;;
    esac
  done

  # --- the verdict ---------------------------------------------------------------------------------------------------------------------------
  if [ -n "$OUT_VER_STATE" ]; then
    outsum_gap
    kit_state_icon "$OUT_VER_STATE"; icon="$KIT_ICON"
    outsum_col "$OUT_VER_STATE"
    outsum_wrap "$icon " "  " 2 "$OUT_VER_TEXT" "$OUTSUM_C$bold"
  fi
  # --- what is not here ----------------------------------------------------------------------------------------------------------------------
  if [ "$OUT_IGNORED" -gt 0 ]; then
    outsum_gap
    t_r tui.out.unsummarised "$OUT_IGNORED"
    outsum_wrap "" "" 0 "$T_OUT" "$dim"
  fi
  # (a trailing blank line is not part of the summary)
  while [ "${#OUTSUM_LINES[@]}" -gt 0 ] && [ -z "${OUTSUM_LINES[${#OUTSUM_LINES[@]} - 1]//[[:space:]]/}" ]; do unset 'OUTSUM_LINES[${#OUTSUM_LINES[@]}-1]'; done
}

# The counters as text for a chip: only the states that appear.
outsum_counts() {
  OUTSUM_COUNTS=""
  [ $((OUT_CNT_OK + OUT_CNT_WARN + OUT_CNT_ERR)) -gt 0 ] || return 0
  OUTSUM_COUNTS="$UI_S_OK $OUT_CNT_OK"
  [ "$OUT_CNT_WARN" -eq 0 ] || OUTSUM_COUNTS+=" $UI_S_WARN $OUT_CNT_WARN"
  [ "$OUT_CNT_ERR" -eq 0 ] || OUTSUM_COUNTS+=" $UI_S_ERR $OUT_CNT_ERR"
}

# The summary of an output, cached: it is rebuilt only when the output, its state, the width, the language (key) or the theme (key) change.
# While the command runs and lines keep arriving (docker's progress by the hundred) it is rebuilt at most every OUTSUM_EVERY_US (300 ms): the frames
# in between show the last summary, and the one that comes when the command ends is always built.
OUTSUM_BASE="" OUTSUM_AT=0 OUTSUM_EVERY_US=300000
outsum_for() { # lines-array command-line running rc width [key]
  local -n _ol="$1"
  local n="${#_ol[@]}" key base
  base="$2|$3|${4-}|$5|${6-}"
  key="$base|$n|${_ol[n - 1]-}"
  if [ "$OUTSUM_KEY" = "$key" ]; then [ "$OUTSUM_OK" -eq 1 ]; return; fi
  if [ "$3" = 1 ] && [ "$OUTSUM_BASE" = "$base" ]; then
    host_now_us
    if [ $((HOST_NOW_US - OUTSUM_AT)) -lt "$OUTSUM_EVERY_US" ]; then [ "$OUTSUM_OK" -eq 1 ]; return; fi
  fi
  OUTSUM_KEY="$key" OUTSUM_BASE="$base" OUTSUM_OK=0 OUTSUM_LINES=() OUTSUM_COUNTS=""
  host_now_us; OUTSUM_AT="$HOST_NOW_US"
  out_parse "$1" "$2" "$3" "${4-}" || return 1
  outsum_build "$5"
  outsum_counts
  [ "${#OUTSUM_LINES[@]}" -gt 0 ] || return 1
  OUTSUM_OK=1
}

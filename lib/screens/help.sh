#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Mode: the keys screen (?).

# The keys of the help (?): when it is taller than the screen, the arrows, PgUp/PgDn and Home/End move it; any other key goes back.
dash_key_help() { # key
  local page=$((TUI_ROWS - 8)) k="$1"
  [ "$page" -ge 1 ] || page=1
  # With the vim keys off, j k g G are letters like any other: they go back.
  if [ "$DASH_VIM" -eq 0 ]; then case "$k" in j | k | g | G) k=other ;; esac; fi
  if [ "$DASH_HELP_MAX" -gt 0 ]; then
    case "$k" in
      up | k) DASH_HELP_OFF=$((DASH_HELP_OFF - 1)) ;;
      down | j) DASH_HELP_OFF=$((DASH_HELP_OFF + 1)) ;;
      pgup) DASH_HELP_OFF=$((DASH_HELP_OFF - page)) ;;
      pgdn) DASH_HELP_OFF=$((DASH_HELP_OFF + page)) ;;
      home | g) DASH_HELP_OFF=0 ;;
      end | G) DASH_HELP_OFF="$DASH_HELP_MAX" ;;
      *) DASH_MODE=normal; return 0 ;;
    esac
    [ "$DASH_HELP_OFF" -ge 0 ] || DASH_HELP_OFF=0
    [ "$DASH_HELP_OFF" -le "$DASH_HELP_MAX" ] || DASH_HELP_OFF="$DASH_HELP_MAX"
    return 0
  fi
  DASH_MODE=normal
}

# The keys (?): the help text over the body. A line too long for the screen goes on under its description (a hanging indent),
# never cut; the heading of the current view stands out and, when the text is taller than the screen, it opens scrolled to it
# (DASH_HELP_OFF -1) and the arrows, PgUp/PgDn and Home/End move it (dash_key_help).
DASH_HELP_OFF=0 DASH_HELP_MAX=0

dash_dialog_help() { # body_height
  local bh="$1" w tw line i k ind n avail head hi=-1 acc first rest cur word pad title end started
  local -a out=() words=()
  w=$((TUI_COLS - 2)); [ "$w" -le 100 ] || w=100
  tw=$((w - 6))     # the borders, the box's own space, two of indent and one of margin
  acc="${TH[accent]:-$C_CYN}"
  dt "tui.help.head.$DASH_VIEW"; head="$DTV"
  dt tui.help
  while IFS= read -r line; do
    # (the heading of the current view is coloured after the line is wrapped: its colour codes take no room on screen)
    first="${line%% *}"
    [ -z "$first" ] || [ "$first" != "$head" ] || hi="${#out[@]}"
    tui_vlen "$line"
    if [ "$TUI_VL" -le "$tw" ]; then out+=("$line"); continue; fi
    # Where the description starts: after the first run of three or more spaces (the padding of the keys' column), or after the
    # first word of a heading at the start of the line ("RESOURCES ↑ ↓ ..."). The keys stay as they are on the first line; the
    # lines that follow start under the description.
    i=0; while [ "$i" -lt "${#line}" ] && [ "${line:$i:1}" = " " ]; do i=$((i + 1)); done
    rest="${line:$i}" k=0
    if [[ "$rest" == *"   "* ]]; then
      word="${rest#*   }"; k=$((i + ${#rest} - ${#word}))
    elif [ "$i" -eq 0 ] && [[ "$rest" == *" "* ]]; then
      word="${rest#* }"; k=$((${#rest} - ${#word}))
    fi
    while [ "$k" -gt 0 ] && [ "$k" -lt "${#line}" ] && [ "${line:$k:1}" = " " ]; do k=$((k + 1)); done
    if [ "$k" -gt 0 ] && [ "$k" -le $((tw / 2)) ]; then ind="$k"; cur="${line:0:$k}"; rest="${line:$k}"
    else ind=$((i + 2)); cur="${line:0:$i}"; rest="${line:$i}"; fi
    printf -v pad '%*s' "$ind" ''
    read -ra words <<< "$rest"
    started=0
    for word in "${words[@]}"; do
      if [ "$started" -eq 0 ]; then cur+="$word"; started=1
      elif [ $((${#cur} + 1 + ${#word})) -gt "$tw" ]; then out+=("$cur"); cur="$pad$word"
      else cur+=" $word"; fi
    done
    out+=("$cur")
  done <<< "$DTV"
  [ "$hi" -lt 0 ] || out[hi]="$acc$C_BLD$head$C_OFF${out[$hi]:${#head}}"
  n="${#out[@]}"
  avail=$((bh - 4)); [ "$avail" -ge 1 ] || avail=1
  DASH_HELP_MAX=$((n - avail)); [ "$DASH_HELP_MAX" -ge 0 ] || DASH_HELP_MAX=0
  if [ "$DASH_HELP_OFF" -lt 0 ]; then
    DASH_HELP_OFF=0
    [ "$hi" -lt "$avail" ] || DASH_HELP_OFF="$hi"
  fi
  [ "$DASH_HELP_OFF" -le "$DASH_HELP_MAX" ] || DASH_HELP_OFF="$DASH_HELP_MAX"
  DASH_DLG=("")
  for ((i = DASH_HELP_OFF; i < n && i < DASH_HELP_OFF + avail; i++)); do DASH_DLG+=("  ${out[$i]}"); done
  DASH_DLG+=("")
  dt tui.help_title; title="$DTV"
  if [ "$DASH_HELP_MAX" -gt 0 ]; then end=$((DASH_HELP_OFF + avail)); [ "$end" -le "$n" ] || end="$n"; title+=" $UI_S_DOT $((DASH_HELP_OFF + 1))-$end/$n"; fi
  dash_dialog "$bh" "$title" "$w"
}

# The last line while the keys are shown: how to scroll them when they do not fit, or that any key goes back.
dash_help_keys() { # width
  if [ "$DASH_HELP_MAX" -gt 0 ]; then dt tui.help_scroll; dash_keyfit "${DTV//\{1\}/$DASH_UD}" "$1"
  else dt tui.help_close; dash_keyfit "$DTV" "$1"; fi
}

# --- The contract of lib/screens/registry.sh --------------------------------------------------------------------
scr_help_render() { dash_dialog_help "$2"; } # width height
scr_help_key() { dash_key_help "$1"; }
scr_help_keys() { dash_help_keys "$1"; TUI_FRAME+=(" $C_GRY$DASH_KF$C_OFF"); } # width
scr_help_sig() { DASH_SIG+="|$DASH_HELP_OFF"; }

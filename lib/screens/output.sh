#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Screen: Output (view 5). The full output of the last command, scrollable.

# The output box of the last command: $1 wide, $2 high, $3 scroll (lines above the end), $4 = 1 for errors only.
# The result is in TUI_BOX.
dash_out_box() { # width height scroll errors_only
  local w="$1" h="$2" scroll="${3:-0}" only="${4:-0}" focus="${5:-0}" inner title col st total start end i line
  local -a body=() errs_only=()
  local -n src=JOB_LINES   # read in place: copying up to ~2200 lines on every rebuild was the biggest cost of a frame
  inner=$((h - 2))
  if [ -z "$JOB_PID" ]; then
    dt tui.out.title; title="$DTV"
    dt tui.out.empty
    body=("$C_GRY$DTV$C_OFF")
    tui_box "$title" "$w" "$h" body "" "$focus"
    return 0
  fi
  dash_job_secs; dash_clock "$DASH_JS"
  if job_running; then
    col="$C_YEL"; dt tui.out.running; st="$DTV $DASH_CLK"
  elif [ "$JOB_CANCELLED" -eq 1 ]; then
    col="$C_GRY"; dt tui.out.cancelled; st="$DTV"
  elif [ "${JOB_RC:-0}" -eq 0 ]; then
    col="$C_GRN"; dt tui.out.ok; st="$DTV $DASH_CLK"
  else
    col="$C_RED"; dt tui.out.failed; st="${DTV//\{1\}/$JOB_RC} $DASH_CLK"
  fi
  dt tui.out.title
  title="$DTV $UI_S_DOT ./deltactl $JOB_TITLE $UI_S_DOT $st"
  # The summary (lib/core/outparse.sh read what the command printed, lib/ui/outsummary.sh draws it): for the commands that have a shape, unless the
  # person asked for the raw text (v) or for the errors only (e). It is built once per output and size, not per frame. What is not recognised
  # is shown raw, as always.
  DASH_OUT_SUM=0
  if [ "$only" -eq 0 ] && [ "$DASH_OUT_RAW" -eq 0 ]; then
    local running=0 sstop send
    job_running && running=1
    if outsum_for JOB_LINES "$JOB_TITLE" "$running" "${JOB_RC-}" $((w - 4)) "$TH_NAME|$TH_MODE|$DASH_LANG_N|$UI_S_OK"; then
      DASH_OUT_SUM=1
      total="${#OUTSUM_LINES[@]}"
      DASH_OUT_STOP_MAX=$((total - inner)); [ "$DASH_OUT_STOP_MAX" -ge 0 ] || DASH_OUT_STOP_MAX=0
      sstop="$DASH_OUT_STOP"
      [ "$sstop" -le "$DASH_OUT_STOP_MAX" ] || sstop="$DASH_OUT_STOP_MAX"
      [ "$sstop" -ge 0 ] || sstop=0
      send=$((sstop + inner)); [ "$send" -le "$total" ] || send="$total"
      for ((i = sstop; i < send; i++)); do body+=("${OUTSUM_LINES[i]}"); done
      # What the title says besides the command: that it is the summary, its counters and where in it the window is; each one only if it fits.
      local piece pos=""
      [ "$total" -le "$inner" ] || pos="$((sstop + 1))-$send/$total"
      dt tui.out.summary
      for piece in "$DTV" "$pos" "$OUTSUM_COUNTS"; do
        [ -n "$piece" ] || continue
        [ $((${#title} + 3 + ${#piece})) -gt $((w - 6)) ] || title+=" $UI_S_DOT $piece"
      done
      tui_box "$title" "$w" "$h" body "$col" "$focus"
      return 0
    fi
  fi
  if [ "$only" -eq 1 ]; then
    for line in "${JOB_LINES[@]}"; do
      case "$line" in *[Ee][Rr][Rr][Oo][Rr]* | *ECONN* | *[Ff][Aa][Ii][Ll]* | *"Unable to"* | *"✖"* | *"x "*) errs_only+=("$line") ;; esac
    done
    if [ "${#errs_only[@]}" -eq 0 ]; then dt tui.out.no_match; errs_only=("$C_GRY$DTV$C_OFF"); fi
    local -n src=errs_only   # re-point the reference (a plain assignment would write into JOB_LINES)
  fi
  total="${#src[@]}"
  [ "$scroll" -le $((total - inner)) ] || scroll=$((total - inner))
  [ "$scroll" -ge 0 ] || scroll=0
  DASH_OUT_SCROLL_EFF="$scroll"
  end=$((total - scroll))
  start=$((end - inner))
  [ "$start" -ge 0 ] || start=0
  for ((i = start; i < end; i++)); do body+=("${src[$i]}"); done
  if [ "$scroll" -gt 0 ]; then dt tui.out.scrolled; title+=" $UI_S_DOT $DTV -$scroll"; fi
  tui_box "$title" "$w" "$h" body "$col" "$focus"
}

DASH_OUT_SCROLL_EFF=0 DASH_OUT_STOP_MAX=0

dash_view_output() { # body_height
  dash_out_box "$TUI_COLS" "$1" "$DASH_OUT_SCROLL" "$DASH_OUT_ERRORS" 1
  TUI_FRAME+=("${TUI_BOX[@]}")
}

dash_key_output() {
  local page=$((TUI_ROWS - 7))
  [ "$page" -ge 3 ] || page=3
  # v: the summary of what the command printed or its raw text
  if [ "$1" = v ]; then DASH_OUT_RAW=$((1 - DASH_OUT_RAW)); DASH_OUT_SCROLL=0 DASH_OUT_STOP=0 DASH_OUT_ERRORS=0; return 0; fi
  if [ "$DASH_OUT_SUM" -eq 1 ] && [ "$DASH_OUT_ERRORS" -eq 0 ]; then
    # The summary reads from the top: the keys move the window down and up it.
    case "$1" in
      up | k) [ "$DASH_OUT_STOP" -le 0 ] || DASH_OUT_STOP=$((DASH_OUT_STOP - 1)) ;;
      down | j) DASH_OUT_STOP=$((DASH_OUT_STOP + 1)) ;;
      pgup) DASH_OUT_STOP=$((DASH_OUT_STOP - page)); [ "$DASH_OUT_STOP" -ge 0 ] || DASH_OUT_STOP=0 ;;
      pgdn) DASH_OUT_STOP=$((DASH_OUT_STOP + page)) ;;
      home | g) DASH_OUT_STOP=0 ;;
      end | G | f) DASH_OUT_STOP=100000 ;;
      e) DASH_OUT_ERRORS=1; DASH_OUT_SCROLL=0 ;;
    esac
    [ "$DASH_OUT_STOP" -le "$DASH_OUT_STOP_MAX" ] || DASH_OUT_STOP="$DASH_OUT_STOP_MAX"
    return 0
  fi
  case "$1" in
    up | k) DASH_OUT_SCROLL=$((DASH_OUT_SCROLL + 1)) ;;
    down | j) [ "$DASH_OUT_SCROLL" -le 0 ] || DASH_OUT_SCROLL=$((DASH_OUT_SCROLL - 1)) ;;
    pgup) DASH_OUT_SCROLL=$((DASH_OUT_SCROLL + page)) ;;
    pgdn) DASH_OUT_SCROLL=$((DASH_OUT_SCROLL - page)); [ "$DASH_OUT_SCROLL" -ge 0 ] || DASH_OUT_SCROLL=0 ;;
    home | g) DASH_OUT_SCROLL=100000 ;;
    end | G | f) DASH_OUT_SCROLL=0 ;;
    e) DASH_OUT_ERRORS=$((1 - DASH_OUT_ERRORS)); DASH_OUT_SCROLL=0 ;;
  esac
  # Do not scroll past the first line.
  [ "$DASH_OUT_SCROLL" -le "${#JOB_LINES[@]}" ] || DASH_OUT_SCROLL="${#JOB_LINES[@]}"
}

# --- The contract of lib/screens/registry.sh --------------------------------------------------------------------
scr_output_render() { dash_view_output "$2"; } # width height
scr_output_key() { dash_key_output "$1"; }
scr_output_keys() { dash_keys_view output "$1"; } # width
scr_output_texts() { DASH_KEYS[output]="$(t tui.keys.output "$DASH_UD" "$DASH_LR")"; }
scr_output_sig() { DASH_SIG+="|$DASH_OUT_SCROLL|$DASH_OUT_ERRORS|$DASH_OUT_RAW|$DASH_OUT_STOP"; }
scr_output_enter() { dash_act_moved_notice; }

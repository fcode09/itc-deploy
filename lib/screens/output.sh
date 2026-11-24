#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Screen: Output (view 3). The full output of the last command, scrollable.

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

DASH_OUT_SCROLL_EFF=0

dash_view_output() { # body_height
  dash_out_box "$TUI_COLS" "$1" "$DASH_OUT_SCROLL" "$DASH_OUT_ERRORS" 1
  TUI_FRAME+=("${TUI_BOX[@]}")
}

dash_key_output() {
  local page=$((TUI_ROWS - 7))
  [ "$page" -ge 3 ] || page=3
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
scr_output_sig() { DASH_SIG+="|$DASH_OUT_SCROLL|$DASH_OUT_ERRORS"; }

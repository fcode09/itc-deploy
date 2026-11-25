#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # DASH_NZ_* belong to lib/screens/newinst.sh
# Step 8 of the new-instance wizard: the review. It is the only place where the instance is created: the bar says how ready it is (how many of
# the steps before it are fine), every step says its answer in one line (the ones that need attention first), and three buttons say what to do
# next: Create, Create and check (then `./deltactl check <name>` runs) and Create and deploy (then `./deltactl deploy <name>` runs; it asks to
# press Enter again, because it starts containers). Nothing is written before the button: the answers are in memory until then.
#
# Keys: up/down (or left/right) choose the button, Enter runs it; c, p and d choose Create, Create and check and Create and deploy (and run
# the first two). A deploy needs a second Enter; any other key puts it back.

DASH_NZR_ACT=0 DASH_NZR_ARM=0   # the button in focus (0 create, 1 create and check, 2 create and deploy) and 1 when the deploy waits for its Enter
DASH_NZR_N=0 DASH_NZR_OK=0 DASH_NZR_BAD=0   # steps before the review, those that are fine, those that block (err)

dash_nzs_review_reset() { DASH_NZR_ACT=0 DASH_NZR_ARM=0; }
dash_nzs_review_enter() { DASH_NZR_ARM=0; }

dash_nzs_review_key() { # key
  case "$1" in
    enter) return 1 ;;
  esac
  DASH_NZR_ARM=0
  case "$1" in
    up | left | h) [ "$DASH_NZR_ACT" -le 0 ] || DASH_NZR_ACT=$((DASH_NZR_ACT - 1)) DASH_NZ_ERR="" ;;
    down | right | l) [ "$DASH_NZR_ACT" -ge 2 ] || DASH_NZR_ACT=$((DASH_NZR_ACT + 1)) DASH_NZ_ERR="" ;;
    c) DASH_NZR_ACT=0; dash_nz_next ;;
    p) DASH_NZR_ACT=1; dash_nz_next ;;
    d) DASH_NZR_ACT=2 DASH_NZ_ERR="" ;;
    *) return 1 ;;
  esac
  return 0
}

# How many of the steps before the review are fine (ok), need attention (warn) or block (err, that is: its gate refuses), into DASH_NZR_*.
dash_nzr_count() {
  local i n="$((${#DASH_NZ_STEPS[@]} - 1))" bad=0 ok=0 save="$DASH_NZ_ERR"
  for ((i = 0; i < n; i++)); do
    dash_nz_state "$i"
    if ! dash_nz_gate_ok "$i"; then bad=$((bad + 1)); continue; fi
    [ "$DASH_NZ_ST" = ok ] && ok=$((ok + 1))
  done
  DASH_NZ_ERR="$save"
  DASH_NZR_N="$n" DASH_NZR_OK="$ok" DASH_NZR_BAD="$bad"
}

dash_nzs_review_state() {
  dash_nzr_count
  if [ "$DASH_NZR_BAD" -gt 0 ]; then DASH_NZ_ST=err; t_r tui.nz.rev.v_block "$DASH_NZR_BAD"; DASH_NZ_VAL="$T_OUT"
  elif [ "$DASH_NZR_OK" -lt "$DASH_NZR_N" ]; then DASH_NZ_ST=warn; t_r tui.nz.rev.v_ready_warn "$((DASH_NZR_N - DASH_NZR_OK))"; DASH_NZ_VAL="$T_OUT"
  else DASH_NZ_ST=ok; t_r tui.nz.rev.v_ready; DASH_NZ_VAL="$T_OUT"; fi
}

dash_nzs_review_sig() { DASH_NZ_AS+="|rev:$DASH_NZR_ACT:$DASH_NZR_ARM"; }

# The readiness bar and the answer of each step (the ones that are not fine first) into DASH_NZ_B, then the three buttons.
dash_nzs_review_render() { # width height
  local iw="$1" ih="$2" i n l dim="${TH[dim]:-}" r="$TH_RESET" acc="${TH[accent]:-}" pct bw lab val row st need b mark key err="$DASH_NZ_ERR"
  local -a good=() todo=() lines=()
  n="$((${#DASH_NZ_STEPS[@]} - 1))"
  dash_nzr_count
  # the lines of the steps: an icon, the name and the answer; the ones that need attention are the ones that go first
  for ((i = 0; i < n; i++)); do
    t_r "tui.nz.step.${DASH_NZ_STEPS[$i]}"; lab="$T_OUT"
    dash_nz_state "$i"; st="$DASH_NZ_ST" val="$DASH_NZ_VAL"
    if ! dash_nz_gate_ok "$i"; then st=err; fi
    kit_state_icon "$st"
    printf -v row '%s %-11s %s' "$KIT_ICON" "$lab" "$dim$val$r"
    tui_fit "$row" "$iw"
    if [ "$st" = ok ]; then good+=("$TUI_OUT"); else todo+=("$TUI_OUT"); fi
  done
  need=$((n + 8))   # (blank, the question, blank, the bar, the steps, blank, the three buttons, their note)
  DASH_NZ_B=()
  if [ "$ih" -ge "$need" ]; then
    DASH_NZ_B+=("")
    t_r tui.nz.help.review; dash_wrap "$T_OUT" "$iw"
    for l in "${DASH_WRAP[@]}"; do DASH_NZ_B+=("$dim$l$r"); done
    DASH_NZ_B+=("")
  fi
  # the bar
  pct=$((DASH_NZR_N > 0 ? DASH_NZR_OK * 100 / DASH_NZR_N : 100))
  t_r tui.nz.rev.ready "$DASH_NZR_OK" "$DASH_NZR_N"; lab="$T_OUT"
  bw=$((iw - ${#lab} - 3))
  [ "$bw" -ge 8 ] || bw=8
  [ "$bw" -le 40 ] || bw=40
  kit_meter "$pct" "$bw" ramp
  DASH_NZ_B+=("$KIT_OUT $lab")
  # the steps: all of them when there is room, else only the ones that need attention
  if [ "$ih" -ge "$need" ]; then lines=("${todo[@]}" "${good[@]}"); else lines=("${todo[@]}"); fi
  for l in "${lines[@]}"; do DASH_NZ_B+=("$l"); done
  # the buttons
  [ "$ih" -lt $((${#DASH_NZ_B[@]} + 5)) ] || DASH_NZ_B+=("")
  for b in 0 1 2; do
    case "$b" in 0) key=tui.nz.rev.b_create ;; 1) key=tui.nz.rev.b_check ;; *) key=tui.nz.rev.b_deploy ;; esac
    t_r "$key"; lab="$T_OUT"
    if [ "$DASH_NZR_ACT" -eq "$b" ]; then mark="$UI_S_SEL"; else mark=" "; fi
    if [ "$DASH_NZR_BAD" -gt 0 ]; then
      tui_fit "$dim$mark [ $lab ]$r" "$iw"
    elif [ "$DASH_NZR_ACT" -eq "$b" ]; then
      tui_fit "$acc$mark$r $TUI_SEL$C_BLD[ $lab ]$r" "$iw"
    else
      tui_fit "  [ $lab ]" "$iw"
    fi
    DASH_NZ_B+=("$TUI_OUT")
  done
  case "$DASH_NZR_ACT" in 0) key=tui.nz.rev.n_create ;; 1) key=tui.nz.rev.n_check ;; *) key=tui.nz.rev.n_deploy ;; esac
  if [ "$DASH_NZR_ARM" -eq 1 ]; then
    kit_state_icon warn; t_r tui.nz.rev.confirm; dash_wrap "$T_OUT" $((iw - 2))
    DASH_NZ_B+=("$KIT_ICON ${TH[warn]:-}${DASH_WRAP[0]}$r")
    for l in "${DASH_WRAP[@]:1}"; do DASH_NZ_B+=("  ${TH[warn]:-}$l$r"); done
  elif [ "$ih" -ge $((${#DASH_NZ_B[@]} + 1)) ]; then
    t_r "$key" "$DASH_NZ_NAME"; dash_wrap "$T_OUT" $((iw - 2))
    for l in "${DASH_WRAP[@]}"; do DASH_NZ_B+=("  $dim$l$r"); done
  fi
  DASH_NZ_ERR="$err"   # (the gates of the steps say why they refuse in DASH_NZ_ERR: drawing must not leave that behind)
}

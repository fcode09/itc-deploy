#!/usr/bin/env bash
# shellcheck disable=SC2034  # KIT_BOX and KM_* are read by the views and the tests
# UI kit: modal boxes (a confirmation, and "type the name to confirm" for what cannot be undone) and the centring of a box over the
# screen. Sourced after box.sh, field.sh and wrap.sh; pure Bash, no fork.
#
#   kit_modal_confirm <width> <title> <message> [yes=<label>] [no=<label>] [sel=yes|no] [danger=1]   -> KIT_BOX
#   kit_modal_name <width> <title> <message> <required-name> <typed> <cursor> [prompt=<text>]       -> KIT_BOX
#   kit_modal_name_ok <typed> <required>   returns 0 when the typed text is exactly the required name
#   kit_center <base-array> <box-array>    lays the box in the middle of the base (kit_overlay)
# The box is <width> cells wide and as tall as its message needs. A confirmation shows two buttons (the selected one is a badge,
# without colour it is wrapped in > <) and the actions of the keys in its bottom border (Enter accept, Esc cancel); with danger=1 the
# border is drawn in the error colour. The name box shows the message, the name to type and a field that turns ok only when the text
# is exactly the name.

kit_modal_confirm() { # width title message [yes=] [no=] [sel=] [danger=1]
  local w="$1" title="$2" msg="$3" o yes="Yes" no="No" sel=yes danger=0 body=() b_yes b_no col=""
  shift 3
  for o in "$@"; do
    case "$o" in yes=*) yes="${o#yes=}" ;; no=*) no="${o#no=}" ;; sel=*) sel="${o#sel=}" ;; danger=*) danger="${o#danger=}" ;; esac
  done
  kit_wrap "$msg" $((w - 4))
  body=("" "${KW_LINES[@]}" "")
  if [ -n "${TH[badge]:-}" ]; then
    if [ "$sel" = yes ]; then b_yes="${TH[badge]} $yes $TH_RESET" b_no="${TH[dim]:-}[ $no ]$TH_RESET"; else b_yes="${TH[dim]:-}[ $yes ]$TH_RESET" b_no="${TH[badge]} $no $TH_RESET"; fi
  else
    if [ "$sel" = yes ]; then b_yes=">$yes<" b_no="[ $no ]"; else b_yes="[ $yes ]" b_no=">$no<"; fi
  fi
  body+=("  $b_yes    $b_no")
  [ "$danger" -eq 0 ] || col="${TH[err]:-}"
  kit_box "$w" $((${#body[@]} + 2)) body "chips=$title" 'footer={Enter} accept|{Esc} cancel' ${col:+"color=$col"}
}

kit_modal_name_ok() { # typed required
  [ -n "$2" ] && [ "$1" = "$2" ]
}

kit_modal_name() { # width title message required typed cursor [prompt=]
  local w="$1" title="$2" msg="$3" req="$4" typed="$5" cur="$6" prompt="Type the name to confirm:" o body=() st msg_state=""
  shift 6
  for o in "$@"; do case "$o" in prompt=*) prompt="${o#prompt=}" ;; esac; done
  kit_wrap "$msg" $((w - 4))
  body=("" "${KW_LINES[@]}" "" "$prompt ${C_BLD}${req}${TH_RESET}")
  # ok when it is the name; still waiting while what is typed can become the name; an error when it cannot.
  if kit_modal_name_ok "$typed" "$req"; then st=ok; elif [ -z "$typed" ] || [[ "$req" == "$typed"* ]]; then st=pend; else st=err; fi
  kit_field_render "" "$typed" "$cur" $((w - 4)) label_width=0 focus=1 state="$st"
  body+=("$KIT_OUT" "")
  kit_box "$w" $((${#body[@]} + 2)) body "chips=$title" 'footer={Enter} confirm|{Esc} cancel' "color=${TH[err]:-}"
}

kit_center() { # base-array box-array
  local -n _b="$1"
  local -n _m="$2"
  local bw mw
  tui_vlen "${_b[0]:-}"; bw="$TUI_VL"
  tui_vlen "${_m[0]:-}"; mw="$TUI_VL"
  kit_overlay "$1" $(((${#_b[@]} - ${#_m[@]}) / 2)) "$2" $(((bw - mw) / 2))
}

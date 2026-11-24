#!/usr/bin/env bash
# shellcheck disable=SC2034  # KF_* and KV_* are read by the views and the tests
# UI kit: the one-line field (a label, an editable value with a cursor, a state and a hint) and its keys. Sourced after
# lib/ui/tui.sh, lib/ui/tokens.sh and lib/ui/kit/state.sh; pure Bash, no fork.
#
# State of the field being edited (the view owns it, the kit only reads and changes it): KF_VALUE (the text) and KF_CUR (the cursor,
# 0..length). kit_field_key <key> edits them with the key names tui_key produces and returns 0 when it used the key, 1 when the
# caller must handle it (enter, esc, tab, up, down, ...). kit_field_insert <text> pastes: control characters and newlines are dropped.
#   keys: characters, space, backspace, delete, left, right, home, end, Ctrl+A / Ctrl+E (start, end), Ctrl+U (to the start),
#         Ctrl+K (to the end), Ctrl+W (the word before the cursor)
#
#   kit_field_render <label> <value> <cursor> <width> [option=value ...]   -> KIT_OUT (exactly <width> cells)
#     label_width=N   cells of the label column (default: the label's length + 2)
#     focus=1         draws the cursor (reverse video on the character under it) and uses the focus colour for the label
#     mask=1          shows • instead of the characters (a secret); reveal=1 shows them anyway
#     placeholder=txt shown faint while the value is empty
#     state=ok|warn|err|pend   an icon before the value (see kit_state_icon)
#     msg=txt         a message at the right, in the colour of the state (dropped if there is no room)
#     unit=txt        a faint suffix right after the value
# The value scrolls so that the cursor is always visible; an ellipsis marks the cut side.
#
# Validators: a function that receives the value and leaves KV_STATE (ok|warn|err|pend) and KV_MSG. kit_validate <function> <value>
# runs it. Ready-made: kv_required, kv_name (instance name), kv_port (1-65535).

KF_VALUE="" KF_CUR=0 KV_STATE="" KV_MSG=""

kit_field_insert() { # text
  local t="$1"
  t="${t//[[:cntrl:]]/}"
  [ -n "$t" ] || return 0
  KF_VALUE="${KF_VALUE:0:$KF_CUR}$t${KF_VALUE:$KF_CUR}"
  KF_CUR=$((KF_CUR + ${#t}))
}

kit_field_key() { # key
  local k="$1" b
  [ "$KF_CUR" -le "${#KF_VALUE}" ] || KF_CUR="${#KF_VALUE}"
  case "$k" in
    backspace) if [ "$KF_CUR" -gt 0 ]; then KF_VALUE="${KF_VALUE:0:$((KF_CUR - 1))}${KF_VALUE:$KF_CUR}"; KF_CUR=$((KF_CUR - 1)); fi ;;
    delete) KF_VALUE="${KF_VALUE:0:$KF_CUR}${KF_VALUE:$((KF_CUR + 1))}" ;;
    left) [ "$KF_CUR" -le 0 ] || KF_CUR=$((KF_CUR - 1)) ;;
    right) [ "$KF_CUR" -ge "${#KF_VALUE}" ] || KF_CUR=$((KF_CUR + 1)) ;;
    home | $'\001') KF_CUR=0 ;;
    end | $'\005') KF_CUR="${#KF_VALUE}" ;;
    $'\025') KF_VALUE="${KF_VALUE:$KF_CUR}" KF_CUR=0 ;;
    $'\013') KF_VALUE="${KF_VALUE:0:$KF_CUR}" ;;
    $'\027')
      b="${KF_VALUE:0:$KF_CUR}"
      b="${b%"${b##*[![:space:]]}"}"
      b="${b%"${b##*[[:space:]]}"}"
      KF_VALUE="$b${KF_VALUE:$KF_CUR}" KF_CUR="${#b}"
      ;;
    space) kit_field_insert " " ;;
    *)
      if [ "${#k}" -eq 1 ] && [[ "$k" != [[:cntrl:]] ]]; then kit_field_insert "$k"; else return 1; fi
      ;;
  esac
  return 0
}

kit_field_render() { # label value cursor width [option=value ...]
  local label="$1" value="$2" cur="$3" w="$4" o lw="" foc=0 mask=0 reveal=0 ph="" st="" msg="" unit="" shown out="" lcell avail
  local vw head ch tail start n icon="" mcol mw=0 lcol
  shift 4
  for o in "$@"; do
    case "$o" in
      label_width=*) lw="${o#label_width=}" ;; focus=*) foc="${o#focus=}" ;; mask=*) mask="${o#mask=}" ;; reveal=*) reveal="${o#reveal=}" ;;
      placeholder=*) ph="${o#placeholder=}" ;; state=*) st="${o#state=}" ;; msg=*) msg="${o#msg=}" ;; unit=*) unit="${o#unit=}" ;;
    esac
  done
  [ -n "$lw" ] || lw=$((${#label} + 2))
  [ "$cur" -le "${#value}" ] || cur="${#value}"
  shown="$value"
  if [ "$mask" -eq 1 ] && [ "$reveal" -eq 0 ] && [ -n "$value" ]; then
    printf -v shown '%*s' "${#value}" ''
    shown="${shown// /$UI_S_MASK}"
  fi
  if [ "$foc" -eq 1 ]; then lcol="${TH[accent]:-}$C_BLD"; else lcol="${TH[dim]:-}"; fi
  tui_fit "$label" "$lw"; lcell="$lcol$TUI_OUT$TH_RESET"
  if [ -n "$st" ]; then kit_state_icon "$st"; icon="$KIT_ICON "; fi
  # The message goes at the right when the value still has room.
  if [ -n "$msg" ]; then
    kit_state_color "${st:-dim}"; mcol="$KIT_COL"
    mw=$((${#msg} + 3))
  fi
  avail=$((w - lw - ${#icon} - mw))
  [ -z "$icon" ] || avail=$((w - lw - 2 - mw))
  if [ "$avail" -lt 4 ] && [ -n "$msg" ]; then mw=0; msg=""; avail=$((w - lw - (${#icon} > 0 ? 2 : 0))); fi
  [ "$avail" -ge 1 ] || avail=1
  vw="$avail"
  # What is drawn of the value: the part that holds the cursor (one cell at the end is kept for it).
  n="${#shown}"
  if [ -z "$value" ] && [ -n "$ph" ] && [ "$foc" -eq 0 ]; then
    tui_fit "${TH[faint]:-}$ph$TH_RESET" "$vw"; out="$TUI_OUT"
  else
    start=0
    if [ $((n + 1 + ${#unit})) -gt "$vw" ]; then
      start=$((cur - vw + 2))
      [ "$start" -ge 0 ] || start=0
      [ $((start + vw - 1)) -le "$n" ] || start=$((n - vw + 1))
      [ "$start" -ge 0 ] || start=0
    fi
    head="${shown:start:$((cur - start))}"
    ch="${shown:cur:1}"
    tail="${shown:$((cur + 1))}"
    if [ -z "$value" ] && [ -n "$ph" ]; then tail="$ph"; fi
    [ "$start" -eq 0 ] || head="$UI_S_ELL${head:1}"
    if [ "$foc" -eq 1 ]; then
      [ -n "$ch" ] || ch=" "
      out="$head${TH[sel]:-$'\033[7m'}$ch$TH_RESET$tail"
    else
      out="$head$ch$tail"
    fi
    [ -z "$unit" ] || out+="${TH[dim]:-} $unit$TH_RESET"
    tui_fit "$out" "$vw"; out="$TUI_OUT"
  fi
  [ -z "$icon" ] || out="$icon$out"
  if [ -n "$msg" ]; then
    # (one blank between the value and the message, two after it)
    tui_fit "$lcell$out" $((w - mw + 1)); KIT_OUT="$TUI_OUT$mcol$msg$TH_RESET  "
    tui_fit "$KIT_OUT" "$w"; KIT_OUT="$TUI_OUT"
  else
    tui_fit "$lcell$out" "$w"; KIT_OUT="$TUI_OUT"
  fi
}

# Runs a validator on a value: KV_STATE and KV_MSG, and returns 0 only when the state is ok.
kit_validate() { # function value
  KV_STATE=ok KV_MSG=""
  "$1" "$2"
  [ "$KV_STATE" = ok ]
}

kv_required() { # value
  if [ -z "$1" ]; then KV_STATE=err KV_MSG="required"; else KV_STATE=ok KV_MSG=""; fi
}
kv_name() { # value   an instance name: lowercase letters, digits and hyphen, starting with a letter, 2 to 31 characters
  if [ -z "$1" ]; then KV_STATE=pend KV_MSG="";
  elif [[ "$1" =~ ^[a-z][a-z0-9-]{1,30}$ ]]; then KV_STATE=ok KV_MSG="";
  else KV_STATE=err KV_MSG="a-z 0-9 -"; fi
}
kv_port() { # value
  if [ -z "$1" ]; then KV_STATE=pend KV_MSG="";
  elif [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; then KV_STATE=ok KV_MSG="";
  else KV_STATE=err KV_MSG="1-65535"; fi
}

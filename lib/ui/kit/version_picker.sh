#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153  # KVP_* results are read by the views and the tests; KTB_LINES comes from table.sh
# UI kit: the version picker, a table of the versions of ONE image (VERSION, CREATED, SIZE, ARCH, USE) with the most recent one starred (★),
# the tags that move marked (▲), the images that cannot run here marked (✖), and two rows at the end: "write another version…" and "load from
# a file…". Sourced after lib/ui/kit/table.sh, field.sh and state.sh; pure Bash, no fork. Used by the Images view, the new-instance wizard
# and the instance's Services tab, so a version is chosen the same way everywhere.
#
#   kit_vpick <width> <height> <records-array> [option=value ...]     -> KVP_LINES (exactly <height> lines)
# Records, one element each (the fields separated by $'\x1f', KIT_SEP; lib/core/imagecat.sh builds them with ic_picker_rows):
#   tag · created (text: "2 days ago") · size · architecture (as Docker says it, ? when it is not known) · use (text: "colorado (current)",
#   "" when nobody) · flags: star (the most recent one you may choose), mutable (latest or not a version: ▲), foreign (another architecture: ✖)
# Options:
#   sel=N        the selected row (0 = the first version; the rows "write another" and "load" come after the last version)
#   filter=text  versions whose tag or use do not contain it (ignoring case) are hidden; the two special rows stay
#   top=N        first row shown (it moves to keep the selection in view)
#   texts=NAME   an associative array with the texts (see kit_vpick_text for the keys); missing ones have English defaults
#   server_arch=amd64   the architecture of the server, for the message of an image that cannot run
#   note=text    a line (warning colour) shown when nothing more important is: "2.13.2 was created after 2.14.0"
#   status=text  what is being done ("loading app.tar…"), shown with a spinner icon; the panel keeps working meanwhile
#   other=0|1 load=0|1   show the row "write another" (default 1) / "load from a file" (default 1)
#   tagw=N       least width of the first column (views that draw several pickers one under the other give the same, so they line up)
#   msg=0        no message line: the table takes the whole <height> (a view that has its own place for what the line says)
#   typing=1 typed=text cursor=N   the row "write another" is being edited: the bottom line is a field that says if what is typed is a
#                version that is loaded (ok), one that is not (warn: it can be written now and loaded later) or not a valid tag (err)
# Results: KVP_N (rows), KVP_SEL (the selected row, kept inside 0..N-1), KVP_STAR (the row of the star, -1 if none), KVP_DEFAULT (the row to
#   start on: the star, else the first one that can run, else 0), KVP_COUNT "shown/total" (versions), and for the selected row KVP_KIND
#   (version | other | load), KVP_TAG, KVP_OK (1 when it can be chosen) and KVP_WHY (why not, when it cannot). KVP_TOP is the first row shown
#   (give it back as top= to keep the scroll). KVP_TYPED_STATE is the state of
#   the typed tag (ok | warn | err | pend).
#
#   kit_vpick_select <records-array> [filter] [other=0|1] [load=0|1]   computes KVP_IDX (the records shown), KVP_N, KVP_STAR, KVP_DEFAULT
#   kit_vpick_pick <records-array> <row> [server_arch]                  what the row is, for Enter: KVP_KIND, KVP_TAG, KVP_OK, KVP_WHY
# Enter: the selected row is a version that can run -> choose it; "write another" -> the view starts typing; "load" -> the view asks for the
# file. A version that cannot run says why instead of being chosen. The view opens the picker on KVP_DEFAULT, so Enter alone takes the star.

KVP_LINES=() KVP_IDX=() KVP_N=0 KVP_SEL=0 KVP_STAR=-1 KVP_DEFAULT=0 KVP_COUNT="0/0"
KVP_KIND="" KVP_TAG="" KVP_OK=0 KVP_WHY="" KVP_FLAGS="" KVP_TYPED_STATE=pend KVP_TYPED_ARCH="" KVP_T=""
KVP_NV=0 KVP_OTHER=1 KVP_LOAD=1 KVP_TOP=0

# The text of a key (from the array named in KVP_TEXTS, else the English default) into KVP_T, with {1} and {2} filled.
KVP_TEXTS=""
kit_vpick_text() { # key [a] [b]
  local k="$1" d
  case "$k" in
    col_version) d="VERSION" ;; col_created) d="CREATED" ;; col_size) d="SIZE" ;; col_arch) d="ARCH" ;; col_use) d="USE" ;;
    latest_hint) d="$UI_S_UP most recent" ;; unused) d="unused" ;; other) d="write another version$UI_S_ELL" ;; load) d="load from a file$UI_S_ELL" ;;
    empty) d="no versions loaded" ;; why_arch) d="image of architecture {1}; this server is {2}: it would not start" ;;
    hint_star) d="Enter chooses the most recent one" ;; hint_mutable) d="a tag that moves: it cannot take you back to an earlier version" ;;
    type_label) d="version" ;; type_ok) d="loaded" ;; type_missing) d="not loaded in this Docker yet" ;; type_bad) d="not a valid tag" ;;
    *) d="$k" ;;
  esac
  if [ -n "$KVP_TEXTS" ]; then
    local -n _tx="$KVP_TEXTS"
    [ -z "${_tx[$k]+x}" ] || d="${_tx[$k]}"
  fi
  d="${d//\{1\}/${2:-}}"
  KVP_T="${d//\{2\}/${3:-}}"
}

# Which records are shown, how many rows there are and where the star is.
kit_vpick_select() { # records-array [filter] [other=0|1] [load=0|1]
  local -n _rec="$1"
  local o i _vr lf="${2,,}" tag use flags
  local -a f
  KVP_OTHER=1 KVP_LOAD=1
  shift 2 2> /dev/null || shift $#
  for o in "$@"; do case "$o" in other=*) KVP_OTHER="${o#other=}" ;; load=*) KVP_LOAD="${o#load=}" ;; esac; done
  KVP_IDX=() KVP_STAR=-1 KVP_DEFAULT=-1
  local first_ok=-1 row=0
  for ((i = 0; i < ${#_rec[@]}; i++)); do
    _vr="${_rec[$i]}"
    IFS=$'\x1f' read -ra f <<< "$_vr"
    tag="${f[0]:-}" use="${f[4]:-}" flags="${f[5]:-}"
    if [ -n "$lf" ]; then
      [[ "${tag,,} ${use,,}" == *"$lf"* ]] || continue
    fi
    KVP_IDX+=("$i")
    if [ "$KVP_STAR" -lt 0 ] && [[ ",$flags," == *,star,* ]]; then KVP_STAR="$row"; fi
    if [ "$first_ok" -lt 0 ] && [[ ",$flags," != *,foreign,* ]]; then first_ok="$row"; fi
    row=$((row + 1))
  done
  KVP_NV="${#KVP_IDX[@]}"
  KVP_N="$KVP_NV"
  [ "$KVP_OTHER" -ne 1 ] || KVP_N=$((KVP_N + 1))
  [ "$KVP_LOAD" -ne 1 ] || KVP_N=$((KVP_N + 1))
  if [ "$KVP_STAR" -ge 0 ]; then KVP_DEFAULT="$KVP_STAR"
  elif [ "$first_ok" -ge 0 ]; then KVP_DEFAULT="$first_ok"
  else KVP_DEFAULT=0; fi
  KVP_COUNT="$KVP_NV/${#_rec[@]}"
}

# What the row $2 is, for Enter: KVP_KIND (version, other or load), KVP_TAG, KVP_OK (1 when it can be chosen) and KVP_WHY.
kit_vpick_pick() { # records-array row [server_arch]
  local -n _rec="$1"
  local row="$2" f_arch _vr
  local -a f
  KVP_KIND="" KVP_TAG="" KVP_OK=0 KVP_WHY="" KVP_FLAGS=""
  if [ "$row" -lt "$KVP_NV" ] 2> /dev/null && [ "$row" -ge 0 ]; then
    _vr="${_rec[${KVP_IDX[$row]}]}"
    IFS=$'\x1f' read -ra f <<< "$_vr"
    KVP_KIND=version KVP_TAG="${f[0]:-}" KVP_OK=1 KVP_FLAGS="${f[5]:-}"
    if [[ ",${f[5]:-}," == *,foreign,* ]]; then
      KVP_OK=0
      f_arch="${f[3]:-?}"
      kit_vpick_text why_arch "$f_arch" "${3:-?}"
      KVP_WHY="$KVP_T"
    fi
    return 0
  fi
  row=$((row - KVP_NV))
  if [ "$KVP_OTHER" -eq 1 ]; then
    if [ "$row" -eq 0 ]; then KVP_KIND=other KVP_OK=1; return 0; fi
    row=$((row - 1))
  fi
  if [ "$KVP_LOAD" -eq 1 ] && [ "$row" -eq 0 ]; then KVP_KIND=load KVP_OK=1; fi
}

# The state of a typed tag among the records: ok (loaded), warn (valid, not loaded), err (not a tag, or an image that cannot run), pend (empty).
kit_vpick_typed() { # records-array typed
  local -n _rec="$1"
  local typed="$2" _vr
  local -a f
  KVP_TYPED_STATE=warn KVP_TYPED_ARCH=""
  if [ -z "$typed" ]; then KVP_TYPED_STATE=pend; return 0; fi
  if ! [[ "$typed" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then KVP_TYPED_STATE=err; return 0; fi
  for _vr in "${_rec[@]}"; do
    IFS=$'\x1f' read -ra f <<< "$_vr"
    [ "${f[0]:-}" = "$typed" ] || continue
    if [[ ",${f[5]:-}," == *,foreign,* ]]; then KVP_TYPED_STATE=err KVP_TYPED_ARCH="${f[3]:-?}"; else KVP_TYPED_STATE=ok; fi
    return 0
  done
}

kit_vpick() { # width height records [option=value ...]
  local w="$1" h="$2" recs="$3" o sel=0 filter="" top=0 sarch="" note="" status="" typing=0 typed="" cur=0 other=1 load=1 tagw=0 msg=1
  local -n _vrec="$3"
  shift 3
  KVP_TEXTS=""
  for o in "$@"; do
    case "$o" in
      sel=*) sel="${o#sel=}" ;; filter=*) filter="${o#filter=}" ;; top=*) top="${o#top=}" ;; texts=*) KVP_TEXTS="${o#texts=}" ;;
      server_arch=*) sarch="${o#server_arch=}" ;; note=*) note="${o#note=}" ;; status=*) status="${o#status=}" ;;
      typing=*) typing="${o#typing=}" ;; typed=*) typed="${o#typed=}" ;; cursor=*) cur="${o#cursor=}" ;;
      other=*) other="${o#other=}" ;; load=*) load="${o#load=}" ;; tagw=*) tagw="${o#tagw=}" ;; msg=*) msg="${o#msg=}" ;;
    esac
  done
  kit_vpick_select "$recs" "$filter" "other=$other" "load=$load"
  [[ "$sel" =~ ^[0-9]+$ ]] || sel="$KVP_DEFAULT"
  [ "$sel" -lt "$KVP_N" ] || sel=$((KVP_N - 1))
  [ "$sel" -ge 0 ] || sel=0
  KVP_SEL="$sel"
  kit_vpick_pick "$recs" "$sel" "$sarch"
  # Rows of the table.
  local -a cols=() rows=() f
  local k _vr tag created size arch use flags tcell acell ucell mark col
  kit_vpick_text col_version; cols+=("$KVP_T|*|l")
  kit_vpick_text col_created; cols+=("$KVP_T|13|l")
  kit_vpick_text col_size; cols+=("$KVP_T|8|r")
  kit_vpick_text col_arch; cols+=("$KVP_T|9|l")
  kit_vpick_text col_use; cols+=("$KVP_T|*|l")
  # (a width of its own for the first column: the longest tag, between 8 and 22 cells)
  local tw=8
  [ "$tagw" -le "$tw" ] || tw="$tagw"
  for ((k = 0; k < KVP_NV; k++)); do
    _vr="${_vrec[${KVP_IDX[$k]}]}"
    tag="${_vr%%$'\x1f'*}"
    [ "${#tag}" -le $((tw - 4)) ] || tw=$((${#tag} + 4))
  done
  # (wide enough for the two special rows, which have their text in this column)
  if [ "$other" -eq 1 ]; then kit_vpick_text other; [ "${#KVP_T}" -le "$tw" ] || tw="${#KVP_T}"; fi
  if [ "$load" -eq 1 ]; then kit_vpick_text load; [ "${#KVP_T}" -le "$tw" ] || tw="${#KVP_T}"; fi
  [ "$tw" -le 26 ] || tw=26
  cols[0]="${cols[0]%%|*}|$tw|l"
  kit_vpick_text latest_hint; local hint_latest="$KVP_T"
  kit_vpick_text unused; local txt_unused="$KVP_T"
  # Only the rows that will be on screen are built (a list can be long): the window is the one kit_table computes for the same selection.
  local th=$h body top_w
  [ "$h" -lt 3 ] || [ "$msg" -eq 0 ] || th=$((h - 1))
  body=$((th - 1))
  top_w="$top"
  [ "$top_w" -ge 0 ] || top_w=0
  [ "$sel" -ge "$top_w" ] || top_w="$sel"
  [ "$sel" -lt $((top_w + body)) ] || top_w=$((sel - body + 1))
  [ $((top_w + body)) -le "$KVP_N" ] || top_w=$((KVP_N - body))
  [ "$top_w" -ge 0 ] || top_w=0
  for ((k = 0; k < KVP_NV; k++)); do
    if [ "$k" -lt "$top_w" ] || [ "$k" -ge $((top_w + body)) ]; then rows+=(""); continue; fi
    _vr="${_vrec[${KVP_IDX[$k]}]}"
    IFS=$'\x1f' read -ra f <<< "$_vr"
    tag="${f[0]:-}" created="${f[1]:-}" size="${f[2]:-}" arch="${f[3]:-?}" use="${f[4]:-}" flags=",${f[5]:-},"
    mark="" col=""
    if [[ "$flags" == *,star,* ]]; then mark=" ${TH[ok]:-}$C_BLD$UI_S_STAR$TH_RESET"
    elif [[ "$flags" == *,mutable,* ]]; then mark=" ${TH[warn]:-}$UI_S_WARN$TH_RESET"; fi
    if [[ "$flags" == *,foreign,* ]]; then col="${TH[dim]:-}"; fi
    tcell="$col$C_BLD$tag$TH_RESET$mark"
    if [[ "$flags" == *,foreign,* ]]; then acell="${TH[err]:-}$arch $UI_S_ERR$TH_RESET"
    elif [ "$arch" = "?" ]; then acell="${TH[dim]:-}?$TH_RESET"
    else acell="$arch ${TH[ok]:-}$UI_S_CHECK$TH_RESET"; fi
    if [ -n "$use" ]; then ucell="$use"; else ucell="${TH[dim]:-}$txt_unused$TH_RESET"; fi
    if [[ "$flags" == *,star,* ]]; then ucell+="  ${TH[accent]:-}$hint_latest$TH_RESET"; fi
    rows+=("$tcell$KIT_SEP$col$created$TH_RESET$KIT_SEP$col$size$TH_RESET$KIT_SEP$acell$KIT_SEP$ucell")
  done
  if [ "$other" -eq 1 ]; then kit_vpick_text other; rows+=("${TH[accent]:-}$KVP_T$TH_RESET$KIT_SEP$KIT_SEP$KIT_SEP$KIT_SEP"); fi
  if [ "$load" -eq 1 ]; then kit_vpick_text load; rows+=("${TH[accent]:-}$KVP_T$TH_RESET$KIT_SEP$KIT_SEP$KIT_SEP$KIT_SEP"); fi
  # The message line (when the box has room for it).
  local line=""
  kit_vpick_text empty; local empty="$KVP_T"
  kit_table "$w" "$th" cols rows "sel=$sel" "top=$top" "empty=$empty"
  KVP_LINES=("${KTB_LINES[@]}")
  KVP_TOP="$KTB_TOP"
  # (selecting a special row of an empty list: the empty text sits over the rows; fine)
  if [ "$th" -lt "$h" ]; then
    if [ "$typing" -eq 1 ]; then
      kit_vpick_typed "$recs" "$typed"
      local msg=""
      case "$KVP_TYPED_STATE" in
        ok) kit_vpick_text type_ok; msg="$KVP_T" ;;
        warn) kit_vpick_text type_missing; msg="$KVP_T" ;;
        err)
          if [ -n "$KVP_TYPED_ARCH" ]; then kit_vpick_text why_arch "$KVP_TYPED_ARCH" "${sarch:-?}"; msg="$KVP_T"; else kit_vpick_text type_bad; msg="$KVP_T"; fi
          ;;
      esac
      kit_vpick_text type_label
      kit_field_render "$KVP_T" "$typed" "$cur" "$w" focus=1 state="$KVP_TYPED_STATE" ${msg:+"msg=$msg"} label_width=10
      line="$KIT_OUT"
    elif [ -n "$status" ]; then
      kit_state_icon run
      line="$KIT_ICON ${TH[accent]:-}$status$TH_RESET"
    elif [ "$KVP_NV" -eq 0 ]; then
      line="${TH[dim]:-}$empty$TH_RESET"
    elif [ "$KVP_KIND" = version ] && [ "$KVP_OK" -eq 0 ]; then
      kit_state_icon err
      line="$KIT_ICON ${TH[err]:-}$KVP_WHY$TH_RESET"
    elif [ "$KVP_KIND" = version ] && [ "$sel" -eq "$KVP_STAR" ]; then
      kit_vpick_text hint_star
      line="${TH[dim]:-}$KVP_T$TH_RESET"
    elif [ "$KVP_KIND" = version ] && [[ ",$KVP_FLAGS," == *,mutable,* ]]; then
      kit_state_icon warn
      kit_vpick_text hint_mutable
      line="$KIT_ICON ${TH[warn]:-}$KVP_T$TH_RESET"
    elif [ -n "$note" ]; then
      kit_state_icon warn
      line="$KIT_ICON ${TH[warn]:-}$note$TH_RESET"
    fi
    tui_fit "$line" "$w"
    KVP_LINES+=("$TUI_OUT")
  fi
}

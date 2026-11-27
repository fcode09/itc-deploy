#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Screen: Images (view 2). What this Docker has of each service: its versions from the newest to the oldest, with the most recent one you may
# choose starred (★), the tags that move marked (▲), the images that cannot run here marked (✖), who uses each one and, for the one chosen,
# why it can or cannot be used. Enter uses a version in an instance (lib/screens/imguse.sh asks which, shows the change and, on y, deploys it);
# l loads an image archive (lib/screens/imgload.sh; `./deltactl load` runs in the background and the panel keeps working); c copies the
# reference; Space opens the detail; R reads Docker again. The rules (order, star, warnings) are those of lib/core/imagecat.sh, shared with
# `./deltactl images`; the rows are drawn by the kit's version picker (lib/ui/kit/version_picker.sh), one table per image.
#
# The catalog is read in the background (a query to Docker takes a moment) and shown as soon as it arrives; it is read again when the view is
# chosen, after a command ends (a load, a deploy: they change what is loaded and who uses it), every minute while the view is on screen, and
# with R. Nothing here deletes an image.
#
# Keys: Up/Down choose a version (across the images) · Enter use it in an instance · Space detail · l load a file · c copy the reference ·
# R read again.

DASH_IMG_STATE=none      # none (never asked) | loading (first answer pending) | ready | nodocker
DASH_IMG_BUSY=0          # 1 while the catalog is being read (the previous answer stays on screen)
DASH_IMG_N=0             # answers applied, for the frame signature
DASH_IMG_AT=0            # SECONDS of the last request
DASH_IMG_EVERY=60        # seconds between two reads while the view is on screen
DASH_IMG_STALE=0         # 1: a command ended since the last read
DASH_IMG_GEN=0           # counts the commands that ended (dash_img_stale): a read launched before the last one gives an old answer
DASH_IMG_REQ_GEN=0       # DASH_IMG_GEN when the read in flight was launched
DASH_IMG_SEL=0           # the version under the cursor (index into DASH_IMG_ITEMS)
DASH_IMG_OPEN=0          # 1: the detail of the version is open
DASH_IMG_JOB=0           # JOB_SEQ of the load this view started (0: none running)
DASH_IMG_SEEN=0          # JOB_SEQ of the last command seen ending
DASH_IMG_LOADING=""      # the file being loaded, for the status line
DASH_IMG_ITEMS=()        # one per version, in the order they are shown: "<group>|<catalog index>"
DASH_IMG_FIRST=()        # the first item of each group (by group index)
DASH_IMG_TOP=0           # the first line of the list that is shown
DASH_IMG_NOTE=""         # the warning of the group of the version under the cursor (the last line of the detail)

# --- Reading the catalog -------------------------------------------------------------------------------------------------

# Runs in the background: reads Docker and prints the tables of the catalog as `declare -p` lines.
dash_img_dump() {
  if ! ic_load; then echo "DASH_IMG_NODOCKER=1"; return 0; fi
  declare -p IC_N IC_SERVER_ARCH IC_SVC IC_REPO IC_FULL IC_TAG IC_ID IC_ARCH IC_SINCE IC_SIZE IC_EPOCH IC_KIND IC_VNUM IC_VPRE IC_OK IC_STAR IC_USE \
    IC_GROUPS IC_ORDER IC_STARIDX IC_DISC IC_CFG
}

# The versions in the order they are shown, from the groups of the catalog.
dash_img_items() {
  local g i
  DASH_IMG_ITEMS=() DASH_IMG_FIRST=()
  for g in "${!IC_GROUPS[@]}"; do
    DASH_IMG_FIRST[g]="${#DASH_IMG_ITEMS[@]}"
    for i in ${IC_ORDER[${IC_GROUPS[$g]}]:-}; do DASH_IMG_ITEMS+=("${IC_GROUPS[$g]}|$i"); done
  done
}

# Loads the lines of dash_img_dump (only the tables of the catalog) and tells the panel.
dash_img_apply() { # text
  local line nodocker=0 keep="" i it
  # The cursor stays on the same version (image and tag) when the catalog changes; the first time it goes to the most recent one.
  if [ "$DASH_IMG_STATE" = "ready" ] && dash_img_cur; then keep="$DASH_IMG_G|${IC_TAG[$DASH_IMG_CI]}"; fi
  while IFS= read -r line; do
    if [[ "$line" =~ ^declare\ -[-AaFgrx]+\ IC_[A-Z_]+= ]]; then eval "declare -g${line#declare}"
    elif [ "$line" = "DASH_IMG_NODOCKER=1" ]; then nodocker=1; fi
  done <<< "$1"
  if [ "$nodocker" -eq 1 ]; then DASH_IMG_STATE=nodocker; IC_N=0 IC_GROUPS=() DASH_IMG_ITEMS=()
  else DASH_IMG_STATE=ready; dash_img_items; fi
  # The answer clears the mark that the catalog is old only when it was asked for after the last command ended.
  [ "$DASH_IMG_REQ_GEN" -ne "$DASH_IMG_GEN" ] || DASH_IMG_STALE=0
  DASH_IMG_BUSY=0 DASH_IMG_N=$((DASH_IMG_N + 1)) DASH_DIRTY=1
  local found=-1
  for i in "${!DASH_IMG_ITEMS[@]}"; do
    it="${DASH_IMG_ITEMS[$i]}"
    if [ -n "$keep" ]; then
      [ "${it%|*}|${IC_TAG[${it##*|}]}" != "$keep" ] || { found="$i"; break; }
    elif [ "${IC_STAR[${it##*|}]}" -eq 1 ]; then found="$i"; break; fi
  done
  if [ "$found" -ge 0 ]; then DASH_IMG_SEL="$found"; fi
  [ "$DASH_IMG_SEL" -lt "${#DASH_IMG_ITEMS[@]}" ] || DASH_IMG_SEL=$((${#DASH_IMG_ITEMS[@]} - 1))
  [ "$DASH_IMG_SEL" -ge 0 ] || DASH_IMG_SEL=0
}

# A command ended (a load, a deploy, a tag written): what the catalog says may be old.
dash_img_stale() { DASH_IMG_STALE=1 DASH_IMG_GEN=$((DASH_IMG_GEN + 1)); }

# Asks for a read without waiting for it (the synchronous one in the test mode).
dash_img_request() {
  DASH_IMG_AT="$SECONDS"
  if tui_test_mode; then DASH_IMG_REQ_GEN="$DASH_IMG_GEN"; dash_img_apply "$(dash_img_dump)"; return 0; fi
  [ -z "${DASH_AS_PID[images]:-}" ] || return 0
  DASH_IMG_REQ_GEN="$DASH_IMG_GEN"
  [ "$DASH_IMG_STATE" = "ready" ] || DASH_IMG_STATE=loading
  DASH_IMG_BUSY=1 DASH_DIRTY=1
  dash_async images "" dash_img_dump || true
}

# The version under the cursor: DASH_IMG_G (its group, "<sN>|<image>"), DASH_IMG_CI (its index in the catalog tables). 1 when there is none.
DASH_IMG_G="" DASH_IMG_CI=-1
dash_img_cur() {
  local it="${DASH_IMG_ITEMS[$DASH_IMG_SEL]:-}"
  DASH_IMG_G="" DASH_IMG_CI=-1
  [ -n "$it" ] || return 1
  DASH_IMG_G="${it%|*}" DASH_IMG_CI="${it##*|}"
}

# --- Drawing -------------------------------------------------------------------------------------------------------------

# A text with {1} {2} {3} {4} {5} filled in, into DASH_T (cached like dt, so no process).
DASH_T=""
dash_img_t() { # key [a] [b] [c] [d] [e]
  dt "$1"
  DASH_T="${DTV//\{1\}/${2:-}}"
  DASH_T="${DASH_T//\{2\}/${3:-}}"
  DASH_T="${DASH_T//\{3\}/${4:-}}"
  DASH_T="${DASH_T//\{4\}/${5:-}}"
  DASH_T="${DASH_T//\{5\}/${6:-}}"
}

# What is in use of one image, in the lines under its heading (DASH_IMG_CUR): which versions the instances that have the service run, and who
# runs each; and a warning for what does not add up: a configured version that is not loaded (the next deploy would fail or pull it) and a
# service that runs a version other than the configured one (the tag was written and it was not deployed). What runs comes from the state of
# the panel (ST_CIMAGE); a stopped service counts with its configured version and says it is stopped.
DASH_IMG_CUR=()
dash_img_current() { # group width
  local grp="$1" w="$2" svc repo name rec cfg key st img base run shown tag i k found nw=0 maxw=2 line ns
  local -a order=() warns=() has=()
  local -A who=()
  svc="${grp%%|*}" repo="${grp#*|}"
  DASH_IMG_CUR=()
  for i in ${IC_ORDER[$grp]:-}; do has+=("${IC_TAG[$i]}"); done
  for name in "${DASH_NAMES[@]}"; do
    case " ${DASH_SVCS[$name]:-} " in *" $svc "*) ;; *) continue ;; esac
    rec="${IC_CFG[$name/$svc]:-}"
    [ -n "$rec" ] && [ "${rec%%|*}" = "$repo" ] || continue
    cfg="${rec#*|}"; cfg="${cfg%%|*}"
    [ -n "$cfg" ] || continue
    key="$name/$svc" st="${ST_STATE[$key]:-}" img="${ST_CIMAGE[$key]:-}" run=""
    if [ "$st" = running ] && [ -n "$img" ]; then
      case "$img" in sha256:* | *@sha256:*) run="?" ;; *) base="${img##*/}"; if [[ "$base" == *:* ]]; then run="${base#*:}"; else run="latest"; fi ;; esac
    fi
    tag="$cfg" shown="$name"
    if [ -n "$run" ]; then
      tag="$run"
      if [ "$run" != "?" ] && [ "$run" != "$cfg" ]; then dash_img_t tui.img.warn_drift "$name" "$run" "$cfg"; warns+=("warn|$DASH_T"); fi
    else
      dt tui.img.stopped; shown="$name [$DTV]"
    fi
    found=0
    for k in "${has[@]}"; do [ "$k" != "$cfg" ] || found=1; done
    if [ "$found" -eq 0 ]; then dash_img_t tui.img.warn_notloaded "$name" "$cfg"; warns+=("err|$DASH_T"); fi
    if [ -z "${who[$tag]+x}" ]; then order+=("$tag"); who[$tag]="$shown"; else who[$tag]+=", $shown"; fi
  done
  if [ "${#order[@]}" -eq 0 ]; then
    dt tui.img.inuse_none; tui_fit "  ${TH[dim]:-}$DTV$TH_RESET" "$w"; DASH_IMG_CUR+=("$TUI_OUT")
    return 0
  fi
  # The versions the catalog has come first, the newest first; a configured version that is not loaded goes last.
  local -a sorted=()
  for k in "${has[@]}"; do [ -z "${who[$k]+x}" ] || sorted+=("$k"); done
  for tag in "${order[@]}"; do
    found=0
    for k in "${has[@]}"; do [ "$k" != "$tag" ] || found=1; done
    [ "$found" -eq 1 ] || sorted+=("$tag")
  done
  line=""
  ns="${IC_STARIDX[$grp]:--1}"
  for tag in "${sorted[@]}"; do
    [ -z "$line" ] || line+=" $UI_S_DOT "
    if [ "$ns" -ge 0 ] && [ "${IC_TAG[$ns]}" = "$tag" ]; then line+="$UI_S_STAR "; fi
    line+="${TH[accent]:-}$tag$TH_RESET ${TH[dim]:-}(${who[$tag]})$TH_RESET"
  done
  dt tui.img.inuse; tui_fit "  ${TH[dim]:-}$DTV$TH_RESET $line" "$w"; DASH_IMG_CUR+=("$TUI_OUT")
  for line in "${warns[@]}"; do
    nw=$((nw + 1))
    if [ "$nw" -gt "$maxw" ]; then continue; fi
    kit_state_icon "${line%%|*}"
    tui_fit "  $KIT_ICON ${KIT_COL}${line#*|}$TH_RESET" "$w"; DASH_IMG_CUR+=("$TUI_OUT")
  done
  if [ "$nw" -gt "$maxw" ]; then dash_img_t tui.img.warn_more $((nw - maxw)); tui_fit "  ${TH[dim]:-}$DASH_T$TH_RESET" "$w"; DASH_IMG_CUR+=("$TUI_OUT"); fi
}

# The lines of the list ($1 cells wide) into DASH_IMG_FLAT, and for each version the line it is on (DASH_IMG_LINE, by item): a heading per
# image, its table (header and one row per version), the warning when the two orders disagree, and a blank line.
# Nothing in them depends on the cursor, so they are built again only when the answer, the language, the theme or the width change.
DASH_IMG_FLAT=() DASH_IMG_LINE=() DASH_IMG_KEY=""
dash_img_build() { # width
  local w="$1" key g grp svc repo n i k nv tw=8 head left right plain mark ns
  local -a REC=() order=() lines=()
  key="$w|$DASH_IMG_N|$DASH_LANG_N|${UI_UTF8:-0}|$DASH_IMG_STATE|$DASH_REFRESH_N"
  [ "$key" != "$DASH_IMG_KEY" ] || return 0
  DASH_IMG_FLAT=() DASH_IMG_LINE=() DASH_IMG_KEY="$key"
  declare -A TX=()
  ic_picker_texts TX
  # One width for the version column in every table, so the tables of the several images line up.
  for ((i = 0; i < ${#IC_TAG[@]}; i++)); do [ "${#IC_TAG[$i]}" -le $((tw - 4)) ] || tw=$((${#IC_TAG[$i]} + 4)); done
  [ "$tw" -le 22 ] || tw=22
  n=0
  for g in "${!IC_GROUPS[@]}"; do
    grp="${IC_GROUPS[$g]}" svc="${grp%%|*}" repo="${grp#*|}"
    read -ra order <<< "${IC_ORDER[$grp]:-}"
    nv="${#order[@]}"
    ic_picker_rows "$grp" REC
    # The heading: the service and the image at the left; how many versions and which is the star at the right.
    if [ "${UI_UTF8:-0}" -eq 1 ]; then mark="▾"; else mark="v"; fi
    left="${TH[accent]:-}$C_BLD$mark $svc $UI_S_DOT $repo$TH_RESET"
    ns="${IC_STARIDX[$grp]:--1}"
    if [ "$nv" -eq 0 ]; then dt tui.img.group_none; right="$DTV"
    else
      if [ "$nv" -eq 1 ]; then dt tui.img.group_one; right="$DTV"; else dash_img_t tui.img.group_n "$nv"; right="$DASH_T"; fi
      if [ "$ns" -ge 0 ]; then right+=" $UI_S_DOT $UI_S_STAR ${IC_TAG[$ns]}"; fi
    fi
    tui_vlen "$left"; head="$TUI_VL"
    tui_vlen "$right"
    if [ $((head + 2 + TUI_VL)) -le "$w" ]; then printf -v plain '%*s' $((w - head - TUI_VL)) ''; DASH_IMG_FLAT+=("$left$plain${TH[dim]:-}$right$TH_RESET")
    else tui_fit "$left" "$w"; DASH_IMG_FLAT+=("$TUI_OUT"); fi
    dash_img_current "$grp" "$w"
    DASH_IMG_FLAT+=("${DASH_IMG_CUR[@]}")
    if [ "$nv" -eq 0 ]; then
      dt tui.img.none; tui_fit "  ${TH[dim]:-}$DTV$TH_RESET" "$w"; DASH_IMG_FLAT+=("$TUI_OUT" "")
      continue
    fi
    # The table of the image: the picker draws the header and the rows (no message line: the view has its own).
    kit_vpick $((w - 2)) $((nv + 1)) REC sel=0 other=0 load=0 msg=0 tagw="$tw" texts=TX server_arch="$IC_SERVER_ARCH"
    lines=("${KVP_LINES[@]}")
    DASH_IMG_FLAT+=("  ${lines[0]}")
    for ((k = 0; k < nv; k++)); do
      DASH_IMG_LINE[n + k]="${#DASH_IMG_FLAT[@]}"
      plain="${lines[$((k + 1))]#"$TUI_SEL"}"
      DASH_IMG_FLAT+=("  $plain")
    done
    n=$((n + nv))
    ic_note "$grp"
    if [ -n "$IC_NOTE" ]; then
      kit_state_icon warn
      tui_fit "  $KIT_ICON ${TH[warn]:-}$IC_NOTE$TH_RESET" "$w"; DASH_IMG_FLAT+=("$TUI_OUT")
    fi
    DASH_IMG_FLAT+=("")
  done
}

# The line under the list for the version under the cursor, into DASH_IMG_MSG: why it cannot be used, what it is, or what is going on.
DASH_IMG_MSG=""
dash_img_msg() {
  local fl arch
  DASH_IMG_MSG=""
  if [ "$DASH_IMG_STATE" = "nodocker" ]; then kit_state_icon err; dt tui.img.nodocker; DASH_IMG_MSG="$KIT_ICON ${TH[err]:-}$DTV$TH_RESET"; return 0; fi
  if [ "$DASH_IMG_STATE" != "ready" ]; then kit_state_icon run; dt tui.img.loading; DASH_IMG_MSG="$KIT_ICON ${TH[accent]:-}$DTV$TH_RESET"; return 0; fi
  if [ -n "$DASH_IMG_LOADING" ]; then kit_state_icon run; dash_img_t tui.img.loading_file "$DASH_IMG_LOADING"; DASH_IMG_MSG="$KIT_ICON ${TH[accent]:-}$DASH_T$TH_RESET"; return 0; fi
  dash_img_cur || return 0
  fl=","
  [ "${IC_STAR[$DASH_IMG_CI]}" -ne 1 ] || fl+="star,"
  [ "${IC_KIND[$DASH_IMG_CI]}" = ver ] || fl+="mutable,"
  [ "${IC_OK[$DASH_IMG_CI]}" -eq 1 ] || fl+="foreign,"
  if [[ "$fl" == *,foreign,* ]]; then
    arch="${IC_ARCH[$DASH_IMG_CI]}"
    kit_state_icon err; dash_img_t images.pick.why_arch "$arch" "$IC_SERVER_ARCH"
    DASH_IMG_MSG="$KIT_ICON ${TH[err]:-}$DASH_T$TH_RESET"
  elif [[ "$fl" == *,mutable,* ]]; then
    kit_state_icon warn; dt images.pick.hint_mutable; DASH_IMG_MSG="$KIT_ICON ${TH[warn]:-}$DTV$TH_RESET"
  elif [[ "$fl" == *,star,* ]]; then
    dt tui.img.hint_star; DASH_IMG_MSG="${TH[dim]:-}$DTV$TH_RESET"
  else
    dt tui.img.hint_use; DASH_IMG_MSG="${TH[dim]:-}$DTV$TH_RESET"
  fi
}

# The detail of the version under the cursor in 3 lines of $1 cells, into DASH_IMG_DET.
DASH_IMG_DET=()
dash_img_detail() { # width
  local w="$1" ci use cur prev ago="" iso="" id
  DASH_IMG_DET=()
  dash_img_cur || return 0
  ci="$DASH_IMG_CI"
  id="${IC_ID[$ci]#sha256:}"; id="${id:0:12}"
  if ic_ago_text "${IC_EPOCH[$ci]}" "${IC_NOW:-}"; then ago="$IC_AGO_T"; else ago="${IC_SINCE[$ci]}"; fi
  if ic_iso "${IC_EPOCH[$ci]}"; then iso="$IC_S"; else iso="?"; fi
  tui_fit "${TH[accent]:-}$C_BLD${IC_REPO[$ci]}:${IC_TAG[$ci]}$TH_RESET" "$w"; DASH_IMG_DET+=("$TUI_OUT")
  dash_img_t tui.img.d_id "$id" "$iso" "$ago" "${IC_SIZE[$ci]}" "${IC_ARCH[$ci]}"
  tui_fit "${TH[dim]:-}$DASH_T$TH_RESET" "$w"; DASH_IMG_DET+=("$TUI_OUT")
  use="${IC_USE[$ci]% }"
  if [ -z "$use" ]; then dt tui.img.d_unused; use="$DTV"
  else
    t_r images.use_current; cur="$T_OUT"; t_r images.use_previous; prev="$T_OUT"
    use="${use//(current)/($cur)}"; use="${use//(previous)/($prev)}"; use="${use// /, }"
    dash_img_t tui.img.d_used "$use"; use="$DASH_T"
  fi
  tui_fit "$use" "$w"; DASH_IMG_DET+=("$TUI_OUT")
}

scr_images_render() { # width height
  local w="$1" h="$2" inner=$((${2} - 2)) cw=$((${1} - 4)) dl=1 bh top cl i status chips foot
  local -a body=()
  dash_img_build "$cw"
  if [ "$DASH_IMG_OPEN" -eq 1 ] && [ "$DASH_IMG_STATE" = "ready" ] && [ "${#DASH_IMG_ITEMS[@]}" -gt 0 ] && [ "$inner" -ge 8 ]; then dl=4; fi
  bh=$((inner - dl))
  [ "$bh" -ge 1 ] || bh=1
  # The window over the list: it keeps the line of the version under the cursor in view, and shows the heading when it goes back up to the
  # first version of an image.
  top="$DASH_IMG_TOP"
  cl="${DASH_IMG_LINE[$DASH_IMG_SEL]:-0}"
  if [ "$cl" -lt $((top + 2)) ]; then top=$((cl - 2)); fi
  if [ "$cl" -ge $((top + bh)) ]; then top=$((cl - bh + 1)); fi
  [ $((top + bh)) -le "${#DASH_IMG_FLAT[@]}" ] || top=$((${#DASH_IMG_FLAT[@]} - bh))
  [ "$top" -ge 0 ] || top=0
  DASH_IMG_TOP="$top"
  for ((i = top; i < top + bh && i < ${#DASH_IMG_FLAT[@]}; i++)); do
    if [ "$DASH_IMG_STATE" = "ready" ] && [ "$i" -eq "$cl" ] && [ "${#DASH_IMG_ITEMS[@]}" -gt 0 ]; then body+=("$TUI_SEL${DASH_IMG_FLAT[$i]}"); else body+=("${DASH_IMG_FLAT[$i]}"); fi
  done
  while [ "${#body[@]}" -lt "$bh" ]; do body+=(""); done
  if [ "$dl" -eq 4 ]; then
    dash_img_detail "$cw"
    body+=("${DASH_IMG_DET[@]}")
    while [ "${#body[@]}" -lt "$inner" ]; do body+=(""); done
    dash_img_note_line "$cw"
    [ -z "$DASH_IMG_NOTE" ] || body[inner - 1]="$DASH_IMG_NOTE"
  else
    dash_img_msg
    tui_fit "$DASH_IMG_MSG" "$cw"
    body+=("$TUI_OUT")
  fi
  # The box: the title, how many versions the server has and its architecture, and the keys of the view in the border.
  dt tui.img.title; chips="2:$DTV"
  if [ "$DASH_IMG_STATE" = "ready" ]; then
    dash_img_t tui.img.status "$IC_SERVER_ARCH" "${#DASH_IMG_ITEMS[@]}"; status="$DASH_T"
    if [ "$DASH_IMG_BUSY" -eq 1 ]; then status+=" $UI_S_DOT $UI_S_RUN"; fi
  elif [ "$DASH_IMG_STATE" = "nodocker" ]; then dt tui.img.status_nodocker; status="$DTV"
  else dt tui.img.status_loading; status="$DTV"; fi
  dt tui.img.foot; foot="$DTV"
  kit_box "$w" "$h" body "chips=$chips" "status=$status" "footer=$foot" focus=1
  TUI_FRAME+=("${KIT_BOX[@]}")
}

# The warning of the group of the version under the cursor, when the two orders disagree, for the last line of the detail (DASH_IMG_NOTE).
dash_img_note_line() { # width
  DASH_IMG_NOTE=""
  dash_img_cur || return 0
  ic_note "$DASH_IMG_G"
  [ -z "$IC_NOTE" ] || { kit_state_icon warn; tui_fit "$KIT_ICON ${TH[warn]:-}$IC_NOTE$TH_RESET" "$1"; DASH_IMG_NOTE="$TUI_OUT"; }
}

# --- Keys ------------------------------------------------------------------------------------------------------------

# `c`: puts the reference (image:tag) of the version under the cursor in the clipboard.
dash_img_copy() {
  local ref
  dash_img_cur || return 0
  ref="${IC_REPO[$DASH_IMG_CI]}:${IC_TAG[$DASH_IMG_CI]}"
  if dash_srv_copy "$ref"; then
    if [ "$DASH_SRV_COPIED" = "term" ]; then dash_msg ok "$(t tui.img.copied_term "$ref")"; else dash_msg ok "$(t tui.img.copied "$ref")"; fi
  else
    dash_msg warn "$(t tui.img.copy_none "$ref")"
  fi
}

# b: remove the version under the cursor. Only one nobody uses (ic_removable says why not otherwise); it asks first and runs `images rm` as a command
# like any other (in the background, in Output, cancellable). The containers are read now, when the key is pressed, never while drawing.
dash_img_rm() {
  local svc tag extra=""
  dash_img_cur || { dash_msg info "$(t tui.img.nothing)"; return 0; }
  if job_running; then dash_msg warn "$(t tui.msg.busy)"; return 0; fi
  svc="${DASH_IMG_G%%|*}" tag="${IC_TAG[$DASH_IMG_CI]}"
  ic_containers_load
  ic_removable "$DASH_IMG_CI"
  if [ "$IC_RM_WHY" != ok ]; then dash_msg warn "$(ic_why_text "$DASH_IMG_CI")"; return 0; fi
  [ "$IC_RM_SHARED" -eq 0 ] || extra+=" $(t images.rm.shared)."
  [ "${IC_STAR[$DASH_IMG_CI]}" -ne 1 ] || extra+=" $(t tui.img.rm.newest "$svc")"
  dash_confirm "$(t tui.img.rm.confirm "$svc" "$tag" "${IC_SIZE[$DASH_IMG_CI]}")$extra" stay images rm "$svc:$tag" --yes
}

# B: remove every version of the service of the cursor that is left over (not in use, not the previous one of an instance, not used by a container,
# not the most recent). It says which ones and how much space it frees before asking.
dash_img_prune() {
  local svc i tags="" n
  dash_img_cur || { dash_msg info "$(t tui.img.nothing)"; return 0; }
  if job_running; then dash_msg warn "$(t tui.msg.busy)"; return 0; fi
  svc="${DASH_IMG_G%%|*}"
  ic_containers_load
  ic_prune_plan "$svc" 0
  n="${#IC_PLAN[@]}"
  if [ "$n" -eq 0 ]; then dash_msg info "$(t tui.img.prune.none "$svc")"; return 0; fi
  for i in "${IC_PLAN[@]}"; do tags+="${tags:+, }${IC_TAG[$i]}"; done
  ic_frees_bytes "${IC_PLAN[@]}"
  ic_fmt_bytes "$IC_FREES"
  dash_confirm "$(t tui.img.prune.confirm "$n" "$svc" "$tags" "$IC_BYTES_H")" stay images prune "$svc" --yes
}

scr_images_key() { # key
  local n="${#DASH_IMG_ITEMS[@]}"
  case "$1" in
    up | k) [ "$DASH_IMG_SEL" -le 0 ] || DASH_IMG_SEL=$((DASH_IMG_SEL - 1)) ;;
    down | j) [ "$DASH_IMG_SEL" -ge $((n - 1)) ] || DASH_IMG_SEL=$((DASH_IMG_SEL + 1)) ;;
    pgup) DASH_IMG_SEL=$((DASH_IMG_SEL - 5)); [ "$DASH_IMG_SEL" -ge 0 ] || DASH_IMG_SEL=0 ;;
    pgdn) DASH_IMG_SEL=$((DASH_IMG_SEL + 5)); [ "$DASH_IMG_SEL" -lt "$n" ] || DASH_IMG_SEL=$((n - 1)); [ "$DASH_IMG_SEL" -ge 0 ] || DASH_IMG_SEL=0 ;;
    home) DASH_IMG_SEL=0 ;;
    end) DASH_IMG_SEL=$((n - 1)); [ "$DASH_IMG_SEL" -ge 0 ] || DASH_IMG_SEL=0 ;;
    enter) dash_img_use ;;
    space) DASH_IMG_OPEN=$((1 - DASH_IMG_OPEN)) ;;
    l) dash_img_load_ask ;;
    c) dash_img_copy ;;
    b) dash_img_rm ;;
    B) dash_img_prune ;;
    R) dash_img_request; dash_msg info "$(t tui.img.refreshing)" ;;
  esac
}

scr_images_keys() { dash_keys_view images "$1"; } # width
scr_images_texts() { DASH_KEYS[images]="$(t tui.keys.images "$DASH_UD")"; }
# (what runs changes with the state of Docker, which only matters while this view is the one drawn: every screen adds its part to the signature of
# every view, and a part that moved with each refresh would rebuild the bodies of the views that are not live)
scr_images_sig() { local r=""; [ "$DASH_VIEW" != images ] || r="$DASH_REFRESH_N"; DASH_SIG+="|$DASH_IMG_SEL|$DASH_IMG_OPEN|$DASH_IMG_STATE|$DASH_IMG_BUSY|$DASH_IMG_N|$DASH_IMG_LOADING|$r"; }

# Esc: first the detail; else leave the view.
scr_images_back() {
  if [ "$DASH_IMG_OPEN" -eq 1 ]; then DASH_IMG_OPEN=0; return 0; fi
  return 1
}

# When the view is chosen the catalog is read (again if it is not recent), once the view has stayed (see dash_dwelled): the tick does it.
DASH_IMG_WANT=0
scr_images_enter() { DASH_IMG_WANT=1; }

# Every turn of the loop, whatever the view: the answer of the read, and a command that ended (a load or a deploy changes what is loaded
# and who uses it).
scr_images_tick() {
  if dash_async_take images; then
    dash_img_apply "$DASH_AS_TEXT"
  elif [ "$DASH_IMG_BUSY" -eq 1 ] && [ -z "${DASH_AS_PID[images]:-}" ]; then
    # The read died or was cut after a minute: free the view (R and the periodic read ask again). Without an answer yet it says Docker does not
    # answer instead of staying on "reading…"; with one, the previous answer stays on screen.
    DASH_IMG_BUSY=0 DASH_DIRTY=1
    [ "$DASH_IMG_STATE" != "loading" ] || DASH_IMG_STATE=nodocker
  fi
  if [ -n "$JOB_RC" ] && [ "$JOB_SEQ" -ne "$DASH_IMG_SEEN" ]; then
    DASH_IMG_SEEN="$JOB_SEQ"; dash_img_stale
    if [ "$DASH_IMG_JOB" -eq "$JOB_SEQ" ]; then DASH_IMG_JOB=0 DASH_IMG_LOADING="" DASH_DIRTY=1; fi
  fi
  if [ "$DASH_VIEW" != "images" ]; then DASH_IMG_WANT=0
  elif [ "$DASH_IMG_WANT" -eq 1 ] && dash_dwelled; then
    DASH_IMG_WANT=0
    if [ "$DASH_IMG_STATE" = "none" ] || [ "$DASH_IMG_STALE" -eq 1 ] || [ $((SECONDS - DASH_IMG_AT)) -ge 5 ]; then dash_img_request; fi
  fi
  [ "$DASH_VIEW" != "images" ] || [ "$DASH_IMG_STALE" -eq 0 ] || [ "$DASH_IMG_STATE" = "none" ] || dash_img_request
}

# Only while the view is current and the panel runs: the catalog is read again every DASH_IMG_EVERY seconds.
scr_images_poll() {
  tui_test_mode && return 0
  if [ "$DASH_IMG_BUSY" -eq 0 ] && [ $((SECONDS - DASH_IMG_AT)) -ge "$DASH_IMG_EVERY" ]; then dash_img_request; fi
}

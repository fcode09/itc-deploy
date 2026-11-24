#!/usr/bin/env bash
# shellcheck disable=SC2034  # the OUT_* results are read by lib/ui/outsummary.sh, the panel views and the tests
# The interpreter of what a command printed: the commands that already print with a shape (`new`, `check`, `deploy`, `init`, `doctor`, `images`,
# `env`, `rollback`, `adopt`) are read back into rows a view can draw as a summary (a headline, sections, items with a state, steps, numbered
# next steps, a verdict), while the raw text stays untouched somewhere else. It never changes what the commands print.
#
#   out_parse <lines-array-name> <command-line> [running=0|1] [rc]   -> 0 when the output was recognised (OUT_OK=1), else 1
#
# Results (all plain text, no colour; nothing is added that the command did not print):
#   OUT_KIND        new | check | deploy | init | doctor | images | env | rollback | adopt  ("" for any other command)
#   OUT_TITLE       the heading the command underlines ("Check of 'x'"), if any
#   OUT_HEAD_STATE  ok | err | "" and OUT_HEAD_TEXT   the line that starts with the OK / ERROR label (the result of the command)
#   OUT_VER_STATE   ok | warn | err | info | "" and OUT_VER_TEXT   the closing verdict of check / doctor ("2 error(es), 0 aviso(s): ...")
#   OUT_CNT_OK / _WARN / _ERR / _INFO   how many items there are of each state
#   OUT_IGNORED     the non-blank lines that are in no row (docker's own progress, ...): the view says it and offers the raw text
#   OUT_R_TYPE[i]   sec | item | kv | step | num | note | hint
#   OUT_R_STATE[i]  ok | warn | err | info | pend | run | "" (items and steps)
#   OUT_R_TEXT[i]   the row's text (a section's title, an item's title, a key, a step, a note)
#   OUT_R_DETAIL[i] what the item says on the same line (after two spaces), the value of a key, the number of a numbered step
#   OUT_R_TAG[i]    a right-hand tag of a table row (the state of a variable, what an image is used by)
#   OUT_R_SUB[i]    the indented lines under an item, joined with newlines
#   OUT_R_PB[i]     1 when a blank line came before the row
#
# What is recognised is decided by the SHAPE and by the i18n catalog, never by loose text: the marker of a line (● ▲ ✖ ℹ → in the rich mode,
# * ! x i -> in plain), the label of OK / AVISO / ERROR (keys label.*), the titles and steps of the commands (keys new.*, deploy.*, init.*) and the
# words of a table (keys env.state.*, images.use_*), always in both languages: what a command printed stays readable after the panel changes
# its language. Anything that is not recognised is not an error: OUT_OK stays 0 and the view shows the raw text.
# Pure Bash, no fork. The cost is one pass over the lines; the caller keeps the result until the output changes (lib/ui/outsummary.sh).

OUT_KIND="" OUT_TITLE="" OUT_OK=0
OUT_HEAD_STATE="" OUT_HEAD_TEXT="" OUT_VER_STATE="" OUT_VER_TEXT=""
OUT_CNT_OK=0 OUT_CNT_WARN=0 OUT_CNT_ERR=0 OUT_CNT_INFO=0 OUT_IGNORED=0
OUT_R_TYPE=() OUT_R_STATE=() OUT_R_TEXT=() OUT_R_DETAIL=() OUT_R_TAG=() OUT_R_SUB=() OUT_R_PB=()

OUT_MAX_LINES=700            # the lines read: the first 200 and the last 500 when there are more (a deploy prints thousands of docker lines)
OUT_READY=0
OUT_LBL_OK=() OUT_LBL_WARN=() OUT_LBL_ERR=()
OUT_STEP_PATS=()             # globs of the lines that open a phase of deploy / init, both languages
OUT_SEC_PATS=()              # globs of the section titles of `new`
OUT_USE_CUR=() OUT_USE_PREV=() OUT_USE_NONE=()
declare -gA OUT_STATEMAP=()  # the words of the state column of `env` -> ok | warn | err | info | pend
OUT_G=""

# The glob of an i18n template: {1}..{9} become *, the glob characters of the text are escaped.
out_glob() { # template -> OUT_G
  local t="$1" i c
  OUT_G=""
  for ((i = 0; i < ${#t}; i++)); do
    c="${t:i:1}"
    case "$c" in
      \\ | '*' | '?' | '[') OUT_G+="\\$c" ;;
      '{') if [[ "${t:i:3}" =~ ^\{[1-9]\}$ ]]; then OUT_G+='*'; i=$((i + 2)); else OUT_G+='{'; fi ;;
      *) OUT_G+="$c" ;;
    esac
  done
}

# Reads the catalogs of both languages once. (The language that is not the active one is loaded on demand; the active one and Spanish are always there.)
out_init() {
  [ "$OUT_READY" -eq 0 ] || return 0
  local l key v
  [ -n "${MSG_en[label.ok]+x}" ] || { declare -F i18n_load_lang > /dev/null && i18n_load_lang en 2> /dev/null || true; }
  for l in es en; do
    local -n _cat="MSG_$l"
    [ -z "${_cat[label.ok]+x}" ] || OUT_LBL_OK+=("${_cat[label.ok]}")
    [ -z "${_cat[label.warn]+x}" ] || OUT_LBL_WARN+=("${_cat[label.warn]}")
    [ -z "${_cat[label.error]+x}" ] || OUT_LBL_ERR+=("${_cat[label.error]}")
    for key in deploy.validating deploy.local_images deploy.pulling deploy.starting init.checking_empty init.will_seed init.step1 init.step2 init.step3 init.step4; do
      [ -z "${_cat[$key]+x}" ] || { out_glob "${_cat[$key]}"; OUT_STEP_PATS+=("$OUT_G"); }
    done
    for key in new.pending_title new.next_title; do
      [ -z "${_cat[$key]+x}" ] || { out_glob "${_cat[$key]}"; OUT_SEC_PATS+=("$OUT_G"); }
    done
    [ -z "${_cat[images.use_current]+x}" ] || OUT_USE_CUR+=("${_cat[images.use_current]}")
    [ -z "${_cat[images.use_previous]+x}" ] || OUT_USE_PREV+=("${_cat[images.use_previous]}")
    [ -z "${_cat[images.unused]+x}" ] || OUT_USE_NONE+=("${_cat[images.unused]}")
    for key in ok:ok warn:warn missing:err invalid:err example:warn default:info unset:pend extra:info fixed:pend; do
      v="${_cat[env.state.${key%%:*}]-}"
      [ -z "$v" ] || OUT_STATEMAP["$v"]="${key##*:}"
    done
    unset -n _cat
  done
  OUT_READY=1
}

out_reset() {
  OUT_KIND="" OUT_TITLE="" OUT_OK=0
  OUT_HEAD_STATE="" OUT_HEAD_TEXT="" OUT_VER_STATE="" OUT_VER_TEXT=""
  OUT_CNT_OK=0 OUT_CNT_WARN=0 OUT_CNT_ERR=0 OUT_CNT_INFO=0 OUT_IGNORED=0
  OUT_R_TYPE=() OUT_R_STATE=() OUT_R_TEXT=() OUT_R_DETAIL=() OUT_R_TAG=() OUT_R_SUB=() OUT_R_PB=()
}

# One row appended: type state text [detail] [tag] [blank-before]
out_row() {
  OUT_R_TYPE+=("$1") OUT_R_STATE+=("$2") OUT_R_TEXT+=("$3") OUT_R_DETAIL+=("${4-}") OUT_R_TAG+=("${5-}") OUT_R_SUB+=("") OUT_R_PB+=("${6:-0}")
}

# The kind of command: the first word of the command line, without "./deltactl".
out_kind_of() { # command-line -> OUT_KIND
  local w="$1"
  w="${w#./deltactl }"; w="${w#deltactl }"; w="${w#bash ./deltactl }"
  w="${w%% *}"
  case "$w" in
    new | check | deploy | init | doctor | images | env | rollback | adopt) OUT_KIND="$w" ;;
    *) OUT_KIND="" ;;
  esac
}

# A line without colour sequences, carriage returns and trailing blanks, into OUT_L.
OUT_L=""
out_clean() { # line
  local l="$1"
  l="${l%$'\r'}"
  if [[ "$l" == *$'\e'* ]]; then
    while [[ "$l" =~ $'\e'\[[0-9\;?]*[A-Za-z] ]]; do l="${l/"${BASH_REMATCH[0]}"/}"; done
  fi
  while [[ "$l" == *" " ]]; do l="${l% }"; done
  OUT_L="$l"
}

# Marker of a line (indented by two or more): sets OUT_M_STATE (ok warn err info hint), OUT_M_INDENT and OUT_M_TEXT. Returns 1 when there is none.
OUT_M_STATE="" OUT_M_INDENT=0 OUT_M_TEXT=""
out_marker() { # line
  local l="$1" rest tok
  rest="${l#"${l%%[! ]*}"}"
  OUT_M_INDENT=$((${#l} - ${#rest}))
  [ "$OUT_M_INDENT" -ge 2 ] || return 1
  tok="${rest%% *}"
  [ "$tok" != "$rest" ] || return 1
  case "$tok" in
    '●' | '*') OUT_M_STATE=ok ;;
    '▲' | '!') OUT_M_STATE=warn ;;
    '✖' | 'x') OUT_M_STATE=err ;;
    'ℹ' | 'i') OUT_M_STATE=info ;;
    '→' | '->') OUT_M_STATE=hint ;;
    *) return 1 ;;
  esac
  rest="${rest#"$tok"}"
  OUT_M_TEXT="${rest#"${rest%%[! ]*}"}"
  return 0
}

# "title  detail": the text split at the first run of two spaces into OUT_SP_A and OUT_SP_B (OUT_SP_B empty without one).
OUT_SP_A="" OUT_SP_B=""
out_split2() { # text
  local t="$1"
  if [[ "$t" == *"  "* ]]; then
    OUT_SP_A="${t%%"  "*}"
    OUT_SP_B="${t#*"  "}"
    OUT_SP_B="${OUT_SP_B#"${OUT_SP_B%%[! ]*}"}"
  else
    OUT_SP_A="$t" OUT_SP_B=""
  fi
}

# A table header: indent 0, three or more columns separated by two spaces, all capitals. Sets OUT_TBL_POS (the start of each column) and OUT_TBL_N.
OUT_TBL_POS=() OUT_TBL_N=0
out_table_header() { # line
  local l="$1" i c prev_sp=1 n=0 word=""
  local -a pos=() words=()
  [[ "$l" != " "* ]] || return 1
  [[ "$l" == *"  "* ]] || return 1
  # (a header has no lowercase letter and no digit: most lines say so at once, before the character loop)
  [[ "$l" != *[[:lower:]]* && "$l" != *[[:digit:]]* ]] || return 1
  for ((i = 0; i <= ${#l}; i++)); do
    c="${l:i:1}"
    if [ -z "$c" ] || [ "$c" = " " ]; then
      if [ -n "$word" ]; then
        # a word followed by a single space is part of the same column ("USADA POR"): only two spaces end a column
        if [ "${l:i:2}" = "  " ] || [ -z "$c" ]; then words[n]="$word"; n=$((n + 1)); word=""; else word+=" "; fi
      fi
      prev_sp=1
    else
      if [ -z "$word" ] && [ "$prev_sp" -eq 1 ]; then pos[n]="$i"; fi
      word+="$c"; prev_sp=0
    fi
  done
  [ "$n" -ge 3 ] || return 1
  for ((i = 0; i < n; i++)); do
    [[ "${words[i]}" != *[[:lower:]]* ]] || return 1
    [[ "${words[i]}" != *[[:digit:]]* ]] || return 1
  done
  OUT_TBL_POS=("${pos[@]}") OUT_TBL_N="$n"
  return 0
}

# The columns of a table row into OUT_COL[0..n-1], trimmed.
OUT_COL=()
out_table_row() { # line
  local l="$1" i from to s
  OUT_COL=()
  for ((i = 0; i < OUT_TBL_N; i++)); do
    from="${OUT_TBL_POS[i]}"
    if [ $((i + 1)) -lt "$OUT_TBL_N" ]; then to=$((OUT_TBL_POS[i + 1] - from)); s="${l:from:to}"; else s="${l:from}"; fi
    s="${s#"${s%%[! ]*}"}"; s="${s%"${s##*[! ]}"}"
    OUT_COL[i]="$s"
  done
}

# Is the line one of the glob patterns of the array?  out_match_any <line> <array-name>
out_match_any() {
  local line="$1" g
  local -n _pats="$2"
  for g in "${_pats[@]}"; do
    # shellcheck disable=SC2053  # the pattern is meant to be a glob
    [[ "$line" == $g ]] && return 0
  done
  return 1
}

# Does the column text contain one of the words of the array?
out_has_word() { # text array-name
  local t="$1" w
  local -n _ws="$2"
  for w in "${_ws[@]}"; do [[ "$t" == *"$w"* ]] && return 0; done
  return 1
}

out_parse() { # lines-array command-line [running] [rc]
  local -n _src="$1"
  local cmd="$2" running="${3:-0}" rc="${4-}"
  local total="${#_src[@]}" i j n k line next lbl st tag
  local -a OUT_LN=()
  out_reset
  out_init
  out_kind_of "$cmd"
  [ -n "$OUT_KIND" ] || return 1
  [ "$total" -gt 0 ] || return 1
  # The lines to read, clean. deploy, init and rollback print their phases first and their result last, with docker's progress in between (thousands
  # of lines): of those only the first and the last ones are read.
  local fast=0 head=200 tail=500 cap="$OUT_MAX_LINES"
  case "$OUT_KIND" in deploy | init | rollback) fast=1 head=150 tail=150 cap=300 ;; esac
  if [ "$total" -le "$cap" ]; then
    for ((i = 0; i < total; i++)); do out_clean "${_src[i]}"; OUT_LN+=("$OUT_L"); done
  else
    for ((i = 0; i < head; i++)); do out_clean "${_src[i]}"; OUT_LN+=("$OUT_L"); done
    for ((i = total - tail; i < total; i++)); do out_clean "${_src[i]}"; OUT_LN+=("$OUT_L"); done
  fi
  n="${#OUT_LN[@]}"

  local blank=0 last_item=-1 chain=0 in_table=0 sect="" indent text rest rr
  for ((i = 0; i < n; i++)); do
    line="${OUT_LN[i]}"
    if [ -z "${line//[[:space:]]/}" ]; then blank=1; chain=0; in_table=0; continue; fi
    rest="${line#"${line%%[! ]*}"}"; indent=$((${#line} - ${#rest}))

    # --- a table row -------------------------------------------------------------------------------------------------------------
    if [ "$in_table" -eq 1 ] && [ "$indent" -eq 0 ]; then
      out_table_row "$line"
      case "$OUT_KIND" in
        env)
          # ARCHIVO VARIABLE VALOR ESTADO: a section per file, an item per variable
          if [ "${OUT_COL[0]}" != "$sect" ] && [ -n "${OUT_COL[0]}" ]; then sect="${OUT_COL[0]}"; out_row sec "" "$sect" "" "" "$blank"; fi
          st="${OUT_STATEMAP[${OUT_COL[3]:-}]:-info}"
          out_row item "$st" "${OUT_COL[1]:-}" "${OUT_COL[2]:-}" "${OUT_COL[3]:-}" 0
          ;;
        images)
          # TAG ID ARCH CREATED SIZE USED_BY (the table of `images`, in either language)
          tag="${OUT_COL[0]:-}"; st=""
          case "$tag" in
            '★'" "* | '*'" "*) st=ok; tag="${tag#* }" ;;
            '▲'" "* | '!'" "*) st=warn; tag="${tag#* }" ;;
            '✖'" "* | 'x'" "*) st=err; tag="${tag#* }" ;;
          esac
          if [ -z "$st" ]; then
            if out_has_word "${OUT_COL[$((OUT_TBL_N - 1))]:-}" OUT_USE_CUR; then st=ok
            elif out_has_word "${OUT_COL[$((OUT_TBL_N - 1))]:-}" OUT_USE_PREV; then st=info
            elif out_has_word "${OUT_COL[$((OUT_TBL_N - 1))]:-}" OUT_USE_NONE; then st=pend
            else st=info; fi
          fi
          text="${OUT_COL[1]:-}"
          for ((k = 2; k < OUT_TBL_N - 1; k++)); do [ -z "${OUT_COL[k]:-}" ] || text+=" · ${OUT_COL[k]}"; done
          # (what the version is used by is long: it goes under the row, not in a tag column)
          out_row item "$st" "$tag" "$text" "" 0
          OUT_R_SUB[${#OUT_R_SUB[@]} - 1]="${OUT_COL[$((OUT_TBL_N - 1))]:-}"
          ;;
        *)
          text=""
          for ((k = 1; k < OUT_TBL_N; k++)); do [ -z "${OUT_COL[k]:-}" ] || text+="${text:+ · }${OUT_COL[k]}"; done
          out_row item info "${OUT_COL[0]:-}" "$text" "" 0
          ;;
      esac
      last_item=-1; chain=0; blank=0
      continue
    fi
    in_table=0

    # --- OK / AVISO / ERROR: the result of the command ---------------------------------------------------------------------------------
    if [ "$indent" -eq 0 ]; then
      st=""
      for lbl in "${OUT_LBL_ERR[@]}"; do [[ "$line" == "$lbl "* ]] && { st=err; text="${line#"$lbl "}"; break; }; done
      if [ -z "$st" ]; then for lbl in "${OUT_LBL_OK[@]}"; do [[ "$line" == "$lbl "* ]] && { st=ok; text="${line#"$lbl "}"; break; }; done; fi
      if [ -z "$st" ]; then for lbl in "${OUT_LBL_WARN[@]}"; do [[ "$line" == "$lbl "* ]] && { st=warn; text="${line#"$lbl "}"; break; }; done; fi
      if [ -n "$st" ]; then
        text="${text#"${text%%[! ]*}"}"
        if [ "$st" != warn ] && { [ -z "$OUT_HEAD_STATE" ] || { [ "$st" = err ] && [ "$OUT_HEAD_STATE" = ok ]; }; }; then
          OUT_HEAD_STATE="$st" OUT_HEAD_TEXT="$text"
        else
          out_row item "$st" "$text" "" "" "$blank"
          last_item=$((${#OUT_R_TYPE[@]} - 1)); chain=1
        fi
        blank=0
        continue
      fi
    fi

    # --- a marker line: an item (or the arrow of a hint) --------------------------------------------------------------------------------
    if out_marker "$line"; then
      if [ "$OUT_M_STATE" = hint ]; then
        out_row hint "" "$OUT_M_TEXT" "" "" "$blank"
        last_item=-1; chain=0
      else
        out_split2 "$OUT_M_TEXT"
        out_row item "$OUT_M_STATE" "$OUT_SP_A" "$OUT_SP_B" "" "$blank"
        last_item=$((${#OUT_R_TYPE[@]} - 1)); chain=1
      fi
      blank=0
      continue
    fi

    # --- a numbered step ("  1. Completa ...") ---------------------------------------------------------------------------------------
    if [ "$indent" -ge 2 ] && [[ "$rest" =~ ^([0-9]+)\.\ +(.+)$ ]]; then
      out_row num "" "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}" "" "$blank"
      last_item=$((${#OUT_R_TYPE[@]} - 1)); chain=1; blank=0
      continue
    fi

    # --- the lines under an item ----------------------------------------------------------------------------------------------------------
    if [ "$indent" -ge 4 ] && [ "$chain" -eq 1 ] && [ "$last_item" -ge 0 ]; then
      if [ -n "${OUT_R_SUB[last_item]}" ]; then OUT_R_SUB[last_item]+=$'\n'; fi
      OUT_R_SUB[last_item]+="$rest"
      blank=0
      continue
    fi

    # --- a phase of deploy / init ----------------------------------------------------------------------------------------------------------
    # These commands print docker's own progress between their phases, by the hundred: a line that is not a phase, a result or a marker is not
    # looked at any further (it is counted as not summarised and the raw view has it).
    if [ "$fast" -eq 1 ]; then
      if [ "$indent" -le 2 ] && out_match_any "$rest" OUT_STEP_PATS; then
        out_row step ok "$rest" "" "" "$blank"
        last_item=-1; chain=0
      else
        OUT_IGNORED=$((OUT_IGNORED + 1))
      fi
      blank=0
      continue
    fi

    # --- the underlined heading ------------------------------------------------------------------------------------------------------
    if [ "$indent" -eq 0 ] && [ -z "$OUT_TITLE" ] && [ $((i + 1)) -lt "$n" ]; then
      next="${OUT_LN[i + 1]}"
      if [ "${#next}" -ge 3 ]; then
        rr="${next//─/}"; rr="${rr//-/}"
        if [ -z "${rr// /}" ]; then OUT_TITLE="$line"; i=$((i + 1)); blank=0; chain=0; continue; fi
      fi
    fi
    # a rule that is not under a title is only decoration
    if [ "${#line}" -ge 3 ]; then rr="${line//─/}"; rr="${rr//-/}"; if [ -z "${rr// /}" ]; then continue; fi; fi

    # --- a section title of `new` -----------------------------------------------------------------------------------------------------------
    if [ "$indent" -eq 0 ] && out_match_any "$line" OUT_SEC_PATS; then
      text="${line%:}"
      out_row sec "" "$text" "" "" "$blank"
      last_item=-1; chain=0; blank=0
      continue
    fi

    # --- the header of a table, and the title of what comes before it ------------------------------------------------------------------
    if [ "$indent" -eq 0 ] && out_table_header "$line"; then
      in_table=1; blank=0; chain=0; last_item=-1; sect=""
      continue
    fi

    # --- "key    value" (indented, no marker) ------------------------------------------------------------------------------------------------
    if [ "$indent" -ge 2 ] && [[ "$rest" == *"  "* ]]; then
      out_split2 "$rest"
      out_row kv "" "$OUT_SP_A" "$OUT_SP_B" "" "$blank"
      last_item=-1; chain=0; blank=0
      continue
    fi

    # --- a section title (a line at the margin followed by indented lines, or by a table) / a note. deploy, init and rollback also print docker's
    # own progress at the margin: that is not shown here (it counts as not summarised; the raw view has it). ------------------------------------------
    if [ "$indent" -eq 0 ] && [ "$OUT_KIND" != deploy ] && [ "$OUT_KIND" != init ] && [ "$OUT_KIND" != rollback ]; then
      next=""; for ((j = i + 1; j < n; j++)); do [ -n "${OUT_LN[j]//[[:space:]]/}" ] && { next="${OUT_LN[j]}"; break; }; done
      # (the lines under a title are items, keys or a table: the arrow of a hint under a note does not make it a title)
      if [ -n "$next" ] && { { out_marker "$next" && [ "$OUT_M_STATE" != hint ]; } || out_table_header "$next"; }; then
        out_row sec "" "${line%:}" "" "" "$blank"
        last_item=-1; chain=0; blank=0
        continue
      fi
      out_row note "" "$line" "" "" "$blank"
      last_item=-1; chain=0; blank=0
      continue
    fi

    OUT_IGNORED=$((OUT_IGNORED + 1))
    blank=0
  done

  # Lines that were skipped are counted from what is not in the rows: the raw ones (docker's progress, ...) of the lines that were read.
  # (done inline above; the lines that were not read because there were too many are added here)
  [ "$total" -le "$cap" ] || OUT_IGNORED=$((OUT_IGNORED + total - cap))

  # The closing verdict of check / doctor: the last item that came after a blank line, with nothing but hints after it.
  case "$OUT_KIND" in
    check | doctor)
      for ((i = ${#OUT_R_TYPE[@]} - 1; i >= 0; i--)); do
        [ "${OUT_R_TYPE[i]}" != hint ] || continue
        if [ "${OUT_R_TYPE[i]}" = item ] && [ "${OUT_R_PB[i]}" = 1 ]; then
          OUT_VER_STATE="${OUT_R_STATE[i]}" OUT_VER_TEXT="${OUT_R_TEXT[i]}${OUT_R_DETAIL[i]:+  ${OUT_R_DETAIL[i]}}"
          OUT_R_TYPE[i]=gone
        fi
        break
      done
      ;;
  esac

  # The phases of deploy / init: every one is done but the last, which is running, failed or done depending on how the command is.
  local last_step=-1 steps=0
  for ((i = 0; i < ${#OUT_R_TYPE[@]}; i++)); do [ "${OUT_R_TYPE[i]}" = step ] && { last_step="$i"; steps=$((steps + 1)); }; done
  if [ "$last_step" -ge 0 ]; then
    if [ "$running" -eq 1 ]; then OUT_R_STATE[last_step]=run
    elif [ "$OUT_HEAD_STATE" = err ]; then OUT_R_STATE[last_step]=err
    elif [ "$OUT_HEAD_STATE" != ok ] && [ -n "$rc" ] && [ "$rc" != 0 ]; then OUT_R_STATE[last_step]=err
    fi
  fi

  for ((i = 0; i < ${#OUT_R_TYPE[@]}; i++)); do
    [ "${OUT_R_TYPE[i]}" = item ] || continue
    case "${OUT_R_STATE[i]}" in
      ok) OUT_CNT_OK=$((OUT_CNT_OK + 1)) ;;
      warn) OUT_CNT_WARN=$((OUT_CNT_WARN + 1)) ;;
      err) OUT_CNT_ERR=$((OUT_CNT_ERR + 1)) ;;
      info) OUT_CNT_INFO=$((OUT_CNT_INFO + 1)) ;;
    esac
  done
  if [ -n "$OUT_HEAD_STATE" ] || [ -n "$OUT_VER_STATE" ] || [ "${#OUT_R_TYPE[@]}" -gt 0 ]; then OUT_OK=1; fi
  # a heading and nothing else is not a summary
  if [ "$OUT_OK" -eq 1 ] && [ -z "$OUT_HEAD_STATE" ] && [ -z "$OUT_VER_STATE" ]; then
    local real=0
    for ((i = 0; i < ${#OUT_R_TYPE[@]}; i++)); do case "${OUT_R_TYPE[i]}" in item | step | num | kv) real=1 ;; esac; done
    [ "$real" -eq 1 ] || OUT_OK=0
  fi
  [ "$OUT_OK" -eq 1 ]
}

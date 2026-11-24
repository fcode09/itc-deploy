#!/usr/bin/env bash
# shellcheck disable=SC2034  # KTB_* results are read by the views and the tests
# UI kit: the table (a header with the sorted column marked, filtered and sorted rows, a scrolling window that keeps the selected row
# in view, a counter n/m and an optional mini-graph column). Sourced after lib/ui/tui.sh, lib/ui/tokens.sh and graph_braille.sh; pure
# Bash, no fork.
#
#   kit_table <width> <height> <columns-array> <rows-array> [option=value ...]   -> KTB_LINES (exactly <height> lines)
# Columns, one element each: "title|width|align|flags": width is a number of cells or * (shares what is left); align l, r or c; flags
# (comma separated) num (sorts as a number), spark (the cell is a history of numbers, drawn as a one-row graph).
# Rows, one element each: the cells separated by the unit separator $'\x1f' (KIT_SEP). A cell may carry colours.
# Options: sel=N (the selected row, counted among the rows shown), sort=<column>:<asc|desc> (0-based), filter=<text> (rows with no
#   cell containing it, ignoring case, are hidden), top=N (first row shown; it moves to keep the selection in view), mag=<magnitude>
#   (gradient of the spark column), empty=<text> (shown when no row is left), max=N (scale of the spark column; default: auto).
# Results: KTB_COUNT "shown/total" (for a chip), KTB_SEL the index in the rows array of the selected row (-1 if none), KTB_TOP the
# first row shown and KTB_N how many rows are shown. The selected line starts with TUI_SEL, like the body lines of kit_box.

KIT_SEP=$'\x1f'
KTB_LINES=() KTB_COUNT="0/0" KTB_SEL=-1 KTB_TOP=0 KTB_N=0

kit_table() { # width height columns rows [option=value ...]
  local w="$1" h="$2" o sel=0 sortc=-1 sortd=asc filter="" top=0 mag=ramp empty="" max=auto total i j k n body fixed=0 flex=0 flexw rest
  local -n _cols="$3"
  local -n _rows="$4"
  shift 4
  for o in "$@"; do
    case "$o" in
      sel=*) sel="${o#sel=}" ;; sort=*) sortc="${o#sort=}"; sortd="${sortc#*:}"; sortc="${sortc%%:*}" ;; filter=*) filter="${o#filter=}" ;;
      top=*) top="${o#top=}" ;; mag=*) mag="${o#mag=}" ;; empty=*) empty="${o#empty=}" ;; max=*) max="${o#max=}" ;;
    esac
  done
  local -a title=() cw=() al=() fl=() vis=() key=() cells=() order=()
  local ncol="${#_cols[@]}" spec f
  KTB_LINES=()
  total="${#_rows[@]}"
  for ((i = 0; i < ncol; i++)); do
    spec="${_cols[$i]}"
    title[i]="${spec%%|*}"; spec="${spec#*|}"
    cw[i]="${spec%%|*}"; spec="${spec#*|}"
    al[i]="${spec%%|*}"; fl[i]="${spec#*|}"
    [ "${al[$i]}" != "${fl[$i]}" ] || fl[i]=""
    if [ "${cw[$i]}" = "*" ]; then flex=$((flex + 1)); else fixed=$((fixed + cw[i])); fi
  done
  # Widths: the flexible columns share what is left after the fixed ones and one blank between columns.
  rest=$((w - fixed - (ncol > 1 ? ncol - 1 : 0)))
  if [ "$flex" -gt 0 ]; then
    flexw=$((rest / flex)); [ "$flexw" -ge 4 ] || flexw=4
    for ((i = 0; i < ncol; i++)); do if [ "${cw[$i]}" = "*" ]; then cw[i]="$flexw"; fi; done
  fi
  # The rows that pass the filter, in order.
  local lf="${filter,,}" line plain
  for ((i = 0; i < total; i++)); do
    if [ -n "$lf" ]; then
      line="${_rows[$i]//$KIT_SEP/ }"
      if [[ "$line" == *$'\033'* ]]; then tui_strip_ansi "$line"; line="$TUI_OUT"; fi
      plain="${line,,}"
      [[ "$plain" == *"$lf"* ]] || continue
    fi
    vis+=("$i")
  done
  n="${#vis[@]}"
  # Sorting (insertion sort on the shown rows; a table has tens or a few hundred rows).
  if [ "$sortc" -ge 0 ] 2> /dev/null && [ "$sortc" -lt "$ncol" ]; then
    for ((k = 0; k < n; k++)); do
      IFS=$'\x1f' read -ra cells <<< "${_rows[${vis[$k]}]}"
      f="${cells[$sortc]:-}"
      if [[ "$f" == *$'\033'* ]]; then tui_strip_ansi "$f"; f="$TUI_OUT"; fi
      if [[ ",${fl[$sortc]}," == *,num,* ]]; then
        [[ "$f" =~ ^[^0-9]*([0-9]+) ]] && f="${BASH_REMATCH[1]}" || f=0
        printf -v f '%020d' "$((10#$f))"
      else
        f="${f,,}"
      fi
      key[k]="$f"
    done
    for ((i = 1; i < n; i++)); do
      f="${key[$i]}"; j="${vis[$i]}"; k=$((i - 1))
      while [ "$k" -ge 0 ]; do
        if [ "$sortd" = desc ]; then [[ "${key[$k]}" < "$f" ]] || break; else [[ "${key[$k]}" > "$f" ]] || break; fi
        key[k + 1]="${key[$k]}"; vis[k + 1]="${vis[$k]}"; k=$((k - 1))
      done
      key[k + 1]="$f"; vis[k + 1]="$j"
    done
  fi
  KTB_COUNT="$n/$total" KTB_N="$n"
  # Header.
  local head="" mark cell
  for ((i = 0; i < ncol; i++)); do
    cell="${title[$i]}"
    if [ "$i" -eq "$sortc" ] 2> /dev/null; then
      if [ "${UI_UTF8:-0}" -eq 1 ]; then mark="▲"; [ "$sortd" != desc ] || mark="▼"; else mark="^"; [ "$sortd" != desc ] || mark="v"; fi
      cell+="$mark"
    fi
    tui_fit "$cell" "${cw[$i]}"; cell="$TUI_OUT"
    if [ "${al[$i]}" = r ]; then cell="${cell%"${cell##*[![:space:]]}"}"; printf -v cell '%*s' "${cw[$i]}" "$cell"; fi
    [ "$i" -eq 0 ] || head+=" "
    head+="${TH[dim]:-}$C_BLD$cell$TH_RESET"
  done
  tui_fit "$head" "$w"; KTB_LINES[0]="$TUI_OUT"
  body=$((h - 1))
  # The window: keeps the selected row in view.
  [ "$sel" -lt "$n" ] || sel=$((n - 1))
  [ "$sel" -ge 0 ] || sel=0
  [ "$top" -ge 0 ] || top=0
  if [ "$sel" -lt "$top" ]; then top="$sel"; fi
  if [ "$sel" -ge $((top + body)) ]; then top=$((sel - body + 1)); fi
  [ $((top + body)) -le "$n" ] || top=$((n - body))
  [ "$top" -ge 0 ] || top=0
  KTB_TOP="$top" KTB_SEL=-1
  if [ "$n" -gt 0 ]; then KTB_SEL="${vis[$sel]}"; fi
  if [ "$n" -eq 0 ] && [ "$body" -gt 0 ]; then
    tui_fit "${TH[dim]:-}$empty$TH_RESET" "$w"; KTB_LINES+=("$TUI_OUT")
  fi
  local line_out c fw
  for ((k = top; k < n && k < top + body; k++)); do
    IFS=$'\x1f' read -ra cells <<< "${_rows[${vis[$k]}]}"
    line_out=""
    for ((i = 0; i < ncol; i++)); do
      c="${cells[$i]:-}"
      if [[ ",${fl[$i]}," == *,spark,* ]]; then
        kit_graph "$c" "$max" "${cw[$i]}" 1 "mag=$mag"
        c="${KG_LINES[0]:-}"
        tui_fit "$c" "${cw[$i]}"; c="$TUI_OUT"
      else
        tui_vlen "$c"; fw="$TUI_VL"
        if [ "${al[$i]}" = r ]; then
          if [ "$fw" -lt "${cw[$i]}" ]; then printf -v j '%*s' $((cw[i] - fw)) ''; c="$j$c"; fi
        elif [ "${al[$i]}" = c ] && [ "$fw" -lt "${cw[$i]}" ]; then
          printf -v j '%*s' $(((cw[i] - fw) / 2)) ''; c="$j$c"
        fi
        tui_fit "$c" "${cw[$i]}"; c="$TUI_OUT"
      fi
      [ "$i" -eq 0 ] || line_out+=" "
      line_out+="$c"
    done
    tui_fit "$line_out" "$w"; line_out="$TUI_OUT"
    if [ "$k" -eq "$sel" ]; then KTB_LINES+=("$TUI_SEL$line_out"); else KTB_LINES+=("$line_out"); fi
  done
  tui_fit "" "$w"
  while [ "${#KTB_LINES[@]}" -lt "$h" ]; do KTB_LINES+=("$TUI_OUT"); done
}

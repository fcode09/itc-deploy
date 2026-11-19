#!/usr/bin/env bash
# ./deltactl runs list [--instance <name>] [-n <count>] [--json]
# ./deltactl runs show <id|last>
# ./deltactl runs logs <id|last> [--tail <n>] [--raw]
# ./deltactl runs stats [--instance <name>] [-n <runs>]
# History of the operations that changed something (see lib/core/runs.sh). It only reads: it never changes a run.

# shellcheck source=lib/core/runs.sh
source "$ROOT/lib/core/runs.sh"

RUNS_F="" RUNS_ID=""

# Milliseconds as a short human duration into RUNS_F.
runs_fmt_ms() { # ms
  local ms="$1" s
  if ! [[ "$ms" =~ ^[0-9]+$ ]]; then RUNS_F="-"; return 0; fi
  if [ "$ms" -lt 1000 ]; then RUNS_F="$ms ms"
  elif [ "$ms" -lt 60000 ]; then RUNS_F="$((ms / 1000)).$(((ms % 1000) / 100)) s"
  else s=$((ms / 1000)); RUNS_F="$((s / 60)) min $(printf '%02d' $((s % 60))) s"; fi
}

# A run by id, by the start of its id, or `last`, into RUNS_ID. The folder names sort by start time.
runs_resolve() { # id|last
  local want="${1:-last}" base d
  local -a found=()
  base="$(runs_dir)/runs"
  [ -d "$base" ] || die "$(t runs.none)"
  for d in "$base"/*; do [ -d "$d" ] && found+=("${d##*/}"); done
  [ "${#found[@]}" -gt 0 ] || die "$(t runs.none)"
  case "$want" in
    last | -) RUNS_ID="${found[-1]}"; return 0 ;;
  esac
  local -a hit=()
  for d in "${found[@]}"; do
    [ "$d" = "$want" ] && { RUNS_ID="$d"; return 0; }
    case "$d" in "$want"*) hit+=("$d") ;; esac
  done
  [ "${#hit[@]}" -gt 0 ] || die "$(t runs.unknown "$want")"
  [ "${#hit[@]}" -eq 1 ] || die "$(t runs.ambiguous "$want")"
  RUNS_ID="${hit[0]}"
}

runs_state_cell() { # state -> RUNS_CELL ("<kind>:<translated text>")
  local k
  case "$1" in succeeded) k=ok ;; failed) k=err ;; running) k=info ;; *) k=warn ;; esac
  RUNS_CELL="$k:$(t "runs.state.$1")"
}
RUNS_CELL=""

# The runs that are going on right now (their wrapper is alive), as index-like lines.
runs_running_lines() {
  local f id pid
  for f in "$(runs_dir)"/active/*; do
    [ -e "$f" ] || continue
    id="${f##*/}"
    pid="$(cat "$f" 2> /dev/null || true)"
    runs_pid_alive "$pid" || continue
    runs_meta_read "$(runs_dir)/runs/$id" || continue
    printf '%s\t%s\t%s\t%s\trunning\t-\t-\n' "$id" "${RUN[STARTED_AT]}" "${RUN[OP]}" "${RUN[INSTANCE]}"
  done
}

runs_list() {
  local inst="" n=20 json=0 idx line id when op ins st rc ms first=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      --instance) [ "$#" -gt 1 ] || die "$(t runs.usage)"; inst="$2"; shift ;;
      -n) [ "$#" -gt 1 ] || die "$(t runs.usage)"; n="$2"; shift ;;
      *) die "$(t runs.unknown_option "$1")" ;;
    esac
    shift
  done
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ] || die "$(t runs.usage)"
  idx="$(runs_dir)/runs.idx"
  local -a lines=()
  # Running ones first, then the finished ones, newest first.
  while IFS= read -r line; do [ -z "$line" ] || lines+=("$line"); done < <(runs_running_lines)
  if [ -s "$idx" ]; then
    while IFS= read -r line; do lines+=("$line"); done < <(awk -F'\t' -v inst="$inst" '(inst == "" || $4 == inst) { a[++c] = $0 } END { for (i = c; i >= 1; i--) print a[i] }' "$idx")
  fi
  if [ -n "$inst" ]; then
    local -a keep=()
    for line in "${lines[@]}"; do IFS=$'\t' read -r id when op ins st rc ms <<< "$line"; [ "$ins" != "$inst" ] || keep+=("$line"); done
    lines=("${keep[@]}")
  fi
  [ "${#lines[@]}" -le "$n" ] || lines=("${lines[@]:0:$n}")
  if [ "$json" -eq 1 ]; then
    printf '[\n'
    for line in "${lines[@]}"; do
      IFS=$'\t' read -r id when op ins st rc ms <<< "$line"
      [ "$first" -eq 1 ] || printf ',\n'
      first=0
      [[ "$rc" =~ ^[0-9]+$ ]] || rc=null
      [[ "$ms" =~ ^[0-9]+$ ]] || ms=null
      printf '  {"id":"%s","started_at":"%s","command":"%s","instance":"%s","state":"%s","exit_code":%s,"duration_ms":%s}' \
        "$(ui_json_escape "$id")" "$(ui_json_escape "$when")" "$(ui_json_escape "$op")" "$(ui_json_escape "$ins")" "$st" "$rc" "$ms"
    done
    printf '\n]\n'
    return 0
  fi
  if [ "${#lines[@]}" -eq 0 ]; then info "$(t runs.none)"; return 0; fi
  ui_table_cols 24 22 12 14 14
  ui_th "$(t runs.col.id)" "$(t runs.col.when)" "$(t runs.col.op)" "$(t runs.col.instance)" "$(t runs.col.state)" "$(t runs.col.duration)"
  for line in "${lines[@]}"; do
    IFS=$'\t' read -r id when op ins st rc ms <<< "$line"
    runs_state_cell "$st"
    runs_fmt_ms "$ms"
    ui_tr "$id" "${when/T/ }" "bold:$op" "$ins" "$RUNS_CELL" "dim:$RUNS_F"
  done
  ui_hint "$(t runs.hint_show)"
}

# Kilobytes / bytes as a short size into RUNS_F.
runs_fmt_kb() { # kb
  local kb="$1"
  if ! [[ "$kb" =~ ^[0-9]+$ ]]; then RUNS_F="-"; return 0; fi
  if [ "$kb" -lt 1024 ]; then RUNS_F="$kb KB"
  elif [ "$kb" -lt 1048576 ]; then RUNS_F="$((kb / 1024)).$(((kb % 1024) * 10 / 1024)) MB"
  else RUNS_F="$((kb / 1048576)).$(((kb % 1048576) * 10 / 1048576)) GB"; fi
}
runs_fmt_bytes() { # bytes
  if ! [[ "$1" =~ ^[0-9]+$ ]]; then RUNS_F="-"; return 0; fi
  if [ "$1" -lt 1024 ]; then RUNS_F="$1 B"; else runs_fmt_kb $(($1 / 1024)); fi
}

# Change from $1 to $2 as "+12%" / "-27%" into RUNS_D.
RUNS_D=""
runs_delta() { # old new
  local old="$1" new="$2" d
  if [ "$old" -le 0 ]; then RUNS_D="-"; return 0; fi
  d=$(((new - old) * 100 / old))
  if [ "$d" -ge 0 ]; then RUNS_D="+$d%"; else RUNS_D="$d%"; fi
}

# The previous finished run of the same command on the same instance, before run $1 (empty when there is none).
runs_prev_of() { # id op instance
  [ -s "$(runs_dir)/runs.idx" ] || return 0
  awk -F'\t' -v id="$1" -v op="$2" -v ins="$3" '$1 == id { exit } $3 == op && $4 == ins && $5 == "succeeded" { p = $1 } END { if (p != "") print p }' "$(runs_dir)/runs.idx"
}

# A row "label  old -> new (change)" when both figures exist.
runs_vs_row() { # label old new formatter
  local a b
  [[ "$2" =~ ^[0-9]+$ ]] && [[ "$3" =~ ^[0-9]+$ ]] || return 0
  "$4" "$2"; a="$RUNS_F"
  "$4" "$3"; b="$RUNS_F"
  runs_delta "$2" "$3"
  ui_kv "$1" "$a $UI_S_ARROW $b ($RUNS_D)" 16
}

# The "Consumption" part of runs show (RUN is loaded). Runs recorded before it existed have no CPU figure and show nothing.
runs_show_consumption() { # run_dir
  local ms="${RUN[DURATION_MS]:-}" cpu="${RUN[CPU_MS]:-}" calls dms slow a b pct run tot mem rst
  [[ "$cpu" =~ ^[0-9]+$ ]] || return 0
  ui_h2 "$(t runs.cons_title)"
  pct="-"
  [[ "$ms" =~ ^[0-9]+$ ]] && [ "$ms" -gt 0 ] && pct=$((cpu * 100 / ms))
  runs_fmt_ms "$cpu"
  ui_kv "$(t runs.kv.cpu)" "$(t runs.cpu_fmt "$RUNS_F" "$pct")" 16
  calls="${RUN[DOCKER_CALLS]:-0}" dms="${RUN[DOCKER_MS]:-0}"
  pct="-"
  [[ "$ms" =~ ^[0-9]+$ ]] && [ "$ms" -gt 0 ] && pct=$((dms * 100 / ms))
  runs_fmt_ms "$dms"
  ui_kv "$(t runs.kv.docker)" "$(t runs.docker_fmt "$calls" "$RUNS_F" "$pct")" 16
  slow="${RUN[DOCKER_SLOW]:-}"
  if [ -n "$slow" ] && [ "${slow%%|*}" -gt 0 ] 2> /dev/null; then
    runs_fmt_ms "${slow%%|*}"
    ui_kv "$(t runs.kv.slowest)" "$RUNS_F $UI_S_DOT docker ${slow#*|}" 16
  fi
  if [ -n "${RUN[PEAK_RSS_KB]:-}" ]; then
    runs_fmt_kb "${RUN[PEAK_RSS_KB]}"
    ui_kv "$(t runs.kv.mem)" "$(t runs.mem_fmt "$RUNS_F" "${RUN[PEAK_PROCS]:-0}")" 16
  fi
  runs_fmt_bytes "${RUN[OUT_BYTES]:-0}"
  ui_kv "$(t runs.kv.out)" "$(t runs.out_fmt "${RUN[OUT_LINES]:-0}" "$RUNS_F")" 16
  if [ -n "${RUN[FOOT_BEFORE]:-}" ] || [ -n "${RUN[FOOT_AFTER]:-}" ]; then
    ui_h2 "$(t runs.foot_title "${RUN[INSTANCE]}")"
    for a in before after; do
      if [ "$a" = before ]; then b="${RUN[FOOT_BEFORE]:-}"; else b="${RUN[FOOT_AFTER]:-}"; fi
      [ -n "$b" ] || continue
      read -r run mem rst <<< "$b"
      tot="${run#*/}" run="${run%/*}"
      runs_fmt_bytes "$mem"
      ui_kv "$(t "runs.kv.$a")" "$(t runs.foot_fmt "$run" "$tot" "$RUNS_F" "${rst:-0}")" 16
    done
  fi
  ui_hint "$(t runs.cons_note)"
}

# The same operation on the same instance, one run earlier: does it improve? (RUN is loaded; it is replaced.)
runs_show_vs() { # run_id
  local id="$1" prev dur="${RUN[DURATION_MS]:-}" cpu="${RUN[CPU_MS]:-}" dms="${RUN[DOCKER_MS]:-}" mem="${RUN[PEAK_RSS_KB]:-}"
  local op="${RUN[OP]}" ins="${RUN[INSTANCE]}"
  [ "${RUN[STATE]}" = "succeeded" ] || return 0
  [[ "$cpu" =~ ^[0-9]+$ ]] || return 0
  prev="$(runs_prev_of "$id" "$op" "$ins")"
  [ -n "$prev" ] || return 0
  runs_meta_read "$(runs_dir)/runs/$prev" || return 0
  [[ "${RUN[CPU_MS]:-}" =~ ^[0-9]+$ ]] || return 0
  ui_h2 "$(t runs.vs_title "$op" "$ins" "$prev")"
  runs_vs_row "$(t runs.kv.duration)" "${RUN[DURATION_MS]:-}" "$dur" runs_fmt_ms
  runs_vs_row "$(t runs.kv.cpu)" "${RUN[CPU_MS]:-}" "$cpu" runs_fmt_ms
  runs_vs_row "$(t runs.kv.docker)" "${RUN[DOCKER_MS]:-}" "$dms" runs_fmt_ms
  runs_vs_row "$(t runs.kv.mem)" "${RUN[PEAK_RSS_KB]:-}" "$mem" runs_fmt_kb
}

runs_show() {
  local id dir f
  [ "$#" -le 1 ] || die "$(t runs.usage)"
  runs_resolve "${1:-last}"
  id="$RUNS_ID"
  dir="$(runs_dir)/runs/$id"
  runs_meta_read "$dir" || die "$(t runs.unknown "$id")"
  runs_fmt_ms "${RUN[DURATION_MS]:-}"
  ui_h1 "$(t runs.title "$id")"
  ui_kv "$(t runs.kv.command)" "./deltactl ${RUN[OP]} ${RUN[ARGS]#"${RUN[OP]}"}" 16
  ui_kv "$(t runs.kv.instance)" "${RUN[INSTANCE]}" 16
  runs_state_cell "${RUN[STATE]}"
  ui_kv "$(t runs.kv.state)" "$(ui_sym "${RUNS_CELL%%:*}") ${RUNS_CELL#*:}" 16
  ui_kv "$(t runs.kv.exit)" "${RUN[RC]:--}" 16
  ui_kv "$(t runs.kv.started)" "${RUN[STARTED_AT]}" 16
  ui_kv "$(t runs.kv.ended)" "${RUN[ENDED_AT]:--}" 16
  ui_kv "$(t runs.kv.duration)" "$RUNS_F" 16
  ui_kv "$(t runs.kv.who)" "${RUN[USER]:--}@${RUN[HOST]:--}" 16
  f="$dir/out.log"
  ui_kv "$(t runs.kv.log)" "$f" 16
  runs_show_consumption "$dir"
  if [ -s "$f" ]; then
    ui_h2 "$(t runs.out_title 12 "$id")"
    tail -n 12 "$f" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' | tr -d '\r' | sed 's/^/  /'
  fi
  runs_show_vs "$id"   # last: it replaces RUN with the previous run
}

# What each kind of operation costs on average: runs stats [--instance <name>] [-n <runs to look at>]
runs_stats() {
  local inst="" n=100 d id op st ms k
  local -A cnt=() ok=() bad=() sdur=() ndur=() scpu=() ncpu=() sdk=() ndk=() peak=()
  local -a ops=() dirs=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --instance) [ "$#" -gt 1 ] || die "$(t runs.usage)"; inst="$2"; shift ;;
      -n) [ "$#" -gt 1 ] || die "$(t runs.usage)"; n="$2"; shift ;;
      *) die "$(t runs.unknown_option "$1")" ;;
    esac
    shift
  done
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ] || die "$(t runs.usage)"
  [ -d "$(runs_dir)/runs" ] || die "$(t runs.none)"
  for d in "$(runs_dir)"/runs/*; do [ -d "$d" ] && dirs+=("$d"); done
  [ "${#dirs[@]}" -gt 0 ] || die "$(t runs.none)"
  [ "${#dirs[@]}" -le "$n" ] || dirs=("${dirs[@]: -$n}")
  for d in "${dirs[@]}"; do
    runs_meta_read "$d" || continue
    [ -z "$inst" ] || [ "${RUN[INSTANCE]}" = "$inst" ] || continue
    case "${RUN[STATE]}" in succeeded | failed | canceled) ;; *) continue ;; esac   # running and interrupted ones have no figures
    op="${RUN[OP]}"
    [ -n "${cnt[$op]:-}" ] || ops+=("$op")
    cnt[$op]=$((${cnt[$op]:-0} + 1))
    case "${RUN[STATE]}" in succeeded) ok[$op]=$((${ok[$op]:-0} + 1)) ;; failed) bad[$op]=$((${bad[$op]:-0} + 1)) ;; esac
    if [[ "${RUN[DURATION_MS]:-}" =~ ^[0-9]+$ ]]; then sdur[$op]=$((${sdur[$op]:-0} + ${RUN[DURATION_MS]})); ndur[$op]=$((${ndur[$op]:-0} + 1)); fi
    if [[ "${RUN[CPU_MS]:-}" =~ ^[0-9]+$ ]]; then scpu[$op]=$((${scpu[$op]:-0} + ${RUN[CPU_MS]})); ncpu[$op]=$((${ncpu[$op]:-0} + 1)); fi
    if [[ "${RUN[DOCKER_MS]:-}" =~ ^[0-9]+$ ]]; then sdk[$op]=$((${sdk[$op]:-0} + ${RUN[DOCKER_MS]})); ndk[$op]=$((${ndk[$op]:-0} + 1)); fi
    if [[ "${RUN[PEAK_RSS_KB]:-}" =~ ^[0-9]+$ ]] && [ "${RUN[PEAK_RSS_KB]}" -gt "${peak[$op]:-0}" ]; then peak[$op]="${RUN[PEAK_RSS_KB]}"; fi
  done
  if [ "${#ops[@]}" -eq 0 ]; then info "$(t runs.none)"; return 0; fi
  ui_h1 "$(t runs.stats_title "${#dirs[@]}")"
  ui_table_cols 12 7 6 8 14 14 14
  ui_th "$(t runs.col.op)" "$(t runs.col.runs)" "$(t runs.col.ok)" "$(t runs.col.failed)" "$(t runs.col.avg_duration)" "$(t runs.col.avg_cpu)" "$(t runs.col.avg_docker)" "$(t runs.col.peak_mem)"
  for op in "${ops[@]}"; do
    local a_d="-" a_c="-" a_k="-" p="-"
    if [ "${ndur[$op]:-0}" -gt 0 ]; then runs_fmt_ms $((${sdur[$op]} / ${ndur[$op]})); a_d="$RUNS_F"; fi
    if [ "${ncpu[$op]:-0}" -gt 0 ]; then runs_fmt_ms $((${scpu[$op]} / ${ncpu[$op]})); a_c="$RUNS_F"; fi
    if [ "${ndk[$op]:-0}" -gt 0 ]; then runs_fmt_ms $((${sdk[$op]} / ${ndk[$op]})); a_k="$RUNS_F"; fi
    if [ "${peak[$op]:-0}" -gt 0 ]; then runs_fmt_kb "${peak[$op]}"; p="$RUNS_F"; fi
    k="${bad[$op]:-0}"
    ui_tr "bold:$op" "${cnt[$op]}" "${ok[$op]:-0}" "$( [ "$k" -gt 0 ] && printf 'err:%s' "$k" || printf '%s' "$k")" "$a_d" "$a_c" "$a_k" "$p"
  done
  ui_hint "$(t runs.cons_note)"
}

runs_logs() {
  local id f tail_n="" raw=0 target=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --raw) raw=1 ;;
      --tail) [ "$#" -gt 1 ] || die "$(t runs.usage)"; tail_n="$2"; shift ;;
      -*) die "$(t runs.unknown_option "$1")" ;;
      *) [ -z "$target" ] || die "$(t runs.usage)"; target="$1" ;;
    esac
    shift
  done
  [ -z "$tail_n" ] || { [[ "$tail_n" =~ ^[0-9]+$ ]] || die "$(t runs.usage)"; }
  runs_resolve "${target:-last}"
  id="$RUNS_ID"
  f="$(runs_dir)/runs/$id/out.log"
  [ -r "$f" ] || die "$(t runs.unknown "$id")"
  # Colours stay only when asked (--raw) or when the output is a terminal; into a pipe or a file the log is plain text.
  if [ "$raw" -eq 1 ] || [ -t 1 ]; then
    if [ -n "$tail_n" ]; then tail -n "$tail_n" "$f"; else cat "$f"; fi
  else
    if [ -n "$tail_n" ]; then tail -n "$tail_n" "$f"; else cat "$f"; fi | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' | tr -d '\r'
  fi
}

cmd_runs() {
  local sub="${1:-list}"
  [ "$#" -eq 0 ] || shift
  case "$sub" in
    list | ls) runs_list "$@" ;;
    show) runs_show "$@" ;;
    logs | log) runs_logs "$@" ;;
    stats) runs_stats "$@" ;;
    *) die "$(t runs.usage)" ;;
  esac
}

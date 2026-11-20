#!/usr/bin/env bash
# ./deltactl runs list [--instance <name>] [-n <count>] [--json]
# ./deltactl runs show <id|last>
# ./deltactl runs logs <id|last> [--tail <n>] [--raw]
# ./deltactl runs stats [--instance <name>] [-n <runs>]
# ./deltactl runs resolve <id|--all> [--note <text>]
# ./deltactl runs prune [--dry-run] [--days <n>] [--max-mb <n>]
# History of the operations that changed something (see lib/core/runs.sh). It only reads, except `resolve` (marks an interrupted run as
# reviewed) and `prune` (deletes old runs), which act when asked for and never change what a run recorded about itself.

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
  local inst="" n=20 json=0 idx line id when op ins st rc ms first=1 pend
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
      pend=false
      [ ! -f "$(runs_dir)/pending/$id" ] || pend=true
      printf '  {"id":"%s","started_at":"%s","command":"%s","instance":"%s","state":"%s","exit_code":%s,"duration_ms":%s,"pending_review":%s}' \
        "$(ui_json_escape "$id")" "$(ui_json_escape "$when")" "$(ui_json_escape "$op")" "$(ui_json_escape "$ins")" "$st" "$rc" "$ms" "$pend"
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
    [ ! -f "$(runs_dir)/pending/$id" ] || RUNS_CELL="err:$(t runs.state.pending)"
    runs_fmt_ms "$ms"
    ui_tr "$id" "${when/T/ }" "bold:$op" "$ins" "$RUNS_CELL" "dim:$RUNS_F"
  done
  if runs_pending; then ui_hint "$(t runs.pending_hint "$RUNS_PEND_N")"; fi
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
  if [ -f "$(runs_dir)/pending/$id" ]; then
    ui_kv "$(t runs.kv.review)" "$(t runs.review.pending "$id")" 16
  elif [ -n "${RUN[RESOLVED_AT]:-}" ]; then
    ui_kv "$(t runs.kv.review)" "$(t runs.review.done "${RUN[RESOLVED_AT]/T/ }")${RUN[NOTE]:+ $UI_S_DOT ${RUN[NOTE]}}" 16
  fi
  # What it had already changed is not undone by stopping it: say so instead of letting the state suggest otherwise.
  case "${RUN[STATE]}" in canceled | interrupted) ui_hint "$(t runs.note_partial "${RUN[INSTANCE]}")" ;; esac
  f="$dir/out.log"
  ui_kv "$(t runs.kv.log)" "$f" 16
  runs_show_consumption "$dir"
  if [ -s "$f" ]; then
    ui_h2 "$(t runs.out_title 12 "$id")"
    tail -n 12 "$f" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' | tr -d '\r' | sed 's/^/  /'
  fi
  runs_show_vs "$id"   # last: it replaces RUN with the previous run
}

# What each kind of operation costs on average. The figures are gathered here (CLI and panel share them) into the RS_* tables.
declare -gA RS_CNT=() RS_OK=() RS_BAD=() RS_SDUR=() RS_NDUR=() RS_SCPU=() RS_NCPU=() RS_SDK=() RS_NDK=() RS_PEAK=()
RS_OPS=() RS_N=0
RS_C_DUR="" RS_C_CPU="" RS_C_DK="" RS_C_PEAK=""

# Looks at the last $2 runs (of instance $1, or of all when empty). Returns 1 when there is no history at all; RS_OPS is empty
# when there is history but none of it finished.
runs_stats_collect() { # instance count
  local inst="$1" n="$2" d op
  local -a dirs=()
  RS_CNT=() RS_OK=() RS_BAD=() RS_SDUR=() RS_NDUR=() RS_SCPU=() RS_NCPU=() RS_SDK=() RS_NDK=() RS_PEAK=() RS_OPS=() RS_N=0
  [ -d "$(runs_dir)/runs" ] || return 1
  for d in "$(runs_dir)"/runs/*; do [ -d "$d" ] && dirs+=("$d"); done
  [ "${#dirs[@]}" -gt 0 ] || return 1
  [ "${#dirs[@]}" -le "$n" ] || dirs=("${dirs[@]: -$n}")
  RS_N="${#dirs[@]}"
  for d in "${dirs[@]}"; do
    runs_meta_read "$d" || continue
    [ -z "$inst" ] || [ "${RUN[INSTANCE]:-}" = "$inst" ] || continue
    case "${RUN[STATE]:-}" in succeeded | failed | canceled) ;; *) continue ;; esac   # running and interrupted ones have no figures
    op="${RUN[OP]:-?}"
    [ -n "${RS_CNT[$op]:-}" ] || RS_OPS+=("$op")
    RS_CNT[$op]=$((${RS_CNT[$op]:-0} + 1))
    case "${RUN[STATE]:-}" in succeeded) RS_OK[$op]=$((${RS_OK[$op]:-0} + 1)) ;; failed) RS_BAD[$op]=$((${RS_BAD[$op]:-0} + 1)) ;; esac
    if [[ "${RUN[DURATION_MS]:-}" =~ ^[0-9]+$ ]]; then RS_SDUR[$op]=$((${RS_SDUR[$op]:-0} + ${RUN[DURATION_MS]})); RS_NDUR[$op]=$((${RS_NDUR[$op]:-0} + 1)); fi
    if [[ "${RUN[CPU_MS]:-}" =~ ^[0-9]+$ ]]; then RS_SCPU[$op]=$((${RS_SCPU[$op]:-0} + ${RUN[CPU_MS]})); RS_NCPU[$op]=$((${RS_NCPU[$op]:-0} + 1)); fi
    if [[ "${RUN[DOCKER_MS]:-}" =~ ^[0-9]+$ ]]; then RS_SDK[$op]=$((${RS_SDK[$op]:-0} + ${RUN[DOCKER_MS]})); RS_NDK[$op]=$((${RS_NDK[$op]:-0} + 1)); fi
    if [[ "${RUN[PEAK_RSS_KB]:-}" =~ ^[0-9]+$ ]] && [ "${RUN[PEAK_RSS_KB]}" -gt "${RS_PEAK[$op]:-0}" ]; then RS_PEAK[$op]="${RUN[PEAK_RSS_KB]}"; fi
  done
  return 0
}

# The averages of one operation as text: RS_C_DUR, RS_C_CPU, RS_C_DK and RS_C_PEAK ("-" when there is no figure).
runs_stats_cells() { # op
  local op="$1"
  RS_C_DUR="-" RS_C_CPU="-" RS_C_DK="-" RS_C_PEAK="-"
  if [ "${RS_NDUR[$op]:-0}" -gt 0 ]; then runs_fmt_ms $((${RS_SDUR[$op]} / ${RS_NDUR[$op]})); RS_C_DUR="$RUNS_F"; fi
  if [ "${RS_NCPU[$op]:-0}" -gt 0 ]; then runs_fmt_ms $((${RS_SCPU[$op]} / ${RS_NCPU[$op]})); RS_C_CPU="$RUNS_F"; fi
  if [ "${RS_NDK[$op]:-0}" -gt 0 ]; then runs_fmt_ms $((${RS_SDK[$op]} / ${RS_NDK[$op]})); RS_C_DK="$RUNS_F"; fi
  if [ "${RS_PEAK[$op]:-0}" -gt 0 ]; then runs_fmt_kb "${RS_PEAK[$op]}"; RS_C_PEAK="$RUNS_F"; fi
}

# runs stats [--instance <name>] [-n <runs to look at>]
runs_stats() {
  local inst="" n=100 op k
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --instance) [ "$#" -gt 1 ] || die "$(t runs.usage)"; inst="$2"; shift ;;
      -n) [ "$#" -gt 1 ] || die "$(t runs.usage)"; n="$2"; shift ;;
      *) die "$(t runs.unknown_option "$1")" ;;
    esac
    shift
  done
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ] || die "$(t runs.usage)"
  runs_stats_collect "$inst" "$n" || die "$(t runs.none)"
  if [ "${#RS_OPS[@]}" -eq 0 ]; then info "$(t runs.none)"; return 0; fi
  ui_h1 "$(t runs.stats_title "$RS_N")"
  ui_table_cols 12 7 6 8 14 14 14
  ui_th "$(t runs.col.op)" "$(t runs.col.runs)" "$(t runs.col.ok)" "$(t runs.col.failed)" "$(t runs.col.avg_duration)" "$(t runs.col.avg_cpu)" "$(t runs.col.avg_docker)" "$(t runs.col.peak_mem)"
  for op in "${RS_OPS[@]}"; do
    runs_stats_cells "$op"
    k="${RS_BAD[$op]:-0}"
    ui_tr "bold:$op" "${RS_CNT[$op]}" "${RS_OK[$op]:-0}" "$( [ "$k" -gt 0 ] && printf 'err:%s' "$k" || printf '%s' "$k")" "$RS_C_DUR" "$RS_C_CPU" "$RS_C_DK" "$RS_C_PEAK"
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

# Marks interrupted runs as reviewed, which lets operations start again: runs resolve <id|--all> [--note <text>]
runs_resolve_cmd() {
  local target="" all=0 note="" id f dir
  local -a ids=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --all) all=1 ;;
      --note) [ "$#" -gt 1 ] || die "$(t runs.resolve.usage)"; note="$2"; shift ;;
      -*) die "$(t runs.unknown_option "$1")" ;;
      *) [ -z "$target" ] || die "$(t runs.resolve.usage)"; target="$1" ;;
    esac
    shift
  done
  if [ "$all" -eq 1 ]; then
    [ -z "$target" ] || die "$(t runs.resolve.usage)"
    for f in "$(runs_dir)"/pending/*; do [ -f "$f" ] && ids+=("${f##*/}"); done
    [ "${#ids[@]}" -gt 0 ] || { info "$(t runs.resolve.none)"; return 0; }
  else
    [ -n "$target" ] || die "$(t runs.resolve.usage)"   # an id on purpose: it is a statement that someone looked at that run
    runs_resolve "$target"
    [ -f "$(runs_dir)/pending/$RUNS_ID" ] || die "$(t runs.resolve.not_pending "$RUNS_ID")"
    ids=("$RUNS_ID")
  fi
  for id in "${ids[@]}"; do
    dir="$(runs_dir)/runs/$id"
    if runs_meta_read "$dir"; then
      RUN[RESOLVED_AT]="$(runs_now_iso)" RUN[NOTE]="${note//$'\n'/ }"
      runs_meta_write "$dir" || warn "$(t runs.resolve.no_meta "$id")"
    fi
    rm -f "$(runs_dir)/pending/$id"
    ok "$(t runs.resolve.ok "$id")"
  done
}

# Deletes the oldest finished runs past a limit of age (days) or of total size (MB): runs prune [--dry-run] [--days <n>] [--max-mb <n>].
# Runs in progress and interrupted ones nobody has reviewed are never deleted. It only ever runs when asked for.
runs_prune() {
  local dry=0 days=30 maxmb=1024 rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      --days) [ "$#" -gt 1 ] || die "$(t runs.prune.usage)"; days="$2"; shift ;;
      --max-mb) [ "$#" -gt 1 ] || die "$(t runs.prune.usage)"; maxmb="$2"; shift ;;
      *) die "$(t runs.unknown_option "$1")" ;;
    esac
    shift
  done
  [[ "$days" =~ ^[0-9]+$ ]] && [[ "$maxmb" =~ ^[0-9]+$ ]] || die "$(t runs.prune.usage)"
  # Deleting and rewriting the index happen under the lock of the operations: nothing appends to the index meanwhile.
  if [ "$dry" -eq 0 ] && ! runs_lock "prune" "runs prune"; then die "$(t runs.prune.busy "$RUNS_OWNER_WHAT")"; fi
  runs_prune_run "$dry" "$days" "$maxmb" || rc=$?
  [ "$dry" -eq 1 ] || runs_unlock
  return "$rc"
}

runs_prune_run() { # dry days maxmb
  local dry="$1" days="$2" maxmb="$3" cutoff base idx kb d id acc=0 total=0 gone=0 gonekb=0 why n=0 total_txt del
  local -A size=() reason=() keepit=()
  local -a ids=() out=()
  base="$(runs_dir)/runs"
  idx="$(runs_dir)/runs.idx"
  [ -d "$base" ] || die "$(t runs.none)"
  cutoff="$(date -u -d "$days days ago" +%Y%m%dT%H%M%SZ)"
  # Sizes of every run in one call (a process per folder would be slow with thousands of them).
  while IFS=$'\t' read -r kb d; do size["${d##*/}"]="$kb"; done < <(du -sk "$base"/*/ 2> /dev/null | sed 's#/\?$##')
  for d in "$base"/*; do [ -d "$d" ] && ids+=("${d##*/}"); done
  [ "${#ids[@]}" -gt 0 ] || { info "$(t runs.none)"; return 0; }
  # What is going on and what nobody has reviewed stays, whatever the limits say.
  for d in "$(runs_dir)"/active/*; do [ -e "$d" ] && keepit["${d##*/}"]=1; done
  for d in "$(runs_dir)"/pending/*; do [ -e "$d" ] && keepit["${d##*/}"]=1; done
  # Newest first: what fits the size budget stays, the rest (and whatever is too old) goes.
  for ((n = ${#ids[@]} - 1; n >= 0; n--)); do
    id="${ids[$n]}"
    kb="${size[$id]:-0}"
    acc=$((acc + kb)) total=$((total + kb))
    [ -z "${keepit[$id]:-}" ] || continue
    why=""
    if [[ "${id:0:16}" < "$cutoff" ]]; then why="age"
    elif [ "$acc" -gt $((maxmb * 1024)) ]; then why="size"; fi
    [ -z "$why" ] || { reason[$id]="$why"; gone=$((gone + 1)); gonekb=$((gonekb + kb)); out+=("$id"); }
  done
  runs_fmt_kb "$total"; total_txt="$RUNS_F"
  if [ "$gone" -eq 0 ]; then info "$(t runs.prune.nothing "$days" "$maxmb" "${#ids[@]}" "$total_txt")"; return 0; fi
  runs_fmt_kb "$gonekb"
  if [ "$dry" -eq 1 ]; then ui_h1 "$(t runs.prune.title_dry "$gone" "${#ids[@]}" "$RUNS_F")"; else ui_h1 "$(t runs.prune.title "$gone" "${#ids[@]}" "$RUNS_F")"; fi
  ui_table_cols 24 14 14 12
  ui_th "$(t runs.col.id)" "$(t runs.col.op)" "$(t runs.col.instance)" "$(t runs.prune.col.size)" "$(t runs.prune.col.why)"
  for id in "${out[@]}"; do
    runs_meta_read "$base/$id" || RUN=()
    runs_fmt_kb "${size[$id]:-0}"
    ui_tr "$id" "${RUN[OP]:--}" "${RUN[INSTANCE]:--}" "$RUNS_F" "dim:$(t "runs.prune.why.${reason[$id]}" "$days" "$maxmb")"
  done
  ui_hint "$(t runs.prune.keeps)"
  [ "$dry" -eq 0 ] || return 0
  del="$(mktemp "$(runs_dir)/.prune.XXXXXX")" || die "$(t runs.cannot_record "$(runs_dir)")"
  printf '%s\n' "${out[@]}" > "$del"
  for id in "${out[@]}"; do rm -rf "${base:?}/$id"; done
  if [ -s "$idx" ]; then
    awk -F'\t' 'NR == FNR { gone[$1]; next } !($1 in gone)' "$del" "$idx" > "$del.idx" && mv -f "$del.idx" "$idx"
  fi
  rm -f "$del" "$del.idx"
}

cmd_runs() {
  local sub="${1:-list}"
  [ "$#" -eq 0 ] || shift
  case "$sub" in
    list | ls) runs_list "$@" ;;
    show) runs_show "$@" ;;
    logs | log) runs_logs "$@" ;;
    stats) runs_stats "$@" ;;
    resolve) runs_resolve_cmd "$@" ;;
    prune) runs_prune "$@" ;;
    *) die "$(t runs.usage)" ;;
  esac
}

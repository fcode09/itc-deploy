#!/usr/bin/env bash
# ./deltactl runs list [--instance <name>] [-n <count>] [--json]
# ./deltactl runs show <id|last>
# ./deltactl runs logs <id|last> [--tail <n>] [--raw]
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
  if [ -s "$f" ]; then
    ui_h2 "$(t runs.out_title 12 "$id")"
    tail -n 12 "$f" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' | tr -d '\r' | sed 's/^/  /'
  fi
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
    *) die "$(t runs.usage)" ;;
  esac
}

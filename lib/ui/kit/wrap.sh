#!/usr/bin/env bash
# shellcheck disable=SC2034  # KW_LINES is read by the callers
# UI kit: word wrap. kit_wrap <text> <width> -> KW_LINES: the text broken at spaces into lines of at most <width> cells (a word longer
# than the width is cut). Plain text only (no colour sequences); a newline in the text starts a new line. Pure Bash, no fork.
KW_LINES=()
kit_wrap() { # text width
  local text="$1" w="$2" para line word
  KW_LINES=()
  [ "$w" -gt 0 ] || return 0
  while IFS= read -r para || [ -n "$para" ]; do
    line=""
    for word in $para; do
      while [ "${#word}" -gt "$w" ]; do
        [ -z "$line" ] || { KW_LINES+=("$line"); line=""; }
        KW_LINES+=("${word:0:$w}")
        word="${word:$w}"
      done
      if [ -z "$line" ]; then line="$word"
      elif [ $((${#line} + 1 + ${#word})) -le "$w" ]; then line+=" $word"
      else KW_LINES+=("$line"); line="$word"; fi
    done
    KW_LINES+=("$line")
  done <<< "$text"
}

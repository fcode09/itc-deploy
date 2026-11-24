#!/usr/bin/env bash
# shellcheck disable=SC2034  # TH_GR_* and TH_STOPS are read by lib/ui/kit/*.sh and the panel views
# Design tokens that sit on top of lib/ui/theme.sh. Sourced by lib/bootstrap.sh after theme.sh; not executed.
#
# A theme may give, besides the semantic colours (accent ok warn err ...), a gradient per magnitude of a metric:
#   cpu_start= cpu_mid= cpu_end=   (also mem disk net_down net_up health)    each #rrggbb; mid is optional (the middle of start and end)
#   track=#rrggbb      the empty part of a meter
#   hotkey=#rrggbb     the letter of a shortcut inside a label (default: accent)
# A magnitude the theme does not define uses the theme's `ramp` (so every existing theme looks as it did).
# The gradients have 101 steps (0..100 percent), built once per theme the first time a magnitude is used (th_grad, th_grad_use):
# painting a value is an array lookup, with no process and no colour arithmetic per frame. In a 256 or 16 colour terminal each step is already reduced
# by th_color; with no colour the arrays are empty and th_grad gives nothing (the charts then read by height, not by colour).

TH_MAGS=(cpu mem disk net_down net_up health)
declare -ga TH_GR_ramp=() TH_GR_cpu=() TH_GR_mem=() TH_GR_disk=() TH_GR_net_down=() TH_GR_net_up=() TH_GR_health=()
TH_STOPS=() TH_MIX="" TH_GRAD_HEX="" TH_GR_GEN=0
declare -gA TH_GR_BUILT=()

# "#rrggbb" -> TH_R TH_G TH_B (0-255)
TH_R=0 TH_G=0 TH_B=0
th_rgb() { # hex
  local h="${1#\#}"
  TH_R=$((16#${h:0:2})) TH_G=$((16#${h:2:2})) TH_B=$((16#${h:4:2}))
}

# Mix of two colours, $3 percent of the way from the first to the second, into TH_MIX (#rrggbb).
th_mix() { # hex hex percent
  local r1 g1 b1 p="$3"
  th_rgb "$1"; r1=$TH_R g1=$TH_G b1=$TH_B
  th_rgb "$2"
  printf -v TH_MIX '#%02x%02x%02x' $((r1 + (TH_R - r1) * p / 100)) $((g1 + (TH_G - g1) * p / 100)) $((b1 + (TH_B - b1) * p / 100))
}

# Colour stops of a magnitude into TH_STOPS: its start/mid/end if the theme gives start and end, else the theme's ramp, else the
# ok/warn/err colours; empty when the theme has no colours at all (mono).
th_grad_stops() { # magnitude
  local m="$1" s e mid
  TH_STOPS=()
  s="${TH_HEX[${m}_start]:-}" e="${TH_HEX[${m}_end]:-}" mid="${TH_HEX[${m}_mid]:-}"
  if [ -n "$s" ] && [ -n "$e" ]; then
    if [ -z "$mid" ]; then th_mix "$s" "$e" 50; mid="$TH_MIX"; fi
    TH_STOPS=("$s" "$mid" "$e")
    return 0
  fi
  if [ -n "${TH_HEX[ramp]:-}" ]; then
    IFS=, read -ra TH_STOPS <<< "${TH_HEX[ramp]}"
  elif [ -n "${TH_HEX[ok]:-}" ] && [ -n "${TH_HEX[warn]:-}" ] && [ -n "${TH_HEX[err]:-}" ]; then
    TH_STOPS=("${TH_HEX[ok]}" "${TH_HEX[warn]}" "${TH_HEX[err]}")
  fi
}

# Builds the 101 escape sequences of a magnitude into TH_GR_<magnitude> ("ramp" is the theme's own ramp).
th_grad_build() { # magnitude
  local m="$1" n i p t f r1 g1 b1
  local -n _g="TH_GR_$m"
  local -a R=() G=() B=()
  _g=()
  if [ "$TH_MODE" = "none" ]; then return 0; fi
  if [ "$m" = "ramp" ]; then
    TH_STOPS=()
    [ -z "${TH_HEX[ramp]:-}" ] || IFS=, read -ra TH_STOPS <<< "${TH_HEX[ramp]}"
    if [ "${#TH_STOPS[@]}" -eq 0 ] && [ -n "${TH_HEX[ok]:-}" ] && [ -n "${TH_HEX[warn]:-}" ] && [ -n "${TH_HEX[err]:-}" ]; then
      TH_STOPS=("${TH_HEX[ok]}" "${TH_HEX[warn]}" "${TH_HEX[err]}")
    fi
  else
    th_grad_stops "$m"
  fi
  n="${#TH_STOPS[@]}"
  [ "$n" -gt 0 ] || return 0
  for ((i = 0; i < n; i++)); do th_rgb "${TH_STOPS[$i]}"; R[i]=$TH_R G[i]=$TH_G B[i]=$TH_B; done
  for ((p = 0; p <= 100; p++)); do
    if [ "$n" -eq 1 ]; then
      i=0 f=0
    else
      t=$((p * (n - 1))) i=$((t / 100)) f=$((t % 100))
      if [ "$i" -ge $((n - 1)) ]; then i=$((n - 2)) f=100; fi
    fi
    if [ "$n" -eq 1 ]; then
      r1=${R[0]} g1=${G[0]} b1=${B[0]}
    else
      r1=$((R[i] + (R[i + 1] - R[i]) * f / 100)) g1=$((G[i] + (G[i + 1] - G[i]) * f / 100)) b1=$((B[i] + (B[i + 1] - B[i]) * f / 100))
    fi
    if [ "$TH_MODE" = truecolor ]; then
      _g[p]=$'\033[38;2;'"$r1;$g1;${b1}m"
    else
      printf -v TH_GRAD_HEX '#%02x%02x%02x' "$r1" "$g1" "$b1"
      th_color "$TH_GRAD_HEX" fg
      _g[p]="$TH_C"
    fi
  done
  TH_GR_BUILT[$m]="$TH_GR_GEN"
}

# Makes sure the gradient of a magnitude is built for the current theme (they are built on first use, once per theme; a kit
# function that reads TH_GR_<magnitude> directly calls this first).
th_grad_use() { # magnitude
  [ "${TH_GR_BUILT[$1]-}" = "$TH_GR_GEN" ] || th_grad_build "$1"
}

# Colour of $2 percent (0-100) of magnitude $1 into TH_C. Nothing when the theme has no colours.
th_grad() { # magnitude percent
  [ "${TH_GR_BUILT[$1]-}" = "$TH_GR_GEN" ] || th_grad_build "$1"
  local p="$2" ref
  case "$p" in '' | *[!0-9]*) p=0 ;; esac
  [ "$p" -le 100 ] || p=100
  ref="TH_GR_$1[$p]"
  TH_C="${!ref-}"
}

# New theme: the gradients are stale (they are rebuilt on first use) and the extra tokens are set (called by theme_apply).
th_tokens_build() {
  local k
  TH_GR_GEN=$((TH_GR_GEN + 1))
  for k in track hotkey; do TH["$k"]=""; done
  [ "$TH_MODE" != "none" ] || return 0
  for k in track hotkey; do
    if [ -n "${TH_HEX[$k]:-}" ]; then th_color "${TH_HEX[$k]}" fg; TH["$k"]="$TH_C"; fi
  done
  [ -n "${TH[track]:-}" ] || TH[track]="${TH[faint]:-}"
  [ -n "${TH[hotkey]:-}" ] || TH[hotkey]="${TH[accent]:-}"
}

# Symbols the design uses everywhere, with their ASCII fallback (decided by ui_init: UTF-8 and rich mode).
ui_tokens_symbols() {
  if [ "${UI_UTF8:-0}" -eq 1 ] && [ "${UI_RICH:-0}" -eq 1 ]; then
    UI_S_PEND='○' UI_S_RUN='◐' UI_S_STAR='★' UI_S_UP='↑' UI_S_SECRET='⚿' UI_S_CHECK='✔' UI_S_LEAD='·' UI_S_ENTER='⏎'
    UI_S_CHIP_L='┐' UI_S_CHIP_R='┌' UI_S_FCHIP_L='┘' UI_S_FCHIP_R='└' UI_S_STEP_ON='━' UI_S_STEP_OFF='─' UI_S_MASK='•'
    UI_SUP=(⁰ ¹ ² ³ ⁴ ⁵ ⁶ ⁷ ⁸ ⁹)
    UI_EIGHTHS=('' ▏ ▎ ▍ ▌ ▋ ▊ ▉)
  else
    UI_S_PEND='.' UI_S_RUN='~' UI_S_STAR='*' UI_S_UP='^' UI_S_SECRET='#' UI_S_CHECK='v' UI_S_LEAD='.' UI_S_ENTER='Enter'
    UI_S_CHIP_L='[' UI_S_CHIP_R=']' UI_S_FCHIP_L='[' UI_S_FCHIP_R=']' UI_S_STEP_ON='=' UI_S_STEP_OFF='-' UI_S_MASK='*'
    UI_SUP=(0 1 2 3 4 5 6 7 8 9)
    UI_EIGHTHS=('' '' '' '' '' '' '' '')
  fi
}
ui_tokens_symbols

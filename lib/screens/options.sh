#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables are shared with lib/cmd/dashboard.sh, dashboard_view.sh and the other screens
# Options screen of the panel (key o): theme, language, sampling interval, refresh interval and the vim keys, in one place.
# Loaded by lib/screens/registry.sh.
#
# Every change applies at once and is remembered in the user config file, the one that already keeps UI_LANG and UI_THEME
# (i18n_config_file: $DELTACTL_CONFIG, else ~/.config/deltactl/config). It is written with set_var, a temporary file swapped in
# with a rename, so a failure never leaves it half written. A failure to write only means the choice lasts one run.
#
#   UI_THEME=<name>      theme of the panel
#   UI_LANG=es|en        language (the CLI reads it too)
#   TUI_SAMPLE=<s>       seconds between two samples of the figures of the services (1-60)
#   TUI_REFRESH=<s>      without Docker events, seconds between two readings of the state (1-3600)
#   TUI_VIM=on|off       whether j k h g G move like the arrows, Home and End
#   TUI_MOUSE=on|off     whether the panel takes clicks and the wheel (off by default: it takes the terminal's text selection)
#   TUI_PREREQ=on|off    whether the panel warns when something required is missing on the server (on by default)
#
# The variables DELTACTL_THEME, DELTACTL_LANG, DELTACTL_METRICS_INTERVAL and DELTACTL_REFRESH still win when the panel starts;
# the screen says so next to the option they fix.
#
# Every value read from the file is checked before it is used: only short runs of digits reach an arithmetic expansion. A variable
# keeps the wider range its own layer always accepted (any whole number of seconds above zero, up to a day).

DASH_OPT_IDS=(theme lang sample refresh vim mouse prereq)
DASH_OPT_SAMPLES=(1 2 3 5 10)
DASH_OPT_REFRESHES=(2 5 10 15 30 60)
DASH_OPT_SEL=0 DASH_OPT_N=0 DASH_VIM=1 DASH_CFG_V="" DASH_OPT_FILE=""
declare -gA DASH_OPT_ENV=()   # options fixed by an environment variable when the panel started (id -> variable name)

# Value of KEY in the config file (the last line wins), into DASH_CFG_V; empty when the file or the key is missing.
dash_cfg_get() { # key
  local f line
  DASH_CFG_V=""
  f="$(i18n_config_file)"
  [ -r "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in "$1="*) DASH_CFG_V="${line#"$1"=}" ;; esac
  done 2>/dev/null < "$f"
}

# Remembers KEY=value in the config file, creating it if needed.
dash_cfg_set() { # key value
  local f
  f="$(i18n_config_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  [ -f "$f" ] || : > "$f" 2>/dev/null || return 0
  set_var "$f" "$1" "$2" 2>/dev/null || true
}

# Is $1 a whole number between $2 and $3? (at most 5 digits, so a long run of digits can never overflow; read in base 10, so
# a leading zero is not taken for octal). The number goes to DASH_OPT_V.
dash_opt_int() { # text min max
  [[ "$1" =~ ^[0-9]{1,5}$ ]] || return 1
  DASH_OPT_V=$((10#$1))
  [ "$DASH_OPT_V" -ge "$2" ] && [ "$DASH_OPT_V" -le "$3" ]
}
DASH_OPT_V=0

# Resolves a number: the environment variable when it holds a valid one (1 s to a day), else the config file (within min-max),
# else the default. Into DASH_OPT_V.
dash_opt_resolve() { # id env_name config_key min max default
  local env="${!2:-}"
  if dash_opt_int "$env" 1 86400; then DASH_OPT_ENV[$1]="$2"; return 0; fi
  dash_cfg_get "$3"
  dash_opt_int "$DASH_CFG_V" "$4" "$5" || DASH_OPT_V="$6"
}

# Reads the options when the panel starts (the theme and the language are resolved by their own layers).
dash_opts_load() {
  local lang="${DELTACTL_LANG:-}"
  DASH_OPT_ENV=()
  [ -z "${DELTACTL_THEME:-}" ] || DASH_OPT_ENV[theme]=DELTACTL_THEME
  if i18n_valid_lang "${lang,,}"; then DASH_OPT_ENV[lang]=DELTACTL_LANG; fi
  dash_opt_resolve refresh DELTACTL_REFRESH TUI_REFRESH 1 3600 5
  DASH_REFRESH_SECONDS="$DASH_OPT_V"
  dash_opt_resolve sample DELTACTL_METRICS_INTERVAL TUI_SAMPLE 1 60 2
  MT_INTERVAL_S="$DASH_OPT_V" MT_INTERVAL_US=""
  dash_cfg_get TUI_VIM
  case "${DASH_CFG_V,,}" in off | no | 0 | false) DASH_VIM=0 ;; *) DASH_VIM=1 ;; esac
  dash_cfg_get TUI_MOUSE
  case "${DASH_CFG_V,,}" in on | yes | 1 | true) tui_mouse 1 ;; *) tui_mouse 0 ;; esac
  dash_cfg_get TUI_PREREQ
  case "${DASH_CFG_V,,}" in off | no | 0 | false) DASH_PREREQ=0 ;; *) DASH_PREREQ=1 ;; esac
  # The new-instance wizard of steps is the one that opens; TUI_WIZARD=1 (or DELTACTL_WIZARD=1) brings back the old form.
  dash_cfg_get TUI_WIZARD
  case "${DELTACTL_WIZARD:-${DASH_CFG_V,,}}" in 1 | v1 | old | form) DASH_WIZARD=1 ;; *) DASH_WIZARD=2 ;; esac
  # The path as the screen shows it, worked out once: under the home it starts with ~, and a long one keeps its end (the part that
  # tells the file), so it never widens the box.
  local f
  f="$(i18n_config_file)"
  # shellcheck disable=SC2088  # a literal ~ on purpose: it is only shown, never used as a path
  [ -z "${HOME:-}" ] || [ "${f#"$HOME"/}" = "$f" ] || f="~/${f#"$HOME"/}"
  if [ "${#f}" -gt 48 ]; then
    if [ "$UI_UTF8" -eq 1 ]; then f="…${f: -47}"; else f="...${f: -45}"; fi
  fi
  DASH_OPT_FILE="$f"
}

# The next value of a list after the current one (dir +1) or before it (dir -1), staying at the ends. A current value that is not
# in the list (one given by an environment variable) moves to the nearest value in that direction. Into DASH_OPT_V.
dash_opt_step() { # current dir values...
  local cur="$1" dir="$2" v
  shift 2
  DASH_OPT_V="$cur"
  if [ "$dir" -gt 0 ]; then
    for v in "$@"; do if [ "$v" -gt "$cur" ]; then DASH_OPT_V="$v"; return 0; fi; done
  else
    for v in "$@"; do [ "$v" -ge "$cur" ] || DASH_OPT_V="$v"; done
  fi
}

dash_open_options() {
  DASH_OPT_SEL=0
  DASH_MODE=options
}

# Changes the option under the cursor one step (dir +1 / -1), applies it and remembers it.
dash_opt_change() { # dir
  local dir="$1" id="${DASH_OPT_IDS[$DASH_OPT_SEL]}" i n="${#TH_THEMES[@]}" cur=0
  case "$id" in
    theme)
      for i in "${!TH_THEMES[@]}"; do [ "${TH_THEMES[$i]}" != "$TH_NAME" ] || cur="$i"; done
      i="${TH_THEMES[$(((cur + n + dir) % n))]}"
      theme_apply "$i" || return 0
      th_save "$i"
      dash_theme_refresh
      dash_msg info "$(t tui.msg.theme_set "$TH_NAME")"
      ;;
    lang) dash_toggle_language ;;
    sample)
      dash_opt_step "$MT_INTERVAL_S" "$dir" "${DASH_OPT_SAMPLES[@]}"
      [ "$DASH_OPT_V" != "$MT_INTERVAL_S" ] || return 0
      MT_INTERVAL_S="$DASH_OPT_V" MT_INTERVAL_US=""
      dash_cfg_set TUI_SAMPLE "$DASH_OPT_V"
      dash_msg info "$(t tui.opt.set "$(t tui.opt.sample)" "$DASH_OPT_V s")"
      ;;
    refresh)
      dash_opt_step "$DASH_REFRESH_SECONDS" "$dir" "${DASH_OPT_REFRESHES[@]}"
      [ "$DASH_OPT_V" != "$DASH_REFRESH_SECONDS" ] || return 0
      DASH_REFRESH_SECONDS="$DASH_OPT_V"
      dash_cfg_set TUI_REFRESH "$DASH_OPT_V"
      dash_msg info "$(t tui.opt.set "$(t tui.opt.refresh)" "$DASH_OPT_V s")"
      ;;
    vim)
      DASH_VIM=$((1 - DASH_VIM))
      if [ "$DASH_VIM" -eq 1 ]; then dash_cfg_set TUI_VIM on; else dash_cfg_set TUI_VIM off; fi
      dash_msg info "$(t tui.opt.set "$(t tui.opt.vim)" "$(dash_opt_onoff "$DASH_VIM")")"
      ;;
    mouse)
      tui_mouse $((1 - TUI_MOUSE))
      if [ "$TUI_MOUSE" -eq 1 ]; then dash_cfg_set TUI_MOUSE on; else dash_cfg_set TUI_MOUSE off; fi
      dash_msg info "$(t tui.opt.set "$(t tui.opt.mouse)" "$(dash_opt_onoff "$TUI_MOUSE")")"
      ;;
    prereq)
      DASH_PREREQ=$((1 - DASH_PREREQ))
      if [ "$DASH_PREREQ" -eq 1 ]; then dash_cfg_set TUI_PREREQ on; else dash_cfg_set TUI_PREREQ off; fi
      dash_msg info "$(t tui.opt.set "$(t tui.opt.prereq)" "$(dash_opt_onoff "$DASH_PREREQ")")"
      ;;
  esac
  DASH_OPT_N=$((DASH_OPT_N + 1))
}

dash_opt_onoff() { if [ "$1" -eq 1 ]; then t tui.opt.on; else t tui.opt.off; fi; }

dash_key_options() { # key
  local n="${#DASH_OPT_IDS[@]}" k="$1"
  if [ "$DASH_VIM" -eq 1 ]; then case "$k" in k) k=up ;; j) k=down ;; h) k=left ;; l) k=right ;; esac; fi
  case "$k" in
    up) DASH_OPT_SEL=$(((DASH_OPT_SEL + n - 1) % n)) ;;
    down) DASH_OPT_SEL=$(((DASH_OPT_SEL + 1) % n)) ;;
    left) dash_opt_change -1 ;;
    right | enter | space) dash_opt_change 1 ;;
    esc | q | o | backspace) DASH_MODE=normal ;;
  esac
}

# Text of an option's current value.
dash_opt_value() { # id -> DASH_OPT_TXT
  case "$1" in
    theme) DASH_OPT_TXT="$TH_NAME" ;;
    lang) dt tui.lang_name; DASH_OPT_TXT="$DTV" ;;
    sample) DASH_OPT_TXT="${MT_INTERVAL_S:-2} s" ;;
    refresh) DASH_OPT_TXT="$DASH_REFRESH_SECONDS s" ;;
    vim) if [ "$DASH_VIM" -eq 1 ]; then dt tui.opt.on; else dt tui.opt.off; fi; DASH_OPT_TXT="$DTV" ;;
    mouse) if [ "$TUI_MOUSE" -eq 1 ]; then dt tui.opt.on; else dt tui.opt.off; fi; DASH_OPT_TXT="$DTV" ;;
    prereq) if [ "$DASH_PREREQ" -eq 1 ]; then dt tui.opt.on; else dt tui.opt.off; fi; DASH_OPT_TXT="$DTV" ;;
  esac
}
DASH_OPT_TXT=""

dash_dialog_options() { # body_height
  local i id acc lab val lt=' <' rt='> ' wl=0 l
  acc="${TH[accent]:-$C_CYN}"
  [ "$UI_UTF8" -ne 1 ] || { lt=' ‹'; rt='› '; }
  for id in "${DASH_OPT_IDS[@]}"; do dt "tui.opt.$id"; [ "${#DTV}" -le "$wl" ] || wl="${#DTV}"; done
  DASH_DLG=("")
  for i in "${!DASH_OPT_IDS[@]}"; do
    id="${DASH_OPT_IDS[$i]}"
    dt "tui.opt.$id"; dash_runs_padr "$DTV" "$wl"; lab="$DASH_PAD"
    dash_opt_value "$id"
    if [ "$i" -eq "$DASH_OPT_SEL" ]; then
      val="$acc$lt$C_OFF$C_BLD$DASH_OPT_TXT$C_OFF$acc$rt$C_OFF"
      DASH_DLG+=("$TUI_SEL$acc$UI_S_SEL$C_OFF $C_BLD$lab$C_OFF  $val")
    else
      DASH_DLG+=("  $lab   $DASH_OPT_TXT")
    fi
  done
  # What the option under the cursor does, and whether a variable overrides it when the panel starts.
  # (wrapped to 54 columns: the box keeps its 60 columns whatever row is selected, and fits an 80-column terminal)
  id="${DASH_OPT_IDS[$DASH_OPT_SEL]}"
  dt "tui.opt.desc.$id"
  dash_wrap "$DTV" 54
  DASH_DLG+=("")
  for l in "${DASH_WRAP[@]}"; do DASH_DLG+=("  $C_GRY$l$C_OFF"); done
  if [ -n "${DASH_OPT_ENV[$id]:-}" ]; then
    dt tui.opt.env
    dash_wrap "${DTV//\{1\}/"${DASH_OPT_ENV[$id]}"}" 54
    for l in "${DASH_WRAP[@]}"; do DASH_DLG+=("  $C_YEL$l$C_OFF"); done
  fi
  dt tui.opt.file; DASH_DLG+=("" "  $C_DIM${DTV//\{1\}/"$DASH_OPT_FILE"}$C_OFF" "")
  dt tui.opt.title
  dash_dialog "$1" "$DTV" 60
}

# --- The contract of lib/screens/registry.sh --------------------------------------------------------------------
scr_options_render() { dash_dialog_options "$2"; } # width height
scr_options_key() { dash_key_options "$1"; }
scr_options_keys() { # width
  local line
  dt tui.opt.keys; line="${DTV//\{1\}/$DASH_UD}"
  dash_keybar "${line//\{2\}/$DASH_LR}" "$1"; TUI_FRAME+=(" $DASH_KBV")
}
scr_options_sig() { DASH_SIG+="|$DASH_OPT_SEL|$DASH_OPT_N"; }

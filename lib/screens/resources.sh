#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # the DASH_* variables (DASH_KEYS, TUI_CURSOR...) are declared in lib/cmd/dashboard*.sh and shared by every screen
# Screen: Resources (view 2). Every service of every instance with memory, CPU and trend; `s` sorts them.

scr_resources_render() { dash_view_resources "$2"; } # width height
scr_resources_key() { dash_key_resources "$1"; }
scr_resources_keys() { dash_keys_view resources "$1"; } # width
scr_resources_texts() { DASH_KEYS[resources]="$(t tui.keys.resources "$DASH_UD" "$DASH_LR")"; }
scr_resources_sig() { DASH_SIG+="|$DASH_RES_SEL|$DASH_RES_SORT"; }

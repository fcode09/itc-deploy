#!/usr/bin/env bash
# shellcheck disable=SC2034  # the scene lists and the nameref targets are read by whoever sources this file
# Scenes of the UI kit: each one draws components with fixed sample data at a given width, as lines on stdout. They are the golden
# snapshots of tests/test-kit.sh and the pages of the gallery (tests/tools/gallery.sh). Sourced, never executed; needs ROOT, the
# bootstrap and lib/ui/tui.sh already loaded, and a theme applied.
# shellcheck source=lib/ui/kit/kit.sh
source "$ROOT/lib/ui/kit/kit.sh"

KIT_SCENES=(box_chips box_footer box_focus inset)
KIT_SCENES_GRAPHS=(graph_cpu graph_mirror meters metric_rows)

kit_scene_body() { # array-name count text   fills the array with sample lines
  local -n _b="$1"
  local i
  _b=()
  for ((i = 1; i <= $2; i++)); do _b+=("$3 $i"); done
}

scene_box_chips() { # width
  local w="$1" body=()
  kit_scene_body body 3 "linea"
  kit_box "$w" 5 body 'chips=1:cpu|^menu|^preset *' 'status=2000ms'
  printf '%s\n' "${KIT_BOX[@]}"
  kit_box "$w" 4 body 'chips=3:net|enp3s0' 'status=up 02:22:35'
  printf '%s\n' "${KIT_BOX[@]}"
  kit_box "$w" 4 body 'chips=4:proc|^filter|per-^core|^reverse|^tree|cpu ^lazy|^pause|a very long chip that cannot fit anywhere in this box'
  printf '%s\n' "${KIT_BOX[@]}"
  kit_box 12 4 body 'chips=1:cpu|menu' 'status=x'
  printf '%s\n' "${KIT_BOX[@]}"
}

scene_box_footer() { # width
  local w="$1" body=()
  kit_scene_body body 2 "fila"
  kit_box "$w" 4 body 'chips=4:proc' 'footer={↑} select|{↓} info|{Enter} ^terminate|^kill|^signals|^Nice|^Follow'
  printf '%s\n' "${KIT_BOX[@]}"
  kit_box 40 4 body 'chips=1:s0' 'footer={↑} select|{↓} info|{Enter} ^terminate|^kill|^signals|^Nice|^Follow'
  printf '%s\n' "${KIT_BOX[@]}"
  kit_box 26 4 body 'chips=1:s0' 'footer=^a one|^b two|^c three|^d four'
  printf '%s\n' "${KIT_BOX[@]}"
}

scene_box_focus() { # width
  local w="$1" body=()
  kit_scene_body body 2 "fila"
  body[1]="${TUI_SEL}fila seleccionada"
  kit_box "$w" 4 body 'chips=1:lista|^filtro' 'focus=1' 'footer={Enter} abrir|^n nueva'
  printf '%s\n' "${KIT_BOX[@]}"
  kit_box "$w" 4 body 'chips=2:detalle|^filtro' 'footer={Enter} abrir|^n nueva'
  printf '%s\n' "${KIT_BOX[@]}"
}

scene_inset() { # width
  local w="$1" base=() ins=() i line
  for ((i = 0; i < 8; i++)); do
    printf -v line '%*s' "$w" ''
    base+=("${line// /.}")
  done
  kit_scene_body ins 3 "CPU"
  kit_box 24 5 ins 'chips=i7-4770' 'status=3.8 GHz'
  local box=("${KIT_BOX[@]}")
  kit_overlay base 1 box $((w - 26))
  printf '%s\n' "${base[@]}"
  kit_overlay base 6 box 0
  printf '%s\n' "${base[@]:5:3}"
}

# A deterministic series of N samples between 0 and 100 (a wave with a burst), oldest first.
kit_scene_series() { # count seed -> KS
  local n="$1" seed="${2:-7}" i v out=""
  for ((i = 0; i < n; i++)); do
    v=$(((i * 37 + seed * 11 + (i % 7) * 9 + (i / 5) * 3) % 70))
    if [ $((i % 23)) -ge 18 ]; then v=$((v + 30)); fi
    out+="${out:+ }$v"
  done
  KS="$out"
}

scene_graph_cpu() { # width
  local w="$1" gw=$(($1 - 4)) body=() i
  kit_scene_series $((gw * 2)) 3
  kit_graph "$KS" 100 "$gw" 6 mag=cpu axis=1 unit=%
  body=("${KG_LINES[@]}")
  kit_box "$w" 8 body 'chips=1:cpu|^menu|^preset *' 'status=2000ms' 'footer={↑} select|{Enter} ^info|^kill'
  printf '%s\n' "${KIT_BOX[@]}"
  kit_graph "$KS" 100 "$gw" 3 mag=mem
  body=("${KG_LINES[@]}")
  kit_box "$w" 5 body 'chips=2:mem'
  printf '%s\n' "${KIT_BOX[@]}"
}

scene_graph_mirror() { # width
  local w="$1" gw=$(($1 - 4)) body=()
  kit_scene_series $((gw * 2)) 5; local up="$KS"
  kit_scene_series $((gw * 2)) 9; local down="$KS"
  kit_graph_mirror "$up" "$down" auto "$gw" 3 3 axis=1 unit=B
  body=("${KG_LINES[@]}")
  kit_box "$w" 8 body 'chips=3:net|enp3s0' 'status=sync auto'
  printf '%s\n' "${KIT_BOX[@]}"
}

scene_meters() { # width
  local w="$1" mw=$(($1 / 3)) body=() p
  for p in 0 7 25 43 61 86 100; do
    kit_meter "$p" "$mw" mem; body+=("$p% $KIT_OUT")
  done
  kit_meter 86 "$mw" disk caps=1; body+=("caps $KIT_OUT")
  kit_box "$w" 11 body 'chips=2:disks' 'status=7 meters'
  printf '%s\n' "${KIT_BOX[@]}"
}

scene_metric_rows() { # width
  local w="$1" cw=$(($1 / 2 - 3)) left=() right=()
  kit_scene_series $((cw * 2)) 4
  kit_metric_row "Used" "5.62 GiB" 49 "$KS" 100 "$cw" 3 mem; left=("${KM_LINES[@]}")
  kit_scene_series $((cw * 2)) 8
  kit_metric_row "Available" "5.89 GiB" 51 "$KS" 100 "$cw" 3 disk; left+=("${KM_LINES[@]}")
  kit_leader "root" "204 GiB" "$cw"; right+=("$KIT_OUT")
  kit_meter 86 "$cw" disk; right+=("Used 86% $KIT_OUT")
  kit_meter 14 "$cw" disk; right+=("Free 14% $KIT_OUT")
  kit_box $((w / 2)) 12 left 'chips=2:mem'
  local lbox=("${KIT_BOX[@]}")
  kit_box $((w - w / 2)) 12 right 'chips=disks'
  local i
  for ((i = 0; i < 12; i++)); do printf '%s%s\n' "${lbox[$i]}" "${KIT_BOX[$i]}"; done
}

kit_scene() { # name width
  "scene_$1" "$2"
}

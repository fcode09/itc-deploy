#!/usr/bin/env bash
# Scenes of the UI kit: each one draws components with fixed sample data at a given width, as lines on stdout. They are the golden
# snapshots of tests/test-kit.sh and the pages of the gallery (tests/tools/gallery.sh). Sourced, never executed; needs ROOT, the
# bootstrap and lib/ui/tui.sh already loaded, and a theme applied.
# shellcheck source=lib/ui/kit/kit.sh
source "$ROOT/lib/ui/kit/kit.sh"

KIT_SCENES=(box_chips box_footer box_focus inset)

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

kit_scene() { # name width
  "scene_$1" "$2"
}

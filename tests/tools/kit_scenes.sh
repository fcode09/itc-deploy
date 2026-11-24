#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2178,SC2128  # the scene lists and the nameref targets are read by whoever sources this file
# Scenes of the UI kit: each one draws components with fixed sample data at a given width, as lines on stdout. They are the golden
# snapshots of tests/test-kit.sh and the pages of the gallery (tests/tools/gallery.sh). Sourced, never executed; needs ROOT, the
# bootstrap and lib/ui/tui.sh already loaded, and a theme applied.
# shellcheck source=lib/ui/kit/kit.sh
source "$ROOT/lib/ui/kit/kit.sh"

KIT_SCENES=(box_chips box_footer box_focus inset)
KIT_SCENES_GRAPHS=(graph_cpu graph_mirror meters metric_rows)
KIT_SCENES_FORMS=(stepper tabs fields table checklist toast_modal vpick)

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

scene_stepper() { # width
  local w="$1"
  kit_stepper "$w" 3 "counter=Paso 3 de 8" Nombre Servicios Versiones Datos Variables Secretos Acceso Revisión
  printf '%s\n' "${KS_LINES[@]}"
  echo
  kit_stepper "$w" 5 "counter=Paso 5 de 8" Nombre Servicios Versiones:warn Datos Variables:err Secretos Acceso Revisión
  printf '%s\n' "${KS_LINES[@]}"
  echo
  kit_stepper 40 4 "counter=Paso 4 de 8" Nombre Servicios Versiones Datos Variables Secretos Acceso Revisión
  printf '%s\n' "${KS_LINES[@]}"
  echo
  kit_stepper 24 2 Uno Dos Tres
  printf '%s\n' "${KS_LINES[@]}"
}

scene_tabs() { # width
  local w="$1"
  kit_tabs "$w" 1 Resumen Servicios Variables Datos Acceso Logs Historial; printf '%s\n' "$KT_LINE"
  kit_tabs "$w" 3 Resumen Servicios ^Variables Datos Acceso Logs Historial; printf '%s\n' "$KT_LINE"
  kit_tabs "$w" 7 Resumen Servicios Variables Datos Acceso Logs Historial; printf '%s\n' "$KT_LINE"
  kit_tabs 30 4 Resumen Servicios Variables Datos Acceso Logs Historial; printf '%s\n' "$KT_LINE"
  kit_tabs 30 7 Resumen Servicios Variables Datos Acceso Logs Historial; printf '%s\n' "$KT_LINE"
}

scene_fields() { # width
  local w="$1" body=() fw=$(($1 - 4))
  kit_field_render "Nombre" "colorado" 8 "$fw" label_width=12 focus=1 state=ok msg=disponible; body+=("$KIT_OUT")
  kit_field_render "Nombre" "Colorado!" 3 "$fw" label_width=12 state=err msg="a-z 0-9 -"; body+=("$KIT_OUT")
  kit_field_render "Puerto" "" 0 "$fw" label_width=12 placeholder="4100" state=pend; body+=("$KIT_OUT")
  kit_field_render "S0_PORT" "4100" 2 "$fw" label_width=12 focus=1 unit="(libre)" state=ok; body+=("$KIT_OUT")
  kit_field_render "JWT_SECRET" "supersecreto" 0 "$fw" label_width=12 mask=1 state=ok msg=generado; body+=("$KIT_OUT")
  kit_field_render "JWT_SECRET" "supersecreto" 0 "$fw" label_width=12 mask=1 reveal=1 state=ok; body+=("$KIT_OUT")
  kit_field_render "MONGO_URI" "mongodb://host.docker.internal:27017/authsoftware2021?replicaSet=rs0&readPreference=primary" 40 "$fw" label_width=12 focus=1 state=warn msg="usa host.docker.internal"; body+=("$KIT_OUT")
  kit_box "$w" 9 body 'chips=1:variables|^editar' 'footer={Enter} ^editar|^g generar|^r revelar'
  printf '%s\n' "${KIT_BOX[@]}"
}

scene_table() { # width
  local w="$1" cols=() rows=() sep=$'\x1f' tw=$(($1 - 4)) body
  cols=("SVC|5|l" "IMAGEN|*|l" "ESTADO|10|l" "MEM MB|7|r|num" "CPU|5|r|num" "TENDENCIA|12|l|spark")
  rows=("s0${sep}auth-backend:2.14.1${sep}healthy${sep}196${sep}3%${sep}5 12 8 20 33 41 30 22 18 25 31 28"
        "s1${sep}gueo-back-end:2.9.0${sep}healthy${sep}1230${sep}21%${sep}60 70 80 90 85 70 60 65 75 80 88 92"
        "s0${sep}auth-backend:2.13.2${sep}unhealthy${sep}180${sep}1%${sep}1 1 2 1 1 3 2 1 1 2 1 1"
        "s1${sep}gueo-back-end:2.8.0${sep}stopped${sep}-${sep}-${sep}0 0 0")
  kit_table "$tw" 6 cols rows sel=1 sort=3:desc mag=cpu
  body=("${KTB_LINES[@]}")
  kit_box "$w" 8 body "chips=2:servicios|^filtro" "status=$KTB_COUNT" 'footer={↑} elegir|{Enter} abrir|^s ordenar'
  printf '%s\n' "${KIT_BOX[@]}"
  kit_table "$tw" 4 cols rows sel=0 filter=auth empty="sin coincidencias"
  body=("${KTB_LINES[@]}")
  kit_box "$w" 6 body "chips=2:servicios|filtro: auth" "status=$KTB_COUNT"
  printf '%s\n' "${KIT_BOX[@]}"
  kit_table "$tw" 3 cols rows sel=3 filter=zzz empty="sin coincidencias"
  body=("${KTB_LINES[@]}")
  kit_box "$w" 5 body "chips=2:servicios|filtro: zzz" "status=$KTB_COUNT"
  printf '%s\n' "${KIT_BOX[@]}"
}

scene_checklist() { # width
  local w="$1" items=() body=()
  items=("err|Variables obligatorias|IP_SERVER, DEEPGRAM_API_KEY|completar"
         "err|Archivos de secretos|fcm.json, keeper-fcm.json|añadir"
         "ok|Versiones elegidas|s0 2.14.1 · s1 2.9.0|"
         "pend|Comprobación (check)|sin ejecutar|ejecutar"
         "pend|Datos iniciales (init)|sin sembrar|sembrar"
         "run|Despliegue|en curso 00:12|")
  kit_checklist $((w - 4)) items sel=1
  body=("${KCK_LINES[@]}")
  kit_box "$w" 8 body "chips=1:Para desplegar" "status=$KCK_OK de $KCK_TOTAL listos" 'footer={Enter} resolver|^u desplegar'
  printf '%s\n' "${KIT_BOX[@]}"
}

scene_toast_modal() { # width
  local w="$1" base=() i line
  KIT_NOW=100 kit_toast_set ok "S0_TAG guardado" 3
  KIT_NOW=101 kit_toast_line "$w"; printf '[%s]\n' "$KIT_OUT"
  KIT_NOW=105 kit_toast_line "$w"; printf '[%s]\n' "$KIT_OUT"
  KIT_NOW=100 kit_toast_set err "no se pudo escribir .env.s0" 3
  KIT_NOW=101 kit_toast_line "$w"; printf '[%s]\n' "$KIT_OUT"
  for ((i = 0; i < 14; i++)); do printf -v line '%*s' "$w" ''; base+=("${line// /·}"); done
  kit_modal_confirm 44 "Rollback" "Vuelve a las etiquetas del despliegue anterior de colorado (s0 2.13.2, s1 2.8.0). Los datos no se tocan." yes=Aceptar no=Cancelar sel=no
  local m1=("${KIT_BOX[@]}")
  kit_center base m1
  printf '%s\n' "${base[@]}"
  base=()
  for ((i = 0; i < 14; i++)); do printf -v line '%*s' "$w" ''; base+=("${line// /·}"); done
  kit_modal_name 50 "Sembrar datos" "init VACÍA y vuelve a crear las colecciones de colorado. No se puede deshacer." colorado colo 4 "prompt=Escribe el nombre para confirmar:"
  local m2=("${KIT_BOX[@]}")
  kit_center base m2
  printf '%s\n' "${base[@]}"
}

scene_vpick() { # width
  local w="$1" rec=() body=() sep=$'\x1f' tw=$(($1 - 4)) texts
  rec=("2.14.1${sep}2 days ago${sep}412MB${sep}amd64${sep}${sep}star"
       "2.14.0${sep}9 days ago${sep}410MB${sep}amd64${sep}colorado(current)${sep}"
       "2.13.2${sep}1 month ago${sep}408MB${sep}amd64${sep}colorado(previous)${sep}"
       "3.0.0-rc1${sep}3 hours ago${sep}420MB${sep}arm64${sep}${sep}foreign"
       "latest${sep}5 days ago${sep}412MB${sep}amd64${sep}lima(current)${sep}mutable")
  # the star, with the hint of the most recent one
  kit_vpick "$tw" 9 rec sel=0 server_arch=amd64
  body=("${KVP_LINES[@]}")
  kit_box "$w" 11 body "chips=3:versions of auth-backend|filter" "status=$KVP_COUNT" 'footer={Enter} choose|^t write another|^l load|{Esc} cancel' focus=1
  printf '%s\n' "${KIT_BOX[@]}"
  # an image that cannot run says why; the tag that moves warns
  kit_vpick "$tw" 8 rec sel=3 server_arch=amd64
  body=("${KVP_LINES[@]}")
  kit_box "$w" 10 body "chips=3:versions of auth-backend" "status=$KVP_COUNT"
  printf '%s\n' "${KIT_BOX[@]}"
  kit_vpick "$tw" 8 rec sel=4 server_arch=amd64
  body=("${KVP_LINES[@]}")
  kit_box "$w" 10 body "chips=3:versions of auth-backend" "status=$KVP_COUNT"
  printf '%s\n' "${KIT_BOX[@]}"
  # typing a version that is not loaded; filter; loading a file; nothing loaded
  kit_vpick "$tw" 8 rec sel=5 typing=1 typed=2.15.0 cursor=6 server_arch=amd64
  body=("${KVP_LINES[@]}")
  kit_box "$w" 10 body "chips=3:versions of auth-backend" "status=$KVP_COUNT" focus=1
  printf '%s\n' "${KIT_BOX[@]}"
  kit_vpick "$tw" 6 rec sel=0 filter=colorado note="2.13.2 was created after 2.14.0" server_arch=amd64
  body=("${KVP_LINES[@]}")
  kit_box "$w" 8 body "chips=3:versions of auth-backend|filter: colorado" "status=$KVP_COUNT"
  printf '%s\n' "${KIT_BOX[@]}"
  kit_vpick "$tw" 6 rec sel=6 status="loading app.tar" server_arch=amd64
  body=("${KVP_LINES[@]}")
  kit_box "$w" 8 body "chips=3:versions of auth-backend" "status=$KVP_COUNT"
  printf '%s\n' "${KIT_BOX[@]}"
  rec=()
  kit_vpick "$tw" 5 rec sel=0
  body=("${KVP_LINES[@]}")
  kit_box "$w" 7 body "chips=3:versions of auth-backend" "status=$KVP_COUNT"
  printf '%s\n' "${KIT_BOX[@]}"
}

kit_scene() { # name width
  "scene_$1" "$2"
}

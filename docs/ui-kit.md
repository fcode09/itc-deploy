# Kit de interfaz del panel

Componentes de dibujo reutilizables del panel (`lib/ui/kit/*.sh`). Son **funciones puras**: reciben datos y dejan líneas en una variable
`KIT_*`/`KG_*`; no guardan estado de negocio ni lanzan procesos, así que una vista puede guardar su resultado en la caché por panel
(`dash_pc_get`/`dash_pc_put`). Se cargan con `lib/ui/kit/kit.sh` (el panel y `tests/tools/gallery.sh` lo hacen) después de `lib/ui/tui.sh` y
`lib/ui/tokens.sh`. Colores y símbolos salen de los *tokens* del tema (`lib/ui/theme.sh`, `lib/ui/tokens.sh`), nunca de un color suelto.

## Marcado de etiquetas

| Marca | Significa |
| --- | --- |
| `^p` | la letra `p` es el atajo: va en el color `hotkey` del tema y en negrita |
| `{Enter}` | un nombre de tecla entero, resaltado igual |
| `^^`, `{{` | un `^` o una `{` literales |
| `N:texto` (solo en chips) | un dígito `N` antes de `:` es la tecla que enfoca el recuadro; se dibuja como superíndice (`¹cpu`) |

`kit_plain` quita la marca y `kit_hotkey texto [color-base]` la resuelve. Sin color el texto queda igual, sin la marca.

## Recuadro con chips (`lib/ui/kit/box.sh`)

```
kit_box <ancho> <alto> <array> [chips=a|b] [status=txt] [footer=a|b] [focus=1] [color=<esc>]
```

- `chips=` va en el borde superior (`╭─┐¹cpu┌─┐menú┌───╮`); lo que no cabe se quita **desde el final** (el título se queda).
- `status=` es un chip a la derecha del borde superior; es lo primero que se quita si falta sitio.
- `footer=` son las acciones del borde inferior (`╰─┘↑ elegir└─┘Enter abrir└───╯`); lo que no cabe se quita **entero**: se quedan los
  primeros y los dos últimos (cómo moverse, y ayuda/salir).
- `focus=1` usa el color de borde de foco y pinta el primer chip como insignia (sin color, con `▸` delante).
- El cuerpo es el array de líneas (las que empiezan por `TUI_SEL` son la fila seleccionada). El resultado queda en `KIT_BOX`:
  exactamente `<alto>` líneas de `<ancho>` celdas.
- `kit_overlay <base> <fila> <inset> <columna>` coloca un recuadro (inset) encima de otro dibujo, conservando colores (`kit_slice` corta por
  celdas visibles y repone los colores activos).

Escenas de ejemplo con datos fijos: `tests/tools/kit_scenes.sh` (son las instantáneas de `tests/test-kit.sh`, en `tests/golden/kit/`, y las
páginas de la galería `tests/tools/gallery.sh`).

## Gráficas (`graph_braille.sh`)

```
kit_graph <hist> <max|auto> <ancho> <filas> [mag=<magnitud>] [invert=1] [zero=1] [axis=1] [unit=<txt>] [mode=braille|blocks|ascii]
kit_graph_cached <id> <hist> <max|auto> <ancho> <filas> [opciones]     # con caché incremental (id: letras, dígitos y _)
kit_graph_mirror <hist-arriba> <hist-abajo> <max|auto> <ancho> <filas-arriba> <filas-abajo> [opciones]
kit_scale <hist> [suelo]     # KG_MAX: el menor de 1, 2, 5 x 10^n que contiene el máximo
kit_si <valor>               # KIT_OUT: 950, 1.5K, 10M
```

- Cada celda braille lleva **dos muestras** (columna izquierda y derecha) con 0–4 puntos cada una; las 25 combinaciones se construyen una vez
  (`KBR` normal, `KBI` invertida, índice `izq*5+der`). Con `invert=1` cuelga de arriba; `kit_graph_mirror` pone una serie hacia arriba y otra
  hacia abajo con la misma escala (descarga/subida de btop).
- El historial son enteros separados por espacios, el más antiguo primero; la muestra más reciente va al borde derecho y un historial corto
  empieza en blanco por la izquierda. `zero=1` dibuja un punto para el valor 0 (la línea base de una gráfica en reposo).
- **Color por altura**: cada fila toma el color del degradado de `mag=` en el porcentaje que esa fila representa (filas bajas = extremo frío),
  así un servicio tranquilo nunca parece una alarma. Sin color, la altura lo dice.
- **Reserva**: braille en un terminal UTF-8; `DELTACTL_GRAPH=blocks` (o `TUI_GRAPH=blocks`) fuerza bloques de octavos; con `LANG=C`, ASCII.
- **Caché**: la gráfica con caché mueve una **celda cada dos muestras**: una muestra nueva rellena la mitad derecha de la última celda o desliza
  una celda a la izquierda; solo cambia la última celda de cada fila (coste ~2 ms a 120x8). Cualquier otro cambio (escala, tamaño, historial que
  no llena la gráfica) la redibuja entera (~25 ms a 120x8, en un equipo cargado).

## Medidores y filas de métrica (`meter.sh`, `metric_row.sh`)

```
kit_meter <porcentaje> <ancho> [magnitud] [caps=1]       # KIT_OUT, exactamente <ancho> celdas
kit_leader <etiqueta> <valor> <ancho>                    # KIT_OUT: etiqueta ····· valor
kit_metric_row <etiqueta> <valor> <%> <hist> <max|auto> <ancho> <filas-gráfica> [magnitud]   # KM_LINES
```

- El medidor dibuja lo lleno en octavos de celda, con el color de cada celda según su posición en el degradado de la magnitud, y la pista
  tenue detrás (`░`). Se recuerda por (magnitud, %, ancho, tema).
- `kit_leader` recorta la etiqueta con `…` antes de perder el valor.

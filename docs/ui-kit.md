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

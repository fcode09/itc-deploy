# Panel en vivo: guía de uso

`./deltactl` sin argumentos, en una terminal, abre el panel: el estado de todas las instancias, su consumo, sus logs y lo que
se está ejecutando, actualizado solo. Fuera de una terminal (una tubería, `TERM=dumb`) muestra la pantalla de inicio en texto.

`?` muestra todas las teclas (con la sección de la vista en la que estás resaltada) y `q` sale.

## Las vistas

| Tecla | Vista | Para qué |
| --- | --- | --- |
| `1` | Instancias | La lista de instancias, el detalle de la seleccionada (servicios, memoria, CPU, errores), sus gráficos y sus logs en vivo, y la consola debajo |
| `2` | Recursos | Todos los servicios de todas las instancias en una tabla; `s` ordena por nombre, memoria o CPU |
| `3` | Salida | La salida completa del último comando |
| `4` | Ejecuciones | El historial de operaciones (deploy, init, rollback...) con su consumo, la comparación con las anteriores y sus logs guardados |
| `5` | Procesos | De qué está hecho el comando que se está ejecutando y cuánto cuesta el propio panel |
| `6` | Consola | La consola a pantalla completa, lista para escribir |

Tab y Mayús+Tab recorren las vistas (en Instancias, los paneles: lista, servicios y logs). Esc vuelve un paso atrás.

## Lo más habitual

- **Ver una instancia**: ↑↓ (o `k` `j`) eligen la instancia, → entra en sus servicios, otra → en sus logs. `z` amplía el panel
  con el foco a toda la pantalla.
- **Actuar sobre ella**: Enter abre el menú de acciones (estado, comprobar, desplegar, rollback, logs, parar...). Atajos directos:
  `u` despliega, `c` comprueba, `s` muestra el estado, `l` sigue los logs del servicio.
- **Buscar cualquier acción**: Ctrl+P abre la paleta; escribe parte del nombre ("despl", "logs", "tema") y Enter.
- **Escribir un comando**: `:` da el teclado a la consola; escribe cualquier comando de deltactl sin el prefijo
  (`status colorado`, `logs colorado s0 -f`). `!` delante lo ejecuta en la terminal; `!` solo abre una shell. En la vista `6` la
  línea siempre está lista.
- **Cancelar**: `x` (o Ctrl+C) para el comando en curso.
- **Logs de un servicio**: con el foco en ellos, Espacio pausa, `f` vuelve a seguir el final, `e` deja solo errores y avisos, `/`
  filtra, `s` busca (`[` y `]` saltan entre coincidencias).

## Alias de la consola

Para las órdenes que repites:

```
alias up=deploy colorado      # define "up"
up                            # ejecuta "deploy colorado"
alias lg=logs colorado        # el resto de la línea va detrás:
lg s0 -f                      # ejecuta "logs colorado s0 -f"
alias                         # los lista
unalias up                    # borra uno
```

Se guardan junto al historial (`~/.config/deltactl/aliases`). Solo admiten comandos de deltactl y del panel: uno que empiece por
`!` se rechaza.

## Opciones (`o`)

Tema, idioma, cada cuánto se leen las cifras, cada cuánto se relee el estado sin eventos de Docker, teclas vim y ratón. Cada cambio
se aplica al momento y se guarda en `~/.config/deltactl/config`. Las variables `DELTACTL_THEME`, `DELTACTL_LANG`,
`DELTACTL_METRICS_INTERVAL` y `DELTACTL_REFRESH` mandan al arrancar (la pantalla lo indica).

- **Teclas vim** (activadas por defecto): `j k h g G` se mueven como las flechas, Inicio y Fin.
- **Ratón** (desactivado por defecto): clic en una pestaña abre su vista; en una instancia la selecciona y un segundo clic abre sus
  acciones; la rueda desplaza. Mientras está activo, el texto se selecciona con Mayús.

También: `T` cambia de tema, `L` de idioma, `p` pausa la actualización, `r` refresca, `n` crea una instancia, `d` diagnóstico,
`i` imágenes.

## Terminales

- Mínimo 60 columnas x 14 filas; desde 120x28 aparece la vista ancha (con gráficos, logs y, desde 150 columnas, eventos).
- Funciona con `xterm`, `xterm-256color`, `screen`/`tmux`, la consola de Linux y `vt100`; con `LANG=C` dibuja en ASCII; con
  `NO_COLOR` sin colores; con color real si el terminal lo anuncia (`COLORTERM=truecolor`). `tests/tools/pty_matrix.py` lo
  comprueba en un pseudo-terminal real contra un Docker simulado.
- Al salir (`q`, Esc desde Instancias o Ctrl+C dos veces) deja la terminal como estaba.

Detalle técnico, decisiones y consumo medido: [panel-pendiente.md](panel-pendiente.md).

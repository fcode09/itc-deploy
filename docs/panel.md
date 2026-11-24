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
| `7` | Servidor | Qué necesita el servidor para funcionar (con el comando para instalarlo) y cómo va: CPU, memoria, discos, red y contenedores |

Tab y Mayús+Tab recorren las vistas (en Instancias, los paneles: lista, servicios y logs). Esc vuelve un paso atrás.

## Lo más habitual

- **Ver una instancia**: ↑↓ (o `k` `j`) eligen la instancia, → entra en sus servicios, otra → en sus logs. `z` amplía el panel
  con el foco a toda la pantalla.
- **Actuar sobre ella**: Enter abre el menú de acciones (estado, comprobar, desplegar, rollback, logs, parar...). Atajos directos:
  `u` despliega, `c` comprueba, `s` muestra el estado, `l` sigue los logs del servicio.
- **Buscar cualquier acción**: Ctrl+P abre la paleta; escribe parte del nombre ("despl", "logs", "tema") y Enter.
- **Crear una instancia**: `n` (o Enter sobre «+ Nueva instancia», o `new` en la consola) abre el formulario de nueva
  instancia dentro del panel. A la izquierda están las secciones (Nombre, Servicios, Datos, Imágenes, Acceso y Resumen), cada una
  con un icono al inicio de su fila que dice cómo va (● lista, ▲ falta algo opcional, ✖ error, ○ pendiente); a la derecha, los
  campos de la sección elegida. El nombre viene propuesto (`instancia-N`): escribe encima para cambiarlo. En Servicios marcas con
  Espacio cuáles desplegar y ves, de cada uno, si su imagen está cargada en Docker y si su puerto está libre. Los campos se validan
  al escribir. ↑ ↓ recorren los campos y pasan a la sección vecina al llegar al borde; Enter sigue; PgUp/PgDn cambian de sección;
  Tab da el teclado a la lista de secciones (allí, `c` crea); Esc vuelve a la lista y, desde ella, cancela. Con menos de 92
  columnas o 20 filas solo se dibujan los campos (Tab cambia de sección). Al crear, el panel ejecuta `new` con las respuestas como
  opciones y la salida queda en la consola; si falta algo obligatorio (nombre, servicios o imagen válida), te lleva a esa sección.
  Con `!` delante (`!new --wizard`) el asistente sigue disponible en el terminal.
- **Escribir un comando**: `:` da el teclado a la consola; escribe cualquier comando de deltactl sin el prefijo
  (`status colorado`, `logs colorado s0 -f`). `!` delante lo ejecuta en la terminal; `!` solo abre una shell. En la vista `6` la
  línea siempre está lista.
- **Cancelar**: `x` (o Ctrl+C) para el comando en curso.
- **Logs de un servicio**: con el foco en ellos, Espacio pausa, `f` vuelve a seguir el final, `e` deja solo errores y avisos, `/`
  filtra, `s` busca (`[` y `]` saltan entre coincidencias).

## Servidor y requisitos (`7`)

Arriba está la lista de lo que necesita el servidor, con un icono por requisito (● listo, ▲ falta algo recomendado o con aviso, ✖ error,
○ espera a otro, ◐ comprobando) y, en dos columnas desde 120 columnas, **obligatorios** (Docker, acceso al daemon, Compose 2.20, disco,
memoria, MongoDB, `ss`, `openssl`, `gunzip`) y **recomendados** (límite de archivos de `mongod`, nginx o Caddy, `certbot`, hora sincronizada,
cortafuegos, `curl`). Es la misma lista que usa `./deltactl doctor` ([server-prerequisites.md](server-prerequisites.md)). Debajo, en cajas como
las de btop: CPU (gráfica braille del total y, encima, una caja con cada núcleo y la carga), memoria por tipo (usada, disponible, total, caché,
libre y swap), discos con su barra de uso, red con la gráfica espejo (bajada arriba, subida abajo) y, desde 120 columnas, los contenedores.
Lo que el sistema no da (WSL, un contenedor) se ve como «no disponible en este sistema».

- **↑ ↓** eligen un requisito; debajo de la lista se ve para qué sirve, qué dijo la comprobación y cómo arreglarlo (el comando de tu
  distribución: apt, dnf, pacman o apk, según `/etc/os-release`; si el requisito no se instala con un paquete, lo que aconseja la comprobación).
- **Enter** abre el detalle completo (cada resultado con su consejo, el comando de cada gestor si la distribución no se reconoce y la página
  de la guía); Enter o Esc lo cierran.
- **c** copia el comando (al portapapeles del escritorio con `wl-copy`, `xclip`, `xsel` o `pbcopy`; si no hay, al del terminal con OSC 52; si
  tampoco, lo muestra para que lo selecciones).
- **!** lo ejecuta en la terminal, **después de preguntar**: la ventana muestra el comando entero y solo `y` lo lanza (ahí `sudo` pide la
  contraseña). El panel **nunca instala nada por su cuenta**. Al volver se comprueban de nuevo los requisitos.
- **m** deja solo las cifras del servidor (los requisitos ceden su sitio; a 80x24 es la forma de ver los discos y la red); **R** vuelve a
  comprobar. Los requisitos se comprueban solos cada 30 s mientras la vista está a la vista.
- Las cifras del servidor (CPU por núcleo, temperatura, red, discos) solo se leen mientras esta vista es la actual.

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

**En reposo**: tras 30 s sin tocar el teclado (y sin ningún comando en marcha) las cifras se leen la mitad de veces y el recuento de
errores cada 2 minutos; la primera tecla vuelve al ritmo normal y toma una muestra al momento. `DELTACTL_TUI_IDLE_AFTER` cambia
esos 30 s.

## Terminales

- Mínimo 60 columnas x 14 filas; desde 120x28 aparece la vista ancha (con gráficos, logs y, desde 150 columnas, eventos). Con siete vistas,
  a 80 columnas la línea de pestañas deja solo el número de las que no están activas.
- Funciona con `xterm`, `xterm-256color`, `screen`/`tmux`, la consola de Linux y `vt100`; con `LANG=C` dibuja en ASCII; con
  `NO_COLOR` sin colores; con color real si el terminal lo anuncia (`COLORTERM=truecolor`). `tests/tools/pty_matrix.py` lo
  comprueba en un pseudo-terminal real contra un Docker simulado.
- Al salir (`q`, Esc desde Instancias o Ctrl+C dos veces) deja la terminal como estaba.

Detalle técnico, decisiones y consumo medido: [panel-pendiente.md](panel-pendiente.md).

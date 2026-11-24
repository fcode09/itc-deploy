# Panel en vivo: qué hay, cómo probarlo y qué falta

Documento para retomar el trabajo del panel interactivo de `deltactl` (rama `feat/live-panel`, fusionada en `develop`).

## Qué hay hecho

Un panel de una sola pantalla (`./deltactl` en una terminal, o `./deltactl menu`) con cinco vistas (`1` a `5` o Tab):

- **Instancias**: lista con `n/m`, memoria y CPU; detalle de la seleccionada (por servicio: imagen, estado, tiempo activo, puerto,
  reinicios, memoria y CPU con barra y tendencia, errores de los últimos 10 min, siguientes pasos) y el panel de salida del último comando.
- **Recursos**: todos los servicios de todas las instancias con memoria, CPU, tendencia, reinicios y tiempo activo; orden con `s`.
- **Salida**: el último comando. Los que tienen forma (`new`, `check`, `deploy`, `init`, `doctor`, `images`, `env`, `rollback`, `adopt`) se muestran como resumen (ver «El resumen de la Salida» abajo); `v` alterna con la salida cruda, que es la que se ve siempre para cualquier otro comando. Desplazamiento (`↑↓`, PgUp/PgDn, Home/End), `f` para seguir y `e` solo errores (siempre sobre la salida cruda).
- **Ejecuciones** (`4`): el historial de las operaciones que cambian algo (`lib/core/runs.sh`). Lista (las que están en curso primero,
  luego las más nuevas), y de la seleccionada: estado y código, comparación con la anterior correcta de la misma operación y con la
  media de las cinco anteriores (duración, CPU, docker, memoria pico), consumo, contenedores antes y después y el final de su salida
  (PgUp/PgDn desplazan el detalle). `t` da las estadísticas por operación (`s` las limita a una instancia) y `Enter` abre su salida
  guardada en un visor paginado: un log de cualquier tamaño se indexa una vez (un punto de control por cada 500 líneas, en segundo
  plano a partir de 8 MiB) y cada página se lee desde el punto de control más cercano, así que la memoria no crece con el log.
- **Logs de un servicio** (vista Instancias en pantalla ancha, o `z` para ampliarlos; `lib/screens/instances_logs.sh`): mientras el panel de
  logs se ve y el servicio corre, un `docker logs --tail 200 -f` escribe en un fichero temporal y el panel lo lee (no por tubería: bash lee
  una tubería byte a byte, ~500 µs por línea, y un fichero por bloques, ~20 µs). Se mata al dejar de verse, al cambiar de servicio (el
  nuevo arranca como mucho cada 300 ms) y al salir. Anillo de 1500 líneas; la pantalla se actualiza cada segundo con el foco y cada 2 s
  sin él; el fichero se vacía al pasar de 4 MiB. Sin flujo (servicio parado, sin Docker) se sondea `docker logs --tail` como antes.
  Con el foco en los logs: `Espacio` pausa y reanuda (el título cuenta las líneas que esperan), `f` o `Fin` vuelven al final, `e` deja solo
  errores y avisos, `/` filtra por texto, `s` busca (resalta, `[` y `]` saltan a la coincidencia anterior o siguiente). Si lees líneas
  antiguas la vista se queda quieta, como siempre.
- **Procesos** (`5`): el árbol vivo del comando en curso (PID, memoria, línea de comandos; la suma no cuenta el proceso que espera,
  igual que `runs show`) y lo que cuesta el propio panel (memoria, CPU ahora y de media, procesos que ha lanzado, p. ej. `docker events`).
  Mientras corre un comando, la cabecera lleva una tarjeta (`N proc · X MB`) y las pestañas inactivas se reducen a su número si falta sitio.

Además:

- Los comandos corren **dentro** del panel, en segundo plano (`lib/core/jobs.sh`): `Enter` abre las acciones de la instancia, `:` escribe
  cualquier comando (Tab completa, ↑ historial), `!` lo ejecuta en el terminal, `x` cancela. Un solo comando a la vez.
- Confirmaciones dentro del panel (rollback, detener, bajar; `init` pide escribir el nombre).
- Cifras en vivo leídas del kernel (cgroups v1/v2 y `/proc`) sin lanzar procesos; el estado de Docker se refresca por **eventos de
  Docker** (y cada 30 s por seguridad), en un proceso en segundo plano para que la pantalla nunca espere a Docker.
- Español/inglés (`L`), ayuda (`?`), pausa (`p`), refresco (`r`), aviso si la terminal es muy pequeña (mínimo 60x14).

Commits (en orden): `feat(metrics)` → `feat(jobs)` → `feat(metrics)` formateadores/eventos → `feat(panel)` → `perf(status)` (una consulta de
imágenes) → `perf(panel)` (segundo plano, dibujo rápido, caché del cuerpo).

## Apariencia y diseño (pista "UI")

- **Temas** (`lib/ui/theme.sh`): `matrix` (por defecto), `cyber`, `amber`, `nord`, `dracula`, `mono`. Tecla `T` para cambiar (se guarda
  como `UI_THEME` en `~/.config/deltactl/config`), o `DELTACTL_THEME=<nombre>`. Temas propios: `~/.config/deltactl/themes/<nombre>.theme`
  (líneas `clave=#rrggbb`; son datos, nunca se ejecutan). Claves opcionales del rediseño: `track` (la parte vacía de un medidor), `hotkey` (la letra de un atajo) y un degradado por magnitud
  (`cpu`, `mem`, `disk`, `net_down`, `net_up`, `health`) con `<magnitud>_start`, `_mid` y `_end`; sin ellas una magnitud usa `ramp`, así que los temas
  existentes se ven igual. Los degradados tienen 101 pasos y se construyen la primera vez que se usan (`lib/ui/tokens.sh`). Color real (24 bits) si el terminal lo soporta (`COLORTERM`, `WT_SESSION`,
  `DELTACTL_TRUECOLOR=1`), si no 256 o 16 colores; sin color con `NO_COLOR`. Solo afecta al panel: la CLI y las golden no cambian.
- **Diseño ancho** (≥120 columnas y ≥28 filas): instancias + servidor | tabla de servicios, gráficos de área (autoescala, color según el valor
  real), siguientes pasos (solo si hay) y logs en vivo | eventos (≥150 columnas), con la salida del último comando debajo. Por debajo
  de 120 columnas se mantiene la vista compacta.
- **Historial**: una muestra cada 2 s (`DELTACTL_METRICS_INTERVAL`), 120 muestras = 4 minutos en los gráficos.
- **Opciones** (tecla `o`, o "Opciones del panel" en Ctrl+P; `lib/screens/options.sh`): tema, idioma, muestreo de cifras
  (1, 2, 3, 5 o 10 s), relectura del estado sin eventos de Docker (2, 5, 10, 15, 30 o 60 s) y teclas vim (`j k h g G`; con `no` solo
  valen las flechas, Inicio y Fin). ↑↓ eligen, ←→ o Enter cambian, Esc cierra. Cada cambio se aplica al momento y se guarda en el mismo
  `~/.config/deltactl/config` que `UI_LANG` y `UI_THEME` (`TUI_SAMPLE`, `TUI_REFRESH`, `TUI_VIM=on|off`), con escritura atómica
  (`set_var`). `DELTACTL_THEME`, `DELTACTL_LANG`, `DELTACTL_METRICS_INTERVAL` y `DELTACTL_REFRESH` siguen mandando al arrancar, y la
  pantalla lo indica. Un valor del archivo que no sea un número dentro de su rango se ignora (vale el de por defecto).
- **Consola a pantalla completa** (vista `6 Consola`): la misma consola de la vista Instancias ocupando todo el cuerpo. `6` (o
  `goto console`, o un clic en la pestaña) la abre con la línea lista para escribir y, tras cada orden, la línea sigue lista, como en
  un terminal; las órdenes se quedan en la consola en vez de abrir Salida. Esc suelta el teclado (↑↓, PgUp/PgDn casi una pantalla e
  Inicio/Fin recorren lo escrito; Enter o `:` vuelven a escribir) y otra Esc vuelve a Instancias. Tab llega a ella desde Procesos sin
  tomar el teclado, para que recorrer las vistas con Tab nunca se quede atascado en la línea.
- **Alias de la consola** (`lib/screens/console_alias.sh`): `alias up=deploy colorado` hace que `up` valga por esa orden como primera
  palabra (el resto de la línea va detrás: `alias lg=logs colorado` y luego `lg s0 -f`); `alias` los lista, `alias up` muestra uno y
  `unalias up` lo borra; Tab completa sus nombres. Se guardan en `aliases`, junto al historial (modo 600, reescrito entero con un
  archivo temporal y un renombrado). El archivo son datos: una línea que no es un alias válido se ignora. Solo admiten órdenes de
  deltactl y del panel: uno que empiece por `!` (el terminal) se rechaza, igual que un nombre que taparía un comando. Se sustituyen
  una sola vez.
- **Barras de teclas que caben**: la última línea pierde elementos enteros, nunca medio: se quedan los primeros (cómo moverse) y
  los dos últimos (ayuda y salir, o cómo volver); antes se cortaban a media palabra a 100 columnas (logs, zoom, consola) y casi
  todas a 80.
- **Pantalla de teclas (`?`)**: las líneas largas siguen debajo de su descripción (sangría francesa) en vez de cortarse; si no cabe
  en la pantalla se desplaza (↑↓, PgUp/PgDn, Inicio/Fin, la rueda) y el título dice qué líneas muestra; abre en la sección de la
  vista actual, resaltada. Tiene sección de Recursos, que faltaba.
- **Matriz de terminales** (`tests/tools/pty_matrix.py`, fuera de la suite; necesita python3): lanza el panel en un pseudo-terminal
  real contra un Docker simulado (12 instancias) y comprueba que arranca, que nada se dibuja más allá del borde derecho, que se
  redibuja al redimensionar, el ratón, y que al salir deja la terminal como estaba (pantalla alterna, cursor, ratón, eco). Resultado
  (2026-11-21): bien en xterm-256color (120x30 redimensionado a 80x24, y 200x55 a 160x40), xterm, screen-256color, consola de
  Linux con `LANG=C`, vt100, `NO_COLOR`, truecolor con ratón, 60x14 y `TERM=dumb` (cae a la pantalla de inicio en texto). CPU
  propia en reposo con 12 instancias simuladas a 120x30: Instancias 1,8 %, Recursos 1,8 %, Salida 0,5 %, Ejecuciones 0,5 %,
  Procesos 0,75 % (2026-11-21, segunda pasada: 2,1 / 1,7 / 0,4 / 0,4 / 0,8 %). La herramienta mide también la CPU de lo que lanza el
  panel: casi toda es la relectura del estado (cada 30 s con eventos de Docker), que con 12 instancias simuladas cuesta ~1 s de
  reloj y ~1,25 s de CPU; buena parte es el Docker simulado (cada llamada arranca un script de Bash), así que hay que medirla con el
  Docker real del servidor antes de concluir nada. Falta probar Windows Terminal/WSL y SSH reales.
- **Guía de uso**: [panel.md](panel.md).
- **Layout por reglas** (`lib/ui/layout.sh`): los repartos de la vista Instancias (ancha y compacta) se calculan con
  `lay_split total "deseado:mínimo:máximo:crece[:opcional]"...`: cada panel empieza en su tamaño deseado dentro de sus límites;
  si no caben, encogen primero los que crecen, luego caen los opcionales (la columna de eventos, la caja del servidor), luego los
  demás bajan a su mínimo y, en último caso, se recortan; lo que sobra va a los que crecen según su peso y el resto al último panel,
  de modo que siempre se llena el total. Se verificó con 990 fotogramas (11 anchos x 9 altos x varios escenarios) antes y después
  del cambio: idénticos. El reparto interno del centro (tabla, gráficos de altura `2*R+5`, siguientes pasos y logs) sigue en su
  panel porque sus alturas van a saltos.
- **Caché por panel**: la lista, el servidor, el centro (tabla, gráficos y siguientes pasos) y el detalle de la vista compacta se
  guardan con la firma del estado del que dependen (estado de Docker, cifras, errores, selección, foco, tamaño, tema e idioma) y
  se reutilizan mientras no cambie; los logs y los eventos ya tenían la suya. Un fotograma tras una línea de log o una tecla
  escrita pasa de ~21 a ~11 ms a 160x40 y de ~12 a ~6 ms a 110x30 (tras una muestra no cambia: ahí todo cambia de verdad).
- **Ratón** (desactivado por defecto; se activa en Opciones, `TUI_MOUSE=on`): modo SGR (1000 + 1006). Clic en una pestaña abre su
  vista; en una instancia la selecciona y un segundo clic abre sus acciones (como Enter); en "+ Nueva instancia" la selecciona y otro
  clic abre el formulario de nueva instancia; en la vista Consola da el teclado a la línea. La rueda hace lo que las flechas allí donde mueven algo y, en
  una línea que se está escribiendo, desplaza lo escrito en vez de recorrer el historial. Mientras está activo, el texto se selecciona
  con Mayús. Se apaga al salir, al abrir una shell o un asistente, y vuelve al regresar.
- **Ver el resultado sin terminal**: `python3 tests/tools/pty_shot.py salida.json FILAS COLUMNAS sleep:10` captura el panel real con color
  (solo lectura sobre Docker) y `pwsh tests/tools/render_shot.ps1 -Json salida.json -Png salida.png` lo dibuja como imagen.
  `HARNESS_ROWS`/`HARNESS_COLS` hacen que `pty_harness.py` mida a otros tamaños.

Consumo medido a 200x55 (WSL2, 2 contenedores): reposo 5,4 % de CPU propia (9,7 % con los procesos que lanza), siguiendo logs 7,0 %,
RSS 8 MB. **El objetivo (<1 % en reposo) sigue sin cumplirse**; el coste está en reconstruir ~48 ms por muestra (cajas y recortes de línea
con color) y en el muestreo (~10 ms). Los gráficos ya son incrementales (`gfx_area_cached`) y las cajas de eventos y logs se cachean.

## Dónde está cada cosa

| Archivo | Responsabilidad |
| --- | --- |
| `lib/ui/theme.sh` | Temas, conversión de colores (24 bits → 256 → 16), bordes, rampa de degradado |
| `lib/ui/gfx.sh` | Gráficos de área de varias filas (bloques de 1/8), con versión incremental |
| `lib/cmd/dashboard.sh` | Controlador: estado compartido, trabajo en segundo plano (`dash_async*`), eventos de Docker, trabajos, teclas globales, ratón y bucle |
| `lib/cmd/dashboard_view.sh` | Dibujo compartido: cabecera, pestañas, marco de los diálogos, barra de teclas y el fotograma (`dash_render`). Solo construye `TUI_FRAME`, nunca ejecuta nada |
| `lib/screens/registry.sh` | Registro de pantallas y router: una línea por pantalla y el contrato que cumple cada una (ver «Pantallas» abajo) |
| `lib/screens/instances.sh` (+ `instances_logs.sh`) | Vista Instancias: lista, detalle, vista ancha, zoom, teclas y el panel de logs en vivo |
| `lib/screens/resources.sh`, `output.sh` | Vistas Recursos y Salida (esta dibuja el resumen o la salida cruda) |
| `lib/core/outparse.sh` | Intérprete de lo que imprimió un comando: filas (titular, secciones, elementos con estado, fases, pasos numerados, veredicto). Solo lee y no dibuja |
| `lib/ui/outsummary.sh` | Dibuja esas filas con el kit y guarda el resultado hasta que cambian la salida, el tamaño, el idioma o el tema |
| `lib/screens/runs.sh` | Vista Ejecuciones: lectura del historial, detalle, comparación, estadísticas, visor de logs paginado, teclas |
| `lib/screens/procs.sh` | Vista Procesos y tarjeta de la cabecera: árbol de `/proc` (`DELTACTL_PROC_ROOT` en los tests) y coste del panel |
| `lib/screens/console.sh` (+ `console_alias.sh`) | Vista Consola y la consola de Instancias: historial, órdenes propias, completado y envío; alias (`alias`/`unalias`, archivo `aliases`) |
| `lib/screens/menu.sh`, `confirm.sh`, `name.sh`, `palette.sh`, `help.sh`, `options.sh`, `wizard.sh` | Modos con diálogo: menú de acciones, confirmación, «escribe el nombre», paleta, ayuda de teclas, Opciones (`TUI_*` en el archivo de configuración) y el formulario de nueva instancia |
| `lib/screens/cmd.sh`, `filter.sh`, `find.sh` | Modos de línea: orden que se escribe (`:`), filtro (`/`) y búsqueda (`s`) de los logs; el editor de línea es `dash_key_edit` (en `cmd.sh`) |
| `lib/ui/layout.sh` | Motor de layout: `lay_split` reparte columnas o filas entre paneles por reglas (deseado, mínimo, máximo, crecimiento, opcional) |
| `lib/ui/tui.sh` | Terminal: pantalla alterna, teclas, cajas, recorte con colores, dibujo incremental |
| `lib/core/metrics.sh` | Muestreo de memoria/CPU por servicio, historial, formato (bytes, %, sparkline) y, con `MT_HOST_DETAIL=1`, del servidor entero (`mt_host_sample`, ver «El servidor entero») |
| `lib/core/jobs.sh` | Un comando en segundo plano: salida sin `fork`, cancelación (TERM y luego KILL a los 2 s) |
| `lib/adapters/host.sh` | Lectores de `/proc`, `/sys` y cgroups (solo builtins de Bash): CPU por núcleo, memoria por tipo, carga, arranque, temperaturas, red, discos |
| `lib/adapters/docker.sh` | `dk_container_rows` (con pid y reinicios), `dk_events_stream`, `dk_images_ids` |
| `lib/i18n/{es,en}/dashboard.sh` | Textos del panel |

## El resumen de la Salida

La vista Salida no vuelca texto: cuando el comando tiene forma, `lib/core/outparse.sh` lo lee y `lib/ui/outsummary.sh` lo dibuja (la vista Actividad
de la tarea A2 usará los mismos dos archivos). Los comandos **no cambian lo que imprimen** (los golden de la CLI no se tocaron) y la salida cruda
sigue intacta en `JOB_LINES`: `v` alterna, `e` (solo errores) y la ayuda de la vista siguen trabajando sobre ella.

**Qué se reconoce** (`out_parse <array> <línea de comando> [en curso] [código]`): `new`, `check`, `deploy`, `init`, `doctor`, `images`, `env`, `rollback` y
`adopt`; el comando se toma de la primera palabra del título del trabajo. Se reconoce por la **forma** y por el **catálogo i18n**, nunca por texto suelto:

| Forma | Cómo se lee |
| --- | --- |
| Título subrayado (`───`) | `OUT_TITLE` |
| `OK …` / `ERROR …` / `AVISO …` en el margen (claves `label.*`) | el primer `OK`/`ERROR` es el titular (`OUT_HEAD_*`; un `ERROR` pesa más que un `OK`); los demás y los `AVISO` son elementos |
| `●` `▲` `✖` `ℹ` `→` (modo rico) o `*` `!` `x` `i` `->` (llano), con 2 o más espacios de sangría | elemento con estado ok / warn / err / info, o la pista (`→`); `título  detalle` (dos espacios) separa el detalle de la misma línea |
| Líneas con más sangría que el elemento | su explicación (`OUT_R_SUB`) |
| `  1. texto` | paso numerado |
| Títulos y fases de los catálogos (`new.pending_title`, `new.next_title`, `deploy.validating`, `init.step1`…) | secciones y fases (`step`); la última fase queda «en curso», fallida o hecha según el comando |
| Cabecera de tabla en mayúsculas (3 o más columnas) | `env` (una sección por archivo, el estado se lee de `env.state.*`) e `images` (estado por `images.use_*`) |
| Última línea con marcador tras un blanco, en `check` y `doctor` | el veredicto (`OUT_VER_*`) |

Las **dos lenguas a la vez**: lo que imprimió un comando sigue leyéndose si el panel cambia de idioma después (`out_init` carga el catálogo que falte).
Si una salida no se reconoce (otro comando, texto inesperado, un título sin nada debajo) `out_parse` devuelve 1 y la vista muestra la salida cruda, sin
error. Lo que está en el medio y no se resume (el progreso de docker en un `deploy`) se cuenta en `OUT_IGNORED` y la vista lo dice en la última línea.
El resumen **no añade palabras**: `tests/test-outsum.sh` comprueba que cada palabra del resumen salió del comando.

**Añadir un comando**: poner su primera palabra en `out_kind_of`, y si tiene secciones, fases o tablas propias, sus claves i18n en `out_init` (o su
cabecera, si la tabla es nueva, en la rama `case "$OUT_KIND"` de las filas de tabla). Un archivo de captura (`tests/tools/outsum_capture.sh`) y una
escena (`tests/tools/outsum_scenes.sh`) para su golden.

**Coste**: se lee una vez por salida y tamaño (el resultado se guarda en `OUTSUM_*`; el fotograma no vuelve a leer). Con la máquina a carga ≈ 2
(`bench_frames.sh`): un fotograma con el resumen ya hecho 2,5–3,2 ms (igual que la salida cruda: 2,5–3,4 ms), una tecla de desplazamiento 8–10 ms, y
leer y dibujar de nuevo la salida de `doctor` (37 líneas) 19–22 ms, una vez. Mientras el comando corre y llegan líneas, el resumen se rehace como mucho
cada 300 ms, y de `deploy`/`init`/`rollback` solo se leen las 150 primeras y las 150 últimas líneas (el progreso de docker son miles): 3000 líneas
cuestan unos 75 ms por rehacer, no por fotograma.

## El servidor entero: fuentes de métricas

`lib/adapters/host.sh` lee, sin lanzar procesos, lo que dibujará la vista Servidor (`DELTACTL_PROC_ROOT` y `DELTACTL_SYS_ROOT` apuntan a árboles
falsos en los tests; `tests/test-metrics.sh`, secciones 4 a 9). Cada lector devuelve 1 y deja sus resultados vacíos si su fuente no existe (WSL,
un contenedor, un kernel sin sensores): `MT_SRC[<fuente>]` vale 0 y la pantalla dice «no disponible» en vez de fallar.

| Lector | Fuente | Resultado |
|---|---|---|
| `host_cpu_read` | `/proc/stat` | `HOST_CPU_PCT[0]` = CPU total y `[1..N]` cada núcleo, en %, entre dos lecturas (la primera solo guarda contadores; `iowait` cuenta como libre) |
| `host_load_full_read` | `/proc/loadavg` | `HOST_LOAD1/5/15`, tareas en ejecución y totales |
| `host_uptime_read` | `/proc/uptime`, `btime` de `/proc/stat` | `HOST_UPTIME_S`, `HOST_BOOT_TS` (el arranque se lee una sola vez) |
| `host_mem_detail_read` | `/proc/meminfo` | usada, en caché (con `SReclaimable`), buffers, libre, disponible y swap, en KB |
| `host_temp_read` | `/sys/class/hwmon/*/temp*_input` (y `thermal_zone*` sin hwmon) | `HOST_TEMP_LABEL/C/CRIT[]`, `HOST_TEMP_CPU_C` (Package, Tctl o Tdie ganan a los núcleos), `HOST_TEMP_MAX_C`; nombres y límites se leen una vez |
| `host_net_read` | `/proc/net/dev` | bytes por interfaz; la principal (la de más tráfico, o `DELTACTL_NET_IFACE`), su velocidad en B/s y sus totales. Sin `lo`, `veth*`, `br-*`, `docker*`, `virbr*`… |
| `host_diskio_read` | `/proc/diskstats` | B/s leídos y escritos por los discos enteros (sin particiones, `dm-*` ni `loop*`, para no contar dos veces) |
| `host_disks_read` | `/proc/mounts` | puntos de montaje que importan: sistemas de archivos reales, uno por dispositivo, sin rutas de Docker, snap ni `/boot/efi` |
| `host_disk_usage_read` | `df -Pk` | total, usado y % de cada uno. **La única excepción a «sin procesos»**: el kernel no da un archivo para esto, así que corre **un** `df` como mucho cada `HOST_DISK_TTL` s (30), con un límite de `HOST_DF_TIMEOUT` s (3) y sin reintento hasta que pase el TTL aunque falle (un montaje de red colgado no bloquea cada muestra) |

`mt_host_sample` los llama y guarda los historiales (`MT_HH_CPU`, `MT_HH_NETD/NETU`, `MT_HH_DIOR/DIOW`, `MT_HH_TEMP`), el máximo reciente de la red
(`MT_NET_DOWN_MAX/UP_MAX`, el mayor de la ventana) y el total de la sesión. Corre dentro de `mt_sample` **solo** con `MT_HOST_DETAIL=1` (la
vista Servidor a la vista): las demás vistas no lo pagan. Las temperaturas se leen en la primera muestra y cada `MT_TEMP_EVERY` (3); la lista de
montajes cada 30 muestras.

Coste medido (`tests/test-metrics.sh` sección 9 pone una red de seguridad de 5 ms; las cifras reales están en el informe de la tarea): cada
lector es de orden de cientos de microsegundos y ninguno lanza un proceso.

## Pantallas: cómo está organizado el panel y cómo añadir una

El panel se compone de **pantallas** con un contrato común (`lib/screens/registry.sh` lo documenta función por función). Hay dos clases:

- **Vistas** (las pestañas, `1` a `7` o Tab): `instances`, `resources`, `output`, `runs`, `procs`, `console`, `server`. Una es la actual (`DASH_VIEW`).
- **Modos** (toman el teclado sobre una vista): `menu`, `confirm`, `name`, `cmd`, `filter`, `find`, `wizard`, `newinst`, `palette`, `help`, `options`, `srvask`.
  Uno es el actual (`DASH_MODE`); `normal` es ninguno.

El resto del panel ya no nombra ninguna: la línea de pestañas, los dígitos, Tab, Esc, la barra de teclas, el cuerpo, la firma del fotograma,
el trabajo periódico y el ratón recorren el registro y llaman a las funciones `scr_<id>_*` (`render`, `key`, `keys`, `texts`, `sig`,
`enter`, `tab`, `back`, `tick`, `poll`, `click`, `bang`: la tecla `!` mientras la vista es la actual; si devuelve 0 se queda con la tecla, si no se
abre la línea de órdenes de siempre).

**Para añadir una pantalla**: crear `lib/screens/<id>.sh` con al menos `scr_<id>_render <ancho> <alto>`, `scr_<id>_key <tecla>` y
`scr_<id>_keys <ancho>`, y añadir **una línea** al final de `lib/screens/registry.sh`
(`dash_screen_register <id> <clave del título> <1 si el cuerpo muestra cifras en vivo>` para una vista, `dash_mode_register <id>` para un modo).
La firma (`scr_<id>_sig`) debe sumar a `DASH_SIG` todo lo que cambia lo que dibuja: el cuerpo se reutiliza mientras la firma no cambie, así que
un valor que falte es una pantalla desactualizada. Los textos que cambian con el idioma van en `scr_<id>_texts`.

Comprobación de refactores: `tests/tools/panel_scenarios.sh <carpeta>` ejecuta 30 secuencias de teclas (vistas, diálogos, asistente, opciones, ayuda,
paleta, consola, ratón) a cinco tamaños y guarda **todos** los fotogramas; dos árboles de dos versiones del código se comparan con `diff -r`.
`tests/tools/panel_frames.sh` hace lo mismo con la última imagen de cada vista.

## La vista Imágenes

`lib/screens/images.sh` (vista `images`, 8) y dos modos: `lib/screens/imguse.sh` (`imguse`, usar una versión en una instancia) y `lib/screens/imgload.sh`
(`imgload`, pedir el archivo y cargarlo). El catálogo es el de `lib/core/imagecat.sh` ([image-catalog.md](image-catalog.md)) y las tablas las dibuja el
selector de versión del kit (`kit_vpick`, una tabla por imagen, con `msg=0` y un ancho común `tagw=`).

- **Lectura**: `ic_load` corre en un trabajo en segundo plano (`dash_async images`, como el estado de Docker y los requisitos) y el resultado vuelve como líneas
  `declare -p` de las tablas `IC_*` (solo esas se cargan; `DASH_IMG_NODOCKER=1` si Docker no responde). En el modo de prueba (`DELTACTL_TUI_KEYS`) es
  síncrono. Se vuelve a leer al elegir la vista, cuando termina un comando (`JOB_SEQ` nuevo con `JOB_RC`: `scr_images_tick`), cada `DASH_IMG_EVERY` (60) s
  mientras está a la vista (`scr_images_poll`) y con `R`. Al aplicar el resultado el cursor se queda en la misma versión (imagen y etiqueta); la primera vez
  va a la ★ de la primera imagen. Una lectura que muere o que lleva un minuto sin responder se olvida (`dash_async_take`) y `scr_images_tick` libera la
  vista (`DASH_IMG_BUSY=0`; sin respuesta previa dice que Docker no responde, con una la deja). Una lectura lanzada antes de que acabe un comando no borra
  la marca de «catálogo viejo»: `dash_img_stale` cuenta los comandos que acabaron (`DASH_IMG_GEN`) y la respuesta solo limpia `DASH_IMG_STALE` si se pidió
  después (`DASH_IMG_REQ_GEN`).
- **Dibujo**: `dash_img_build` arma las líneas (un título por imagen, su tabla, el aviso si el orden por fecha y por versión discrepan) y solo se repite
  cuando cambian la respuesta, el idioma, el tema o el ancho; el cursor solo cambia qué línea lleva la marca de selección, y la ventana sobre la lista lo
  mantiene a la vista. Las marcas (★ ▲ ✖) no dependen del color: en ASCII son `*`, `!` y `x`.
- **Usar una versión**: `dash_img_use` abre `imguse` con las instancias de `DASH_NAMES` que tienen el servicio (`DASH_SVCS`); `dash_iu_write` escribe
  `<SN>_TAG` con `set_var` (sustituye el archivo de una vez) y `y` lanza `deploy <instancia> <sN>` con `dash_start_job`. Nada se escribe antes de la respuesta.
  Antes de escribir, `dash_iu_blocked` mira sin tomarlo el candado de las mutaciones (`runs_busy`) y, para `y`, las ejecuciones interrumpidas sin revisar
  (`runs_pending`); y al armar la lista `dash_iu_findable` descarta (con el motivo en la fila y entero al pulsar Enter) las instancias que no encontrarían la
  imagen: una local necesita `<imagen>:<etiqueta>` cargada con ese nombre, una con `REGISTRY` necesita `<registry>/<imagen>:<etiqueta>` (`IC_FULL`).
- **Cargar**: `dash_img_load_ask` abre `imgload` con el campo del kit (`KF_VALUE`, `KF_CUR`); Enter con un archivo que existe lanza
  `dash_start_job stay load <archivo>` y recuerda su `JOB_SEQ` (`DASH_IMG_JOB`) para mostrar el archivo que se carga y releer al terminar.
- **Pruebas**: `tests/test-imgview.sh` (escenas de `tests/tools/images_scenes.sh` en `tests/golden/images/` a 80x24, 120x30 y 160x40, y las teclas de punta
  a punta contra el docker simulado: usar una versión con `g` y con `y`, copiar con `DELTACTL_CLIP`, cargar un archivo y ver la versión nueva). El docker
  simulado (`tests/fake-docker.sh`) entiende `docker load` (`load_result`, `load_date`, `load_arch`), las fechas de creación (`image_dates.txt`) y la
  arquitectura del servidor (`server_arch`), un demonio que no responde (`daemon_down`) y anotar cada llamada (`log_all` → `all_calls.log`).

## El asistente de nueva instancia por pasos (modo `newinst`)

`lib/screens/newinst.sh` es el **motor** y `lib/screens/newinst/<paso>.sh` son los **pasos**. Se abre en lugar del formulario antiguo (`lib/screens/wizard.sh`)
cuando el ajuste `TUI_WIZARD=2` está en el archivo de configuración o se arranca el panel con `DELTACTL_WIZARD=2`; por omisión sigue abriéndose el antiguo
hasta que el nuevo cree, revise y avise (tareas N2 y N3 del plan). `n`, la paleta, la consola y el botón de la cabecera llaman a `dash_open_new`, que
decide.

- **Qué se ve**: una barra de progreso arriba (`kit_stepper`: ● hecho, ◉ abierto, ▲ con aviso, ✖ con error, ○ por venir), el formulario del paso a la izquierda
  (`kit_box` con el número y el nombre del paso en el borde y `Esc atrás`/`Enter siguiente` en el pie) y, a la derecha desde 100 columnas, la **vista previa**
  (los archivos que se crearán, las variables que fijan las respuestas y el comando `./deltactl new …` equivalente, partido por opciones) y la lista del
  estado de cada paso. En una pantalla estrecha solo hay el formulario y **Tab** lo cambia por la vista previa. Por debajo de 14 filas la barra son dos
  líneas sin marco.
- **Teclas**: Enter sigue con lo propuesto y Esc vuelve (en el primer paso, con algo elegido, pide Esc otra vez); PgUp/PgDn van al paso anterior y siguiente;
  los dígitos y un clic en la barra saltan a un paso ya visitado (en un paso donde se escribe, como el nombre, los dígitos son texto).
- **Los cuatro pasos de hoy**: *Nombre* (la primera `instancia-N` libre; libre = sin carpeta, sin proyecto de Compose con contenedores y sin red
  `<nombre>_…`: `lib/core/instname.sh` lee Docker una vez al abrir y compara sin lanzar procesos en cada tecla), *Servicios* (una tarjeta por servicio del
  catálogo con su descripción, puerto, memoria y dependencias), *Versiones* (el selector del kit con la ★ ya elegida; una por servicio, la que tiene el
  cursor desplegada) y *Datos* (nueva o ya existente, con la consecuencia dicha). Las imágenes son las del catálogo: cambiar el nombre de la imagen es una
  variable de la instancia (paso de variables, tarea N2).
- **Al terminar** (Enter en el último paso) arranca `./deltactl new <nombre> …` como trabajo del panel, igual que el formulario antiguo, tras volver a
  comprobar todos los pasos: si un nombre dejó de estar libre mientras tanto, abre ese paso con el motivo y no crea nada. Nada se escribe antes.
- **Para añadir un paso**: crear `lib/screens/newinst/<id>.sh` con `dash_nzs_<id>_render <ancho> <alto>` (añade líneas a `DASH_NZ_B`) y, si hace falta,
  `_key`, `_enter`, `_state`, `_gate`, `_typing`, `_args` (opciones que añade a `new`) y `_preview`; añadir los textos `tui.nz.step.<id>`, `tui.nz.help.<id>`
  y `tui.nz.keys.<id>` en los dos idiomas y **una línea** `dash_nz_step_register <id>` al final de `newinst.sh`. El motor no cambia. El contrato completo
  está en la cabecera de `lib/screens/newinst.sh`.
- **Pruebas**: `tests/test-newinst.sh` (registro y apertura, nombres libres y tomados con el docker simulado, cada paso, el recorrido, la instancia creada
  de punta a punta, escenas de `tests/tools/newinst_scenes.sh` en `tests/golden/newinst/` a 80x24, 120x30 y 160x40 y su degradación). El docker simulado
  entiende `network ls` (`networks.txt`) y `ps -a --format` con el proyecto de cada contenedor (`containers.txt`).
- **Límites de hoy**: no hay todavía el editor de variables, los secretos, el acceso ni la revisión (N2 y N3); el paso de versiones no carga archivos `.tar`
  (se hace en la vista Imágenes, `l`); el ratón solo actúa en la barra de pasos.

## La vista Variables

`lib/screens/env.sh` (vista `env`, 9) y `lib/screens/envedit.sh` (modo `envedit`, el editor tiene el teclado). El editor es el del kit
(`lib/ui/kit/env_editor.sh`, ver [ui-kit.md](ui-kit.md)); la vista pone lo que es del panel: qué instancia, el teclado, los mensajes, el despliegue que
sigue a un guardado y las marcas «sin desplegar».

- **Qué instancia**: la elegida en Instancias (`dash_env_target`). Con cambios preparados la vista conserva la suya aunque se cambie la selección (caminar
  a otra vista no pierde nada); `[` y `]` cambian de instancia solo cuando no hay cambios. Si se llega a la vista sin su dígito (paleta, `goto env`) el editor
  se abre en el primer dibujo.
- **El teclado es un modo**: con el dígito `9` el editor recibe el teclado (`DASH_MODE=envedit`): aquí `d` es «valor por defecto» (no «diagnóstico»), `r`
  «revelar» y `g` «generar», así que las letras no llegan a las teclas globales. Lo que el editor no usa sí llega al panel (`scr_envedit_key` lo pasa a
  `dash_key_global`): los dígitos cambian de vista, Tab sigue, `?` ayuda, `:` la línea de comandos, `q` sale (pregunta antes si hay cambios; como Esc).
  Con la vista a la vista pero sin el teclado (se llegó con Tab) la primera tecla que el panel no toma se lo da y va al editor, de modo que Enter es «editar».
- **Marcas «sin desplegar»**: se leen en segundo plano (`dash_async env`, `dash_env_dump`: sumar un archivo es un proceso) al abrir, al terminar un comando
  y tras guardar; el resultado llega como líneas `archivo estado` (`synced`, `pending`, `unknown`) a `KEE_DEPLOY`. En el modo de prueba es síncrono. Si
  una vista se abre antes de que llegue, simplemente no muestra ↻ todavía.
- **Guardar y desplegar**: `u` pregunta («¿Guardar los cambios (n) y desplegar X?»); con `y` guarda y la vista lanza `dash_start_job stay deploy <instancia>`,
  un comando como cualquiera (en segundo plano, en Salida, se cancela con `x`). Un guardado rechazado no despliega.
- **Coste** (equipo con carga 3–4, simulado): una tecla que mueve el cursor 20–26 ms a 160x40 (el dibujo de una fila cuesta más que todo lo demás, así que las
  filas dibujadas se guardan mientras nada de lo que enseñan cambie: `KEE_LC`, invalidada por `KEE_GEN`); abrir una instancia ~65 ms (cada archivo se lee una vez
  y se evalúa cada variable, una sola vez por apertura); en reposo ~0,8 % de una CPU (el cuerpo se reutiliza entre muestras, no hay animación).
- **Pestañas**: con nueve vistas, a 100 columnas la línea de pestañas enseña solo el número de las que no están abiertas (a 110 caben los nombres); los
  clics siguen la forma que se dibuja. Una pantalla registrada con una línea en `test-tui` ocupa el sitio de la novena pestaña: un dígito no abre una décima.
- **Pruebas**: `tests/test-envview.sh` (el modelo, cada tecla, que nada se escribe hasta `s`, el todo-o-nada del guardado, que un secreto no sale en ningún
  fotograma, 48 instantáneas de `tests/tools/env_scenes.sh` en `tests/golden/envview/` a 80x24, 120x30 y 160x40 — 13 escenas en español y 3 en inglés —
  y las teclas de punta a punta contra el docker simulado).

## La vista Servidor y la barrera de primer arranque

`lib/screens/server.sh` (vista `server`, 7) y `lib/screens/srvask.sh` (modo `srvask`, la pregunta). Se construyen con el kit (`kit_box` con chips y
pie, `kit_graph` y `kit_graph_mirror`, `kit_meter`, `kit_leader`, `kit_table`, `kit_state_icon`, `kit_overlay` para la caja de los núcleos sobre la
gráfica de CPU) y con el motor de reparto (`lay_split`: las filas y las columnas se recomponen a 80, 120 y 160 columnas; lo que no cabe se quita, la
segunda fila primero).

- **Requisitos**: `prereq_run_all` corre en un trabajo en segundo plano (`dash_async prereq`, como el estado de Docker y los logs: una comprobación
  puede preguntar a Docker o abrir un TCP) y el resultado vuelve como líneas `declare -p` de las variables `PR_*` (solo esas se cargan). En el modo
  de prueba (`DELTACTL_TUI_KEYS`) es síncrono. Se repite cada 2 minutos mientras la vista está a la vista (cuesta ~0,35 s de procesos) y con `R`.
- **Cifras**: `MT_HOST_DETAIL=1` solo mientras la vista es la actual (`scr_server_tick`); elegir la vista pide la primera muestra al instante.
- **Copiar y ejecutar**: `dash_srv_copy` (`wl-copy`, `xclip`, `xsel`, `pbcopy`, OSC 52) y `dash_srv_terminal`, que solo llama el modo `srvask` tras un
  `y`. Nada instala por su cuenta. Variables de prueba: `DELTACTL_CLIP` (un comando que lee el texto por su entrada, en vez de tocar el portapapeles),
  `DELTACTL_PR_SHELL` (el intérprete del comando, en vez de `bash`: los tests ponen un script que solo anota qué se le pidió) y `DELTACTL_DF`:
  las tres solo se respetan dentro de los tests (`DELTACTL_TEST_ISOLATED=1`, que exporta `tests/run.sh`), para que una variable heredada por
  casualidad no cambie qué programa ejecuta un comando confirmado. El comando se muestra entero o no se muestra: si no cabe en la ventana
  (URL larga en una terminal estrecha, terminal baja), la ventana pide agrandarla y `y` no ejecuta nada. Un requisito que espera a otro (el
  daemon de un Docker sin instalar) o que aún no tiene respuesta no ofrece comando para copiar ni ejecutar.
- **Primer arranque**: `dash_srv_startup` pide la comprobación al arrancar; con un obligatorio en `err` abre la vista Servidor y avisa una vez
  (`dash_srv_after_apply`). `dash_open_new` (el único punto por el que se abre el formulario de nueva instancia) llama a `dash_srv_blocking` y, si
  falta algo y la persona no ha dicho que siga, abre `srvask` en vez del formulario. La opción `TUI_PREREQ=on|off` (Opciones) lo apaga y enciende.
  En el modo de prueba el arranque no comprueba nada salvo con `DELTACTL_TUI_GATE=1`: así las demás pruebas no abren en esta vista por lo que le
  falte a la máquina donde corren.
- **Pruebas**: `tests/test-server.sh`; las escenas con datos fijos (`tests/tools/server_scenes.sh`: ok, missing, open, zoom, na, loading) son las
  instantáneas de `tests/golden/server/` (`DELTACTL_GOLDEN=record` las regraba). `tests/tools/sim_env.sh` tiene `sim_host`, un servidor simulado
  (CPU, red, discos y sensor en un `/proc` y un `/sys` falsos) con `sim_host_tick` para moverlo.
- **Capturas**: `tests/tools/pty_shot.py` (un PTY real; `DELTACTL_SHOT_ALL=1` copia todas las instancias de un servidor simulado) y
  `tests/tools/shot_png.py` (Pillow) dibujan el resultado como PNG; también acepta un fotograma con colores de una escena
  (`DELTACTL_COLOR=always COLORTERM=truecolor`) para ver el diseño sin esperar a que las gráficas se llenen.

**Consumo de la vista Servidor** (simulado: `bench_frames.sh` y un PTY real contra Docker y host simulados, 12 instancias, máquina con poca carga; son cifras de
esta máquina, no del WSL de las medidas anteriores). Fotograma con la firma sin cambios (solo se vuelve a pintar): 7, 12 y 16 ms a 80x24, 120x30 y
160x40 (en el modo de prueba pinta todas las líneas; el panel real solo las que cambian). Con una muestra nueva: 5, 9 y 12 ms si las cifras no se
movieron (cada recuadro se guarda mientras su clave —las cifras que dibuja, el tamaño, el idioma y el tema— no cambia) y 24, 38 y 55 ms **con la lectura
del host incluida** si el servidor se mueve (todo se dibuja de nuevo). CPU en reposo durante 40 s a 160x40: Instancias 2,4 %, Servidor 3,7 % con el
host moviéndose y 3,2 % con el host quieto (+1,2 y +0,8 puntos); a 120x30, 2,2 % y 2,7 % con el host moviéndose (+0,5). Lo que más costaba era la comprobación de requisitos (≈0,35 s de procesos: cada 30 s
sumaba unos 2 puntos): por eso se repite cada 2 minutos. El presupuesto del diseño (≤ 1,5 % en cualquier vista, ≤ 45 ms sin caché a 160x40) **no se cumple
del todo con un servidor que se mueve** (55 ms, +1,2 puntos); lo que queda es el coste de `kit_box` (≈ 2 ms por recuadro) y de pintar las gráficas por fila.
`TUI_SAMPLE` en Opciones (5 s) lo reduce a la mitad.

Límites: con siete vistas, a 80 columnas la línea de pestañas deja solo el número de las que no están activas; hasta 120 columnas la vista no
dibuja la caja de contenedores (la vista Recursos sigue siendo la tabla completa).

## Cómo probar

Siempre con `tests/run.sh` (copia aislada). Desde Windows, en WSL:

```bash
wsl.exe -e bash -lc 'cd /mnt/e/ITC/itc-deploy && bash tests/run.sh'               # todo
wsl.exe -e bash -lc 'cd /mnt/e/ITC/itc-deploy && bash tests/run.sh test-tui'      # solo el panel (134 comprobaciones)
```

- `test-tui` usa el modo de prueba: `DELTACTL_TUI_KEYS=<archivo>` (una tecla por línea; `space`, `enter`, `esc`, `wait` espera al
  comando, `sample` toma una muestra de métricas; el fin del archivo es la tecla `eof` y siempre sale) y simula `/proc` y los cgroups.
- Terminal real: `tests/tools/pty_harness.py` maneja `./deltactl` en un pseudo-terminal, reconstruye la pantalla y mide CPU/RAM contra el
  Docker real **solo en lectura** (`python3 tests/tools/pty_harness.py /tmp/informe.json idle|quick`). `bench_render.sh` y
  `bench_micro.sh` miden cuánto cuesta cada pieza.

## Trampas aprendidas (no repetirlas)

- `deltactl` corre con `set -euo pipefail`: dentro del panel `cmd_dashboard` apaga `errexit` y lo restaura al salir.
- Con `set -u`, `local a="$1" b="${X[$a]}"` en una sola línea falla: `a` aún no existe al expandir `b`.
- El fin de la entrada es la tecla `eof` (no `q`): si no, estando en la línea de comandos se escribiría una `q` en bucle.
- Una secuencia de teclas desconocida (F5...) es `other`, no `esc`: si no, saldría del panel.
- No terminar una línea dibujada con `ESC[K`: tras escribir en la última columna el cursor sigue en ella y `ESC[K` la borra (se perdía el
  borde derecho de todas las cajas). `tui_draw` limpia la línea **antes** de escribirla.
- Cada `$(...)` es un proceso: en el dibujo los ayudantes devuelven el resultado en variables (`dt`, `dash_bar`, `mt_*_v`, `tui_fit`).

## Consumo de las vistas Ejecuciones y Procesos (2026-11-20; WSL2, Docker real, 2 contenedores, 120x30, `pty_harness.py`)

CPU propia del panel / con los procesos que lanza, 30 s por escenario (el ruido del harness es de ±0,5 puntos):

| Escenario | CPU propia | CPU total |
| --- | --- | --- |
| Instancias en reposo (línea base) | 2,57 % | 5,10 % |
| Ejecuciones en reposo | 2,22 % | 2,72 % |
| Procesos en reposo (sin comando) | 3,31 % | 4,59 % |
| Siguiendo logs, vista Instancias (con la tarjeta) | 9,69 % | 12,89 % |
| Siguiendo logs, vista Procesos | 8,72 % | 10,69 % |
| Siguiendo logs, vista Ejecuciones | 7,59 % | 9,47 % |

Después de optimizar (misma máquina, 2 repeticiones alternadas con el código anterior; CPU propia en reposo, 30 s): Ejecuciones
**2,58 % → 1,73 %**, Procesos **2,96 % → 2,19 %**, Instancias 2,56 % → 2,74 % (sin cambio apreciable; el ruido del harness es de ±0,5).
Qué se hizo, y por qué solo ayuda a las vistas sin métricas:

- `mt_push` cuenta los valores con un contador (`MT_HN`) en vez de contar los espacios de un historial de 120 valores en cada
  inserción (1,6 ms → una concatenación), y `host_cg_mem` lee `memory.stat` de una vez (`$(< fichero)`, sin proceso) en vez de línea a
  línea. Con 7 contenedores en marcha `mt_sample` pasó de unos 24 ms a unos 15 ms en régimen estable.
- La firma de caché del cuerpo ya no incluye muestras, estado de Docker, errores, eventos ni logs en las vistas Salida, Ejecuciones
  y Procesos: su cuerpo no usa esas cifras y se reconstruía igual cada 2 s.
- En esas tres vistas se muestrea cada 4 s en vez de cada 2 (solo cambia la cabecera, que se mueve despacio).

Dónde queda el coste en Instancias (con 7 contenedores): ~15 ms de `mt_sample` + ~2 ms de la cabecera + ~23 ms de reconstrucción del
fotograma por cada muestra de 2 s. Con esos cambios de cifras en cada muestra, bajar de ahí exige dibujar menos (cachear por panel con
una firma de las cifras ya redondeadas, o muestrear más despacio), no leer más rápido; el objetivo de menos del 1 % sigue sin cumplirse.

RSS 8,5-8,8 MB en todos. Las vistas nuevas no cuestan más que la línea base: el historial se relee cada 5 s solo mientras la vista está
en pantalla y el detalle se construye una vez por selección; los procesos se leen con builtins de Bash desde `/proc` (cada 1 s con un
comando en marcha, cada 2 s sin él). El objetivo de menos del 1 % en reposo sigue sin cumplirse (el coste es el de siempre: reconstruir
el fotograma y el muestreo). Un hallazgo útil de la vista Procesos: el `docker events` que lanza el panel ocupa unos 32 MB de RSS (es el CLI
de Docker, no el panel).

## Siguiendo logs (2026-11-20; WSL2, Docker real, 2 contenedores, 130x30, `pty_harness.py`, 25 s con el foco en los logs)

CPU propia del panel. "Antes" es el sondeo (`docker logs --tail 400` cada 3 s); los logs simulados salen de un `docker` falso:

| Caso | Antes | Después |
| --- | --- | --- |
| Docker real, logs en silencio | 10,3 % | **2,8 %** |
| 100 líneas/s | 8,6 % | **4,7 %** |
| ~2000 líneas/s | 10,1 % | 14,9 % |

Lo que costaba: leer una línea de una tubería (~470-680 µs) frente a un fichero (~15 µs); limpiar secuencias de escape de cada línea (~52 µs;
ahora solo las que llevan ESC, CR o tabulador); publicar y reconstruir la caja. Con 2000 líneas/s el panel lee todo (antes solo veía una muestra
cada 3 s), de ahí el 15 %: más allá de eso nadie puede leerlo y conviene `logs <instancia> <servicio> -f` en la vista Salida.

## Consumo medido (WSL2, Docker real, 2 contenedores, 110x30)

Medido con `pty_harness.py ... idle`, 60 s sin tocar teclas, sumando CPU del panel y de los procesos que lanza:

| | Panel anterior | Panel nuevo |
| --- | --- | --- |
| CPU total en reposo | 12,9 % de un núcleo (el 12,4 % era Docker) | **8,3 %** (4,6 % el panel + 3,7 % Docker) |
| Memoria (RSS) | 5,5 MB | 7,1 MB |
| Llamadas a Docker en 30 s | 40 | **8** (2 `info`, 1 `ps`, 1 `inspect`, 1 `image ls`, 1 flujo de eventos, 2 `logs`) |
| Seguir logs en vivo (25 s) | no existía | 54 % (48 % el panel) → **10,3 %** (7,1 % el panel) tras corregir `tui_vlen` |
| 150 pulsaciones + cambio de vista | no medido | 35 % → **13,4 %** (11,7 % el panel) |

Segunda medición (misma máquina, mismo harness): reposo 60 s = 6,1 % total (3,3 % el panel + 2,8 % Docker).

**Lección de rendimiento**: `tui_vlen` quitaba los colores con `${1//$'\033'\[+([0-9;])m/}`; ese reemplazo con extglob cuesta ~24 ms por
línea con colores en Bash 5.3/UTF-8 y se llamaba decenas de veces por fotograma (un repintado real: ~110 ms). Ahora usa expansiones
simples y recuerda el resultado (`TUI_VL_CACHE`): ~15 ms por repintado. Los benchmarks `bench_render.sh`/`bench_micro.sh` no lo
veían porque usan texto sin colores en parte de las rutas; para medir de verdad hay que usar el terminal real (`pty_harness.py`).
Evitar patrones extglob en reemplazos (`//`) sobre cadenas largas.

## Qué falta (por prioridad)

1. **CPU del propio panel en reposo**: el objetivo es menos del 1 % y hoy son ~3,3 % (siguiendo logs ya es ~7 %, antes ~40 %). Cada
   segundo cuesta un muestreo (~12 ms, `mt_sample`) y un repintado (~15 ms). Ideas: muestrear cada 2 s cuando no se ve la vista
   Instancias/Recursos, repintar solo si cambió algo visible (comparar cifras redondeadas, no `MT_SAMPLES`), y acelerar
   `tui_box`/`dash_detail_lines` (el cuerpo reconstruido sigue siendo lo más caro). Medir con el terminal real, no solo con los bench.
2. **Informe de consumo en un servidor Linux real** (no WSL) y con varias instancias (10+): hoy solo hay medición en WSL2 con 2
   contenedores.
3. **Revisión nativa (RDD)** de los commits de esta rama: no se ejecutó (requiere tu consentimiento por cada commit).
4. **Probar en el servidor real**: cgroup v2 con systemd está verificado en WSL; falta cgroup v1 real.
5. Documentación: guía corta en `docs/panel.md`; falta una captura.
6. Opcional: presets de layout (fuera de U5), ratón en más sitios (servicios, logs, menús), historial de comandos persistente, filtro de instancias, vista nativa de imágenes, aviso visual de `oom` por eventos.

## Límites conocidos

- Un solo comando a la vez; el resto espera o se rechaza con un aviso.
- La línea de comandos separa por espacios (no admite comillas); `menu` y los comandos con `!` delante salen al terminal. El
  asistente de `new` ya no sale: es un formulario del panel (`lib/screens/wizard.sh`) que repite lo que pregunta `lib/cmd/new.sh`
  y arranca `new <nombre> --services ... --s0-image ... --ip ... --generate-secrets`; si se cambia una pregunta, hay que cambiarla
  en los dos sitios (las validaciones y los textos son compartidos). El formulario dibuja dos paneles desde 92 columnas y 20
  filas; por debajo, solo los campos de la sección. Los servicios que aún no tienen Docker (walle, robin, link) se muestran
  apagados y sus nombres están escritos a mano en `dash_nw_pane_services`; al dockerizar uno hay que darlo de alta en `lib/core/catalog.data` y
  quitarlo de ahí.
  El estado de las imágenes y los puertos se lee una vez al abrir el formulario: no se refresca mientras está abierto.
- "Errores (10 min)" cuesta un `docker logs` por servicio cada 30 s, solo de la instancia seleccionada.
- Mínimo 60 columnas x 14 filas.

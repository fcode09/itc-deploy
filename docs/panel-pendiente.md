# Panel en vivo: qué hay, cómo probarlo y qué falta

Documento para retomar el trabajo del panel interactivo de `deltactl` (rama `feat/live-panel`, fusionada en `develop`).

## Qué hay hecho

Un panel de una sola pantalla (`./deltactl` en una terminal, o `./deltactl menu`) con cinco vistas (`1` a `5` o Tab):

- **Instancias**: lista con `n/m`, memoria y CPU; detalle de la seleccionada (por servicio: imagen, estado, tiempo activo, puerto,
  reinicios, memoria y CPU con barra y tendencia, errores de los últimos 10 min, siguientes pasos) y el panel de salida del último comando.
- **Recursos**: todos los servicios de todas las instancias con memoria, CPU, tendencia, reinicios y tiempo activo; orden con `s`.
- **Salida**: la salida completa del último comando, con desplazamiento (`↑↓`, PgUp/PgDn, Home/End), `f` para seguir y `e` solo errores.
- **Ejecuciones** (`4`): el historial de las operaciones que cambian algo (`lib/core/runs.sh`). Lista (las que están en curso primero,
  luego las más nuevas), y de la seleccionada: estado y código, comparación con la anterior correcta de la misma operación y con la
  media de las cinco anteriores (duración, CPU, docker, memoria pico), consumo, contenedores antes y después y el final de su salida
  (PgUp/PgDn desplazan el detalle). `t` da las estadísticas por operación (`s` las limita a una instancia) y `Enter` abre su salida
  guardada en un visor paginado: un log de cualquier tamaño se indexa una vez (un punto de control por cada 500 líneas, en segundo
  plano a partir de 8 MiB) y cada página se lee desde el punto de control más cercano, así que la memoria no crece con el log.
- **Logs de un servicio** (vista Instancias en pantalla ancha, o `z` para ampliarlos; `lib/cmd/dashboard_logs.sh`): mientras el panel de
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
  (líneas `clave=#rrggbb`; son datos, nunca se ejecutan). Color real (24 bits) si el terminal lo soporta (`COLORTERM`, `WT_SESSION`,
  `DELTACTL_TRUECOLOR=1`), si no 256 o 16 colores; sin color con `NO_COLOR`. Solo afecta al panel: la CLI y las golden no cambian.
- **Diseño ancho** (≥120 columnas y ≥28 filas): instancias + servidor | tabla de servicios, gráficos de área (autoescala, color según el valor
  real), siguientes pasos (solo si hay) y logs en vivo | eventos (≥150 columnas), con la salida del último comando debajo. Por debajo
  de 120 columnas se mantiene la vista compacta.
- **Historial**: una muestra cada 2 s (`DELTACTL_METRICS_INTERVAL`), 120 muestras = 4 minutos en los gráficos.
- **Opciones** (tecla `o`, o "Opciones del panel" en Ctrl+P; `lib/cmd/dashboard_options.sh`): tema, idioma, muestreo de cifras
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
- **Alias de la consola** (`lib/cmd/dashboard_alias.sh`): `alias up=deploy colorado` hace que `up` valga por esa orden como primera
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
| `lib/cmd/dashboard.sh` | Controlador: estado, bucle, teclas, línea de comandos, trabajo en segundo plano (`dash_async*`), eventos de Docker |
| `lib/cmd/dashboard_view.sh` | Dibujo: cabecera, pestañas, vistas, diálogos. Solo construye `TUI_FRAME`, nunca ejecuta nada |
| `lib/cmd/dashboard_runs.sh` | Vista Ejecuciones: lectura del historial, detalle, comparación, estadísticas, visor de logs paginado, teclas |
| `lib/cmd/dashboard_procs.sh` | Vista Procesos y tarjeta de la cabecera: árbol de `/proc` (`DELTACTL_PROC_ROOT` en los tests) y coste del panel |
| `lib/cmd/dashboard_options.sh` | Pantalla de Opciones: lectura y validación de `TUI_*` en el archivo de configuración, cambios y diálogo |
| `lib/cmd/dashboard_alias.sh` | Alias de la consola: validación, archivo `aliases`, órdenes `alias`/`unalias` y sustitución |
| `lib/ui/layout.sh` | Motor de layout: `lay_split` reparte columnas o filas entre paneles por reglas (deseado, mínimo, máximo, crecimiento, opcional) |
| `lib/ui/tui.sh` | Terminal: pantalla alterna, teclas, cajas, recorte con colores, dibujo incremental |
| `lib/core/metrics.sh` | Muestreo de memoria/CPU por servicio, historial, formato (bytes, %, sparkline) |
| `lib/core/jobs.sh` | Un comando en segundo plano: salida sin `fork`, cancelación (TERM y luego KILL a los 2 s) |
| `lib/adapters/host.sh` | Lectores de `/proc` y cgroups (solo builtins de Bash) |
| `lib/adapters/docker.sh` | `dk_container_rows` (con pid y reinicios), `dk_events_stream`, `dk_images_ids` |
| `lib/i18n/{es,en}/dashboard.sh` | Textos del panel |

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
  asistente de `new` ya no sale: es un formulario del panel (`lib/cmd/dashboard_new.sh`) que repite las preguntas de `lib/cmd/new.sh`
  y arranca `new <nombre> --services ... --s0-image ... --ip ... --generate-secrets`; si se cambia una pregunta, hay que cambiarla
  en los dos sitios (las validaciones y los textos son compartidos). En una terminal de 14 filas el resumen se comprime (sin filas
  en blanco) y el mínimo de filas sigue siendo 14.
- "Errores (10 min)" cuesta un `docker logs` por servicio cada 30 s, solo de la instancia seleccionada.
- Mínimo 60 columnas x 14 filas.

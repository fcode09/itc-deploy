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
- **Procesos** (`5`): el árbol vivo del comando en curso (PID, memoria, línea de comandos; la suma no cuenta el proceso que espera,
  igual que `runs show`) y lo que cuesta el propio panel (memoria, CPU ahora y de media, procesos que ha lanzado, p. ej. `docker events`).
  Mientras corre un comando, la cabecera lleva una tarjeta (`N proc · X MB`) y las pestañas inactivas se reducen a su número si falta sitio.

Además:

- Los comandos corren **dentro** del panel, en segundo plano (`lib/core/jobs.sh`): `Enter` abre las acciones de la instancia, `:` escribe
  cualquier comando (Tab completa, ↑ historial), `!` lo ejecuta en el terminal (asistentes), `x` cancela. Un solo comando a la vez.
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
5. Documentación: `README.md` y `lib/help/{,en/}cmd-menu.txt` ya describen el panel; falta una captura o guía corta de uso.
6. Opcional: ratón, historial de comandos persistente, filtro de instancias, vista nativa de imágenes, aviso visual de `oom` por eventos.

## Límites conocidos

- Un solo comando a la vez; el resto espera o se rechaza con un aviso.
- La línea de comandos separa por espacios (no admite comillas); los asistentes (`new --wizard`, `menu`) salen al terminal.
- "Errores (10 min)" cuesta un `docker logs` por servicio cada 30 s, solo de la instancia seleccionada.
- Mínimo 60 columnas x 14 filas.

# Panel en vivo: qué hay, cómo probarlo y qué falta

Documento para retomar el trabajo del panel interactivo de `deltactl` (rama `feat/live-panel`, fusionada en `develop`).

## Qué hay hecho

Un panel de una sola pantalla (`./deltactl` en una terminal, o `./deltactl menu`) con tres vistas (`1`, `2`, `3` o Tab):

- **Instancias**: lista con `n/m`, memoria y CPU; detalle de la seleccionada (por servicio: imagen, estado, tiempo activo, puerto,
  reinicios, memoria y CPU con barra y tendencia, errores de los últimos 10 min, siguientes pasos) y el panel de salida del último comando.
- **Recursos**: todos los servicios de todas las instancias con memoria, CPU, tendencia, reinicios y tiempo activo; orden con `s`.
- **Salida**: la salida completa del último comando, con desplazamiento (`↑↓`, PgUp/PgDn, Home/End), `f` para seguir y `e` solo errores.

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

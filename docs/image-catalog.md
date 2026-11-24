# Catálogo de versiones de imagen

Qué versiones de cada servicio hay cargadas en este Docker, cuál es la más reciente que se puede elegir y quién usa cuál. Lo lee la CLI
(`./deltactl images`, `new --sN-tag latest`) y el panel (la vista Imágenes y el selector de versión), así que hay **una sola regla** y no
dos. Código: `lib/core/imagecat.sh`. Solo imágenes **cargadas en este Docker** (`docker load`); no consulta ningún registry.

## La regla (determinista y explicable)

1. Las versiones de una imagen se ordenan por la **fecha de creación de la imagen** (`CreatedAt` de Docker), la más nueva primero. Una
   etiqueta es solo un nombre; la fecha es un hecho. Con la misma fecha, gana el número de versión más alto.
2. La **★** es la más nueva por fecha que (a) tiene una etiqueta de **versión** (`1.2.3`, `v1.2.3`, `2026.11.3`, `1.2`, `7`, `1.2.3-rc1`) y
   (b) **puede arrancar en este servidor** (su arquitectura es la del servidor, o una de las dos no se conoce).
3. `latest` y las etiquetas que no son versión (`dev`, `a1b2c3d`) se marcan **▲** («se mueve: no sirve para volver atrás») y **nunca** son ★.
4. Una imagen de otra arquitectura se marca **✖** y no se puede elegir.
5. Si las etiquetas son versiones y el orden por versión **discrepa** del orden por fecha (la 2.13.2 se creó después que la 2.14.0), la ★
   sigue siendo la más nueva por fecha y el grupo lo dice («¿se reconstruyó una versión vieja?»).
6. Sin fechas (Docker no las da) no hay ★ ni se inventa nada; el orden cae al número de versión.

Los números se comparan como números (`1.2.10` > `1.2.9`), un número que falta vale 0 (`1.2` = `1.2.0`) y una pre-versión es menor que su
versión (`1.2.3-rc1` < `1.2.3`).

## En la CLI

- `./deltactl images [servicio] [--json]` muestra cada imagen de la más nueva a la más vieja, con `★`, `▲` y `✖` junto a la etiqueta o la
  arquitectura, y avisos y notas debajo. `--json` añade `created_at` (ISO 8601 UTC, vacío si Docker no la da), `latest` (`true` en la ★),
  `compatible` y `kind` (`version`, `latest`, `other`).
- `./deltactl new <instancia> --s0-tag latest` guarda **la etiqueta de la ★** (por ejemplo `v1.2.9`), no la palabra `latest`; con
  `--s0-image otro/nombre` busca entre las versiones de esa imagen. Si no hay una versión elegible falla y no crea nada.

## Cómo se construye (para quien lo use)

```
ic_load [<sN>=<imagen> ...]   lee Docker (1 `docker image ls` + 1 `docker image inspect` de todas las imágenes) y rellena las tablas IC_*
ic_latest <sN> [imagen]       la etiqueta de la ★ en IC_LATEST (1 si no hay)
ic_epoch / ic_iso / ic_ago    fechas sin procesos: «2026-11-20 10:00:00 -0500 EST» ⇄ segundos ⇄ ISO 8601 ⇄ «hace 2 días»
ic_version / ic_vcmp          ¿parece una versión? y comparación de dos versiones
```

Las tablas (`IC_TAG`, `IC_EPOCH`, `IC_KIND`, `IC_OK`, `IC_STAR`, `IC_USE`, `IC_ORDER`, `IC_STARIDX`, `IC_DISC`...) están descritas en la cabecera
del archivo. Una imagen `<none>` no se lista. La arquitectura se pide en una sola consulta (`dk_images_arch`); si el Docker no responde a varias
a la vez, se pide de una en una.

## Pruebas

`tests/test-images.sh` (secciones 4–9) usa `tests/fake-docker.sh` con dos ganchos opcionales: `$FIX/image_dates.txt` (`referencia|fecha`) y
`$FIX/server_arch` (la arquitectura del servidor). Cubre fechas (zonas, bisiestos), versiones (`1.2.10` vs `1.2.9`, pre-versiones), empate de
fechas, `latest`, arquitectura incompatible, sin imágenes, imagen sin etiqueta, uso por instancia, `--json` y `new --sN-tag latest`.

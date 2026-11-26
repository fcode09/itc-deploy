# Catálogo de versiones de imagen

Qué versiones de cada servicio hay cargadas en este Docker, cuál es la más reciente que se puede elegir y quién usa cuál. Lo lee la CLI
(`./deltactl images`, `new --sN-tag latest`) y el panel (la vista Imágenes y el selector de versión), así que hay **una sola regla** y no
dos. Código: `lib/core/imagecat.sh`. Solo imágenes **cargadas en este Docker** (`docker load`); no consulta ningún registry.

## La regla (determinista y explicable)

1. Las versiones de una imagen se ordenan por la **fecha de creación de la imagen** (`CreatedAt` de Docker), la más nueva primero. Una
   etiqueta es solo un nombre; la fecha es un hecho. Con la misma fecha, gana el número de versión más alto.
2. La **★** es la más nueva por fecha que (a) tiene una etiqueta de **versión estable** (`1.2.3`, `v1.2.3`, `2026.11.3`, `1.2`, `7`) y
   (b) **puede arrancar en este servidor** (su arquitectura es la del servidor, o una de las dos no se conoce). Una etiqueta con sufijo
   (`1.2.3-rc1`, `2.14.0-debug`, `2.0.0-alpine`) es una versión, se lista y se puede elegir a mano, pero **nunca es la ★**: una fecha no debe
   mover la instancia de un municipio a un candidato a versión o a una variante. Si solo hay etiquetas con sufijo, no hay ★.
3. `latest` y las etiquetas que no son versión (`dev`, `a1b2c3d`) se marcan **▲** («se mueve: no sirve para volver atrás») y **nunca** son ★.
4. Una imagen de otra arquitectura se marca **✖** y no se puede elegir.
   Una imagen cargada con el nombre de un registry (`reg.io/backend-s0`) entra en el grupo de `backend-s0`, y se guarda el nombre que le da
   Docker (`IC_FULL`). Una instancia con imágenes locales ejecuta `backend-s0:<etiqueta>` y no descarga nada, así que la ★ se elige entre las
   cargadas con el nombre sin registry cuando hay alguna; si todas llevan registry, entre ellas.
5. Si las etiquetas son versiones y el orden por versión **discrepa** del orden por fecha (la 2.13.2 se creó después que la 2.14.0), la ★
   sigue siendo la más nueva por fecha y el grupo lo dice («¿se reconstruyó una versión vieja?»).
6. Sin fechas (Docker no las da) no hay ★ ni se inventa nada; el orden cae al número de versión.

Los números se comparan como números (`1.2.10` > `1.2.9`), un número que falta vale 0 (`1.2` = `1.2.0`) y una pre-versión es menor que su
versión (`1.2.3-rc1` < `1.2.3`). Dos pre-versiones se comparan campo a campo, separados por puntos, como hace semver: los números como
números (`rc.10` > `rc.9`), las palabras por sus bytes —nunca por el orden del idioma del usuario (`RC2` < `rc1`)—, un número es menor que una
palabra y, con los primeros campos iguales, gana la lista más larga (`rc.1` < `rc.1.1`). Una etiqueta con forma de fecha (`2026-11-24`) es una
versión con sufijo: se compara como fecha y no es ★.

## En la CLI

- `./deltactl images [servicio] [--json]` muestra cada imagen de la más nueva a la más vieja, con `★`, `▲` y `✖` junto a la etiqueta o la
  arquitectura, y avisos y notas debajo. `--json` añade `created_at` (ISO 8601 UTC, vacío si Docker no la da), `latest` (`true` en la ★),
  `compatible` y `kind` (`version`, `latest`, `other`).
- `./deltactl new <instancia> --s0-tag latest` guarda **la etiqueta de la ★** (por ejemplo `v1.2.9`), no la palabra `latest`; con
  `--s0-image otro/nombre` busca entre las versiones de esa imagen. Solo resuelve los servicios de la instancia (`--services`). Si Docker
  responde y no hay una versión elegible, falla y no crea nada. **`new` no necesita Docker para crear una instancia**: si Docker no responde,
  avisa de que no pudo buscar la versión, la etiqueta se queda en `latest` y la instancia se crea; pon una versión en `S0_TAG` de
  `.env.instance` antes de desplegar.

## Cómo se construye (para quien lo use)

```
ic_load [<sN>=<imagen> ...]   lee Docker (1 `docker image ls` + 1 `docker image inspect` de todas las imágenes) y rellena las tablas IC_*
ic_latest <sN> [imagen]       la etiqueta de la ★ en IC_LATEST (1 si no hay)
ic_epoch / ic_iso / ic_ago    fechas sin procesos: «2026-11-20 10:00:00 -0500 EST» ⇄ segundos ⇄ ISO 8601 ⇄ «hace 2 días»
ic_version / ic_vcmp          ¿parece una versión? y comparación de dos versiones (ic_precmp: las pre-versiones, campo a campo)
```

Las tablas (`IC_TAG`, `IC_EPOCH`, `IC_KIND`, `IC_OK`, `IC_STAR`, `IC_USE`, `IC_ORDER`, `IC_STARIDX`, `IC_DISC`...) están descritas en la cabecera
del archivo. Una imagen `<none>` no se lista. La arquitectura se pide en una sola consulta (`dk_images_arch`); si el Docker no responde a varias
a la vez, se pide de una en una.

## «Usar esta versión» en el panel (vista Imágenes)

`Enter` en una versión pregunta en qué instancia usarla y enseña el cambio. Antes de escribir nada comprueba tres cosas:

- **Que la instancia pueda encontrar la imagen.** Una instancia sin `REGISTRY` necesita `<imagen>:<etiqueta>` cargada con ese nombre; una con
  `REGISTRY=reg.io` necesita `reg.io/<imagen>:<etiqueta>` cargada (si no, Docker la descargaría de allí, y puede no tenerla). Si no, la fila lo
  dice («solo cargada como reg.io/backend-s0») y `Enter` sobre ella lo explica entero.
- **Que no haya otra operación en curso**, en otra terminal (el candado `instances/.deltactl/locks/mutation.lock` en manos de un proceso
  vivo): ni `y` (cambiar y desplegar) ni `g` (solo guardar la etiqueta) escriben nada, porque el despliegue que corre podría registrar la
  etiqueta nueva sobre el contenedor viejo.
- **Que no haya una ejecución interrumpida sin revisar** (`runs resolve`): bloquearía el despliegue, así que `y` tampoco escribe; `g`, que no
  arranca nada, sí funciona.

La vista no se queda en «leyendo…» si Docker no responde en un minuto (dice que no responde), y una lectura lanzada antes de que acabe un
`load` o un despliegue no borra la marca de «el catálogo está viejo».

## Pruebas

`tests/test-images.sh` (secciones 4–9) usa `tests/fake-docker.sh` con dos ganchos opcionales: `$FIX/image_dates.txt` (`referencia|fecha`) y
`$FIX/server_arch` (la arquitectura del servidor), más `$FIX/daemon_down` (el demonio no responde) y `$FIX/log_all` (anota cada llamada en
`all_calls.log`, para comprobar qué se le pidió a Docker). Cubre fechas (zonas, bisiestos), versiones (`1.2.10` vs `1.2.9`, el orden de
pre-versiones de semver y su independencia del idioma), empate de fechas, `latest`, la ★ solo estable, nombres con registry, arquitectura
incompatible, sin imágenes, imagen sin etiqueta, uso por instancia, `--json` y `new --sN-tag latest` (con y sin Docker).

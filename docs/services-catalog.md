# Catálogo de servicios

Estado de los servicios del ecosistema y qué falta para sumarlos a `deltactl`.
Hoy solo `s0` y `s1` tienen `services/compose-sN.yaml`.

> Los datos de los servicios sin Docker salen de una revisión superficial
> (`package.json`, puerto de arranque y variables `process.env` de `src/`), no de una
> auditoría. Confírmalos antes de dockerizar.

## Servicios dockerizados

| Clave | Servicio | Repo | Puerto interno | Compose |
|---|---|---|---|---|
| `s0` | auth-backend | AuthSoftwareUpdateV1 | 3200 | `services/compose-s0.yaml` |
| `s1` | gueo-back-end | gueosoftwareupdatev1 | 3000 | `services/compose-s1.yaml` |

## Servicios pendientes de dockerizar

La clave `sN` de cada uno está **por asignar**. Ninguno tiene Dockerfile todavía; hoy corren con PM2.

| Servicio | Repo | Stack | Puerto por defecto | Dependencias externas |
|---|---|---|---|---|
| walle-backend | walle | NestJS 11, Mongoose 9, TypeORM + `pg` (Postgres/Timescale), Kafka, Puppeteer 22.15.0 | 3700 (`PORT`) | MongoDB, Postgres/Timescale, Kafka, Delta Dispatch API, Query Forge |
| robin-backend | RobinSoftware | NestJS 10, Mongoose 7, Kafka | 3601 (`SERVER_PORT`) | MongoDB, Kafka, Delta Dispatch, Query Forge |
| sipcop-backend (Link) | sipcopsoftware | NestJS 10, Mongoose 7, Puppeteer 20.3.0 | 3603 (`SERVER_PORT`) | MongoDB, Delta Dispatch, Query Forge |

"Link" es el nombre actual de la plataforma que antes se llamaba SIPCOP.

## Cosas a resolver al dockerizarlos

- **Link (sipcop-backend): Puppeteer está en `devDependencies` pero el código lo usa**
  (`cron.service.ts`, `sipcop.gateway.ts`, `puppeteer-step-config.*`). El patrón de imagen ejecuta
  `npm prune --omit=dev`, que lo eliminaría y rompería la app al arrancar. Hay que moverlo a
  `dependencies`. Su Chromium sería el 113 (Puppeteer 20.3.0), distinto del 127 de s1 y walle.
- **Robin:** tiene Puppeteer 20.3.0 en `devDependencies` sin usarlo en `src`; se puede ignorar.
- **Walle y Robin usan Kafka** y walle además Postgres/Timescale: el compose deberá apuntar a los
  que ya existan en el servidor, como se hace con MongoDB.
- **Nombres de variables de Mongo distintos** por proyecto (`MONGO_ROBIN_SERVER_URI` en walle,
  `ROBIN_MONGO_URI` en robin, `MONGO_URI` en sipcop): cada servicio tendrá su propia plantilla.
- **Convivencia durante la transición:** mientras estos servicios sigan en PM2 en el host, los
  contenedores los alcanzan por `host.docker.internal` (el compose ya añade `extra_hosts`).

## Pasos para sumar un servicio nuevo

Un servicio se define **una sola vez**, en `lib/core/catalog.data` (una línea; lo lee `lib/core/catalog.sh`). De esa línea salen
`KNOWN_SERVICES`, el nombre de imagen por defecto, `REQUIRED_<SN>`, las variables de URI de Mongo de `check`, las carpetas de
`data/`, los secretos que genera `--generate-secrets`, la plantilla que copia `new`, el puerto (`base + desplazamiento`), las
opciones `--<sN>-image` y `--<sN>-tag` y la lista de la guía `./deltactl help servicios`.

1. Dockerizarlo y dejar su imagen disponible en el servidor (`./deltactl load`) o publicada en un registry.
2. Compose: `services/compose-sN.yaml` siguiendo `compose-s0.yaml` (variables `SN_TAG`, `SN_PORT`, `SN_MEM_LIMIT`, `profiles: ["sN"]`;
   si depende de otro servicio, `depends_on` con `required: false`) y su línea en `include` de `compose.yaml`.
3. Plantillas: `templates/.env.sN.example` y las variables `SN_TAG`, `SN_PORT` en `templates/.env.instance.example`.
4. Catálogo y ayuda: la línea de `lib/core/catalog.data` (clave, nombre, imagen, puertos, plantilla, obligatorias, Mongo, dependencias,
   memoria, carpetas, archivos de `secrets/`, secretos a generar), su descripción `catalog.desc.sN` en `lib/i18n/{es,en}/common.sh`,
   cada variable de su plantilla en `lib/help/variables.txt` (y `en/`) y, si añade opciones a algún comando, su página `cmd-*.txt`.
   `tests/run.sh test-help` y `test-catalog` fallan mientras falte algo.

Solo hace falta código si el servicio tiene una regla propia: una comprobación previa especial se define como
`preflight_extra_sN` en `lib/cmd/deploy.sh` (como la de `s1`, que avisa si `TCP_LISTEN_HOST` solo escucha en el contenedor).
Las instancias existentes no lo activan solas: `./deltactl service add <instancia> sN` (o la pestaña Servicios del panel) crea su `.env.sN`, sus carpetas de `data/`,
le busca un puerto libre y lo suma a `COMPOSE_PROFILES`; `service remove` lo quita conservando sus datos (`./deltactl help service`).
Después, actualizar este catálogo y la tabla del README.

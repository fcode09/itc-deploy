# Catálogo de servicios

Estado de los servicios del ecosistema y qué falta para sumarlos a `deltactl`.
Hoy `s0`, `s1` y `robin` tienen `services/compose-<clave>.yaml`; `robin` aún no tiene imagen.

> Los datos de los servicios sin Docker salen de una revisión superficial
> (`package.json`, puerto de arranque y variables `process.env` de `src/`), no de una
> auditoría. Confírmalos antes de dockerizar.

## Servicios dockerizados

| Clave | Servicio | Repo | Puerto interno | Compose |
|---|---|---|---|---|
| `s0` | backend-s0 | AuthSoftwareUpdateV1 | 3200 | `services/compose-s0.yaml` |
| `s1` | backend-s1 | gueosoftwareupdatev1 | 3000 | `services/compose-s1.yaml` |
| `robin` | backend-robin | RobinSoftware | 3601 | `services/compose-robin.yaml` (falta el Dockerfile) |

## Servicios pendientes de dockerizar

La clave `sN` de cada uno está **por asignar**. Ninguno tiene Dockerfile todavía; hoy corren con PM2.

| Servicio | Repo | Stack | Puerto por defecto | Dependencias externas |
|---|---|---|---|---|
| walle-backend | walle | NestJS 11, Mongoose 9, TypeORM + `pg` (Postgres/Timescale), Kafka, Puppeteer 22.15.0 | 3700 (`PORT`) | MongoDB, Postgres/Timescale, Kafka, Delta Dispatch API, Query Forge |
| sipcop-backend (Link) | sipcopsoftware | NestJS 10, Mongoose 7, Puppeteer 20.3.0 | 3603 (`SERVER_PORT`) | MongoDB, Delta Dispatch, Query Forge |

"Link" es el nombre actual de la plataforma que antes se llamaba SIPCOP.

## Cosas a resolver al dockerizarlos

- **Link (sipcop-backend): Puppeteer está en `devDependencies` pero el código lo usa**
  (`cron.service.ts`, `sipcop.gateway.ts`, `puppeteer-step-config.*`). El patrón de imagen ejecuta
  `npm prune --omit=dev`, que lo eliminaría y rompería la app al arrancar. Hay que moverlo a
  `dependencies`. Su Chromium sería el 113 (Puppeteer 20.3.0), distinto del 127 de s1 y walle.
- **Robin (`robin`):** definido en el catálogo y con su compose y su plantilla; falta el Dockerfile en su repo. Tiene Puppeteer 20.3.0 en
  `devDependencies` sin usarlo en `src`: se puede ignorar. Escribe en `./src/media/file` y `./src/common/assets/geofence/` (relativos a `/app`).
  Para quien escriba su Dockerfile (en el repo de Robin): arranque `node dist/main`; puerto 3601; en ejecución lee `src/proto/telemetry.proto`
  (relativo al directorio de trabajo, así que `src/proto` debe copiarse a la imagen final) y escribe en `src/media/file` y
  `src/common/assets/geofence`, que el compose monta como volúmenes; `JWT_SECRET`, Mongo y Kafka llegan por variables, nunca en la imagen.
- **Walle y Robin usan Kafka** y walle además Postgres/Timescale: el compose deberá apuntar a los
  que ya existan en el servidor, como se hace con MongoDB.
- **Nombres de variables de Mongo distintos** por proyecto (`MONGO_ROBIN_SERVER_URI` en walle,
  `ROBIN_MONGO_URI` en robin, `MONGO_URI` en sipcop): cada servicio tendrá su propia plantilla.
- **Convivencia durante la transición:** mientras estos servicios sigan en PM2 en el host, los
  contenedores los alcanzan por `host.docker.internal` (el compose ya añade `extra_hosts`).

## Pasos para sumar un servicio nuevo

Van en su propia guía: [add-service.md](add-service.md) (datos a decidir, lista de archivos, variables nuevas, cómo activarlo en
instancias que ya existen y cómo comprobarlo). Después, actualizar este catálogo y la tabla del README.

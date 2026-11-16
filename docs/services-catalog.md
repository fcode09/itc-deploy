# Catálogo de servicios

Estado de los servicios del ecosistema y qué falta para sumarlos a `itc-deploy`.
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

1. Dockerizarlo y publicar su imagen en el registry.
2. Asignarle la siguiente clave libre (`s2`, `s3`...) y un puerto: `base + N` dentro del bloque de la instancia.
3. Crear `services/compose-sN.yaml` siguiendo `compose-s0.yaml` (variables `SN_TAG`, `SN_PORT`, `SN_MEM_LIMIT`).
4. Añadir su línea a `include` en `compose.yaml`.
5. Crear `templates/sN.env.example` y añadir las variables a `templates/instance.env.example`.
6. Ampliar `scripts/cmd/new.sh` (carpetas de `data/`) y las validaciones de `scripts/cmd/deploy.sh`.
7. Actualizar este catálogo y la tabla del README.

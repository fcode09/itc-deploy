# itc-deploy

Despliegue con Docker Compose de los backends de ITC (auth-backend y gueo-back-end).
Usa imágenes ya construidas (cargadas en el Docker del servidor, o bajadas de un registry);
no contiene código fuente ni construye imágenes.

Cada **instancia** (por ejemplo `colorado`) es un despliegue independiente. Varias
instancias conviven en el mismo servidor con un único `compose.yaml`.

## Servicios

| Clave | Servicio | Puerto interno | Contenedor |
|---|---|---|---|
| `s0` | auth-backend | 3200 | `s0_<instancia>` |
| `s1` | gueo-back-end | 3000 | `s1_<instancia>` |

Walle, Robin y Link todavía no están dockerizados: ver [`docs/services-catalog.md`](docs/services-catalog.md).

## Requisitos del servidor

- Docker Engine con **Docker Compose v2.20 o superior** (`include` lo necesita).
- Las imágenes de `s0` y `s1` ya disponibles: **cargadas en el Docker del servidor** (ver "Imágenes locales")
  o, si usas un registry, con sesión iniciada (`docker login`; recomendado un *deploy token* de solo lectura).
- MongoDB ya disponible en el servidor. **Este repo no levanta Mongo.**
- Usuario con permisos para ejecutar `docker` y `chown` sobre `instances/` (los contenedores corren como uid 1000).

## Estructura

```
itc-deploy/
├─ itc                  # CLI: ./itc help
├─ compose.yaml         # name: ${INSTANCE}; include de services/
├─ services/            # compose-s0.yaml, compose-s1.yaml
├─ templates/           # plantillas versionadas: .env.instance.example, .env.s0.example, .env.s1.example
├─ instances/           # instancias reales: NO se versionan
├─ scripts/             # lib.sh y cmd/*.sh que usa ./itc
└─ docs/                # catálogo de servicios
```

## Uso

```bash
git clone <este-repo> && cd itc-deploy

./itc images                # versiones de imagen cargadas en este servidor y quién las usa
./itc new colorado          # crea instances/colorado/ desde las plantillas
# Completa instances/colorado/{instance.env,s0.env,s1.env} (S0_TAG y S1_TAG = versiones de ./itc images)
# y copia los JSON de Firebase a secrets/
./itc deploy colorado       # comprueba las imágenes, levanta y espera a que estén healthy

./itc list                  # instancias, servicios, puertos, etiquetas y estado
./itc ps colorado           # estado
./itc logs colorado s1      # logs de un servicio
./itc rollback colorado     # vuelve a las etiquetas anteriores
./itc down colorado         # detiene la instancia
```

Guía completa con valores de ejemplo: [`docs/example-new-municipality.md`](docs/example-new-municipality.md)
(archivos completados en [`examples/colorado/`](examples/colorado/)).

Para actualizar una instancia: cambia `S0_TAG` / `S1_TAG` en su `instance.env` y ejecuta
`./itc deploy <instancia>`. Las etiquetas anteriores quedan guardadas para el rollback.
**No uses `latest`**: usa una etiqueta por versión o commit.

## Imágenes locales (sin registry)

Construir las imágenes, empaquetarlas y copiarlas al servidor **queda fuera de este repo**. Este
repo empieza cuando la imagen ya está en el Docker del servidor.

**Cómo funciona.** Docker lee las imágenes de su propio almacén (normalmente `/var/lib/docker`),
no de una carpeta. Con `REGISTRY` vacío en `instance.env`, el compose usa `auth-backend:<S0_TAG>` y
`gueo-back-end:<S1_TAG>` tal cual están en ese almacén, y **no descarga nada**. Cada instancia elige su
versión con sus etiquetas, así que pueden convivir versiones distintas en el mismo servidor.

**Cargar una imagen que llegó como archivo** (el resultado de `docker save`, comprimido o no):

```bash
./itc load imagenes-2026-11-16.tar.gz   # equivale a docker load; el archivo se puede borrar después
./itc images                            # ver qué etiquetas quedaron y cuáles usa cada instancia
```

**Comprobaciones de `./itc deploy` (con `REGISTRY` vacío):**
- Que cada imagen exista en este Docker; si falta, dice cuál y cómo cargarla.
- Que su arquitectura sea la del servidor (aviso).
- Con `PULL_POLICY=never`, para que si falta una imagen Docker no baje de Docker Hub una imagen
  homónima que no es la nuestra.
- Que la etiqueta no apunte ahora a otra imagen distinta de la desplegada antes (aviso): una etiqueta
  local se puede reconstruir. **No reutilices etiquetas**; usa una versión nueva por build.

**Rollback:** exige que la imagen previa siga cargada, y avisa si su ID cambió. Por eso **no borres
versiones viejas**: `./itc images` marca las que ninguna instancia usa (ni como actual ni como previa)
como candidatas a borrar, pero solo lista. Evita `docker image prune -a` y `docker system prune -a`.

**Con registry:** pon su ruta en `REGISTRY` (ej. `registry.ejemplo.com/itc`) y `deploy` hará `pull`.
El resto no cambia.

## Elegir qué servicios corre cada instancia

`COMPOSE_PROFILES` en `instance.env` lista los servicios activos de la instancia. Un servicio que
no está en la lista no se descarga ni se levanta, y no se le exige configuración.

```
COMPOSE_PROFILES=s0,s1       # los dos
COMPOSE_PROFILES=s1          # solo Gue (Auth corre en otro lugar)
COMPOSE_PROFILES=s0,s1,s3    # "todos menos s2": listas los que sí quieres
```

`./itc new <instancia> --services s1` crea la instancia ya con esa lista. Un servicio nuevo que se
añada al repo **no** se activa solo en instancias existentes: hay que sumarlo a su lista.

## Actuar sobre un solo servicio

Sin argumento, `deploy` y `rollback` actúan sobre todos los servicios activos. Con el nombre
de un servicio, solo sobre ese; los demás no se descargan ni se reinician:

```bash
./itc deploy colorado s1              # actualiza solo s1 (cambia antes S1_TAG en instance.env)
./itc rollback colorado s1            # vuelve solo s1 a su etiqueta anterior
./itc stop colorado s0                # detiene s0 sin tocar los demás
./itc logs colorado s1 -f             # logs en vivo de s1
```

Las etiquetas desplegadas y las previas se guardan por servicio, así que el rollback de uno no
afecta al otro. Sin servicio, `rollback` solo revierte los que tengan una etiqueta previa distinta
de la actual. **Quitar un servicio de `COMPOSE_PROFILES` no lo detiene** si ya está corriendo:
usa `./itc stop <instancia> <servicio>`.

## Puertos por instancia

Los puertos del host se publican solo en `127.0.0.1`; un proxy inverso decide qué sale a
internet. Los puertos internos (3200, 3000, 5020, 5050) no se publican.

Cada instancia ocupa un bloque de 10 puertos desde `4100`, y la clave `sN` usa `base + N`:

| Instancia | Base | `S0_PORT` | `S1_PORT` |
|---|---|---|---|
| 1.ª | 4100 | 4100 | 4101 |
| 2.ª | 4110 | 4110 | 4111 |
| n-ésima | 4100 + 10·(n−1) | base | base + 1 |

`./itc new` propone el siguiente bloque libre y avisa si un puerto ya lo usa otra instancia.

## Red privada por instancia

Cada instancia tiene su **propia red de Docker**, `<instancia>_net` (por ejemplo `colorado_net`).
Sus servicios se conectan a ella y se resuelven por nombre (`s0`, `s1`); los de otra
municipalidad están en otra red y no los ven. La red no es `internal`: los contenedores siguen
pudiendo salir al exterior y llegar a Mongo en el host.

| Comunicación | Cómo viaja | ¿Red privada? |
|---|---|---|
| s0 → s1 (TCP, puerto fijo 5020) | `IP_INTERNAL_CONNECTION=s1` en `s0.env` | Sí |
| s1 → s0 (HTTP, 3200) | `AUTH_URL=http://s0:3200` en `s1.env` | Sí |
| Navegadores y apps → servicios | `127.0.0.1:<S0_PORT/S1_PORT>` detrás de un proxy | No (es lo público) |
| Servicios → Mongo | `host.docker.internal` | No (sale al host) |

**`AUTH_URL` requiere una imagen de gueo-back-end que la soporte** (rama `feat/auth-internal-url`
del repo de Gue, commit `445533bc`). Una imagen anterior la ignora y llama a `${IP_SERVER}:3200`,
que en este diseño no está publicado. `./itc deploy` exige que `AUTH_URL` esté definida en `s1.env`.

## Qué es por instancia

Todo lo que podría chocar entre instancias es una variable:

- Nombre del proyecto Compose (`INSTANCE`): aísla la red (`<instancia>_net`) y los volúmenes.
- Nombres de contenedor: `s0_${INSTANCE}`, `s1_${INSTANCE}`.
- Puertos del host, etiquetas de imagen y límites de memoria.
- Carpetas `data/` y `secrets/` dentro de `instances/<instancia>/`.
- Todos los secretos (`JWT_SECRET`, `FEDERATION_ENCRYPTION_KEY`, URI de Mongo, JSON de Firebase). **No los compartas entre instancias.**

## Seguridad

- `instances/*` está en `.gitignore`: ningún `.env` ni secreto entra al git.
- Las imágenes no incluyen `.env`; las variables se inyectan al arrancar.
- Respalda `instances/` aparte: la configuración de cada instancia solo existe en el servidor.

## Riesgos y pendientes conocidos

- **`IP_SERVER` en gueo-back-end** era a la vez la URL pública y la dirección de auth-backend
  (`${IP_SERVER}:3200`). Se separó con `AUTH_URL` (ver "Red privada por instancia"), pero eso
  depende de que la imagen de Gue incluya ese cambio, que hoy está en una rama local de su repo.
- **Mongo en el host:** los contenedores lo alcanzan con `host.docker.internal` (el compose añade
  `extra_hosts` con `host-gateway`). Si Mongo está en otra máquina, usa su dirección en las URI.
- **Chromium:** cada gueo-back-end puede abrir hasta 2 Chromium a la vez; ajusta `S1_MEM_LIMIT`.
- **Sin probar con imágenes reales.** Este repo se validó con `docker compose config` y valores
  de prueba; falta un despliegue real con imágenes publicadas.

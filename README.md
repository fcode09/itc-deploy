# itc-deploy

Despliegue con Docker Compose de los backends de ITC (auth-backend y gueo-back-end).
Usa imágenes ya construidas del registry; no contiene código fuente.

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
- Sesión en el registry de las imágenes (`docker login`). Recomendado: un *deploy token* de solo lectura.
- MongoDB ya disponible en el servidor. **Este repo no levanta Mongo.**
- Usuario con permisos para ejecutar `docker` y `chown` sobre `instances/` (los contenedores corren como uid 1000).

## Estructura

```
itc-deploy/
├─ itc                  # CLI: ./itc help
├─ compose.yaml         # name: ${INSTANCE}; include de services/
├─ services/            # compose-s0.yaml, compose-s1.yaml
├─ templates/           # plantillas versionadas (instance, s0, s1)
├─ instances/           # instancias reales: NO se versionan
├─ scripts/             # lib.sh y cmd/*.sh que usa ./itc
└─ docs/                # catálogo de servicios
```

## Uso

```bash
git clone <este-repo> && cd itc-deploy

./itc new colorado          # crea instances/colorado/ desde las plantillas
# Completa instances/colorado/{instance.env,s0.env,s1.env} y copia los JSON de Firebase a secrets/
./itc deploy colorado       # pull + up -d + espera a que estén healthy

./itc list                  # instancias, servicios, puertos, etiquetas y estado
./itc ps colorado           # estado
./itc logs colorado s1      # logs de un servicio
./itc rollback colorado     # vuelve a las etiquetas anteriores
./itc down colorado         # detiene la instancia
```

Para actualizar una instancia: cambia `S0_TAG` / `S1_TAG` en su `instance.env` y ejecuta
`./itc deploy <instancia>`. Las etiquetas anteriores quedan guardadas para el rollback.
**No uses `latest`**: usa una etiqueta por versión o commit.

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

## Qué es por instancia

Todo lo que podría chocar entre instancias es una variable:

- Nombre del proyecto Compose (`INSTANCE`): aísla redes y volúmenes.
- Nombres de contenedor: `s0_${INSTANCE}`, `s1_${INSTANCE}`.
- Puertos del host, etiquetas de imagen y límites de memoria.
- Carpetas `data/` y `secrets/` dentro de `instances/<instancia>/`.
- Todos los secretos (`JWT_SECRET`, `FEDERATION_ENCRYPTION_KEY`, URI de Mongo, JSON de Firebase). **No los compartas entre instancias.**

## Seguridad

- `instances/*` está en `.gitignore`: ningún `.env` ni secreto entra al git.
- Las imágenes no incluyen `.env`; las variables se inyectan al arrancar.
- Respalda `instances/` aparte: la configuración de cada instancia solo existe en el servidor.

## Riesgos y pendientes conocidos

- **`IP_SERVER` en gueo-back-end** es a la vez la URL pública y la dirección con la que se llama
  a auth-backend (`${IP_SERVER}:3200`). Con varias instancias en un servidor no puede haber un
  único puerto 3200 público; lo limpio es separar ambas variables en el código de Gue. No resuelto aquí.
- **Mongo en el host:** los contenedores lo alcanzan con `host.docker.internal` (el compose añade
  `extra_hosts` con `host-gateway`). Si Mongo está en otra máquina, usa su dirección en las URI.
- **Chromium:** cada gueo-back-end puede abrir hasta 2 Chromium a la vez; ajusta `S1_MEM_LIMIT`.
- **Sin probar con imágenes reales.** Este repo se validó con `docker compose config` y valores
  de prueba; falta un despliegue real con imágenes publicadas.

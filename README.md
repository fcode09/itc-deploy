# deltactl

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
- Bash 4.3 o superior (el código usa arrays asociativos y `nameref`).
- Usuario con permisos para ejecutar `docker` y `chown` sobre `instances/` (los contenedores corren como uid 1000).

## Estructura

```
deltactl/
├─ deltactl             # CLI: ./deltactl help
├─ compose.yaml         # name: ${INSTANCE}; include de services/
├─ services/            # compose-s0.yaml, compose-s1.yaml
├─ templates/           # plantillas versionadas: .env.instance.example, .env.s0.example, .env.s1.example
├─ instances/           # instancias reales: NO se versionan
├─ lib/                 # el código, por capas (ver abajo)
├─ tests/               # suites de pruebas (tests/run.sh) y snapshots de la interfaz (tests/golden/)
└─ docs/                # catálogo de servicios
```

### Arquitectura de `lib/`

Cada capa solo conoce a las de abajo; lo único que toca el exterior son los adaptadores.

```
lib/
├─ bootstrap.sh    # carga todas las capas en orden
├─ i18n/           # idioma (es por defecto, en) y catálogos de mensajes: lo que lee el usuario
├─ ui/             # colores, tablas, banner, mensajes y confirmaciones: cómo se muestra
├─ core/           # reglas: instancias, servicios, imágenes, puertos (sin entrada/salida propia)
├─ adapters/       # docker.sh, state.sh (archivos de la instancia), host.sh (puertos, permisos, disco)
├─ cmd/            # un archivo por comando; se cargan al usarlos
└─ help/           # las páginas de ayuda
```

El código y los comentarios están en inglés; el español es el idioma de la interfaz (se cambia con
`DELTACTL_LANG=en` o con `UI_LANG=en` en `~/.config/deltactl/config`).

## La consola

`./deltactl` es una consola con colores, tablas y ayuda integrada. Todo lo que hace está también en la línea
de comandos; el menú y el asistente solo preguntan por ti y te muestran el comando equivalente.

```bash
./deltactl                        # en una terminal: banner + panel de estado de todas las instancias
./deltactl menu                   # menú interactivo con todas las acciones (con ?4 ves la ayuda de la opción 4)
./deltactl status                 # versión configurada vs la que corre, salud, puertos, uptime y siguientes pasos
./deltactl status colorado        # detalle de una instancia: imagen, previa, memoria/CPU y errores recientes
./deltactl images                 # versiones cargadas, quién las usa, previas para rollback y las que sobran
./deltactl check colorado         # comprueba todo lo que deploy exigiría, sin levantar nada (--mongo prueba las bases)
./deltactl doctor                 # diagnóstico del servidor: Docker, disco, memoria, Mongo, permisos
./deltactl new --wizard           # asistente: pregunta lo esencial y lista lo que falta completar
./deltactl completion bash        # autocompletado con Tab (source <(./deltactl completion bash))
```

El panel `status` avisa de lo que no cuadra y sugiere el comando para arreglarlo: etiqueta configurada distinta
de la que corre, imagen reconstruida con la misma etiqueta, imagen que falta, servicio `unhealthy` o detenido,
servicio que corre fuera de `COMPOSE_PROFILES`, puerto repetido o instancia sin sembrar. Con `--json`
sale en formato para scripts y con `--strict` termina con código 2 si hay avisos (útil en monitoreo).

### Ayuda

```bash
./deltactl help                       # índice de comandos y guías
./deltactl help deploy                # qué hace, ejemplos y errores típicos (también: ./deltactl deploy --help)
./deltactl help nueva-instancia       # guía paso a paso para una instancia nueva
./deltactl help variable S0_TAG       # qué significa cada variable de los .env (sin nombre: todas)
./deltactl help buscar rollback       # busca un texto en toda la ayuda
```

Guías: `nueva-instancia`, `instancia-existente`, `actualizar`, `imagenes`, `servicios`, `red`, `datos`,
`secretos`, `archivos`, `puertos`, `solucion-problemas` y `glosario`. Los mensajes de error terminan con una
pista como `(ayuda: ./deltactl help secretos)`.

La ayuda vive en `lib/help/*.txt` (una página por comando, una guía por tema y el glosario de variables).
Las pruebas fallan si un comando, tema o variable de las plantillas no está documentado, si el glosario
difiere de lo que valida `deploy`, o si una página recomienda algo que no existe.

### Salida plana y colores

Fuera de una terminal (pipes, scripts, logs) la salida es texto plano sin códigos de escape. `NO_COLOR=1`
desactiva los colores, `DELTACTL_COLOR=always|never` los fuerza y `DELTACTL_ASCII=1` evita los caracteres Unicode.

## Uso

```bash
git clone <este-repo> && cd deltactl

./deltactl images                # versiones de imagen cargadas en este servidor y quién las usa
./deltactl new colorado          # crea instances/colorado/ desde las plantillas (o ./deltactl new --wizard)
# Completa instances/colorado/{.env.instance,.env.s0,.env.s1} (S0_TAG y S1_TAG = versiones de ./deltactl images)
# y copia los JSON de Firebase a secrets/
./deltactl check colorado        # comprueba la configuración, las imágenes y los puertos sin levantar nada
./deltactl init colorado         # SOLO si es una municipalidad NUEVA: siembra los datos iniciales y levanta s1 y s0
# (si YA tiene datos: ./deltactl new colorado --existing, o ./deltactl adopt colorado, y luego ./deltactl deploy colorado)

./deltactl list                  # instancias, servicios, puertos, etiquetas, datos y estado
./deltactl ps colorado           # estado
./deltactl logs colorado s1      # logs de un servicio
./deltactl rollback colorado     # vuelve a las etiquetas anteriores
./deltactl down colorado         # detiene la instancia
```

Los archivos de configuración de cada instancia siguen el mismo patrón que las plantillas:
`instances/<instancia>/.env.instance`, `.env.s0` y `.env.s1`. Empiezan con punto, así que `ls` no los
muestra: usa `ls -a`. Ninguno se versiona (`instances/*` está en `.gitignore`).

Guía completa con valores de ejemplo: [`docs/example-new-municipality.md`](docs/example-new-municipality.md)
(archivos completados en [`examples/colorado/`](examples/colorado/)).

Para actualizar una instancia: cambia `S0_TAG` / `S1_TAG` en su `.env.instance` y ejecuta
`./deltactl deploy <instancia>`. Las etiquetas anteriores quedan guardadas para el rollback.
**No uses `latest`**: usa una etiqueta por versión o commit.

## Datos iniciales de una instancia nueva

Los datos iniciales salen de comandos de la CLI que ya vienen en las imágenes (`populating_data_s1`,
`populating_data_s0`, `create_root_user`, `url_systems`). Son **destructivos**: hacen `drop` de colecciones
y el seed de s0 le ordena a s1, por TCP, que **vacíe su tabla de usuarios**. Por eso `./deltactl deploy` **nunca
siembra**: sembrar y actualizar son cosas separadas.

**`./deltactl init <instancia>`** (solo para municipalidades **nuevas**, una sola vez) hace, en este orden:
1. Comprueba que las tablas de usuarios de Auth (`usuarios`) y Gue (`users`) estén vacías; si tienen datos, **se niega**.
2. Seed de s1 (catálogos).
3. Levanta s1 y espera a que esté `healthy`: **s1 tiene que estar arriba** cuando corre el seed de s0, o no se
   sincroniza ningún usuario con él (Auth avisa `GUEP SERVER IS DOWN!`).
4. Seeds de s0 en la red privada de la instancia: `populating_data_s0` (vacía los usuarios de s1 y vuelve a
   enviarle los de seed), `create_root_user` (superuser, root y deltadispatch, en Auth y en Gue) y `url_systems`.
5. Levanta s0 y escribe el marcador `.initialized`.

Salvaguardas: no hay `--force`; con el marcador presente `init` no se vuelve a ejecutar; los seeds terminan
siempre con código 0 aunque fallen, así que `init` **lee su log** (sin `Ocurred an error` y con los pasos
esperados: 30 en s1 y al menos 17 en s0); si algo falla, **no marca la instancia**, deja el log en
`instances/<instancia>/init-logs/` y te pide limpiar las bases a mano antes de reintentar.
`SPIDER SERVER IS DOWN!` es normal (no hay servidor Spider en este despliegue).

**Municipalidades que ya existen con datos reales** (por ejemplo las que hoy corren con PM2): nunca se les
hace `init`. Usa `./deltactl new <x> --existing` al crearlas, o `./deltactl adopt <x>` si la instancia ya estaba
creada, apunta sus URI a las bases actuales y despliega con `./deltactl deploy`.

**Actualizar** una instancia sembrada es solo `./deltactl deploy`: no repuebla ni borra datos (verificado). La
columna `DATOS` de `./deltactl list` muestra `init`, `existente` o `sin sembrar`.

**Requisitos:** imágenes de gueo-back-end con `TCP_LISTEN_HOST` (para que s0 alcance a s1) y
`TCP_LISTEN_HOST=0.0.0.0` en `.env.s1`. Los usuarios root y superuser salen con contraseñas **fijas en el
código de Auth**: cámbialas tras el primer login.

## Imágenes locales (sin registry)

Construir las imágenes, empaquetarlas y copiarlas al servidor **queda fuera de este repo**. Este
repo empieza cuando la imagen ya está en el Docker del servidor.

**Cómo funciona.** Docker lee las imágenes de su propio almacén (normalmente `/var/lib/docker`),
no de una carpeta. Con `REGISTRY` vacío en `.env.instance`, el compose usa `<S0_IMAGE>:<S0_TAG>` y
`<S1_IMAGE>:<S1_TAG>` tal cual están en ese almacén (por defecto `auth-backend` y `gueo-back-end`), y
**no descarga nada**. Cada instancia elige su versión con sus etiquetas, así que pueden convivir versiones
distintas en el mismo servidor.

**Nombre de la imagen.** El nombre (sin etiqueta ni registry) se define en `.env.instance` con `S0_IMAGE` y
`S1_IMAGE`; si no existen, valen `auth-backend` y `gueo-back-end`. Si construiste las imágenes con otro
nombre (por ejemplo `s0` y `s1`), ponlo ahí: `S0_IMAGE=s0`, `S1_IMAGE=s1`. Debe construirse con ese mismo
nombre: `docker build -t s1:1.0.0 .`. Formato: minúsculas, números y `. _ - `; admite `/` para rutas; **sin
`:`** (la etiqueta va en `S1_TAG`). Cada instancia puede usar nombres distintos. Con un `REGISTRY` se
antepone: `<registry>/<S1_IMAGE>:<S1_TAG>`.

**Solo cuenta el archivo.** `deltactl` ignora las variables de la instancia (`S0_IMAGE`, `S1_TAG`, `REGISTRY`,
puertos, límites, `DATA_DIR`, `COMPOSE_PROFILES`, `COMPOSE_FILE`...) aunque estén exportadas en tu shell,
para que lo que valida sea siempre lo que Docker despliega. Escríbelas en `.env.instance`.

**Cargar una imagen que llegó como archivo** (el resultado de `docker save`, comprimido o no):

```bash
./deltactl load imagenes-2026-11-16.tar.gz   # equivale a docker load; el archivo se puede borrar después
./deltactl images                            # ver qué etiquetas quedaron y cuáles usa cada instancia
```

**Comprobaciones de `./deltactl deploy` (con `REGISTRY` vacío):**
- Que cada imagen exista en este Docker; si falta, dice cuál y cómo cargarla.
- Que su arquitectura sea la del servidor (aviso).
- Con `PULL_POLICY=never`, para que si falta una imagen Docker no baje de Docker Hub una imagen
  homónima que no es la nuestra.
- Que la etiqueta no apunte ahora a otra imagen distinta de la desplegada antes (aviso): una etiqueta
  local se puede reconstruir. **No reutilices etiquetas**; usa una versión nueva por build.

**Rollback:** exige que la imagen previa siga cargada, y avisa si su ID cambió. Por eso **no borres
versiones viejas**: `./deltactl images` marca las que ninguna instancia usa (ni como actual ni como previa)
como candidatas a borrar, pero solo lista. Evita `docker image prune -a` y `docker system prune -a`.

**Con registry:** pon su ruta en `REGISTRY` (ej. `registry.ejemplo.com/itc`) y `deploy` hará `pull`.
El resto no cambia.

## Elegir qué servicios corre cada instancia

`COMPOSE_PROFILES` en `.env.instance` lista los servicios activos de la instancia. Un servicio que
no está en la lista no se descarga ni se levanta, y no se le exige configuración.

```
COMPOSE_PROFILES=s0,s1       # los dos
COMPOSE_PROFILES=s1          # solo Gue (Auth corre en otro lugar)
COMPOSE_PROFILES=s0,s1,s3    # "todos menos s2": listas los que sí quieres
```

`./deltactl new <instancia> --services s1` crea la instancia ya con esa lista. Un servicio nuevo que se
añada al repo **no** se activa solo en instancias existentes: hay que sumarlo a su lista.

## Actuar sobre un solo servicio

Sin argumento, `deploy` y `rollback` actúan sobre todos los servicios activos. Con el nombre
de un servicio, solo sobre ese; los demás no se descargan ni se reinician:

```bash
./deltactl deploy colorado s1              # actualiza solo s1 (cambia antes S1_TAG en .env.instance)
./deltactl rollback colorado s1            # vuelve solo s1 a su etiqueta anterior
./deltactl stop colorado s0                # detiene s0 sin tocar los demás
./deltactl logs colorado s1 -f             # logs en vivo de s1
```

Las etiquetas desplegadas y las previas se guardan por servicio, así que el rollback de uno no
afecta al otro. Sin servicio, `rollback` solo revierte los que tengan una etiqueta previa distinta
de la actual. **Quitar un servicio de `COMPOSE_PROFILES` no lo detiene** si ya está corriendo:
usa `./deltactl stop <instancia> <servicio>`.

## Puertos por instancia

Los puertos del host se publican solo en `127.0.0.1`; un proxy inverso decide qué sale a
internet. Los puertos internos (3200, 3000, 5020, 5050) no se publican.

Cada instancia ocupa un bloque de 10 puertos desde `4100`, y la clave `sN` usa `base + N`:

| Instancia | Base | `S0_PORT` | `S1_PORT` |
|---|---|---|---|
| 1.ª | 4100 | 4100 | 4101 |
| 2.ª | 4110 | 4110 | 4111 |
| n-ésima | 4100 + 10·(n−1) | base | base + 1 |

`./deltactl new` propone el siguiente bloque libre y avisa si un puerto ya lo usa otra instancia.

## Red privada por instancia

Cada instancia tiene su **propia red de Docker**, `<instancia>_net` (por ejemplo `colorado_net`).
Sus servicios se conectan a ella y se resuelven por nombre (`s0`, `s1`); los de otra
municipalidad están en otra red y no los ven. La red no es `internal`: los contenedores siguen
pudiendo salir al exterior y llegar a Mongo en el host.

| Comunicación | Cómo viaja | ¿Red privada? |
|---|---|---|
| s0 → s1 (TCP, puerto fijo 5020) | `IP_INTERNAL_CONNECTION=s1` en `.env.s0` **y** `TCP_LISTEN_HOST=0.0.0.0` en `.env.s1` | Sí (el puerto no se publica) |
| s1 → s0 (HTTP, 3200) | `AUTH_URL=http://s0:3200` en `.env.s1` | Sí |
| Navegadores y apps → servicios | `127.0.0.1:<S0_PORT/S1_PORT>` detrás de un proxy | No (es lo público) |
| Servicios → Mongo | `host.docker.internal` | No (sale al host) |

**Estas dos variables requieren una imagen de gueo-back-end que las soporte** (commits `445533bc`
para `AUTH_URL` y `4ca9913b` para `TCP_LISTEN_HOST`, en la rama `feat/docker-backend` del repo de Gue):
- Una imagen anterior ignora `AUTH_URL` y llama a `${IP_SERVER}:3200`, que en este diseño no está publicado.
- Una imagen anterior ignora `TCP_LISTEN_HOST` y su TCP 5020 queda solo en `127.0.0.1`: s0 no lo alcanza
  y la sincronización de ajustes hacia Gue se omite en silencio.

`./deltactl deploy` exige `AUTH_URL` en `.env.s1` y avisa si s0 está activo y `TCP_LISTEN_HOST` no lo está.

**Despliegues sin Docker (PM2):** no cambian. `TCP_LISTEN_HOST` sin definir deja el TCP en `127.0.0.1`,
como siempre, y `AUTH_URL` sin definir usa `${IP_SERVER}:3200`. Ambas variables solo se definen en Docker.

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

## Pruebas

```bash
tests/run.sh                       # todas las suites
tests/run.sh test-help test-menu   # algunas
```

`tests/run.sh` copia el repositorio a una carpeta temporal con `instances/` vacío antes de ejecutar cada suite:
ninguna prueba puede tocar instancias reales. Usan un `docker` simulado (`tests/fake-docker.sh`), así que no
levantan contenedores ni necesitan Docker: cubren la capa visual, `status`, `images`, la ayuda y su coherencia
con el código, `check`, `doctor`, el asistente, el menú y el autocompletado.

## Riesgos y pendientes conocidos

- **`IP_SERVER` en gueo-back-end** era a la vez la URL pública y la dirección de auth-backend
  (`${IP_SERVER}:3200`). Se separó con `AUTH_URL` (ver "Red privada por instancia"), pero eso
  depende de que la imagen de Gue incluya ese cambio, que hoy está en una rama local de su repo.
- **Mongo en el host:** los contenedores lo alcanzan con `host.docker.internal` (el compose añade
  `extra_hosts` con `host-gateway`). Si Mongo está en otra máquina, usa su dirección en las URI.
- **Chromium:** cada gueo-back-end puede abrir hasta 2 Chromium a la vez; ajusta `S1_MEM_LIMIT`.
- **Sin probar con imágenes reales.** Este repo se validó con `docker compose config` y valores
  de prueba; falta un despliegue real con imágenes publicadas.

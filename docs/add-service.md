# Cómo sumar un servicio nuevo

Un servicio se define **una sola vez**, en `lib/core/catalog.data` (una línea). El asistente de nueva instancia, la pestaña
Servicios del panel, `./deltactl service add`, `new`, `check`, `deploy`, la ayuda y el completado leen esa línea: no hace falta
tocar código de pantallas ni de comandos. Lo demás son archivos de datos: un compose, una plantilla de variables y los textos.

El ejemplo recorre el caso real de **Robin = `robin`**. Los servicios que aún no existen aquí (Walle, Link) siguen el mismo camino.

## 1. Decidir los datos antes de escribir nada

| Dato | Cómo se decide | Robin (`robin`) |
|---|---|---|
| Clave | una palabra en minúsculas y dígitos que empieza con letra (`s0`, `s1`, `robin`, `walle`); no puede ser `instance`. Da el nombre del servicio en Compose, del contenedor (`<clave>_<instancia>`), de `.env.<clave>`, de la carpeta `data/<clave>/` y de las variables de la instancia (`<CLAVE>_TAG`, `<CLAVE>_PORT`…) | `robin` |
| Nombre e imagen | `backend-<clave>`, como `s0` y `s1` | `backend-robin` |
| Puerto interno | el que abre el código (`app.listen`, `SERVER_PORT`/`PORT`) | 3601 |
| Desplazamiento de puerto | el siguiente al del último servicio; el puerto del host es `S0_PORT` + desplazamiento | 2 |
| Variables | `process.env.*` y `configService.get(...)` del código del servicio | ver `templates/.env.robin.example` |
| Obligatorias | las que, sin valor, el servicio no arranca o se comporta mal (por ejemplo un secreto con valor por defecto en el código) | `JWT_SECRET ROBIN_MONGO_URI KAFKA_BROKER_IP KAFKA_BROKER_PORT KAFKA_TOPIC KAFKA_GROUP_ID DELTA_DISPATCH_URL` |
| URI de Mongo | variables que apuntan a una base; `check` las comprueba | `ROBIN_MONGO_URI` |
| Dependencias suaves | servicios de la instancia que este usa (solo avisa si faltan) | `s1` (Delta Dispatch) |
| Memoria | medida en el panel (vista Recursos); un valor inicial razonable | `256m` (provisional) |
| Carpetas de datos | destinos de escritura del código (por ejemplo los de multer) | `media/file`, `geofence` |
| Archivos de `secrets/` | ficheros que el servicio lee (JSON, certificados) | ninguno |
| Secretos que se generan | `shared` (el mismo en todos los servicios), `hex32`, `hex24`, `b64-32` | `JWT_SECRET:shared` |

**Lo que no se ve en el código no se inventa:** si el servicio trae un `.env` que no puedes leer, pide a su equipo la lista de
variables antes de dar la plantilla por buena.

## 2. Lista de pasos

| # | Archivo | Qué | Si falta |
|---|---|---|---|
| 0 | Dockerfile (en el repo **del servicio**, no en este) | imagen `backend-<clave>:<etiqueta>` cargada con `./deltactl load` o publicada en un registry | el servicio aparece en el panel pero `deploy` se detiene: la imagen no existe |
| 1 | `services/compose-<clave>.yaml` | el servicio, copiado de `compose-s0.yaml`/`compose-s1.yaml` | `deploy` falla |
| 2 | `compose.yaml` | una línea en `include:` (no admite comodines) | el compose no ve el servicio |
| 3 | `templates/.env.<clave>.example` | las variables, con su valor de ejemplo | `new` y `service add` no pueden crear su `.env.<clave>` |
| 4 | `templates/.env.instance.example` | `<CLAVE>_IMAGE`, `<CLAVE>_TAG`, `<CLAVE>_PORT`, `<CLAVE>_MEM_LIMIT` | `tests/run.sh test-help` falla |
| 5 | `lib/core/catalog.data` | la línea del servicio (13 campos separados por `\|`) | el servicio no existe para deltactl |
| 6 | `lib/i18n/{es,en}/common.sh` | `catalog.desc.<clave>`: lo que es, en una frase | `test-help` y `test-catalog` fallan |
| 7 | `lib/help/variables.txt` y `lib/help/en/variables.txt` | cada variable de la plantilla (y las `fija`) | `test-help` falla |
| 8 | `lib/core/envschema.data` | solo las variables cuyo nombre no basta para validarlas (ver abajo) | la variable se valida como texto |
| 9 | `lib/screens/wizard.sh` | solo el nombre corto de la tarjeta (`dash_nw_svc_name`) y quitar el servicio de la nota «aún sin Docker» | el asistente muestra `ROBIN` y sigue diciendo «sin Docker» |
| 10 | `docs/services-catalog.md` y `README.md` | tabla de servicios | documentación vieja |

Los pasos 1 a 7 son obligatorios; 8 y 9 solo cuando aplican. Un servicio con una regla propia (una comprobación previa al
despliegue) define `preflight_extra_<clave>` en `lib/cmd/deploy.sh`, como la de `s1`.

### Detalle de la línea del catálogo (paso 5)

```
# clave|nombre|imagen|puerto interno|desplaz.|plantilla|obligatorias|Mongo|dependencias|memoria|carpetas de datos|archivos de secrets/|secretos a generar
robin|backend-robin|backend-robin|3601|2|.env.robin.example|JWT_SECRET ROBIN_MONGO_URI …|ROBIN_MONGO_URI|s1|256m|media/file geofence||JWT_SECRET:shared
```

Las listas van separadas por espacio. Un campo vacío se deja vacío, pero el número de campos debe seguir siendo 13
(`test-catalog` lo comprueba).

### Notas del compose (paso 1)

- `image` con `${REGISTRY:+…}` y `${<CLAVE>_TAG:?…}`, `pull_policy: ${PULL_POLICY:-missing}`, `container_name: <clave>_${INSTANCE}` y
  `profiles: ["<clave>"]`: así el servicio solo corre donde `COMPOSE_PROFILES` lo lista.
- `env_file` con el `.env.<clave>` de la instancia: **cualquier variable nueva de ese archivo llega al contenedor sin tocar el compose.**
  Solo va en `environment:` lo que el compose debe **fijar** (el puerto interno).
- Puerto publicado solo en `127.0.0.1:${<CLAVE>_PORT}`.
- Datos bajo `${DATA_DIR:-./instances/${INSTANCE}/data}/<clave>/…`: las carpetas del campo «carpetas de datos» las crea `new`/`service add`.
- Si depende de otro servicio, `depends_on` con `required: false` (la instancia puede no tenerlo). Usa `service_healthy` solo si
  ese servicio tiene `healthcheck`; si no, `service_started`.

## 3. Variables de entorno nuevas

Cada variable se declara en **dos** sitios, y `tests/run.sh test-help` falla mientras no coincidan:

1. `templates/.env.<clave>.example`: la clave con su valor de ejemplo (los marcadores `CAMBIAR_<nombre>_INSTANCIA` se reemplazan por
   `<nombre>_<instancia>` al crear la instancia).
2. El glosario, en español y en inglés:
   ```
   @ ROBIN_X | .env.robin | opcional | 10
   Qué hace y qué pasa si falta.
   ```
   Tipos: `obligatoria`, `opcional` o `fija` (la fija el compose o la imagen; no va en el `.env`). En inglés: `required`, `optional`, `fixed`.

Además:

- **Obligatoria:** añádela también al campo «obligatorias» de su línea en `catalog.data`. Una obligatoria nueva hace que `deploy`
  falle en las instancias que ya existen hasta que la completen: si no es imprescindible, hazla opcional.
- **Validación:** sale del nombre (`*_PORT` puerto, `*_URL` URL, `*_SECRET`/`*_API_KEY` secreto, `*_ENABLED` verdadero o falso,
  `MONGO*URI` URI de Mongo…). Solo si el nombre no basta, una línea en `lib/core/envschema.data`
  (`URI_SIPCOPM|url|0`). Ver [env-variables.md](env-variables.md).
- **Compose:** no se toca (usa `env_file`).

### Instancias que ya existen: `env sync`

Las plantillas solo se copian al **crear** el archivo: una instancia que ya existe no recibe las variables que se agregan después.
`env sync` compara los `.env` de la instancia con las plantillas actuales y agrega lo que falta:

```bash
./deltactl env <instancia> sync              # solo mira: qué variables nuevas le faltan a cada archivo (y cuáles ya no están)
./deltactl env <instancia> sync --apply      # las escribe al final de cada archivo, con su comentario y su valor de ejemplo
./deltactl env <instancia> sync robin        # un servicio concreto, aunque la instancia no lo corra
./deltactl env <instancia> pending           # el archivo queda como cambio sin desplegar
./deltactl deploy <instancia> robin          # el contenedor lee el .env al arrancar
```

- **Solo agrega.** Nunca cambia un valor que ya está ni borra nada (lo que el `.env` tiene y la plantilla ya no, solo se avisa). Deja
  `<archivo>.bak` (permiso 600) y escribe de forma atómica, igual que `env set`.
- **Las obligatorias nuevas quedan «por completar»** (traen el valor de ejemplo `CAMBIAR…` o vacío): complétalas en la vista Variables
  o con `env set`.
- **Los servicios que la instancia no corre no se revisan** (no están en `COMPOSE_PROFILES`), salvo que se pidan por su nombre.
- **Dónde se ve sin ejecutar nada:** el chip «N nuevas de la plantilla» de la vista Variables (tecla `9` o la pestaña Variables de la
  instancia; `A` las agrega, pidiendo confirmación con `s`), el cuadro «usar versión» de la vista Imágenes, `./deltactl check` y
  `./deltactl service set … tag`.
- **Es la plantilla de deltactl, no la de la imagen.** Si una versión nueva de un servicio necesita una variable, primero va a la
  plantilla y al glosario de este repo; con `git pull` en el servidor, `env sync` la ofrece a todas las instancias.

## 4. Activarlo en una instancia

- **Instancia nueva:** el asistente (`n` en el panel, o `./deltactl new <nombre> --services s0,s1,robin`) lo ofrece en el paso
  Servicios, con su puerto y su memoria.
- **Instancia que ya existe:** pestaña **Servicios** del panel, o

  ```bash
  ./deltactl service add <instancia> robin --tag <versión> --generate-secrets
  # completa instances/<instancia>/.env.robin (las obligatorias que falten)
  ./deltactl deploy <instancia> robin
  ```

  `service add` crea el `.env.robin` y las carpetas de `data/`, busca un puerto libre, copia los secretos compartidos (`JWT_SECRET`) y lo
  suma a `COMPOSE_PROFILES`. No arranca nada. Pasa `--tag`: sin él `ROBIN_TAG` queda vacío y `deploy` se detiene en la comprobación previa.
  Con `service remove` se quita conservando sus variables y sus datos.

## 5. Comprobarlo

```bash
bash tests/run.sh test-help test-catalog test-envschema test-service   # glosario, catálogo, esquema y service
DELTACTL_GOLDEN=record bash tests/run.sh test-golden                   # SOLO si la pantalla cambió a propósito; revisa el diff
./deltactl new prueba --services s0,s1,robin && ./deltactl check prueba   # en un servidor de pruebas, con Docker real
```

Las pruebas corren sobre una copia aislada (`tests/run.sh`): nunca tocan `instances/`. En Windows: `wsl.exe -e bash -lc 'cd /mnt/e/ITC/itc-deploy && bash tests/run.sh test-help'`.

## 6. Trampas conocidas

- **Las pruebas conocen el catálogo.** Varias suites asumen cuántos servicios hay (`s0 s1 robin`) y los golden de pantalla
  muestran la lista. Al sumar uno, actualiza esas expectativas y re-graba los golden. `test-catalog` usa una clave ficticia
  (`walle`) para probar «un servicio nuevo es una línea de datos»: elige una clave que no exista en el catálogo real.
- **Dockerfile:** el patrón de imagen ejecuta `npm prune --omit=dev`; todo lo que el código use en ejecución debe estar en
  `dependencies`, no en `devDependencies`.
- **Secretos por defecto en el código:** si el servicio tiene un valor por defecto para un secreto (Robin trae uno para
  `JWT_SECRET`), la variable es obligatoria y compartida: un valor conocido en producción es un agujero.
- **Dentro del contenedor, `127.0.0.1` es el propio contenedor.** Lo que corre en el host (Mongo, Kafka) se alcanza por
  `host.docker.internal`; lo que corre en otro servicio de la instancia, por su nombre (`http://s1:3000`).
- **Saltos de línea:** en Windows, `catalog.data` y `envschema.data` pueden salir con CRLF; Git los normaliza (`.gitattributes`) y
  el cargador ignora el `\r` final.

## Servicio ya definido pero sin imagen

Mientras no exista la imagen, el servicio aparece en el panel y se puede activar en una instancia, pero `deploy` se detiene al
comprobar que la imagen no está. Es lo esperado: construye la imagen (paso 0) y cárgala con `./deltactl load` o publícala.

# Ejemplo: dar de alta una municipalidad nueva ("colorado")

Guía de punta a punta con valores de ejemplo. Los archivos completados están en
[`examples/colorado/`](../examples/colorado/): **son ficticios**, genera los tuyos.
Cada municipalidad es una **instancia** de este repo (ver el README).

## 0. Antes de empezar

- Las imágenes `backend-s0` (s0) y `backend-s1` (s1) ya están **cargadas en el Docker del servidor**
  (`./deltactl load <archivo>` si llegaron como archivo de `docker save`), con la etiqueta que vas a desplegar.
  Compruébalo con `./deltactl images`. Con un registry, déjalas publicadas y pon su ruta en `REGISTRY`.
- El servidor tiene Docker Compose 2.20 o superior.
- Existe un MongoDB en el servidor. Decide los **nombres de base** de esta municipalidad (el ejemplo usa `colorado_authsoftware`, `colorado_deltadispatch` y `colorado_robin`); no compartas bases entre instancias.
- Tienes los dos JSON de cuenta de servicio de Firebase **de esa municipalidad**.

## 1. Crear la instancia

```bash
./deltactl new colorado
```

Crea `instances/colorado/` con `.env.instance`, `.env.s0`, `.env.s1`, `secrets/` y `data/`, y propone el
siguiente bloque de puertos libre. Para una municipalidad que solo usará Gue: `./deltactl new colorado --services s1`.

## 2. Completar la configuración

Compara tus archivos con los de [`examples/colorado/`](../examples/colorado/):

| Archivo | Qué completar |
|---|---|
| `.env.instance` | `S0_TAG` y `S1_TAG` (una etiqueta por versión), `S0_IMAGE` y `S1_IMAGE` (solo si construiste las imágenes con otro nombre), `REGISTRY`, y revisar `COMPOSE_PROFILES` y puertos |
| `.env.s0` | `IP_SERVER`, `JWT_SECRET`, `MONGO_URI`, `GOOGLE_KEY` |
| `.env.s1` | `IP_SERVER`, `AUTH_URL` (déjala en `http://s0:3200`), `JWT_SECRET`, las tres URI de Mongo, `FEDERATION_ENCRYPTION_KEY`, `DEEPGRAM_API_KEY`, `DELTA_UNIVERSITY_HANDOFF_SECRET` |

Secretos únicos por instancia (no los reutilices entre municipalidades):

```bash
openssl rand -hex 32      # JWT_SECRET
openssl rand -base64 32   # FEDERATION_ENCRYPTION_KEY (base64 de exactamente 32 bytes)
```

## 3. Copiar los JSON de Firebase

Copia los dos archivos a `instances/colorado/secrets/` con **estos nombres**, porque `.env.s1` los
referencia así (`FCM_CERT=/run/secrets/fcm.json`, `KEEPER_FCM_CERT=/run/secrets/keeper-fcm.json`):

| Archivo | Para qué |
|---|---|
| `fcm.json` | Cuenta de servicio de Firebase de la app principal |
| `keeper-fcm.json` | Cuenta de servicio de Firebase de Keeper |

El contenedor los lee como el uid 1000 (usuario `node`), en solo lectura:

```bash
sudo chown 1000:1000 instances/colorado/secrets/*.json
chmod 600 instances/colorado/secrets/*.json
```

## 4. Inicializar y desplegar

**Municipalidad nueva** (sin datos): una sola vez,

```bash
./deltactl init colorado
```

Comprueba que las bases estén vacías, siembra los datos iniciales en el orden correcto (seed de s1, s1
arriba, seeds de s0 con su sincronización de usuarios) y deja s1 y s0 corriendo y `healthy`. Se niega si
las bases ya tienen datos. Tras el primer login, cambia las contraseñas de `root` y `superuser`.

**Municipalidad que ya existe con datos**: apunta sus URI a las bases actuales, crea la instancia con
`./deltactl new colorado --existing` (o `./deltactl adopt colorado` si ya estaba creada) y despliega:

```bash
./deltactl deploy colorado
```

`deploy` valida la configuración (avisa de variables vacías, valores de ejemplo y JSON faltantes),
comprueba que las imágenes con esas etiquetas estén cargadas en el servidor (con un registry, las
descarga), levanta los servicios y espera a que estén `healthy`. **Nunca siembra datos**.

## 5. Comprobar

```bash
./deltactl list                # servicios, puertos, etiquetas y estado
./deltactl ps colorado         # contenedores s0_colorado y s1_colorado
./deltactl logs colorado s1    # logs de Gue
```

## 6. Operar después

```bash
# actualizar solo Gue: cambia S1_TAG en .env.instance y
./deltactl deploy colorado s1

# volver atrás solo ese servicio
./deltactl rollback colorado s1

# detener un servicio sin tocar el otro
./deltactl stop colorado s0
```

## Segunda municipalidad en el mismo servidor

```bash
./deltactl new tarapoto
```

| Instancia | Contenedores | Puertos (`S0`/`S1`) | Bases de Mongo |
|---|---|---|---|
| `colorado` | `s0_colorado`, `s1_colorado` | 4100 / 4101 | `colorado_*` |
| `tarapoto` | `s0_tarapoto`, `s1_tarapoto` | 4110 / 4111 | `tarapoto_*` |

Cada una tiene sus propios secretos, JSON de Firebase, carpeta `data/` y etiquetas. Actualizar o
detener una no afecta a la otra.

## Qué no cubre este ejemplo

- **Proxy inverso y TLS:** los puertos se publican solo en `127.0.0.1`; qué sale a internet y con qué
  dominio lo decide un proxy que no forma parte de este repo.
- **`IP_SERVER`:** el valor del ejemplo (`203.0.113.10`) es una dirección de documentación. Con
  `AUTH_URL=http://s0:3200`, Gue llama a Auth por la red privada `colorado_net` y `IP_SERVER` queda
  solo como URL pública; eso exige una imagen de Gue con soporte de `AUTH_URL` (ver el README).
- **Walle, Robin y Link:** todavía no se despliegan con este repo (ver `docs/services-catalog.md`).

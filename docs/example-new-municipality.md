# Ejemplo: dar de alta una municipalidad nueva ("colorado")

Guía de punta a punta con valores de ejemplo. Los archivos completados están en
[`examples/colorado/`](../examples/colorado/): **son ficticios**, genera los tuyos.
Cada municipalidad es una **instancia** de este repo (ver el README).

## 0. Antes de empezar

- Las imágenes `auth-backend` (s0) y `gueo-back-end` (s1) ya están **cargadas en el Docker del servidor**
  (`./itc load <archivo>` si llegaron como archivo de `docker save`), con la etiqueta que vas a desplegar.
  Compruébalo con `./itc images`. Con un registry, déjalas publicadas y pon su ruta en `REGISTRY`.
- El servidor tiene Docker Compose 2.20 o superior.
- Existe un MongoDB en el servidor. Decide los **nombres de base** de esta municipalidad (el ejemplo usa `colorado_authsoftware`, `colorado_deltadispatch` y `colorado_robin`); no compartas bases entre instancias.
- Tienes los dos JSON de cuenta de servicio de Firebase **de esa municipalidad**.

## 1. Crear la instancia

```bash
./itc new colorado
```

Crea `instances/colorado/` con `instance.env`, `s0.env`, `s1.env`, `secrets/` y `data/`, y propone el
siguiente bloque de puertos libre. Para una municipalidad que solo usará Gue: `./itc new colorado --services s1`.

## 2. Completar la configuración

Compara tus archivos con los de [`examples/colorado/`](../examples/colorado/):

| Archivo | Qué completar |
|---|---|
| `instance.env` | `S0_TAG` y `S1_TAG` (una etiqueta por versión), `REGISTRY`, y revisar `COMPOSE_PROFILES` y puertos |
| `s0.env` | `IP_SERVER`, `JWT_SECRET`, `MONGO_URI`, `GOOGLE_KEY` |
| `s1.env` | `IP_SERVER`, `AUTH_URL` (déjala en `http://s0:3200`), `JWT_SECRET`, las tres URI de Mongo, `FEDERATION_ENCRYPTION_KEY`, `DEEPGRAM_API_KEY`, `DELTA_UNIVERSITY_HANDOFF_SECRET` |

Secretos únicos por instancia (no los reutilices entre municipalidades):

```bash
openssl rand -hex 32      # JWT_SECRET
openssl rand -base64 32   # FEDERATION_ENCRYPTION_KEY (base64 de exactamente 32 bytes)
```

## 3. Copiar los JSON de Firebase

Copia los dos archivos a `instances/colorado/secrets/` con **estos nombres**, porque `s1.env` los
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

## 4. Desplegar

```bash
./itc deploy colorado
```

Valida la configuración (avisa de variables vacías, valores de ejemplo y JSON faltantes), comprueba
que las imágenes con esas etiquetas estén cargadas en el servidor (con un registry, las descarga),
levanta los servicios y espera a que estén `healthy`.

## 5. Comprobar

```bash
./itc list                # servicios, puertos, etiquetas y estado
./itc ps colorado         # contenedores s0_colorado y s1_colorado
./itc logs colorado s1    # logs de Gue
```

## 6. Operar después

```bash
# actualizar solo Gue: cambia S1_TAG en instance.env y
./itc deploy colorado s1

# volver atrás solo ese servicio
./itc rollback colorado s1

# detener un servicio sin tocar el otro
./itc stop colorado s0
```

## Segunda municipalidad en el mismo servidor

```bash
./itc new tarapoto
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

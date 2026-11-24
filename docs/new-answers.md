# Lo que `new` recibe además del nombre

`./deltactl new <instancia>` crea la carpeta de la instancia desde las plantillas. Además de `--services`, `--existing`, las imágenes y las versiones
(`--sN-image`, `--sN-tag`), `--ip` y `--generate-secrets`, acepta cuatro grupos de respuestas más. Existen para el asistente por pasos del panel
(`docs/panel-pendiente.md`) y sirven igual desde un script. Todas se **comprueban antes de crear nada**: si una no vale, `new` termina con el motivo y no deja
una carpeta a medias.

## `--env-file ARCHIVO`: variables, sin pasar por la línea de comandos

Líneas `<archivo>:<CLAVE>=<valor>`, donde `<archivo>` es `instance` (`.env.instance`) o un servicio (`s0`, `s1`…; es el de `.env.<servicio>`). Se saltan las
líneas en blanco y las que empiezan con `#`; un fin de línea de Windows se acepta.

```
s0:IP_SERVER=https://muni.example.com
s1:IP_SERVER=https://muni.example.com
s0:IP_INTERNAL_CONNECTION=s1
instance:S0_PORT=4300
```

- **Por qué un archivo**: un secreto en la línea de comandos queda en `ps` y en el historial del shell. El panel escribe el archivo con modo 600 en su carpeta
  temporal solo mientras corre el comando y lo borra al terminar. `new` lo lee y **no lo borra**: es de quien lo pasó.
- **Se valida con las reglas de las variables** (`lib/core/envschema.sh`, las mismas de `./deltactl env set` y de `./deltactl help variable`). Una que no pasa
  detiene `new` con el nombre de la variable; **el valor no se muestra nunca** (puede ser un secreto), ni el de una línea mal escrita: se dice el número de línea.
  Un servicio que la instancia no tiene (`--services`) es un error.
- **Puertos**: si da `S0_PORT` o `S1_PORT`, ese puerto es el que se comprueba (que no lo use otra instancia) y el que se escribe.
- **Prioridad**: pesa más que `--generate-secrets` y que `--ip`; lo que la persona puso es lo que queda.
- Se escribe con `envedit_save` (atómico, conserva comentarios y orden, modo 600 en los secretos). No deja `.bak`: el archivo acaba de crearse, no hay a qué volver.

## `--secret-file ORIGEN[:NOMBRE]`: archivos para `secrets/`

Copia `ORIGEN` a `instances/<instancia>/secrets/<NOMBRE>` con modo 600 (por ejemplo el JSON de Firebase: `--secret-file ~/Descargas/firebase.json:fcm.json`; sin
`:NOMBRE` se conserva el nombre del origen). Se puede repetir.

- **Qué se comprueba** (`lib/core/secretfile.sh`): que exista, sea un archivo, se pueda leer, no esté vacío, no pase de 128 KiB y sea un **objeto JSON** (se lee
  con Bash, sin `jq`). El contenido no se muestra nunca: el motivo se dice con la ruta.
- **El nombre** lleva letras, números, punto, guion y guion bajo, hasta 64 caracteres; sin `/`, sin `..`, sin empezar con punto o guion.
- **Qué nombre ponerle**: el que dice la variable que lo usa. `FCM_CERT=/run/secrets/fcm.json` es `fcm.json`; la lista de variables que apuntan a un archivo está en
  el catálogo de servicios (`lib/core/catalog.data`, el campo de los archivos de `secrets/`).
- **Dónde las busca el panel**: `lib/core/secretfile.sh` (`sf_candidates`) mira solo los **nombres** de los `*.json` de Descargas, la carpeta del usuario, la
  actual y la del repositorio que parecen una cuenta de servicio (`*firebase*`, `*adminsdk*`, `*service*account*`, `*fcm*`, `*keeper*`); no abre ninguno hasta que
  se elige. En las pruebas `DELTACTL_SECRET_DIRS` reemplaza esas carpetas.

## `--domain DOMINIO [--proxy nginx|caddy|both] [--tls]`: el bloque del proxy

Genera el texto del proxy inverso de cada servicio de la instancia y lo guarda **dentro de la instancia**: `instances/<instancia>/proxy/nginx.conf` y/o
`proxy/Caddyfile`.

- **Qué genera** (`lib/core/proxy.sh`): un servidor por servicio, con el nombre `<nombre del servicio>.<dominio>` (por ejemplo `auth-backend.muni.example.com`) hacia
  `127.0.0.1:<puerto de la instancia>`. Con `--tls`, nginx redirige el 80 y escucha el 443 con las rutas de certbot (`/etc/letsencrypt/live/<nombre>/…`, solo como texto) y Caddy
  consigue el certificado solo; sin `--tls`, solo http. nginx lleva los encabezados de un proxy y el *upgrade* de websocket.
- **Solo texto**: no escribe nada en `/etc`, no recarga nginx ni Caddy, no instala nada y no ejecuta ningún comando. Se copia a donde el proxy lo lea
  (`/etc/nginx/conf.d/`, el `Caddyfile`) y se aplica con `nginx -t && systemctl reload nginx` o `caddy reload`. El panel muestra el mismo texto y puede copiarlo.
- **Qué se valida**: el nombre (minúsculas, números, guion y puntos; etiquetas de hasta 63; hasta 253 en total), el puerto y la etiqueta de cada servicio. Nada que no se
  haya comprobado entra en el texto: un nombre con un `;` o una `}` no puede cerrar el bloque ni añadir una directiva.
- `--proxy` y `--tls` necesitan `--domain`. Sin `--proxy`, se escriben los dos archivos.
- Los puertos son los que la instancia tiene al terminar (si `--env-file` cambió `S0_PORT`, el bloque lleva ese).

## Dónde está el código

| Qué | Dónde |
| --- | --- |
| Las opciones y el orden (comprobar → crear → aplicar) | `lib/cmd/new.sh` (`new_read_envfile`, `new_check_envfile`, `new_add_secretfile`, `new_apply_answers`, `new_write_proxy`) |
| Un archivo que puede ir a `secrets/` y dónde buscarlo | `lib/core/secretfile.sh` |
| El texto del proxy y dónde se guarda | `lib/core/proxy.sh` |
| Las reglas de las variables y su escritura segura | `lib/core/envschema.sh`, `lib/core/envedit.sh` |
| Las pruebas | `tests/test-newcfg.sh` (la CLI y los dos núcleos), `tests/test-newinst.sh` (el asistente del panel) |

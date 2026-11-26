# Panel en vivo: guía de uso

`./deltactl` sin argumentos, en una terminal, abre el panel: el estado de todas las instancias, su consumo, sus logs y lo que
se está ejecutando, actualizado solo. Fuera de una terminal (una tubería, `TERM=dumb`) muestra la pantalla de inicio en texto.

`?` muestra todas las teclas (con la sección de la vista en la que estás resaltada) y `q` sale.

## Las vistas

| Tecla | Vista | Para qué |
| --- | --- | --- |
| `1` | Servidor | Qué necesita el servidor para funcionar (con el comando para instalarlo) y cómo va: una tira con las constantes vitales y los avisos, y cajas de CPU, memoria, discos, red, contenedores (y, en pantallas muy altas, procesos y puertos) |
| `2` | Imágenes | Qué versiones de cada servicio hay cargadas en este Docker, cuál es la más reciente, quién usa cuál; usar una versión en una instancia y cargar un archivo |
| `3` | Instancias | La lista de instancias, el detalle de la seleccionada (servicios, memoria, CPU, errores), sus gráficos y sus logs en vivo, y la consola debajo |
| `4` | Recursos | Todos los servicios de todas las instancias en una tabla; `s` ordena por nombre, memoria o CPU |
| `5` | Salida | El resultado del último comando: de `new`, `check`, `deploy`, `init`, `doctor`, `images` y `env` un resumen con iconos, secciones y veredicto (`v` pasa a la salida cruda); de cualquier otro, la salida completa |
| `6` | Ejecuciones | El historial de operaciones (deploy, init, rollback...) con su consumo, la comparación con las anteriores y sus logs guardados |
| `7` | Procesos | De qué está hecho el comando que se está ejecutando y cuánto cuesta el propio panel |
| `8` | Consola | La consola a pantalla completa, lista para escribir |
| `9` | Variables | Las variables de una instancia, con su esquema (ver [env-variables.md](env-variables.md)) |
| `0` | Actividad | Todo lo que se ha ejecutado en una lista (el comando de este panel, lo que está en marcha en cualquier terminal y lo reciente de todas las instancias) y, de la elegida, cuatro pestañas: Resumen, Salida, Consumo y Procesos. Junta las vistas 3, 4 y 5, que siguen un tiempo |

Tab y Mayús+Tab recorren las vistas (en Instancias, los paneles: lista, servicios y logs; en Servidor, las cajas). Esc vuelve un paso atrás; desde otra vista vuelve a Servidor, y desde Servidor sale del panel.

## Lo más habitual

- **Ver una instancia**: ↑↓ (o `k` `j`) eligen la instancia, → entra en sus servicios, otra → en sus logs. `z` amplía el panel
  con el foco a toda la pantalla.
- **Actuar sobre ella**: Enter abre el menú de acciones (estado, comprobar, desplegar, rollback, logs, parar...). Atajos directos:
  `u` despliega, `c` comprueba, `s` muestra el estado, `l` sigue los logs del servicio.
- **Buscar cualquier acción**: Ctrl+P abre la paleta; escribe parte del nombre ("despl", "logs", "tema") y Enter.
- **Crear una instancia**: `n` (o Enter sobre «+ Nueva instancia», o `new` en la consola) abre el formulario de nueva
  instancia dentro del panel. A la izquierda están las secciones (Nombre, Servicios, Datos, Imágenes, Acceso y Resumen), cada una
  con un icono al inicio de su fila que dice cómo va (● lista, ▲ falta algo opcional, ✖ error, ○ pendiente); a la derecha, los
  campos de la sección elegida. El nombre viene propuesto (`instancia-N`): escribe encima para cambiarlo. En Servicios marcas con
  Espacio cuáles desplegar y ves, de cada uno, si su imagen está cargada en Docker y si su puerto está libre. Los campos se validan
  al escribir. ↑ ↓ recorren los campos y pasan a la sección vecina al llegar al borde; Enter sigue; PgUp/PgDn cambian de sección;
  Tab da el teclado a la lista de secciones (allí, `c` crea); Esc vuelve a la lista y, desde ella, cancela. Con menos de 92
  columnas o 20 filas solo se dibujan los campos (Tab cambia de sección). Al crear, el panel ejecuta `new` con las respuestas como
  opciones y la salida queda en la consola; si falta algo obligatorio (nombre, servicios o imagen válida), te lleva a esa sección.
  Con `!` delante (`!new --wizard`) el asistente sigue disponible en el terminal.
- **Escribir un comando**: `:` da el teclado a la consola; escribe cualquier comando de deltactl sin el prefijo
  (`status colorado`, `logs colorado s0 -f`). `!` delante lo ejecuta en la terminal; `!` solo abre una shell. En la vista `8` la
  línea siempre está lista.
- **Cancelar**: `x` (o Ctrl+C) para el comando en curso.
- **Logs de un servicio**: con el foco en ellos, Espacio pausa, `f` vuelve a seguir el final, `e` deja solo errores y avisos, `/`
  filtra, `s` busca (`[` y `]` saltan entre coincidencias).

## Servidor y requisitos (`1`)

Es la vista con la que se abre el panel. Arriba hay una **tira** de tres filas: a la izquierda el chip de los requisitos (`9/9 listos · 2 recomendados
pendientes`), y en la fila de dentro las constantes vitales del servidor (disco de `/`, carga con su tendencia ↗ → ↘ y los núcleos, tiempo
encendido, red ▼▲) y el aviso que hay: «sin avisos», o el primero y cuántos son (`✖ 3 avisos: disco / al 96%`). Mientras todo lo obligatorio está en
orden, los requisitos son solo esa tira; si algo obligatorio falla o avisa, la tira **se abre sola** en la lista de requisitos, y `Enter` la abre a mano
(`Esc` la repliega). Debajo, el resto de la pantalla son cajas como las de btop (CPU, memoria, discos, red, contenedores), y en pantallas muy altas los
procesos y los puertos.

**La lista de requisitos** (la que se abre): un requisito por fila, `● nombre  resultado resumido`, en dos grupos, **obligatorios** (Docker, acceso al
daemon, Compose 2.20, disco, memoria, MongoDB, `ss`, `openssl`, `gunzip`) y **recomendados** (límite de archivos de `mongod`, nginx o Caddy, `certbot`,
hora sincronizada, cortafuegos, `curl`), con cuántos están listos en el título de cada grupo. Dentro de cada grupo va primero lo que falla (✖), luego lo
que avisa (▲), luego lo que espera o está sin comprobar (○ ◐) y al final lo que está bien (●). Es la misma lista que usa `./deltactl doctor`
([server-prerequisites.md](server-prerequisites.md)). En dos columnas desde 110 columnas; el resultado de una fila que no cabe acaba en `…` (el
resultado entero está en el detalle). Bajo la lista, separado por una línea con el estado y el nombre del requisito elegido, está su **detalle**, en una
zona aparte: *Para qué* sirve, *Resultado* completo, *Cómo* arreglarlo (el comando de tu distribución: apt, dnf, pacman o apk, según `/etc/os-release`; si
no se instala con un paquete, lo que aconseja la comprobación) y *Más información* (la guía).

- **↑ ↓** eligen un requisito (con la lista abierta); **Enter** abre el detalle completo (cada resultado con su consejo y, si la distribución no se
  reconoce, el comando de cada gestor); Enter o Esc lo cierran.
- **c** copia el comando (portapapeles del escritorio con `wl-copy`, `xclip`, `xsel` o `pbcopy`; si no hay, el del terminal con OSC 52; si tampoco,
  lo muestra para que lo selecciones). **!** lo ejecuta en la terminal **después de preguntar**: la ventana muestra el comando entero y solo `y` lo lanza
  (ahí `sudo` pide la contraseña). El panel **nunca instala nada por su cuenta**; al volver se comprueban de nuevo los requisitos. Los requisitos se
  comprueban solos cada 2 minutos mientras la vista está a la vista (una comprobación lanza unas decenas de procesos) y con **R**.

**Avisos** (la tira y el borde de la caja afectada toman el color): disco al 85 % (aviso) o 95 % (error), memoria **disponible** por debajo del 10 % (aviso)
o del 5 % (error; la caché no cuenta), swap al 50 %, carga de un minuto mayor que los núcleos, temperatura de la CPU a menos de 10 grados de su límite,
un contenedor con error o aviso (uno que nunca se creó no es un problema) y la hora sin sincronizar. Los umbrales se mueven con variables de entorno:
`DELTACTL_ALERT_DISK_WARN`, `DELTACTL_ALERT_DISK_ERR`, `DELTACTL_ALERT_MEM_AVAIL`, `DELTACTL_ALERT_SWAP`, `DELTACTL_ALERT_LOAD_PCT` (la carga como
porcentaje de los núcleos, 100) y `DELTACTL_ALERT_TEMP_MARGIN`.

**Las cajas.** Cada una tiene su gráfica con un eje de tiempo (`-4 min ──── ahora`) y el mínimo, la media y el máximo de lo que dibuja; el historial del
servidor guarda 240 muestras. Lo que el sistema no da (WSL, un contenedor) se ve como «no disponible en este sistema».

| Ancho | Filas de cajas |
| --- | --- |
| 200 columnas o más | cpu · memoria · discos · red, y los contenedores a todo el ancho |
| 120 a 199 | cpu · memoria · discos, y red · contenedores |
| menos de 120 | cpu · memoria, y los contenedores (con 44 filas o más, disco · red) |

Desde 55 filas de terminal se añade una fila con los **procesos** que más CPU usan (`ps`) y los **puertos** que escuchan (`ss`, con el servicio de la
instancia cuando es el puerto de uno). Son las únicas cajas que lanzan un programa: en segundo plano, solo mientras están a la vista, cada 5 y 15
segundos (`DELTACTL_PS_TTL` y `DELTACTL_SS_TTL`, entre 5 y 60), con un límite de tiempo, y si falta el programa la caja lo dice.

- **Tab** y **Mayús+Tab** mueven el foco entre las cajas que hay en pantalla (la que lo tiene lleva el chip marcado); **z** amplía la caja con foco a todo
  el cuerpo y enseña lo que no cabía (todos los núcleos y la historia de la carga; cada montaje y cada disco con su ocupación; todas las interfaces y los
  sockets; todas las columnas de los contenedores con sus procesos), **Esc** o **z** la reducen; **m** deja solo las cifras (la tira cede su sitio).
- En los **contenedores**: **↑ ↓** mueven el cursor, **Enter** abre la instancia con el cursor en ese servicio, **l** sigue sus logs, **s** ordena (nombre,
  memoria, CPU, como en Recursos) y **h** enseña u oculta los servicios que nunca se crearon (por defecto son una línea, `+3 no creados`). En los
  procesos y los puertos, ↑ ↓ mueven el cursor.
- Con el ratón activado (Opciones): un clic da el foco a una caja o abre la lista de requisitos si es la tira, un clic en una fila del recuadro con foco
  pone el cursor ahí y un segundo clic hace lo que Enter; la rueda mueve el cursor de la caja con foco.
- Las cifras del servidor (CPU por núcleo, temperatura, presión del kernel, sockets, memoria virtual, red, discos) se leen mientras esta vista es la
  actual (ver «Consumo» en [panel-pendiente.md](panel-pendiente.md)).

**Aviso al abrir el panel**: si falta algo obligatorio (error de Docker, del daemon, de Compose, de disco o de MongoDB), la lista de requisitos se abre
sola y el panel lo dice en la línea de mensajes; las demás vistas siguen disponibles. Con todo en su sitio no dice nada. **Crear una instancia**
(`n`, el botón o `new`) pregunta antes mientras falte algo obligatorio: `y` crea igualmente, `v` muestra los requisitos, `n` no vuelve a
avisar (se guarda `TUI_PREREQ=off`; en Opciones, «Aviso de requisitos» lo vuelve a activar) y Esc cancela.

## Imágenes (`2`)

Una caja por **imagen** (`s0 · auth-backend`, `s1 · gueo-back-end`, y las que alguna instancia use con otro nombre) con una tabla de sus versiones, de la
más nueva a la más vieja **por fecha de creación de la imagen** (una etiqueta es solo un nombre): VERSIÓN, CREADA («hace 2 días»), TAMAÑO, ARQ y USO
(quién la usa, `colorado(actual)`, `colorado(previa)`; o «sin usar»). Las marcas son las de `./deltactl images` ([image-catalog.md](image-catalog.md)):
**★** la más reciente que este servidor puede usar (la más nueva por fecha entre las etiquetas que son versión y de la arquitectura del servidor; se
marca «↑ más reciente»), **▲** una etiqueta que se mueve (`latest`, o sin versión: no sirve para volver atrás y nunca es ★), **✖** una imagen de otra
arquitectura (no arrancaría aquí). Si el orden por versión discrepa del orden por fecha (¿se reconstruyó una vieja?), un aviso lo dice debajo de la imagen.
Bajo el encabezado de cada imagen, una línea **En uso** dice qué versiones corren y quién corre cada una (`★ 2.14.1 (lima) · 2.13.2 (colorado)`; un servicio
parado cuenta con su versión configurada y lo dice: `[parada]`). Debajo, un aviso por cada cosa que no cuadra: **▲** la instancia corre una versión distinta
de la configurada en `.env.instance` (se escribió la etiqueta y falta desplegar) y **✖** la versión configurada no está cargada en este Docker (el próximo
despliegue fallaría o la descargaría de un registry). Salen hasta dos avisos por imagen y «+N avisos más». Lo configurado se lee de `.env.instance`
(`IC_CFG`, en el mismo segundo plano que el catálogo) y lo que corre del estado de Docker que el panel ya tiene: la vista no hace consultas nuevas.
El cursor empieza en la ★ de la primera imagen. La última línea de la caja dice lo importante de la versión elegida (por qué no se puede usar, que la
etiqueta se mueve, que es la más reciente).

- **↑ ↓** (y PgUp, PgDn, Inicio, Fin) eligen una versión, pasando de una imagen a la siguiente.
- **Enter** la usa en una instancia: una ventana pregunta en cuál (solo las que tienen ese servicio activo; las que ya usan esa versión, o usan
  otro nombre de imagen, salen con el motivo y no se pueden elegir) y enseña lo que cambia (`S0_TAG` de `2.14.0` a `2.14.1`). **`y`** escribe la etiqueta en
  el `.env.instance` y despliega ese servicio (un comando en segundo plano como cualquiera: se ve en Salida y `x` lo cancela; `deploy` guarda la versión
  anterior para el rollback); **`g`** solo escribe la etiqueta (se despliega después); cualquier otra tecla cancela. Una imagen de otra arquitectura no
  se ofrece: Enter dice por qué.
- **l** carga un archivo de imágenes (`docker save`, `.tar` o `.tar.gz`): se escribe la ruta (puede empezar por `~/`; el campo dice si el archivo existe) y
  Enter lanza `./deltactl load` **en segundo plano**: el panel sigue funcionando, la última línea de la caja dice qué archivo se carga y, al terminar, la
  vista se actualiza con las versiones nuevas.
- **Espacio** abre el detalle de la versión (la referencia completa, el id, la fecha exacta en UTC y en palabras, el tamaño, la arquitectura y quién la
  usa); Espacio o Esc lo cierran.
- **c** copia la referencia (`auth-backend:2.14.1`) como en la vista Servidor. **R** lee Docker de nuevo.

La vista lee el catálogo en segundo plano al elegirla, cuando termina un comando (una carga o un despliegue cambian lo cargado y quién lo usa), cada
minuto mientras está a la vista y con `R`. Nada de aquí borra una imagen.

## Acceso desde fuera: nginx y Caddy

La sección **Acceso** de una instancia (y `./deltactl access <instancia>` en la terminal) genera el bloque de proxy inverso de cada servicio. Es **solo
texto**: se muestra, se copia (`y`) y se guarda dentro de la instancia (`g`, `instances/<instancia>/proxy/`); nunca se escribe en `/etc` ni se recarga
nginx: el comando para ponerlo en marcha (`sudo cp … /etc/nginx/conf.d/…`, `sudo nginx -t && sudo systemctl reload nginx`) lo ejecuta quien administra el servidor.

- **Una plantilla por servicio**, en `templates/nginx/<servicio>.location.conf` (`@PORT@` es el puerto de `.env.instance`). `s0` lleva WebSockets y cabeceras de
  proxy; `s1` además timeouts de 10 minutos y `proxy_buffering off`. Si un servicio no tiene la suya, usa `default.location.conf`; la carpeta se cambia con
  `DELTACTL_NGINX_TEMPLATES`. Las de `s0` y `s1` llevan `Connection 'upgrade'` literal y no necesitan el `map`, así que varias instancias conviven en un
  servidor sin definirlo dos veces (nginx lo rechaza). `nginx -t` comprueba lo que se escriba en una plantilla.
- **El nombre de cada servicio**: por defecto `<nombre-del-servicio>.<dominio>`; con `--host s0=backlion.deltampa.com --host s1=backguep.deltampa.com` cada
  uno responde en el suyo, y con `--www` también en `www.<nombre>` (el certificado se pide para los dos). Se recuerda en `proxy/access.conf`
  (`HOST_S0=…`, `WWW=1`), que la pestaña Acceso lee y conserva al guardar.
- `new --domain D --host sN=NOMBRE --www` lo hace al crear la instancia; `access` lo cambia después (`--save` guarda; sin él es una vista previa).

## Alias de la consola

Para las órdenes que repites:

```
alias up=deploy colorado      # define "up"
up                            # ejecuta "deploy colorado"
alias lg=logs colorado        # el resto de la línea va detrás:
lg s0 -f                      # ejecuta "logs colorado s0 -f"
alias                         # los lista
unalias up                    # borra uno
```

Se guardan junto al historial (`~/.config/deltactl/aliases`). Solo admiten comandos de deltactl y del panel: uno que empiece por
`!` se rechaza.

## Opciones (`o`)

Tema, idioma, cada cuánto se leen las cifras, cada cuánto se relee el estado sin eventos de Docker, teclas vim, ratón y el aviso de
requisitos del servidor. Cada cambio
se aplica al momento y se guarda en `~/.config/deltactl/config`. Las variables `DELTACTL_THEME`, `DELTACTL_LANG`,
`DELTACTL_METRICS_INTERVAL` y `DELTACTL_REFRESH` mandan al arrancar (la pantalla lo indica).

**Un solo panel por servidor, y por qué se cierra solo.** El primer panel guarda su PID y su terminal en `instances/.deltactl/panel.pid`;
otro panel no arranca mientras ese proceso siga vivo (`DELTACTL_ALLOW_MULTI=1` lo permite). Si se pierde el terminal (una sesión SSH que se
cae), el panel sale en vez de quedarse girando.

**Medir el consumo del panel**: `DELTACTL_PROF=1 ./deltactl` escribe cada 30 s (y al salir) un informe en
`${TMPDIR:-/tmp}/deltactl-prof-<pid>.txt` (o en `DELTACTL_PROF_FILE`): la CPU del propio panel y de los procesos que lanza, y para cada fase
(muestra del host, dibujo de cada vista, tick, procesos en segundo plano) las llamadas, el total, la media y el porcentaje del tiempo. Está
apagado por defecto y no cuesta nada mientras lo esté.

- **Teclas vim** (activadas por defecto): `j k h g G` se mueven como las flechas, Inicio y Fin.
- **Ratón** (desactivado por defecto): clic en una pestaña abre su vista; en una instancia la selecciona y un segundo clic abre sus
  acciones; la rueda desplaza. Mientras está activo, el texto se selecciona con Mayús.
- **Aviso de requisitos** (activado por defecto, `TUI_PREREQ`): avisa al abrir el panel y al crear una instancia si falta algo obligatorio
  del servidor (ver «Servidor y requisitos»).

- **Asistente de nueva instancia por pasos**: `n` abre un asistente de ocho pasos con una barra de progreso (Nombre, Servicios, Versiones, Datos,
  Variables, Secretos, Acceso y Revisión), una vista previa de lo que se creará y el comando `./deltactl new …` equivalente. Enter sigue con lo propuesto,
  Esc vuelve, los dígitos y el clic saltan a un paso ya visitado y Tab muestra la vista previa en una pantalla estrecha. Comprueba que el nombre esté libre
  también en Docker (proyectos y redes), no solo en la carpeta `instances/`. **Nada se escribe hasta la Revisión**, que dice cuántos pasos están listos y
  tiene tres botones: *Crear*, *Crear y comprobar* (después corre `check`) y *Crear y desplegar* (pide Enter otra vez, porque arranca contenedores). Al
  terminar abre la instancia en la vista Instancias; si falla, el asistente vuelve con todas las respuestas, en el primer paso que no pasa. El formulario
  antiguo vuelve con `TUI_WIZARD=1` en el archivo de configuración (o `DELTACTL_WIZARD=1`).

También: `T` cambia de tema, `L` de idioma, `p` pausa la actualización, `r` refresca, `n` crea una instancia, `d` diagnóstico,
`i` imágenes.

**En reposo**: tras 30 s sin tocar el teclado (y sin ningún comando en marcha) las cifras se leen la mitad de veces y el recuento de
errores cada 2 minutos; la primera tecla vuelve al ritmo normal y toma una muestra al momento. `DELTACTL_TUI_IDLE_AFTER` cambia
esos 30 s.

## Terminales

- Mínimo 60 columnas x 14 filas; desde 120x28 aparece la vista ancha (con gráficos, logs y, desde 150 columnas, eventos). Con siete vistas,
  a 80 columnas la línea de pestañas deja solo el número de las que no están activas.
- Funciona con `xterm`, `xterm-256color`, `screen`/`tmux`, la consola de Linux y `vt100`; con `LANG=C` dibuja en ASCII; con
  `NO_COLOR` sin colores; con color real si el terminal lo anuncia (`COLORTERM=truecolor`). `tests/tools/pty_matrix.py` lo
  comprueba en un pseudo-terminal real contra un Docker simulado.
- Al salir (`q`, Esc desde Instancias o Ctrl+C dos veces) deja la terminal como estaba.

Detalle técnico, decisiones y consumo medido: [panel-pendiente.md](panel-pendiente.md).

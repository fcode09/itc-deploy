# Requisitos del servidor

Qué necesita un servidor para ejecutar `deltactl` y sus instancias. Una sola fuente de verdad:
**`lib/core/prereqs.data`** (la lista) y **`lib/core/prereqs.sh`** (cómo se comprueba cada uno). De ahí salen
`./deltactl doctor`, `./deltactl doctor --json` y la pantalla Servidor del panel.

`doctor` es **solo lectura**: no instala, no escribe y no arranca nada. Cuando algo falta, muestra el comando de instalación de la
distribución (se detecta con `/etc/os-release`: apt, dnf, pacman o apk) para que **tú** lo copies y lo ejecutes.

## Qué se comprueba

| Id | Nivel | Para qué sirve | Cómo se comprueba |
|---|---|---|---|
| `docker` | obligatorio | ejecuta los servicios en contenedores | `docker` en el PATH y su versión |
| `daemon` | obligatorio | `deltactl` habla con Docker con tu usuario | `docker info` responde (servicio activo, grupo `docker`) |
| `compose` | obligatorio | cada instancia es un proyecto de Compose (`include`) | `docker compose version` ≥ 2.20 |
| `disk` | obligatorio | imágenes, datos y logs | libre donde Docker guarda las imágenes: error < 3 GB, aviso < 10 GB |
| `ram` | obligatorio | techos de memoria de los servicios | RAM total y suma de los `SN_MEM_LIMIT` de las instancias |
| `mongo` | obligatorio | los servicios guardan sus datos | cada URI de las instancias responde por TCP (la puerta de enlace de Docker para `host.docker.internal`) |
| `ss` · `openssl` · `gunzip` | obligatorio | detectar puertos · generar secretos · leer `.tar.gz` | el programa existe (si falta es un aviso, no un error) |
| `nofile` | recomendado | `mongod` con muchas instancias | `Max open files` de `mongod` ≥ 64000 |
| `proxy` | recomendado | HTTPS y nombre de dominio delante de las instancias | `nginx` o `caddy` (también en `/usr/sbin`) |
| `certbot` | recomendado | certificados HTTPS | el programa existe |
| `timesync` | recomendado | JWT y certificados dependen de la hora | `timedatectl show -p NTPSynchronized` |
| `firewall` | recomendado | no exponer los puertos de las instancias | `ufw`, `firewalld` o `nftables` activos (`systemctl is-active`) |
| `curl` | recomendado | probar servicios a mano | el programa existe |

Un recomendado que falta solo **informa** (símbolo `i`): nunca cuenta como aviso ni como error, así que no cambia el código de salida
ni el resumen de `doctor`.

## `doctor --json`

Una línea de JSON con la distribución, los totales y cada requisito:

```json
{"distro":{"id":"debian","name":"Debian GNU/Linux 12 (bookworm)","manager":"apt"},
 "summary":{"errors":0,"warnings":1,"ok":true},
 "prerequisites":[{"id":"openssl","name":"openssl","level":"required","status":"ok","summary":"openssl disponible",
   "why":"Genera los secretos (JWT, claves) del asistente de nueva instancia.",
   "install":"sudo apt-get install -y openssl","url":"","results":[{"status":"ok","message":"openssl disponible"}]}]}
```

`status` es `ok`, `info`, `warn`, `err` o `na` (no aplica porque falta algo de lo que depende, por ejemplo Compose sin Docker).
Termina con código 1 si hay errores, igual que el modo normal. Los textos salen en el idioma activo.

## Añadir un requisito

1. Una fila en `lib/core/prereqs.data` (id, nivel, sección, enlace y comando para apt, dnf, pacman y apk; `-` si no hay).
2. Su comprobación `prereq_check_<id>` en `lib/core/prereqs.sh`: solo lee, y comunica con `pr_res ok|warn|err|info <texto> [pista...]`
   (`pr_quiet` para un resultado que no se imprime y `pr_na` si no aplica).
3. Su nombre y para qué sirve: `prereq.name.<id>` y `prereq.why.<id>` en `lib/i18n/{es,en}/prereqs.sh`.
4. `tests/run.sh test-prereqs` y `test-i18n` fallan mientras falte algo.

Las pruebas simulan `PATH`, `os-release` (`DELTACTL_OS_RELEASE`) y las carpetas `sbin` (`DELTACTL_PR_SBIN`).

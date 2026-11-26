#!/usr/bin/env bash
# `./deltactl mongo setup` (lib/cmd/mongo.sh): it reads the gateway of Docker, shows what would change in mongod.conf (bindIp), in systemd (start after
# Docker) and in ufw, writes nothing without --apply, and with --apply keeps a copy, changes only that, restarts mongod and tests again. A mongod.conf it
# does not recognise is left alone. Simulated Docker, ufw and systemctl; the files are redirected with DELTACTL_MONGOD_CONF and DELTACTL_SYSTEMD_DIR.
# Run it from the root of the isolated copy (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS

FIX="$(mktemp -d)"
export FIX
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/bin" "$FIX/systemd"
: > "$FIX/images.txt"; : > "$FIX/calls.log"
cp tests/fake-docker.sh "$FIX/bin/docker"
printf '#!/bin/sh\necho "ufw $*" >> "$FIX/ufw.log"\ncase "$1" in status) if [ "${LC_ALL:-}" = C ]; then cat "$FIX/ufw.status" 2>/dev/null; else sed "s/^Status: active/Estado: activo/; s/^Status: inactive/Estado: inactivo/" "$FIX/ufw.status" 2>/dev/null; fi ;; allow) printf "27017/tcp   ALLOW   %%s\\n" "$3" >> "$FIX/ufw.status" ;; esac\nexit 0\n' > "$FIX/bin/ufw"
printf '#!/bin/sh\necho "systemctl $*" >> "$FIX/systemctl.log"\nexit 0\n' > "$FIX/bin/systemctl"
chmod +x "$FIX/bin/"*
export PATH="$FIX/bin:$PATH"
export DELTACTL_MONGOD_CONF="$FIX/mongod.conf" DELTACTL_SYSTEMD_DIR="$FIX/systemd"
echo 172.17.0.1 > "$FIX/gateway"

D() { bash ./deltactl "$@"; }
conf_default() { printf '# mongod.conf\nstorage:\n  dbPath: /var/lib/mongodb\nnet:\n  port: 27017\n  bindIp: 127.0.0.1\nsecurity:\n  authorization: disabled\n'; }
reset() { conf_default > "$FIX/mongod.conf"; rm -rf "$FIX/systemd"/* "$FIX/ufw.log" "$FIX/systemctl.log" "$FIX"/mongod.conf.deltactl-*; printf 'Status: active\n' > "$FIX/ufw.status"; }
rlib() { ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/core/runs.sh; $1"; }

section "1. it shows, and writes nothing without --apply"
reset
out="$(D mongo setup 2>&1)"; rc=$?
check "it says the gateway it read from Docker, not an assumed one" '[ "$rc" -eq 0 ] && echo "$out" | grep -q "por 172.17.0.1 (la puerta de enlace de Docker"'
check "it shows the change of bindIp as a diff: the gateway is added and 127.0.0.1 stays" 'echo "$out" | grep -q "bindIp pasa de 127.0.0.1 a 127.0.0.1,172.17.0.1" && echo "$out" | grep -q "^    -  bindIp: 127.0.0.1$" && echo "$out" | grep -q "^    +  bindIp: 127.0.0.1,172.17.0.1$"'
check "it shows the drop-in (mongod after Docker) and the rule of ufw for the networks of the containers, only them" 'echo "$out" | grep -q "mongod arranca después de Docker" && echo "$out" | grep -q "ufw: ufw allow from 172.16.0.0/12 to any port 27017 proto tcp"'
check "it says how to apply it and that authentication is not touched" 'echo "$out" | grep -q "sudo ./deltactl mongo setup --apply" && echo "$out" | grep -q "No se activa la autenticación"'
check "nothing was written, restarted or added" '[ "$(conf_default | cksum)" = "$(cksum < "$FIX/mongod.conf")" ] && [ -z "$(ls "$FIX/systemd")" ] && ! grep -q "allow\|restart" "$FIX/ufw.log" "$FIX/systemctl.log" 2> /dev/null && ! ls "$FIX"/mongod.conf.deltactl-* > /dev/null 2>&1'

section "2. --apply"
reset
out="$(D mongo setup --apply --yes 2>&1)"
check "bindIp has the gateway now, and the rest of the file is as it was" 'grep -q "^  bindIp: 127.0.0.1,172.17.0.1$" "$FIX/mongod.conf" && [ "$(conf_default | sed "s/^  bindIp: 127.0.0.1$/  bindIp: 127.0.0.1,172.17.0.1/" | cksum)" = "$(cksum < "$FIX/mongod.conf")" ]'
check "a copy of the original was kept next to it" 'cmp -s <(conf_default) "$(ls "$FIX"/mongod.conf.deltactl-*.bak | head -1)"'
check "the drop-in starts mongod after Docker" 'grep -qx "After=docker.service" "$FIX/systemd/mongod.service.d/deltactl-after-docker.conf" && grep -qx "Wants=docker.service" "$FIX/systemd/mongod.service.d/deltactl-after-docker.conf"'
check "ufw gets the rule for the networks of the containers and nothing wider" 'grep -qx "ufw allow from 172.16.0.0/12 to any port 27017 proto tcp" "$FIX/ufw.log" && ! grep "allow" "$FIX/ufw.log" | grep -qE "anywhere|0.0.0.0/0|from any"'
check "mongod is restarted after systemd reads its new drop-in, and the connection is tested again" 'grep -q "daemon-reload" "$FIX/systemctl.log" && grep -q "restart mongod" "$FIX/systemctl.log" && echo "$out" | grep -qE "172.17.0.1:27017 (responde|aún no responde)"'
check "it says what it did, and that authentication stays off" 'echo "$out" | grep -q "actualizado (copia del original" && echo "$out" | grep -q "mongod reiniciado" && echo "$out" | grep -q "No se activa la autenticación"'
out="$(D mongo setup --apply --yes 2>&1)"
check "run again it finds everything done and changes nothing (idempotent)" 'echo "$out" | grep -q "Nada que cambiar" && [ "$(grep -c "allow" "$FIX/ufw.log")" -eq 1 ] && [ "$(ls "$FIX"/mongod.conf.deltactl-*.bak | wc -l)" -eq 1 ]'

section "3. other servers, other files"
reset; echo 10.200.0.1 > "$FIX/gateway"
out="$(D mongo setup 2>&1)"
check "a gateway that is not in the block of Docker gets the /16 of its own network" 'echo "$out" | grep -q "127.0.0.1,10.200.0.1" && echo "$out" | grep -q "allow from 10.200.0.0/16 to any port 27017"'
echo 172.17.0.1 > "$FIX/gateway"
reset; sed -i "s/^  bindIp: 127.0.0.1$/  bindIp: 0.0.0.0/" "$FIX/mongod.conf"; printf 'Status: inactive\n' > "$FIX/ufw.status"
out="$(D mongo setup 2>&1)"
check "with 0.0.0.0 there is nothing to change in mongod.conf, no dependency on Docker, and with ufw off there is no rule" 'echo "$out" | grep -q "ya deja entrar a los contenedores (0.0.0.0)" && ! echo "$out" | grep -q "mongod arranca después de Docker" && echo "$out" | grep -q "ufw no está activo" && echo "$out" | grep -q "Nada que cambiar"'
reset; sed -i "/^  bindIp: 127.0.0.1$/d" "$FIX/mongod.conf"
out="$(D mongo setup --apply --yes 2>&1)"
check "without a bindIp line it is written in the net: section (the default of mongod is 127.0.0.1)" 'grep -A1 "^net:" "$FIX/mongod.conf" | grep -q "bindIp: 127.0.0.1,172.17.0.1" && grep -q "^  port: 27017$" "$FIX/mongod.conf"'
reset; sed -i "s/^  bindIp: 127.0.0.1$/  bindIp: 127.0.0.1,::1 # local/" "$FIX/mongod.conf"
D mongo setup --apply --yes > /dev/null 2>&1
check "a list and a comment on the line are kept: the gateway goes at the end of the list" 'grep -q "^  bindIp: 127.0.0.1,::1,172.17.0.1 # local$" "$FIX/mongod.conf"'
printf 'storage: {dbPath: /x}\nsystemLog: {}\n' > "$FIX/mongod.conf"
out="$(D mongo setup --apply --yes 2>&1)"
check "a mongod.conf with no net: section is not touched, and it says which line to write" 'echo "$out" | grep -q "no tiene el formato habitual" && echo "$out" | grep -q "bindIp: 127.0.0.1,172.17.0.1" && [ "$(cat "$FIX/mongod.conf")" = "$(printf "storage: {dbPath: /x}\nsystemLog: {}")" ]'
rm -f "$FIX/mongod.conf"
out="$(D mongo setup 2>&1)"
check "without mongod.conf it says so and still shows the rest" 'echo "$out" | grep -q "No se puede leer"'

section "4. usage"
check "an unknown sub-command or option, or none, is refused with the usage" '! D mongo > /dev/null 2>&1 && D mongo 2>&1 | grep -q "uso: ./deltactl mongo setup" && ! D mongo frob > /dev/null 2>&1 && ! D mongo setup --nope > /dev/null 2>&1'
check "it is recorded as an operation only with --apply, and it is about the server (no instance)" '[ "$(rlib "runs_is_mutation mongo setup --apply && echo y")" = y ] && [ -z "$(rlib "runs_is_mutation mongo setup && echo y")" ] && [ "$(rlib "runs_instance_of mongo setup --apply")" = "-" ]'
check "it has its help page in both languages, and the completion knows it" 'D help mongo 2>&1 | grep -q "mongo · dejar el Mongo" && DELTACTL_LANG=en D help mongo 2>&1 | grep -q "mongo · make the Mongo" && D completion bash | grep -q "mongo)"'

finish

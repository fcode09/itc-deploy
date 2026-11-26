#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # the cases go in single quotes and are evaluated with eval
# `./deltactl access <instance> --apply|--remove [--service sN]` (lib/cmd/access.sh, lib/core/proxy.sh): the block of each service goes to the folder of nginx
# as its own file, nginx tests it and is reloaded; a test that fails puts everything back and reloads nothing; HTTPS needs its certificates; --remove takes
# the files out the same way. Nothing is written without --apply or --remove, and never without asking. nginx, systemctl and the folders are simulated.
# Run it from the root of the isolated copy (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS

FIX="$(mktemp -d)"
export FIX
trap 'rm -rf "$FIX" instances/aa-*' EXIT
rm -rf instances/aa-*
mkdir -p "$FIX/bin" "$FIX/conf.d" "$FIX/le"
: > "$FIX/images.txt"; : > "$FIX/calls.log"
cp tests/fake-docker.sh "$FIX/bin/docker"
printf '#!/bin/sh\necho "nginx $*" >> "$FIX/nginx.log"\nif [ "$1" = "-t" ]; then if [ -f "$FIX/nginx_fail" ]; then echo "nginx: [emerg] test failure" >&2; exit 1; fi; echo "syntax is ok" >&2; fi\nexit 0\n' > "$FIX/bin/nginx"
printf '#!/bin/sh\necho "systemctl $*" >> "$FIX/systemctl.log"\nexit 0\n' > "$FIX/bin/systemctl"
chmod +x "$FIX/bin/"*
export PATH="$FIX/bin:$PATH"
export DELTACTL_NGINX_DIR="$FIX/conf.d" DELTACTL_LETSENCRYPT_DIR="$FIX/le"

D() { bash ./deltactl "$@"; }
reset() { rm -rf "$FIX/conf.d"/* "$FIX/nginx.log" "$FIX/systemctl.log" "$FIX/nginx_fail"; }
certs() { local h; for h in "$@"; do mkdir -p "$FIX/le/$h"; : > "$FIX/le/$h/fullchain.pem"; : > "$FIX/le/$h/privkey.pem"; done; }
ACC=(access aa-x --domain d.example.com --host s0=a.d.example.com --host s1=b.d.example.com)

D new aa-x --generate-secrets > /dev/null 2>&1

section "1. nothing is written unless it is asked for"
reset
D "${ACC[@]}" > /dev/null 2>&1
check "access with no --apply only shows: nothing goes to the folder of nginx" '[ -z "$(ls "$FIX/conf.d")" ] && [ ! -f "$FIX/nginx.log" ]'
out="$(D "${ACC[@]}" --apply 2>&1 < /dev/null)"; rc=$?
check "without --yes it asks, and with no terminal to answer it stops: nothing was written" '[ "$rc" -ne 0 ] && [ -z "$(ls "$FIX/conf.d")" ] && ! grep -q "reload" "$FIX/systemctl.log" 2> /dev/null'

section "2. --apply"
out="$(D "${ACC[@]}" --apply --yes 2>&1)"; rc=$?
check "HTTPS without its certificates is refused, with the certbot command of each name, and writes nothing" '[ "$rc" -ne 0 ] && echo "$out" | grep -q "faltan los certificados de HTTPS de: a.d.example.com b.d.example.com" && echo "$out" | grep -q "certbot certonly --nginx -d a.d.example.com" && echo "$out" | grep -q "certbot certonly --nginx -d b.d.example.com" && [ -z "$(ls "$FIX/conf.d")" ]'
certs a.d.example.com b.d.example.com
out="$(D "${ACC[@]}" --apply --yes 2>&1)"; rc=$?
check "with the certificates, one file per service goes to the folder of nginx, with the name it answers to and its port" '[ "$rc" -eq 0 ] && grep -q "server_name a.d.example.com;" "$FIX/conf.d/aa-x-s0.conf" && grep -q "server_name b.d.example.com;" "$FIX/conf.d/aa-x-s1.conf" && grep -q "proxy_pass http://127.0.0.1:41" "$FIX/conf.d/aa-x-s0.conf" && ! grep -q "b.d.example.com" "$FIX/conf.d/aa-x-s0.conf"'
check "nginx tested the configuration and was reloaded, and it says what it installed" 'grep -q "nginx -t" "$FIX/nginx.log" && grep -q "reload nginx" "$FIX/systemctl.log" && echo "$out" | grep -q "instalado en nginx:" && echo "$out" | grep -q "nginx recargado"'
check "the files are readable by nginx (644) and no copy is left once the test passed" '[ "$(stat -c %a "$FIX/conf.d/aa-x-s0.conf")" = 644 ] && ! ls "$FIX/conf.d" | grep -q "deltactl-bak"'
check "the block is also saved in the instance (apply saves first)" 'grep -q "server_name a.d.example.com;" instances/aa-x/proxy/nginx.conf'
reset; certs a.d.example.com b.d.example.com
D "${ACC[@]}" --apply --yes --service s1 > /dev/null 2>&1
check "--service applies only that service: the other one has no file" '[ -f "$FIX/conf.d/aa-x-s1.conf" ] && [ ! -e "$FIX/conf.d/aa-x-s0.conf" ]'
check "a service that the instance does not run is refused" '! D "${ACC[@]}" --apply --yes --service s9 > /dev/null 2>&1'

section "3. when nginx refuses it, everything goes back"
reset; certs a.d.example.com b.d.example.com
printf 'OLD s0\n' > "$FIX/conf.d/aa-x-s0.conf"
touch "$FIX/nginx_fail"
out="$(D "${ACC[@]}" --apply --yes 2>&1)"; rc=$?
check "the file that existed is as it was, the one that did not exist is not there, no copy is left and nginx was not reloaded" '[ "$rc" -ne 0 ] && [ "$(cat "$FIX/conf.d/aa-x-s0.conf")" = "OLD s0" ] && [ ! -e "$FIX/conf.d/aa-x-s1.conf" ] && ! ls "$FIX/conf.d" | grep -q "deltactl-bak" && ! grep -q "reload" "$FIX/systemctl.log" 2> /dev/null'
check "it says nginx refused it, shows why, and that everything was put back" 'echo "$out" | grep -q "test failure" && echo "$out" | grep -q "nginx -t rechazó la configuración: se devolvió todo como estaba"'
rm -f "$FIX/nginx_fail"

section "4. without HTTPS, and other proxies"
reset
D "${ACC[@]}" --no-tls --apply --yes > /dev/null 2>&1
check "--no-tls needs no certificates and the block has no 443" '[ -f "$FIX/conf.d/aa-x-s0.conf" ] && ! grep -q "listen 443" "$FIX/conf.d/aa-x-s0.conf" && grep -q "listen 80;" "$FIX/conf.d/aa-x-s0.conf"'
reset
check "Caddy cannot be installed by this command: it says so and writes nothing" '! D "${ACC[@]}" --proxy caddy --apply --yes > /dev/null 2>&1 && [ -z "$(ls "$FIX/conf.d")" ]'

section "5. --remove"
reset; certs a.d.example.com b.d.example.com
D "${ACC[@]}" --apply --yes > /dev/null 2>&1
: > "$FIX/nginx.log"; : > "$FIX/systemctl.log"
out="$(D access aa-x --remove --service s0 --yes 2>&1)"
check "--remove --service takes out only that file (kept as .deltactl-removed), tests and reloads" '[ ! -e "$FIX/conf.d/aa-x-s0.conf" ] && [ -f "$FIX/conf.d/aa-x-s0.conf.deltactl-removed" ] && [ -f "$FIX/conf.d/aa-x-s1.conf" ] && grep -q "nginx -t" "$FIX/nginx.log" && grep -q "reload nginx" "$FIX/systemctl.log" && echo "$out" | grep -q "quitado de nginx:"'
D access aa-x --remove --yes > /dev/null 2>&1
check "--remove with no service takes out all of them" '[ ! -e "$FIX/conf.d/aa-x-s1.conf" ]'
out="$(D access aa-x --remove --yes 2>&1)"; rc=$?
check "with nothing installed it says so and is not an error" '[ "$rc" -eq 0 ] && echo "$out" | grep -q "no tiene ningún bloque instalado en nginx"'
reset; certs a.d.example.com b.d.example.com
D "${ACC[@]}" --apply --yes > /dev/null 2>&1
touch "$FIX/nginx_fail"
D access aa-x --remove --yes > /dev/null 2>&1
check "when the test fails after taking them out, they are put back" '[ -f "$FIX/conf.d/aa-x-s0.conf" ] && [ -f "$FIX/conf.d/aa-x-s1.conf" ]'
rm -f "$FIX/nginx_fail"
check "--apply and --remove together are refused" '! D "${ACC[@]}" --apply --remove --yes > /dev/null 2>&1'

section "6. a command of the tool"
check "it is recorded as an operation with --apply or --remove, and not when it only shows" '[ "$(ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/core/runs.sh; runs_is_mutation access aa-x --apply && echo y")" = y ] && [ "$(ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/core/runs.sh; runs_is_mutation access aa-x --remove && echo y")" = y ] && [ -z "$(ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/core/runs.sh; runs_is_mutation access aa-x --save && echo y")" ]'
check "the options are in its help page and in the completion" 'D help access 2>&1 | grep -q -- "--apply" && D help access 2>&1 | grep -q -- "--remove" && D completion bash | grep -q -- "--apply"'

finish

#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # the cases go in single quotes and are evaluated with eval
# `./deltactl access <instance> --apply|--remove [--service sN]` (lib/cmd/access.sh, lib/core/proxy.sh): the block of each service goes to the folder of nginx as
# its own file in sites-available/ and a link to it in sites-enabled/ (the way Debian and Ubuntu enable a site; conf.d/ when the server has no such folders),
# nginx tests it and is reloaded; a test that fails puts everything back and reloads nothing; HTTPS needs its certificates; --remove disables the services the
# same way. The files that an earlier version left in conf.d/ are set aside. Nothing is written without --apply or --remove, and never without asking.
# nginx, systemctl and the folders are simulated. Run it from the root of the isolated copy (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS

FIX="$(mktemp -d)"
export FIX
trap 'rm -rf "$FIX" instances/aa-*' EXIT
rm -rf instances/aa-*
AV="$FIX/nginx/sites-available" EN="$FIX/nginx/sites-enabled" CD="$FIX/nginx/conf.d"
mkdir -p "$FIX/bin" "$AV" "$EN" "$CD" "$FIX/le" "$FIX/nginx2/conf.d"
: > "$FIX/images.txt"; : > "$FIX/calls.log"
cp tests/fake-docker.sh "$FIX/bin/docker"
printf '#!/bin/sh\necho "nginx $*" >> "$FIX/nginx.log"\nif [ "$1" = "-t" ]; then if [ -f "$FIX/nginx_fail" ]; then echo "nginx: [emerg] test failure" >&2; exit 1; fi; echo "syntax is ok" >&2; fi\nexit 0\n' > "$FIX/bin/nginx"
printf '#!/bin/sh\necho "systemctl $*" >> "$FIX/systemctl.log"\nexit 0\n' > "$FIX/bin/systemctl"
chmod +x "$FIX/bin/"*
export PATH="$FIX/bin:$PATH"
export DELTACTL_NGINX_ROOT="$FIX/nginx" DELTACTL_LETSENCRYPT_DIR="$FIX/le"

D() { bash ./deltactl "$@"; }
reset() { rm -rf "$AV"/* "$EN"/* "$CD"/* "$FIX/nginx.log" "$FIX/systemctl.log" "$FIX/nginx_fail"; }
certs() { local h; for h in "$@"; do mkdir -p "$FIX/le/$h"; : > "$FIX/le/$h/fullchain.pem"; : > "$FIX/le/$h/privkey.pem"; done; }
ACC=(access aa-x --domain d.example.com --host s0=a.d.example.com --host s1=b.d.example.com)

D new aa-x --generate-secrets > /dev/null 2>&1

section "1. nothing is written unless it is asked for"
reset
D "${ACC[@]}" > /dev/null 2>&1
check "access with no --apply only shows: nothing goes to the folders of nginx" '[ -z "$(ls "$AV")" ] && [ -z "$(ls "$EN")" ] && [ ! -f "$FIX/nginx.log" ]'
out="$(D "${ACC[@]}" --apply 2>&1 < /dev/null)"; rc=$?
check "without --yes it asks, and with no terminal to answer it stops: nothing was written" '[ "$rc" -ne 0 ] && [ -z "$(ls "$AV")" ] && [ -z "$(ls "$EN")" ] && ! grep -q "reload" "$FIX/systemctl.log" 2> /dev/null'

section "2. --apply: a file in sites-available and a link in sites-enabled"
out="$(D "${ACC[@]}" --apply --yes 2>&1)"; rc=$?
check "HTTPS without its certificates is refused, with the certbot command of each name, and writes nothing" '[ "$rc" -ne 0 ] && echo "$out" | grep -q "faltan los certificados de HTTPS de: a.d.example.com b.d.example.com" && echo "$out" | grep -q "certbot certonly --nginx -d a.d.example.com" && echo "$out" | grep -q "certbot certonly --nginx -d b.d.example.com" && [ -z "$(ls "$AV")" ] && [ -z "$(ls "$EN")" ]'
certs a.d.example.com b.d.example.com
out="$(D "${ACC[@]}" --apply --yes 2>&1)"; rc=$?
check "with the certificates, one file per service goes to sites-available, with the name it answers to and its port" '[ "$rc" -eq 0 ] && grep -q "server_name a.d.example.com;" "$AV/aa-x-s0" && grep -q "server_name b.d.example.com;" "$AV/aa-x-s1" && grep -q "proxy_pass http://127.0.0.1:41" "$AV/aa-x-s0" && ! grep -q "b.d.example.com" "$AV/aa-x-s0"'
check "each one is enabled with a link in sites-enabled that points to its file" '[ -L "$EN/aa-x-s0" ] && [ "$(readlink "$EN/aa-x-s0")" = "$AV/aa-x-s0" ] && [ -L "$EN/aa-x-s1" ] && [ "$(readlink "$EN/aa-x-s1")" = "$AV/aa-x-s1" ]'
check "nginx tested the configuration and was reloaded, and it says what it enabled" 'grep -q "nginx -t" "$FIX/nginx.log" && grep -q "reload nginx" "$FIX/systemctl.log" && echo "$out" | grep -q "instalado en nginx:" && echo "$out" | grep -q "sites-enabled/aa-x-s0" && echo "$out" | grep -q "nginx recargado"'
check "the files are readable by nginx (644) and no copy is left once the test passed" '[ "$(stat -c %a "$AV/aa-x-s0")" = 644 ] && ! ls "$AV" | grep -q "deltactl-bak"'
check "the block is also saved in the instance (apply saves first)" 'grep -q "server_name a.d.example.com;" instances/aa-x/proxy/nginx.conf'
D "${ACC[@]}" --apply --yes > /dev/null 2>&1
check "applying again is the same: the link stays, one of each, nothing duplicated" '[ "$(ls "$AV" | wc -l)" -eq 2 ] && [ "$(ls "$EN" | wc -l)" -eq 2 ] && [ -L "$EN/aa-x-s0" ]'
reset; certs a.d.example.com b.d.example.com
D "${ACC[@]}" --apply --yes --service s1 > /dev/null 2>&1
check "--service applies only that service: the other one has no file and no link" '[ -f "$AV/aa-x-s1" ] && [ -L "$EN/aa-x-s1" ] && [ ! -e "$AV/aa-x-s0" ] && [ ! -L "$EN/aa-x-s0" ]'
check "a service that the instance does not run is refused" '! D "${ACC[@]}" --apply --yes --service s9 > /dev/null 2>&1'

section "3. when nginx refuses it, everything goes back"
reset; certs a.d.example.com b.d.example.com
printf 'OLD s0\n' > "$AV/aa-x-s0"; ln -s "$AV/aa-x-s0" "$EN/aa-x-s0"
touch "$FIX/nginx_fail"
out="$(D "${ACC[@]}" --apply --yes 2>&1)"; rc=$?
check "the file that existed is as it was and still enabled; the service that did not exist has neither file nor link; no copy is left; nginx was not reloaded" '[ "$rc" -ne 0 ] && [ "$(cat "$AV/aa-x-s0")" = "OLD s0" ] && [ -L "$EN/aa-x-s0" ] && [ ! -e "$AV/aa-x-s1" ] && [ ! -L "$EN/aa-x-s1" ] && ! ls "$AV" | grep -q "deltactl-bak" && ! grep -q "reload" "$FIX/systemctl.log" 2> /dev/null'
check "it says nginx refused it, shows why, and that everything was put back" 'echo "$out" | grep -q "test failure" && echo "$out" | grep -q "nginx -t rechazó la configuración: se devolvió todo como estaba"'
rm -f "$FIX/nginx_fail"
reset; printf 'FOREIGN\n' > "$EN/aa-x-s0"
check "a file of somebody else in sites-enabled is not replaced: it stops, and nothing else was left half done" '! D "${ACC[@]}" --no-tls --apply --yes > /dev/null 2>&1 && [ "$(cat "$EN/aa-x-s0")" = FOREIGN ] && [ ! -e "$AV/aa-x-s1" ] && [ ! -L "$EN/aa-x-s1" ]'

section "4. what an earlier version left in conf.d, without HTTPS, and other proxies"
reset
printf 'LEGACY s0\n' > "$CD/aa-x-s0.conf"; printf 'LEGACY s1\n' > "$CD/aa-x-s1.conf"
D "${ACC[@]}" --no-tls --apply --yes > /dev/null 2>&1
check "the files of conf.d of the same services are set aside (the name is not served twice): they do not end in .conf any more" '[ ! -e "$CD/aa-x-s0.conf" ] && [ -f "$CD/aa-x-s0.conf.deltactl-removed" ] && [ ! -e "$CD/aa-x-s1.conf" ] && [ -L "$EN/aa-x-s0" ]'
check "--no-tls needs no certificates and the block has no 443" '[ -f "$AV/aa-x-s0" ] && ! grep -q "listen 443" "$AV/aa-x-s0" && grep -q "listen 80;" "$AV/aa-x-s0"'
reset
printf 'LEGACY s0\n' > "$CD/aa-x-s0.conf"; touch "$FIX/nginx_fail"
D "${ACC[@]}" --no-tls --apply --yes > /dev/null 2>&1
check "when nginx refuses it the old file of conf.d comes back with its name" '[ -f "$CD/aa-x-s0.conf" ] && [ ! -e "$CD/aa-x-s0.conf.deltactl-removed" ] && [ ! -e "$AV/aa-x-s0" ]'
rm -f "$FIX/nginx_fail"
reset
check "Caddy cannot be installed by this command: it says so and writes nothing" '! D "${ACC[@]}" --proxy caddy --apply --yes > /dev/null 2>&1 && [ -z "$(ls "$AV")" ] && [ -z "$(ls "$EN")" ]'

section "5. a server without sites-available: conf.d"
export DELTACTL_NGINX_ROOT="$FIX/nginx2"
D "${ACC[@]}" --no-tls --apply --yes > /dev/null 2>&1
check "the file goes to conf.d with .conf, as before" 'grep -q "server_name a.d.example.com;" "$FIX/nginx2/conf.d/aa-x-s0.conf" && grep -q "server_name b.d.example.com;" "$FIX/nginx2/conf.d/aa-x-s1.conf"'
D access aa-x --remove --service s0 --yes > /dev/null 2>&1
check "--remove there sets the file aside, only for that service" '[ ! -e "$FIX/nginx2/conf.d/aa-x-s0.conf" ] && [ -f "$FIX/nginx2/conf.d/aa-x-s0.conf.deltactl-removed" ] && [ -f "$FIX/nginx2/conf.d/aa-x-s1.conf" ]'
export DELTACTL_NGINX_ROOT="$FIX/nginx"

section "6. --remove"
reset; certs a.d.example.com b.d.example.com
D "${ACC[@]}" --apply --yes > /dev/null 2>&1
: > "$FIX/nginx.log"; : > "$FIX/systemctl.log"
out="$(D access aa-x --remove --service s0 --yes 2>&1)"
check "--remove --service disables only that service: its link goes, its file stays in sites-available, nginx is tested and reloaded" '[ ! -e "$EN/aa-x-s0" ] && [ ! -L "$EN/aa-x-s0" ] && [ -f "$AV/aa-x-s0" ] && [ -L "$EN/aa-x-s1" ] && grep -q "nginx -t" "$FIX/nginx.log" && grep -q "reload nginx" "$FIX/systemctl.log" && echo "$out" | grep -q "quitado de nginx:"'
D access aa-x --remove --yes > /dev/null 2>&1
check "--remove with no service disables all of them (the files stay, to enable them again)" '[ ! -L "$EN/aa-x-s1" ] && [ -f "$AV/aa-x-s1" ]'
out="$(D access aa-x --remove --yes 2>&1)"; rc=$?
check "with nothing enabled it says so and is not an error" '[ "$rc" -eq 0 ] && echo "$out" | grep -q "no tiene ningún bloque instalado en nginx"'
reset; certs a.d.example.com b.d.example.com
D "${ACC[@]}" --apply --yes > /dev/null 2>&1
touch "$FIX/nginx_fail"
D access aa-x --remove --yes > /dev/null 2>&1
check "when the test fails after removing the links, they are put back and point to the same files" '[ "$(readlink "$EN/aa-x-s0")" = "$AV/aa-x-s0" ] && [ "$(readlink "$EN/aa-x-s1")" = "$AV/aa-x-s1" ]'
rm -f "$FIX/nginx_fail"
check "--apply and --remove together are refused" '! D "${ACC[@]}" --apply --remove --yes > /dev/null 2>&1'

section "7. a command of the tool"
check "it is recorded as an operation with --apply or --remove, and not when it only shows" '[ "$(ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/core/runs.sh; runs_is_mutation access aa-x --apply && echo y")" = y ] && [ "$(ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/core/runs.sh; runs_is_mutation access aa-x --remove && echo y")" = y ] && [ -z "$(ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/core/runs.sh; runs_is_mutation access aa-x --save && echo y")" ]'
check "the options are in its help page and in the completion" 'D help access 2>&1 | grep -q -- "--apply" && D help access 2>&1 | grep -q -- "--remove" && D completion bash | grep -q -- "--apply"'
check "the help says where it goes: sites-available and sites-enabled" 'D help access 2>&1 | grep -q "sites-available" && D help access 2>&1 | grep -q "sites-enabled"'

finish

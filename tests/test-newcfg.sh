#!/usr/bin/env bash
# Tests de lo que `new` recibe además del nombre y las versiones: --env-file (variables de los archivos, sin pasar por la línea de comandos),
# --secret-file (archivos para secrets/), --domain/--proxy/--tls (el bloque de nginx o Caddy dentro de la instancia) y de los núcleos que los
# sostienen: lib/core/secretfile.sh (qué archivo puede ir a secrets/, JSON sin imprimir nada) y lib/core/proxy.sh (texto de nginx y Caddy, nunca
# escribe fuera de la instancia). Sin Docker. Se ejecuta desde la raíz de la copia aislada (tests/run.sh).
# shellcheck disable=SC2016,SC2034  # los casos van entre comillas simples y se evalúan con eval
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8 LC_ALL=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS DELTACTL_SECRET_DIRS

rm -rf instances/nc-*
TMPD="$(mktemp -d)"
trap 'rm -rf instances/nc-* "$TMPD"' EXIT
run() { ROOT="$PWD" bash -c "source lib/bootstrap.sh; $1" 2>&1; }
newi() { DELTACTL_LANG="${LANGX:-es}" ./deltactl new "$@" 2>&1; }
# A function of lib/core/proxy.sh with its arguments as arguments (an entry has "|": it must not meet the shell). It prints the text and, last,
# "#rc=<code> lines=<n> err=<reason>".
prx() { ROOT="$PWD" bash -c 'source lib/bootstrap.sh; f="$1"; shift; rc=0; "$f" "$@" || rc=$?; printf "%s" "$PROXY_OUT"; printf "#rc=%s lines=%s err=%s\n" "$rc" "${PROXY_LINES:-}" "${PROXY_ERR:-}"' _ "$@" 2>&1; }

mkdir -p "$TMPD/dl" "$TMPD/other"
printf '{"type":"service_account","project_id":"p","private_key":"-----BEGIN KEY-----\\nAAAA\\n-----END KEY-----\\n","n":[1,-2.5e3,true,null,{}],"e":[]}\n' > "$TMPD/dl/muni-firebase-adminsdk.json"
cp "$TMPD/dl/muni-firebase-adminsdk.json" "$TMPD/dl/fcm.json"
printf '{"a": 1,}\n' > "$TMPD/bad-comma.json"
printf '{"a": "unterminated}\n' > "$TMPD/bad-string.json"
printf '[1,2,3]\n' > "$TMPD/array.json"
printf 'not json at all\n' > "$TMPD/text.json"
printf '{"a":1} {"b":2}\n' > "$TMPD/two.json"
: > "$TMPD/empty.json"
head -c 140000 /dev/zero | tr '\0' ' ' > "$TMPD/big.json"; printf '{}' >> "$TMPD/big.json"
printf '{"x":1}\n' > "$TMPD/dl/notes.json"
printf '{"x":1}\n' > "$TMPD/other/keeper-firebase.json"

section "1. a file for secrets/ is a JSON object that can be read, and nothing of it is printed"
check "a service account is accepted" 'run "sf_check $TMPD/dl/fcm.json && echo ok" | grep -q "^ok$"'
check "nested arrays, numbers, true/false/null and escapes are accepted" 'run "sf_check $TMPD/dl/muni-firebase-adminsdk.json && echo ok" | grep -q "^ok$"'
for f in bad-comma bad-string array text two empty big; do
  want=notjson; [ "$f" = empty ] && want=empty; [ "$f" = big ] && want=toobig
  check "$f.json is refused ($want)" '[ "$(run "sf_check $TMPD/$f.json || echo \$SF_WHY")" = "'"$want"'" ]'
done
check "a path that does not exist is missing, a folder is not a file" '[ "$(run "sf_check $TMPD/nope.json || echo \$SF_WHY; sf_check $TMPD/dl || echo \$SF_WHY" | tr "\n" " ")" = "missing notfile " ]'
check "a file without permission is unreadable (when not root)" '[ "$(id -u)" -eq 0 ] || { cp "$TMPD/dl/fcm.json" "$TMPD/noperm.json"; chmod 000 "$TMPD/noperm.json"; [ "$(run "sf_check $TMPD/noperm.json || echo \$SF_WHY")" = "unreadable" ]; }'
check "names: letters, digits, dot, hyphen, underscore; never a slash, .. or a leading dot" '
  run "for n in fcm.json keeper-fcm.json a_b-1.json; do sf_valid_name \$n || exit 1; done; for n in ../x a/b .hidden -x \"\" \"a b\" a..b; do sf_valid_name \"\$n\" && exit 1; done; exit 0"'
check "the check never prints the content" '! run "sf_check $TMPD/text.json; sf_check $TMPD/dl/fcm.json" | grep -q "BEGIN\|not json"'
check "the reader starts no process (no command substitution in the JSON functions)" '! sed -n "/^sf_ws()/,/^sf_json_object()/p" lib/core/secretfile.sh | grep -qE "[$][(][^(]"'

section "2. the usual places have candidates, by name"
check "only the names that look like a service account, from the folders given" '
  out="$(run "SF_DIRS=$TMPD/dl:$TMPD/other; sf_candidates; printf \"%s\n\" \"\${SF_CAND[@]}\"")"
  echo "$out" | grep -q "muni-firebase-adminsdk.json" && echo "$out" | grep -q "/dl/fcm.json" && echo "$out" | grep -q "keeper-firebase.json" && ! echo "$out" | grep -q notes.json'
check "the same folder twice counts once and the list stops at 8" '
  for i in 1 2 3 4 5 6 7 8 9 10; do cp "$TMPD/dl/fcm.json" "$TMPD/other/fcm-$i.json"; done
  [ "$(run "SF_DIRS=$TMPD/other:$TMPD/other; sf_candidates; echo \${#SF_CAND[@]}")" = 8 ]'
rm -f "$TMPD"/other/fcm-*.json
check "a folder that does not exist is skipped" '[ "$(run "SF_DIRS=$TMPD/nope:$TMPD/dl; sf_candidates; echo \${#SF_CAND[@]}")" = 2 ]'
check "inside the tests DELTACTL_SECRET_DIRS replaces the folders (not outside them)" '
  [ "$(DELTACTL_TEST_ISOLATED=1 DELTACTL_SECRET_DIRS=$TMPD/dl run "sf_candidates; echo \${#SF_CAND[@]}")" = 2 ] && [ "$(DELTACTL_TEST_ISOLATED= DELTACTL_SECRET_DIRS=$TMPD/dl run "SF_DIRS=$TMPD/other; sf_candidates; echo \${#SF_CAND[@]}")" = 1 ]'
check "sf_install copies with mode 600 and refuses a name that is not valid" '
  mkdir -p "$TMPD/inst/secrets"; run "sf_install $TMPD/dl/fcm.json $TMPD/inst fcm.json" >/dev/null; [ "$(stat -c %a "$TMPD/inst/secrets/fcm.json")" = 600 ] && cmp -s "$TMPD/dl/fcm.json" "$TMPD/inst/secrets/fcm.json" && ! run "sf_install $TMPD/dl/fcm.json $TMPD/inst ../evil" >/dev/null && [ ! -e "$TMPD/inst/evil" ]'

section "3. the proxy block is text: a name and a port that are valid, never anything else"
check "valid and invalid public names" '
  run "for h in a.b.com muni-1.example.org localhost a1; do proxy_host_ok \$h || exit 1; done; for h in \"\" A.com a..b .a a. -a.com a-.com \"a b\" \"a;b\" \"a{b}\" \"a\\\$x\" \"a/b\" \"a.com;rm\" ñ.com; do proxy_host_ok \"\$h\" && { echo bad:\$h; exit 1; }; done; exit 0"'
check "a name longer than 253 or a label longer than 63 is refused" '
  l="$(printf "a%.0s" $(seq 1 64))"; ! run "proxy_host_ok $l.com" >/dev/null && ! run "proxy_host_ok $(printf "a.%.0s" $(seq 1 130))com" >/dev/null'
check "ports: 1 to 65535" 'run "for p in 1 80 65535 4300; do proxy_port_ok \$p || exit 1; done; for p in 0 65536 abc \"\" -1 1.5 \"80;\"; do proxy_port_ok \"\$p\" && exit 1; done; exit 0"'
check "nginx without TLS: one server per service, to the port of the service, the name in server_name" '
  out="$(prx proxy_render nginx 0 "a.example.com|4300|s0" "b.example.com|4101|s1")"
  echo "$out" | grep -q "server_name a.example.com;" && echo "$out" | grep -q "proxy_pass http://127.0.0.1:4300;" && echo "$out" | grep -q "proxy_pass http://127.0.0.1:4101;" && ! echo "$out" | grep -q "listen 443" && [ "$(echo "$out" | grep -c "^server {")" = 2 ]'
check "nginx with TLS: port 80 redirects, 443 has the certificate paths of certbot as text" '
  out="$(prx proxy_render nginx 1 "a.example.com|4300|s0")"
  echo "$out" | grep -q "return 301 https://\$host\$request_uri;" && echo "$out" | grep -q "listen 443 ssl;" && echo "$out" | grep -q "/etc/letsencrypt/live/a.example.com/fullchain.pem" && echo "$out" | grep -q "certbot --nginx -d a.example.com"'
check "nginx passes the headers of a proxy and the websocket upgrade" '
  out="$(prx proxy_render nginx 0 "a.example.com|4300|s0")"
  for h in "Host \$host" "X-Real-IP" "X-Forwarded-For" "X-Forwarded-Proto" "Upgrade \$http_upgrade" "Connection \$connection_upgrade" "map \$http_upgrade"; do echo "$out" | grep -qF "$h" || exit 1; done'
check "Caddy: with TLS the name alone (Caddy gets the certificate), without it http://name" '
  a="$(prx proxy_render caddy 1 "a.example.com|4300|s0")"; b="$(prx proxy_render caddy 0 "a.example.com|4300|s0")"
  echo "$a" | grep -q "^a.example.com {" && echo "$a" | grep -q "reverse_proxy 127.0.0.1:4300" && echo "$b" | grep -q "^http://a.example.com {"'
check "an entry that is not valid writes NOTHING (host, port, label, flavor, tls, no entries)" '
  bad() { local o; o="$(prx proxy_render "$@")"; echo "$o" | grep -q "^#rc=1 lines=0 err=" && [ "$(echo "$o" | wc -l)" = 1 ]; }
  bad nginx 0 "a;b.com|1|s0" && bad nginx 0 "a.com|99999|s0" && bad nginx 0 "a.com|1|s 0" && bad nginx 0 "a.com|1|s0;x" && bad apache 0 "a.com|1|s0" && bad nginx 2 "a.com|1|s0" && bad nginx 0'
check "the number of lines of the block is counted" '[ "$(prx proxy_render caddy 1 "a.com|1|s0" | sed -n "s/.*lines=\([0-9]*\).*/\1/p")" -gt 5 ]'
check "domain names: <catalog name>.<domain>, lowered, one entry per service with its port" '
  [ "$(run "PROXY_PORTS[s0]=4300; PROXY_PORTS[s1]=4101; proxy_domain_names Muni.Example.com s0 s1; printf \"%s\n\" \"\${PROXY_ENTRIES[@]}\"" | tr "\n" " ")" = "auth-backend.muni.example.com|4300|s0 gueo-back-end.muni.example.com|4101|s1 " ]'
check "a domain that is not valid has no entries" '! run "proxy_domain_names \"a b\" s0" >/dev/null'
check "the generator runs no command (no \$( ), no eval, no network, nothing under /etc)" '
  ! sed -n "/^proxy_nginx()/,/^proxy_save()/p" lib/core/proxy.sh | grep -v "PROXY_OUT" | grep -qE "[$][(]|eval|curl|systemctl|nginx -s|>> */etc|> */etc" '
check "proxy_save writes only in the instance, atomically, mode 644" '
  mkdir -p instances/nc-save; ROOT="$PWD" bash -c "source lib/bootstrap.sh; proxy_render nginx 0 \"a.example.com|4300|s0\"; proxy_save nc-save nginx" && [ -f instances/nc-save/proxy/nginx.conf ] && [ "$(stat -c %a instances/nc-save/proxy/nginx.conf)" = 644 ] && [ -z "$(ls -A instances/nc-save/proxy | grep "^\.")" ] && grep -q "proxy_pass http://127.0.0.1:4300" instances/nc-save/proxy/nginx.conf'
check "proxy_save refuses an instance that does not exist, a name that is not valid and an empty block" '
  ! ROOT="$PWD" bash -c "source lib/bootstrap.sh; proxy_render nginx 0 \"a.example.com|4300|s0\"; proxy_save nc-nope nginx" && ! ROOT="$PWD" bash -c "source lib/bootstrap.sh; proxy_render nginx 0 \"a.example.com|4300|s0\"; proxy_save ../x nginx" && ! ROOT="$PWD" bash -c "source lib/bootstrap.sh; PROXY_OUT=; proxy_save nc-save nginx" && [ ! -e instances/proxy ]'
check "proxy_detect says nginx, caddy or nothing from the PATH" '
  mkdir -p "$TMPD/pb"; printf "#!/bin/sh\nexit 0\n" > "$TMPD/pb/caddy"; chmod +x "$TMPD/pb/caddy"
  [ "$(PATH="$TMPD/pb:/usr/bin:/bin" run "[ -x /usr/sbin/nginx ] && echo skip || proxy_detect")" = "caddy" ] || [ -x /usr/sbin/nginx ]'
rm -rf instances/nc-save

section "4. new --env-file puts variables in the files, and a secret is never in a command line"
printf '%s\n' '# a comment' '' 's0:IP_INTERNAL_CONNECTION=s1' 's0:IP_SERVER=https://muni.example.com' 's1:IP_SERVER=https://muni.example.com' 'instance:S0_PORT=4333' > "$TMPD/env1.txt"
check "the variables of the file are written, in the file each one belongs to" '
  newi nc-a --env-file "$TMPD/env1.txt" >/dev/null; [ "$(grep -h "^S0_PORT=" instances/nc-a/.env.instance)" = "S0_PORT=4333" ] && grep -q "^IP_SERVER=https://muni.example.com$" instances/nc-a/.env.s0 && grep -q "^IP_SERVER=https://muni.example.com$" instances/nc-a/.env.s1 && grep -q "^IP_INTERNAL_CONNECTION=s1$" instances/nc-a/.env.s0'
check "a new instance has no .bak: there is nothing to go back to" '[ -z "$(ls instances/nc-a | grep "\.bak$")" ] && [ -z "$(ls -A instances/nc-a | grep "\.bak$")" ]'
check "the files keep their mode and the order of the template" '[ "$(stat -c %a instances/nc-a/.env.s0)" = 600 ] && [ "$(stat -c %a instances/nc-a/.env.instance)" = 600 ] && [ "$(grep -n "^IP_SERVER=" instances/nc-a/.env.s0 | head -1 | cut -d: -f1)" -lt "$(grep -n "^JWT_SECRET=" instances/nc-a/.env.s0 | head -1 | cut -d: -f1)" ]'
check "the port it gives to a service is checked like the one that is proposed (a port that another instance uses stops it, nothing is created)" '
  out="$(newi nc-b --env-file "$TMPD/env1.txt")"; [ ! -e instances/nc-b ] && echo "$out" | grep -qi "4333"'
printf '%s\n' 's0:JWT_SECRET=a-secret-value-that-must-not-appear' > "$TMPD/env2.txt"
check "a secret in the file goes to the file and is never in the output (nor in a message)" '
  out="$(newi nc-c --env-file "$TMPD/env2.txt")"; grep -q "^JWT_SECRET=a-secret-value-that-must-not-appear$" instances/nc-c/.env.s0 && ! echo "$out" | grep -q "must-not-appear" && [ "$(stat -c %a instances/nc-c/.env.s0)" = 600 ]'
printf '%s\n' 's0:S0_NOPE_X=1' 'garbage line' > "$TMPD/env3.txt"
check "a line that is not <file>:<KEY>=<value> stops it with the number of the line, not the line, and creates nothing" '
  out="$(newi nc-d --env-file "$TMPD/env3.txt")"; [ ! -e instances/nc-d ] && echo "$out" | grep -q "2" && ! echo "$out" | grep -q "garbage"'
printf '%s\n' 'instance:S0_PORT=notaport-secretish' > "$TMPD/env4.txt"
check "a value that does not pass its validator stops it before anything is created, and is not printed" '
  out="$(newi nc-e --env-file "$TMPD/env4.txt")"; [ ! -e instances/nc-e ] && echo "$out" | grep -q "S0_PORT" && ! echo "$out" | grep -q "notaport-secretish"'
printf '%s\n' 'sx:FOO=1' > "$TMPD/env5.txt"; printf '%s\n' 's1:IP_SERVER=https://x.example.com' > "$TMPD/env6.txt"
check "an unknown file stops it; a file of a service that the instance does not have stops it" '
  ! newi nc-f --env-file "$TMPD/env5.txt" >/dev/null && ! newi nc-f --services s0 --env-file "$TMPD/env6.txt" >/dev/null && [ ! -e instances/nc-f ]'
check "a file that does not exist stops it" '! newi nc-g --env-file "$TMPD/nope.txt" >/dev/null && [ ! -e instances/nc-g ]'
check "--env-file needs a value" 'newi nc-h --env-file | grep -qi "env-file"'
check "a CRLF file is read like the others" '
  printf "s0:IP_INTERNAL_CONNECTION=s1\r\n" > "$TMPD/crlf.txt"; newi nc-i --env-file "$TMPD/crlf.txt" >/dev/null; grep -q "^IP_INTERNAL_CONNECTION=s1$" instances/nc-i/.env.s0'
check "with --generate-secrets the file wins over what was generated (the value of the person is the one that stays)" '
  newi nc-j --generate-secrets --env-file "$TMPD/env2.txt" >/dev/null; grep -q "^JWT_SECRET=a-secret-value-that-must-not-appear$" instances/nc-j/.env.s0 && ! grep -q "^JWT_SECRET=a-secret-value-that-must-not-appear$" instances/nc-j/.env.s1'
check "the same in English" 'LANGX=en newi nc-k --env-file "$TMPD/env3.txt" | grep -q "is not <file>"'

section "5. new --secret-file copies files to secrets/ (checked first, mode 600)"
check "a file goes to secrets/ with the name asked, mode 600, and nothing of it is printed" '
  out="$(newi nc-l --secret-file "$TMPD/dl/fcm.json:fcm.json" --secret-file "$TMPD/dl/muni-firebase-adminsdk.json:keeper-fcm.json")"; [ "$(stat -c %a instances/nc-l/secrets/fcm.json)" = 600 ] && cmp -s "$TMPD/dl/fcm.json" instances/nc-l/secrets/keeper-fcm.json && ! echo "$out" | grep -q "BEGIN KEY"'
check "without :NAME the name of the file is kept" 'newi nc-m --secret-file "$TMPD/dl/fcm.json" >/dev/null; [ -f instances/nc-m/secrets/fcm.json ]'
check "after it the instance does not list those files as missing" '
  out="$(newi nc-n --secret-file "$TMPD/dl/fcm.json:fcm.json" --secret-file "$TMPD/dl/fcm.json:keeper-fcm.json")"; ! echo "$out" | grep -qE "^ +! +secrets/" && newi nc-n2 | grep -qE "^ +! +secrets/"'
check "a file that is not JSON, empty or missing stops it before anything is created" '
  for f in text empty nope array; do ! newi nc-o --secret-file "$TMPD/$f.json:fcm.json" >/dev/null || exit 1; [ ! -e instances/nc-o ] || exit 1; done'
check "a name that is not valid stops it" '! newi nc-p --secret-file "$TMPD/dl/fcm.json:../evil" >/dev/null && ! newi nc-p --secret-file "$TMPD/dl/fcm.json:.x" >/dev/null && [ ! -e instances/nc-p ]'
check "the reason is said, the content is not" '
  out="$(newi nc-q --secret-file "$TMPD/text.json:fcm.json")"; echo "$out" | grep -q "no es un objeto JSON" && ! echo "$out" | grep -q "not json at all"'

section "6. new --domain writes the proxy block inside the instance and nowhere else"
check "--domain alone writes both files, from the ports the instance ended with" '
  newi nc-r --domain muni.example.com >/dev/null; p0="$(grep "^S0_PORT=" instances/nc-r/.env.instance | cut -d= -f2)"; p1="$(grep "^S1_PORT=" instances/nc-r/.env.instance | cut -d= -f2)"
  grep -q "proxy_pass http://127.0.0.1:$p0;" instances/nc-r/proxy/nginx.conf && grep -q "reverse_proxy 127.0.0.1:$p1" instances/nc-r/proxy/Caddyfile && grep -q "server_name auth-backend.muni.example.com;" instances/nc-r/proxy/nginx.conf'
check "--proxy nginx writes only nginx; --tls adds the 443 block" '
  newi nc-s --domain m.example.com --proxy nginx --tls >/dev/null; [ -f instances/nc-s/proxy/nginx.conf ] && [ ! -e instances/nc-s/proxy/Caddyfile ] && grep -q "listen 443 ssl" instances/nc-s/proxy/nginx.conf'
printf '%s\n' 'instance:S0_PORT=4555' > "$TMPD/env7.txt"
check "a port set by --env-file is the one in the block" '
  newi nc-t --domain m.example.com --env-file "$TMPD/env7.txt" >/dev/null; grep -q "proxy_pass http://127.0.0.1:4555;" instances/nc-t/proxy/nginx.conf'
check "only the services of the instance are in the block" '
  newi nc-u --services s1 --domain m.example.com >/dev/null; grep -q gueo-back-end instances/nc-u/proxy/nginx.conf && ! grep -q auth-backend instances/nc-u/proxy/nginx.conf'
check "the block is text: it holds no secret and the instance holds nothing else outside its folder" '
  ! grep -rqi "secret\|password" instances/nc-r/proxy && [ ! -e /etc/nginx/conf.d/nc-r.conf ]'
check "a domain that is not valid, --proxy without --domain, --tls without --domain and a flavor that does not exist stop it, with nothing created" '
  ! newi nc-v --domain "a b" >/dev/null && ! newi nc-v --proxy nginx >/dev/null && ! newi nc-v --tls >/dev/null && ! newi nc-v --domain a.com --proxy apache >/dev/null && [ ! -e instances/nc-v ]'
check "the messages say it is text and where it was written (es and en)" '
  newi nc-w --domain m.example.com | grep -q "solo texto" && LANGX=en newi nc-x --domain m.example.com | grep -q "text only"'
check "every message of the new options exists in both languages" '
  for k in envfile_unreadable envfile_line envfile_file envfile_inactive envfile_invalid envfile_write secret_name secret_missing secret_notfile secret_unreadable secret_empty secret_toobig secret_notjson secret_copy secret_copied domain_invalid proxy_opt proxy_needs_domain proxy_render proxy_write proxy_written; do
    grep -q "MSG_es\[\"new.$k\"\]" lib/i18n/es/new.sh && grep -q "MSG_en\[\"new.$k\"\]" lib/i18n/en/new.sh || { echo "falta $k"; exit 1; }
  done'

finish

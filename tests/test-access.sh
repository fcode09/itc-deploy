#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2046  # the cases go in single quotes and are evaluated with eval
# The Access tab of the workspace of an instance (lib/screens/ws/acceso.sh, lib/screens/accdom.sh) and what it stands on (lib/core/proxy.sh: what an
# instance remembers of its access, the ports, whether a service answers, whether the saved block is the one that would be written now). Covers:
# what is remembered (written atomically, read back, hostile or broken files ignored, guessed from the block `new --domain` left), the blocks
# themselves (golden text for nginx and Caddy, with and without HTTPS, `nginx -t` when this machine has nginx), the keys of the tab (domain,
# other proxy, HTTPS, copy, save, scroll, zoom), that saving writes only inside instances/<name>/proxy/ and nothing under /etc, that the drawing
# starts no process and that a state change is never a stale screen. No real Docker.
# Golden text: tests/golden/access/<flavor>-<tls|http>.txt. DELTACTL_GOLDEN=record rewrites them (only when a change is intended).
# Run it from the root of the isolated copy (tests/run.sh).
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8 LC_ALL=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS DELTACTL_TUI_KEYS DELTACTL_TUI_EVENTS DELTACTL_TUI_ROWS DELTACTL_THEME DELTACTL_TUI_WSENV DELTACTL_TUI_WSACC
unset DELTACTL_REFRESH DELTACTL_METRICS_INTERVAL DELTACTL_TUI_IDLE_AFTER DELTACTL_TUI_GATE DELTACTL_CLIP DELTACTL_PR_SHELL DELTACTL_GRAPH TUI_GRAPH

FIX="$(mktemp -d)"
export FIX
LISTENER=""
trap 'rm -rf "$FIX" instances/ta-*; [ -z "$LISTENER" ] || kill "$LISTENER" 2>/dev/null' EXIT
rm -rf instances/ta-*
mkdir -p "$FIX/bin"
: > "$FIX/containers.txt"; : > "$FIX/images.txt"; : > "$FIX/stats.txt"; : > "$FIX/calls.log"
cp tests/fake-docker.sh "$FIX/bin/docker-fake"
cat > "$FIX/bin/docker" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  ps) n=$(wc -l < "$FIX/containers.txt"); for ((i = 1; i <= n; i++)); do echo "c$i"; done ;;
  inspect) cat "$FIX/containers.txt" ;;
  stats) cat "$FIX/stats.txt" ;;
  logs) echo "linea normal" ;;
  compose) exec bash "$FIX/bin/docker-fake" "$@" ;;
  *) exec bash "$FIX/bin/docker-fake" "$@" ;;
esac
SHIM
printf '#!/bin/sh\nexit 0\n' > "$FIX/bin/ss"
chmod +x "$FIX/bin/docker" "$FIX/bin/ss"
export PATH="$FIX/bin:$PATH"
printf 'MemTotal:        8388608 kB\nMemAvailable:    3145728 kB\n' > "$FIX/meminfo"
printf '0.82 0.50 0.40 1/200 1234\n' > "$FIX/loadavg"
export DELTACTL_MEMINFO="$FIX/meminfo" DELTACTL_LOADAVG="$FIX/loadavg"
export DELTACTL_PROC_ROOT="$FIX/proc" DELTACTL_CGROUP_ROOT="$FIX/cg" DELTACTL_CONFIG="$FIX/none.cfg"

newinst() { bash ./deltactl new "$1" > /dev/null 2>&1; }
newinst ta-a; newinst ta-b
setp() { sed -i "s/^$2=.*/$2=$3/" "instances/$1/.env.instance"; }
setp ta-a S0_PORT 4100; setp ta-a S1_PORT 4101

KEYS="$FIX/keys.txt"
# The panel with the keys given (one per line): ASCII, no colours, 160 x 40 (the access tab is a whole column there). PANEL_COLS / PANEL_ROWS change it.
panel() { printf '%s\n' "$@" > "$KEYS"; DELTACTL_TUI_KEYS="$KEYS" DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_ASCII=1 COLUMNS="${PANEL_COLS:-160}" DELTACTL_TUI_ROWS="${PANEL_ROWS:-40}" DELTACTL_LANG="${LANGX:-es}" bash ./deltactl 2>&1; }
last_frame() { awk '/^=== frame /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }'; }
frame_n() { awk -v n="$1" '/^=== frame /{ f = ($3 == n) } f'; }
# The keys that type a text, one character per line.
typed() { local s="$1" i c; for ((i = 0; i < ${#s}; i++)); do c="${s:i:1}"; if [ "$c" = " " ]; then echo space; else echo "$c"; fi; done; }
run_lib() { ROOT="$PWD" DELTACTL_TUI_KEYS=/dev/null DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_ASCII=1 COLUMNS=160 DELTACTL_TUI_ROWS=40 bash -c 'source lib/bootstrap.sh; source lib/cmd/dashboard.sh; set +e; '"$1" 2>&1; }
core() { ROOT="$PWD" bash -c 'source lib/bootstrap.sh; set +e; '"$1" 2>&1; }
files() { (cd "instances/$1" && find . -type f | sort); }

section "1. what an instance remembers of its access"
check "a domain, a proxy and HTTPS are saved and read back (the domain lowered)" '[ "$(core "proxy_meta_save ta-a Ejemplo.PE caddy 0 && proxy_meta_load ta-a && echo \"\$PROXY_M_DOMAIN \$PROXY_M_FLAVOR \$PROXY_M_TLS \$PROXY_M_FROM\"")" = "ejemplo.pe caddy 0 file" ]'
check "the file is plain text with three lines, readable by everyone (it holds no secret) and no temporary file is left" '[ "$(cat instances/ta-a/proxy/access.conf)" = "$(printf "DOMAIN=ejemplo.pe\nFLAVOR=caddy\nTLS=0")" ] && [ "$(stat -c %a instances/ta-a/proxy/access.conf)" = "644" ] && [ -z "$(ls -A instances/ta-a/proxy | grep "^\.")" ]'
check "what is not valid is refused and nothing is written: a name that is not a host, a proxy that is not nginx or caddy, HTTPS that is not 0 or 1, an instance that is not one" 'rm -rf instances/ta-b/proxy; core "proxy_meta_save ta-b -bad.pe nginx 1; echo \$?; proxy_meta_save ta-b a.pe apache 1; echo \$?; proxy_meta_save ta-b a.pe nginx 2; echo \$?; proxy_meta_save ../ta-b a.pe nginx 1; echo \$?; proxy_meta_save ta-zz a.pe nginx 1; echo \$?" | tr "\n" " " | grep -q "^1 1 1 1 1 $" && [ ! -e instances/ta-b/proxy ]'
check "a file that is not ours is read as data, never run: a hostile line is ignored, a good one is kept" 'mkdir -p instances/ta-b/proxy; printf "DOMAIN=a;touch %s/pwned\nDOMAIN=ok.pe\nFLAVOR=evil\nFLAVOR=nginx\nTLS=7\nTLS=0\nEXTRA=\$(touch %s/pwned2)\n" "$FIX" "$FIX" > instances/ta-b/proxy/access.conf; [ "$(core "proxy_meta_load ta-b; echo \"\$PROXY_M_DOMAIN \$PROXY_M_FLAVOR \$PROXY_M_TLS\"")" = "ok.pe nginx 0" ] && [ ! -e "$FIX/pwned" ] && [ ! -e "$FIX/pwned2" ]'
check "a file with CRLF line ends is read too" 'printf "DOMAIN=crlf.pe\r\nFLAVOR=caddy\r\nTLS=1\r\n" > instances/ta-b/proxy/access.conf; [ "$(core "proxy_meta_load ta-b; echo \"\$PROXY_M_DOMAIN \$PROXY_M_FLAVOR \$PROXY_M_TLS\"")" = "crlf.pe caddy 1" ]'
check "with no file and no block nothing is remembered" 'rm -rf instances/ta-b/proxy; [ "$(core "proxy_meta_load ta-b; echo \"[\$PROXY_M_DOMAIN][\$PROXY_M_FLAVOR][\$PROXY_M_TLS][\$PROXY_M_FROM]\"")" = "[][][1][none]" ]'
rm -rf instances/ta-a/proxy      # (what the first checks saved in ta-a: the cases of the panel start from an instance that remembers nothing)
newinst ta-c
bash ./deltactl new ta-d --domain guess.pe --proxy nginx --tls > /dev/null 2>&1
bash ./deltactl new ta-e --domain plain.pe --proxy caddy > /dev/null 2>&1
check "without access.conf the domain is guessed from the block that new --domain left: nginx with HTTPS" '[ -f instances/ta-d/proxy/nginx.conf ] && [ ! -e instances/ta-d/proxy/access.conf ] && [ "$(core "proxy_meta_load ta-d; echo \"\$PROXY_M_DOMAIN \$PROXY_M_FLAVOR \$PROXY_M_TLS \$PROXY_M_FROM\"")" = "guess.pe nginx 1 block" ]'
check "and from a Caddyfile without HTTPS" '[ -f instances/ta-e/proxy/Caddyfile ] && [ "$(core "proxy_meta_load ta-e; echo \"\$PROXY_M_DOMAIN \$PROXY_M_FLAVOR \$PROXY_M_TLS \$PROXY_M_FROM\"")" = "plain.pe caddy 0 block" ]'
check "the ports of the services are read from .env.instance (no process)" '[ "$(core "proxy_instance_ports ta-a s0 s1; echo \"\${PROXY_PORTS[s0]} \${PROXY_PORTS[s1]}\"")" = "4100 4101" ]'

section "2. the saved block against the one that would be written now"
ENT='"auth-backend.ejemplo.pe|4100|s0" "gueo-back-end.ejemplo.pe|4101|s1"'
check "no file: none" '[ "$(core "proxy_render nginx 1 $ENT; proxy_state ta-c nginx; echo \$PROXY_SAVED")" = "none" ]'
check "the file is what would be written: same; a change in the block: differs" 'core "proxy_render nginx 1 $ENT; proxy_save ta-c nginx" ; [ "$(core "proxy_render nginx 1 $ENT; proxy_state ta-c nginx; echo \$PROXY_SAVED")" = "same" ] && [ "$(core "proxy_render nginx 0 $ENT; proxy_state ta-c nginx; echo \$PROXY_SAVED")" = "differs" ]'
check "a flavor that does not exist or an instance that is not one has no state" '! core "proxy_state ta-c apache" | grep -q . ; [ "$(core "proxy_state ../x nginx; echo \$?")" = "1" ]'

section "3. does something answer on this server"
if command -v python3 > /dev/null 2>&1; then
  python3 -c 'import socket,sys,time
s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(5)
open(sys.argv[1],"w").write(str(s.getsockname()[1]))
t=socket.socket(); t.bind(("127.0.0.1",0)); open(sys.argv[2],"w").write(str(t.getsockname()[1])); t.close()
time.sleep(300)' "$FIX/port.open" "$FIX/port.closed" &
  LISTENER=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$FIX/port.closed" ] && break; sleep 0.2; done
  OPEN="$(cat "$FIX/port.open" 2> /dev/null)" CLOSED="$(cat "$FIX/port.closed" 2> /dev/null)"
  check "a port with a listener answers" '[ -n "$OPEN" ] && core "proxy_reach $OPEN"'
  check "a port that nobody listens on does not" '[ -n "$CLOSED" ] && ! core "proxy_reach $CLOSED"'
else
  echo "  SKIP python3 is not here: no listener to probe"
  OPEN="" CLOSED=""
fi
check "a value that is not a port is not probed (2) and never reaches a shell" '[ "$(core "proxy_reach \"80; touch $FIX/pwned3\"; echo \$?")" = "2" ] && [ "$(core "proxy_reach 0; echo \$?")" = "2" ] && [ "$(core "proxy_reach 70000; echo \$?")" = "2" ] && [ ! -e "$FIX/pwned3" ]'

section "4. the blocks: golden text, and nginx -t when this machine has nginx"
GOLD="${DELTACTL_GOLDEN_DIR:-tests/golden}/access"
MODE="${DELTACTL_GOLDEN:-check}"
mkdir -p "$GOLD" 2> /dev/null || true
for fl in nginx caddy; do
  for tls in 1 0; do
    n="$fl-$([ "$tls" = 1 ] && echo tls || echo http)"
    core "proxy_render $fl $tls $ENT; printf '%s' \"\$PROXY_OUT\"" > "$FIX/$n.txt"
    if [ "$MODE" = record ]; then cp "$FIX/$n.txt" "$GOLD/$n.txt"; echo "  REC  $n"
    else check "the $fl block ($([ "$tls" = 1 ] && echo "with HTTPS" || echo "http only")) equals its golden text" '[ -f "$GOLD/$n.txt" ] && cmp -s "$FIX/$n.txt" "$GOLD/$n.txt"'; fi
  done
done
check "the nginx block passes the headers a proxy needs: Host, X-Forwarded-For, X-Forwarded-Proto and the upgrade of a WebSocket" 'grep -q "proxy_set_header Host" "$FIX/nginx-http.txt" && grep -q "X-Forwarded-For" "$FIX/nginx-http.txt" && grep -q "X-Forwarded-Proto" "$FIX/nginx-http.txt" && grep -q "proxy_set_header Upgrade" "$FIX/nginx-http.txt" && grep -q "map \$http_upgrade" "$FIX/nginx-http.txt"'
if command -v nginx > /dev/null 2>&1; then
  mkdir -p "$FIX/ng/logs" "$FIX/ng/tmp"
  { printf 'pid %s/ng/nginx.pid;\nerror_log %s/ng/logs/error.log;\nevents {}\nhttp {\n access_log off;\n client_body_temp_path %s/ng/tmp;\n proxy_temp_path %s/ng/tmp;\n fastcgi_temp_path %s/ng/tmp;\n uwsgi_temp_path %s/ng/tmp;\n scgi_temp_path %s/ng/tmp;\n' "$FIX" "$FIX" "$FIX" "$FIX" "$FIX" "$FIX" "$FIX"; cat "$FIX/nginx-http.txt"; printf '}\n'; } > "$FIX/ng/nginx.conf"
  check "nginx accepts the block (nginx -t in a prefix of its own: nothing of the system is read or written)" 'nginx -t -p "$FIX/ng" -c "$FIX/ng/nginx.conf" 2>&1 | grep -q "syntax is ok"'
else
  echo "  SKIP nginx is not here: the block was compared with its golden text"
fi

section "5. the tab: where it is, what it shows"
check "the access tab is registered with one line and is a file of lib/screens/ws" '[ -f lib/screens/ws/acceso.sh ] && grep -q "^dash_ws_register acceso " lib/screens/instances_ws.sh && [ "$(run_lib "echo \${DASH_WS_TABS[*]}")" = "resumen logs acceso historial servicios variables datos" ]'
check "the mode that types the domain is registered" 'run_lib "printf \"%s \" \${DASH_MODES[@]}" | grep -q "accdom "'
check "an instance with no services has no access tab (the services tab is there: it is how one is added)" '[ "$(run_lib "COLUMNS=100; DELTACTL_TUI_ROWS=30; tui_size; DASH_SVCS[x]=\"\"; dash_ws_visible x; echo \${DASH_WS_VIS[*]}")" = "resumen servicios variables datos" ]'
out="$(panel '>' q)"
check "> opens it with the focus in it: the strip names it, the border says whose it is, and the domain, the proxy and HTTPS are there" 'f="$(echo "$out" | frame_n 2)"; echo "$f" | grep -q "\[Resumen\] Acceso\|Resumen \[Acceso\]" && echo "$f" | grep -q "\[ >ta-a" && echo "$f" | grep -q "Dominio" && echo "$f" | grep -q "Proxy" && echo "$f" | grep -q "HTTPS"'
check "with no domain it says what to do instead of an empty box, and no block is shown" 'f="$(echo "$out" | frame_n 2)"; echo "$f" | grep -q "Escribe el dominio" && ! echo "$f" | grep -q "server_name"'
check "the services are a table: port, whether they answer here (not checked yet) and the public name column" 'f="$(echo "$out" | frame_n 2)"; echo "$f" | grep -q "Servicio *Puerto" && echo "$f" | grep -q "s0 *:4100" && echo "$f" | grep -q "s1 *:4101" && echo "$f" | grep -q "sin comprobar"'
check "the last line has the keys of the tab" 'echo "$out" | frame_n 2 | tail -2 | grep -q "Enter dominio . b otro proxy . w https . y copiar . g guardar"'
check "the border has the keys too (the ones that do not fit are dropped whole)" 'echo "$out" | frame_n 2 | grep -q "\[Enter dominio\]-\[b bloque\]-\[w https\]-\[y copiar\]-\[g guardar\]"'
check "in English the tab says Access, Domain and its keys in English" 'f="$(LANGX=en panel ">" q | frame_n 2)"; echo "$f" | grep -q "Access" && echo "$f" | grep -q "Domain" && echo "$f" | grep -q "Enter domain . b other proxy"'
check "on a small terminal the first lines are kept and no line is wider than the screen" 'f="$(PANEL_COLS=80 PANEL_ROWS=24 panel ">" ">" q | frame_n 3)"; [ "$(echo "$f" | awk "{ if (length(\$0) > 80) b = 1 } END { print b + 0 }")" = "0" ] && echo "$f" | grep -q "Dominio"'
check "the column is the tab's: the logs that sit under the summary are not drawn under it" '! echo "$out" | frame_n 2 | grep -q "Logs . s0"'

section "6. the keys: domain, other proxy, HTTPS, copy, save"
out="$(panel '>' enter $(typed ejemplo.pe) enter q)"
check "Enter opens the line of the domain (the last line says how it ends) and typing fills it" 'echo "$out" | frame_n 3 | tail -2 | grep -q "Enter acepta el dominio" && echo "$out" | frame_n 3 | grep -q "Dominio .*ejemplo.pe" '
check "Enter keeps it: the block of each service is there with its public name and its port, and the table has the public names" 'f="$(echo "$out" | last_frame)"; echo "$f" | grep -q "auth-backend.ejemplo.pe" && echo "$f" | grep -q "gueo-back-end.ejemplo.pe" && echo "$f" | grep -q "sin guardar"'
check "a domain in capital letters is lowered" 'f="$(panel ">" enter $(typed Ejemplo.PE) enter q | last_frame)"; echo "$f" | grep -q "auth-backend.ejemplo.pe" && ! echo "$f" | grep -q "Ejemplo"'
out="$(panel '>' enter $(typed 'bad_name') enter q)"
check "a name that is not a host is refused, the line stays open for the person to fix it, and no block appears" 'f="$(echo "$out" | last_frame)"; echo "$f" | grep -q "Enter acepta el dominio" && echo "$f" | grep -q "no es un nombre v.lido" && ! echo "$f" | grep -q "server_name"'
out="$(panel '>' enter $(typed ejemplo.pe) esc q)"
check "Esc leaves it as it was (no domain, so no block)" 'echo "$out" | last_frame | grep -q "Escribe el dominio"'
out="$(panel '>' enter $(typed uno.pe) enter enter backspace backspace backspace backspace backspace backspace enter q)"
check "an empty line removes the domain: no block is generated any more" 'f="$(echo "$out" | last_frame)"; echo "$f" | grep -q "Escribe el dominio" && ! echo "$f" | grep -q "uno.pe"'
out="$(panel '>' y g q)"
check "with no domain y and g say there is no block and write nothing" 'echo "$out" | grep -q "No hay bloque" && [ ! -e instances/ta-a/proxy ]'
rm -rf instances/ta-a/proxy
before="$(files ta-a)"; envsum="$(md5sum instances/ta-a/.env.* | md5sum)"
out="$(panel '>' enter $(typed ejemplo.pe) enter g q)"
check "g saves the block and what the tab remembers inside the instance, and says nothing was touched elsewhere" 'f="$(echo "$out" | last_frame)"; echo "$f" | grep -q "Guardado en instances/ta-a/proxy/" && echo "$f" | grep -q "No se ha tocado /etc"'
after="$(files ta-a)"
check "only two files appeared in the instance, both under proxy/: the block and access.conf" '[ "$(diff <(echo "$before") <(echo "$after") | grep "^[<>]" | sort | tr "\n" " ")" = "> ./proxy/access.conf > ./proxy/nginx.conf " ] || [ "$(diff <(echo "$before") <(echo "$after") | grep "^[<>]" | sort | tr "\n" " ")" = "> ./proxy/Caddyfile > ./proxy/access.conf " ]'
check "the saved block has the ports of the instance and the access file the domain and HTTPS" 'grep -qE "proxy_pass http://127.0.0.1:4100|reverse_proxy 127.0.0.1:4100" instances/ta-a/proxy/* && grep -q "^DOMAIN=ejemplo.pe$" instances/ta-a/proxy/access.conf && grep -q "^TLS=1$" instances/ta-a/proxy/access.conf'
check "nothing of the instance changed outside proxy/: its files are the same and the .env files have the same content" '[ "$(files ta-a | grep -v "^./proxy/" | md5sum)" = "$(echo "$before" | grep -v "^./proxy/" | md5sum)" ] && [ "$(md5sum instances/ta-a/.env.* | md5sum)" = "$envsum" ]'
out="$(panel '>' q)"
check "the next time the panel remembers: the domain, and the saved block is the one that would be written (guardado)" 'f="$(echo "$out" | frame_n 2)"; echo "$f" | grep -q "Dominio .*ejemplo.pe" && echo "$f" | grep -q "guardado"  && ! echo "$f" | grep -q "sin guardar"'
out="$(panel '>' b q)"
check "b shows the other proxy: the block is the one of Caddy and it is not the saved one" 'f="$(echo "$out" | last_frame)"; echo "$f" | grep -q "Bloque de caddy" && echo "$f" | grep -q "reverse_proxy" && echo "$f" | grep -q "sin guardar"'
out="$(panel '>' w q)"
check "w turns HTTPS off: the block is http only, and it differs from the saved one" 'f="$(echo "$out" | last_frame)"; echo "$f" | grep -qE "HTTPS +no" && ! echo "$f" | grep -q "listen 443" && echo "$f" | grep -q "distinto del guardado"'
out="$(panel '>' w w q)"
check "w twice is HTTPS on again, and the block is the saved one again" 'echo "$out" | last_frame | grep -q "guardado" && ! echo "$out" | last_frame | grep -q "distinto"'
rm -f "$FIX/clip.txt"
DELTACTL_CLIP="cat > $FIX/clip.txt" panel '>' y q > /dev/null 2>&1 || true
check "y copies the whole block (with the lines of comments that say where it goes), the same text that g saves" '[ -s "$FIX/clip.txt" ] && [ "$(cat "$FIX/clip.txt")" = "$(cat instances/ta-a/proxy/nginx.conf)" ]'
check "PgDn scrolls the block and the first line of it leaves the box; Home brings it back" 'f1="$(panel ">" q | frame_n 2)"; f2="$(panel ">" pgdn q | frame_n 3)"; f3="$(panel ">" pgdn home q | frame_n 4)"; echo "$f1" | grep -q "map .http_upgrade" && ! echo "$f2" | grep -q "map .http_upgrade" && echo "$f3" | grep -q "map .http_upgrade"'
check "z gives the tab the whole body and z again gives it back" 'f="$(panel ">" z q | frame_n 3)"; ! echo "$f" | grep -q "Nueva instancia" && echo "$f" | grep -q "Dominio"; panel ">" z z q | frame_n 4 | grep -q "Nueva instancia"'
check "Esc goes back to the list (the access tab stays chosen) and right comes back into it" 'f="$(panel ">" esc q | frame_n 3)"; echo "$f" | grep -q "Instancias" && echo "$f" | grep -q "Acceso"; panel ">" esc right q | frame_n 4 | grep -q "\[ >ta-a"'
check "Tab walks the list and the tab (the tab that owns a pane has one stop), and does not stop in the services of the summary" '[ "$(panel ">" tab q | frame_n 3 | grep -c "\[ >ta-a")" -eq 0 ] && [ "$(panel ">" tab tab q | frame_n 4 | grep -c "\[ >ta-a")" -ge 1 ]'
check "up and down choose the service (its row is marked)" 'panel ">" q | frame_n 2 | grep -q "> . s0" && panel ">" down q | frame_n 3 | grep -q "> . s1"'
check "the keys of the summary still work in the tab that is not the tab's: u deploys, c checks (they are not taken)" 'panel ">" c wait q | grep -q "Ejecutando: ./deltactl check ta-a"'

section "7. a state change is never a stale screen"
check "every key that changes the tab changes the frame: other proxy, HTTPS, a service, the domain" 'a="$(panel ">" q | frame_n 2 | sed 1d | md5sum)"; for k in b w down; do [ "$(panel ">" $k q | frame_n 3 | sed 1d | md5sum)" != "$a" ] || { echo "$k"; exit 1; }; done; [ "$(panel ">" enter x enter q | last_frame | sed 1d | md5sum)" != "$a" ]'
check "what a frame depends on is in its signature: the tab says its own part of it" 'run_lib "DASH_NAMES=(ta-a); DASH_SEL=0; DASH_ON_NEW=0; DASH_SVCS[ta-a]=\"s0 s1\"; DASH_WS_TAB=acceso; DASH_FOCUS=tab; dash_init; DASH_SIG=\"\"; dash_ws_frame_sig; a=\"\$DASH_SIG\"; DASH_ACC_N=\$((DASH_ACC_N + 1)); DASH_SIG=\"\"; dash_ws_frame_sig; [ \"\$a\" != \"\$DASH_SIG\" ] && echo different" | grep -q different'

section "8. what answers on this server is read in the background and shown"
if [ -n "${OPEN:-}" ] && [ -n "${CLOSED:-}" ]; then
  setp ta-a S0_PORT "$OPEN"; setp ta-a S1_PORT "$CLOSED"
  out="$(DELTACTL_TUI_WSACC=1 panel '>' q)"
  check "a service whose port has a listener answers, one that has none does not" 'f="$(echo "$out" | frame_n 2)"; echo "$f" | grep -qE "s0 +:$OPEN +responde" && echo "$f" | grep -qE "s1 +:$CLOSED +sin respuesta"'
  check "the block uses the ports the instance has now" 'DELTACTL_TUI_WSACC=1 panel ">" enter $(typed ejemplo.pe) enter w q | last_frame | grep -q "127.0.0.1:$OPEN"'
  setp ta-a S0_PORT 4100; setp ta-a S1_PORT 4101
else
  echo "  SKIP no listener: the probe of a port was not shown"
fi
check "the probe is not taken in a test unless it is asked for (a test never waits for a connection)" '! panel ">" q | frame_n 2 | grep -q "responde"'
setp ta-a S1_PORT ""
check "a service with no port in .env.instance says so, and the block is not generated with a hole in it" 'f="$(DELTACTL_TUI_WSACC=1 panel ">" enter $(typed ejemplo.pe) enter q | last_frame)"; echo "$f" | grep -q "sin puerto" && echo "$f" | grep -q "Falta el puerto de s1" && ! echo "$f" | grep -q "server_name"'
setp ta-a S1_PORT 4101

section "9. it never touches the system, and the drawing starts no process"
check "the tab and its mode have no command that writes under /etc, reloads or installs anything (the comments apart)" '! grep -vE "^[[:space:]]*#" lib/screens/ws/acceso.sh lib/screens/accdom.sh | grep -qE "systemctl|sudo|apt-get|nginx -|caddy reload|/etc/|certbot"'
inside_only() { local d="$FIX/inst"; rm -rf "$d"; mkdir -p "$d/zz"; ROOT="$PWD" bash -c 'source lib/bootstrap.sh; set +e; INSTANCES_DIR="$1"; proxy_render nginx 0 "a.pe|4100|s0" && proxy_save zz nginx && proxy_meta_save zz a.pe nginx 0' _ "$d"; (cd "$d" && find . -type f | sort | tr '\n' ' '); }
check "the core writes only inside the instance: proxy_save and proxy_meta_save build the path from INSTANCES_DIR and the validated name" '[ "$(inside_only)" = "./zz/proxy/access.conf ./zz/proxy/nginx.conf " ]'
body() { sed -n "/^$1() {/,/^}/p" lib/screens/ws/acceso.sh | grep -vE "^[[:space:]]*#"; }
check "the model and the drawing of the tab start no process: no command substitution in them" 'for f in dash_acc_model dash_acc_top dash_acc_table dash_acc_label ws_acceso_box ws_acceso_sig dash_acc_load dash_acc_ports; do body "$f" | grep -qE "\\$\\([^(]|\`" && { echo "$f"; exit 1; }; done; true'
check "the tab that is chosen is read when the key arrives and when the loop turns, not at every frame: the tick does nothing while another tab is on screen" '[ "$(run_lib "DASH_VIEW=instances; DASH_NAMES=(ta-a); DASH_SEL=0; DASH_ON_NEW=0; DASH_SVCS[ta-a]=\"s0\"; DASH_WS_TAB=resumen; ws_acceso_tick; echo \"[\${DASH_ACC_LOADED[ta-a]:-}]\"")" = "[]" ]'

finish

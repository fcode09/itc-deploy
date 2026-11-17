#!/usr/bin/env bash
# Tests of the interactive panel (lib/cmd/dashboard.sh) and its terminal layer (lib/ui/tui.sh).
# The panel runs in test mode: DELTACTL_TUI_KEYS points to a file with one key name per line and every frame is
# printed as plain text, so no real terminal is needed. Docker is simulated. Runs from the root of the isolated copy.
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS DELTACTL_TUI_KEYS

FIX="$(mktemp -d)"
export FIX
trap 'rm -rf "$FIX" instances/tui-*' EXIT
rm -rf instances/tui-*
mkdir -p "$FIX/bin"
: > "$FIX/containers.txt"; : > "$FIX/images.txt"; : > "$FIX/stats.txt"

cp tests/fake-docker.sh "$FIX/bin/docker-fake"
cat > "$FIX/bin/docker" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  ps) n=$(wc -l < "$FIX/containers.txt"); for ((i = 1; i <= n; i++)); do echo "c$i"; done ;;
  inspect) cat "$FIX/containers.txt" ;;
  stats) cat "$FIX/stats.txt" ;;
  logs) echo "linea normal" ;;
  *) exec bash "$FIX/bin/docker-fake" "$@" ;;
esac
SHIM
printf '#!/bin/sh\nexit 0\n' > "$FIX/bin/ss"
chmod +x "$FIX/bin/docker" "$FIX/bin/ss"
export PATH="$FIX/bin:$PATH"
printf 'MemTotal:        8388608 kB\nMemAvailable:    3145728 kB\n' > "$FIX/meminfo"
printf '0.82 0.50 0.40 1/200 1234\n' > "$FIX/loadavg"
export DELTACTL_MEMINFO="$FIX/meminfo" DELTACTL_LOADAVG="$FIX/loadavg"

# Runs the panel with the keys given as arguments (one per line) and optional stdin. ASCII, no colors.
KEYS="$FIX/keys.txt"
panel() { # key...  (stdin: answers to the confirmation prompts)
  printf '%s\n' "$@" > "$KEYS"
  DELTACTL_TUI_KEYS="$KEYS" DELTACTL_UI=rich DELTACTL_COLOR=never DELTACTL_ASCII=1 COLUMNS=100 bash ./deltactl 2>&1
}
frames() { grep -c '^=== frame' ; }

section "1. no instances"
out="$(panel q)"
check "the panel opens and shows the empty state" 'echo "$out" | grep -q "^=== frame 1 ===" && echo "$out" | grep -q "no hay instancias; pulsa n para crear una"'
check "the panel shows the keys in the footer" 'echo "$out" | grep -q "Arriba/Abajo mover - Enter acciones - r refrescar"'

started() { date -u -d "$1 ago" +%Y-%m-%dT%H:%M:%S.000000000Z; }
container() { printf '%s|%s|%s|%s|%s|%s|/%s_%s\n' "$1" "$2" "$3" "$4" "$5" "$(started "$6")" "$2" "$1" >> "$FIX/containers.txt"; }
image() { printf '%s|%s|amd64\n' "$1" "$2" >> "$FIX/images.txt"; }
deployed() { printf '%s_TAG=%s\n%s_IMAGE_ID=%s\n' "${2^^}" "$3" "${2^^}" "$4" >> "instances/$1/.deployed"; }
newinst() { bash ./deltactl new "$1" >/dev/null 2>&1; fill_instance "instances/$1" "$2" "$3"; }
seeded() { printf 'SOURCE=init\nINITIALIZED_AT=2026-01-01T00:00:00Z\n' > "instances/$1/.initialized"; }
newinst tui-a 1.0 1.0; seeded tui-a
newinst tui-b 1.0 1.0
newinst tui-c 1.0 1.0; seeded tui-c
image auth-backend:1.0 sha256:aaa; image gueo-back-end:1.0 sha256:bbb
deployed tui-a s0 1.0 sha256:aaa; deployed tui-a s1 1.0 sha256:bbb
container tui-a s0 running healthy auth-backend:1.0 "2 days"
container tui-a s1 running healthy gueo-back-end:1.0 "2 days"
container tui-c s0 running healthy auth-backend:1.0 "1 hour"
container tui-c s1 exited none gueo-back-end:1.0 "1 hour"

section "2. the list of instances"
out="$(panel q)"
check "every instance is a row with its n/m" 'echo "$out" | grep -q "tui-a  *2/2" && echo "$out" | grep -q "tui-b  *0/2" && echo "$out" | grep -q "tui-c  *1/2"'
check "the rows show the services with their state, the ports and the tags" 'echo "$out" | grep "tui-a" | grep -q "s0 \* s1 \*" && echo "$out" | grep "tui-a" | grep -q "4100/4101" && echo "$out" | grep "tui-a" | grep -q "v1.0/1.0"'
check "the first row is selected" 'echo "$out" | grep -q "^> . tui-a\|^> \* tui-a"'
check "the header shows the host line with memory and load" 'echo "$out" | grep -q "Memoria \[######....\] 5.0/8.0 GB 62%" && echo "$out" | grep -q "Carga 0.82"'
check "the next steps are listed under the instances" 'echo "$out" | grep -q "Siguientes pasos sugeridos"'

section "3. moving the selection"
out="$(panel down q)"
check "down moves the selection to the next row" 'echo "$out" | awk "/^=== frame 2/{f=1} f" | grep -q "^> . tui-b"'
out="$(panel up q)"
check "up from the first row wraps to the last" 'echo "$out" | awk "/^=== frame 2/{f=1} f" | grep -q "^> .* tui-c"'
out="$(panel j j k q)"
check "j and k work like the arrows" 'echo "$out" | awk "/^=== frame 4/{f=1} f" | grep -q "^> . tui-b"'
out="$(panel down down down q)"
check "down from the last row wraps to the first" 'echo "$out" | awk "/^=== frame 4/{f=1} f" | grep -q "^> .* tui-a"'

section "4. the actions of an instance"
out="$(panel enter q q)"
check "Enter opens the actions with the instance and its n/m" 'echo "$out" | grep -q "Acciones de tui-a (2/2)"'
check "the actions are listed" 'echo "$out" | grep -q "Ver detalle" && echo "$out" | grep -q "Desplegar" && echo "$out" | grep -q "Volver a la versión anterior" && echo "$out" | grep -q "Bajar la instancia"'
check "a seeded instance does not offer to seed" '! echo "$out" | grep -q "Sembrar datos iniciales"'
out="$(panel down enter q q)"
check "an unseeded instance offers to seed" 'echo "$out" | grep -q "Acciones de tui-b (0/2)" && echo "$out" | grep -q "Sembrar datos iniciales"'
out="$(panel enter enter q)"
check "the first action shows the equivalent command and runs it" 'echo "$out" | grep -q "\-> ./deltactl status tui-a" && echo "$out" | grep -q "^Instancia tui-a"'
check "after an action the panel comes back to the list" 'echo "$out" | tail -12 | grep -q "Instancias"'
out="$(panel enter down enter q)"
check "the second action runs check" 'echo "$out" | grep -q "\-> ./deltactl check tui-a"'
out="$(panel enter esc q)"
check "Esc goes back from the actions to the list" '[ "$(echo "$out" | grep -c "Acciones de tui-a")" -ge 1 ] && echo "$out" | tail -20 | grep -q "Instancias"'

section "5. confirmations"
out="$(printf 'n\n' | panel enter down down down enter q)"
check "rollback asks for confirmation and does nothing on N" 'echo "$out" | grep -q "Vuelve a la versión anterior de todos los servicios de .tui-a.. ¿Continuar? \[s/N\]" && ! echo "$out" | grep -q "\-> ./deltactl rollback"'
out="$(printf 'y\n' | panel enter down down down enter q)"
check "rollback runs after confirming with y" 'echo "$out" | grep -q "\-> ./deltactl rollback tui-a --yes"'
out="$(printf 'n\n' | panel enter down down down down down down down enter q)"
check "down asks for confirmation too" 'echo "$out" | grep -q "Detiene y elimina los contenedores de .tui-a." && ! echo "$out" | grep -q "\-> ./deltactl down"'
out="$(printf 'otro\n' | panel down enter down down down down down down down down enter q)"
check "init asks to type the instance name and cancels if it differs" 'echo "$out" | grep -q "Los seeds BORRAN datos" && echo "$out" | grep -q "cancelado" && ! echo "$out" | grep -q "\-> ./deltactl init tui-b --yes"'

section "6. help, language and refresh"
out="$(panel '?' x q)"
check "? shows the list of keys" 'echo "$out" | grep -q "Teclas" && echo "$out" | grep -q "q o Esc         salir" && echo "$out" | grep -q "Pulsa cualquier tecla para volver"'
export DELTACTL_CONFIG="$FIX/config"
out="$(panel L q)"
check "L switches to English in the next frame" 'echo "$out" | awk "/^=== frame 2/{f=1} f" | grep -q "^  Instances$" && echo "$out" | grep -q "Up/Down move - Enter actions - r refresh"'
check "L remembers the language in the config file" 'grep -q "^UI_LANG=en$" "$FIX/config"'
out="$(panel L L q)"
check "L twice goes back to Spanish" 'echo "$out" | awk "/^=== frame 3/{f=1} f" | grep -q "^  Instancias$" && grep -q "^UI_LANG=es$" "$FIX/config"'
unset DELTACTL_CONFIG
out="$(panel timeout timeout q)"
check "the periodic refresh redraws the panel" '[ "$(echo "$out" | frames)" -eq 3 ]'
check "keys that do nothing just redraw" 'out="$(panel x y q)"; [ "$(echo "$out" | frames)" -eq 3 ]'

section "7. without a terminal the panel is not used"
check "tui_interactive is false in a pipe and true in test mode" '! ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/ui/tui.sh; tui_interactive" < /dev/null && DELTACTL_TUI_KEYS=/dev/null ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/ui/tui.sh; tui_interactive"'
check "the menu keeps the numbered menu when it is not a terminal" 'printf "0\n" | DELTACTL_UI=plain bash ./deltactl menu 2>&1 | grep -q "1) Ver estado"'
check "menu --classic forces the numbered menu even in the panel test mode" 'printf "0\n" > "$FIX/k0"; printf "0\n" | DELTACTL_TUI_KEYS="$FIX/k0" DELTACTL_UI=plain bash ./deltactl menu --classic 2>&1 | grep -q "1) Ver estado"'
check "menu in the panel test mode opens the panel" 'printf "q\n" > "$FIX/kq"; DELTACTL_TUI_KEYS="$FIX/kq" DELTACTL_UI=rich bash ./deltactl menu 2>&1 | grep -q "^=== frame 1 ==="'
check "menu still rejects other arguments" 'DELTACTL_LANG=es bash ./deltactl menu extra 2>&1 | grep -q "^ERROR menu no recibe argumentos"'
check "the static home screen is used when the terminal is not interactive" 'DELTACTL_UI=rich DELTACTL_COLOR=never bash ./deltactl 2>&1 < /dev/null | grep -q "^Estado de las instancias"'

section "8. terminal layer"
tk() { # bytes -> TUI_KEY (reads from stdin as a terminal would deliver them)
  ROOT="$PWD" bash -c 'source lib/bootstrap.sh; source lib/ui/tui.sh; tui_key; printf "%s" "$TUI_KEY"'
}
check "tui_key reads the arrow keys" '[ "$(printf "\033[A" | tk)" = "up" ] && [ "$(printf "\033[B" | tk)" = "down" ] && [ "$(printf "\033[C" | tk)" = "right" ] && [ "$(printf "\033[D" | tk)" = "left" ]'
check "tui_key reads the application-mode arrows too" '[ "$(printf "\033OA" | tk)" = "up" ] && [ "$(printf "\033OB" | tk)" = "down" ]'
check "tui_key reads Enter, Tab, Backspace and Escape" '[ "$(printf "\n" | tk)" = "enter" ] && [ "$(printf "\t" | tk)" = "tab" ] && [ "$(printf "\177" | tk)" = "backspace" ] && [ "$(printf "\033" | tk)" = "esc" ]'
check "tui_key returns the typed character" '[ "$(printf "j" | tk)" = "j" ] && [ "$(printf "L" | tk)" = "L" ] && [ "$(printf "?" | tk)" = "?" ]'
check "tui_key treats the end of input as q" '[ "$(tk < /dev/null)" = "q" ]'
check "tui_key times out" '[ "$( (sleep 2) | ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/ui/tui.sh; tui_key 0.2; printf \"%s\" \"\$TUI_KEY\"")" = "timeout" ]'
check "tui_draw homes the cursor and clears line ends and the rest of the screen" 'out="$(ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/ui/tui.sh; TUI_FRAME=(one two); tui_draw" | od -c | tr -d " \n")"; echo "$out" | grep -q "033\[H" && echo "$out" | grep -q "033\[K" && echo "$out" | grep -q "033\[J"'
check "tui_enter and tui_leave switch the alternate screen once each" 'out="$(ROOT="$PWD" bash -c "source lib/bootstrap.sh; source lib/ui/tui.sh; tui_enter; tui_enter; tui_leave; tui_leave" | od -c | tr -d " \n")"; [ "$(echo "$out" | grep -o "033\[?1049h" | wc -l)" -eq 1 ] && [ "$(echo "$out" | grep -o "033\[?1049l" | wc -l)" -eq 1 ]'

finish

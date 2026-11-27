#!/usr/bin/env bash
# `docker` simulado y determinista para los tests: no necesita Docker real y nunca levanta nada.
# Se copia a "$FIX/bin/docker" (ver tests/test-guided.sh y tests/test-menu.sh). Entiende solo lo que usa deltactl:
#   info, network inspect, ps, image ls/inspect, load, run (prueba de Mongo) y compose (version, config, up/pull/...).
# Estado simulado en $FIX: images.txt (ref|id|arquitectura), calls.log (lo que se intentó ejecutar),
# y los archivos compose_invalid y mongo_fail que fuerzan errores. Opcionales: image_dates.txt (referencia|fecha de creación), server_arch (la
# arquitectura del servidor), daemon_down (el demonio no responde), log_all (anota cada llamada en all_calls.log) y load_result/load_date/load_arch (lo que `docker load` imprime y carga).
[ ! -f "$FIX/log_all" ] || echo "$*" >> "$FIX/all_calls.log"   # $FIX/log_all (optional): every call is noted in all_calls.log (what was asked of Docker)
case "$1" in
  info)
    [ ! -f "$FIX/daemon_down" ] || exit 1   # $FIX/daemon_down (optional): the daemon does not answer
    case "$*" in
      *Architecture*) cat "$FIX/server_arch" 2> /dev/null || echo x86_64 ;;   # $FIX/server_arch (optional): the architecture of the server
      *ServerVersion*) echo 27.0.0 ;;
      *DockerRootDir*) echo "" ;;
    esac
    exit 0 ;;
  network)
    # `network ls`: $FIX/networks.txt (optional), one name per line. Any other network command answers the gateway of the bridge.
    if [ "${2:-}" = ls ]; then cat "$FIX/networks.txt" 2> /dev/null; exit 0; fi
    cat "$FIX/gateway" 2> /dev/null || echo 127.0.0.1   # ($FIX/gateway: the address of the bridge, for the tests of mongo setup)
    exit 0 ;;
  ps)
    # `ps -a --format '{{.Image}}'`: the image of every container of containers.txt (project|service|state|health|image|...), one per line.
    case "$*" in *'{{.Image}}'*) cut -d'|' -f5 "$FIX/containers.txt" 2> /dev/null; exit 0 ;; esac
    # `ps -a --format ...com.docker.compose.project...`: the project of every row of containers.txt, one per line.
    case "$*" in *'--format'*'com.docker.compose.project'*) cut -d'|' -f1 "$FIX/containers.txt" 2> /dev/null; exit 0 ;; esac
    # $FIX/containers.txt (optional): project|service|state|health|image|started|name|pid|restarts, one per container.
    # `ps` prints the line numbers of the rows of the project named in the label filter; `inspect <ids>` prints those rows.
    [ -f "$FIX/containers.txt" ] || exit 0
    case "$*" in
      *com.docker.compose.project=*)
        all="$*"; p="${all#*com.docker.compose.project=}"; p="${p%% *}"   # (${*#...} would trim each argument separately)
        awk -F'|' -v p="$p" '$1 == p { print NR }' "$FIX/containers.txt" ;;
    esac
    exit 0 ;;
  inspect)
    [ -f "$FIX/containers.txt" ] || exit 1
    for id in "${@:4}"; do sed -n "${id}p" "$FIX/containers.txt"; done
    exit 0 ;;
  image)
    case "$2" in
      ls)
        # The size is 300MB unless $FIX/image_sizes.txt (ref|size, optional) says another.
        # repo|tag|id|created|size|created_at. The date comes from $FIX/image_dates.txt (ref|date, optional); without it the field is empty.
        awk -F'|' -v dates="$FIX/image_dates.txt" -v sizes="$FIX/image_sizes.txt" '
          BEGIN { while ((getline l < dates) > 0) { split(l, d, "|"); at[d[1]] = d[2] } while ((getline l < sizes) > 0) { split(l, z, "|"); sz[z[1]] = z[2] } }
          { split($1, r, ":"); printf "%s|%s|%s|1 hour ago|%s|%s\n", r[1], r[2], $2, ($1 in sz ? sz[$1] : "300MB"), at[$1] }' "$FIX/images.txt" ;;
      inspect)
        # Any number of references (or ids) after the options; --format decides what each one prints: id|architecture, the architecture or the id.
        shift 2
        fmt="" refs=() rc=0
        while [ "$#" -gt 0 ]; do
          case "$1" in --format) fmt="$2"; shift 2 ;; *) refs+=("$1"); shift ;; esac
        done
        for ref in "${refs[@]}"; do
          line="$(grep -F "$ref|" "$FIX/images.txt" | head -n1)"
          if [ -z "$line" ]; then rc=1; continue; fi
          id="$(echo "$line" | cut -d'|' -f2)" arch="$(echo "$line" | cut -d'|' -f3)"
          case "$fmt" in
            *Architecture*"{{.Id}}"* | *"{{.Id}}"*Architecture*) echo "$id|$arch" ;;
            *Architecture*) echo "$arch" ;;
            *"{{.Id}}"*) echo "$id" ;;
          esac
        done
        [ "$rc" -eq 0 ] || exit 1 ;;
    esac
    exit 0 ;;
  rmi)
    # `docker rmi <ref>`: logs "rmi <ref>" in calls.log. Like the real one it refuses an image a container uses (the 5th field of containers.txt), and
    # $FIX/rmi_fail (optional) makes it refuse everything. Otherwise the reference leaves images.txt and answers "Untagged: <ref>".
    echo "rmi $2" >> "$FIX/calls.log"
    if [ -f "$FIX/rmi_fail" ]; then echo "Error response from daemon: simulated failure" >&2; exit 1; fi
    if cut -d'|' -f5 "$FIX/containers.txt" 2> /dev/null | grep -qxF "$2"; then
      echo "Error response from daemon: conflict: unable to remove repository reference \"$2\" (must force) - container abc123 is using its referenced image def456" >&2
      exit 1
    fi
    grep -qF "$2|" "$FIX/images.txt" 2> /dev/null || { echo "Error response from daemon: No such image: $2" >&2; exit 1; }
    grep -vF "$2|" "$FIX/images.txt" > "$FIX/images.txt.new"; mv -f "$FIX/images.txt.new" "$FIX/images.txt"
    echo "Untagged: $2"
    exit 0 ;;
  load)
    # `docker load -i <file>` (or reading stdin): prints what $FIX/load_result says ("Loaded image: ref" lines, one per image) and adds those
    # images to images.txt, dated $FIX/load_date (or now). Without $FIX/load_result it loads nothing, as an archive with no images does.
    echo "$*" >> "$FIX/calls.log"   # (so the line is "load -i <file>")
    [ -f "$FIX/load_result" ] || exit 0
    cat "$FIX/load_result"
    sed -n 's/^Loaded image: //p' "$FIX/load_result" | while IFS= read -r ref; do
      printf '%s|sha256:%s|%s\n' "$ref" "$(printf '%s' "$ref" | cksum | cut -d' ' -f1)abcdef000000" "$(cat "$FIX/load_arch" 2> /dev/null || echo amd64)" >> "$FIX/images.txt"
      printf '%s|%s\n' "$ref" "$(cat "$FIX/load_date" 2> /dev/null || date -u '+%Y-%m-%d %H:%M:%S +0000 UTC')" >> "$FIX/image_dates.txt"
    done
    exit 0 ;;
  run)
    echo "run $*" >> "$FIX/calls.log"
    case "$*" in
      *usersInfo*)
        # init creates the Mongo user of the instance: $FIX/mongouser_fail makes it fail, $FIX/mongouser_exists says it is there already
        if [ -f "$FIX/mongouser_fail" ]; then echo "ERR=auth de prueba"; elif [ -f "$FIX/mongouser_exists" ]; then echo "EXISTS=u"; else echo "CREATED=u"; fi
        exit 0 ;;
      *countDocuments*)
        # init's document count: the collection is the last argument; the value comes from $FIX/count_<collection> (0 by default)
        if [ -f "$FIX/mongo_fail" ]; then echo "ERR=timeout de prueba"; else echo "COUNT=$(cat "$FIX/count_${*: -1}" 2>/dev/null || echo 0)"; fi
        exit 0 ;;
      *dist/cli.js*)
        # A seed of the image's CLI. $FIX/seed_out_<command> replaces its output, $FIX/seed_rc_<command> sets its exit code
        # (real seeds exit 0 even when they fail), $FIX/seed_slow_<command> holds the seconds it takes before it writes anything
        # (to have a seed to kill), and $FIX/no_users_after keeps the user collections empty.
        all="$*"; cmd="${all#*dist/cli.js }"; cmd="${cmd%% *}"   # (${*#...} would trim each argument separately)
        if [ -f "$FIX/seed_slow_$cmd" ]; then sleep "$(cat "$FIX/seed_slow_$cmd")"; fi
        if [ -f "$FIX/seed_out_$cmd" ]; then
          cat "$FIX/seed_out_$cmd"
        else
          case "$cmd" in
            populating_data_s1) for i in $(seq 30); do echo "catalog $i populated"; done ;;
            populating_data_s0)
              for i in $(seq 17); do echo "table $i populated"; done
              [ -f "$FIX/no_users_after" ] || { echo 4 > "$FIX/count_usuarios"; echo 4 > "$FIX/count_users"; } ;;
            create_root_user) echo "Root user created" ;;
            url_systems) echo "Url of server has created successfully" ;;
          esac
        fi
        exit "$(cat "$FIX/seed_rc_$cmd" 2>/dev/null || echo 0)" ;;
    esac
    if [ -f "$FIX/mongo_fail" ]; then echo "ERR=timeout de prueba"; else echo "OK=basedeprueba"; fi
    exit 0 ;;
  compose)
    shift
    envf=""; prof=""; cfg=0; quiet=0; imgs=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --env-file) envf="$2"; shift 2 ;;
        --profile) prof="$2"; shift 2 ;;
        version) case "$*" in *--short*) echo v2.30.0 ;; *) echo "Docker Compose version v2.30.0" ;; esac; exit 0 ;;
        config) cfg=1; shift ;;
        -q) quiet=1; shift ;;
        --images) imgs=1; shift ;;
        up | pull | ps | stop | down | logs)
          echo "COMPOSE $1" >> "$FIX/calls.log"
          # $FIX/hook_<command> is a script that runs while that command is running (to change a file in the middle of a deploy)
          if [ -f "$FIX/hook_$1" ]; then bash "$FIX/hook_$1" > /dev/null 2>&1 || true; fi
          # $FIX/slow_<command> holds the seconds that command takes (to have a real operation to cancel or kill)
          if [ -f "$FIX/slow_$1" ]; then sleep "$(cat "$FIX/slow_$1")"; fi
          # $FIX/fail_<command> holds the exit code that command must return (for example fail_pull=23)
          if [ -f "$FIX/fail_$1" ]; then exit "$(cat "$FIX/fail_$1")"; fi
          exit 0 ;;
        *) shift ;;
      esac
    done
    if [ "$cfg" -eq 1 ]; then
      if [ -f "$FIX/compose_invalid" ]; then echo "services.s0 invalido de prueba" >&2; exit 1; fi
      if [ "$imgs" -eq 1 ]; then
        get() { grep -E "^$1=" "$envf" | tail -n1 | cut -d= -f2-; }
        u="${prof^^}"; reg="$(get REGISTRY)"
        echo "${reg:+$reg/}$(get "${u}_IMAGE"):$(get "${u}_TAG")"
      fi
    fi
    exit 0 ;;
esac
exit 0

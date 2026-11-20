#!/usr/bin/env bash
# `docker` simulado y determinista para los tests: no necesita Docker real y nunca levanta nada.
# Se copia a "$FIX/bin/docker" (ver tests/test-guided.sh y tests/test-menu.sh). Entiende solo lo que usa deltactl:
#   info, network inspect, ps, image ls/inspect, run (prueba de Mongo) y compose (version, config, up/pull/...).
# Estado simulado en $FIX: images.txt (ref|id|arquitectura), calls.log (lo que se intentó ejecutar),
# y los archivos compose_invalid y mongo_fail que fuerzan errores.
case "$1" in
  info)
    case "$*" in
      *Architecture*) echo x86_64 ;;
      *ServerVersion*) echo 27.0.0 ;;
      *DockerRootDir*) echo "" ;;
    esac
    exit 0 ;;
  network) echo 127.0.0.1; exit 0 ;;
  ps)
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
      ls) awk -F'|' '{ split($1, r, ":"); printf "%s|%s|%s|1 hour ago|300MB\n", r[1], r[2], $2 }' "$FIX/images.txt" ;;
      inspect)
        ref="${*: -1}"
        line="$(grep -F "$ref|" "$FIX/images.txt" | head -n1)"
        [ -n "$line" ] || exit 1
        case "$*" in
          *Architecture*) echo "$(echo "$line" | cut -d'|' -f3)" ;;
          *"{{.Id}}"*) echo "$(echo "$line" | cut -d'|' -f2)" ;;
        esac ;;
    esac
    exit 0 ;;
  run)
    echo "run $*" >> "$FIX/calls.log"
    case "$*" in
      *countDocuments*)
        # init's document count: the collection is the last argument; the value comes from $FIX/count_<collection> (0 by default)
        if [ -f "$FIX/mongo_fail" ]; then echo "ERR=timeout de prueba"; else echo "COUNT=$(cat "$FIX/count_${*: -1}" 2>/dev/null || echo 0)"; fi
        exit 0 ;;
      *dist/cli.js*)
        # A seed of the image's CLI. $FIX/seed_out_<command> replaces its output, $FIX/seed_rc_<command> sets its exit code
        # (real seeds exit 0 even when they fail), and $FIX/no_users_after keeps the user collections empty.
        all="$*"; cmd="${all#*dist/cli.js }"; cmd="${cmd%% *}"   # (${*#...} would trim each argument separately)
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

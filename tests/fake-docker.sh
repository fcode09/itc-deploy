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
  ps) exit 0 ;;
  image)
    case "$2" in
      ls) awk -F'[:|]' '{ printf "%s|%s|%s|1 hour ago|300MB\n", $1, $2, $3 }' "$FIX/images.txt" ;;
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
        up | pull | ps | stop | down | logs) echo "COMPOSE $1" >> "$FIX/calls.log"; exit 0 ;;
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

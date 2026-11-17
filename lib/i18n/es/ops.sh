#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_es is read by t through a nameref
# ops messages: Spanish. Sourced by lib/i18n/i18n.sh; not executed.

MSG_es["ops.stop_usage"]="uso: ./deltactl stop <instancia> <servicio>  (para detener todo: ./deltactl down {1})"
MSG_es["ops.stopped"]="{1} detenido en '{2}'"
MSG_es["ops.down_info"]="Detiene y elimina los contenedores de '{1}'. Los datos (data/) y secretos se conservan."
MSG_es["ops.down_done"]="instancia '{1}' detenida"

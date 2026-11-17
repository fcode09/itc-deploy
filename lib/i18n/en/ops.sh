#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_en is read by t through a nameref
# ops messages: English. Sourced by lib/i18n/i18n.sh; not executed.

MSG_en["ops.stop_usage"]="usage: ./deltactl stop <instance> <service>  (to stop everything: ./deltactl down {1})"
MSG_en["ops.stopped"]="{1} stopped in '{2}'"
MSG_en["ops.down_info"]="Stops and removes the containers of '{1}'. The data (data/) and secrets are kept."
MSG_en["ops.down_done"]="instance '{1}' stopped"

#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_en is read by t through a nameref
# list messages: English. Sourced by lib/i18n/i18n.sh; not executed.

MSG_en["list.col.instance"]="INSTANCE"
MSG_en["list.col.services"]="SERVICES"
MSG_en["list.col.data"]="DATA"
MSG_en["list.col.state"]="STATE"
MSG_en["list.docker_unavailable"]="(docker not available)"
MSG_en["list.up"]="up ({1} containers)"
MSG_en["list.stopped"]="stopped"
MSG_en["list.none"]="(no instances; create one with ./deltactl new <instance>)"

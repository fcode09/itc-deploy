#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_en is read by t through a nameref
# secret messages (the files of secrets/): English. Sourced by lib/i18n/i18n.sh; not executed.

MSG_en["secret.usage"]="usage: ./deltactl secret list|check <instance>   ./deltactl secret add <instance> <variable|file> <path> [--force]  (help: ./deltactl help secret)"
MSG_en["secret.unknown_sub"]="'secret {1}' does not exist. Use: list, check or add."
MSG_en["secret.no_instance"]="the instance '{1}' does not exist"
MSG_en["secret.none"]="'{1}' needs no files in secrets/ (no variable of its services points to /run/secrets/...)"
MSG_en["secret.title"]="Files of secrets/ of '{1}'"
MSG_en["secret.state_ok"]="loaded"
MSG_en["secret.state_missing"]="missing: it is not in secrets/ yet"
MSG_en["secret.how_add"]="Load it with: ./deltactl secret add {1} <variable|file> <path of the file on this server>"
MSG_en["secret.unknown_target"]="'{1}' is not a file that '{2}' needs. It needs: {3}"
MSG_en["secret.exists"]="secrets/{1} already exists: use --force to replace it"
MSG_en["secret.same"]="secrets/{1} is already that very file"
MSG_en["secret.copy_failed"]="the file could not be copied to secrets/{1}"
MSG_en["secret.added"]="secrets/{1} loaded into '{2}' (mode 600)"
MSG_en["secret.next_deploy"]="For the service to use it: ./deltactl deploy {1}"
MSG_en["secret.err_missing"]="{1} does not exist"
MSG_en["secret.err_notfile"]="{1} is not a file"
MSG_en["secret.err_unreadable"]="{1} cannot be read"
MSG_en["secret.err_empty"]="{1} is empty"
MSG_en["secret.err_toobig"]="{1} is too big for a service account (up to 128 KiB)"
MSG_en["secret.err_notjson"]="{1} is not a JSON object (its content is not shown)"

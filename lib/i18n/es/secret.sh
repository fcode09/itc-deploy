#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_es is read by t through a nameref
# secret messages (the files of secrets/): Spanish. Sourced by lib/i18n/i18n.sh; not executed.

MSG_es["secret.usage"]="uso: ./deltactl secret list|check <instancia>   ./deltactl secret add <instancia> <variable|archivo> <ruta> [--force]  (ayuda: ./deltactl help secret)"
MSG_es["secret.unknown_sub"]="'secret {1}' no existe. Usa: list, check o add."
MSG_es["secret.no_instance"]="la instancia '{1}' no existe"
MSG_es["secret.none"]="'{1}' no necesita archivos en secrets/ (ninguna variable de sus servicios apunta a /run/secrets/...)"
MSG_es["secret.title"]="Archivos de secrets/ de '{1}'"
MSG_es["secret.state_ok"]="cargado"
MSG_es["secret.state_missing"]="falta: aún no está en secrets/"
MSG_es["secret.how_add"]="Cárgalo con: ./deltactl secret add {1} <variable|archivo> <ruta del archivo en este servidor>"
MSG_es["secret.unknown_target"]="'{1}' no es un archivo que '{2}' necesite. Necesita: {3}"
MSG_es["secret.exists"]="secrets/{1} ya existe: usa --force para reemplazarlo"
MSG_es["secret.same"]="secrets/{1} ya es ese mismo archivo"
MSG_es["secret.copy_failed"]="no se pudo copiar el archivo a secrets/{1}"
MSG_es["secret.added"]="secrets/{1} cargado en '{2}' (permisos 600)"
MSG_es["secret.next_deploy"]="Para que el servicio lo use: ./deltactl deploy {1}"
MSG_es["secret.err_missing"]="{1} no existe"
MSG_es["secret.err_notfile"]="{1} no es un archivo"
MSG_es["secret.err_unreadable"]="{1} no se puede leer"
MSG_es["secret.err_empty"]="{1} está vacío"
MSG_es["secret.err_toobig"]="{1} es demasiado grande para una cuenta de servicio (hasta 128 KiB)"
MSG_es["secret.err_notjson"]="{1} no es un objeto JSON (su contenido no se muestra)"

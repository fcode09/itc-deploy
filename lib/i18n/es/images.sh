#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_es is read by t through a nameref
# images messages: Spanish. Sourced by lib/i18n/i18n.sh; not executed.

MSG_es["images.unknown_option"]="opción desconocida: {1} (ver ./deltactl help images)"
MSG_es["images.extra_arg"]="sobra el argumento '{1}'"
MSG_es["images.title"]="Imágenes de este servidor"
MSG_es["images.server_arch"]="Arquitectura de este servidor: {1}"
MSG_es["images.col.tag"]="ETIQUETA"
MSG_es["images.col.id"]="ID"
MSG_es["images.col.arch"]="ARQ"
MSG_es["images.col.created"]="CREADA"
MSG_es["images.col.size"]="TAMAÑO"
MSG_es["images.col.used_by"]="USADA_POR"
MSG_es["images.use_current"]="actual"
MSG_es["images.use_previous"]="previa"
MSG_es["images.unused"]="sin uso (candidata a borrar)"
MSG_es["images.none_loaded"]="  (sin imágenes cargadas; cárgalas con ./deltactl load <archivo>)"
MSG_es["images.note_unused"]="Las versiones 'sin uso' no las usa ninguna instancia (ni como actual ni como previa)."
MSG_es["images.note_listing"]="Este comando solo lista: borrar imágenes lo decides tú. Evita 'docker image prune -a'."
MSG_es["images.hint_delete"]="{1} de {2} imagen(es) sin uso. Para borrar una concreta: docker image rm <nombre>:<etiqueta>"

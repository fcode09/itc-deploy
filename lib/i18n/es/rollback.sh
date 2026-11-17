#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_es is read by t through a nameref
# rollback messages: Spanish. Sourced by lib/i18n/i18n.sh; not executed.

MSG_es["rollback.instance"]="Instancia: {1}"
MSG_es["rollback.no_prev_tag"]="no hay una etiqueta previa registrada para {1} en '{2}'"
MSG_es["rollback.prev_missing"]="la imagen previa {1} ({2}) ya no está en este servidor (¿se borró?)"
MSG_es["rollback.prev_changed"]="{1}: la etiqueta {2} ahora apunta a otra imagen ({3}) distinta de la que estaba desplegada ({4})"
MSG_es["rollback.missing_images"]="faltan imágenes previas en este servidor: no se cambió nada. Revisa ./deltactl images"
MSG_es["rollback.nothing"]="no hay nada que revertir en '{1}'"
MSG_es["rollback.confirm"]="¿Volver a estas etiquetas?"
MSG_es["rollback.not_healthy"]="el rollback de '{1}' no llegó a healthy"
MSG_es["rollback.done"]="rollback de '{1}' completado ({2})"

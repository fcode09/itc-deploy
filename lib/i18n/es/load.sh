#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_es is read by t through a nameref
# load messages: Spanish. Sourced by lib/i18n/i18n.sh; not executed.

MSG_es["load.usage"]="uso: ./deltactl load <archivo.tar|archivo.tar.gz>"
MSG_es["load.no_file"]="no existe el archivo: {1}"
MSG_es["load.loading"]="Cargando {1} ..."
MSG_es["load.failed"]="no se pudo cargar {1}"
MSG_es["load.no_images"]="el archivo no contiene imágenes con nombre (¿es un archivo de docker save?)"
MSG_es["load.loaded_title"]="Imágenes cargadas:"
MSG_es["load.done"]="{1} imagen(es) disponibles. Usa estas etiquetas en S0_TAG / S1_TAG y revisa con ./deltactl images"

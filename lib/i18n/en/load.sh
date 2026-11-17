#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_en is read by t through a nameref
# load messages: English. Sourced by lib/i18n/i18n.sh; not executed.

MSG_en["load.usage"]="usage: ./deltactl load <file.tar|file.tar.gz>"
MSG_en["load.no_file"]="the file does not exist: {1}"
MSG_en["load.loading"]="Loading {1} ..."
MSG_en["load.failed"]="could not load {1}"
MSG_en["load.no_images"]="the file contains no named images (is it a docker save archive?)"
MSG_en["load.loaded_title"]="Loaded images:"
MSG_en["load.done"]="{1} image(s) available. Use these tags in S0_TAG / S1_TAG and check with ./deltactl images"

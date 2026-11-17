#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_en is read by t through a nameref
# images messages: English. Sourced by lib/i18n/i18n.sh; not executed.

MSG_en["images.unknown_option"]="unknown option: {1} (see ./deltactl help images)"
MSG_en["images.extra_arg"]="unexpected argument '{1}'"
MSG_en["images.title"]="Images on this server"
MSG_en["images.server_arch"]="Architecture of this server: {1}"
MSG_en["images.col.tag"]="TAG"
MSG_en["images.col.id"]="ID"
MSG_en["images.col.arch"]="ARCH"
MSG_en["images.col.created"]="CREATED"
MSG_en["images.col.size"]="SIZE"
MSG_en["images.col.used_by"]="USED_BY"
MSG_en["images.use_current"]="current"
MSG_en["images.use_previous"]="previous"
MSG_en["images.unused"]="unused (candidate for deletion)"
MSG_en["images.none_loaded"]="  (no images loaded; load them with ./deltactl load <file>)"
MSG_en["images.note_unused"]="The 'unused' versions are not used by any instance (neither as current nor as previous)."
MSG_en["images.note_listing"]="This command only lists: deleting images is up to you. Avoid 'docker image prune -a'."
MSG_en["images.hint_delete"]="{1} of {2} image(s) unused. To delete a specific one: docker image rm <name>:<tag>"

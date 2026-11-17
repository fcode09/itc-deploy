#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_en is read by t through a nameref
# rollback messages: English. Sourced by lib/i18n/i18n.sh; not executed.

MSG_en["rollback.instance"]="Instance: {1}"
MSG_en["rollback.no_prev_tag"]="no previous tag recorded for {1} in '{2}'"
MSG_en["rollback.prev_missing"]="the previous image {1} ({2}) is no longer on this server (was it deleted?)"
MSG_en["rollback.prev_changed"]="{1}: tag {2} now points to another image ({3}) different from the one that was deployed ({4})"
MSG_en["rollback.missing_images"]="previous images are missing on this server: nothing was changed. Check ./deltactl images"
MSG_en["rollback.nothing"]="nothing to roll back in '{1}'"
MSG_en["rollback.confirm"]="Go back to these tags?"
MSG_en["rollback.not_healthy"]="the rollback of '{1}' did not reach healthy"
MSG_en["rollback.done"]="rollback of '{1}' completed ({2})"

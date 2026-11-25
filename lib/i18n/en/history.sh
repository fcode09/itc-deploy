#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_en is read by t through a nameref
# The History tab of the workspace of an instance (lib/screens/ws/historial.sh): English.
# Loaded by lib/i18n/i18n.sh; not executed.

MSG_en["tui.ws.tab.historial"]="History"
MSG_en["tui.his.count"]="{1} operations"
MSG_en["tui.his.empty"]="This instance has no recorded operations yet. The ones that change something (deploy, init, adopt, rollback, stop, down) stay here with their output and what they consumed."
MSG_en["tui.his.summary"]="What it printed (summary)"
MSG_en["tui.his.foot.open"]="{Enter} whole output"
MSG_en["tui.his.foot.scroll"]="^PgUp ^PgDn scroll"
MSG_en["tui.his.keys"]="{1} operation · Enter the whole output · PgUp/PgDn scroll the detail · z zoom · {2} back · ? help · q quit"

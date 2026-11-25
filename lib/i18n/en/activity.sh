#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_en is read by t through a nameref
# The Activity view of the panel (lib/screens/activity.sh): English. It absorbs Output, Runs and Processes.
# Loaded by lib/i18n/i18n.sh; not run.

MSG_en["tui.tab.activity"]="Activity"
MSG_en["tui.act.title"]="Activity"
MSG_en["tui.act.tab.resumen"]="Summary"
MSG_en["tui.act.tab.salida"]="Output"
MSG_en["tui.act.tab.consumo"]="Usage"
MSG_en["tui.act.tab.procesos"]="Processes"
MSG_en["tui.act.panel"]="this panel"
MSG_en["tui.act.panel_note"]="The last command of this panel. Commands that only read are not kept in the history: this is where they show."
MSG_en["tui.act.job.running"]="running"
MSG_en["tui.act.job.ok"]="succeeded"
MSG_en["tui.act.job.failed"]="failed"
MSG_en["tui.act.job.cancelled"]="cancelled"
MSG_en["tui.act.live_cost"]="What it uses now"
MSG_en["tui.act.job_nousage"]="This command is not kept in the history, so it has no recorded usage. While it runs, the Processes tab shows what it is made of and what it uses."
MSG_en["tui.act.no_usage"]="This run was saved before usage was measured: there are no figures to show."
MSG_en["tui.act.no_output"]="This operation saved no output."
MSG_en["tui.act.empty"]="No activity yet. When you run something (deploy, check, bring down…), or another terminal does, you will see here what it was, how it ended, its output, what it used and the processes it is made of."
MSG_en["tui.act.moved"]="Output, Runs and Processes now live in Activity (key 0). These views stay for a while, but they will not get anything new."
MSG_en["tui.keys.act_resumen"]="{1} choose · ← → tab · PgUp/PgDn detail · Enter output · t usage · : command · ? help · q quit"
MSG_en["tui.keys.act_salida"]="{1} choose · ← → tab · PgUp/PgDn Home/End scroll · f follow · v summary/raw · e errors · x cancel · ? help · q quit"
MSG_en["tui.keys.act_consumo"]="{1} choose · ← → tab · PgUp/PgDn detail · t statistics · : command · ? help · q quit"
MSG_en["tui.keys.act_procesos"]="{1} choose · ← → tab · PgUp/PgDn Home scroll the tree · x cancel the command · ? help · q quit"
MSG_en["tui.keys.act_stats"]="s one instance / all · t or Esc go back · : command · ? help · q quit"

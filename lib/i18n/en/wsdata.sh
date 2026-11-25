#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_en is read by t through a nameref
# The Variables and Data tabs of the workspace (lib/screens/ws/variables.sh and datos.sh): English.
# Sourced by lib/i18n/i18n.sh; not executed.

MSG_en["tui.ws.tab.variables"]="Variables"
MSG_en["tui.ws.tab.datos"]="Data"
MSG_en["tui.wsd.state"]="Data"
MSG_en["tui.wsd.marker"]="Marker"
MSG_en["tui.wsd.no_marker"]="none: the instance was not seeded (I) or adopted (A) yet"
MSG_en["tui.wsd.folders"]="data/ folders"
MSG_en["tui.wsd.logs"]="Seed records (init-logs/)"
MSG_en["tui.wsd.no_logs"]="none yet"
MSG_en["tui.wsd.hint.unseeded"]="This instance's databases are not seeded. I seeds them (it asks to type the name of the instance); if it already had data, A marks it as existing without touching it."
MSG_en["tui.wsd.hint.done"]="The marker prevents seeding twice. No operation of the panel touches the data in data/."
MSG_en["tui.wsd.foot.init"]="^I seed"
MSG_en["tui.wsd.foot.adopt"]="^A adopt"
MSG_en["tui.wsd.keys"]="I seed · A adopt (mark as existing) · < > tab · {1} list · ? help"
MSG_en["tui.wsd.already"]="'{1}' already has its .initialized marker: it is not seeded or adopted again"
MSG_en["tui.wsd.confirm_adopt"]="Marks '{1}' as an instance that already had data (it creates the .initialized marker, seeds nothing). Continue?"
MSG_en["tui.wsv.dirty"]="There are unsaved changes in '{1}': save them (s) or discard them in its Variables tab before seeing the variables of '{2}'."

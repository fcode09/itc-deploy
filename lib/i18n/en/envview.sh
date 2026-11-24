#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_en is read by t through a nameref
# The Variables view of the panel (lib/screens/env.sh) and the variables editor of the kit (lib/ui/kit/env_editor.sh): English.
# Loaded by lib/i18n/i18n.sh; never executed. No text repeats the value of a variable: it may be a secret.

MSG_en["tui.tab.env"]="Variables"
MSG_en["tui.keys.env"]="{1} move · Enter edits · 1-9 views · : command · ? help · q quit"
MSG_en["tui.help.head.env"]="VARIABLES"
MSG_en["tui.env.title"]="variables"
MSG_en["tui.env.none"]="There are no instances: create one with n and come back."
MSG_en["tui.env.switch_dirty"]="There are unsaved changes in {1}: save them (s) or discard them (Esc) before changing instance"

# A row: what the state of the variable says
MSG_en["envview.note.required"]="required"
MSG_en["envview.note.example"]="to fill in"
MSG_en["envview.note.changed"]="changed"
MSG_en["envview.note.optional"]="optional"
MSG_en["envview.default_is"]="default: {1}"
MSG_en["envview.empty"]="(empty)"
MSG_en["envview.empty_list"]="This instance has no variables files."
MSG_en["envview.file_todo"]="{1} variables · {2} to fill in"
MSG_en["envview.file_all"]="{1} variables"
MSG_en["envview.file_pending"]="not deployed"

# The card of what is under the cursor
MSG_en["envview.type.req"]="Required"
MSG_en["envview.type.opt"]="Optional"
MSG_en["envview.type.secret"]="secret"
MSG_en["envview.card.default"]="Default: {1}"
MSG_en["envview.card.example"]="Example: {1}"
MSG_en["envview.card.gen"]="g generates a new value."
MSG_en["envview.card.missing"]="Required: without it the deploy is refused."
MSG_en["envview.card.example_left"]="It still has the template's example value: change it."
MSG_en["envview.card.state_pending"]="not deployed"
MSG_en["envview.card.state_synced"]="as at the last deploy"
MSG_en["envview.card.state_unknown"]="no deploy mark"
MSG_en["envview.card.file_pending"]="Changed since the last deploy: it is applied when you deploy (u)."
MSG_en["envview.card.file_synced"]="Nothing to deploy in this file."
MSG_en["envview.card.file_unknown"]="The mark is made when the next deploy ends; until then there is no telling what changed."
MSG_en["envview.card.hidden"]="{1} optional variables are hidden: a shows them."

# Border chips
MSG_en["envview.status.todo"]="{1} to fill in"
MSG_en["envview.status.changed"]="{1} unsaved"
MSG_en["envview.status.pending"]="{1} not deployed"
MSG_en["envview.status.ok"]="all in order"
MSG_en["envview.foot"]="{Enter} edit|^g generate|^r reveal|^d default|^a advanced|^s save|^u deploy"
MSG_en["envview.foot_edit"]="{Enter} accept|{Esc} cancel"

# Status line messages
MSG_en["envview.refused"]="{1} is not accepted: {2}"
MSG_en["envview.generated"]="{1} generated (the value is not shown): s saves"
MSG_en["envview.default_set"]="{1} takes its default value: s saves"
MSG_en["envview.no_default"]="{1} has no default value"
MSG_en["envview.not_secret"]="{1} is not a secret: its value is already visible"
MSG_en["envview.saved"]="Saved {1} variable(s) in {2}"
MSG_en["envview.nothing"]="There are no changes to save"
MSG_en["envview.save_refused"]="Nothing was saved: {1} not valid ({2})"
MSG_en["envview.adv_0"]="Advanced hidden ({1})"
MSG_en["envview.adv_1"]="Advanced shown"

# Questions
MSG_en["envview.ask.leave"]="There are unsaved changes ({1}). What do I do with them?"
MSG_en["envview.ask.deploy"]="Save the changes ({1}) and deploy {2}?"
MSG_en["envview.ask.deploy_only"]="Deploy {2} now? There are no unsaved changes."
MSG_en["envview.ask.deploy_note"]="Deploying restarts the services of the instance."

# The last line, by what the editor is doing
MSG_en["envview.keys"]="{1} move · Enter edits · g generate · r reveal · d default · a advanced · s save · u deploy · [/] instance · Esc leaves"
MSG_en["envview.keys_file"]="{1} move · Enter folds · a advanced · s save · u deploy · [/] instance · Esc leaves"
MSG_en["envview.keys_edit"]="Enter accepts · Esc cancels · ←→ move · Ctrl+U deletes · q ? : are letters here"
MSG_en["envview.keys_ask_gen"]="y replace · any other key cancels"
MSG_en["envview.keys_ask_leave"]="s save and leave · d discard and leave · any other key keeps editing"
MSG_en["envview.keys_ask_deploy"]="y confirm · any other key cancels"

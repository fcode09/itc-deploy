#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_en is read by t through a nameref
# The new-instance wizard of the panel, version 2 (lib/screens/newinst.sh and lib/screens/newinst/*.sh): English.
# Loaded by lib/i18n/i18n.sh; not executed.

MSG_en["tui.nz.title"]="new instance"
MSG_en["tui.nz.counter"]="Step {1} of {2}"
MSG_en["tui.nz.preview"]="preview"
MSG_en["tui.nz.steps"]="steps"
MSG_en["tui.nz.esc_again"]="Esc again cancels and drops what was chosen; any other key goes on."
MSG_en["tui.nz.blocked"]="It cannot be created yet: {1}"
MSG_en["tui.nz.foot.back"]="back"
MSG_en["tui.nz.foot.next"]="next"
MSG_en["tui.nz.foot.create"]="create"
MSG_en["tui.nz.foot.preview"]="preview"
MSG_en["tui.nz.foot.form"]="form"

MSG_en["tui.nz.step.name"]="Name"
MSG_en["tui.nz.step.services"]="Services"
MSG_en["tui.nz.step.versions"]="Versions"
MSG_en["tui.nz.step.data"]="Data"

MSG_en["tui.nz.help.name"]="What is the instance called? It is the name of its folder and its containers: lowercase letters, digits and hyphen; it starts with a letter."
MSG_en["tui.nz.help.services"]="Which services does it run? Each card says what it is, the port it would get on the server and the memory reserved for it."
MSG_en["tui.nz.help.versions"]="Which version of each service? The most recent one is already chosen: Enter accepts it."
MSG_en["tui.nz.help.data"]="Does the municipality start from scratch, or does it already have data (it comes from PM2 or another deployment)?"

MSG_en["tui.nz.keys.name"]="Enter next · Esc back · Tab preview"
MSG_en["tui.nz.keys.services"]="{1} move · Enter next · Space marks · a all · 1-9 step · Esc back · Tab preview"
MSG_en["tui.nz.keys.versions"]="{1} choose · Enter chooses and goes on · R reread Docker · 1-9 step · Esc back · Tab preview"
MSG_en["tui.nz.keys.data"]="{1} choose · Enter creates · Space switches · 1-9 step · Esc back · Tab preview"

MSG_en["tui.nz.pv.noname"]="name"
MSG_en["tui.nz.pv.notag"]="(the template's)"
MSG_en["tui.nz.pv.existing"]="data/ already there: the existing one"
MSG_en["tui.nz.pv.empty"]="data/ empty: init seeds it"

MSG_en["tui.nz.name.label"]="Name"
MSG_en["tui.nz.name.v_empty"]="type a name"
MSG_en["tui.nz.name.ok"]="Available: no folder, project or Docker network has that name."
MSG_en["tui.nz.name.empty"]="Type a name for the instance."
MSG_en["tui.nz.name.bad"]="Not valid: lowercase letters, digits and hyphen; it starts with a letter; 2 to 31 characters."
MSG_en["tui.nz.name.folder"]="The folder instances/{1} already exists."
MSG_en["tui.nz.name.project"]="Docker already has containers of the project {1} (an instance whose folder is gone, or another deployment on this server)."
MSG_en["tui.nz.name.network"]="Docker already has a network {1}_*: an instance with that name would collide with it on deploy."
MSG_en["tui.nz.name.where"]="It will be created in {1}"
MSG_en["tui.nz.name.nodocker"]="Docker does not answer: only the folder was checked, not the containers or the networks."
MSG_en["tui.nz.name.proposed"]="Proposed: the first free one. Type to change it."

MSG_en["tui.nz.svc.none"]="Choose at least one service."
MSG_en["tui.nz.svc.v_none"]="none"
MSG_en["tui.nz.svc.port_ok"]="port {1}"
MSG_en["tui.nz.svc.port_busy"]="port {1} in use"
MSG_en["tui.nz.svc.dep"]="Uses: {1} (if it is in the instance)"
MSG_en["tui.nz.svc.dep_missing"]="{1} uses {2}, which is not in the instance: whatever depends on it will not work."

MSG_en["tui.nz.ver.v_notag"]="no version chosen"
MSG_en["tui.nz.ver.typed_bad"]="That is not a valid tag (letters, digits, dot, hyphen and underscore)."
MSG_en["tui.nz.ver.image"]="image {1}"
MSG_en["tui.nz.ver.nodocker"]="Docker does not answer: the loaded versions cannot be seen; you can type one."

MSG_en["tui.nz.data.v_new"]="new"
MSG_en["tui.nz.data.v_existing"]="has data"
MSG_en["tui.nz.data.new"]="New: starts from scratch"
MSG_en["tui.nz.data.new_note"]="The databases stay empty and ./deltactl init seeds them the first time (administrator, municipality). Secrets are generated."
MSG_en["tui.nz.data.existing"]="Has data: it comes from another deployment"
MSG_en["tui.nz.data.existing_note"]="It uses the same databases and secrets. The instance is marked as existing: init will not be able to seed it."
MSG_en["tui.nz.data.warn"]="It is marked as existing when created; undoing that means editing the instance by hand. If unsure, choose New."

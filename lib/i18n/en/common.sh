#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_en is read by t through a nameref
# English catalog. Sourced by lib/i18n/i18n.sh with the other files of lib/i18n/en/; not executed.
# Placeholders {1}..{9} are replaced by the arguments of t. Keep every key in sync with the same area file of the other language
# (tests/test-i18n.sh fails if the key sets or the placeholders differ).

# --- Message labels ----------------------------------------------------------------------------------
MSG_en["label.ok"]="OK"
MSG_en["label.warn"]="WARN"
MSG_en["label.error"]="ERROR"

# --- Help pointers -----------------------------------------------------------------------------------
MSG_en["see.hint"]=" (help: ./deltactl help {1})"
MSG_en["topic.new-instance"]="new-instance"
MSG_en["topic.existing-instance"]="existing-instance"
MSG_en["topic.update"]="update"
MSG_en["topic.local-images"]="local-images"
MSG_en["topic.services"]="services"
MSG_en["topic.network"]="network"
MSG_en["topic.data"]="data"
MSG_en["topic.secrets"]="secrets"
MSG_en["topic.files"]="files"
MSG_en["topic.ports"]="ports"
MSG_en["topic.troubleshooting"]="troubleshooting"
MSG_en["topic.glossary"]="glossary"

# --- Entry point (deltactl) -------------------------------------------------------------------------------
MSG_en["cli.unknown_command"]="unknown command: {1}"
MSG_en["cli.try_help"]="Try: ./deltactl help      (commands and guides)   |   ./deltactl help search {1}"

# --- UI layer ----------------------------------------------------------------------------------------
MSG_en["ui.banner_subtitle"]="Deployment of instances per municipality"
MSG_en["ui.host_fallback"]="server"

# --- Common checks (lib.sh) --------------------------------------------------------------------------
MSG_en["ph.command"]="<command>"
MSG_en["err.instance_name_missing"]="missing instance name. Usage: ./deltactl {1} <instance>"
MSG_en["err.instance_name_invalid"]="invalid instance name: '{1}' (lowercase letters, digits and hyphens; must start with a letter; 2 to 31 characters)"
MSG_en["err.instance_not_found"]="instance '{1}' does not exist. Create it with: ./deltactl new {1}"

MSG_en["err.docker_missing"]="docker is not installed or not in the PATH"
MSG_en["err.docker_daemon"]="cannot talk to the Docker daemon (service stopped or missing permissions?)"
MSG_en["err.compose_missing"]="the 'docker compose' plugin is missing (v2.20 or newer is required)"
MSG_en["err.compose_old"]="Docker Compose {1} is too old: 2.20 or newer is required (for 'include')"
MSG_en["warn.arch_mismatch"]="image {1} is {2} and this server is {3}: it will not start"

MSG_en["err.profiles_empty"]=".env.instance: COMPOSE_PROFILES is empty; list the active services (e.g. s0,s1)"
MSG_en["err.profiles_unknown"]=".env.instance: COMPOSE_PROFILES contains '{1}', which is not a known service ({2})"
MSG_en["err.profiles_none"]=".env.instance: COMPOSE_PROFILES contains no services"
MSG_en["err.service_unknown"]="unknown service: '{1}' (valid: {2})"
MSG_en["err.service_inactive"]="'{1}' is not active in '{2}' (COMPOSE_PROFILES={3}); add it to .env.instance if it should run there"

MSG_en["err.confirm_needed"]="confirmation required: run interactively or add --yes"
MSG_en["prompt.confirm"]="{1} [y/N] "

# --- Shared by several commands ----------------------------------------------------------------------
MSG_en["prompt.continue"]="Continue?"
MSG_en["err.cancelled"]="cancelled"
MSG_en["data.init"]="init"
MSG_en["data.existing"]="existing"
MSG_en["data.unseeded"]="unseeded"

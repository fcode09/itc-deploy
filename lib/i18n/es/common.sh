#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_es is read by t through a nameref
# Spanish catalog (default UI language). Sourced by lib/i18n/i18n.sh with the other files of lib/i18n/es/; not executed.
# Placeholders {1}..{9} are replaced by the arguments of t. Keep every key in sync with en.sh
# (tests/test-i18n.sh fails if the key sets or the placeholders differ).

# --- Message labels ----------------------------------------------------------------------------------
MSG_es["label.ok"]="OK"
MSG_es["label.warn"]="AVISO"
MSG_es["label.error"]="ERROR"

# --- Help pointers -----------------------------------------------------------------------------------
MSG_es["see.hint"]=" (ayuda: ./deltactl help {1})"
MSG_es["topic.new-instance"]="nueva-instancia"
MSG_es["topic.existing-instance"]="instancia-existente"
MSG_es["topic.update"]="actualizar"
MSG_es["topic.local-images"]="imagenes"
MSG_es["topic.services"]="servicios"
MSG_es["topic.network"]="red"
MSG_es["topic.data"]="datos"
MSG_es["topic.secrets"]="secretos"
MSG_es["topic.files"]="archivos"
MSG_es["topic.ports"]="puertos"
MSG_es["topic.troubleshooting"]="solucion-problemas"
MSG_es["topic.glossary"]="glosario"

# --- Entry point (deltactl) -------------------------------------------------------------------------------
MSG_es["cli.unknown_command"]="comando desconocido: {1}"
MSG_es["cli.try_help"]="Prueba: ./deltactl help      (comandos y guías)   |   ./deltactl help buscar {1}"

# --- UI layer ----------------------------------------------------------------------------------------
MSG_es["ui.banner_subtitle"]="Despliegue de instancias por municipalidad"
MSG_es["ui.host_fallback"]="servidor"

# --- Common checks (lib.sh) --------------------------------------------------------------------------
MSG_es["ph.command"]="<comando>"
MSG_es["err.instance_name_missing"]="falta el nombre de la instancia. Uso: ./deltactl {1} <instancia>"
MSG_es["err.instance_name_invalid"]="nombre de instancia inválido: '{1}' (minúsculas, números y guion; empieza con letra; 2 a 31 caracteres)"
MSG_es["err.instance_not_found"]="la instancia '{1}' no existe. Créala con: ./deltactl new {1}"

MSG_es["err.docker_missing"]="docker no está instalado o no está en el PATH"
MSG_es["err.docker_daemon"]="no se puede hablar con el daemon de Docker (¿servicio detenido o sin permisos?)"
MSG_es["err.compose_missing"]="falta el plugin 'docker compose' (se necesita v2.20 o superior)"
MSG_es["err.compose_old"]="Docker Compose {1} es demasiado antiguo: se necesita 2.20 o superior (por 'include')"
MSG_es["warn.arch_mismatch"]="la imagen {1} es {2} y este servidor es {3}: no podrá arrancar"

MSG_es["err.profiles_empty"]=".env.instance: COMPOSE_PROFILES está vacío; indica los servicios activos (ej. s0,s1)"
MSG_es["err.profiles_unknown"]=".env.instance: COMPOSE_PROFILES contiene '{1}', que no es un servicio conocido ({2})"
MSG_es["err.profiles_none"]=".env.instance: COMPOSE_PROFILES no contiene servicios"
MSG_es["err.service_unknown"]="servicio desconocido: '{1}' (válidos: {2})"
MSG_es["err.service_inactive"]="'{1}' no está activo en '{2}' (COMPOSE_PROFILES={3}); añádelo a .env.instance si debe correr ahí"

MSG_es["err.confirm_needed"]="se requiere confirmación: ejecuta de forma interactiva o añade --yes"
MSG_es["prompt.confirm"]="{1} [s/N] "

# --- Shared by several commands ----------------------------------------------------------------------
MSG_es["prompt.continue"]="¿Continuar?"
MSG_es["err.cancelled"]="cancelado"
MSG_es["data.init"]="init"
MSG_es["data.existing"]="existente"
MSG_es["data.unseeded"]="sin sembrar"
MSG_es["prompt.hint_yes"]="S/n"
MSG_es["prompt.hint_no"]="s/N"

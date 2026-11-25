#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_es is read by t through a nameref
# Las pestañas Variables y Datos del espacio de trabajo (lib/screens/ws/variables.sh y datos.sh): español.
# Lo carga lib/i18n/i18n.sh; no se ejecuta.

MSG_es["tui.ws.tab.variables"]="Variables"
MSG_es["tui.ws.tab.datos"]="Datos"
MSG_es["tui.wsd.state"]="Datos"
MSG_es["tui.wsd.marker"]="Marcador"
MSG_es["tui.wsd.no_marker"]="no hay: la instancia aún no se sembró (I) ni se adoptó (A)"
MSG_es["tui.wsd.folders"]="Carpetas de data/"
MSG_es["tui.wsd.logs"]="Registros de la siembra (init-logs/)"
MSG_es["tui.wsd.no_logs"]="ninguno todavía"
MSG_es["tui.wsd.hint.unseeded"]="Las bases de esta instancia están sin sembrar. I las siembra (pide escribir el nombre de la instancia); si ya tenía datos de antes, A la marca como existente sin tocarlos."
MSG_es["tui.wsd.hint.done"]="El marcador evita sembrar dos veces. Los datos de data/ no los toca ninguna operación del panel."
MSG_es["tui.wsd.foot.init"]="^I sembrar"
MSG_es["tui.wsd.foot.adopt"]="^A adoptar"
MSG_es["tui.wsd.keys"]="I sembrar · A adoptar (marcar como existente) · < > pestaña · {1} lista · ? ayuda"
MSG_es["tui.wsd.already"]="'{1}' ya tiene su marcador .initialized: no se siembra ni se adopta otra vez"
MSG_es["tui.wsd.confirm_adopt"]="Marca '{1}' como instancia que ya tenía datos (crea el marcador .initialized sin sembrar nada). ¿Continuar?"
MSG_es["tui.wsv.dirty"]="Hay cambios sin guardar en '{1}': guárdalos (s) o descártalos en su pestaña Variables antes de ver las variables de '{2}'."

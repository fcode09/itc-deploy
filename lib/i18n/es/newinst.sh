#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_es is read by t through a nameref
# El asistente de nueva instancia del panel, versión 2 (lib/screens/newinst.sh y lib/screens/newinst/*.sh): español.
# Lo carga lib/i18n/i18n.sh; no se ejecuta.

MSG_es["tui.nz.title"]="nueva instancia"
MSG_es["tui.nz.counter"]="Paso {1} de {2}"
MSG_es["tui.nz.preview"]="vista previa"
MSG_es["tui.nz.steps"]="pasos"
MSG_es["tui.nz.esc_again"]="Esc otra vez cancela y descarta lo elegido; cualquier otra tecla sigue."
MSG_es["tui.nz.blocked"]="No se puede crear todavía: {1}"
MSG_es["tui.nz.foot.back"]="atrás"
MSG_es["tui.nz.foot.next"]="siguiente"
MSG_es["tui.nz.foot.create"]="crear"
MSG_es["tui.nz.foot.preview"]="vista previa"
MSG_es["tui.nz.foot.form"]="formulario"

MSG_es["tui.nz.step.name"]="Nombre"
MSG_es["tui.nz.step.services"]="Servicios"
MSG_es["tui.nz.step.versions"]="Versiones"
MSG_es["tui.nz.step.data"]="Datos"

MSG_es["tui.nz.help.name"]="¿Cómo se llama la instancia? Es el nombre de su carpeta y de sus contenedores: minúsculas, números y guion; empieza con letra."
MSG_es["tui.nz.help.services"]="¿Qué servicios lleva? Cada tarjeta dice qué es, el puerto que tendría en el servidor y la memoria que se le reserva."
MSG_es["tui.nz.help.versions"]="¿Qué versión de cada servicio? La más reciente ya viene elegida: Enter la acepta."
MSG_es["tui.nz.help.data"]="¿La municipalidad empieza de cero o ya tiene datos (viene de PM2 u otro despliegue)?"

MSG_es["tui.nz.keys.name"]="Enter siguiente · Esc atrás · Tab vista previa"
MSG_es["tui.nz.keys.services"]="{1} mover · Enter siguiente · Espacio marca · a todos · 1-9 paso · Esc atrás · Tab vista previa"
MSG_es["tui.nz.keys.versions"]="{1} elegir · Enter elige y sigue · R releer Docker · 1-9 paso · Esc atrás · Tab vista previa"
MSG_es["tui.nz.keys.data"]="{1} elegir · Enter crea · Espacio cambia · 1-9 paso · Esc atrás · Tab vista previa"

MSG_es["tui.nz.pv.noname"]="nombre"
MSG_es["tui.nz.pv.notag"]="(la de la plantilla)"
MSG_es["tui.nz.pv.existing"]="data/ ya existente: la de antes"
MSG_es["tui.nz.pv.empty"]="data/ vacía: init la siembra"

MSG_es["tui.nz.name.label"]="Nombre"
MSG_es["tui.nz.name.v_empty"]="escribe un nombre"
MSG_es["tui.nz.name.ok"]="Disponible: no hay carpeta, proyecto ni red de Docker con ese nombre."
MSG_es["tui.nz.name.empty"]="Escribe un nombre para la instancia."
MSG_es["tui.nz.name.bad"]="No es válido: minúsculas, números y guion; empieza con letra; de 2 a 31 caracteres."
MSG_es["tui.nz.name.folder"]="Ya existe la carpeta instances/{1}."
MSG_es["tui.nz.name.project"]="Docker ya tiene contenedores del proyecto {1} (de una instancia cuya carpeta ya no está, u otro despliegue en este servidor)."
MSG_es["tui.nz.name.network"]="Docker ya tiene una red {1}_*: una instancia con ese nombre chocaría con ella al desplegar."
MSG_es["tui.nz.name.where"]="Se creará en {1}"
MSG_es["tui.nz.name.nodocker"]="Docker no responde: solo se comprobó la carpeta, no los contenedores ni las redes."
MSG_es["tui.nz.name.proposed"]="Propuesto: la primera libre. Escribe para cambiarlo."

MSG_es["tui.nz.svc.none"]="Elige al menos un servicio."
MSG_es["tui.nz.svc.v_none"]="ninguno"
MSG_es["tui.nz.svc.port_ok"]="puerto {1}"
MSG_es["tui.nz.svc.port_busy"]="puerto {1} ocupado"
MSG_es["tui.nz.svc.dep"]="Usa: {1} (si está en la instancia)"
MSG_es["tui.nz.svc.dep_missing"]="{1} usa {2}, que no está en la instancia: lo que dependa de él no funcionará."

MSG_es["tui.nz.ver.v_notag"]="sin versión elegida"
MSG_es["tui.nz.ver.typed_bad"]="Eso no es una etiqueta válida (letras, números, punto, guion y guion bajo)."
MSG_es["tui.nz.ver.image"]="imagen {1}"
MSG_es["tui.nz.ver.nodocker"]="Docker no responde: no se ven las versiones cargadas; puedes escribir una."

MSG_es["tui.nz.data.v_new"]="nueva"
MSG_es["tui.nz.data.v_existing"]="ya tiene datos"
MSG_es["tui.nz.data.new"]="Nueva: empieza de cero"
MSG_es["tui.nz.data.new_note"]="Las bases quedan vacías y ./deltactl init las siembra la primera vez (administrador, municipalidad). Genera los secretos."
MSG_es["tui.nz.data.existing"]="Ya tiene datos: viene de otro despliegue"
MSG_es["tui.nz.data.existing_note"]="Usa sus mismas bases y secretos. La instancia queda marcada como existente: init no podrá sembrarla."
MSG_es["tui.nz.data.warn"]="Se marca como existente al crearla; revertirlo es editar la instancia a mano. Si no estás seguro, elige Nueva."

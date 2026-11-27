#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_es is read by t through a nameref
# La vista Variables del panel (lib/screens/env.sh) y el editor de variables del kit (lib/ui/kit/env_editor.sh): español.
# Lo carga lib/i18n/i18n.sh; no se ejecuta. Ningún texto repite el valor de una variable: puede ser un secreto.

MSG_es["tui.tab.env"]="Variables"
MSG_es["tui.keys.env"]="{1} mover · Enter edita · 1-9 vistas · : comando · ? ayuda · q salir"
MSG_es["tui.help.head.env"]="VARIABLES"
MSG_es["tui.env.title"]="variables"
MSG_es["tui.env.none"]="No hay instancias: crea una con n y vuelve aquí."
MSG_es["tui.env.switch_dirty"]="Hay cambios sin guardar en {1}: guárdalos (s) o descártalos (Esc) antes de cambiar de instancia"
MSG_es["tui.env.sync_dirty"]="Hay cambios sin guardar en {1}: guárdalos (s) o descártalos (Esc) antes de agregar las variables nuevas"
MSG_es["tui.env.sync_confirm"]="Agrega a '{1}' las {2} variable(s) nuevas de la plantilla que sus archivos no tienen. Solo agrega, al final de cada archivo: no cambia ningún valor ni borra nada (deja una copia .bak). Las obligatorias quedan por completar. ¿Continuar?"
MSG_es["envview.status.sync"]="{1} nuevas de la plantilla"
MSG_es["envview.keys_sync"]="A agrega las {1} nuevas"

# Una fila: lo que dice el estado de la variable
MSG_es["envview.note.required"]="obligatoria"
MSG_es["envview.note.example"]="por completar"
MSG_es["envview.note.changed"]="modificada"
MSG_es["envview.note.optional"]="opcional"
MSG_es["envview.default_is"]="por defecto: {1}"
MSG_es["envview.empty"]="(vacía)"
MSG_es["envview.empty_list"]="Esta instancia no tiene archivos de variables."
MSG_es["envview.file_todo"]="{1} variables · {2} sin completar"
MSG_es["envview.file_all"]="{1} variables"
MSG_es["envview.file_pending"]="sin desplegar"

# La ficha de lo que hay bajo el cursor
MSG_es["envview.type.req"]="Obligatoria"
MSG_es["envview.type.opt"]="Opcional"
MSG_es["envview.type.secret"]="secreto"
MSG_es["envview.card.default"]="Por defecto: {1}"
MSG_es["envview.card.example"]="Ejemplo: {1}"
MSG_es["envview.card.gen"]="g genera un valor nuevo."
MSG_es["envview.card.missing"]="Obligatoria: sin ella el despliegue se rechaza."
MSG_es["envview.card.example_left"]="Todavía tiene el valor de ejemplo de la plantilla: cámbialo."
MSG_es["envview.card.state_pending"]="sin desplegar"
MSG_es["envview.card.state_synced"]="como en el último despliegue"
MSG_es["envview.card.state_new"]="se crea con la instancia"
MSG_es["envview.card.file_new"]="Este archivo aún no existe: se hace desde su plantilla al crear la instancia, con lo que se ponga aquí."
MSG_es["envview.card.state_unknown"]="sin marca de despliegue"
MSG_es["envview.card.file_pending"]="Cambió desde el último despliegue: se aplica al desplegar (u)."
MSG_es["envview.card.file_synced"]="Nada que desplegar en este archivo."
MSG_es["envview.card.file_unknown"]="La marca se crea al terminar el próximo deploy; hasta entonces no se sabe qué cambió."
MSG_es["envview.card.hidden"]="{1} variables opcionales ocultas: a las muestra."

# Chips del borde
MSG_es["envview.status.todo"]="{1} sin completar"
MSG_es["envview.status.changed"]="{1} sin guardar"
MSG_es["envview.status.pending"]="{1} sin desplegar"
MSG_es["envview.status.ok"]="todo en orden"
MSG_es["envview.foot"]="{Enter} editar|^g generar|^r revelar|^d defecto|^a avanzadas|^s guardar|^u desplegar"
MSG_es["envview.foot_edit"]="{Enter} aceptar|{Esc} cancelar|{Tab} ver|{Ctrl+G} generar|{Ctrl+U} borrar"

# Mensajes de la línea de estado
MSG_es["envview.refused"]="{1} no se acepta: {2}"
MSG_es["envview.generated"]="{1} generada (el valor no se muestra): s guarda"
MSG_es["envview.default_set"]="{1} toma su valor por defecto: s guarda"
MSG_es["envview.no_default"]="{1} no tiene valor por defecto"
MSG_es["envview.not_secret"]="{1} no es un secreto: su valor ya se ve"
MSG_es["envview.saved"]="Guardadas {1} variable(s) en {2}"
MSG_es["envview.nothing"]="No hay cambios que guardar"
MSG_es["envview.save_refused"]="No se guardó nada: {1} no válidas ({2})"
MSG_es["envview.adv_0"]="Avanzadas ocultas ({1})"
MSG_es["envview.adv_1"]="Avanzadas visibles"

# Preguntas
MSG_es["envview.ask.leave"]="Hay cambios sin guardar ({1}). ¿Qué hago con ellos?"
MSG_es["envview.ask.deploy"]="¿Guardar los cambios ({1}) y desplegar {2}?"
MSG_es["envview.ask.deploy_only"]="¿Desplegar {2} ahora? No hay cambios sin guardar."
MSG_es["envview.ask.deploy_note"]="El despliegue reinicia los servicios de la instancia."

# La última línea según lo que hace el editor
MSG_es["envview.keys"]="{1} mover · Enter edita · g generar · r revelar · f archivo · d defecto · a avanzadas · s guardar · u desplegar · [/] instancia · Esc sale"
MSG_es["envview.keys_file"]="{1} mover · Enter pliega · a avanzadas · s guardar · u desplegar · [/] instancia · Esc sale"
MSG_es["envview.keys_edit"]="Enter acepta · Esc cancela · Tab ver u ocultar · Ctrl+G genera · Ctrl+U borra · se puede pegar · q ? : son letras aquí"
MSG_es["envview.keys_ask_gen"]="y reemplazar · otra tecla cancela"
MSG_es["envview.keys_ask_leave"]="s guardar y salir · d descartar y salir · otra tecla sigue editando"
MSG_es["envview.keys_ask_deploy"]="y confirmar · otra tecla cancela"

# A variable that points to a file of secrets/ (FCM_CERT=/run/secrets/fcm.json): whether it is there, and the dialog that loads it (key f).
MSG_es["envview.note.file_missing"]="falta el archivo (f)"
MSG_es["envview.note.file_invalid"]="archivo no válido (f)"
MSG_es["envview.note.file_ok"]="archivo cargado"
MSG_es["envview.not_file"]="{1} no apunta a un archivo de secrets/: su valor se escribe con Enter"
MSG_es["envview.file.what"]="Variable {1} · {2}"
MSG_es["envview.file.text"]="Escribe la ruta de este archivo en este servidor. Se copia a secrets/{1} con permisos 600 y su contenido no se muestra."
MSG_es["envview.file.replace"]="Ya hay un archivo en secrets/{1}: se reemplaza."
MSG_es["envview.file.label"]="Ruta"
MSG_es["envview.file.found"]="archivo encontrado"
MSG_es["envview.file.nofile"]="ese archivo no existe"
MSG_es["envview.file.isdir"]="es una carpeta, no un archivo"
MSG_es["envview.file.empty"]="Escribe la ruta del archivo (Tab busca en las carpetas usuales)."
MSG_es["envview.foot_file"]="{Enter} cargar|{Esc} cancelar|{Tab} buscar"
MSG_es["envview.keys_file_edit"]="Enter carga el archivo · Esc cancela · Tab busca en las carpetas usuales · se puede pegar la ruta · q ? : son letras aquí"

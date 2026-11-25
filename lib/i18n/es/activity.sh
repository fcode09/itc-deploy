#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_es is read by t through a nameref
# La vista Actividad del panel (lib/screens/activity.sh): español. Absorbe Salida, Ejecuciones y Procesos.
# Lo carga lib/i18n/i18n.sh; no se ejecuta.

MSG_es["tui.tab.activity"]="Actividad"
MSG_es["tui.act.title"]="Actividad"
MSG_es["tui.act.tab.resumen"]="Resumen"
MSG_es["tui.act.tab.salida"]="Salida"
MSG_es["tui.act.tab.consumo"]="Consumo"
MSG_es["tui.act.tab.procesos"]="Procesos"
MSG_es["tui.act.panel"]="este panel"
MSG_es["tui.act.panel_note"]="El último comando de este panel. Los comandos que solo leen no se guardan en el historial: aquí es donde se ven."
MSG_es["tui.act.job.running"]="en curso"
MSG_es["tui.act.job.ok"]="correcto"
MSG_es["tui.act.job.failed"]="con error"
MSG_es["tui.act.job.cancelled"]="cancelado"
MSG_es["tui.act.live_cost"]="Lo que usa ahora"
MSG_es["tui.act.job_nousage"]="Este comando no se guarda en el historial, así que no tiene consumo registrado. Mientras corre, la pestaña Procesos muestra lo que lo forma y lo que usa."
MSG_es["tui.act.no_usage"]="Esta ejecución se guardó antes de que se midiera el consumo: no hay cifras que mostrar."
MSG_es["tui.act.no_output"]="Esta operación no guardó salida."
MSG_es["tui.act.empty"]="Todavía no hay actividad. Cuando lances algo (desplegar, comprobar, bajar…), o lo haga otra terminal, verás aquí qué fue, cómo terminó, su salida, lo que consumió y los procesos que lo forman."
MSG_es["tui.act.moved"]="Salida, Ejecuciones y Procesos ahora viven en Actividad (tecla 0). Estas vistas siguen un tiempo, pero ya no recibirán novedades."
MSG_es["tui.keys.act_resumen"]="{1} elegir · ← → pestaña · RePág/AvPág detalle · Enter salida · t consumo · : comando · ? ayuda · q salir"
MSG_es["tui.keys.act_salida"]="{1} elegir · ← → pestaña · RePág/AvPág Inicio/Fin desplazan · f sigue · v resumen/crudo · e errores · x cancela · ? ayuda · q salir"
MSG_es["tui.keys.act_consumo"]="{1} elegir · ← → pestaña · RePág/AvPág detalle · t estadísticas · : comando · ? ayuda · q salir"
MSG_es["tui.keys.act_procesos"]="{1} elegir · ← → pestaña · RePág/AvPág Inicio desplazan el árbol · x cancela el comando · ? ayuda · q salir"
MSG_es["tui.keys.act_stats"]="s una instancia / todas · t o Esc vuelven · : comando · ? ayuda · q salir"

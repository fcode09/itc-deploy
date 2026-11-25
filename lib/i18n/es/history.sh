#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_es is read by t through a nameref
# La pestaña Historial del espacio de trabajo de una instancia (lib/screens/ws/historial.sh): español.
# Lo carga lib/i18n/i18n.sh; no se ejecuta.

MSG_es["tui.ws.tab.historial"]="Historial"
MSG_es["tui.his.count"]="{1} operaciones"
MSG_es["tui.his.empty"]="Esta instancia aún no tiene operaciones registradas. Las que cambian algo (desplegar, init, adopt, rollback, detener, bajar) quedan aquí con su salida y lo que consumieron."
MSG_es["tui.his.summary"]="Lo que imprimió (resumen)"
MSG_es["tui.his.foot.open"]="{Enter} salida entera"
MSG_es["tui.his.foot.scroll"]="^PgUp ^PgDn desplaza"
MSG_es["tui.his.keys"]="{1} operación · Enter la salida entera · RePág/AvPág desplaza el detalle · z ampliar · {2} atrás · ? ayuda · q salir"

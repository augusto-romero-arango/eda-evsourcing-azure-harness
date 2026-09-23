---
fecha: 2026-09-17
hora: 22:47
sesion: mefisto-planner
tema: Refinar #1473 (intento de correccion del rol antes del abort del gate de neutralidad)
---

## Contexto
Tercer eslabon de la familia #1416/#1439: #1468 evita escribir la fuga, #1469 da el remedio correcto al fallar, #1473 concede un intento de correccion antes de perder la corrida.

## Descubrimientos
- `run_agent "merge" "writer"` es el precedente exacto de un sub-stage con tag no numerico: logs, JSONL y metricas propios sin tocar `run_agent`.
- Trampa: ambos stages leen `LAST_AGENT_*` despues de `run_neutrality_gate`; un segundo `run_agent` las pisa y el historial atribuiria al rol las metricas del fix. Hay que capturar y restaurar.
- `auto_commit_if_needed` corre justo despues del gate: la correccion entra al commit del stage sin cambios.
- El stub del test ya cuenta llamadas: un modo `leak-then-fix` cubre el camino feliz; `leak` sigue cubriendo el abort.

## Decisiones
- Un solo intento, ambos roles (misma funcion), sin variable de entorno nueva: el fix usa el watchdog estandar de `run_agent`.
- Rastro en `events.log` (`[neutralidad][fix]`) + archivo de metricas propio; sin cambios de esquema en `pipeline-history.jsonl`.
- El prompt de fix no pide resumen; si su CLI falla, aborta por el camino ordinario de `run_agent`.

## Descartado
- Presupuesto de tiempo propio para el intento.
- Campo nuevo en el historial para contar correcciones (issue aparte sobre `mefisto-metrics-report.sh` si se quiere medir).

## Preguntas abiertas
- Ninguna. #1473 queda `bloqueado` hasta que #1469 cierre.

## Referencias
Issues refinados: #1473 (estado:borrador -> estado:listo, bloqueado por #1469)

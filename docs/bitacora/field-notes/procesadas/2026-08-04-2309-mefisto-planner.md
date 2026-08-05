---
fecha: 2026-08-04
hora: 23:09
sesion: mefisto-planner
tema: Evaluacion con datos del paso 1 del plan de velocidad y desglose del paso 2 (hook PostToolUse)
---

## Contexto

El 2026-07-31 se entrego el paso 1 del plan de velocidad del pipeline interno (issue #481 / PR #482: bloque ECONOMIA DE TURNOS en los dos prompts de `mefisto-tooling-pipeline.sh`), con el compromiso de evaluar su efecto con datos antes de continuar con los pasos 0/2/3/4. Esta sesion hizo esa evaluacion y, con el gate superado, desgloso el paso 2 en issues.

## Descubrimientos

- **El paso 1 funciono y supero la proyeccion.** Baseline (2026-W31, n=26 instrumentadas): 85,1 turnos/issue, wall 15m58s. Post-cambio (2026-W32, n=17, todas posteriores al merge de #482): 51,2 turnos/issue (-39,8%), tool calls 49,1 (-41,5%), wall 12m38s (-20,9%), costo/issue ~$7,42 -> ~$4,94 (-33%). Por stage: writer 28,2 / reviewer 23,1 (proyeccion era 32-36).
- **Atribucion limpia**: `a06a44a` (#482) es el unico commit que toco `mefisto-tooling-pipeline.sh` en el periodo; las 17 corridas W32 son todas post-merge.
- **Sin degradacion de calidad visible**: 17/17 corridas completed a la primera (cero failed/reintentos), 18 PRs post-cambio con 0 comentarios de review, y tokens_out/turno se mantuvo en la constante historica (~1.059 vs ~1.050): cayo el numero de turnos, no la densidad de cada turno — exactamente el mecanismo que predijo el modelo `wall = turnos x tokens/turno / throughput`.
- **Caveat honesto**: no es un A/B controlado; la mezcla de issues W32 (propagacion de doctrina MEF-ADR-0037) pudo ser mas liviana que la de W31.
- **El bloque "QUE CRECIO" del reporte ya funciona** (2 meses instrumentados): el paso 0 del plan (comparacion ventana-vs-ventana) quedo parcialmente cubierto de gratis.
- `.claude/settings.json` hoy NO existe versionado; el pipeline lo inyecta al worktree si esta presente (sed de la ruta del events.log, lineas ~276-280) y lo revierte con `git checkout` en ~439 y ~517. Cualquier hook versionado debe reconciliarse con ese mecanismo.
- El blocklist publicado (`is_path_in_consumer_blocklist`) NO debe recibir `.claude/settings.json`: en el consumidor esa ruta es del consumidor, no reservada al plugin. La decision se documenta como comentario, sin tocar el case.

## Decisiones

- **Gate del plan superado**: los turnos bajaron, el diagnostico del eje A queda confirmado, via libre al paso 2. (El plan pedia 3-4 corridas a partir del 2026-08-07; hubo 17 al 2026-08-04.)
- **Paso 2 desglosado en dos issues** (MEF-ADR-0019 seccion E: registrar una ruta y poblarla son dos PRs, registro primero):
  - #522: registrar `.claude/settings.json` en `is_path_in_mefisto_scope` (entrada exacta, no `.claude/*`; actualizar test [E2]; sin crear el archivo).
  - #523: hook `PostToolUse` (matcher Edit|Write) que valida con `is_path_in_mefisto_scope` y devuelve exit 2 + stderr al modelo; degradacion segura; reconciliar inyeccion/reverts del pipeline; actualizar ECONOMIA DE TURNOS; `validate_mefisto_scope_changes` se mantiene como juez final.
- **Gate de changelog explicitamente fuera de alcance** de #523: es condicion de fin de stage, un PostToolUse daria falsos positivos; si los datos post-paso-2 muestran turnos residuales, evaluar hook `Stop` en issue aparte.
- **Protocolo de medicion del paso 2 escrito en #523**: baseline post-paso-1 = writer 28,2 / reviewer 23,1 turnos/stage (W32).
- **Batch lanzado**: `/mefisto-sequential 522 523` (tmux `mefisto-batch-230854`); la validacion 1.5 quito `bloqueado` de #523 (dependencia satisfactible por el orden del batch).

## Descartado

- No se creo issue para el paso 0 (comparacion ventana-vs-ventana en el reporte): la comparacion mensual ya salio sola con 2 meses instrumentados; si hace falta el modo `--desde` explicito, sera un issue menor mas adelante.
- No mover el gate de changelog a PostToolUse (falsos positivos por diseño; ver arriba).

## Preguntas abiertas

- Pasos 3 (acotar razonamiento del writer, eje B) y 4 (politica sonnet/opus) siguen en pausa: medirlos sobre los turnos que queden despues del paso 2.
- Verificar tras el merge de #523 si el hook realmente reduce los turnos residuales de auto-verificacion (baseline W32 documentado en el issue).

## Referencias

Issues creados: #522, #523
Batch lanzado: tmux `mefisto-batch-230854` (orden: #522 -> #523)
PR evaluado: #482 (issue #481)

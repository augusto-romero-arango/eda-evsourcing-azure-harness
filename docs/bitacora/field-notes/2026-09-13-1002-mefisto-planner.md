---
fecha: 2026-09-13
hora: 10:02
sesion: mefisto-planner
tema: Reportar metricas por etapa (modelo, tokens, tiempo, costo) en el PR de los pipelines
---

## Contexto

El mantenedor pidio que toda corrida de TDD (consumidor) y de tooling (consumidor e interno)
reporte en el PR de GitHub, por cada etapa, el modelo utilizado, los tokens consumidos, el
tiempo en formato `15m 7s` y el costo estimado en dolares.

## Descubrimientos

- **La instrumentacion ya existe completa; lo que falta es solo el render.** `compute_stage_metrics`
  (en `scripts/_pipeline-common.sh` y su gemela `src/internal/scripts/lib/_mefisto-common.sh`) ya
  deriva por stage `model`, `tokens.{input,output,cache_read,cache_creation}`, `cost_usd`,
  `duration_ms` y `turns`. Los tres pipelines tienen ese JSON vivo en variables
  (`AGENT_*_METRICS_JSON`; en `tooling-pipeline.sh` sin el sufijo `_JSON`) justo en el punto donde
  componen el body del PR -- y lo descartan: solo viaja al `pipeline-history.jsonl` que consume
  `metrics-report.sh` a posteriori.
- **El costo no necesita tabla de precios propia.** El protocolo neutral ya trae `cost_usd` resuelto
  por cada runtime: Claude via `total_cost_usd` (`src/runtime/lib/runtime-claude.jq`), OpenCode
  sumando `.part.cost` de los steps (`src/runtime/lib/runtime-opencode.jq`). Mantener tarifas
  propias en el harness envejeceria en silencio con cada cambio del proveedor.
- `iac-pipeline.sh` es el unico pipeline con agentes que NO llama a `compute_stage_metrics`: infra
  no esta instrumentado. Queda fuera del trio; cubrirlo seria instrumentar, no renderizar.
- El body del PR solo se escribe en `gh pr create`. Cuando `find_open_pr_for_branch` devuelve una
  URL, los tres pipelines reutilizan el PR sin tocar el body: una segunda corrida sobre la misma
  rama no dejaba hoy ningun rastro de su costo en el PR.
- El cierre documental automatico (`mefisto-field-note.sh`) esta caido por el defecto que ya cubre
  el issue #1310: invoca `gh repo view --repo <slug>`, bandera que `gh repo view` no acepta (el slug
  va posicional). Esta field note se entrego por la via manual del epilogo.

## Decisiones

- **Forma**: tabla unica `## Metricas de la corrida`, una fila por etapa mas fila Total.
  Columnas: Etapa | Modelo | Tokens (total) | in/out/cache | Tiempo (`15m 7s`) | Costo.
- **Tokens**: total sumado MAS desglose visible. `cache_read` domina por uno o dos ordenes de
  magnitud, asi que un total plano se leeria como contexto nuevo.
- **Total = suma de las etapas**, nunca el wall-clock del pipeline. Una tabla cuyas filas no suman
  a su total es peor que no tenerla; el tiempo no-agente (builds, tests, merges, hold por limite de
  uso) queda deliberadamente fuera de lo que la tabla mide. Si algun stage no aporto cifras, el
  Total se marca parcial.
- **PR reutilizado**: la corrida publica su tabla como comentario fechado (`gh pr comment`), no
  edita ni acumula en el body -- parsear un body que un humano pudo editar es fragil.
- **Modelo mostrado**: `metrics.model` (el EFECTIVO del terminal), no `requested_model`.
- **Orden interno -> publicado**: el PR del issue interno muestra su propia tabla, asi que el
  formato se dogfoodea en este repo antes de congelarlo para los consumidores. Mismo camino que
  siguio `metrics-report.sh` (interno #427 -> publicado #647).

## Descartado

- **Metricas inline en cada `<summary>`** (`Writer -- opus-5 - 1.2M tok - 15m 7s - $3.41`): no da
  total ni permite comparar etapas de un vistazo.
- **Editar el body para acumular una subtabla por corrida**: requiere parsear y reemplazar un body
  que un humano pudo haber editado.
- **Fila Total igual al wall-clock del pipeline**, con las etapas como desglose parcial que no
  cuadra con el.
- **Calcular el costo con una tabla de precios por modelo** mantenida en el harness.
- **Instrumentar `iac-pipeline.sh`** en este trio: es otro problema (instrumentar, no renderizar).

## Preguntas abiertas

- `iac-pipeline.sh` sigue sin instrumentar: sus PRs no podran mostrar la tabla hasta que alguien
  cablee `compute_stage_metrics` en sus stages `infra-writer`/`infra-reviewer`.
- En un stage con reintentos, `AGENT_*_METRICS_JSON` conserva solo el ULTIMO intento; la tabla
  hereda esa semantica y por tanto subdeclara el costo real de un stage reintentado.
- Con suscripcion (Claude Pro/Max u OpenCode sobre suscripcion) el `cost_usd` reportado es
  equivalente-API, no desembolso real. No se decidio si la tabla debe advertirlo.

## Referencias

Issues creados: #1311 (render interno), #1312 (porte a tooling del consumidor), #1313 (cableado en TDD).
Orden de batch verificado con `mefisto-next-order.sh`: 1311 -> 1312 -> 1313.

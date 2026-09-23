---
fecha: 2026-09-13
hora: 11:03
sesion: mefisto-planner
tema: estimacion neutral de costos de agentes
---

## Contexto

Los issues #1311-#1313 pretendian mostrar costo por etapa en los PRs, pero OpenCode registraba
`cost_usd: 0` al autenticarse mediante ChatGPT OAuth. Se investigo si ese cero podia publicarse
como comparable con `total_cost_usd` de Claude y se concluyo que hacia falta corregir primero el
contrato y la telemetria de origen.

## Descubrimientos

- El plugin OAuth de OpenCode reemplaza las tarifas del modelo por cero; el valor describe el
  costo marginal de la suscripcion, no el consumo equivalente a tarifas API.
- OpenCode obtiene su catalogo de Models.dev. `https://models.opencode.ai/api.json` conserva los
  IDs exactos `openai/gpt-5.6-luna`, `openai/gpt-5.6-terra` y `openai/gpt-5.6-sol`, sus tarifas y
  tiers de contexto aunque la sesion OAuth reporte costo cero.
- Cada `step_finish` conserva input nuevo, cache read/write, output visible y reasoning. La formula
  de OpenCode resta cache del input, cobra reasoning como output y elige el tier por el contexto
  de cada paso, no por el acumulado de la corrida.
- El contrato neutral vigente exigia `cost_usd` y, por `additionalProperties:false`, descartaba
  cache y razonamiento. Los consumidores internos y publicados propagaban esa perdida.
- En las trazas de #1315 se observaron 193492 tokens de input nuevo, 2368768 de cache, 10023 de
  output visible y 3697 de reasoning. Con las tarifas base observadas, el equivalente fue
  aproximadamente USD 0.592652 para Writer Terra y USD 0.8423432 para Reviewer Sol.

## Decisiones

- Nombrar la magnitud nueva `estimated_cost_usd`: costo equivalente a tarifa API, independiente
  de la facturacion marginal de OAuth/suscripcion.
- Los escritores nuevos emiten solo `estimated_cost_usd`; los lectores aceptan `cost_usd` para
  historia local, lo presentan como costo reportado legado y lo excluyen de totales estimados.
- Ampliar `tokens` con `cache_read`, `cache_write` y `reasoning`, conservando `input` y `output`.
- Consultar Models.dev como maximo una vez por dia UTC con una cache propia bajo
  `MEFISTO_STATE_DIR/cache/model-pricing/`, sin leer cache ni credenciales privadas de OpenCode.
- Ante fallo usar la ultima cache valida; sin cache/modelo resoluble emitir
  `estimated_cost_usd:null`. La telemetria nunca aborta una corrida.
- Separar el rollout por ADR, cache, contrato, estimador OpenCode, metricas internas/publicadas,
  reportes internos/publicados y finalmente las tablas #1311-#1313.
- Todos los issues pasaron la revision simplificada: como maximo seis CAs, un componente principal,
  lado explicito y verificaciones concretas. Los issues de migracion abarcan varios archivos por
  ser variaciones homogeneas del mismo contrato.

## Descartado

- Usar `.part.cost` de OpenCode bajo OAuth: fija ceros semanticamente incorrectos.
- Parsear `opencode models --verbose`: mezcla el catalogo con overrides del runtime y su formato de
  CLI no es un contrato estable para el harness.
- Mantener una tabla de precios estatica en el repo: envejeceria silenciosamente.
- Renombrar `cost_usd` historico durante lectura o sumarlo con estimaciones nuevas.
- Consultar el catalogo en cada stage o cada traduccion live.

## Preguntas abiertas

Ninguna para el desglose. Cada detalle pendiente de implementacion quedo convertido en criterio
verificable o nota tecnica de los issues.

## Referencias

Issues creados: #1321, #1322, #1323, #1324, #1325, #1326, #1327, #1328.

Issues refinados: #1311, #1312, #1313.

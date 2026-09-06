---
fecha: 2026-08-31
hora: 09:06
sesion: mefisto-planner
tema: Refinamiento de los drafts MCP del consumidor (#788, #789) y desglose del trigger Stage 2b (#791)
---

## Contexto
Dos drafts `estado:borrador` creados desde el consumidor Bitakora.ControlAsistencia (PR 533 de ese repo, primera adopcion real de la doctrina MCP de MEF-ADR-0047/0048) llegaron con contexto de campo rico. Sesion de refinamiento para llevarlos a `estado:listo`.

## Descubrimientos
- **El trigger del Stage 2b no cubre MCP** (hallazgo propio del refinamiento, no venia en el draft): `SMOKE_FILES` grepea `Function/` y `Obtener|Listar.../FunctionEndpoint.cs`, y `SMOKE_TEST_PROJECT` se deriva por dominio (`tests/{NS}.{Dominio}.SmokeTests`). Un diff con `src/{NS}.Mcp.{Proposito}/{X}Tool.cs` nunca dispara el stage — la doctrina del smoke-test-writer sola seria letra muerta.
- **El gap del planner era parcial, no total**: el template de issues MCP ya listaba "Extension de la suite de smoke e2e" pero en `## Capas de test esperadas`, no como CA exigible — exactamente el resquicio por el que el consumidor la degrado a "evaluacion del implementer/reviewer".
- **La proteccion original de la exclusion DTO** (`type_decls -eq 1` en `coverage_classify_file`) existe para no esconder un record junto a una clase con metodos; la relajacion segura es "todos los tipos son records puros terminados en `;`", no quitar el conteo.
- El argumento del reviewer del consumidor ("sin la key de dev no se puede verificar") contradice el diseno verificado: el gate local del Stage 2b solo compila, y CI resuelve `mcp_extension` por OIDC en runtime (MEF-ADR-0048).

## Decisiones
- **#788 queda como un solo issue** (los tres cambios de clasificacion viven en la misma funcion, mismo archivo de tests, misma enmienda a MEF-ADR-0014; precedente directo: issue #590 con `*EventHandler.cs`).
- **Cada tool MCP nueva exige su propia tool call real** en la suite smoke — va mas alla del minimo actual de MEF-ADR-0048 ("las cinco son el minimo" es piso de la suite, no doctrina de extension), asi que #789 incluye una enmienda pequena al ADR fijando las tres piezas obligatorias: pin de catalogo, pin de `inputSchema.required`, tool call real.
- **#789 se parte por mecanica**: doctrina (4 markdown: planner, smoke-test-writer, reviewer, enmienda ADR) en #789; el trigger bash del Stage 2b en #791 (nuevo), dependiente de #789 y con label `bloqueado`.
- Fuera de alcance deliberado en #788: `FiltroDeNombre.cs` y `RespuestaJson.cs` siguen "sin clasificar"; issue futuro si molestan.
- Caso mixto del Stage 2b (Function de dominio + tool MCP en un mismo diff): no se soporta — improbable por diseno (MEF-ADR-0047 decision 3 + issues separados del planner); basta que no rompa.

## Descartado
- Partir el punto 3 de #788 (relajacion DTO, regla general no exclusiva de MCP) en issue aparte: habria producido dos PRs tocando la misma funcion y la misma enmienda de ADR.
- Enmienda a MEF-ADR-0048 como issue separado: es pequena y sin ella los CAs de los agentes en #789 no tendrian respaldo doctrinal.

## Preguntas abiertas
- Ninguna.

## Referencias
Issues refinados: #788 (clasificacion MCP en coverage gate), #789 (extension obligatoria de la suite smoke MCP en planner/smoke-test-writer/reviewer + enmienda MEF-ADR-0048).
Issues creados: #791 (trigger del Stage 2b para tools MCP, depende de #789).
Evidencia de origen: PR 533 de Bitakora.ControlAsistencia.

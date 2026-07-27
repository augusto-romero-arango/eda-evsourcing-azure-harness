---
fecha: 2026-07-26
hora: 12:40
sesion: mefisto-planner
tema: Portar de ControlPlane a Mefisto — worker de proyecciones, Functions de query y (parqueado) correlacion/causacion
---

## Contexto
El usuario trajo tres avances de `Cosmos.ControlPlane` para integrar al harness:
1. Proyecto de proyecciones (worker daemon Marten) y su onboarding.
2. CorrelationId/CausationId + middleware de trazas sobre ASB.
3. Functions de query (sobre proyecciones y directas al event store), con estrategia de tests desde `implementer`.

Se analizo el codigo de ControlPlane (`Projections`, `ReadModels`, `TenantResolver`, `Program.cs` de dominios) y el PR abierto #134 (config-test del worker). Se investigo a fondo la doc oficial de Marten (proyecciones, sesiones, multitenancy) y de Anthropic (subagentes, Agent Skills).

## Descubrimientos
- **Vocabulario nuevo del harness que emerge**: worker de proyecciones por BC, `ConfiguracionMartenProjections` (seam del PR 134), `I{Dominio}ProjectionStore`, `tipo:projection`, Skill `projections`, subagentes `projection-test-writer`/`projection-implementer`.
- **Marten** (verificado): 5 recetas (SingleStream, MultiStream, EventProjection, Custom, IProjection), 3 lifecycles (Inline/Live/Async), 2 estilos (convencional vs explicito Evolve), inmutable vs mutable. `FetchLatest` es agnostico al lifecycle pero **solo** en `IDocumentSession`; `AggregateStreamAsync`/`FetchStreamAsync` viven en `IQueryEventStore` (disponibles en `QuerySession`). Confirmado en `JasperFx.Events.IQueryEventStore`.
- **Sesiones Marten**: `QuerySession` (read-only por tipo) y `LightweightSession` tienen el MISMO perfil (sin identity map ni dirty checking); no hay ventaja de rendimiento en usar Lightweight para leer — solo se justifica si se necesita `FetchLatest`.
- **Seguridad**: acotar la sesion al tenant resuelto (`ITenantResolver`), nunca al id de la ruta (previene BOLA/IDOR, OWASP API #1); conjoined tenancy lo fuerza en la capa de datos.
- **Anthropic**: subagentes = ventana de contexto propia + system prompt enfocado; Agent Skills = progressive disclosure en 3 niveles (metadata ~100 tokens siempre; cuerpo <5k al dispararse; recursos Nivel-3 al leerse); los plugins publican Skills en `<plugin>/skills/<name>/SKILL.md` y los subagentes los referencian con `skills:` en frontmatter. Mefisto hoy no usa ningun Skill.
- **Arquitectura del pipeline**: `tdd-pipeline.sh` despacha cada agente como proceso `claude -p --agent X` (contexto por-agente); `batch`/`parallel`/`tmux` son routers por label `tipo:*`.

## Decisiones
- **Tema 1 (proyecciones)**: un worker por BC (D1); skill nuevo `/scaffold-projections` idempotente (D2); opt-in via token `projections` en `harness.config.json` (D3); el config-test del PR 134 se reparte entre `/scaffold-projections` (seam + test base) y el flujo read-side (per-proyeccion); doctrina como seccion del ADR de worker (cross-ref MEF-ADR-0029). Las columnas de metadata del writer entran en scope (independientes del Tema 2).
- **Tema 3 (queries/proyecciones)**: superficie (a) proyecciones + (b1) hidratar aggregate + (b2) eventos crudos, por GET, sin time-travel (D5); recetas SingleStream=N1 / MultiStream=N2 / Event-Custom=N3 (D6a); Async canonico, Inline opt-in (D6b); convencional + inmutable (records) + estatico (D6c); `QuerySession`+`LoadAsync` canonico, `FetchLatest` opt-in (D6d); naming `Obtener`/`Listar` + carpeta por query + ruta REST (D7a); `{Concepto}View`/`{Concepto}Projection`/`I{Dominio}ProjectionStore` con traza 1:1 (D7b); 1 Skill + 2 subagentes read-side + reviewer/planner via `skills:` (D8); `tipo:projection` -> `tdd-pipeline.sh` rama read-side, mismo BC serializa (D8b); taxonomia de 4 capas de test + carve-out del endpoint (D9).
- **ADRs**: 3 nuevos + 1 enmienda (D10) — adopcion de Agent Skills; worker de proyecciones (+ enmienda MEF-ADR-0021); doctrina read-side; enmienda MEF-ADR-0006 (naming).
- **Refinamiento del backlog**: se partio el issue de skills-wiring (planner vs reviewer/smoke) y el scaffolder (worker vs read-models+tests) por tamano/cohesion; se resolvio la pregunta de deteccion de BC (ver abajo). Backlog final: 16 issues, todos `estado:listo`.

## Descartado
- **Tema 2 (CorrelationId/CausationId + TraceContextMiddleware)**: **parqueado** por decision del usuario — todavia experimental de su lado como para fijarlo en el harness. No se creo issue ni ADR. Retomar empezando por "donde vive el middleware" (nuget building block vs generado por Mefisto).
- Bolt-on de la doctrina de proyeccion a `test-writer`/`implementer` (infla el 80% write-side) — reemplazado por Skill + subagentes.
- Pipeline `projection-pipeline.sh` dedicado — se reusa `tdd-pipeline.sh` con rama read-side.
- Estandarizar time-travel / Event / Custom projections ahora — diferido (Rule of Three, MEF-ADR-0018).
- No calcar ControlPlane: naming preliminar (mejorado en D7), read models mutables (ahora inmutables), `Query().FirstOrDefault` (ahora `LoadAsync`), `XQueriesEndpoint` agrupado (ahora carpeta por query).

## Preguntas abiertas
- **Naming para proyectos codificados en ingles**: conciliar los esquemas espanol/ingles del marco. Candidato a ADR futuro; fuera del alcance de esta tanda.
- **Caveat de compatibilidad**: version minima de Claude Code que soporta plugin-skills y el campo `skills:` en agentes (afecta el `claude -p` del pipeline). A verificar al implementar #360.
- **Tema 2** completo, cuando el usuario estabilice el enfoque.
- *(RESUELTO)* Deteccion del BC para `/parallel`: como el contrato declara un BC por repo (MEF-ADR-0023) y `/parallel` opera sobre un repo, todos los `tipo:projection` comparten el worker -> regla simple "dos `tipo:projection` cualesquiera son incompatibles"; sin logica de deteccion. Anclado en #372.

## Referencias
Backlog final: **16 issues** en el repo de Mefisto, todos `tipo:tooling` + `estado:listo` (#364-#375 con `bloqueado`).

- **Oleada 0 — ADRs** (desbloqueados, punto de arranque): #360 (adopcion Agent Skills), #361 (worker proyecciones + enmienda 0021), #362 (doctrina read-side), #363 (enmienda naming 0006).
- **Oleada 1 — skill + subagentes**: #364 (Skill `projections`), #365 (subagentes read-side), #366 (planner: propuesta de receta + DoR), #374 (reviewer + smoke via `skills:`).
- **Oleada 2 — scaffolding**: #367 (`/scaffold-projections` + agente, fase 1 worker), #375 (fase 2: ReadModels + Projections.Tests base), #368 (modulos Terraform Container App), #369 (token `projections` + `/onboard`).
- **Oleada 3 — integracion**: #370 (paso en `domain-scaffolder`), #371 (rama read-side en `tdd-pipeline.sh`), #372 (routers + serializacion de projections), #373 (label `tipo:projection` + DoR).

Splits aplicados en el refinamiento: el antiguo #366 (skills en reviewer/planner/smoke) -> #366 (planner) + #374 (reviewer/smoke); el antiguo #367 (scaffolder monolitico) -> #367 (worker/launcher) + #375 (read-models + tests base).

Grafo de dependencias: #364←(#360,#362,#363); #365←#364; #366←#364; #374←#364; #367←(#361,#363); #375←#367; #368←#361; #369←#361; #370←#367; #371←#365; #372←#371; #373←(#362,#363).

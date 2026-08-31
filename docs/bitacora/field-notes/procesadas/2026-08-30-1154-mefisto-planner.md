---
fecha: 2026-08-30
hora: 11:54
sesion: mefisto-planner
tema: desglose de la doctrina MCP (#761) tras el cierre del piloto en el consumidor
---

## Contexto

El piloto MCP de Bitakora.ControlAsistencia quedo completo y validado (issues #502/#508/#509/#516 del consumidor; suite smoke 8/8 verde contra dev; PR #518 mergeado). Era la condicion que #761 declaraba para poder refinarse. Sesion ejecutada desde la sesion de trabajo del consumidor (el lanzamiento headless del agente fue bloqueado por permisos; se aplico el playbook del planner directamente).

## Descubrimientos

- Los gates de scope ya cubren `commands/*`, `agents/*`, `docs/*` por glob: crear `scaffold-mcp.md`, `mcp-scaffolder.md` y los ADRs NO requiere el PR previo de registro de rutas (MEF-ADR-0019 seccion E solo aplica a tipos de ruta nuevos).
- El precedente de desglose canonico es la cadena de proyecciones: #361 (ADR) -> #367 (scaffolder fase 1) -> #375 (fase 2) -> #453 (deploy action). Se replico el mismo corte incremental.
- La doctrina de testing MCP tiene entidad propia (piramide de 3 niveles, endpoints de gate, key por OIDC, criterio de concurrencia) y se separo en su propio ADR en vez de inflar el de doctrina.

## Decisiones

- #761 se acoto al ADR de doctrina (sin epic; la relacion vive en `## Dependencias`) y paso a `estado:listo`.
- Desglose creado, todo `estado:listo`:
  - #767 ADR de testing MCP (depende de #761)
  - #768 `/scaffold-mcp` + `mcp-scaffolder` fase 1: proyecto + unit tests + endpoints de gate (depende de #761, #767)
  - #769 fase 2: Terraform + workflow de deploy (depende de #768)
  - #770 fase 3: SmokeTests + reusable de smoke (depende de #767, #769)
  - #771 doctrina del planner publicado: composicion asistida (depende de #761)
- Orden de batch sugerido para `/mefisto-sequential`: 761 -> 767 -> 768 -> 769 -> 770 -> 771 (771 puede ir en cualquier punto despues de 761).
- Los numeros de ADR se fijan al implementar ("siguiente numero libre"), para no colisionar con PRs paralelos.

## Descartado

- Issue de registro de rutas en los gates: innecesario (ver Descubrimientos).
- Extender `smoke-tests-dominio.yml` en vez de reusable propio: ya descartado en el piloto (contaminaria con OIDC a 4 invocadores).
- Un Agent Skill `skills/mcp/` con la doctrina para implementers: prematuro; se reevalua cuando exista el segundo servidor MCP (Mcp.Comandos) y la doctrina duela en la practica (MEF-ADR-0018).

## Preguntas abiertas

- Si el ADR de testing debe ademas enmendar el control de cambios de MEF-ADR-0013 o solo citarlo: decision del writer de #767.
- Extraccion del warmup version+ready compartido entre reusables: esperar la tercera aparicion (Mcp.Comandos), ya anotado en ambos issues.

## Referencias

Issues creados: #767, #768, #769, #770, #771. Refinado: #761 (borrador -> listo, retitulado).
Evidencia del piloto: Bitakora.ControlAsistencia #502/#508/#509/#516, PR #518; comentario issuecomment-5469925919 en #761.

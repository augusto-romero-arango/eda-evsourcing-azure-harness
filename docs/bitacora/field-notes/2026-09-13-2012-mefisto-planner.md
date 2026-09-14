---
fecha: 2026-09-13
hora: 20:12
sesion: mefisto-planner
tema: Refinamiento del retiro de WEBSITE_USE_PLACEHOLDER_DOTNETISOLATED
---

## Contexto
Se solicito refinar el draft #1276, creado desde el consumidor
`augusto-romero-arango/Bitakora.ControlAsistencia` tras investigar un crash de
arranque de Azure Functions y retirar localmente un app setting que Mefisto
seguia generando y diagnosticando como obligatorio.

## Descubrimientos
- El setting aparece exactamente en dos componentes publicados: el HCL inline
  del modulo `function-app` de `agents/infra-base-scaffolder.md` y el checklist
  de deploy de `agents/bug-investigator.md`.
- MEF-ADR-0020 proscribe Consumption `Y1` y fija planes Linux dedicados Basic o
  superiores, mientras la referencia oficial de Azure Functions acota el
  setting a una optimizacion de cold start de Consumption.
- Un miembro del equipo de Azure Functions confirmo en
  Azure/azure-functions-host#10445 que la plataforma establece el setting y no
  requiere accion del usuario.
- El codigo del host consulta el flag en
  `WebHostRpcWorkerChannelManager.UsePlaceholderChannel()` durante la
  especializacion del worker placeholder.
- El issue equivalente del consumidor, #677, ya fue aplicado exitosamente; no
  hay evidencia de que el setting causara el crash que origino la
  investigacion.

## Decisiones
- Se refino #1276 como correccion del lado publicado, con
  `infra-base-scaffolder` como componente principal y `bug-investigator` como
  ajuste secundario de coherencia.
- Se mantuvieron ambos agentes en un solo issue: retirar la emision sin corregir
  el triage, o viceversa, dejaria contradictorio el contrato publicado; el
  cambio completo sigue siendo homogeneo, de cinco CAs y menor a 30 minutos.
- Se agrego el label `bug` porque Mefisto emite y exige una configuracion que no
  debe administrar manualmente, aclarando que no es un fix del crash del
  consumidor.
- Los ADRs aplicables son MEF-ADR-0019, MEF-ADR-0020 y MEF-ADR-0021. No se
  requiere enmendar ninguno.
- El cambio debe dejar una explicacion con fuentes junto al HCL emitido y anotar
  la remocion mediante `changelog.d/1276.removed.md`.

## Descartado
- Dividir el ajuste en dos issues, uno por agente: agregaria una dependencia y
  permitiria deriva temporal sin reducir de forma util la complejidad.
- Presentar el retiro como solucion de estabilidad o cold start en planes
  dedicados: la investigacion no aporta esa evidencia.
- Modificar agentes internos o adaptadores de runtime: ambos componentes son
  publicados y no tienen equivalente interno aplicable a infraestructura
  Azure del consumidor.

## Preguntas abiertas
Ninguna.

## Referencias
Draft refinado: #1276 — Retirar WEBSITE_USE_PLACEHOLDER_DOTNETISOLATED del
scaffolding y triage de Functions.

Issues creados: ninguno.

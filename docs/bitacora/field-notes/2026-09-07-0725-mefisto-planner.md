---
fecha: 2026-09-07
hora: 07:25
sesion: mefisto-planner
tema: Refinamiento de la semantica HTTP de comandos
---

## Contexto

Se refino el draft #849, originado en Bitakora.ControlAsistencia, que detecto que el `202 Accepted`
universal del harness contradice el flujo real: el endpoint espera `ICommandRouter.InvokeAsync` y el
middleware de Wolverine/Marten confirma la transaccion antes del retorno. El borrador mezclaba la
decision arquitectonica con su propagacion a cuatro ADRs, cinco agentes y dos skills.

## Descubrimientos

- La pregunta decidible no es si existen efectos downstream asincronos, sino si el cambio primario
  solicitado por el endpoint termino y quedo durable antes de responder.
- La materializacion eventual de una proyeccion `Async` no convierte el commit sincronico del
  write-side en `202`; un `Location` puede identificar la URI canonica aunque el GET requiera polling.
- `agents/mcp-scaffolder.md` ya consume HTTP mediante `EnsureSuccessStatusCode()` y no fija `202`.
- `agents/domain-scaffolder.md` no genera endpoints HTTP de comando de ejemplo; no necesita ripple.
- `commands/install-apim.md` y `commands/install-auth.md` si conservaban un `202 Accepted` fijo en sus
  checklists post-deploy, un alcance ausente del draft original.

## Decisiones

- #849 queda como issue fundacional, listo y limitado a MEF-ADR-0004.
- La propagacion se parte por componente para respetar el limite de seis CAs, un componente principal
  y una pasada menor a 30 minutos.
- Los ADRs se encadenan #849 -> #990 -> #991 -> #992. Los agentes y skills dependen de la fuente
  doctrinal que consumen y llevan `bloqueado` mientras esa dependencia siga abierta.
- Todos los issues de esta cadena llevan `tipo:tooling`, `estado:listo` y `bug` porque corrigen una
  premisa observable del harness, no agregan dominio ni runtime nuevo.
- La respuesta de PUT/DELETE cuando el estado ya esta alcanzado permanece separada en el draft #850:
  es semantica de no-op, no seleccion del codigo del camino de exito completado.

## Descartado

- Mantener #849 como megaissue: excedia componentes y tiempo de una pasada.
- Modificar `mcp-scaffolder` o `domain-scaffolder`: la inspeccion no encontro el supuesto universal.
- Ampliar el cambio al soporte APIM de PUT/DELETE: el checklist puede probar un POST real y ese soporte
  tiene otra motivacion y alcance.
- Introducir Result Pattern: el endpoint puede elegir el `IActionResult` contractual despues del router.

## Preguntas abiertas

- Refinar #850 y decidir su propia cadena de propagacion sobre no-ops idempotentes.
- Antes de ejecutar toda la cadena como batch, usar `/mefisto-next-order`; las dependencias declaradas
  son la unica fuente de verdad del orden.

## Referencias

Issues creados: #990, #991, #992, #993, #994, #995, #997, #998, #999, #1000.

Draft refinado: #849.

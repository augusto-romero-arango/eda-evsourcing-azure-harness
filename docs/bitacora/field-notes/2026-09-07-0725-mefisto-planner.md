---
fecha: 2026-09-07
hora: 07:25
sesion: mefisto-planner
tema: Refinamiento de codigos de exito y no-ops HTTP de comandos
---

## Contexto

Se refinaron los drafts #849 y #850, originados en Bitakora.ControlAsistencia. #849 detecto que el `202 Accepted`
universal del harness contradice el flujo real: el endpoint espera `ICommandRouter.InvokeAsync` y el
middleware de Wolverine/Marten confirma la transaccion antes del retorno. El borrador mezclaba la
decision arquitectonica con su propagacion a cuatro ADRs, cinco agentes y dos skills.

#850 partia de una segunda divergencia: PUT/DELETE sobre un estado ya alcanzado recibian exito, 404 o
409 segun el precedente local. Se refino despues de separar el no-op exitoso de una identidad
desconocida, una precondicion incumplida y una regla de negocio real.

## Descubrimientos

- La pregunta decidible no es si existen efectos downstream asincronos, sino si el cambio primario
  solicitado por el endpoint termino y quedo durable antes de responder.
- La materializacion eventual de una proyeccion `Async` no convierte el commit sincronico del
  write-side en `202`; un `Location` puede identificar la URI canonica aunque el GET requiera polling.
- `agents/mcp-scaffolder.md` ya consume HTTP mediante `EnsureSuccessStatusCode()` y no fija `202`.
- `agents/domain-scaffolder.md` no genera endpoints HTTP de comando de ejemplo; no necesita ripple.
- `commands/install-apim.md` y `commands/install-auth.md` si conservaban un `202 Accepted` fijo en sus
  checklists post-deploy, un alcance ausente del draft original.
- RFC 9110 seccion 9.2.2 define idempotencia por igualdad del efecto pretendido y aclara que la
  respuesta puede diferir. El exito estable ante un no-op es una convencion deliberada de Mefisto,
  respaldada por el experto, no una obligacion del RFC.
- El no-op no necesita un tipo `SinCambios`: los aggregates ya admiten guard clauses y metodos `void`.
  Retornar antes de agregar eventos, completar el handler sin excepcion y responder el exito
  contractual conserva la arquitectura vigente.
- El harness de testing ya expresa cero efectos sin API nueva: `Then()`/`Then(streamId)` compara count
  exacto cero y los asserts de publicacion con parametros vacios exigen que nada se haya publicado.

## Decisiones

- #849 queda como issue fundacional, listo y limitado a MEF-ADR-0004.
- La propagacion se parte por componente para respetar el limite de seis CAs, un componente principal
  y una pasada menor a 30 minutos.
- Los ADRs se encadenan #849 -> #990 -> #991 -> #992. Los agentes y skills dependen de la fuente
  doctrinal que consumen y llevan `bloqueado` mientras esa dependencia siga abierta.
- Todos los issues de esta cadena llevan `tipo:tooling`, `estado:listo` y `bug` porque corrigen una
  premisa observable del harness, no agregan dominio ni runtime nuevo.
- La respuesta de PUT/DELETE cuando el estado ya esta alcanzado se mantuvo separada en #850: es
  semantica de no-op, no seleccion del codigo del camino de exito completado.
- #850 queda listo, bloqueado por #849 y limitado a MEF-ADR-0004. Fija retorno normal + cero eventos
  y cero publicaciones cuando la identidad/alcance existe y la intencion ya esta satisfecha.
- La propagacion de #850 se encadena sobre la de #849: #1003 (MEF-ADR-0043), #1004 (MEF-ADR-0011),
  #1005 (MEF-ADR-0013), #1006 (planner), #1007 (test-writer), #1008 (implementer), #1009
  (smoke-test-writer) y #1010 (reviewer).

## Descartado

- Mantener #849 como megaissue: excedia componentes y tiempo de una pasada.
- Modificar `mcp-scaffolder` o `domain-scaffolder`: la inspeccion no encontro el supuesto universal.
- Ampliar el cambio al soporte APIM de PUT/DELETE: el checklist puede probar un POST real y ese soporte
  tiene otra motivacion y alcance.
- Introducir Result Pattern: el endpoint puede elegir el `IActionResult` contractual despues del router.
- Presentar como mandato del RFC que dos requests idempotentes devuelvan el mismo status: el RFC dice
  explicitamente que la respuesta puede cambiar.
- Imponer `SinCambios` como protocolo aggregate-handler: agrega un tipo sin necesidad observable y
  tensiona la decision vigente de no adoptar Result Pattern.
- Reescribir en #850 los conflictos reales como 409 sin evento: MEF-ADR-0004 ya separa precondiciones
  del handler y reglas del aggregate; el no-op no reabre esa frontera.

## Preguntas abiertas

- Ninguna sobre el alcance de #849/#850. Antes de ejecutar la cadena como batch se usara
  `/mefisto-next-order`; las dependencias declaradas son la unica fuente de verdad del orden.

## Referencias

Issues creados: #990, #991, #992, #993, #994, #995, #997, #998, #999, #1000, #1003,
#1004, #1005, #1006, #1007, #1008, #1009, #1010.

Drafts refinados: #849, #850.

---
fecha: 2026-10-03
hora: 09:25
sesion: mefisto-planner
tema: Refinamiento de #1803 (eventos publicados sin ruta de salida en Wolverine)
---

## Contexto
Refinar el draft #1803, capturado desde Bitakora.ControlAsistencia tras el segundo incidente de un evento publicado sin `PublicarEventoServerless<T>`, descartado en silencio.

## Descubrimientos
- La causa raiz del harness es que `agents/implementer.md` afirma que el domain-scaffolder genera el registro de enrutamiento y que el implementer "no lo toca". La plantilla solo trae comentarios-guia: el registro es por evento (MEF-ADR-0024 #7).
- El test de composicion protege `TiposPersistidos`, pero no hay guardrail sobre la salida de los eventos.
- Los gates del reviewer sobre la composicion solo se disparan si el diff la toca, que es el caso opuesto al de la falla.

## Decisiones
- Partir el draft en 4 issues de un componente cada uno: #1803 (implementer, raiz), #1804 (guardrail del scaffold, absorbe la investigacion e), #1805 (gate del reviewer) y #1806 (campo Ruta de salida en el DoR del planner).
- #1804 y #1805 dependen de #1803 y quedan con el label `bloqueado`.

## Descartado
- El check del test de composicion contra `topics_config` de Terraform: fuera de alcance de #1804, por acoplamiento.

## Preguntas abiertas
- Si `IPrivateEventSender` de Cosmos.EventDriven ofrece un modo estricto (lo resuelve el CA-1 de #1804).

## Referencias
Issues creados: #1804, #1805, #1806. Refinado: #1803.

---
fecha: 2026-07-15
hora: 12:33
sesion: mefisto-planner
tema: Desglose del epico de colas de Service Bus con sesion (fan-in) — issue #269
---

## Contexto
Llego un draft cross-repo (#269) desde el consumidor `Cosmos-SincoERP/Cosmos.ControlPlane`
(@luisfelipediaz) proponiendo que el harness soporte colas de Azure Service Bus con sesion
como primitiva de primera clase, junto a la doctrina "topic (fan-out) vs queue con sesion
(fan-in / serializacion por clave)". El draft venia muy completo (doctrina, CA-1..CA-5, ADRs
aplicables, sustento en doc oficial verificada, 3 decisiones del mantenedor pendientes) pero
era un EPICO que tocaba 5 agentes + un ADR nuevo + cross-refs. Se pidio evaluar el desglose
critico antes de crear/editar nada.

## Descubrimientos
- El draft #269 llego SIN labels (los drafts cross-repo no traen `estado:borrador` automatico).
- Verificado contra codigo real que el gap es genuino:
  - Infra: el modulo `service-bus` (infra-base-scaffolder.md:374-487) solo modela topics +
    subscriptions via `topics_config`; no hay `azurerm_servicebus_queue`, `requires_session`
    ni `forward_to`. infra-writer/infra-reviewer tampoco los conocen (reviewer solo valida
    "Standard/Premium para topics", linea 46).
  - Endpoint: implementer.md:276-336 y domain-scaffolder.md:458-475 solo scaffoldean
    `[ServiceBusTrigger("<topic>","<subscription>")]`; sin `IsSessionsEnabled`, sin trigger de
    queue de un argumento, sin `switch` por `message.Subject`.
  - Productor: la capacidad `PublishAsync(groupId, ...)` YA existe en el paquete externo
    `Cosmos.EventDriven.Abstractions` (el DSL de test la modela: harness-cheatsheet.md:160-169),
    pero los agentes nunca ensenan CUANDO fijar `groupId` (implementer.md:134,183 publican sin el).
    El gap de CA-4 es de GUIA de agente, no de capacidad.
- Interaccion no obvia con ADR-0006: una Function de fan-in no tiene un unico estimulo (convergen
  N eventos), asi que se DESVIA del patron `AccionCuandoEstimulo`. Esto obligo a sumar ADR-0006
  al set de cross-refs y a documentar la desviacion en ADR-0026.

## Decisiones
- Desglose en 4 issues secuenciales/paralelos en vez de un solo pipeline:
  - (a)=#269 repurposed (ADR-0026 + cross-refs; se fundio CA-5 aqui). Fundacional.
  - (b)=#270 capa de infra (3 agentes IaC, issue homogeneo de un eje).
  - (c)=#271 endpoint con trigger de sesion + switch por Subject.
  - (d)=#272 guia del productor (invariante groupId <-> requires_session).
- #269 se REPURPOSE (no se cierra): la doctrina del planner prohibe issues-contenedor, asi que
  #269 pasa a ser un issue concreto de un solo scope (el ADR), preservando su "## Origen".
- Grafo: Ola 1 = #269; Ola 2 = #270 y #271 en paralelo (archivos disjuntos); Ola 3 = #272 tras
  #271 (ambos tocan `agents/implementer.md` -> secuencial obligado).
- 3 decisiones del mantenedor resueltas:
  1. ADR-0026, titulo "Colas de Service Bus con sesion para fan-in y serializacion por clave de
     agregado" (0026 = siguiente libre verificado).
  2. Naming del queue: reconciliacion A+B — "queue kebab-case = nombre de la Function que lo
     consume", con la Function nombrada por la CONVERGENCIA del flujo (yield natural tipo opcion B),
     desviacion de ADR-0006 documentada.
  3. Subscriptions con forward: mantener `{consumidor}-escucha-{productor}` sin tocar (ADR-0001;
     el issue #252 que proponia simplificar ya fue evaluado y descartado el 2026-07-10).
- CA-4 reformulado: el edit real de `CreateAdminUserCommandHandler` es tarea DOWNSTREAM del
  consumidor; el harness solo ensena la invariante.

## Descartado
- Cerrar #269 como contenedor: descartado en favor de repurpose (evita perder el "## Origen").
- Sub-partir (b) en b1 (contrato del modulo) + b2 (writer+reviewer): descartado por
  sobre-particion; el contrato HCL y su uso/validacion son cohesivos y deben aterrizar juntos.
- Fusionar (c)+(d): descartado; se dejan separados-secuenciales por trazabilidad 1:1 con CA-3/CA-4
  y por el matiz cross-repo de CA-4.
- Reabrir #252 (naming de subscriptions): descartado — decision ya tomada.

## Preguntas abiertas
- La firma exacta de `IPrivateEventSender.PublishAsync(groupId, ...)` solo se verifico
  indirectamente (via el DSL de test); vive en el paquete externo. Confirmar al implementar (d).
- El cierre del workaround en `CreateAdminUserCommandHandler` requiere un draft en el consumidor
  (`Cosmos.ControlPlane`); no se creo en esta sesion (fuera de scope del harness).

## Referencias
Issues creados/refinados:
- #269 (refinado, repurposed) — Fijar ADR-0026 [tipo:tooling, estado:listo]
- #270 (creado) — Capa de infra: queues con sesion + forward [tipo:tooling, estado:listo, bloqueado]
- #271 (creado) — Endpoint trigger de sesion + switch por Subject [tipo:tooling, estado:listo, bloqueado]
- #272 (creado) — Guia del productor: invariante groupId <-> requires_session [tipo:tooling, estado:listo, bloqueado]

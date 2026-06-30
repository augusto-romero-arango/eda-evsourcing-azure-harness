---
fecha: 2026-06-30
hora: 12:49
sesion: mefisto-planner
tema: Diagnostico del backlog + refinamiento de la cadena de dos namespaces ASB y creacion de drafts de gaps
---

## Contexto

Sesion larga de planeacion sobre el backlog del propio Mefisto, centrada en la cadena
de issues de la topologia de dos namespaces de Azure Service Bus (ADR-0023). Arranco como
un diagnostico del backlog ("revisar el plan de implementacion de los issues existentes")
y evoluciono a traves de varias tareas: refinar issues gateados al cerrarse sus
dependencias, incorporar el veredicto de un spike, crear drafts para gaps detectados por
una investigacion, y refinar esos drafts a estado:listo.

## Descubrimientos

- **Flujo iterativo vs scaffold inicial**: la cadena #128/#130/#131 cubrio el provisioning
  + publish del SCAFFOLD INICIAL, pero el flujo ITERATIVO (un dominio que gana su primer
  evento publico DESPUES del scaffold, via `implementer.md`) quedo sin cubrir. #130 fue
  explicito en NO tocar `implementer.md`. De ahi salieron los gaps G1/G2/G4.
- **Wiring real de dos namespaces** (verificado en spike #129, cerrado positivo): NO son
  "dos calls a `HabilitarAzureServiceBusParaServerLess`" (como decia ADR-0003 L79/L108),
  sino `HabilitarAzureServiceBusParaServerLess(interno)` (broker default) +
  `AgregarAzureServiceBusNombradoServerless("integracion", integracion)` (named broker).
- **Caveat del helper bulk**: `PublicarEventosServerless(..., Assembly)` filtra por
  `IsAssignableTo(typeof(IEvent))` -> captura privados Y publicos; usarlo con el assembly
  completo rompe la separacion de namespaces. El registro debe ser por tipo.
- **Nombres reales tras #130** (anclados a main): modulos `service_bus_interno` /
  `service_bus_integracion`; app settings `SERVICE_BUS_CONNECTION_INTERNO` /
  `SERVICE_BUS_CONNECTION_INTEGRACION`; RBAC Data Sender del productor lo agrega el
  `domain-scaffolder` por dominio, no el implementer.
- **Lado consumo**: el paquete `Cosmos.EventDriven.CritterStack.AzureServiceBus` NO expone
  helper de listen (el de RabbitMQ si). El consumo es `[ServiceBusTrigger]` de Azure
  Functions, independiente del registro de brokers de Wolverine. El connection string
  huerfano (`ServiceBusConnectionString` vs `SERVICE_BUS_CONNECTION`) resulto ser solo
  higiene de doc (no bug desplegado), verificado contra ControlAsistencia.
- La clase base `ServiceBusEndpointBase` NO define el `[ServiceBusTrigger]`: el `Connection`
  vive en el endpoint concreto.

## Decisiones

- **#147 (G2b) -> Rama A**: el consumo via `[ServiceBusTrigger]` eligiendo app setting por
  origen del topic es SUFICIENTE. SIN listen helper en Cosmos.BuildingBlocks, SIN draft
  cross-repo, SIN ADR nuevo. La propuesta de particion del issue quedo descartada.
- **Desglose de G2**: G2a (higiene de doc del ejemplo de trigger, prioridad baja, sin label
  bug) + G2b (diseno del consumo dual). G3 y G5 absorbidos como notas dentro de G2b.
- **Secuenciacion de implementacion**: #146 y #147 tocan ambos `implementer.md` y comparten
  el nombre de app setting -> secuenciar, no paralelo. #145 y #148 pueden ir en paralelo.
- **#147 aplicado a estado:listo** (con confirmacion directa del usuario).

## Descartado

- Re-inflar G2a a bug (era higiene de doc, no bug desplegado).
- Draft cross-repo a Cosmos.BuildingBlocks por un listen helper (Rama A lo hace innecesario).
- Particion de #147 en issue padre + hijo (Rama A lo vuelve coherente como issue unico).
- Crear issue epic/contenedor para la cadena (relacion solo via ## Dependencias).

## Preguntas abiertas

- Coherencia operativa entre #146 y #147 al mergear: ambos deben usar exactamente
  `SERVICE_BUS_CONNECTION_INTERNO` en el ejemplo de trigger; verificar al implementar.
- Orquestacion codigo<->infra del topic (CA-6 de #145): Wolverine SendInline no
  auto-provisiona; el topic debe existir en Terraform antes del publish. Documentar al
  cerrar #145.

## Referencias

Issues refinados/aplicados en esta sesion (cuerpos en el scratchpad de la sesion):
- #145 (G1) Actualizar implementer para enrutar topics al namespace ASB correcto -> estado:listo
- #146 (G2a) Corregir el ejemplo de ServiceBusTrigger en implementer.md -> estado:listo
- #147 (G2b) Disenar el wiring del lado consumidor para dos namespaces ASB -> estado:listo (Rama A, aplicado en esta sesion)
- #148 (G4) Corregir el wiring de dos namespaces en ADR-0003 -> estado:listo

Issues de la cadena previa (mergeados antes de esta sesion): #128, #130, #131, #135; spike #129 cerrado positivo.
Investigacion origen: docs/bitacora/field-notes/2026-06-30-1120-mefisto-investigation.md

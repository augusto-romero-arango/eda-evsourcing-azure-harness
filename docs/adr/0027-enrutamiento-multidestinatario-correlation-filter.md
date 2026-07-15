# ADR-0027: Enrutamiento multi-destinatario de un evento por correlation filter de igualdad

- **Fecha**: 2026-07-15
- **Estado**: aceptado
- **Aplica a**: doctrina de mensajeria del marco; complementa ADR-0001 (no lo reemplaza) con una excepcion gobernada al rechazo de filtros SQL; cross-referencia ADR-0001, ADR-0024, ADR-0025 y ADR-0026 (advertencia sobre no reusar `SessionId`). Gobierno futuro de `infra-base-scaffolder`/`infra-writer`/`infra-reviewer` (infraestructura, diferido) e `implementer` (guia del productor, diferido).

## Contexto

ADR-0001 fija topic-por-tipo-de-evento como topologia por defecto y descarta explicitamente los
filtros SQL "por complejidad operativa": si un consumidor se suscribe a un topic, quiere **todos**
los mensajes de ese topic; sin filtros SQL, la topologia es completamente declarativa
(`docs/adr/0001-service-bus-topics-por-evento.md:15-26,57-61`). Ese rechazo razona sobre un eje
concreto: **varios tipos de evento** conviviendo en un topic de dominio, filtrados por **tipo** con
SQL.

Existe un eje distinto que ADR-0001 no contemplo: un **unico** evento publico (`IPublicEvent`)
que debe llegar a **N destinatarios** distintos, donde cada uno solo quiere su subconjunto -- no
varia el tipo de evento, varia el **destinatario**. Precedente que origina este ADR: el
aprovisionamiento de subscriptions al ApplicationPlane por request-reply del consumidor
`Cosmos-SincoERP/Cosmos.ControlPlane` (issue #22 de ese repo; contrato relacionado issue #61), donde
un evento de aprovisionamiento debe llegar a varios bounded contexts, cada uno interesado solo en
las instancias dirigidas a el.

Sin una primitiva de enrutamiento, la alternativa es que cada destinatario se suscriba al topic
completo y descarte en su handler los mensajes que no le corresponden: Service Bus factura por
operacion, no por entidad, asi que cada mensaje descartado ya consumio una entrega y un ciclo de
procesamiento en el consumidor, y el filtrado real queda enterrado en codigo de aplicacion en vez
de ser visible en la infraestructura.

Azure Service Bus resuelve este eje con **correlation filters**: matchean propiedades del mensaje
(de sistema o definidas por el usuario) por **igualdad exacta**, combinando varias condiciones con
AND si se especifica mas de una propiedad; ademas, ningun filtro (SQL o correlacion) evalua el
body del mensaje. Microsoft Learn los recomienda explicitamente sobre los filtros SQL: "Whenever
possible, applications should choose correlation filters over SQL-like filters because they're
much more efficient in processing and have less impact on throughput" y confirma que "All filters
evaluate message properties. Filters can't evaluate the message body" [1]. Esto encaja con
ADR-0024: el evento publico, plano y portable, ya viaja con propiedades en el sobre (application
properties), separadas del body.

La plataforma soporta esto en Terraform: `azurerm_servicebus_subscription_rule` (provider AzureRM)
acepta `filter_type = "CorrelationFilter"` con un bloque `correlation_filter` cuyo atributo
`properties` es un mapa de propiedades de usuario (soportado desde el provider 2.30.0; el bloque
exige al menos una propiedad) [2]. El recurso ARM subyacente
(`Microsoft.ServiceBus/.../subscriptions/rules`, API 2024-01-01) declara el mismo campo
`properties` en su objeto `CorrelationFilter` [3]. La topologia resultante -- un topic + N
subscriptions, cada una con su correlation filter -- sigue siendo completamente declarativa y
visible en Terraform, igual que exige ADR-0001: el filtro de cada destinatario se lee en su
subscription, sin cruzar a codigo de aplicacion.

ADR-0026 (issue #269) fijo el patron a seguir cuando un eje nuevo de la topologia de mensajeria no
encaja en ADR-0001: doctrina en un ADR nuevo, con una cross-referencia minima de vuelta a ADR-0001
que acota su absoluto sin reabrirlo, en vez de reformar ADR-0001 en profundidad. Este ADR sigue el
mismo patron, con la advertencia adicional de ADR-0026: la clave de enrutamiento de este ADR **no
debe conflacionarse** con `SessionId`, reservado para la serializacion de fan-in de ADR-0026 -- son
mecanismos distintos aunque ambos operen sobre application properties.

## Decision

### 1. Un eje distinto al que ADR-0001 rechazo: filtrar por destinatario, no por tipo

ADR-0001 rechaza filtros SQL para el eje "varios tipos de evento en un topic de dominio, filtrar
por tipo". Este ADR fija la primitiva para un eje distinto: "**un unico** tipo de evento publicado
a **N destinatarios**, filtrar por **destinatario**". La topologia sigue siendo un topic + N
subscriptions -- ADR-0001 no cambia: el productor sigue publicando unicamente a topics. Lo nuevo es
que cada subscription destinataria puede llevar un **correlation filter de igualdad** sobre una
clave de enrutamiento.

### 2. Clave de enrutamiento: application property de igualdad, nombrada por el flujo

La clave de enrutamiento es una **application property string**, estampada por el productor al
publicar el evento, matcheada por **igualdad exacta** en el correlation filter de cada subscription
destinataria. Su nombre lo decide el flujo concreto (por ejemplo `destinatarioId`, `tenantId`,
segun el dominio) -- este ADR fija el **mecanismo**, no el nombre de una propiedad concreta; no
hardcodea `bundleId` ni ningun otro nombre. El valor no es un secreto (ver decision #6).

### 3. Solo igualdad -- el rechazo de filtros SQL de ADR-0001 no se toca

Este ADR **no** habilita filtros SQL. El unico mecanismo que fija es el correlation filter
(igualdad exacta, AND si hay varias propiedades) [1]. Una condicion que exija algo distinto a
igualdad (rangos, `LIKE`, OR entre propiedades) queda fuera de esta doctrina y no la habilita un
correlation filter: sigue cayendo, sin excepcion, bajo el rechazo de ADR-0001.

### 4. Construccion exclusiva del lado consumidor; el productor no cambia de contrato

Igual que el queue con sesion de ADR-0026, el correlation filter es una construccion del **lado
consumidor**: cada destinatario declara su subscription con su propio filtro; el productor no
decide ni conoce los filtros de sus consumidores. El productor sigue publicando al topic sin
cambio de contrato (ADR-0001/ADR-0024); su unica obligacion nueva es **estampar la clave de
enrutamiento como application property** al publicar, porque los filtros no evaluan el body [1] --
si la clave solo viviera en el body, ningun correlation filter podria verla.

### 5. No confundir la clave de enrutamiento con `SessionId`

ADR-0026 reserva `SessionId` (el `groupId` de `IPrivateEventSender`) para la serializacion de
fan-in por clave de aggregate. La clave de enrutamiento de este ADR es una propiedad de usuario
**distinta**, con un proposito distinto (seleccion de destinatario, no serializacion de escritura
concurrente). Un flujo podria necesitar ambas a la vez -- un evento con clave de enrutamiento hacia
varios destinatarios, y alguno de ellos resolviendo ademas fan-in -- son ortogonales y no deben
compartir la misma propiedad.

### 6. La clave de enrutamiento no es un secreto

Alineado con ADR-0025: la clave de enrutamiento es un dato de **negocio** (identificador de
destinatario, tenant, etc.), no una credencial ni una key. No se custodia en Key Vault; se
documenta en claro en el flujo (YAML de `docs/eda/flows/`, comentarios de Terraform) como
cualquier otro dato de negocio del evento. Se deja explicito para evitar que un agente la trate por
error como secreto, dado el vocabulario compartido ("clave") con las claves de cifrado.

## Alternativas consideradas

### Alt 1: cada destinatario se suscribe al topic completo y descarta en el handler

**Descartada**: mueve el filtrado a codigo de aplicacion, invisible desde la infraestructura --
contradice el principio de ADR-0001 de que la topologia completa (quien consume que) se lee en
Terraform. Ademas cada mensaje descartado ya facturo una operacion de entrega y el tiempo de
computo del handler que lo descarta.

### Alt 2: filtro SQL por destinatario

Usar `SqlFilter` con una expresion (`destinatarioId = 'x'`) en vez de un correlation filter.

**Descartada**: el correlation filter cubre el mismo caso -- igualdad exacta sobre una propiedad --
de forma "much more efficient" segun Microsoft Learn [1], sin pagar el costo de procesamiento de
un SQL filter. No hay necesidad de la generalidad de SQL para un match de igualdad; adoptarlo
reabriria el rechazo de ADR-0001 sin beneficio real.

### Alt 3: un topic por destinatario en vez de un topic + N subscriptions filtradas

El productor publica a un topic distinto por cada destinatario.

**Descartada**: rompe la invariante de ADR-0001 de que cada tipo de evento tiene **un** topic, y
obligaria al productor a conocer de antemano cuantos y cuales destinatarios existen -- agregar un
destinatario nuevo exigiria cambiar al productor (un topic nuevo), en vez de ser una construccion
exclusiva del lado consumidor (decision #4). Un topic + N subscriptions permite agregar
destinatarios sin tocar al productor, igual que ya vale para el caso simple de ADR-0001.

## Consecuencias

### Positivas

- **Cierra un vacio real de la doctrina**: ADR-0001 no tenia una respuesta declarativa para "un
  evento, N destinatarios, cada uno con su subconjunto" -- la alternativa era filtrado en codigo de
  aplicacion (Alt 1).
- **No reabre el rechazo de filtros SQL**: el mecanismo sigue siendo estrictamente de igualdad;
  ADR-0001 mantiene su rechazo de SQL intacto para cualquier caso que exija mas que igualdad.
- **Topologia visible en Terraform**: el filtro de cada destinatario se lee en su subscription
  (`azurerm_servicebus_subscription_rule`), sin codigo de aplicacion oculto.
- **Sin ambiguedad con ADR-0026**: se documenta explicitamente que la clave de enrutamiento y
  `SessionId` son mecanismos distintos, para que ningun agente los conflacione.

### Negativas

- **Nueva superficie de nombres a coordinar**: cada flujo elige su propia clave de enrutamiento
  (decision #2); sin una convencion de nombre unico, dos flujos podrian nombrar la misma nocion de
  forma distinta. Se acepta como costo menor frente a hardcodear un nombre que no aplicaria a todos
  los dominios.
- **El escape-hatch `SqlFilter` sigue latente en el modulo `service-bus` de
  `infra-base-scaffolder`**: el campo `sub.filter` que el modulo ya expone hoy emite, sin
  excepcion, `filter_type = "SqlFilter"` -- el unico mecanismo de filtro que el modulo conoce. Este
  ADR fija la doctrina de cuando usar un correlation filter, pero no cambia todavia ese modulo (ver
  "Trabajo diferido"): hasta que se implemente, nada impide tecnicamente configurar un `SqlFilter`
  a mano donde este ADR exigiria un correlation filter.

### Trabajo diferido

- **Infraestructura** (issue b del epico, bloqueado por este ADR): extender el modulo `service-bus`
  de `infra-base-scaffolder` (y `infra-writer`/`infra-reviewer`) para declarar subscriptions con
  correlation filter (`filter_type = "CorrelationFilter"`, bloque `correlation_filter.properties`),
  reconciliando el escape-hatch `SqlFilter` latente descrito en "Consecuencias > Negativas": el
  modulo debe dejar de ser el unico camino de filtro y `infra-reviewer` debe senalar (o restringir)
  un `SqlFilter` configurado donde el eje es enrutamiento por destinatario.
- **Guia del productor** (issue c del epico, bloqueado por este ADR): documentar en
  `agents/implementer.md` como estampar la clave de enrutamiento como application property al
  publicar con `IPublicEventSender`, y la advertencia de no conflacionarla con `groupId`/
  `SessionId` (ADR-0026).

## Referencias

- **[1]** "Topic filters and actions" -- Microsoft Learn. Correlation filters matchean propiedades
  de sistema y de usuario por igualdad exacta (AND si hay varias); "Whenever possible, applications
  should choose correlation filters over SQL-like filters because they're much more efficient in
  processing and have less impact on throughput"; "All filters evaluate message properties.
  Filters can't evaluate the message body".
  https://learn.microsoft.com/azure/service-bus-messaging/topic-filters#filters
- **[2]** `azurerm_servicebus_subscription_rule` -- Terraform Registry (provider `hashicorp/azurerm`).
  `filter_type = "CorrelationFilter"` con bloque `correlation_filter` (atributo `properties`, mapa
  de propiedades de usuario; el bloque exige al menos una propiedad); soporte de
  `correlation_filter.properties` agregado en la version 2.30.0 del provider.
  https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/servicebus_subscription_rule
- **[3]** "Microsoft.ServiceBus namespaces/topics/subscriptions/rules" (API 2024-01-01) -- Microsoft
  Learn. `CorrelationFilter.properties`: diccionario de propiedades de usuario para filtrado;
  `filterType` en {`CorrelationFilter`, `SqlFilter`}.
  https://learn.microsoft.com/azure/templates/microsoft.servicebus/2024-01-01/namespaces/topics/subscriptions/rules#property-values
- ADR-0001 (Service Bus: un topic por tipo de evento): este ADR acota, sin reemplazar, el rechazo
  de filtros SQL -- fija la excepcion gobernada del correlation filter de igualdad para el eje "un
  evento, N destinatarios", distinto del eje "varios tipos de evento" que ADR-0001 razono.
- ADR-0024 (modelo de eventos de bus, privado/publico): el evento publico cruza el backbone
  compartido; la clave de enrutamiento viaja en el sobre (application property), no en el body --
  coherente con la forma plana y portable de los eventos que cruzan el bus.
- ADR-0025 (custodia de secretos): la clave de enrutamiento no es un secreto ni una key; se
  documenta en claro, sin custodiarse en Key Vault.
- ADR-0026 (colas de Service Bus con sesion para fan-in): precedente del patron ADR-nuevo +
  cross-ref minima hacia ADR-0001; advierte no conflacionar la clave de enrutamiento de este ADR
  con `SessionId` (`groupId` de `IPrivateEventSender`), reservado para la serializacion de fan-in.
- issue #22 y #61 del consumidor `Cosmos-SincoERP/Cosmos.ControlPlane`: origen del caso real
  (aprovisionamiento de subscriptions al ApplicationPlane por request-reply) que motivo este ADR.

## Control de cambios

- 2026-07-15: creacion como `aceptado` (issue #275, draft cross-repo del consumidor
  `Cosmos-SincoERP/Cosmos.ControlPlane`). Fija la doctrina fundacional de enrutamiento
  multi-destinatario de un evento unico por correlation filter de igualdad. Es el issue fundacional
  de un epico de 3: bloquea a los issues (b) infraestructura y (c) guia del productor.

# MEF-ADR-0023: Bounded Context, namespace interno de Azure Service Bus y frontera publico/privado

- **Fecha**: 2026-06-26 (reformado 2026-07-01)
- **Estado**: aceptado
- **Aplica a**: doctrina de mensajeria del marco; gobierno de los agentes `implementer`, `test-writer`, `infra-base-scaffolder`, `domain-scaffolder` e `infra-writer`; flujo de integracion inter-bounded-context.

## Contexto

El marco crecio con varias decisiones de mensajeria parciales y sin una raiz estrategica que las unifique:

- MEF-ADR-0001 fija "un topic por tipo de evento" pero no dice **en que namespace** vive ese topic, ni que pasa cuando un evento debe cruzar de un grupo de dominios a otro.
- MEF-ADR-0020 fija "una Function App (dominio) por App Service Plan" pero no define la unidad de agrupacion superior al dominio.
- MEF-ADR-0012 ata la regla de serializacion del payload al marcador `IPublicEvent` (eje "alcance"), mezclando el eje "forma del payload" (rico vs plano) con el eje "alcance". Esa mezcla se puede desacoplar, pero solo si existe primero una doctrina que defina con precision que es "publico" y que es "privado".
- La distincion `IPublicEvent` / `IPrivateEvent` aparece en `agents/implementer.md` ("Donde vive cada tipo de evento") y `agents/test-writer.md` (seccion 6e), pero ningun ADR define la **topologia de infraestructura** que justifica esa distincion: a donde se publica un evento publico, quien se suscribe, como se aisla del trafico interno.

Sin esta raiz, cada decision satelite (MEF-ADR-0001, 0012, 0020) razona sobre un eje distinto sin un marco comun, y el lenguaje del harness ("publico", "privado", "dominio", "bounded context") es ambiguo.

## Decision

### 1. Bounded Context y dominio

**Bounded Context** (BC) = grupo de dominios relacionados, con su propio resource group de Azure.
**Dominio** = Function App (sin cambio respecto a MEF-ADR-0020: un App Service Plan por dominio sigue vigente; el BC es la unidad de agrupacion superior al dominio, materializada como resource group).

Un BC puede contener uno o varios dominios. Los dominios dentro de un mismo BC comparten contexto de negocio, lenguaje ubicuo y pueden comunicarse a traves de un bus interno; los dominios de BCs distintos se comunican unicamente a traves del backbone compartido del producto o, en el caso diferido, de la integracion externa (MEF-ADR-0024).

### 2. Un namespace interno de Azure Service Bus por Bounded Context

El BC provisiona **un** namespace de Azure Service Bus, compartido por todos sus dominios:

| Namespace | Proposito | Interfaz de publicacion |
|---|---|---|
| **Namespace interno** | Eventos privados intra-BC; mensajeria entre dominios del mismo BC | `IPrivateEventSender` |

La separacion entre trafico privado y publico es por **namespace** (no por convencion de naming dentro de un namespace unico): el namespace interno del BC no es visible ni alcanzable desde fuera del BC; ningun consumidor externo recibe credenciales/RBAC sobre el. Lo publico (evento consumido por un dominio de otro BC, decision #4) no vive en un namespace propio del productor: viaja por el **backbone compartido** del producto en el caso comun, o por integracion externa en el caso diferido — topologia y transporte que fija MEF-ADR-0024.

### 3. Todo lo que cruza un bus es plano y portable

Todo evento o comando que cruza un bus (namespace interno del BC, backbone compartido del producto, o integracion externa) contiene exclusivamente tipos serializables con el serializador por defecto de System.Text.Json: primitivos, `enum`, `string`, fechas (`DateOnly` / `DateTime` / `DateTimeOffset`), `Guid`, colecciones de esos tipos, y `record` DTO planos compuestos de lo anterior.

El modelo de dominio rico (value objects con campos privados, `ConfigurarSerializacion`, factory statics) vive **exclusivamente** en el event store de Marten, dentro del dominio productor. Al publicar, el handler traduce a una forma plana y portable antes de llamar a `IPublicEventSender` o `IPrivateEventSender`.

Esto **desacopla el eje de serializacion** (rico/plano) **del eje de alcance** (publico/privado): el criterio de "plano" pasa a ser "¿cruza un bus?", no "¿es `IPublicEvent`?". Ambas categorias de evento son planas; lo que las diferencia es el destino, no la forma del payload. La materializacion de este desacoplamiento en el texto de MEF-ADR-0012 es el trabajo de #122.

### 4. Publico vs privado = enrutamiento, no forma del payload

Un evento privado y uno publico tienen exactamente la misma exigencia de forma: plano y portable. Lo unico que los diferencia es el **destino**:

- `IPrivateEventSender` -> namespace interno del BC
- `IPublicEventSender` -> backbone compartido del producto (caso comun) o integracion externa (caso diferido) — MEF-ADR-0024

No existe una regla distinta de serializacion, ni un contrato de tipo diferente, entre eventos privados y publicos. La distincion es puramente de enrutamiento. Un `IPublicEvent` no es "mas plano" que un `IPrivateEvent`: ambos son planos porque ambos cruzan un bus.

### 5. Open Host Service + Published Language: el caso diferido de integracion externa entrante

El default del trafico publico inter-BC dentro del producto es el **backbone compartido** (MEF-ADR-0024): infra administra el namespace, el productor crea sus topics y cada BC consumidor crea su propia subscription. Open Host Service + Published Language [1] no es esa topologia por defecto; aplica al caso **diferido** en el que una aplicacion ajena al producto nos consume (hostear un namespace de integracion propio para ese consumidor externo). Sin casos hoy (MEF-ADR-0024).

Cuando ese caso se materialice:

- **El productor publica en SU namespace de integracion** y la aplicacion externa **se suscribe conectandose a el**. El productor nunca empuja a un ASB ajeno.
- El namespace de integracion del productor es el "host" que expone su Published Language [1]: el conjunto de topics y contratos de eventos que ese BC garantiza como superficie publica estable frente a esa aplicacion externa.
- La seguridad se logra **por topologia**: el namespace interno del BC no tiene ninguna asignacion de rol para entidades externas y no es alcanzable desde fuera del BC; el consumidor externo solo puede operar sobre el namespace de integracion que se hostea para el. Azure Service Bus no tiene acceso anonimo, por lo que cualquier consumidor externo necesita alguna credencial sobre ese namespace — pero el mecanismo exacto (RBAC fino a nivel de topic/subscription vs acceso mas grueso al namespace) es una **decision de la fase de integracion cross-BC**, explicitamente diferida junto con el Context Map (#131).
- **Recomendacion diferida** (a decidir al materializar la integracion cross-BC): el mecanismo de autorizacion recomendado es RBAC least-privilege por entidad — el productor con rol **Azure Service Bus Data Sender** sobre sus topics del namespace de integracion [2][3]; el consumidor externo con rol **Azure Service Bus Data Receiver** sobre la subscription que le corresponde [2][3]; roles asignados a nivel de topic/subscription, no de namespace. Esta decision se tomara al formalizar el Context Map (#131) y la infraestructura de identidades de los consumidores externos.

### Context Map: concepto diferido, no implementacion

El **Context Map** [1] (registro de las relaciones entre BCs, el backbone compartido al que se conectan y, en el caso diferido, los namespaces de integracion externos que hosteen) es el rumbo de evolucion del marco para declarar explicitamente que BCs existen, como se conectan al backbone y, si aplica, que namespaces de integracion exponen a consumidores externos. MEF-ADR-0023 lo nombra como direccion futura y lo fija como concepto; **su materializacion como configuracion** (`harness.config.json`, registro de BCs externos, extension del `infra-base-scaffolder`) queda **explicitamente diferida** a un issue posterior (#131 introduce el concepto de BC como primer eslabon de esa cadena; MEF-ADR-0024 retoma el Context Map con el eje de "alcance" de cada ASB).

## Alternativas consideradas

### Alt 1: un solo namespace de ASB por BC con convencion de naming

Un unico namespace por BC donde los topics "internos" llevan un prefijo (ej. `int-`) y los "externos" otro (ej. `ext-`).

**Descartada**: el aislamiento dependeria de **configuracion** (filtros, naming, RBAC fino dentro del namespace), no de **topologia**. Un error de configuracion o un permiso mal asignado expondria topics internos a consumidores que no deberian verlos; separar el namespace interno del BC (privado, solo alcanzable desde dentro del BC) del namespace donde viaja lo publico (el backbone compartido del producto, o un namespace de integracion externo en el caso diferido — MEF-ADR-0024) hace el aislamiento estructural: un evento privado nunca esta en el mismo namespace que uno publico, sin depender de naming ni de RBAC fino dentro de un namespace compartido.

### Alt 2: push directo al ASB de otro BC o de la aplicacion externa

El productor publica un evento publico escribiendo directamente en el namespace del consumidor (otro BC del producto, o una aplicacion externa) en vez de publicar en el backbone compartido o exponer su propio namespace de integracion.

**Descartada**: invierte la direccion de la dependencia de pub/sub. Tanto el backbone compartido del producto (MEF-ADR-0024) como Open Host Service [1] para el caso externo diferido (decision #5) resuelven lo publico con el productor creando sus topics en un namespace que no es el ASB privado de ningun consumidor, y los consumidores suscribiendose alli. Empujar directamente al ASB de otro BC o de una aplicacion externa acopla al productor con la topologia interna de cada consumidor y rompe la autonomia que justifica la arquitectura basada en eventos (MEF-ADR-0001: "la verdad viaja en el evento; cada dominio es el unico productor de los eventos que le pertenecen"). Tambien introduce una dependencia operativa bidireccional: el productor necesita credenciales sobre todos los namespaces ajenos a los que empuja, y esa lista crece con cada nuevo consumidor.

## Consecuencias

### Positivas

- **Aislamiento estructural**: separar el namespace interno del BC (privado) del namespace donde viaja lo publico (el backbone compartido, o un namespace de integracion externo en el caso diferido) aisla el trafico interno del publico sin dependencia de convencion de naming o configuracion de RBAC fino dentro de un namespace compartido.
- **Autonomia del productor**: en el backbone compartido y, si se materializa, en la integracion externa diferida, el productor crea sus topics y expone su Published Language; el consumidor crea su propia subscription, sin que el productor necesite conocer ni tener credenciales sobre cada consumidor.
- **Desacoplamiento de ejes**: separar "alcance" (a donde se publica) de "forma" (plano/rico) hace que cada eje evolucione independientemente. Hoy el criterio de forma es identico para todo trafico de bus; en el futuro podria diferir sin reestructurar la topologia.
- **Lenguaje preciso**: "publico" y "privado" pasan a ser terminos de enrutamiento con significado topologico exacto, no etiquetas ambiguas de serializacion.
- **Least-privilege como norte diferido**: el principio de least-privilege por entidad (roles a nivel de topic/subscription) es la recomendacion para cuando se materialice la integracion externa diferida; hasta entonces, la frontera de seguridad establecida es la separacion de namespaces — el namespace interno del BC no es alcanzable desde fuera del BC.
- **Raiz de la cascada**: las reformas de MEF-ADR-0012 (#122) y la evolucion de los agentes (#125, #126) tienen ahora una raiz comun a referenciar, en vez de razonar cada uno sobre un eje distinto.

### Negativas

- **RBAC fino es trabajo diferido**: la granularidad de los role assignments (topic/subscription vs namespace completo) y su implementacion en Terraform se decide al materializar la integracion externa diferida (#131); hasta entonces no hay costo operativo de RBAC inter-BC.
- **El Context Map queda diferido**: la declaracion formal de que BCs existen y como se conectan no se materializa en este ADR; un consumidor que integra multiples BCs debe gestionar manualmente las conexiones hasta que #131 y sus sucesores lo formalicen.
- **La reforma de MEF-ADR-0012 es un issue separado**: el desacoplamiento "plano = cruza un bus" vs "plano = es `IPublicEvent`" que este ADR establece como doctrina no se refleja aun en el texto de MEF-ADR-0012 hasta que #122 lo edite.

## Referencias

- **[1]** Eric Evans, *Domain-Driven Design: Tackling Complexity in the Heart of Software* (Addison-Wesley, 2003), cap. 14 "Maintaining Model Integrity" — patrones Open Host Service, Published Language y Context Map. Open Host Service: "Define a protocol that gives access to your subsystem as a set of services [...] The protocol is open, so that all who need to integrate with you can use it." Published Language: "Use a well-documented shared language that can express the necessary domain information as a common medium of communication, translating as necessary into and out of that language."
- **[2]** "Azure Service Bus authentication and authorization — Azure role-based access control" — roles integrados Azure Service Bus Data Owner, Data Sender y Data Receiver, y asignacion de roles a nivel de entidad (namespace, cola, topic, subscription). https://learn.microsoft.com/azure/service-bus-messaging/service-bus-managed-service-identity
- **[3]** "Azure built-in roles — Azure Service Bus Data Sender / Data Receiver" — definicion oficial de los roles integrados `69a216fc-b8fb-44d8-bc22-1f3c2cd27a39` (Data Sender) y `4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0` (Data Receiver). El rol Data Owner (`090c5cfd-751d-490a-894a-3ce6f1109419`) da acceso completo y queda fuera del esquema least-privilege recomendado para la integracion cross-BC (recomendacion diferida, ver decision #5). https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/integration
- MEF-ADR-0001 (un topic por tipo de evento): MEF-ADR-0023 anade la dimension faltante — en que namespace vive ese topic (interno del BC, backbone compartido del producto, o integracion externa) segun el alcance del evento (MEF-ADR-0024).
- MEF-ADR-0003 (stack ES: Marten + Wolverine + Postgres): origen de `IPublicEventSender` / `IPrivateEventSender` (paquete `Cosmos.EventDriven.Abstractions`); MEF-ADR-0023 define la topologia destino de cada sender, sin modificar las interfaces.
- MEF-ADR-0005 (naming y versionado de eventos): las convenciones de naming de topics y subscriptions de MEF-ADR-0001/0005 aplican por igual dentro del namespace interno, del backbone compartido y de cualquier namespace de integracion externo.
- MEF-ADR-0012 (heuristicas de modelado de objetos de dominio): la seccion "Frontera de serializacion: event store vs bus" establece que el payload de un `IPublicEvent` debe ser plano y portable. MEF-ADR-0023 extiende esa regla a los eventos privados (todo lo que cruza un bus es plano) y clarifica que el criterio de forma es "cruza un bus", no "es `IPublicEvent`". La reforma del texto de MEF-ADR-0012 para reflejar este desacoplamiento es #122.
- MEF-ADR-0020 (un App Service Plan por dominio): el dominio como unidad de Function App sigue vigente; MEF-ADR-0023 anade el nivel superior — el BC como resource group que agrupa dominios relacionados.
- MEF-ADR-0021 (infraestructura base del consumidor): el `infra-base-scaffolder` genera un namespace interno de Service Bus por BC; no provisiona namespace de integracion (reformado por issue #160 siguiendo MEF-ADR-0024).
- MEF-ADR-0022 (autenticacion de CI hacia Azure por OIDC): MEF-ADR-0022 cubre el eje CI/deploy (Service Principal de GitHub Actions); el eje de autenticacion runtime de la integracion externa diferida (como se autoriza a un consumidor externo sobre el namespace de integracion que se hostee para el) es trabajo **explicitamente diferido** — MEF-ADR-0022 lo declara fuera de su alcance en su seccion "Frontera de alcance: autenticacion runtime cross-BC". Cuando ese caso se materialice, la recomendacion diferida de RBAC least-privilege de MEF-ADR-0023 (roles Data Sender / Data Receiver) se enmarcara en el mismo patron de autorizacion de identidades Azure que MEF-ADR-0022 establece.
- MEF-ADR-0024 (modelo de eventos de bus: privado propio, publico via backbone compartido, integracion externa diferida): enmienda las decisiones #2 y #5 de este ADR (topologia de un solo namespace interno por BC; OHS reencuadrado como el caso diferido de integracion externa entrante) y reafirma la decision #4 (criterio publico/privado por frontera de BC).
- MEF-ADR-0026 (colas de Service Bus con sesion para fan-in y serializacion por clave de aggregate): el queue de fan-in vive en el namespace interno del BC que fija este ADR, como cualquier entidad de consumo privada — sin cambio a la doctrina de namespaces ni a la separacion privado/publico de este ADR.

## Control de cambios

- 2026-07-01: enmendado (issue #161, mandato de MEF-ADR-0024) para reemplazar la topologia de dos namespaces por Bounded Context (decision #2) por un unico namespace interno por BC, y reencuadrar Open Host Service (decision #5) como el caso diferido de integracion externa entrante en vez de la topologia por defecto de integracion inter-BC. Lo publico inter-BC dentro del producto viaja por el backbone compartido (MEF-ADR-0024). El titulo del ADR se ajusta para no describir la topologia superada. La decision #4 (criterio publico/privado por frontera de BC) no se modifica.
- 2026-07-15: enmendado (issue #269, doctrina fundacional de MEF-ADR-0026) para agregar la referencia cruzada a MEF-ADR-0026: el queue de fan-in con sesion vive en el namespace interno del BC que fija este ADR, sin cambio a la topologia de namespaces.

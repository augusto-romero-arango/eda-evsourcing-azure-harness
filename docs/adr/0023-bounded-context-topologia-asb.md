# ADR-0023: Bounded Context, topologia de dos namespaces de Azure Service Bus y Open Host Service

- **Fecha**: 2026-06-26
- **Estado**: aceptado
- **Aplica a**: doctrina de mensajeria del marco; gobierno de los agentes `implementer`, `test-writer`, `infra-base-scaffolder`, `domain-scaffolder` e `infra-writer`; flujo de integracion inter-bounded-context.

## Contexto

El marco crecio con varias decisiones de mensajeria parciales y sin una raiz estrategica que las unifique:

- ADR-0001 fija "un topic por tipo de evento" pero no dice **en que namespace** vive ese topic, ni que pasa cuando un evento debe cruzar de un grupo de dominios a otro.
- ADR-0020 fija "una Function App (dominio) por App Service Plan" pero no define la unidad de agrupacion superior al dominio.
- ADR-0012 ata la regla de serializacion del payload al marcador `IPublicEvent` (eje "alcance"), mezclando el eje "forma del payload" (rico vs plano) con el eje "alcance". Esa mezcla se puede desacoplar, pero solo si existe primero una doctrina que defina con precision que es "publico" y que es "privado".
- La distincion `IPublicEvent` / `IPrivateEvent` aparece en `agents/implementer.md` ("Donde vive cada tipo de evento") y `agents/test-writer.md` (seccion 6e), pero ningun ADR define la **topologia de infraestructura** que justifica esa distincion: a donde se publica un evento publico, quien se suscribe, como se aisla del trafico interno.

Sin esta raiz, cada decision satelite (ADR-0001, 0012, 0020) razona sobre un eje distinto sin un marco comun, y el lenguaje del harness ("publico", "privado", "dominio", "bounded context") es ambiguo.

## Decision

### 1. Bounded Context y dominio

**Bounded Context** (BC) = grupo de dominios relacionados, con su propio resource group de Azure.
**Dominio** = Function App (sin cambio respecto a ADR-0020: un App Service Plan por dominio sigue vigente; el BC es la unidad de agrupacion superior al dominio, materializada como resource group).

Un BC puede contener uno o varios dominios. Los dominios dentro de un mismo BC comparten contexto de negocio, lenguaje ubicuo y pueden comunicarse a traves de un bus interno; los dominios de BCs distintos se comunican unicamente a traves del bus de integracion.

### 2. Dos namespaces de Azure Service Bus por Bounded Context

Cada BC provisiona exactamente **dos** namespaces de Azure Service Bus, con responsabilidades ortogonales:

| Namespace | Proposito | Interfaz de publicacion |
|---|---|---|
| **Namespace interno** | Eventos privados intra-BC; mensajeria entre dominios del mismo BC | `IPrivateEventSender` |
| **Namespace de integracion** | Eventos publicos inter-BC; los dominios externos se suscriben aqui | `IPublicEventSender` |

La separacion es por **namespace** (no por convencion de naming dentro de un namespace unico). Un consumidor externo al BC solo recibe credenciales/RBAC sobre el namespace de integracion; el namespace interno no es visible ni alcanzable desde fuera del BC.

### 3. Todo lo que cruza un bus es plano y portable

Todo evento o comando que cruza cualquiera de los dos namespaces (interno o de integracion) contiene exclusivamente tipos serializables con el serializador por defecto de System.Text.Json: primitivos, `enum`, `string`, fechas (`DateOnly` / `DateTime` / `DateTimeOffset`), `Guid`, colecciones de esos tipos, y `record` DTO planos compuestos de lo anterior.

El modelo de dominio rico (value objects con campos privados, `ConfigurarSerializacion`, factory statics) vive **exclusivamente** en el event store de Marten, dentro del dominio productor. Al publicar, el handler traduce a una forma plana y portable antes de llamar a `IPublicEventSender` o `IPrivateEventSender`.

Esto **desacopla el eje de serializacion** (rico/plano) **del eje de alcance** (publico/privado): el criterio de "plano" pasa a ser "¿cruza un bus (interno o de integracion)?", no "¿es `IPublicEvent`?". Ambas categorias de evento son planas; lo que las diferencia es el namespace destino, no la forma del payload. La materializacion de este desacoplamiento en el texto de ADR-0012 es el trabajo de #122.

### 4. Publico vs privado = enrutamiento, no forma del payload

Un evento privado y uno publico tienen exactamente la misma exigencia de forma: plano y portable. Lo unico que los diferencia es el **namespace destino**:

- `IPrivateEventSender` -> namespace interno del BC
- `IPublicEventSender` -> namespace de integracion del BC

No existe una regla distinta de serializacion, ni un contrato de tipo diferente, entre eventos privados y publicos. La distincion es puramente de enrutamiento. Un `IPublicEvent` no es "mas plano" que un `IPrivateEvent`: ambos son planos porque ambos cruzan un bus.

### 5. Topologia de integracion inter-BC: Open Host Service + Published Language

La integracion entre BCs sigue el patron **Open Host Service + Published Language** [1] en su variante de dos namespaces:

- **El productor publica en SU namespace de integracion** y los BCs externos **se suscriben conectandose a el**. El productor nunca empuja a ASB ajenos.
- El namespace de integracion del productor es el "host" que expone su Published Language [1]: el conjunto de topics y contratos de eventos que ese BC garantiza como superficie publica estable.
- La seguridad se logra **por topologia**: el namespace interno del BC no tiene ninguna asignacion de rol para entidades externas y no es alcanzable desde fuera del BC; el consumidor externo solo puede operar sobre el namespace de integracion. Azure Service Bus no tiene acceso anonimo, por lo que cualquier consumidor externo necesita alguna credencial sobre el namespace de integracion — pero el mecanismo exacto (RBAC fino a nivel de topic/subscription vs acceso mas grueso al namespace de integracion) es una **decision de la fase de integracion cross-BC**, explicitamente diferida junto con el Context Map (#131).
- **Recomendacion diferida** (a decidir al materializar la integracion cross-BC): el mecanismo de autorizacion recomendado es RBAC least-privilege por entidad — el productor con rol **Azure Service Bus Data Sender** sobre sus topics del namespace de integracion [2][3]; el consumidor externo con rol **Azure Service Bus Data Receiver** sobre la subscription que le corresponde [2][3]; roles asignados a nivel de topic/subscription, no de namespace. Esta decision se tomara al formalizar el Context Map (#131) y la infraestructura de identidades de los BCs externos.

### Context Map: concepto diferido, no implementacion

El **Context Map** [1] (registro de las relaciones entre BCs y sus namespaces de integracion) es el rumbo de evolucion del marco para declarar explicitamente que BCs existen, que namespaces de integracion exponen y quien se suscribe a quien. ADR-0023 lo nombra como direccion futura y lo fija como concepto; **su materializacion como configuracion** (`harness.config.json`, registro de BCs externos, extension del `infra-base-scaffolder`) queda **explicitamente diferida** a un issue posterior (#131 introduce el concepto de BC como primer eslabon de esa cadena).

## Alternativas consideradas

### Alt 1: un solo namespace de ASB por BC con convencion de naming

Un unico namespace por BC donde los topics "internos" llevan un prefijo (ej. `int-`) y los "externos" otro (ej. `ext-`).

**Descartada**: el aislamiento dependeria de **configuracion** (filtros, naming, RBAC fino dentro del namespace), no de **topologia**. Un error de configuracion o un permiso mal asignado expondria topics internos a consumidores externos; con dos namespaces distintos el aislamiento es estructural: un consumidor externo solo puede tener credenciales sobre el namespace de integracion porque el namespace interno no existe en su contexto de autenticacion.

### Alt 2: push directo a los ASB de los BCs externos

El productor publica un evento publico escribiendo directamente en el namespace de integracion del consumidor (el BC productor tiene credenciales sobre el ASB ajeno).

**Descartada**: invierte la direccion de la dependencia de pub/sub. En Open Host Service [1] el productor expone su Published Language y los consumidores se suscriben; empujar a un ASB ajeno acopla al productor con la topologia interna de cada consumidor y rompe la autonomia que justifica la arquitectura basada en eventos (ADR-0001: "la verdad viaja en el evento; cada dominio es el unico productor de los eventos que le pertenecen"). Tambien introduce una dependencia operativa bidireccional: el productor necesita credenciales sobre todos los BCs que consumen sus eventos, y esa lista crece con cada nuevo consumidor.

## Consecuencias

### Positivas

- **Aislamiento estructural**: la topologia de dos namespaces aisla el trafico interno del publico sin dependencia de convencion de naming o configuracion de RBAC fino dentro de un namespace compartido.
- **Autonomia del productor**: el BC productor no necesita conocer ni tener credenciales sobre los BCs consumidores; ellos se suscriben a el.
- **Desacoplamiento de ejes**: separar "alcance" (a que namespace se publica) de "forma" (plano/rico) hace que cada eje evolucione independientemente. Hoy el criterio de forma es identico para ambos namespaces; en el futuro podria diferir sin reestructurar la topologia.
- **Lenguaje preciso**: "publico" y "privado" pasan a ser terminos de enrutamiento con significado topologico exacto, no etiquetas ambiguas de serializacion.
- **Least-privilege como norte diferido**: el principio de least-privilege por entidad (roles a nivel de topic/subscription) es la recomendacion para cuando se materialice la integracion cross-BC; hasta entonces, la frontera de seguridad establecida es la topologia de namespaces separados — el namespace interno no es alcanzable desde fuera del BC.
- **Raiz de la cascada**: las reformas de ADR-0012 (#122) y la evolucion de los agentes (#125, #126) tienen ahora una raiz comun a referenciar, en vez de razonar cada uno sobre un eje distinto.

### Negativas

- **Mas namespaces de ASB**: cada BC provisiona dos namespaces en vez de uno. Impacto en costo y en superficie de administracion de Terraform. Mitigado por el `infra-base-scaffolder` (ADR-0021) que genera la infraestructura base del BC.
- **RBAC fino es trabajo diferido**: la granularidad de los role assignments (topic/subscription vs namespace completo) y su implementacion en Terraform se decide al materializar la integracion cross-BC (#131); hasta entonces no hay costo operativo de RBAC inter-BC.
- **El Context Map queda diferido**: la declaracion formal de que BCs existen y como se conectan no se materializa en este ADR; un consumidor que integra multiples BCs debe gestionar manualmente las conexiones hasta que #131 y sus sucesores lo formalicen.
- **La reforma de ADR-0012 es un issue separado**: el desacoplamiento "plano = cruza un bus" vs "plano = es `IPublicEvent`" que este ADR establece como doctrina no se refleja aun en el texto de ADR-0012 hasta que #122 lo edite.

## Referencias

- **[1]** Eric Evans, *Domain-Driven Design: Tackling Complexity in the Heart of Software* (Addison-Wesley, 2003), cap. 14 "Maintaining Model Integrity" — patrones Open Host Service, Published Language y Context Map. Open Host Service: "Define a protocol that gives access to your subsystem as a set of services [...] The protocol is open, so that all who need to integrate with you can use it." Published Language: "Use a well-documented shared language that can express the necessary domain information as a common medium of communication, translating as necessary into and out of that language."
- **[2]** "Azure Service Bus authentication and authorization — Azure role-based access control" — roles integrados Azure Service Bus Data Owner, Data Sender y Data Receiver, y asignacion de roles a nivel de entidad (namespace, cola, topic, subscription). https://learn.microsoft.com/azure/service-bus-messaging/service-bus-managed-service-identity
- **[3]** "Azure built-in roles — Azure Service Bus Data Sender / Data Receiver" — definicion oficial de los roles integrados `69a216fc-b8fb-44d8-bc22-1f3c2cd27a39` (Data Sender) y `4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0` (Data Receiver). El rol Data Owner (`090c5cfd-751d-490a-894a-3ce6f1109419`) da acceso completo y queda fuera del esquema least-privilege recomendado para la integracion cross-BC (recomendacion diferida, ver decision #5). https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/integration
- ADR-0001 (un topic por tipo de evento): ADR-0023 anade la dimension faltante — en que namespace vive ese topic (interno vs integracion) segun el alcance del evento.
- ADR-0003 (stack ES: Marten + Wolverine + Postgres): origen de `IPublicEventSender` / `IPrivateEventSender` (paquete `Cosmos.EventDriven.Abstractions`); ADR-0023 define la topologia destino de cada sender, sin modificar las interfaces.
- ADR-0005 (naming y versionado de eventos): las convenciones de naming de topics y subscriptions de ADR-0001/0005 aplican por igual dentro del namespace interno y del de integracion.
- ADR-0012 (heuristicas de modelado de objetos de dominio): la seccion "Frontera de serializacion: event store vs bus" establece que el payload de un `IPublicEvent` debe ser plano y portable. ADR-0023 extiende esa regla a los eventos privados (todo lo que cruza un bus es plano) y clarifica que el criterio de forma es "cruza un bus", no "es `IPublicEvent`". La reforma del texto de ADR-0012 para reflejar este desacoplamiento es #122.
- ADR-0020 (un App Service Plan por dominio): el dominio como unidad de Function App sigue vigente; ADR-0023 anade el nivel superior — el BC como resource group que agrupa dominios relacionados.
- ADR-0021 (infraestructura base del consumidor): el `infra-base-scaffolder` genera hoy un namespace de Service Bus por BC; la evolucion a dos namespaces (interno + integracion) es el trabajo del issue #128.
- ADR-0022 (autenticacion de CI hacia Azure por OIDC): ADR-0022 cubre el eje CI/deploy (Service Principal de GitHub Actions); el eje de autenticacion runtime cross-BC (como se autoriza a un consumidor externo sobre el namespace de integracion del productor) es trabajo **explicitamente diferido** — ADR-0022 lo declara fuera de su alcance en su seccion "Frontera de alcance: autenticacion runtime cross-BC". Cuando se materialice la integracion cross-BC, la recomendacion diferida de RBAC least-privilege de ADR-0023 (roles Data Sender / Data Receiver) se enmarcara en el mismo patron de autorizacion de identidades Azure que ADR-0022 establece.

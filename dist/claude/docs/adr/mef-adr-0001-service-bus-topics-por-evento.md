# MEF-ADR-0001: Service Bus - un topic por tipo de evento

## Estado

Aceptado (reemplaza la decision anterior de un topic por dominio productor)

## Contexto

El principio central de la arquitectura es que "la verdad viaja en el evento": cada dominio
es el unico productor de los eventos que le pertenecen y ningun dominio puede modificar la
verdad de otro dominio directamente.

Para implementar este principio con Azure Service Bus se evaluaron dos topologias:

1. **Topic por dominio productor**: un topic agrupa todos los eventos de un dominio.
   Los consumidores usan filtros SQL en sus subscriptions para seleccionar los tipos de
   evento que les interesan. Menos topics, pero la complejidad se traslada a los filtros.

2. **Topic por tipo de evento**: cada tipo de evento publicado tiene su propio topic.
   Si un consumidor se suscribe a un topic, quiere todos los mensajes de ese topic.
   Sin filtros SQL. Mas topics, pero cada subscription es semanticamente clara.

La topologia de topic-por-dominio genera complejidad operativa: para saber quien consume
que evento hay que leer las reglas de filtro SQL de cada subscription. Ademas, agregar un
nuevo tipo de evento al dominio no requiere crear infraestructura nueva, lo que puede
llevar a que se publiquen eventos sin que nadie los consuma sin que esto sea evidente.

## Decision

Se usa un topic de Service Bus por tipo de evento publicado. La nomenclatura sigue estas
reglas:

- Topics: kebab-case, nombre del evento en pasado. Ej: `turno-creado`, `empleado-asignado`
- Subscriptions: kebab-case, patron `{consumidor}-escucha-{productor}`. Ej: `depuracion-escucha-marcaciones`, `calculo-horas-escucha-programacion`
- Sin prefijos artificiales (ni `sbt-`, ni `eventos-`). El nombre comunica el contrato de dominio.

**Por que la subscription incluye `{productor}` aunque sea derivable del topic.** El topic ya nombra el evento y, por la regla de un unico productor por evento, tambien identifica al productor; el segmento `{productor}` de la subscription es por tanto redundante con el topic. Se conserva de forma **deliberada**: el nombre auto-documentado (`depuracion-escucha-marcaciones`) permite leer un flujo completo -- quien consume y de quien -- sin cruzar la referencia al topic. En un harness donde el desarrollo lo conducen agentes, ese sobre-contexto facilita tanto la revision asistida de flujos como el instruir a un agente para que actue sobre una subscription concreta; el beneficio de legibilidad supera el ahorro del presupuesto de nombre (Azure limita el nombre de subscription a 50 caracteres). Se evaluo explicitamente adoptar `{consumidor}` a secas (issue #252) y se descarto por esta razon.

Un topic por tipo de evento aplica **dentro de cada namespace o backbone**. Los eventos privados (via `IPrivateEventSender`) se publican a topics del namespace interno del bounded context; los eventos publicos (via `IPublicEventSender`) al backbone compartido del producto (caso comun) o, en el caso diferido de integracion verdaderamente externa, a un namespace de integracion propio del productor (MEF-ADR-0024). En el backbone compartido, el **productor** crea sus topics y cada BC **consumidor** crea su propia subscription (permisos baseline de infra); en el caso diferido, las subscriptions del consumidor externo viven en el namespace de integracion del **productor** (patron Open Host Service, MEF-ADR-0023 decision #5: el consumidor se conecta a suscribirse; no se empuja a ASB ajenos).

Cada dominio publica **unicamente** a los topics de los eventos que produce. Ningun dominio
publica al topic de otro dominio.

Esta topologia es **fan-out** por diseno: N subscriptions independientes de un mismo topic procesan en paralelo, sin estado compartido entre ellas. Cuando varios eventos deben converger en una decision sobre el **mismo aggregate** y ese paralelismo rompe la concurrencia optimista de Marten, la primitiva complementaria es un queue de Service Bus con sesion, alimentado por auto-forward desde subscriptions de este ADR — ver MEF-ADR-0026. Topic vs queue **nunca es decision del productor**: el productor siempre publica a topics; el queue, cuando aplica, es una construccion exclusiva del lado consumidor que no altera esta topologia.

Un eje distinto -- no cuantos tipos de evento sino cuantos **destinatarios** de un mismo evento -- tiene tambien una excepcion gobernada al rechazo de filtros SQL de este ADR: cuando un unico evento publico debe llegar a N destinatarios que solo quieren su subconjunto, cada subscription destinataria puede llevar un **correlation filter de igualdad** sobre una clave de enrutamiento (application property), sin recurrir a un filtro SQL — ver MEF-ADR-0027. El escape-hatch `filter_type = "SqlFilter"` que el modulo `service-bus` de `infra-base-scaffolder` expone hoy para el campo `sub.filter` no es el mecanismo que MEF-ADR-0027 fija para este eje; ese modulo se reconcilia en el trabajo de infraestructura diferido de MEF-ADR-0027. El rechazo de filtros SQL de este ADR no se reabre: sigue aplicando, sin excepcion, a cualquier caso que no sea igualdad exacta.

Los topics y subscriptions se gestionan como infraestructura mediante Terraform en
`infra/environments/{ambiente}/main.tf`. El agente `es-implementer` es responsable de
agregar los topics y subscriptions necesarios cuando implementa un handler que publica
eventos publicos.

## Consecuencias

**Positivas**

- Sin filtros SQL: el rechazo se mantiene sin excepcion (MEF-ADR-0027 acota este absoluto con un
  correlation filter de **igualdad** para el eje "un evento, N destinatarios", que no reabre el
  rechazo de expresiones SQL). Sin ese filtro, suscribirse a un topic sigue significando querer
  todos sus mensajes; la topologia sigue siendo completamente declarativa -- el filtro, cuando
  aplica, se lee en la subscription, no en codigo de aplicacion.
- Visible desde la infraestructura: ver las subscriptions de un topic revela exactamente
  quien consume ese evento, sin leer codigo de aplicacion.
- Agregar un nuevo consumidor solo requiere crear una nueva subscription en Terraform,
  sin tocar el productor.
- Cada consumidor tiene su propio cursor de lectura y su propio dead-letter queue.
- El limite de Azure Service Bus Standard es 10,000 topics por namespace. Un sistema con
  cientos de tipos de evento usa una fraccion minima de ese limite sin costo adicional por
  cantidad de topics (el costo es por operaciones, no por entidades).

**Negativas**

- Mas topics que gestionar en Azure. Con un diseno de dominio granular, el numero de topics
  puede crecer significativamente.
- La topologia completa (que topics y subscriptions existen) vive en Terraform y no es
  directamente visible desde el codigo de la aplicacion.

## Referencias

- MassTransit usa topic-per-event como topologia por defecto en Azure Service Bus
- Azure Service Bus Standard: limite de 10,000 topics, sin costo adicional por cantidad
- MEF-ADR-0023: Bounded Context, namespace interno de Azure Service Bus y frontera publico/privado — define el namespace interno del BC (eventos privados) y el criterio publico/privado por frontera de BC.
- MEF-ADR-0024: Modelo de eventos de bus (privado propio, publico via backbone compartido, integracion externa diferida) — define el transporte del evento publico: backbone compartido del producto (caso comun) o namespace de integracion externo (caso diferido, Open Host Service).
- MEF-ADR-0026: Colas de Service Bus con sesion para fan-in y serializacion por clave de aggregate — complementa la topologia fan-out de este ADR con la primitiva de fan-in (queue con sesion, alimentado por auto-forward desde subscriptions de este ADR) para el caso en que varios eventos convergen en una decision sobre el mismo aggregate. No reemplaza ni modifica el naming de topics/subscriptions de este ADR.
- MEF-ADR-0027: Enrutamiento multi-destinatario de un evento por correlation filter de igualdad — acota el rechazo de filtros SQL de este ADR con una excepcion gobernada (correlation filter de igualdad) para el eje "un evento, N destinatarios", distinto del eje "varios tipos de evento" que este ADR razono. No reemplaza el rechazo de filtros SQL ni el naming de topics/subscriptions de este ADR.

## Control de cambios

- 2026-07-01: enmendado (issue #167, barrido de coherencia hacia MEF-ADR-0024) para reemplazar "namespace de integracion del bounded context" como destino por defecto del evento publico por el modelo de MEF-ADR-0024: backbone compartido del producto (caso comun) o namespace de integracion externo (caso diferido). El criterio "un topic por tipo de evento" y la convencion de naming no cambian.
- 2026-07-10: se evaluo simplificar el patron de subscription a `{consumidor}` a secas -- eliminando el segmento `{productor}`, redundante con el topic (issue #252) -- y se **descarto**. La redundancia es deliberada: el nombre auto-documentado facilita la revision de flujos asistida por agentes y el instruir acciones sobre subscriptions concretas, beneficio que supera el ahorro frente al limite de 50 caracteres de Azure. El patron `{consumidor}-escucha-{productor}` y su hogar canonico (este ADR) no cambian; se agrego el rationale explicito a la seccion "Decision".
- 2026-07-15: enmendado (issue #269, doctrina fundacional de MEF-ADR-0026) para anadir, en la seccion "Decision", el parrafo que aclara que esta topologia es fan-out por diseno y que MEF-ADR-0026 la complementa con la primitiva de fan-in (queue con sesion) sin alterar el naming ni la topologia de este ADR; se agrega la referencia cruzada a MEF-ADR-0026.
- 2026-07-15: enmendado (issue #275, doctrina fundacional de MEF-ADR-0027) para acotar, sin eliminarlo, el absoluto "sin filtros SQL / suscribirse a un topic es querer todo": se anade en "Decision" el parrafo que reconoce el eje "un evento, N destinatarios" y la excepcion gobernada de un correlation filter de igualdad (MEF-ADR-0027), reconciliando el escape-hatch `filter_type = "SqlFilter"` latente del modulo `service-bus` de `infra-base-scaffolder`, cuyo ajuste queda diferido al trabajo de infraestructura de MEF-ADR-0027; se ajusta la consecuencia "Sin filtros SQL" en la misma direccion y se agrega la referencia cruzada a MEF-ADR-0027.

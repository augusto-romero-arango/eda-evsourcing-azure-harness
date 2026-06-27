# ADR-0001: Service Bus - un topic por tipo de evento

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

Un topic por tipo de evento aplica **dentro de cada namespace**. Los eventos privados (via `IPrivateEventSender`) se publican a topics del namespace interno del bounded context; los eventos publicos (via `IPublicEventSender`) al namespace de integracion del bounded context. Las subscriptions de consumidores externos viven en el namespace de integracion del **productor** (patron Open Host Service, ADR-0023: el consumidor se conecta a suscribirse; no se empuja a ASB ajenos).

Cada dominio publica **unicamente** a los topics de los eventos que produce. Ningun dominio
publica al topic de otro dominio.

Los topics y subscriptions se gestionan como infraestructura mediante Terraform en
`infra/environments/{ambiente}/main.tf`. El agente `es-implementer` es responsable de
agregar los topics y subscriptions necesarios cuando implementa un handler que publica
eventos publicos.

## Consecuencias

**Positivas**

- Sin filtros SQL: suscribirse a un topic significa querer todos sus mensajes. La topologia
  es completamente declarativa.
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
- ADR-0023: Bounded Context, topologia de dos namespaces ASB y Open Host Service — define la topologia que justifica la separacion por namespace (interno vs integracion) segun el alcance del evento.

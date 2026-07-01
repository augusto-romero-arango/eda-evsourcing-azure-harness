# ADR-0005: Convencion de naming y versionado de eventos

## Estado

Aceptado

## Contexto

Un sistema basado en eventos que evolucionara con el tiempo necesita reglas claras para
nombrar los eventos, los topics y las subscriptions, y para manejar cambios en los contratos
sin romper a los consumidores existentes.

Sin una convencion establecida, cada desarrollador puede nombrar eventos de distinta forma
(presente, pasado, futuro; PascalCase, snake_case; con o without prefijo de dominio), lo
que hace que el sistema sea dificil de razonar y auditar.

El versionado es el aspecto mas critico: si un evento cambia su estructura de forma
incompatible y todos los consumidores se deben actualizar de forma sincronizada, se pierde
la autonomia que justifica la arquitectura basada en eventos.

## Decision

### Naming de eventos

Los nombres de eventos usan PascalCase en participio pasado, describiendo el hecho que
ocurrio. Ejemplos: `MarcacionesRegistradas`, `HorasCalculadas`, `EmpleadoActualizado`,
`LiquidacionGenerada`.

### Naming de topics y subscriptions

Para la convencion de naming de topics y subscriptions de Service Bus, ver
[ADR-0001: Service Bus - un topic por tipo de evento](0001-service-bus-topics-por-evento.md).

### Eventos publicos como Published Language del Bounded Context

Los eventos **publicos** son el **Published Language** del bounded context (Evans, *Domain-Driven Design*, 2003, cap. 14) y se publican al backbone compartido del producto (caso comun) o, en el caso diferido de integracion verdaderamente externa, al namespace de integracion propio del productor (ADR-0024). El contrato externo que fija el Published Language se blinda con el versionado aditivo y la regla V2 descritos en este ADR.

### Versionado aditivo

Agregar campos opcionales (con valor por defecto) a un evento existente no constituye
un cambio breaking: los consumidores existentes ignoraran los nuevos campos y seguiran
funcionando. Esta es la estrategia preferida para evolucionar contratos.

Un cambio breaking (renombrar un campo requerido, cambiar un tipo, eliminar un campo) se
maneja creando un nuevo tipo de evento con el sufijo `V2`, manteniendo el tipo original
hasta que todos los consumidores hayan migrado. Ejemplo: si `HorasCalculadas` requiere un
cambio breaking, se crea `HorasCalculadasV2` y ambos coexisten durante la transicion.

### Envelope de eventos

Cuando el sistema lo requiera por primera vez, se define un tipo generico `EventoEnvelope<T>`
en el proyecto Contracts con los siguientes campos:

- `EventId`: GUID unico por evento
- `Type`: nombre del tipo de evento (string)
- `Version`: version del esquema (string, e.g. "1.0")
- `Timestamp`: fecha y hora de creacion del evento en UTC
- `Source`: dominio que origino el evento
- `CorrelationId`: identificador para rastrear una cadena de eventos relacionados
- `Data`: el payload tipado del evento

## Consecuencias

**Positivas**

- Convencion unica y consistente en todo el sistema para nombrar eventos en codigo
  (PascalCase, participio pasado), evitando la dispersion de estilos entre dominios.
- El versionado aditivo permite que productores y consumidores evolucionen de forma
  independiente sin coordinacion sincronizada.
- El `CorrelationId` en el envelope facilita el trazado distribuido a traves de los dominios.

**Negativas**

- Cuando un cambio si es breaking, hay que mantener dos versiones del evento en paralelo
  (e.g. `HorasCalculadas` y `HorasCalculadasV2`) mientras todos los consumidores migran.
  Esta deuda tecnica temporal debe gestionarse activamente para evitar que el proyecto
  Contracts acumule versiones obsoletas indefinidamente.

## Referencias

- ADR-0001 (Service Bus, un topic por tipo de evento): las convenciones de naming de topics y subscriptions de ADR-0001 y este ADR aplican por igual dentro del namespace interno, del backbone compartido del producto y de cualquier namespace de integracion externo (ADR-0024).
- ADR-0023: Bounded Context, namespace interno de Azure Service Bus y frontera publico/privado — define que los eventos publicos son el Published Language del BC; este ADR fija el naming y el versionado que blindan ese contrato externo.
- ADR-0024: Modelo de eventos de bus (privado propio, publico via backbone compartido, integracion externa diferida) — define donde vive ese Published Language: el backbone compartido del producto (caso comun) o un namespace de integracion externo (caso diferido).

## Control de cambios

- 2026-07-01: enmendado (issue #167, barrido de coherencia hacia ADR-0024) para reemplazar "namespace de integracion (ADR-0023)" como destino por defecto del Published Language por el modelo de ADR-0024: backbone compartido del producto (caso comun) o namespace de integracion externo (caso diferido). El naming, el versionado aditivo y la regla V2 no cambian.

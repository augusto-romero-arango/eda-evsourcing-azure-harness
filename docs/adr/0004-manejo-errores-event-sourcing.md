# ADR-0004: Manejo de errores en event sourcing - eventos de fallo vs excepciones

## Estado

Aceptado

## Contexto

En un sistema event-driven con event sourcing, los errores pueden ocurrir en multiples
capas: validacion de entrada, precondiciones de orquestacion, reglas de negocio del
aggregate, y fallos de infraestructura. Cada capa tiene diferentes necesidades de
retroalimentacion y diferentes consumidores del error.

Adicionalmente, el sistema es eventual: un endpoint HTTP no espera el resultado completo
del procesamiento de dominio — los efectos downstream son asincronos. Y los handlers
que reaccionan a eventos de ServiceBus tienen consumidores downstream que esperan una
respuesta (de exito o de fallo) para continuar sus propios flujos.

La decision de como manejar errores en cada capa impacta el diseno de aggregates, handlers,
tests y la comunicacion entre dominios.

## Decision

### Principio general

El tipo de trigger (HTTP o ServiceBus) determina el mecanismo de error. El aggregate
nunca lanza excepciones para logica de negocio — emite eventos de fallo.

### Capa por capa

**1. Validacion de entrada (endpoint HTTP)**

Responsabilidad del `IRequestValidator`. Retorna 400 BadRequest si el body esta vacio,
malformado o no cumple las reglas de FluentValidation. No es excepcional, es esperado.

**2. Precondiciones de orquestacion (CommandHandler)**

El handler verifica precondiciones segun la intencion del comando:

- **Crear (stream nuevo)**: verifica que el aggregate no exista. Si ya existe:
  - HTTP → lanza excepcion que se traduce a 409 Conflict (feedback inmediato al cliente)
  - ServiceBus → retorna silenciosamente (idempotencia)
- **Modificar (stream existente)**: verifica que el aggregate exista. Si no existe:
  - HTTP → lanza excepcion que se traduce a 404 NotFound
  - ServiceBus → emite evento de fallo (alguien downstream espera respuesta)
- **Upsert**: maneja ambos casos sin error (idempotencia natural)

**3. Reglas de negocio (AggregateRoot)**

El aggregate **emite eventos de fallo** en `_uncommittedEvents` cuando una regla de
negocio se viola. Nunca lanza excepciones para logica de dominio. Los eventos de fallo
se persisten en el stream del aggregate y se publican como cualquier otro evento.

Esto permite que:
- Los consumidores downstream reaccionen al fallo (compensacion, notificacion, retry)
- La historia del aggregate quede completa (auditoria)
- Los eventos compensatorios futuros no se bloqueen

**4. Metodos Apply() del aggregate**

Los metodos `Apply(TEvent)` que reconstruyen estado desde el event store **nunca lanzan
excepciones**. Si un Apply lanza una excepcion al encontrar un evento "invalido", el
aggregate queda permanentemente roto: nunca llegara al evento compensatorio que lo corrige.

**5. Fallos de infraestructura**

Excepciones naturales del runtime (red, DB, ServiceBus). El retry y dead letter de Azure
Functions los manejan automaticamente. No se capturan en el handler excepto en endpoints
de ServiceBus donde se hace dead letter explicito.

### Respuestas HTTP

El endpoint HTTP responde con la aceptacion de la solicitud, no con el resultado del
procesamiento de dominio:

- 202 Accepted — comando aceptado, efectos downstream son asincronos
- 400 BadRequest — validacion de estructura (IRequestValidator)
- 404 NotFound — aggregate no encontrado
- 409 Conflict — aggregate ya existe (solo creacion)

### No se adopta Result Pattern

No es necesario entre Handler y Endpoint porque el HTTP siempre responde 202 si paso la
validacion. El IRequestValidator ya resuelve la validacion con una tupla simple.

## Consecuencias

**Positivas**

- Los aggregates son autonomos en su manejo de errores: evaluan reglas y emiten el evento
  correspondiente (exito o fallo) sin depender de capas externas.
- Los eventos de fallo viajan por los mismos canales que los de exito, habilitando
  compensacion, monitoreo y auditoria.
- Los Apply() son seguros: reconstruir un aggregate nunca falla, incluso si el stream
  contiene eventos que representan errores de negocio.
- La heuristica es clara: el tipo de trigger determina el mecanismo.

**Negativas**

- El aggregate tiene mas responsabilidad: debe modelar explicitamente los caminos de fallo
  como eventos, lo que aumenta la cantidad de tipos de evento.
- Los tests son mas complejos: deben cubrir eventos de fallo, aggregate no encontrado, y
  aggregate ya existente, ademas del camino feliz.

## Referencias

- Oskar Dudycz — "Should you throw an exception when rebuilding state from events?"
- Szymon Kulec — "Event sourcing and failure handling"
- Andrzej Sliwa — "Event Sourced Aggregates and Error/Exception flows"
- Oskar Dudycz — "Saga and Process Manager - distributed processes in practice"

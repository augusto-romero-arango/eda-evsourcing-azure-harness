# MEF-ADR-0004: Manejo de errores en event sourcing - eventos de fallo vs excepciones

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

El handler verifica precondiciones segun la intencion del comando. Cuando la precondicion no
se cumple y el trigger es HTTP, lanza una excepcion **tipada de precondicion** —
scaffoldeada en el consumidor, nunca la `InvalidOperationException` generica de .NET, que
esta doctrina reserva exclusivamente a los fallos de infraestructura de la seccion 5:

- `PrecondicionComandoException` (`abstract`): base comun. El endpoint HTTP solo conoce esta
  clase (ver "Respuestas HTTP").
- `RecursoYaExisteException` (deriva de la base): el handler la lanza cuando el stream que el
  comando pretende crear ya existe.
- `RecursoNoEncontradoException` (deriva de la base): el handler la lanza cuando el stream que
  el comando pretende modificar no existe.

El mensaje de la excepcion sigue el patron `.resx` per-handler de MEF-ADR-0009 sin cambios:
`throw new RecursoYaExisteException(Mensajes.TurnoYaExiste)`.

Por tipo de comando:

- **Crear (stream nuevo)**: verifica que el aggregate no exista. Si ya existe:
  - HTTP → lanza `RecursoYaExisteException` (feedback inmediato al cliente, ver "Respuestas HTTP")
  - ServiceBus → retorna silenciosamente (idempotencia)
- **Modificar (stream existente)**: verifica que el aggregate exista. Si no existe:
  - HTTP → lanza `RecursoNoEncontradoException`
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
procesamiento de dominio, salvo cuando el handler declina la precondicion de orquestacion
(seccion 2):

- 202 Accepted — comando aceptado, efectos downstream son asincronos
- 400 BadRequest — validacion de estructura (IRequestValidator)
- 404 NotFound — el handler lanzo `RecursoNoEncontradoException`
- 409 Conflict — el handler lanzo `RecursoYaExisteException`

El endpoint captura `PrecondicionComandoException` (la base) y mapea por tipo concreto al
codigo HTTP correspondiente. **Toda otra excepcion no capturada sube** y el runtime la
traduce a `500 Internal Server Error` — incluida `InvalidOperationException`, que ya no es
un tipo que el endpoint reconozca. El mapeo es **exhaustivo sobre las derivadas que el
consumidor declara**: si agrega una derivada nueva, extiende el mapeo explicitamente en vez
de apoyarse en un codigo por defecto — una derivada que el endpoint no reconoce se relanza y
termina en `500`, nunca en un `409`/`404` adivinado.

Esta distincion es la leccion del incidente #802 (documentado en MEF-ADR-0028): el
`ProxyTenantResolver` de `Cosmos.MultiTenancy.CritterStack`, cableado en un consumidor,
resultaba inservible para HTTP en Azure Functions isolated worker y lanzaba
`InvalidOperationException` desde `WolverineMessageContextTenantResolver` — un fallo de
**infraestructura** (el resolver de tenant no podia resolver el tenant), no un dato de
negocio. Como el catch anterior atrapaba `InvalidOperationException` a secas, ese fallo de
infraestructura se traducia al mismo `409 Conflict` que una colision real de datos,
indistinguible para quien diagnostica. El mismo catch amplio agravaba un segundo defecto:
`Mensajes.TurnoNoEncontrado` lanzaba tambien `InvalidOperationException`, asi que el caso
"no encontrado" respondia `409` en vez del `404` que esta misma seccion ya prescribia. Separar la jerarquia por tipo — y
dejar que cualquier excepcion fuera de ella suba como `500` — hace que un fallo de
infraestructura nunca se disfrace de conflicto de negocio.

### No se adopta Result Pattern

No es necesario entre Handler y Endpoint porque el HTTP siempre responde 202 si paso la
validacion. El IRequestValidator ya resuelve la validacion con una tupla simple. Las
excepciones tipadas de precondicion (seccion 2) no reabren esta decision: siguen siendo
*excepciones*, no un tipo de retorno `Result<T>` — el handler declina lanzando, el endpoint
traduce por tipo en el catch; no se introduce un canal de retorno adicional entre ambos.

### Regimen de migracion

Esta doctrina rige el codigo **nuevo**: todo command handler y endpoint que se escriba o
reescriba a partir de esta enmienda lanza/captura las excepciones tipadas de la seccion 2.
Los handlers, endpoints y tests **preexistentes** que ya lanzaban/capturaban
`InvalidOperationException` no se migran de oficio — sus suites siguen en verde porque su
codigo sigue lanzando el tipo generico, y cada consumidor decide su propio ritmo de
migracion (mismo precedente de MEF-ADR-0043 seccion 7, "Aplicabilidad: solo endpoints
nuevos"). Sugerir la migracion de un handler viejo es legitimo pero siempre discutido con el
humano, nunca automatico ni bloqueante de un PR no relacionado.

## Consecuencias

**Positivas**

- Los aggregates son autonomos en su manejo de errores: evaluan reglas y emiten el evento
  correspondiente (exito o fallo) sin depender de capas externas.
- Los eventos de fallo viajan por los mismos canales que los de exito, habilitando
  compensacion, monitoreo y auditoria.
- Los Apply() son seguros: reconstruir un aggregate nunca falla, incluso si el stream
  contiene eventos que representan errores de negocio.
- La heuristica es clara: el tipo de trigger determina el mecanismo.
- La capa 2 declina con excepciones tipadas por resultado (`RecursoYaExisteException` /
  `RecursoNoEncontradoException`), nunca con la excepcion generica que la seccion 5 reserva a
  fallos de infraestructura — un endpoint que captura solo la base `PrecondicionComandoException`
  nunca enmascara un fallo ajeno a la precondicion como si fuera un conflicto de negocio (ver
  incidente #802 en "Respuestas HTTP").

**Negativas**

- El aggregate tiene mas responsabilidad: debe modelar explicitamente los caminos de fallo
  como eventos, lo que aumenta la cantidad de tipos de evento.
- Los tests son mas complejos: deben cubrir eventos de fallo, aggregate no encontrado, y
  aggregate ya existente, ademas del camino feliz.
- La capa 2 requiere que el consumidor scaffoldee y mantenga la jerarquia de tres tipos
  (`PrecondicionComandoException` + 2 derivadas): boilerplate pequeno pero adicional al
  patron `.resx` de MEF-ADR-0009.

## Referencias

- Oskar Dudycz — "Should you throw an exception when rebuilding state from events?"
- Szymon Kulec — "Event sourcing and failure handling"
- Andrzej Sliwa — "Event Sourced Aggregates and Error/Exception flows"
- Oskar Dudycz — "Saga and Process Manager - distributed processes in practice"
- Issue #802 / MEF-ADR-0028 (incidente Bitakora.ControlAsistencia, 2026-09-01): el
  `ProxyTenantResolver` inservible para HTTP en el worker aislado motivo la enmienda de la
  capa 2 hacia excepciones tipadas; MEF-ADR-0028 es la fuente de verdad del incidente.
- MEF-ADR-0043 seccion 7 ("Aplicabilidad: solo endpoints nuevos"): precedente del regimen de
  migracion que adopta la seccion "Regimen de migracion" de esta enmienda.
- MEF-ADR-0009 (patron de mensajes `.resx` per-aggregate): el mensaje de las excepciones
  tipadas de la capa 2 sigue su convencion sin cambio de doctrina propia.

## Control de cambios

- 2026-09-01: enmienda (issue #805). La seccion 2 ("Precondiciones de orquestacion")
  reemplaza `InvalidOperationException` generica por la jerarquia tipada
  `PrecondicionComandoException` (base abstracta, scaffoldeada en el consumidor) con
  derivadas `RecursoYaExisteException` (409) y `RecursoNoEncontradoException` (404); la
  seccion "Respuestas HTTP" fija que el endpoint captura solo la base y mapea por tipo
  concreto, y que toda otra excepcion — incluida `InvalidOperationException` de
  infraestructura — sube como 500. Motivado por el incidente de Bitakora.ControlAsistencia
  (#802, 2026-09-01, documentado en MEF-ADR-0028): el `ProxyTenantResolver` del paquete
  `Cosmos.MultiTenancy.CritterStack` lanzaba `InvalidOperationException` desde la
  infraestructura de tenancy, y el catch amplio anterior la traducia al mismo 409 que una
  colision real de datos, alargando el diagnostico; el mismo catch respondia 409 tambien al
  caso "no encontrado" porque `Mensajes.TurnoNoEncontrado` usaba el mismo tipo generico,
  contradiciendo el 404 que esta seccion ya prescribia. Fija el regimen de migracion
  (precedente MEF-ADR-0043 seccion 7): la doctrina rige codigo nuevo, sin migracion de oficio
  de handlers/endpoints/tests preexistentes. La ubicacion de archivo de los tres tipos en el
  consumidor queda fuera de este ADR — la fija el issue dependiente #806 sobre
  `agents/implementer.md`. Ripples de una linea de ejemplo en MEF-ADR-0016 y MEF-ADR-0009,
  sin cambio de doctrina propia en ninguno de los dos.

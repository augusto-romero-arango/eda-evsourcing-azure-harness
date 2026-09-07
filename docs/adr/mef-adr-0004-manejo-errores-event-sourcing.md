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

#### Estado ya alcanzado: no-op exitoso

Cuando la identidad y el alcance que requiere el comando existen, y la intencion del comando
ya esta satisfecha en el estado vigente, la operacion es un **no-op exitoso**. No es una
precondicion ausente ni una regla de negocio violada: simplemente no hay un hecho nuevo que
registrar. El aggregate retorna normalmente **antes** de agregar eventos a
`_uncommittedEvents`; el handler termina normalmente y no persiste ni publica nada nuevo. El
endpoint retorna el codigo de exito contractual del comando, incluido el que corresponda a
PUT o DELETE.

"Ya ausente" solo es un no-op si el contrato reconoce la identidad o el alcance y puede saber
que la intencion ya se cumple. Una identidad nunca conocida o un stream padre inexistente no
califican: conservan la precondicion explicita de recurso no encontrado.

| Situacion | Tratamiento |
|---|---|
| Cambio necesario | Aplica la doctrina vigente y emite el hecho correspondiente. |
| Estado ya alcanzado (identidad/alcance existente + intencion satisfecha) | Exito contractual sin excepcion, evento persistido ni publicacion nueva. |
| Identidad o stream requerido inexistente | Tratamiento `404 NotFound` vigente para HTTP; evento de fallo para ServiceBus cuando corresponda. |
| POST de creacion sobre stream existente | Tratamiento `409 Conflict` vigente para HTTP; retorno silencioso para ServiceBus. |
| Regla de negocio real | Evento de fallo vigente del aggregate. |

El mecanismo canonico es el retorno normal del metodo del aggregate antes de agregar eventos,
seguido de la finalizacion normal del handler. No se exige `SinCambios`, `Result<T>` ni ningun
tipo nuevo entre aggregate, handler y endpoint. Los tests del harness validan este camino con
`Then()` o `Then(streamId)` sin eventos esperados, que exige count exacto cero, y con los
asserts vacios de publicacion, que validan que no se publico nada.

RFC 9110 define la idempotencia por la igualdad del efecto pretendido en el servidor y aclara
que las respuestas de solicitudes identicas pueden diferir (seccion 9.2.2). Sus secciones
9.3.4 (PUT) y 9.3.5 (DELETE) no imponen una respuesta unica para este caso. Elegir exito
estable para el no-op es una convencion deliberada de Mefisto, orientada a no generar ruido al
cliente; no es una obligacion del RFC.

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
La regla de estado ya alcanzado aplica a todo PUT o DELETE **nuevo**. Cambiar un endpoint
existente que hoy responde distinto requiere un issue de refactor propio con inventario de los
endpoints afectados y aviso a sus consumidores antes de cambiar su contrato; nunca se migra de
oficio dentro de un PR no relacionado.
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
- RFC 9110, "HTTP Semantics" -- IETF, §9.2.2 (idempotencia: el efecto pretendido es el mismo,
  aunque las respuestas de solicitudes identicas puedan diferir), §9.3.4 (PUT) y §9.3.5
  (DELETE). https://www.rfc-editor.org/rfc/rfc9110.html#section-9.2.2
- `docs/testing/harness-cheatsheet.md` (DSL `Then` y asserts de publicacion vacios): confirma
  que los asserts sin eventos validan exactamente la ausencia de persistencia y publicacion.
- Issue #849: fija el codigo de exito contractual que tambien retorna el no-op.
- Issue #1003: propagara esta convencion a PUT/DELETE en MEF-ADR-0043 y a sus agentes/tests.
- Regla del experto, 2026-09-05: "Es idempotente quitar algo que ya no existe y le generamos
  ruido al cliente innecesario". Descubierta al refinar el issue #622 de
  Bitakora.ControlAsistencia; el inventario de campo encontro exito sin evento en
  `AsignarSede`, `409` en `RetirarEtiqueta`, `RetirarCentroDeCostos` y `RetirarTurno`, y `404`
  en `RetirarDispositivo`.

## Control de cambios

- 2026-09-07: enmienda (issue #850). La seccion 2 clasifica estado ya alcanzado -- identidad y
  alcance existentes con la intencion ya satisfecha -- como no-op exitoso: el aggregate retorna
  antes de agregar eventos y el handler finaliza sin persistir ni publicar; el endpoint responde
  el codigo de exito contractual. Fija la frontera frente a cambio necesario, identidad/stream
  inexistente, POST de creacion sobre stream existente y regla de negocio real; no exige
  `SinCambios`, `Result<T>` ni otro protocolo de retorno. Cita RFC 9110 §§9.2.2, 9.3.4 y 9.3.5:
  el exito estable es convencion de Mefisto, no mandato del estandar. Aplica a PUT/DELETE nuevos;
  cualquier endpoint existente requiere refactor con inventario y aviso a consumidores. Origen:
  regla del experto del 2026-09-05 y divergencia descubierta en Bitakora.ControlAsistencia al
  refinar #622. Depende de #849 y bloquea #1003.
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

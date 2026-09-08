# MEF-ADR-0013: Smoke tests contra entorno dev desplegado

## Estado

Aceptado (actualizado 2026-04-13: cobertura completa de efectos secundarios, una clase por comando, ejecucion secuencial, patron purge-before-act; actualizado 2026-07-19: asserts de dead-letter acotados a la corrida, prohibicion del assert cross-domain; actualizado 2026-08-05: csproj referencia `PublicEvents`/`PrivateEvents` en vez de Contracts, MEF-ADR-0039; actualizado 2026-09-07: el codigo de exito del camino feliz viene del contrato HTTP del issue, nunca de un default `202`; distincion commit del event store vs materializacion de proyeccion `Async`; todo PUT/DELETE nuevo o migrado cubre el no-op idempotente de estado ya alcanzado y verifica cero efectos nuevos en la repeticion; identidad sintetica configurable en HTTP y Service Bus para tenancy etapa (b))

## Contexto

Los unit tests (MEF-ADR-0002) verifican logica de dominio con un event store en memoria (TestStore). Esto
cubre correctamente la logica de negocio pero no verifica que el sistema desplegado funcione: que la
Function App responda, que la persistencia en PostgreSQL via Marten funcione, que la serializacion JSON
sea correcta, ni que la validacion opere end-to-end.

Se evaluaron alternativas:

- **Testcontainers**: descartado por experiencia previa en otro proyecto. Son fragiles, requieren mucha
  configuracion y acoplan la prueba a la implementacion (connection strings, schemas, configuracion de
  Wolverine/Marten).
- **.NET Aspire Testing**: inmaduro. Microsoft reconoce que testing es su mayor brecha en Aspire.
- **Service Bus Emulator**: experimental y bajo ROI para verificar publicacion de eventos.

Se necesita un enfoque que verifique "esto realmente funciona" con minima sobrecarga.

## Decision

Se adoptan smoke tests con HttpClient puro contra el entorno dev desplegado. Los tests son black-box:
llaman a los endpoints HTTP reales y verifican status codes. No tienen dependencia de la implementacion
interna.

### Identidad sintetica de smoke: directa a la Function App, configurable y uniforme

Los smoke tests de dominio llaman **directamente a las Function Apps desplegadas**. No adquieren un
token real de WorkOS ni atraviesan APIM: su proposito es verificar el backend black-box, no el gate de
identidad del borde. La validacion de JWT, el mapping de claims y el anti-spoofing de APIM conservan su
verificacion separada en el checklist post-deploy de `/install-apim` (MEF-ADR-0032).

El incidente que motivo el draft de esta enmienda no fue causado por headers ausentes: los fixtures del
consumidor ya enviaban `X-Tenant-Id`/`X-User-Id`, y el fallo era que `ProxyTenantResolver` decidia la
rama HTTP/Wolverine demasiado pronto. El issue #802 lo reemplazo por `TenantExecutionContext`
(`AsyncLocal`) y `TenantContextMiddleware` (MEF-ADR-0028). Sin embargo, el harness conserva un gap
distinto y vigente: los fixtures que genera `domain-scaffolder` aun no transportan identidad en ninguno
de los dos canales de entrada.

Por eso, cada proyecto de smoke tests define una **unica identidad sintetica**, explicita y
configurable, bajo la configuracion estandar de la suite:

```json
"SmokeIdentity": {
  "TenantId": "tenant-smoke",
  "UserId": "smoke-tests"
}
```

Los defaults `tenant-smoke` y `smoke-tests` no son secretos. `appsettings.local.json` o las variables
de entorno `SmokeIdentity__TenantId` y `SmokeIdentity__UserId` pueden sobreescribirlos, con la misma
jerarquia de configuracion que `Api`, `ServiceBus` y `Postgres`. No se crea ni se siembra una
organizacion en WorkOS: este flujo no atraviesa el IdP.

Los fixtures aplican esa identidad incondicionalmente y sin que el proyecto de smoke interprete
`harness.config.json` ni `tenancy.strategy`:

- `ApiFixture` agrega por defecto `X-Tenant-Id` y `X-User-Id` a todas las llamadas HTTP.
- `ServiceBusFixture.PublishAsync` agrega `tenant-id` y `user_id` a `ApplicationProperties` de todo
  mensaje publicado.

En la etapa (a) de MEF-ADR-0028, el resolver mono-tenant ignora esos valores; en la etapa (b),
`TenantContextMiddleware` los consume y sus getters fallan ruidosamente si faltan. El envio
incondicional mantiene los fixtures independientes de la estrategia de tenancy y permite que el mismo
proyecto de smoke siga funcionando durante la transicion (a)->(b).

### Alcance de un smoke test: cobertura completa de efectos secundarios

**Un smoke test debe verificar todos los efectos secundarios de la funcion bajo prueba.** Verificar
solo el status code HTTP es cobertura incompleta. Si una funcion responde su codigo de exito
contractual (ver "Codigo de exito esperado" abajo) y ademas publica eventos a Service Bus, el test
debe consumir y verificar esos eventos. Si persiste en Postgres, debe verificar la persistencia. Si
hace ambas cosas, verifica ambas.

Esta regla existe porque los efectos secundarios no verificados generan mensajes huerfanos en Service
Bus que terminan en dead letter, contaminando la senal operacional. Dead letters en la suscripcion
`smoke-tests` deben significar que algo esta roto, no que hay basura de tests con cobertura incompleta.

Efectos secundarios conocidos y como verificarlos:

| Efecto | Como detectarlo en el handler | Como verificarlo en el smoke test |
|---|---|---|
| Publicacion a topic | `IPublicEventSender.PublishAsync(eventos)` | `PurgeAsync` previo + `WaitForMessageAsync` desde suscripcion `smoke-tests` |
| Persistencia en event store | `IEventStore.StartStream(...)` o `AppendToStream(...)` | `PostgresFixture.ExisteEventoAsync` / `ObtenerEventoAsync` |
| Envio a queue (futuro) | `ISender.SendAsync(...)` o similar | Consumir de la queue y verificar contenido |
| Materializacion de una proyeccion `Async` | No esta en el handler: la proyeccion del evento vive registrada en el named store del worker de proyecciones (MEF-ADR-0034) | GET a la Function de consulta envuelto en `Polling.WaitUntilTrueAsync` con el timeout estandar, que tolera la ventana de materializacion |

Los tests que no generan operaciones exitosas (400, 404) no producen efectos secundarios y no necesitan
verificarlos.

### Codigo de exito esperado: viene del contrato HTTP del issue, nunca de un default

El status code que un smoke test asierta para el camino feliz no es un valor memorizado por el
`smoke-test-writer`: es el codigo de exito que el contrato HTTP del comando declara en el issue
(MEF-ADR-0011, fila "Contrato HTTP del comando" -- el cuarto elemento del contrato, junto a verbo,
ruta y paso de precedencia de MEF-ADR-0043). El agente lee ese codigo del issue y lo asierta tal
cual: `200`, `201`, `204` o `202`, segun lo que el contrato haya fijado para ese endpoint especifico.
Si el issue no lo declara, el smoke test no se escribe con un default asumido -- eso es un problema
del Definition of Ready (MEF-ADR-0011), no algo que el `smoke-test-writer` deba resolver adivinando.

**`202 Accepted` no es el default de un comando exitoso.** MEF-ADR-0004 restringe `202` al caso donde
el procesamiento primario solicitado continua despues de responder, y exige que el issue documente
explicitamente que trabajo queda pendiente y por que no completo antes de responder. Un smoke test
que asierta `202` sin que el contrato del issue lo haya declarado adivina el mismo default que
MEF-ADR-0004 (issue #849) y MEF-ADR-0011 (issue #991) ya retiraron del resto del pipeline -- el
`smoke-test-writer` no es una excepcion a esa correccion.

### No-op idempotente de PUT/DELETE: repetir la intencion y verificar cero efectos nuevos

Todo smoke test de un comando PUT o DELETE **nuevo o migrado** (MEF-ADR-0043, pasos 2 y 3 del
test de precedencia) cubre, ademas del camino que produce el cambio, el camino de **estado ya
alcanzado** que MEF-ADR-0004 clasifica como no-op exitoso y que MEF-ADR-0011 exige declarar como
quinto elemento del contrato HTTP -- el campo "Estado ya alcanzado" (MEF-ADR-0043 seccion 6). La
cobertura completa de efectos secundarios que ya fija este ADR (seccion "Alcance de un smoke
test") no distingue entre el primer intento y una repeticion: si el segundo intento no debe
producir un evento ni una publicacion nuevos, el smoke test tiene que demostrarlo, no asumirlo.

**Estructura del test**: prepara o ejecuta una vez el cambio que deja al comando en el estado que
su contrato declara como no-op, repite la **misma intencion** (mismo verbo, misma ruta, mismo id,
mismo payload cuando el comando lo recibe), y verifica:

1. El segundo intento responde el **mismo codigo de exito contractual** que el primero -- el que
   el contrato HTTP del issue declara para ese endpoint (seccion "Codigo de exito esperado" de este
   ADR), nunca un status memorizado ni deducido de una tabla. Si el campo "Estado ya alcanzado" del
   issue declaro y justifico una respuesta distinta del no-op -- la excepcion explicita que admite
   MEF-ADR-0043 seccion 6 --, el smoke test asierta esa respuesta declarada; sin esa declaracion,
   reclasificar el estado ya alcanzado a `404`/`409` es precisamente el defecto que el test detecta.
2. El segundo intento **no agrega un evento** al stream de la corrida -- se compara la cantidad de
   eventos (o la version) de **ese** stream antes y despues del Act 2, nunca un conteo global de la
   tabla de eventos. Un `ExisteEventoAsync` booleano no sirve para este assert: responde lo mismo
   con un evento que con dos. Si el `PostgresFixture` del dominio todavia no expone esa consulta
   acotada al stream, el smoke test la agrega al fixture -- es infraestructura del proyecto de
   smoke tests (ver "Integracion en el proceso de desarrollo"), no una excepcion a la regla.
3. El segundo intento **no produce una publicacion nueva** atribuible a la repeticion, cuando el
   comando publica a Service Bus.

```
Arrange: PurgeAsync(topic, suscripcion)               <- purge previo, patron vigente
Act 1:   PUT /api/colaboradores/{id}/nombres {valor}  <- primer intento, cambia el VO
Assert 1: 204 No Content; PostgresFixture confirma el evento persistido y cuenta los eventos de
          ESE stream; WaitForMessageAsync recibe la publicacion (y la completa, con lo que la
          saca de la suscripcion)
Act 2:   PUT /api/colaboradores/{id}/nombres {valor}  <- repite la MISMA intencion
Assert 2: 204 No Content (mismo codigo); el conteo de eventos de ESE stream sigue siendo el del
          Assert 1; la espera de publicacion acotada al identificador de la corrida se agota sin
          recibir mensaje -- ese TimeoutException es el resultado esperado, no un fallo
```

**Correlacion por stream/id de la corrida, no por conteo global**: el assert de "cero efectos
nuevos" nunca exige la suscripcion o el stream globalmente vacios -- el mismo riesgo de falso rojo
que ya motivo "Hermeticidad del assert de dead-letter: acotado a la corrida". Se correlaciona por
el streamId o el identificador de negocio unico que el propio test genero con
`Guid.CreateVersion7()` (seccion "Aislamiento de datos"). Para Service Bus, la purga previa al Act
(patron purge-before-act vigente) corre una sola vez, en el Arrange, y **no se repite entre Act 1 y
Act 2**: purgar entre ambos actos consumiria el mensaje que Act 2 hubiera publicado indebidamente,
exactamente lo que el test necesita detectar. Tampoco hace falta repetirla -- el
`WaitForMessageAsync` del Assert 1 ya completo (elimino) el mensaje de Act 1 de la suscripcion
(ver "Fail-on-mismatch en WaitForMessageAsync"), asi que un mensaje que matchee el identificador de
la corrida despues del Act 2 solo puede venir del Act 2. La ausencia se verifica con esa misma
espera, invirtiendo su criterio de exito: el `TimeoutException` que `WaitForMessageAsync` lanza al
agotar el timeout **es** el resultado esperado del assert, y recibir un mensaje es el fallo. Ese
timeout se paga completo en cada corrida verde, asi que se elige corto, no el timeout generoso de
una espera que si espera recibir algo.

**Distincion frente a identidad nunca conocida o stream padre inexistente**: el no-op exige que la
identidad o el alcance que el comando requiere ya sean reconocidos por el contrato (MEF-ADR-0004,
"Estado ya alcanzado: no-op exitoso"). Un smoke test que dirige el PUT/DELETE a un id que el
contrato nunca conocio, o a un stream padre inexistente, verifica el `404 NotFound` vigente -- un
escenario de test distinto, nunca el mismo caso que el no-op. Ambos escenarios se escriben como
tests separados dentro de la misma clase del comando (seccion "Estructura: una clase por
comando"): uno cubre el estado ya alcanzado, otro cubre la identidad desconocida.

**El unit test del aggregate no descarga esta obligacion**: el `Then()` sin eventos esperados
(MEF-ADR-0004) prueba que el aggregate no emite eventos ante el estado ya alcanzado, y lo hace
sobre el store en memoria del DSL (MEF-ADR-0002). Prueba la decision del dominio, no que el
endpoint desplegado, su handler y su pipeline de publicacion no agreguen efectos observables en
dev -- que es lo que este ADR verifica black-box. Son coberturas complementarias: la del unit test
no sustituye la del smoke test.

**Aplicabilidad**: este escenario rige todo PUT/DELETE **nuevo o migrado** (mismo regimen que
MEF-ADR-0004 "Regimen de migracion" y MEF-ADR-0043 seccion 7). No se exige al POST de creacion
(paso 1 de MEF-ADR-0043): un POST sobre un stream que ya existe conserva su `409 Conflict`
vigente, no es un no-op. Tampoco se retrofitea a un PUT/DELETE preexistente fuera de una
migracion pactada con inventario y aviso a consumidores.

### Persistencia del write-side vs. materializacion del read-side: el polling del GET no cambia el status del POST

La tabla de efectos secundarios distingue **persistir en el event store** de **materializar una
proyeccion**. Son dos operaciones con distinta temporalidad, y un smoke test debe distinguirlas igual
que MEF-ADR-0034 distingue el ciclo de vida `Inline` del `Async`:

- El **commit del event store** es sincronico respecto del endpoint de escritura: no responde su
  codigo de exito hasta que el evento quedo durable (MEF-ADR-0004, "Respuestas HTTP"). El smoke test
  verifica esa persistencia con `PostgresFixture.ExisteEventoAsync`/`ObtenerEventoAsync` sin
  ventana de consistencia eventual que tolerar: si el POST ya respondio su codigo de exito, el
  evento ya esta en el stream. El `timeout` que esos metodos reciben no espera esa durabilidad --
  cubre los transitorios de la consulta (ver "Polling tolerante a excepciones") y se pasa igual. La
  excepcion esta en el Act, no en el write-side: cuando el smoke test dispara el flujo publicando al
  topic en vez de por HTTP (dominio consumidor), el procesamiento del consumidor si es asincronico
  respecto del Act y ese timeout es la espera real.
- La **materializacion de una proyeccion `Async`** ocurre en el daemon del worker de proyecciones,
  fuera del request que escribio (MEF-ADR-0034): es consistencia eventual por diseno. Un smoke test
  que verifica una vista materializada via su Function GET necesita `Polling` tolerante a que la
  vista todavia no exista (`404` o coleccion vacia durante la ventana de materializacion) -- el mismo
  matiz que MEF-ADR-0004 ya advierte para el `Location` de un `201 Created` hacia una URI que una
  proyeccion `Async` puede tardar en poblar.

Ninguna de las dos verificaciones cambia el codigo de exito del POST: ese status ya quedo fijado por
si el cambio primario termino y quedo durable al responder (MEF-ADR-0004), sin importar si el
read-side ya materializo o todavia esta materializando. Un smoke test nunca reclasifica un endpoint
de comando como `202 Accepted` porque su proyeccion asociada sea `Async` -- eso confundiria la
latencia del read-side con el contrato sincronico del write-side.

### Estructura: una clase por comando

Todos los tests de un comando van en una sola clase. No se separan los tests HTTP de los tests de
Service Bus en archivos distintos. Una funcion es una unidad con todos sus efectos — si el trigger es
HTTP y publica a Service Bus, una sola clase testea ambas cosas.

```
tests/Bitakora.ControlAsistencia.{Dominio}.SmokeTests/
  {Comando}Function/
    {Comando}SmokeTests.cs    <-- una sola clase con todos los tests del comando
```

La clase recibe los fixtures que necesite segun los efectos secundarios del handler:

```csharp
// Comando que solo persiste (sin publicacion a SB)
public class CrearTurnoSmokeTests(ApiFixture api)

// Comando que persiste + publica a Service Bus
public class SolicitarProgramacionTurnoSmokeTests(ApiFixture api, ServiceBusFixture serviceBus)

// Consumidor Service Bus que persiste en Postgres
public class AsignarTurnoSmokeTests(ServiceBusFixture serviceBus, PostgresFixture postgres)
```

Los tests que no generan efectos secundarios (400, 404) simplemente no usan los fixtures adicionales.

### Ejecucion secuencial

Los smoke tests de cada dominio corren secuencialmente (`[assembly: DisableParallelization]`). Los tests
de Service Bus comparten la suscripcion `smoke-tests` como recurso externo. Si dos tests corren en
paralelo contra la misma suscripcion, una purga de uno podria consumir el mensaje que el otro espera.
La ejecucion secuencial elimina este riesgo. Los smoke tests son pocos y contra infraestructura real —
el paralelismo no aporta valor aqui.

### Patron purge-before-act

Antes de ejecutar el Act (enviar el comando HTTP), el test purga la suscripcion `smoke-tests`
consumiendo y completando (`ReceiveMessageAsync` + `CompleteMessageAsync`) todos los mensajes
preexistentes. Esto limpia basura de ejecuciones anteriores. Completar un mensaje lo elimina
permanentemente de la suscripcion — no va al dead letter.

```
Arrange: PurgeAsync(topic, suscripcion)   <- recibe+completa toda la basura historica
Act:     POST /api/...                    <- la FA procesa y publica al topic
Assert:  WaitForMessageAsync(...)         <- cualquier mensaje aqui es de ESTE test
```

`PurgeAsync` se invoca en el Arrange del test, nunca dentro de `WaitForMessageAsync`. Si se purga
despues del Act, la Function App podria haber publicado el mensaje antes de que empiece la purga,
y se eliminaria el mensaje que el test necesita verificar.

### Fail-on-mismatch en WaitForMessageAsync

Despues del Act, `WaitForMessageAsync` aplica estas reglas:

| Situacion | Accion |
|---|---|
| Mensaje deserializa OK y cumple el predicado | `CompleteMessageAsync` + retornar (verde) |
| Mensaje deserializa OK pero NO cumple el predicado | `CompleteMessageAsync` + lanzar excepcion con diagnostico |
| Mensaje no deserializa al tipo esperado (JsonException) | `CompleteMessageAsync` + continuar esperando |
| Timeout sin ningun mensaje | Lanzar `TimeoutException` con diagnostico |

Ninguna rama usa `AbandonMessageAsync`. Todos los mensajes se completan (eliminan) de la suscripcion.
Un mensaje post-Act que no matchea el predicado es un fallo legitimo, no basura.

### Consumo de multiples eventos

Cuando un handler publica N eventos (ej: uno por fecha), el test debe consumirlos todos. El predicado
debe ser amplio (ej: `SolicitudId`) porque el orden de llegada no esta garantizado y el fail-on-mismatch
lanza excepcion si un mensaje no matchea:

```csharp
// CORRECTO - matchea por SolicitudId (ambos eventos lo comparten)
e => e.SolicitudId == solicitudId

// INCORRECTO - si el primer mensaje que llega es de fecha2, explota
e => e.SolicitudId == solicitudId && e.Fecha == fecha1
```

Se llama `WaitForMessageAsync` N veces con el predicado amplio. Cada llamada consume un mensaje. Las
verificaciones de campos especificos (Fecha, etc.) se hacen sobre los objetos retornados.

### Hermeticidad del assert de dead-letter: acotado a la corrida

El dead-letter queue (DLQ) de una suscripcion es un recurso compartido que no se auto-vacia. Un smoke
test que exige el DLQ **globalmente vacio** (`PeekDeadLetterMessagesAsync(...).Should().BeEmpty()`) es
fragil: un dead-letter residual de una corrida anterior fallida, de un warmup contra codigo viejo, o de
un race deploy->smoke tumba el test aunque el flujo de la corrida actual haya sido correcto — un falso
rojo determinista.

El assert de dead-letter debe estar **acotado a la corrida**: filtra los dead-letters por un
identificador unico de la corrida (ej. `SolicitudId`, `EmpleadoId`, `CorrelationId`) en vez de exigir
ausencia total. El fixture expone esto con dos metodos:

- `PeekAllDeadLetterMessagesAsync(topic, suscripcion)`: peekea el DLQ **completo iterando el cursor**
  (`fromSequenceNumber`), nunca con un tope fijo pequeno — un tope bajo (ej. `maxMessages = 10`) perderia
  el mensaje relevante si hay muchos residuales acumulados.
- `ExisteDeadLetterDeLaCorridaAsync<TIdentificador>(topic, suscripcion, match)`: deserializa cada
  dead-letter a una **forma minima** (un record con solo el identificador de la corrida) y evalua el
  predicado `match`. No depende de la deserializacion de value objects ricos: un dead-letter con un
  shape distinto simplemente no matchea (la `JsonException` se ignora, igual que en `WaitForMessageAsync`
  cuando el mensaje no deserializa al tipo esperado).

El patron `purge-before-act` (seccion anterior) se conserva sin cambios donde aplique — hermeticidad del
assert de dead-letter y purga previa de la suscripcion `smoke-tests` son complementarios, no alternativos.

**Prohibido el assert cross-domain.** Un dominio nunca verifica el DLQ/subscription de **otro** dominio.
"Acotar a la corrida" reduce los falsos rojos por residuales, pero no elimina el acoplamiento de que un
smoke test conozca y dependa del nombre de la suscripcion de un dominio ajeno. Por eso el Patron 1
(dominio publicador, HTTP -> Service Bus) del `smoke-test-writer` ya no verifica el DLQ de la suscripcion
del consumidor: esa suscripcion pertenece a otro dominio. Solo el Patron 2 (dominio consumidor,
Service Bus -> Postgres) verifica dead-letters, y unicamente los de su **propia** suscripcion.

### Fixtures obligatorios

En un sistema event-driven, todos los dominios publican y consumen eventos. Los tres fixtures
(Api, ServiceBus, Postgres) se generan siempre para todo dominio nuevo. No se pregunta al usuario
si el dominio los necesita — el scaffolder los crea y estan listos para usar desde el primer dia.

### Configuracion y secrets

Jerarquia estandar de .NET: `appsettings.json` < `appsettings.local.json` < variables de entorno.

- `appsettings.json` (commiteado): contiene la URL base, placeholders vacios para ServiceBus y
  Postgres connection strings, y la identidad sintetica no secreta `SmokeIdentity` con defaults
  `tenant-smoke`/`smoke-tests`. Nunca contiene valores reales ni secretos.
- `appsettings.local.json` (gitignored): cadenas de conexion reales para desarrollo local.
- Variables de entorno en CI: `ServiceBus__ConnectionString`, `Postgres__ConnectionString`. Se pasan
  como secrets opcionales (`required: false`) en el workflow de deploy. Las variables no secretas
  `SmokeIdentity__TenantId` y `SmokeIdentity__UserId` pueden sobreescribir la identidad sintetica.

Esta jerarquia permite que los smoke tests se ejecuten en cualquier contexto (local, CI, manual)
sin cambiar codigo y sin exponer secrets en el repositorio.

### Aislamiento de datos

Cada test genera IDs unicos con `Guid.CreateVersion7()`. No hay interferencia entre ejecuciones ni
necesidad de cleanup. Los nombres de entidades llevan prefijo `[TEST]`.

### Ejecucion

```bash
dotnet test --project tests/Bitakora.ControlAsistencia.Programacion.SmokeTests/
dotnet test --filter "Category=Smoke"                    # desde la raiz
Api__BaseUrl=http://localhost:7071 dotnet test ...       # contra local
```

### Skip graceful: IsConfigured + Assert.SkipWhen

Los fixtures de ServiceBus y Postgres no lanzan excepcion si la configuracion no esta disponible.
En su lugar, exponen `bool IsConfigured` y los tests usan `Assert.SkipWhen` (xUnit v3) para
omitirse con un mensaje descriptivo:

```csharp
Assert.SkipWhen(!serviceBus.IsConfigured,
    "ServiceBus no configurado. Usa appsettings.local.json o variable ServiceBus__ConnectionString.");
Assert.SkipWhen(!postgres.IsConfigured,
    postgres.SkipReason ?? "Postgres no disponible.");
```

Esto resuelve dos problemas:
- **AssemblyFixture cascading failure**: si un fixture lanza en `InitializeAsync`, xUnit cancela
  TODOS los tests del assembly. Con `IsConfigured`, el fixture se inicializa sin error y los tests
  individuales se omiten con un mensaje claro.
- **Firewall de Azure**: PostgresFixture atrapa `NpgsqlException` con `SocketException`/`TimeoutException`
  y expone `SkipReason` con instrucciones para agregar la IP al firewall.

**Importante**: es `Assert.SkipWhen()` de xUnit v3, NO `Skip.When()` que no existe y no compila.

### Polling tolerante a excepciones

El helper `Polling` captura excepciones transitorias dentro del loop de retry en vez de propagar al
primer error. Si el timeout se agota, reporta la ultima excepcion en el `TimeoutException`. Esto
maneja casos como tablas de Marten que aun no existen en la primera consulta.

### Integracion en el proceso de desarrollo

La infraestructura del proyecto de smoke tests (csproj, fixtures, appsettings, workflow) la crea el
`domain-scaffolder` como parte del scaffold de cada nuevo dominio. Los tests los escribe el agente
`smoke-test-writer`, que asume que el proyecto ya existe y se limita a escribir tests black-box.

Responsabilidades separadas:
- **domain-scaffolder**: crea `tests/*.SmokeTests/` con los 3 fixtures, Polling, appsettings.json
  con placeholders y `SmokeIdentity` no secreta, csproj con ProjectReference a
  `PublicEvents`/`PrivateEvents` (los ensamblados de
  eventos de bus del BC, para igualdad de records; MEF-ADR-0039), y el job
  `smoke-tests` con secrets opcionales en el workflow de deploy, y registra el dominio en su propio
  archivo `.github/smoke-tests/{kebab}.json` (un objeto JSON por dominio, issue #234). La **primera
  vez** que corre en un repo genera tambien (idempotente, no sobreescribe si ya existen) el workflow
  reutilizable `.github/workflows/smoke-tests-dominio.yml` (`workflow_call`) que el deploy referencia,
  y el workflow global `.github/workflows/smoke-tests.yml` que arma su matrix por glob de
  `.github/smoke-tests/*.json`. `ApiFixture` aplica `X-Tenant-Id`/`X-User-Id` y
  `ServiceBusFixture.PublishAsync` aplica `tenant-id`/`user_id`, ambos desde la unica
  `SmokeIdentity` configurable de la suite.
- **smoke-test-writer**: escribe tests dentro de ese proyecto. Asierta el codigo de exito declarado
  en el contrato HTTP del issue (MEF-ADR-0011), nunca un default memorizado. Verifica todos los
  efectos secundarios de cada funcion. Para un PUT/DELETE nuevo o migrado, ademas escribe el test
  del no-op idempotente de "Estado ya alcanzado" (repetir la intencion, mismo codigo de exito,
  cero efectos nuevos) segun la seccion "No-op idempotente de PUT/DELETE" de este ADR. Usa
  `Assert.SkipWhen` para tests que dependen de ServiceBus o Postgres.
- **reviewer**: verifica que cada smoke test con operacion exitosa asierte el codigo de exito
  contractual del issue y cubra todos los efectos secundarios del command handler. Para todo
  PUT/DELETE nuevo o migrado, verifica ademas que el smoke test cubre el no-op idempotente con la
  repeticion de la misma intencion y el assert de cero efectos nuevos. Tanto el status code
  incorrecto como la cobertura incompleta -- de efectos secundarios o del no-op -- son defecto
  bloqueante.

### CI/CD

El workflow de deploy de cada dominio (`.github/workflows/deploy-<dominio>.yml`) tiene tres jobs:

```
build-and-test (unit tests, --filter "Category!=Smoke") -> deploy -> smoke-tests
```

El job `smoke-tests` no corre los tests en linea: invoca el workflow **reutilizable**
`.github/workflows/smoke-tests-dominio.yml` (`on: workflow_call`) pasandole `base_url` y `test_project`,
y los secrets opcionales (`required: false`) `SERVICEBUS_CONNECTION_STRING` y `POSTGRES_CONNECTION_STRING`
para ServiceBus y Postgres. Si los secrets no estan configurados en el repo, los tests que dependen de
ellos se omiten via `Assert.SkipWhen` en vez de fallar. Esto permite que el pipeline funcione desde el
primer deploy sin configuracion extra. El reutilizable mapea esos secrets a las variables de entorno
`ServiceBus__ConnectionString` / `Postgres__ConnectionString` y `base_url` a `Api__BaseUrl`.

Ademas existe un workflow **global** `.github/workflows/smoke-tests.yml` (`workflow_dispatch` + `schedule`)
que arma su matrix por glob de `.github/smoke-tests/*.json` (un archivo por dominio; tolerante a cero
archivos, el job se omite sin fallar) y corre los smoke tests de **todos** los dominios registrados,
reusando el mismo `smoke-tests-dominio.yml`. Sirve como verificacion periodica y como disparo manual
del estado del entorno completo.

Ambos workflows (el reutilizable y el global) los genera el `domain-scaffolder` la primera vez que corre
en el repo (idempotente; ver "Integracion en el proceso de desarrollo").

## Consecuencias

### Positivas

- **Verificacion real**: confirma que el sistema desplegado funciona end-to-end (HTTP -> validacion ->
  handler -> Marten -> PostgreSQL -> Service Bus).
- **Cero acoplamiento**: los tests no conocen la implementacion. Si se cambia Marten por otro event
  store, los smoke tests siguen funcionando sin modificacion.
- **Cero infraestructura local**: no requiere Docker, emuladores ni containers. Solo un entorno
  desplegado.
- **Integracion natural en CI/CD**: se ejecutan como job post-deploy en GitHub Actions.
- **Senal operacional limpia**: dead letters en `smoke-tests` significan un problema real, no basura
  acumulada. La purga previa y el fail-on-mismatch eliminan los falsos positivos.
- **Cobertura completa**: cada efecto secundario de una funcion se verifica, no solo el status code HTTP.

### Negativas

- **Dependencia del entorno**: si dev esta caido, los tests fallan. Los fixtures mitigan esto con
  health check fail-fast (Api) y skip graceful (ServiceBus, Postgres) con mensajes descriptivos.
- **Datos residuales**: cada ejecucion crea datos en la base de datos de dev. Al ser GUIDs unicos y
  tener prefijo `[TEST]`, no interfieren con datos reales, pero se acumulan.
- **Firewall de Azure**: las conexiones a Postgres desde desarrollo local requieren IP whitelisted
  en el portal de Azure. PostgresFixture detecta esto y omite los tests con un mensaje claro.
- **Ejecucion secuencial**: los smoke tests no se paralelizan dentro de un dominio. Esto es aceptable
  porque son pocos tests contra infraestructura real donde el cuello de botella es la latencia de red,
  no la concurrencia del runner.

## Control de cambios

- 2026-09-07: enmienda (issue #798) para fijar una identidad sintetica, explicita y configurable para
  los smoke tests de dominio. Corrige la premisa del draft: el incidente de Bitakora.ControlAsistencia
  posterior a `/install-apim` no fue ausencia de headers -- los fixtures ya enviaban
  `X-Tenant-Id`/`X-User-Id` -- sino `ProxyTenantResolver`, que decidia la rama HTTP/Wolverine demasiado
  pronto; el issue #802 lo reemplazo por `TenantExecutionContext` (`AsyncLocal`) +
  `TenantContextMiddleware` (MEF-ADR-0028). Confirma, separado de ese incidente, el gap vigente del
  harness: `ApiFixture` no agrega los headers HTTP y `ServiceBusFixture.PublishAsync` no agrega las
  `ApplicationProperties` de identidad. Los smoke de dominio siguen llamando directo a las Function
  Apps, sin token WorkOS ni APIM; el gate real de JWT, mapping de claims y anti-spoofing permanece en
  el checklist post-deploy de `/install-apim` (MEF-ADR-0032). Se exige una unica `SmokeIdentity`, con
  defaults no secretos `tenant-smoke`/`smoke-tests` y overrides por `appsettings.local.json` o
  `SmokeIdentity__TenantId`/`SmokeIdentity__UserId`; no se crea ni siembra una organizacion WorkOS.
  Los fixtures la envian incondicionalmente como `X-Tenant-Id`/`X-User-Id` en HTTP y
  `tenant-id`/`user_id` en `ApplicationProperties` de cada `PublishAsync`: la etapa (a) la ignora y la
  etapa (b) la consume, sin que los smoke interpreten `harness.config.json`.
- 2026-09-07: enmienda (issue #1005, depende de #992 y #1004) para exigir que todo smoke test de
  un PUT/DELETE **nuevo o migrado** cubra el no-op idempotente de "Estado ya alcanzado" que
  MEF-ADR-0004 clasifica como exito sin evento (issue #850) y que MEF-ADR-0011/MEF-ADR-0043
  seccion 6 exigen declarar como quinto elemento del contrato HTTP (issue #1004). Hasta esta
  enmienda, la doctrina black-box cubria status y efectos secundarios del primer intento, pero no
  exigia repetir la misma intencion ni demostrar que el segundo intento no agrego eventos ni
  publicaciones. Se agrega la seccion "No-op idempotente de PUT/DELETE: repetir la intencion y
  verificar cero efectos nuevos" (estructura prepara/ejecuta-repite-verifica, correlacion por
  streamId/identificador de la corrida en vez de conteos globales, reuso del patron
  purge-before-act sin repetir la purga entre el primer y el segundo intento, y la distincion
  frente a una identidad nunca conocida o un stream padre inexistente, que conservan el `404`
  vigente en vez del no-op) y se actualizan las responsabilidades del `smoke-test-writer` y del
  `reviewer` para nombrar la cobertura del no-op como algo a escribir y a revisar. Acota el
  alcance al mismo regimen de aplicabilidad que ya fijan MEF-ADR-0004 ("Regimen de migracion") y
  MEF-ADR-0043 (seccion 7): no aplica al POST de creacion ni se retrofitea a un PUT/DELETE
  preexistente fuera de una migracion pactada. El assert de cero eventos nuevos se especifica sobre
  el conteo (o la version) del stream de la corrida, no sobre `ExisteEventoAsync`, que responde lo
  mismo con un evento que con dos: cuando el `PostgresFixture` de un dominio no expone esa consulta
  acotada al stream, agregarla es parte del trabajo del smoke test. Divergencia conocida que esta
  enmienda abre y que requiere un issue dependiente de sincronizacion: MEF-ADR-0011 ("Por que cada
  campo critico", bullet "Estado ya alcanzado", issue #1004) asigna hoy la confirmacion de cero
  eventos al test unitario del aggregate y se la niega explicitamente al smoke test, mientras este
  ADR -- fuente de la doctrina black-box -- pasa a exigirsela tambien end-to-end. Este ADR es la
  fuente autoritativa para la capa black-box; mientras esa frase de MEF-ADR-0011 no se sincronice,
  el `smoke-test-writer` sigue esta seccion y el `reviewer` la aplica como defecto bloqueante.
- 2026-09-07: enmienda (issue #992, depende de #991) para vincular el status code del camino feliz
  de un smoke test al contrato HTTP declarado en el issue en vez de un `202` memorizado por el
  `smoke-test-writer`. Motivo: tras las enmiendas de MEF-ADR-0004 (issue #849, retira el `202`
  universal) y MEF-ADR-0011 (issue #991, hace obligatorio el codigo de exito como cuarto elemento del
  contrato), esta doctrina seguia presentando `202` como respuesta representativa en su ejemplo de
  cobertura de efectos secundarios, sin decir de donde sale el valor esperado -- un desfase que dejaba
  al `smoke-test-writer` como la unica pieza del pipeline todavia adivinando entre `200`/`201`/`202`/
  `204`. Se agregan las secciones "Codigo de exito esperado: viene del contrato HTTP del issue, nunca
  de un default" (remite a MEF-ADR-0011 como fuente contractual y a MEF-ADR-0004 para la restriccion
  de `202` a procesamiento diferido justificado) y "Persistencia del write-side vs. materializacion
  del read-side: el polling del GET no cambia el status del POST" (distingue el commit sincronico del
  event store, sin ventana de consistencia eventual que tolerar cuando el Act es el propio POST, de la
  materializacion eventual de una proyeccion `Async` del worker de proyecciones, MEF-ADR-0034; el
  polling que tolera la ventana de materializacion de una vista nunca reclasifica el status del comando
  que la origino), y se suma a la tabla de efectos secundarios la fila de esa materializacion, que la
  seccion nueva daba por presente sin estarlo. Se
  neutraliza el ejemplo de la seccion "Alcance de un smoke test" (dejaba de citar `202` como caso
  representativo) y se actualizan las responsabilidades del `smoke-test-writer` y del `reviewer` para
  nombrar el codigo de exito contractual como algo a asertar y a revisar, no a asumir. No se toca la
  regla de cobertura completa de efectos secundarios ni la respuesta de no-op idempotente (#850, fuera
  de alcance de este issue).
- 2026-08-30: enmienda (issue #767, creacion de MEF-ADR-0048) -- MEF-ADR-0048 extiende esta doctrina
  a servidores MCP (piramide de tres niveles, verificaciones canonicas del nivel e2e, endpoints de
  gate propios y credencial de CI). Sin cambio en el cuerpo de este ADR.
- 2026-08-05: enmienda (issue #543, creacion de MEF-ADR-0039) para reemplazar, en la responsabilidad
  de `domain-scaffolder` (seccion "Integracion en el proceso de desarrollo"), el csproj con
  `ProjectReference` a Contracts por `PublicEvents`/`PrivateEvents` (los ensamblados de eventos de
  bus del BC bajo la particion canonica de MEF-ADR-0039) -- `Contracts` muere del canon del marco.
  Sin cambio en el resto de la doctrina de smoke tests (cobertura de efectos secundarios, estructura,
  fixtures, CI/CD).
- 2026-07-19: enmienda (issue #324) para acotar a la corrida los asserts de dead-letter: se agrega la
  seccion "Hermeticidad del assert de dead-letter: acotado a la corrida" (filtrar por identificador
  unico de la corrida en vez de exigir DLQ globalmente vacio; peek completo iterando el cursor sin tope
  fijo; deserializacion a forma minima; prohibicion del assert cross-domain). Motivo: incidente en el
  consumidor `Bitakora.ControlAsistencia` (issue #223, field note `2026-07-18-2027-bug-investigation.md`)
  donde un dead-letter residual de una corrida anterior produjo un falso rojo determinista en un smoke
  test que exigia el DLQ globalmente vacio, agravado por un assert cross-domain (un dominio assertando
  sobre la subscripcion de otro). El `smoke-test-writer` deja de generar por defecto
  `PeekDeadLetterMessagesAsync(...).Should().BeEmpty()` y el Patron 1 (dominio publicador) deja de
  verificar el DLQ de la suscripcion del consumidor.
- 2026-07-08: reformado (issue #234) para que el registro de dominios del workflow global deje de ser
  un array compartido (`.github/smoke-tests-dominios.json`) y pase a ser un archivo propio por dominio
  (`.github/smoke-tests/{kebab}.json`), cuya matrix arma `smoke-tests.yml` por glob. Motivo: dos
  dominios scaffoldeados en ramas separadas desde el mismo `origin/main` ya no compiten por el mismo
  archivo, lo que hace viable el scaffold en paralelo. Se elimina del cuerpo la descripcion del array
  compartido (secciones "Integracion en el proceso de desarrollo" y "CI/CD").

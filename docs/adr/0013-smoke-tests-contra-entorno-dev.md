# ADR-0013: Smoke tests contra entorno dev desplegado

## Estado

Aceptado (actualizado 2026-04-13: cobertura completa de efectos secundarios, una clase por comando, ejecucion secuencial, patron purge-before-act)

## Contexto

Los unit tests (ADR-0002) verifican logica de dominio con un event store en memoria (TestStore). Esto
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

### Alcance de un smoke test: cobertura completa de efectos secundarios

**Un smoke test debe verificar todos los efectos secundarios de la funcion bajo prueba.** Verificar
solo el status code HTTP es cobertura incompleta. Si una funcion retorna 202 y ademas publica eventos
a Service Bus, el test debe consumir y verificar esos eventos. Si persiste en Postgres, debe verificar
la persistencia. Si hace ambas cosas, verifica ambas.

Esta regla existe porque los efectos secundarios no verificados generan mensajes huerfanos en Service
Bus que terminan en dead letter, contaminando la senal operacional. Dead letters en la suscripcion
`smoke-tests` deben significar que algo esta roto, no que hay basura de tests con cobertura incompleta.

Efectos secundarios conocidos y como verificarlos:

| Efecto | Como detectarlo en el handler | Como verificarlo en el smoke test |
|---|---|---|
| Publicacion a topic | `IPublicEventSender.PublishAsync(eventos)` | `PurgeAsync` previo + `WaitForMessageAsync` desde suscripcion `smoke-tests` |
| Persistencia en event store | `IEventStore.StartStream(...)` o `AppendToStream(...)` | `PostgresFixture.ExisteEventoAsync` / `ObtenerEventoAsync` |
| Envio a queue (futuro) | `ISender.SendAsync(...)` o similar | Consumir de la queue y verificar contenido |

Los tests que no generan operaciones exitosas (400, 404) no producen efectos secundarios y no necesitan
verificarlos.

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

### Fixtures obligatorios

En un sistema event-driven, todos los dominios publican y consumen eventos. Los tres fixtures
(Api, ServiceBus, Postgres) se generan siempre para todo dominio nuevo. No se pregunta al usuario
si el dominio los necesita — el scaffolder los crea y estan listos para usar desde el primer dia.

### Configuracion y secrets

Jerarquia estandar de .NET: `appsettings.json` < `appsettings.local.json` < variables de entorno.

- `appsettings.json` (commiteado): contiene la URL base y placeholders vacios para ServiceBus y
  Postgres connection strings. Nunca contiene valores reales.
- `appsettings.local.json` (gitignored): cadenas de conexion reales para desarrollo local.
- Variables de entorno en CI: `ServiceBus__ConnectionString`, `Postgres__ConnectionString`. Se pasan
  como secrets opcionales (`required: false`) en el workflow de deploy.

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
  con placeholders, csproj con ProjectReference a Contracts (para igualdad de records), y el job
  `smoke-tests` con secrets opcionales en el workflow de deploy, y registra el dominio en su propio
  archivo `.github/smoke-tests/{kebab}.json` (un objeto JSON por dominio, issue #234). La **primera
  vez** que corre en un repo genera tambien (idempotente, no sobreescribe si ya existen) el workflow
  reutilizable `.github/workflows/smoke-tests-dominio.yml` (`workflow_call`) que el deploy referencia,
  y el workflow global `.github/workflows/smoke-tests.yml` que arma su matrix por glob de
  `.github/smoke-tests/*.json`.
- **smoke-test-writer**: escribe tests dentro de ese proyecto. Verifica todos los efectos secundarios
  de cada funcion. Usa `Assert.SkipWhen` para tests que dependen de ServiceBus o Postgres.
- **reviewer**: verifica que cada smoke test con operacion exitosa cubra todos los efectos secundarios
  del command handler. La cobertura incompleta es defecto bloqueante.

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

- 2026-07-08: reformado (issue #234) para que el registro de dominios del workflow global deje de ser
  un array compartido (`.github/smoke-tests-dominios.json`) y pase a ser un archivo propio por dominio
  (`.github/smoke-tests/{kebab}.json`), cuya matrix arma `smoke-tests.yml` por glob. Motivo: dos
  dominios scaffoldeados en ramas separadas desde el mismo `origin/main` ya no compiten por el mismo
  archivo, lo que hace viable el scaffold en paralelo. Se elimina del cuerpo la descripcion del array
  compartido (secciones "Integracion en el proceso de desarrollo" y "CI/CD").

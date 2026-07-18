# ADR-0003: Event Sourcing con Marten y Wolverine

## Estado

Aceptado

## Contexto

El sistema necesita persistir el estado de cada dominio de negocio. Las opciones consideradas
fueron el patron CRUD tradicional (una tabla por entidad con el estado actual) y Event Sourcing
(persistir los eventos que producen los cambios de estado, en lugar del estado resultante).

Adicionalmente, cada dominio necesita un mecanismo para recibir comandos internos y publicar
eventos hacia otros dominios via Azure Service Bus. Las opciones evaluadas fueron implementar
este flujo manualmente (deserializar mensajes, llamar handlers, publicar resultados) o usar
una libreria que lo estandarice.

El proyecto ControlPlane del mismo equipo ya valido en produccion el uso de Marten como event
store y Wolverine como mediador de comandos, encapsulados en los paquetes Cosmos.* publicados
en NuGet.org. Este conocimiento esta disponible para ser reutilizado.

## Decision

Se adoptan los siguientes paquetes para todos los dominios de ControlAsistencias:

| Paquete | Version | Rol |
|---------|---------|-----|
| `Cosmos.EventSourcing.CritterStack` | 2.1.0 | Configura Marten como event store |
| `Cosmos.EventSourcing.Abstractions` | 2.1.0 | Interfaces de event sourcing (IEventStore, etc.) |
| `Cosmos.EventDriven.CritterStack` | 2.1.0 | Configura Wolverine como mediador de comandos |
| `Cosmos.EventDriven.CritterStack.AzureServiceBus` | 2.1.0 | Integra Wolverine con Azure Service Bus |
| `Cosmos.EventDriven.Abstractions` | 2.1.0 | Interfaces de mensajeria (ICommandRouter, IPublicEventSender, etc.) |
| `Microsoft.Azure.Functions.Worker` | 2.52.0 | Metapaquete del worker aislado; fijado en lockstep con `Worker.OpenTelemetry` para evitar desalineamiento Core/Grpc |
| `Microsoft.Azure.Functions.Worker.OpenTelemetry` | 1.2.0 | Defaults de OpenTelemetry para el worker aislado de Functions |
| `OpenTelemetry.Extensions.Hosting` | 1.13.1 | SDK de hosting de OpenTelemetry; minimo exigido por `Worker.OpenTelemetry` |
| `Azure.Monitor.OpenTelemetry.Exporter` | 1.8.2 | Exporter de OpenTelemetry hacia Application Insights |

`Cosmos.EventSourcing.CritterStack` 2.1.0 arrastra Marten 9.12.0 -- la misma version que ya fijaba
1.3.0, sin cambio transitorio en este bump (verificado contra el nuspec real de
`Cosmos.EventSourcing.CritterStack` 2.0.0 y 2.1.0 en api.nuget.org: ambas declaran `Marten [9.12.0, )`,
igual que 1.3.0) --, que sigue resolviendo [GHSA-vmw2-qwm8-x84c](https://github.com/advisories/GHSA-vmw2-qwm8-x84c)
(CVE-2026-45288 -- sanitizacion insuficiente del parametro `regConfig` en las APIs de busqueda de
texto completo de Marten, permitiendo inyeccion de SQL arbitrario; corregida en Marten 8.37.0). No
hay reintroduccion del CVE. El salto 0.x -> 1.3.0 de los cinco paquetes `Cosmos.*` no introdujo
breaking changes de API (verificado por el consumidor Cosmos.ControlPlane: `dotnet build -c Release`
limpio y 111 tests unitarios en verde tras el bump, y `dotnet list package --vulnerable --include-transitive`
sin paquetes vulnerables).

El salto `1.3.0 -> 2.0.0 -> 2.1.0` (issue #312) se verifico decompilando con `ilspycmd` las tres
versiones de cada uno de los cinco `.dll` (descargados de `api.nuget.org/v3-flatcontainer/`) y
diffeando la superficie publica resultante -- los paquetes shipean solo binario, sin `.cs` publico
ni release notes en el nuspec. Resultado:

- **Sin cambios de API** en `Cosmos.EventSourcing.Abstractions`, `Cosmos.EventSourcing.CritterStack`
  y `Cosmos.EventDriven.CritterStack.AzureServiceBus`: el diff entre versiones solo toca
  `AssemblyInformationalVersion`. Todos los simbolos que citan los agentes del harness --
  `IEventStore`, `ICommandRouter`, `ICommandHandlerAsync<T>`, `AgregarWolverineParaComandosServerless`,
  `AgregarWolverineCommandRouter`, `AgregarWolverineEventSender`, `AgregarMartenEventStore`,
  `CommandHandlerAsyncTest<T>` -- mantienen nombre, namespace y firma sin cambios.
- **Breaking change real en `Cosmos.EventDriven.Abstractions` 2.0.0** (se conserva en 2.1.0): la
  sobrecarga `IPrivateEventSender.PublishAsync(string groupId, ...)` /
  `IPublicEventSender.PublishAsync(string groupId, ...)` se reemplaza por
  `PublishAsync(PublishOptions options, ...)`, con `PublishOptions { GroupId, Headers }` (record
  nuevo). La sobrecarga sin `groupId` (`PublishAsync(params IEvent[])`) no cambia. Este cambio rompe
  la invariante `groupId`/`SessionId` de ADR-0026 documentada en `agents/implementer.md` (seccion
  "`groupId` en `PublishAsync`") y el harness de testing `Cosmos.EventSourcing.Testing.Utilities`
  (`ThenIsPublishedPrivately(string groupId, ...)` / `ThenIsPublishedPublicly(string groupId, ...)`
  -> `(PublishOptions expectedOptions, ...)`; `TestPrivateEventSender.GetEventsByGroupId` /
  `TestPublicEventSender.GetEventsByGroupId` -> propiedad `PublishedWithOptions`). Corregido en el
  mismo cambio que este bump: `agents/implementer.md`, `agents/test-writer.md` y
  `docs/testing/harness-cheatsheet.md`. La doctrina de ADR-0024/ADR-0026/ADR-0027 no cambia -- el
  concepto `groupId` sigue existiendo, ahora como propiedad de `PublishOptions` en vez de argumento
  posicional -- y no requirio enmienda: ninguna contiene codigo C# literal con la firma vieja.
- **Aditivo en 2.1.0** (no rompe nada existente, prerrequisito de issue #313): `Cosmos.EventDriven.Abstractions`/
  `Cosmos.EventDriven.CritterStack` suman `IPrivateEventHandlerAsync<TEvent>`, `IPrivateEventRouter`,
  la clase `WolverinePrivateEventRouter` y el metodo de extension `AgregarWolverinePrivateEventRouter()`.
  `Cosmos.EventSourcing.Testing.Utilities` suma `PrivateEventHandlerAsyncTest<TEvent>`. Estos simbolos
  no existen antes de 2.1.0.
- **No verificado / fuera de alcance de issue #312**: `PublishOptions.Headers` (nuevo desde 2.0.0,
  `IReadOnlyDictionary<string, string>?`) estampa headers de Wolverine (`DeliveryOptions.WithHeader`,
  confirmado decompilando `Cosmos.EventDriven.CritterStack`) y podria levantar el "LIMITE verificado"
  que `agents/implementer.md` documenta en la seccion "Clave de enrutamiento como application
  property" (ADR-0027) -- no se confirmo en este cambio si el transporte
  `Cosmos.EventDriven.CritterStack.AzureServiceBus` traduce esos headers de Wolverine a application
  properties de Azure Service Bus. Se corrige unicamente la mencion de firma en esa seccion
  (`PublishAsync(groupId, events)` -> `PublishAsync(PublishOptions options, events)`); confirmar la
  traduccion a application properties y, si aplica, adoptar `Headers` para resolver el limite de
  ADR-0027 queda diferido a un issue de seguimiento -- no se implemento especulativamente.

Los paquetes `Microsoft.ApplicationInsights.WorkerService` y
`Microsoft.Azure.Functions.Worker.ApplicationInsights` se reemplazan por OpenTelemetry.

### Patron de configuracion en Program.cs

Cada Function App configura Wolverine y Marten con el metodo de extension
`AgregarWolverineParaComandosServerless`, que recibe:
- El assembly del dominio (via una interface marker) para el discovery automatico de handlers
- La connection string de PostgreSQL para Marten
- El nombre del schema de Marten para ese dominio (aislamiento de datos)
- Un callback para configurar Service Bus y declarar que eventos se publican a que topics

```csharp
builder.Services.AgregarWolverineParaComandosServerless(
    typeof(IDominioAssemblyMarker).Assembly,
    martenConnectionString,
    "nombre_schema",
    builder.Environment.IsDevelopment(),
    options =>
    {
        options.HabilitarAzureServiceBusParaServerLess(serviceBusConnectionString);
        options.PublicarEventoServerless<MiEvento>("eventos-dominio");
    });
```

### Interface marker

Cada dominio define una interface vacia en su namespace raiz para que Wolverine pueda
escanear el assembly y registrar los handlers automaticamente sin necesidad de nombrarlos
explicitamente:

```csharp
namespace Bitakora.ControlAsistencia.MiDominio;
public interface IMiDominioAssemblyMarker;
```

### Modo serverless

Wolverine opera en modo serverless: no hay bus in-process. Los eventos se publican
explicitamente a Azure Service Bus usando `IPublicEventSender` o `IPrivateEventSender`.
Los triggers de Service Bus (`[ServiceBusTrigger]`) despachan mensajes al `ICommandRouter`.

Wolverine en modo serverless distingue **dos senders** segun el marcador del evento: `IPrivateEventSender` publica al Azure Service Bus **propio** del bounded context (eventos privados intra-BC); `IPublicEventSender` publica al backbone compartido del producto (eventos publicos comunes) o, en el caso diferido de integracion verdaderamente externa, a un ASB externo. El wiring registra el ASB propio del BC como **broker default**, siempre, con `HabilitarAzureServiceBusParaServerLess(serviceBusInterno)`; el backbone compartido y, si aplica, cada ASB externo se registran como **brokers nombrados**, uno por ASB, con `AgregarAzureServiceBusNombradoServerless(<nombre>, <cadena>)`, cada uno leyendo su cadena de conexion custodiada. El wiring se mantiene **por cadena de conexion**, coherente con el paquete `Cosmos.EventDriven.CritterStack.AzureServiceBus` actual (spike #129 cerrado positivo); la custodia de las cadenas (Key Vault) y el acceso por managed identity como norte diferido se definen en ADR-0024 (decision #6 y Alt 4 respectivamente).

### Observabilidad

Se configura OpenTelemetry con AddSource para "Wolverine", "Marten" y el namespace del
dominio, en lugar del SDK propietario de ApplicationInsights. Para Azure Functions en modo
worker aislado no existe una ingesta automatica del host: sin un exporter explicito, OpenTelemetry
recolecta esos traces/metrics/logs y los descarta, y a Application Insights solo llegan los
`requests` que emite el propio host. El camino oficial (Microsoft Learn, "Use OpenTelemetry with
Azure Functions" -- el Azure Monitor OpenTelemetry Exporter es el metodo **recomendado** para apps
nuevas y existentes, ver "Monitor executions in Azure Functions") exige tres piezas:

1. El trio de paquetes `Microsoft.Azure.Functions.Worker.OpenTelemetry`, `OpenTelemetry.Extensions.Hosting`
   y `Azure.Monitor.OpenTelemetry.Exporter` (tabla de paquetes arriba) -- no
   `Azure.Monitor.OpenTelemetry.AspNetCore` (la distro de ASP.NET Core, no soportada para Functions
   isolated worker: trae `AspNetCoreInstrumentation` y duplica la telemetria de requests que el host
   de Functions ya emite).
2. En `Program.cs`, encadenar `.UseFunctionsWorkerDefaults()` y `.UseAzureMonitorExporter()` sobre
   `AddOpenTelemetry()`, junto al `.WithTracing(...).AddSource(...)` de siempre.
3. En `host.json`, `"telemetryMode": "OpenTelemetry"` en la raiz, para que el host tambien emita
   OpenTelemetry y se correlacione con el worker.

El exporter lee `APPLICATIONINSIGHTS_CONNECTION_STRING` (no soporta instrumentation key); ese valor
lo provee el `site_config.application_insights_connection_string` del modulo Terraform `function-app`
(ADR-0021), como referencia `@Microsoft.KeyVault(...)` versionless (ADR-0025).

**Nota de compatibilidad de versiones (issue #263):** `Microsoft.Azure.Functions.Worker.OpenTelemetry`
1.2.0 exige `Microsoft.Azure.Functions.Worker.Core >= 2.52.0` (nuspec del paquete, api.nuget.org). Por
eso el metapaquete `Microsoft.Azure.Functions.Worker` se fija explicitamente en `2.52.0` (tabla de
paquetes arriba): si queda en una version menor -- por ejemplo la que trae por defecto una plantilla
`func init` desactualizada --, `Worker.Core` sube a esa version minima por resolucion transitiva pero
`Worker.Grpc` puede quedar rezagado, y el desalineamiento entre ambos dispara `MissingMethodException`
en `DefaultTraceContext..ctor` al arrancar el host -- HTTP 500 en toda funcion del dominio (verificado
por el consumidor Cosmos.ControlPlane, PR #46).

## Consecuencias

**Positivas**

- Event Sourcing provee un log de auditoria completo e inmutable de todo lo que sucede en
  cada dominio, critico para el calculo de horas y la liquidacion de nomina.
- El patron es identico en todos los dominios: cualquier desarrollador puede entender la
  configuracion de un dominio nuevo leyendo la de cualquier otro.
- Wolverine en modo serverless no introduce overhead de infraestructura in-process y es
  compatible con el modelo de escalado de Azure Functions.
- Los paquetes Cosmos.* ya estan probados en produccion en ControlPlane, reduciendo el
  riesgo de adopcion.

**Negativas**

- Los paquetes `Cosmos.*` son mantenidos internamente por el equipo. Si hay un bug o se
  necesita una nueva version, el equipo debe publicar una nueva version en NuGet.org.
- Event Sourcing agrega complejidad en las consultas (queries requieren proyecciones o
  snapshots), lo cual no se necesita para simples operaciones CRUD de baja frecuencia.
- La curva de aprendizaje de Marten y Wolverine es mas alta que la de un ORM tradicional.

## Referencias

- ADR-0023: Bounded Context — define el ASB propio del BC (namespace interno, compartido por todos sus dominios) al que publica `IPrivateEventSender`.
- ADR-0024: modelo de eventos de bus (privado propio, publico via backbone compartido, integracion externa diferida) — define a que broker enruta `IPublicEventSender` (backbone compartido comun o ASB externo diferido) y el wiring de broker default mas N brokers nombrados por cadena de conexion custodiada.
- ADR-0021: infraestructura base — define el modulo Terraform `function-app` cuyo `site_config.application_insights_connection_string` provee el valor que el exporter de OpenTelemetry lee en runtime.
- ADR-0025: custodia de secretos — la connection string de Application Insights viaja como referencia `@Microsoft.KeyVault(...)` versionless, nunca en claro.
- Microsoft Learn: [Guide for running C# Azure Functions in the isolated worker model](https://learn.microsoft.com/azure/azure-functions/dotnet-isolated-process-guide#logging), [Use OpenTelemetry with Azure Functions](https://learn.microsoft.com/azure/azure-functions/opentelemetry-howto), [Monitor executions in Azure Functions](https://learn.microsoft.com/azure/azure-functions/functions-monitoring#telemetry-export-options).

## Control de cambios

- 2026-07-01: enmendado (issue #162, mandato de ADR-0024) para reemplazar el wiring fijo de dos brokers por Bounded Context (namespace interno como broker default + namespace de integracion como named broker `"integracion"`) por broker interno por defecto (siempre) mas N brokers nombrados (backbone compartido y, si aplica, externos), uno por ASB, por cadena de conexion custodiada.
- 2026-07-10: enmendado (issue #259) para corregir la seccion "Observabilidad" y la tabla de paquetes -- `Azure.Monitor.OpenTelemetry.AspNetCore` (distro de ASP.NET Core, no soportada para Functions isolated worker) se reemplaza por `Microsoft.Azure.Functions.Worker.OpenTelemetry` + `Azure.Monitor.OpenTelemetry.Exporter` (camino oficial de Functions), y se documenta que la telemetria del worker exige un exporter explicito (`.UseFunctionsWorkerDefaults()` + `.UseAzureMonitorExporter()`, `host.json` con `telemetryMode: "OpenTelemetry"`) -- sin ellos, OpenTelemetry recolecta y descarta, y Application Insights solo recibe los `requests` del host. La afirmacion previa de que "la infraestructura de Azure Monitor sigue siendo necesaria para que el agente de Application Insights reciba las trazas" describia una ingesta automatica que no existe para Functions isolated worker; se elimina del cuerpo.
- 2026-07-10: enmendado (issue #263) en dos frentes. **(a)** bump de los cinco paquetes `Cosmos.*` de pre-1.0 a `1.3.0` (sin breaking changes de API, verificado por el consumidor Cosmos.ControlPlane), que arrastra Marten `9.12.0` y resuelve [GHSA-vmw2-qwm8-x84c](https://github.com/advisories/GHSA-vmw2-qwm8-x84c)/CVE-2026-45288 (inyeccion SQL en Marten <= 8.36). **(b)** se completa el trio de OpenTelemetry del worker -- el bump de #259 solo habia agregado `Microsoft.Azure.Functions.Worker.OpenTelemetry` + `Azure.Monitor.OpenTelemetry.Exporter`, sin `OpenTelemetry.Extensions.Hosting` -- y se corrige `Microsoft.Azure.Functions.Worker.OpenTelemetry` de `1.4.0` (version que nunca existio en NuGet) a `1.2.0`; se fija ademas el metapaquete `Microsoft.Azure.Functions.Worker` en `2.52.0` en lockstep con el requisito `Worker.Core >= 2.52.0` de `Worker.OpenTelemetry` 1.2.0, para evitar el `MissingMethodException` en `DefaultTraceContext..ctor` (HTTP 500 en toda funcion) que dispara un desalineamiento Core/Grpc -- verificado por el consumidor Cosmos.ControlPlane (PR #46). Todas las versiones se verificaron contra el nuspec real de cada paquete en api.nuget.org al momento de este cambio.
- 2026-07-18: enmendado (issue #312, prerrequisito de issue #313) para bumpear los cinco paquetes `Cosmos.*` de `1.3.0` a `2.1.0`. El delta `1.3.0 -> 2.0.0 -> 2.1.0` se verifico decompilando con `ilspycmd` las tres versiones de cada `.dll` (los paquetes no publican codigo fuente ni release notes): Marten se mantiene en `9.12.0` (sin reintroducir GHSA-vmw2-qwm8-x84c/CVE-2026-45288) y los simbolos `IEventStore`, `ICommandRouter`, `ICommandHandlerAsync<T>`, `AgregarWolverineParaComandosServerless`, `AgregarWolverineCommandRouter`, `AgregarWolverineEventSender`, `AgregarMartenEventStore`, `CommandHandlerAsyncTest<T>` no cambiaron. Se encontro un breaking change real en `Cosmos.EventDriven.Abstractions` 2.0.0 (se conserva en 2.1.0): `IPrivateEventSender.PublishAsync(string groupId, ...)`/`IPublicEventSender.PublishAsync(string groupId, ...)` se reemplaza por `PublishAsync(PublishOptions options, ...)`; el mismo cambio corrige, ademas de `agents/domain-scaffolder.md` y este ADR, `agents/implementer.md` (seccion "`groupId` en `PublishAsync`") y `agents/test-writer.md`/`docs/testing/harness-cheatsheet.md` (DSL `ThenIsPublishedPrivately`/`ThenIsPublishedPublicly`), que citaban la firma vieja. 2.1.0 ademas agrega (aditivo, sin romper nada) `IPrivateEventHandlerAsync<TEvent>`, `IPrivateEventRouter`, `AgregarWolverinePrivateEventRouter()` y `PrivateEventHandlerAsyncTest<TEvent>` -- el prerrequisito que issue #313 necesita para enseñar el patron `PrivateEventHandler`. Queda diferido a un issue de seguimiento verificar si `PublishOptions.Headers` (nuevo desde 2.0.0) resuelve el "LIMITE verificado" de ADR-0027 sobre estampado de application properties arbitrarias.

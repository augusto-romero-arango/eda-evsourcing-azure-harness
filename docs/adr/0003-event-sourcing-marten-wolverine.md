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
| `Cosmos.EventSourcing.CritterStack` | 0.1.9 | Configura Marten como event store |
| `Cosmos.EventSourcing.Abstractions` | 0.0.12 | Interfaces de event sourcing (IEventStore, etc.) |
| `Cosmos.EventDriven.CritterStack` | 0.0.5 | Configura Wolverine como mediador de comandos |
| `Cosmos.EventDriven.CritterStack.AzureServiceBus` | 0.0.6 | Integra Wolverine con Azure Service Bus |
| `Cosmos.EventDriven.Abstractions` | 0.0.8 | Interfaces de mensajeria (ICommandRouter, IPublicEventSender, etc.) |
| `Azure.Monitor.OpenTelemetry.AspNetCore` | 1.4.0 | Observabilidad via OpenTelemetry |

Los paquetes `Microsoft.ApplicationInsights.WorkerService` y
`Microsoft.Azure.Functions.Worker.ApplicationInsights` se reemplazan por OpenTelemetry.
La infraestructura de Azure Monitor sigue configurada via app settings (no hay cambios en
Terraform para esta parte); solo cambia el SDK usado en el codigo C#.

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
dominio, en lugar del SDK propietario de ApplicationInsights. La infraestructura de Azure
Monitor (APPLICATIONINSIGHTS_CONNECTION_STRING en app settings) sigue siendo necesaria para
que el agente de Application Insights reciba las trazas de OpenTelemetry.

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

## Control de cambios

- 2026-07-01: enmendado (issue #162, mandato de ADR-0024) para reemplazar el wiring fijo de dos brokers por Bounded Context (namespace interno como broker default + namespace de integracion como named broker `"integracion"`) por broker interno por defecto (siempre) mas N brokers nombrados (backbone compartido y, si aplica, externos), uno por ASB, por cadena de conexion custodiada.

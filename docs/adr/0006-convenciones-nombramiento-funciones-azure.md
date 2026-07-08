# ADR-0006: Convenciones de nombramiento para funciones Azure y organizacion vertical

## Estado

Aceptado

## Contexto

Cada dominio del sistema es una Azure Function App con multiples funciones. Necesitamos
convenciones de nombramiento que sean:

1. Consistentes y predecibles para que los agentes de IA generen codigo correcto
2. A prueba de crecimiento: agregar una nueva funcion no debe forzar renombrar las existentes
3. Legibles tanto en el codigo como en el portal de Azure
4. Libres de colision de namespaces en la organizacion vertical de directorios

El proyecto de referencia (ControlPlane) tenia inconsistencias: `HandleOnboardingTopic` mezclaba
el nombre del topic con un prefijo Handle, y los nombres camelCase se destruian por el
lowercase forzado de Azure Service Bus.

## Decision

### Funciones HTTP

El nombre de la funcion Azure es el nombre del comando, como string literal:

```csharp
[Function("CrearTurno")]
```

El string literal evita la necesidad de `using` aliases por colision de namespaces
en la organizacion vertical (el record del comando y la clase del endpoint comparten namespace).

### Funciones ServiceBus

El nombre de la funcion describe la **accion** Y el **estimulo**, usando el patron
`{Accion}Cuando{Evento}`:

```csharp
[Function("DepurarMarcacionesCuandoTurnoCreado")]
[Function("NotificarSupervisorCuandoTurnoCreado")]
```

**Fundamento**: si una funcion se nombra solo por el estimulo (`CuandoTurnoCreado`) y
despues se necesita agregar otra reaccion al mismo evento, hay que renombrar la primera
para desambiguar — eso es un breaking change en Azure Functions (el nombre es la identidad
de la funcion en el runtime). Nombrando siempre por accion + estimulo, agregar nuevas
reacciones no rompe las existentes.

Inspirado en el patron del proyecto eShop de Microsoft:
`ValidateOrAddBuyerAggregateWhenOrderStartedDomainEventHandler`

### Organizacion vertical de directorios

Cada comando o reaccion a evento vive en su propio directorio:

```
src/Bitakora.ControlAsistencia.{Dominio}/
  CrearTurnoFunction/                    <- sufijo Function para evitar colision con el record
    CrearTurno.cs                        <- record del comando
    FunctionEndpoint.cs                  <- [Function("CrearTurno")]
    CommandHandler/
      CrearTurnoCommandHandler.cs
      CrearTurnoValidator.cs
  AsignarEmpleadoATurnoFunction/
    AsignarEmpleadoATurno.cs
    FunctionEndpoint.cs                  <- [Function("AsignarEmpleadoATurno")]
    CommandHandler/
      AsignarEmpleadoATurnoCommandHandler.cs
  Entities/                              <- AggregateRoots + eventos del dominio
    TurnoAggregateRoot.cs
    TurnoCreado.cs
    AsignacionEmpleadoFallida.cs
  Infraestructura/                       <- servicios transversales del dominio
    RequestValidator.cs
  DepurarMarcacionesCuandoTurnoCreado/   <- feature folder por reaccion a evento (sin sufijo Function)
    FunctionEndpoint.cs                  <- [Function("DepurarMarcacionesCuandoTurnoCreado")]
```

- `FunctionEndpoint.cs` como nombre de clase en cada directorio. No colisiona porque cada
  directorio es un namespace diferente.
- Sufijo `Function` en directorios HTTP para evitar colision entre el namespace y el record del comando.
  ServiceBus triggers sin sufijo (no tienen record con nombre colisionante).
- El directorio comunica la intencion; la clase es generica.

### Convenciones de nombramiento en codigo C#

| Concepto | Convencion | Ejemplo |
|---|---|---|
| Evento de exito | Sustantivo + pasado | `TurnoCreado`, `EmpleadoAsignado` |
| Evento de fallo | Pasado + contexto | `AsignacionEmpleadoFallida` |
| Comando | Verbo infinitivo + sustantivo | `CrearTurno`, `AsignarEmpleado` |
| CommandHandler | `{Comando}CommandHandler` | `CrearTurnoCommandHandler` |
| Validator | `{Comando}Validator` | `CrearTurnoValidator` |
| AggregateRoot | `{Entidad}AggregateRoot` | `TurnoAggregateRoot` |

Las clases son en espanol. Los sufijos de patrones reconocidos (CommandHandler, Validator,
AggregateRoot, Endpoint) son en ingles.

## Consecuencias

**Positivas**

- A prueba de crecimiento: agregar una nueva reaccion a un evento no rompe funciones existentes
- Sin colision de namespaces: cada `Endpoint.cs` vive en su propio namespace
- Autodocumentado: el nombre de la funcion dice que hace y a que reacciona
- Predecible: los agentes de IA pueden generar nombres correctos sin ambiguedad

**Negativas**

- Los nombres de funciones ServiceBus son largos (`DepurarMarcacionesCuandoTurnoCreado`)
- Los directorios tambien son largos, lo que puede afectar la legibilidad en el explorador de archivos
- El patron `{Accion}Cuando{Evento}` requiere disciplina desde el dia 1

## Nota (issue #245): limite real del nombre de la Function App

Esta ADR cubre el nombramiento de funciones y clases en codigo; el nombre del **recurso** Azure (`func-{prefix_func}-{kebab}`) tiene su propio limite, verificado contra las naming rules de Azure:

- El nombre de recurso `Microsoft.Web/sites` (Function App) admite **2-60 caracteres** (https://learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules#microsoftweb). El App Service Plan (`Microsoft.Web/serverfarms`) admite 1-60 en la misma tabla.
- Existe un limite distinto de **32 caracteres** para el **host ID** de Azure Functions (truncado del nombre), pero su colision solo ocurre **cuando dos Function Apps comparten la misma storage account** (https://learn.microsoft.com/azure/azure-functions/storage-considerations#host-id-considerations; evento de diagnostico AZFD0004: https://learn.microsoft.com/azure/azure-functions/errors-diagnostics/diagnostic-events/azfd0004). En este marco cada Function App tiene su propia Storage Account y su propio App Service Plan dedicado sin deployment slots (ADR-0020), por lo que esa colision no aplica y el limite de 32 no rige el nombre del recurso.
- `agents/domain-scaffolder.md` (Paso 0, Validacion 1) valida el nombre completo `func-{prefix_func}-{kebab}` contra el limite real de 60.

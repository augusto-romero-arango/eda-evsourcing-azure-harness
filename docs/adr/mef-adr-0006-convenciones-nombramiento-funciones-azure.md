# MEF-ADR-0006: Convenciones de nombramiento para funciones Azure y organizacion vertical

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

**Hueco (issue #363): Functions de query y artefactos de proyeccion.** Esta ADR, hasta esta
enmienda, cubria Functions HTTP de comando, ServiceBus y fan-in, pero no las Functions de query
(GET) ni los artefactos de proyeccion (read models, clases de proyeccion, named store) que
MEF-ADR-0034 (worker de proyecciones) y MEF-ADR-0035 (doctrina read-side) dejaron explicitamente
diferidos a esta enmienda. El mismo ControlPlane fue inconsistente tambien aqui: agrupo sus
queries en un unico `XQueriesEndpoint` por dominio (en vez de una carpeta por query), uso verbos
en ingles (`Get`/`List`) en vez de espanol, y no fijo un criterio unico de singular/plural para
las colecciones. Esta enmienda cierra ese hueco y da molde predecible a los futuros subagentes
read-side (Skill `projections`, `/scaffold-projections`, extension de `domain-scaffolder`).

## Decision

### Funciones HTTP

El nombre de la funcion Azure es el nombre del comando, como string literal:

```csharp
[Function("CrearTurno")]
```

El string literal evita la necesidad de `using` aliases por colision de namespaces
en la organizacion vertical (el record del comando y la clase del endpoint comparten namespace).

### Funciones HTTP de query (GET)

Una Function de query (lectura, GET) se nombra igual que un comando -- **verbo infinitivo espanol
+ sustantivo** -- pero con dos verbos fijos segun la cardinalidad del resultado:

| Cardinalidad | Patron | Ejemplo |
|---|---|---|
| Un item, por id | `Obtener{X}` | `ObtenerTurno` |
| Coleccion/filtro | `Listar{X}s` | `ListarTurnos` |

`{X}` es el **concepto** que la Function devuelve. Las tres vias de consulta que fija
MEF-ADR-0035 (seccion 3) mapean a este patron asi:

- **(a) Proyeccion materializada** (`session.LoadAsync<TView>(id)` / `session.Query<TView>()`):
  `Obtener{Concepto}` por id, `Listar{Concepto}s` por filtro/lista -- `{Concepto}` es el nombre
  base del read model (`TurnoView` -> `ObtenerTurno`).
- **(b1) Aggregate en vivo** (`session.Events.AggregateStreamAsync<T>(id)`, el mismo mecanismo
  `Live` que MEF-ADR-0015 ya fija como default de rehidratacion): `Obtener{Aggregate}` --
  `{Aggregate}` es el nombre del aggregate sin el sufijo `AggregateRoot`
  (`TurnoAggregateRoot` -> `ObtenerTurno`).
- **(b2) Eventos crudos del stream** (`session.Events.FetchStreamAsync(id)`):
  `ListarEventosDe{Aggregate}` (`ListarEventosDeTurno`).

**Colision deliberada entre (a) y (b1), y como se resuelve.** Cuando el read model y el aggregate
comparten concepto (el caso comun: `TurnoView` proyecta `TurnoAggregateRoot`), (a) y (b1)
producen el **mismo** nombre de Function (`ObtenerTurno`) -- y dos Functions con identico
`[Function("...")]` no pueden coexistir en la misma Function App. Esto no es un defecto del
patron: para un mismo concepto, un dominio expone **una sola** via de lectura por id a la vez
(la materializada (a) es la default de MEF-ADR-0035; (b1) es la excepcion cuando no existe --
todavia, o nunca -- una proyeccion materializada para ese concepto). Un dominio que de verdad
necesite ambas vias sobre el mismo concepto debe desambiguar el nombre explicitamente en el
issue que lo pida; este ADR no fija un calificador generico para ese caso porque MEF-ADR-0035 no
registra ningun caso real que lo necesite hoy (Rule of Three, MEF-ADR-0018).

**Ruta HTTP: REST por recurso, nunca el nombre de la Function.** A diferencia de una Function de
comando (sin `Route` explicito -- la ruta implicita es la propia Function), una Function de query
fija su propia ruta: sustantivo plural, con `{id}` cuando aplica.

```csharp
[Function("ObtenerTurno")]
public async Task<HttpResponseData> Run(
    [HttpTrigger(AuthorizationLevel.Function, "get", Route = "turnos/{id}")] HttpRequestData req, string id)

[Function("ListarTurnos")]
public async Task<HttpResponseData> Run(
    [HttpTrigger(AuthorizationLevel.Function, "get", Route = "turnos")] HttpRequestData req)
```

Verificado contra la documentacion oficial: el `Route` del `HttpTriggerAttribute` en el worker
aislado es opcional, y *"the default value if none is provided is `<functionname>`"*
(https://learn.microsoft.com/azure/azure-functions/functions-bindings-http-webhook-trigger#attributes)
-- sin este atributo, la ruta implicita seria `/api/ObtenerTurno`, no el recurso REST que este
ADR fija. El GET y el POST del mismo recurso quedan distinguidos por el **verbo HTTP** (`"get"`
vs sin metodo/`"post"`), nunca por el nombre de la Function: Azure Functions enruta por el par
(metodo, plantilla), no solo por plantilla, asi que `CrearTurno` y `ObtenerTurno` pueden
compartir el segmento `turnos`/`turnos/{id}` sin colisionar.

**Nunca `Route = ""`**: fijar la ruta vacia para que una query quede en la raiz de `/api`
produce 404 en el worker aislado -- comportamiento observado en campo, **no verificado** aqui
contra un caso reproducible de la documentacion oficial (que solo documenta el default
`<functionname>` y la opcion de quitar el prefijo `api` entero via `host.json`, no el caso
especifico de una plantilla vacia con el prefijo presente). Se trata como regla operativa de
este ADR hasta que un issue puntual la reverifique empiricamente.

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

**Excepcion: Functions de fan-in sobre un queue con sesion (MEF-ADR-0026).** El patron `{Accion}Cuando{Evento}` asume un estimulo unico. Cuando la Function consume un queue de fan-in donde convergen N eventos (potencialmente de tipos distintos) sobre la misma decision de aggregate, no hay un unico estimulo que nombrar sin ser enganoso. La convencion para este caso es distinta: el nombre de la Function es el nombre del **queue** en PascalCase (el queue en si va en kebab-case), y describe la decision o convergencia que resuelve, no un evento puntual. Ejemplo: queue `consolidar-cierre-turno` -> Function `ConsolidarCierreTurno`. El detalle de la doctrina de fan-in vive en MEF-ADR-0026; esta seccion documenta unicamente la desviacion de naming.

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
  ObtenerTurno/                          <- feature folder por query GET (sin sufijo Function)
    FunctionEndpoint.cs                  <- [Function("ObtenerTurno")], Route = "turnos/{id}"
  ListarTurnos/
    FunctionEndpoint.cs                  <- [Function("ListarTurnos")], Route = "turnos"
```

- `FunctionEndpoint.cs` como nombre de clase en cada directorio. No colisiona porque cada
  directorio es un namespace diferente.
- Sufijo `Function` en directorios HTTP **de comando** para evitar colision entre el namespace y
  el record del comando. ServiceBus triggers y Functions de query GET van sin sufijo: ninguno de
  los dos tiene un record de comando con nombre colisionante en su propio directorio.
- Las Functions de query GET van **una carpeta por query**, nunca agrupadas bajo un unico
  endpoint de coleccion (p. ej. `XQueriesEndpoint`, patron descartado -- ver "Nota" al final de
  este ADR): es el mismo criterio de organizacion vertical que ya rige comandos y reacciones a
  evento (una carpeta = un namespace = una responsabilidad).
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
| Query (Function/metodo GET) | Verbo infinitivo + sustantivo: `Obtener{X}` (item por id) / `Listar{X}s` (coleccion) | `ObtenerTurno`, `ListarTurnos` |
| Read model (view) | `{Concepto}View` | `TurnoView` |
| Clase de proyeccion (companion, N2 de MEF-ADR-0035) | `{Concepto}Projection` (`partial`, mismo stem que su View) | `ResumenEquipoProjection` -> `ResumenEquipoView` |
| Marker del named store de proyecciones | `I{Dominio}ProjectionStore` | `IVentasProjectionStore` |
| Seam de composicion de proyecciones (por dominio) | `ConfiguracionMartenProjections{Dominio}`, metodo `Configurar{Dominio}` | `ConfiguracionMartenProjectionsVentas.ConfigurarVentas()` |

Las clases son en espanol. Los sufijos de patrones reconocidos (CommandHandler, Validator,
AggregateRoot, Endpoint, View, Projection, ProjectionStore) son en ingles. El estilo de codigo y
la superficie de consulta de estos artefactos de proyeccion (record inmutable, metodos
convencionales `Create`/`Apply`/`ShouldDelete`, `QuerySession` acotada al tenant) los fija
MEF-ADR-0035, no este ADR -- aqui solo se fija el naming.

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
- Existe un limite distinto de **32 caracteres** para el **host ID** de Azure Functions (truncado del nombre), pero su colision solo ocurre **cuando dos Function Apps comparten la misma storage account** (https://learn.microsoft.com/azure/azure-functions/storage-considerations#host-id-considerations; evento de diagnostico AZFD0004: https://learn.microsoft.com/azure/azure-functions/errors-diagnostics/diagnostic-events/azfd0004). En este marco cada Function App tiene su propia Storage Account y su propio App Service Plan dedicado sin deployment slots (MEF-ADR-0020), por lo que esa colision no aplica y el limite de 32 no rige el nombre del recurso.
- `agents/domain-scaffolder.md` (Paso 0, Validacion 1) valida el nombre completo `func-{prefix_func}-{kebab}` contra el limite real de 60.

## Nota (issue #269, MEF-ADR-0026): excepcion de naming para Functions de fan-in

MEF-ADR-0026 (colas de Service Bus con sesion para fan-in y serializacion por clave de aggregate) documenta un caso donde el patron `{Accion}Cuando{Evento}` de este ADR no aplica: la Function que consume un queue de fan-in no reacciona a un estimulo unico, sino a la convergencia de N eventos sobre la misma decision de aggregate. La seccion "Decision > Funciones ServiceBus" arriba fija la convencion alterna para ese caso (nombre de la Function = nombre del queue en PascalCase); MEF-ADR-0026 fija la invariante completa "queue kebab-case = nombre de la Function que lo consume" y el porque de la excepcion.

## Nota (issue #363, MEF-ADR-0035): naming de Functions de query y artefactos de proyeccion

Esta ADR, hasta esta enmienda, cubria Functions HTTP de comando, ServiceBus y fan-in, pero no las Functions de query (GET) ni los artefactos de proyeccion que MEF-ADR-0034 (worker de proyecciones) y MEF-ADR-0035 (doctrina read-side) dejaron explicitamente diferidos a esta enmienda -- ambos lo registran en su propia cabecera/seccion 6. Las secciones "Funciones HTTP de query (GET)" y las filas nuevas de "Convenciones de nombramiento en codigo C#" arriba fijan ese naming.

Se descarta explicitamente el patron `XQueriesEndpoint` (una unica clase agrupando todas las queries de un dominio) que uso el proyecto de referencia ControlPlane: rompe el mismo invariante de organizacion vertical que ya rige comandos y reacciones a evento (una carpeta = un namespace = una responsabilidad), y reintroduce el riesgo de colision de nombres que el sufijo `Function`/su ausencia ya resuelven caso por caso. Cross-referencia MEF-ADR-0035 (superficie de consulta y estilo de codigo de las proyecciones que estas Functions exponen) y MEF-ADR-0029 (el endpoint GET vive en el Function App del write-side, mismo host cuyo grafo de DI valida el test de composicion).

## Control de cambios

- 2026-07-26: enmendado (issue #363, hermano de MEF-ADR-0035) para fijar el naming de las Functions HTTP de query (GET) -- `Obtener{X}`/`Listar{X}s`, con los casos especificos `Obtener{Aggregate}` (via (b1) `Live`) y `ListarEventosDe{Aggregate}` (via (b2) eventos crudos) que fija MEF-ADR-0035 seccion 3 -- su ruta HTTP (REST por recurso, nunca `Route = ""`), la organizacion vertical (una carpeta por query sin sufijo `Function`, descartando el patron agrupado `XQueriesEndpoint` de ControlPlane) y el naming de los artefactos de proyeccion (`{Concepto}View`, `{Concepto}Projection`, `I{Dominio}ProjectionStore`, seam `ConfiguracionMartenProjections{Dominio}`/`Configurar{Dominio}`).

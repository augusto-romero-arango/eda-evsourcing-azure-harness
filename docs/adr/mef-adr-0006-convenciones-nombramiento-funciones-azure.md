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

**Queries y artefactos de proyeccion (issue #363).** El read-side suma dos familias de nombres a
las de comando/ServiceBus: las Functions HTTP de query (GET) y los artefactos de proyeccion (read
models, clases de proyeccion, named store) que introducen MEF-ADR-0034 (worker de proyecciones) y
MEF-ADR-0035 (doctrina read-side). ControlPlane volvio a ser inconsistente ahi: agrupo sus queries
en un unico `XQueriesEndpoint` por dominio en vez de una carpeta por query, uso verbos en ingles
(`Get`/`List`) en vez de espanol, y no fijo un criterio unico de singular/plural para las
colecciones. Los subagentes read-side (Skill `projections`, `/scaffold-projections`, extension de
`domain-scaffolder`) necesitan un molde igual de predecible para estos nombres.

## Decision

### Funciones HTTP

El nombre de la funcion Azure es el nombre del comando, como string literal:

```csharp
[Function("CrearTurno")]
```

El string literal evita la necesidad de `using` aliases por colision de namespaces
en la organizacion vertical (el record del comando y la clase del endpoint comparten namespace).

### Funciones HTTP de query (GET/QUERY)

Una Function de query (lectura, GET o QUERY -- MEF-ADR-0042 fija el criterio decidible de cuando
usar cada metodo HTTP, RFC 10008) se nombra igual que un comando -- **verbo infinitivo espanol
+ sustantivo** -- pero con dos verbos fijos segun la cardinalidad del resultado:

| Cardinalidad | Patron | Ejemplo |
|---|---|---|
| Un item, por id | `Obtener{X}` | `ObtenerTurno` |
| Coleccion/filtro | `Listar{X}s` | `ListarTurnos` |

El `s` de `Listar{X}s` es el **plural correcto del espanol**, no un sufijo literal: `Perfil` ->
`ListarPerfiles`, `Mes` -> `ListarMeses`, nunca `ListarPerfils`. Es la **misma palabra plural** que
nombra el recurso en la ruta HTTP (ver abajo; ahi la capitalizacion y el prefijo los hereda del
segmento que ya declaro el comando de ese recurso), de modo que nombre de Function y ruta no se
derivan por separado -- es el criterio unico de singular/plural que faltaba en ControlPlane.

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

**El metodo QUERY (RFC 10008) no cambia nombre ni ruta -- solo el verbo declarado (issue #587,
MEF-ADR-0042).** Cuando `Listar{X}s` expone filtros estructurados (combinaciones AND/OR, rangos,
listas de valores) o paginacion por cursor, MEF-ADR-0042 fija que el metodo HTTP pasa de GET a
QUERY -- pero el nombre de la Function (`[Function("Listar{X}s")]`) y su `Route` (el mismo
segmento de recurso REST que ya fija esta seccion) **no cambian**: el verbo HTTP es lo unico que
distingue GET de QUERY para el mismo recurso, igual que ya distingue GET de POST en el mismo
segmento (ver "Cada Function declara su verbo, siempre" mas abajo). Un dominio que empiece con
`Listar{X}s` sobre GET y despues necesite filtros estructurados no renombra la Function ni cambia
su ruta al migrar a QUERY -- solo cambia el segundo argumento del `HttpTriggerAttribute` (`"get"`
-> `"query"`). El criterio de cuando cruzar esa frontera, la doctrina de paginacion y la de
filtros multiples viven en MEF-ADR-0042, no en este ADR.

**Ruta HTTP: REST por recurso, nunca el nombre de la Function.** Toda Function HTTP del marco --
comando y query -- declara su `Route` explicitamente; el default del atributo nunca se usa. Una
query reutiliza **el mismo segmento de recurso que ya usa el comando de ese recurso** (el ejemplo
canonico del marco es `Route = "programacion/turnos"` del endpoint de comando en
`agents/implementer.md`), sumando `{id}` para el caso de un item. **El verbo HTTP y la forma de
ruta de un comando** (POST a la coleccion, PUT, DELETE o `POST {recurso}:{verbo}`, segun el test
de precedencia por comando) **los fija MEF-ADR-0043, no esta seccion** -- aqui solo se fija que
toda query comparte el segmento de recurso de su comando, y el casing (kebab-case minusculo en
todo segmento, comando o query, MEF-ADR-0043 seccion 3):

```csharp
// ObtenerTurno/FunctionEndpoint.cs
[Function("ObtenerTurno")]
public async Task<IActionResult> Run(
    [HttpTrigger(AuthorizationLevel.Function, "get", Route = "programacion/turnos/{id}")]
    HttpRequest req,
    Guid id,
    CancellationToken ct)

// ListarTurnos/FunctionEndpoint.cs  <- clase y namespace distintos: una carpeta por query
[Function("ListarTurnos")]
public async Task<IActionResult> Run(
    [HttpTrigger(AuthorizationLevel.Function, "get", Route = "programacion/turnos")]
    HttpRequest req,
    CancellationToken ct)
```

El tipo de la request es `HttpRequest` y el retorno `IActionResult` -- la **integracion ASP.NET
Core** del worker aislado --, no `HttpRequestData`/`HttpResponseData`: es el modelo que ya usan
todos los endpoints que genera el marco (`agents/domain-scaffolder.md` para `health`/`version`,
`agents/implementer.md` para el endpoint de comando). El modelo alterno (built-in, con tipos
propios del worker) la documentacion oficial lo describe como *"maintained for backward
compatibility with previous .NET isolated worker apps"*
(https://learn.microsoft.com/azure/azure-functions/dotnet-isolated-process-guide#http-trigger):
una query escrita con esos tipos quedaria fuera de convencion en su propio host.

**Por que `Route` explicito**: verificado contra la documentacion oficial, el `Route` del
`HttpTriggerAttribute` es opcional y *"the default value if none is provided is `<functionname>`"*
(https://learn.microsoft.com/azure/azure-functions/functions-bindings-http-webhook-trigger#attributes)
-- sin el atributo, la ruta seria `/api/ObtenerTurno`, no el recurso REST que este ADR fija.

**Cada Function declara su verbo, siempre.** El GET y el POST del mismo recurso se distinguen por
el **metodo HTTP**, nunca por el nombre de la Function -- y eso obliga a declarar el metodo en
**ambos** lados. Verificado contra la misma referencia: el parametro `Methods` tambien es opcional
y *"if not specified, the function responds to all HTTP methods"*, asi que un comando que omita su
`"post"` captura tambien el GET del mismo segmento y se pisa con la query. El diseno "misma URL
para GET y POST del mismo recurso logico" es el que documenta ASP.NET Core para APIs REST
(*"many operations, such as GET and POST on the same logical resource, use the same URL"*,
https://learn.microsoft.com/aspnet/core/mvc/controllers/routing#http-verb-templates); lo que
**no** esta verificado aqui es que dos Functions con plantilla de ruta identica y verbos disjuntos
convivan sin conflicto en el host de Azure Functions -- la referencia del HTTP trigger no cubre
ese caso. La query por id no lo necesita (su plantilla lleva `{id}` y no coincide con la del POST
de creacion); el par que si comparte plantilla (`ListarTurnos` GET vs `CrearTurno` POST) debe
verificarse empiricamente en el primer dominio que lo implemente.

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
    FunctionEndpoint.cs                  <- [Function("ObtenerTurno")], Route = "programacion/turnos/{id}"
  ListarTurnos/
    FunctionEndpoint.cs                  <- [Function("ListarTurnos")], Route = "programacion/turnos"
```

- `FunctionEndpoint.cs` como nombre de clase en cada directorio. No colisiona porque cada
  directorio es un namespace diferente.
- Sufijo `Function` en directorios HTTP **de comando** para evitar colision entre el namespace y
  el record del comando. ServiceBus triggers y Functions de query GET van sin sufijo: ninguno de
  los dos tiene un record de comando con nombre colisionante en su propio directorio.
- Las Functions de query GET van **una carpeta por query**, nunca agrupadas en una sola clase que
  aloje todas las queries del dominio (p. ej. `XQueriesEndpoint`, patron descartado -- ver "Nota"
  al final de este ADR): es el mismo criterio de organizacion vertical que ya rige comandos y
  reacciones a evento (una carpeta = un namespace = una responsabilidad).
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
| Query (Function/metodo GET o QUERY) | Verbo infinitivo + sustantivo: `Obtener{X}` (item por id) / `Listar{X}s` (coleccion, GET o QUERY segun MEF-ADR-0042) | `ObtenerTurno`, `ListarTurnos` |
| Read model (vista de lectura) | Nombre valioso del lenguaje ubicuo, sin sufijo de implementacion (MEF-ADR-0041) | `ResumenAsistenciaDiaria` |
| Clase de proyeccion (companion, N1/N2 de MEF-ADR-0035) | `{TerminoVista}Projection` (`partial`, mismo stem que la vista) | `ResumenAsistenciaDiariaProjection` -> `ResumenAsistenciaDiaria` |
| Marker del named store de proyecciones | `I{Dominio}ProjectionStore` | `IVentasProjectionStore` |
| Seam de composicion de proyecciones (por dominio) | `ConfiguracionMartenProjections{Dominio}`, metodo `Configurar{Dominio}` | `ConfiguracionMartenProjectionsVentas.ConfigurarVentas()` |

El seam de proyecciones es el hermano read-side del seam de composicion del write-side que fija
MEF-ADR-0029 (`ComposicionServicios{Dominio}` / `AgregarServicios{Dominio}`): misma idea de una
fuente unica de wiring por dominio compartida entre el host y su test, distinto proceso y distinto
nombre para que nunca se confundan al leer un `Program.cs`.

Las clases son en espanol. Los sufijos de patrones reconocidos (CommandHandler, Validator,
AggregateRoot, Endpoint, Projection, ProjectionStore) son en ingles. El read model es la
excepcion deliberada: no lleva sufijo tecnico -- su nombre es un termino del lenguaje ubicuo
(MEF-ADR-0041). El estilo de codigo y
la superficie de consulta de estos artefactos de proyeccion (record de read model plano sin
`partial`, clase de proyeccion companion `partial` con metodos convencionales
`Create`/`Apply`/`ShouldDelete` -- misma forma en N1 y N2 --, y la `QuerySession` acotada al
tenant) los fija MEF-ADR-0035, no este ADR: aqui solo se fija el naming.

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

Esta ADR cubre el nombramiento de funciones y clases en codigo; el nombre del **recurso** Azure (`func-{kebab}-{prefix_func}`) tiene su propio limite, verificado contra las naming rules de Azure:

- El nombre de recurso `Microsoft.Web/sites` (Function App) admite **2-60 caracteres** (https://learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules#microsoftweb). El App Service Plan (`Microsoft.Web/serverfarms`) admite 1-60 en la misma tabla.
- Existe un limite distinto de **32 caracteres** para el **host ID** de Azure Functions (truncado del nombre), pero su colision solo ocurre **cuando dos Function Apps comparten la misma storage account** (https://learn.microsoft.com/azure/azure-functions/storage-considerations#host-id-considerations; evento de diagnostico AZFD0004: https://learn.microsoft.com/azure/azure-functions/errors-diagnostics/diagnostic-events/azfd0004). En este marco cada Function App tiene su propia Storage Account y su propio App Service Plan dedicado sin deployment slots (MEF-ADR-0020), por lo que esa colision no aplica y el limite de 32 no rige el nombre del recurso.
- `agents/domain-scaffolder.md` (Paso 0, Validacion 1) valida el nombre completo `func-{kebab}-{prefix_func}` contra el limite real de 60.

## Nota (issue #269, MEF-ADR-0026): excepcion de naming para Functions de fan-in

MEF-ADR-0026 (colas de Service Bus con sesion para fan-in y serializacion por clave de aggregate) documenta un caso donde el patron `{Accion}Cuando{Evento}` de este ADR no aplica: la Function que consume un queue de fan-in no reacciona a un estimulo unico, sino a la convergencia de N eventos sobre la misma decision de aggregate. La seccion "Decision > Funciones ServiceBus" arriba fija la convencion alterna para ese caso (nombre de la Function = nombre del queue en PascalCase); MEF-ADR-0026 fija la invariante completa "queue kebab-case = nombre de la Function que lo consume" y el porque de la excepcion.

## Nota (issue #363, MEF-ADR-0035): patron `XQueriesEndpoint` descartado

Se descarta explicitamente el patron `XQueriesEndpoint` (una unica clase agrupando todas las queries de un dominio) que uso el proyecto de referencia ControlPlane: rompe el mismo invariante de organizacion vertical que ya rige comandos y reacciones a evento (una carpeta = un namespace = una responsabilidad), y reintroduce el riesgo de colision de nombres que el sufijo `Function`/su ausencia ya resuelven caso por caso. Las secciones "Funciones HTTP de query (GET/QUERY)" y las filas de query/proyeccion de "Convenciones de nombramiento en codigo C#" arriba fijan la alternativa.

Cross-referencias: MEF-ADR-0035 (superficie de consulta y estilo de codigo de las proyecciones que estas Functions exponen -- su seccion 6 delega en este ADR el naming exacto de las Functions de query), MEF-ADR-0034 (worker de proyecciones, que fija el named store y el seam de composicion cuyos nombres registra la tabla de arriba) y MEF-ADR-0029 (el endpoint GET vive en el Function App del write-side, mismo host cuyo grafo de DI valida el test de composicion).

## Nota (issue #581, MEF-ADR-0041): el read model pierde el sufijo `View`

La tabla de "Convenciones de nombramiento en codigo C#" fijaba el read model como `{Concepto}View`. MEF-ADR-0041 retira ese sufijo: el nombre del record es un termino valioso del lenguaje ubicuo (`ResumenAsistenciaDiaria`, no `ResumenAsistenciaDiariaView`) -- el rol del tipo ya lo declara su ubicacion (`<RootNamespace>.ReadModels`, MEF-ADR-0034 seccion 5), no su sufijo. La clase de proyeccion companion conserva su sufijo tecnico (`{TerminoVista}Projection`, mismo stem que la vista) porque es artefacto de infraestructura del worker, no objeto del dominio. La colision (a)/(b1) que documenta la seccion "Funciones HTTP de query (GET/QUERY)" arriba (`TurnoView` proyecta `TurnoAggregateRoot`, ambas vias resuelven a `ObtenerTurno`) queda resuelta mejor por la politica misma de MEF-ADR-0041: con nombre propio, `Obtener{TerminoVista}` no colisiona con `Obtener{Aggregate}` por construccion, salvo el caso residual de una vista genuinamente 1:1 con el aggregate (MEF-ADR-0041, "Consecuencias negativas").

## Nota (issue #587, MEF-ADR-0042): `Listar{X}s` conserva nombre y ruta cuando su verbo es QUERY

MEF-ADR-0042 fija la frontera decidible entre GET y QUERY (RFC 10008) para `Listar{X}s`: GET para
filtros planos de igualdad en query string, QUERY para filtros estructurados (AND/OR, rangos,
listas de valores) y paginacion por cursor. Esta seccion no gana un tercer verbo ni una tercera
fila de naming -- el patron `Listar{X}s` (seccion "Funciones HTTP de query (GET/QUERY)" arriba)
sigue siendo el mismo nombre y la misma ruta para ambos metodos; solo el argumento de verbo del
`HttpTriggerAttribute` distingue uno de otro. La doctrina de paginacion y de filtros multiples que
motiva la eleccion vive integramente en MEF-ADR-0042.

## Control de cambios

- 2026-07-26: enmendado (issue #363, hermano de MEF-ADR-0035) para fijar el naming de las Functions HTTP de query (GET) -- `Obtener{X}`/`Listar{X}s` con plural real del espanol, y los casos especificos `Obtener{Aggregate}` (via (b1) `Live`) y `ListarEventosDe{Aggregate}` (via (b2) eventos crudos) que fija MEF-ADR-0035 seccion 3 --, su ruta HTTP (REST por recurso, reutilizando el segmento del comando de ese recurso, con verbo HTTP declarado explicitamente en ambos lados y nunca `Route = ""`), la organizacion vertical (una carpeta por query sin sufijo `Function`, descartando el patron agrupado `XQueriesEndpoint` de ControlPlane) y el naming de los artefactos de proyeccion (`{Concepto}View`, `{Concepto}Projection`, `I{Dominio}ProjectionStore`, seam `ConfiguracionMartenProjections{Dominio}`/`Configurar{Dominio}`, hermano del seam write-side de MEF-ADR-0029).
- 2026-07-27: enmendada la fila `{Concepto}Projection` de la tabla de naming y su nota (issue #412, hermano de la enmienda de MEF-ADR-0034/0035). La clase de proyeccion companion deja de ser exclusiva de N2: con el estilo canonico unificado que fija MEF-ADR-0035 seccion 2, N1 tambien la usa (el read model auto-agregante con `partial` deja de ser el canonico del marco). La nota sobre el `partial` se ajusta: aplica a la clase de proyeccion companion en ambos niveles, nunca al record de read model.
- 2026-08-07: enmendadas la tabla de "Convenciones de nombramiento en codigo C#" y la lista de sufijos tecnicos (issue #581, creacion de MEF-ADR-0041). El read model pierde el sufijo `View` -- su nombre pasa a ser un termino valioso del lenguaje ubicuo, sin sufijo de implementacion; `View` sale de la lista de sufijos tecnicos en ingles. La clase de proyeccion companion conserva su sufijo (`{TerminoVista}Projection`, mismo stem que la vista). Suma la nota "issue #581, MEF-ADR-0041" documentando el cambio y su efecto sobre la colision (a)/(b1) ya documentada en este ADR.
- 2026-08-11: enmendada la seccion "Funciones HTTP de query" (issue #587, creacion de MEF-ADR-0042). El titulo pasa a "Funciones HTTP de query (GET/QUERY)": una Function de query ya no es exclusivamente GET -- MEF-ADR-0042 fija el criterio decidible para elegir GET o el metodo QUERY (RFC 10008) segun la forma del filtro (plano de igualdad vs estructurado) o si expone paginacion por cursor. Fija que cruzar esa frontera no cambia el nombre de la Function ni su `Route`: solo el verbo declarado en el `HttpTriggerAttribute`. La tabla de "Convenciones de nombramiento en codigo C#" ajusta su fila de Query a "GET o QUERY". Suma la nota "issue #587, MEF-ADR-0042" documentando el cambio.
- 2026-08-14: enmendada la seccion "Ruta HTTP" (issue #621, creacion de MEF-ADR-0043). El ejemplo canonico de `Route` pasa de PascalCase (`Programacion/Turnos`) a kebab-case minusculo (`programacion/turnos`) -- casing que MEF-ADR-0043 seccion 3 fija como regla explicita para todo segmento de ruta, comando o query. La seccion deja de ser la fuente del verbo HTTP y la forma de ruta de un comando (POST a la coleccion, PUT, DELETE o `POST {recurso}:{verbo}`): esa doctrina, con su test de precedencia de cinco pasos, vive ahora en MEF-ADR-0043; esta seccion conserva solo que la query comparte el segmento de recurso de su comando y el casing.
- 2026-08-27: corregida la nota del issue #245 (issue #733, aplicacion de MEF-ADR-0045). El nombre del recurso Azure que esa nota cita pasa de `func-{prefix_func}-{kebab}` a `func-{kebab}-{prefix_func}`: el dominio cumple el rol `{uso}` del patron CAF y va inmediatamente despues de la abreviatura de tipo (MEF-ADR-0045 seccion 1). El limite de 60 chars y el deslinde host ID/nombre de recurso no cambian; el deslinde de alcance con MEF-ADR-0045 (este ADR gobierna el nombre logico de la Function, no el del recurso ARM) sigue vigente sin enmienda.

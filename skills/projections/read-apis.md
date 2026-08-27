# Read APIs: como consultar una proyeccion o un aggregate

Fuente: MEF-ADR-0035 secciones 3-5 (superficie de consulta); MEF-ADR-0041 decision 4 (frontera HTTP del GET, DTO de respuesta bajo Rule of Three); MEF-ADR-0042 (frontera GET vs QUERY, paginacion y filtros multiples). Toda API de esta pagina esta disponible sobre `IQuerySession` salvo donde se indique lo contrario.

## Tabla de read APIs canonicas

| Superficie | API canonica | Tipo de sesion |
|---|---|---|
| (a) Proyeccion materializada, por id | `session.LoadAsync<TView>(id)` | `QuerySession` |
| (a') Proyeccion materializada, por filtro/lista | `session.Query<TView>()` (LINQ) | `QuerySession` |
| (b1) Hidratar aggregate a demanda (`Live`) | `session.Events.AggregateStreamAsync<T>(id)` | `QuerySession` |
| (b2) Eventos crudos del stream | `session.Events.FetchStreamAsync(id)` | `QuerySession` |
| Opt-in documentado (no default) | `session.Events.FetchLatest<T>(id)` | requiere `IDocumentSession` -- **no disponible en `QuerySession`** |

`QuerySession` es la sesion de solo lectura de Marten -- *"For strictly read-only querying, the `QuerySession` is a lightweight session that is optimized for reading"*, sin identity map ni dirty checking. Las cuatro APIs canonicas ((a), (a'), (b1), (b2)) estan disponibles sobre ella: `IQuerySession` declara `IQueryEventStore Events { get; }`, y esa interfaz declara `FetchStreamAsync(...)` y `AggregateStreamAsync<T>(...)` -- ninguna de las cuatro exige una sesion de escritura.

## Cuando usar cada via

- **(a)/(a')**: default. Consulta el documento que el daemon del worker ya mantiene actualizado (MEF-ADR-0034). Es la via mas barata -- no reaplica eventos en el momento de la consulta.
- **(b1)**: cuando no existe -- todavia, o nunca -- una proyeccion materializada para ese concepto. Reconstruye el estado actual reaplicando todos los eventos del stream. Es el **mismo mecanismo** `Live` que MEF-ADR-0015 ya fija como default de rehidratacion del `AggregateRoot` de escritura -- no se introduce un segundo modelo de reconstruccion.
- **(b2)**: para un consumidor que necesita el historial de eventos en si (auditoria, debugging, un cliente que reconstruye su propia vista), sin que el marco le imponga ninguna forma agregada.

**Colision entre (a) y (b1), ahora infrecuente por construccion**: cuando el read model y el aggregate comparten concepto, ambas vias producirian el mismo nombre de Function -- un dominio expone **una sola** via de lectura por id a la vez (la materializada (a) es la default; (b1) es la excepcion). Con un read model nombrado por su necesidad de lectura en vez de calcado del aggregate (`ResumenAsistenciaDiaria`, no `Asistencia`), esa colision deja de ocurrir en el caso comun (MEF-ADR-0041 decision 3). Ver [naming.md](naming.md).

## `FetchLatest`: opt-in, no default

*"For internal reasons, the `FetchLatest()` API is only available off of `IDocumentSession` and not `IQuerySession`"*. Adoptarlo para un endpoint de lectura significa abrir una sesion de **escritura** (`LightweightSession`) solo para leer -- el mismo tipo de excepcion-opt-in que MEF-ADR-0034 ya aplica a `Inline` frente a `Async`. Util cuando se necesita el comportamiento adaptativo por ciclo de vida (`Live` -> `AggregateStreamAsync`; `Inline` -> documento persistido; `Async` -> snapshot + eventos no aplicados en memoria), pero **no** es el camino feliz por defecto.

## Patron de seguridad: sesion acotada al tenant resuelto, nunca al id de la ruta

Toda `QuerySession` de un endpoint de lectura se abre **acotada al tenant que resolvio `ITenantResolver`** (MEF-ADR-0028) -- **nunca** a un tenant id que llegue en la ruta, el query string o el body de la request:

```csharp
// CORRECTO: el tenant viene del resolver, no de la request.
// ITenantResolver expone TenantId/UserId como PROPIEDADES, no metodos (MEF-ADR-0028 seccion 1).
await using var session = store.QuerySession(tenantResolver.TenantId);
var seguimiento = await session.LoadAsync<SeguimientoTurno>(turnoId.ToString()); // turnoId SI viene de la ruta -- es el recurso, no el tenant
                                                        // (ya parseado tipado -- MEF-ADR-0037, seccion de abajo)

// INCORRECTO: confiar en un tenant id que el cliente puede falsificar
await using var sesionInsegura = store.QuerySession(request.Query["tenantId"]); // BOLA/IDOR
```

Esto no es un detalle de conveniencia: es la mitigacion estructural del marco contra **BOLA/IDOR** (Broken Object Level Authorization / Insecure Direct Object Reference). Marten filtra por una columna `tenant_id` a nivel de sesion, pero **no lo garantiza a nivel de acceso a base de datos** -- *"Marten does not guarantee or enforce data isolation via database access privileges"*. La responsabilidad de abrir la sesion con el tenant **correcto** es enteramente del codigo de la aplicacion.

## Identidad del stream en la ruta del GET: un unico parseo tipado (MEF-ADR-0037)

El `id` de un item por la via (a)/(b1)/(b2) llega del segmento de ruta como texto. MEF-ADR-0037 fija que ese texto crudo **nunca** viaja sin parsear hasta `LoadAsync`/`AggregateStreamAsync`/`FetchStreamAsync`: el endpoint hace un unico parseo tipado y, si resuelve, la unica salida a string de toda la request es la del punto unico de conversion del ADR (`ToString()` sin argumentos) -- nunca una reconstruccion propia.

**Identidad nacida `Guid`** (el caso comun -- `TurnoId`, `EmpleadoId`): el endpoint parsea el segmento de ruta una sola vez (`Guid.TryParse`) y responde `400` explicito si falla; si resuelve, pasa `idTipado.ToString()` a la read API que corresponda:

```csharp
// ObtenerSeguimientoTurno/FunctionEndpoint.cs
[Function("ObtenerSeguimientoTurno")]
public async Task<IActionResult> Run(
    [HttpTrigger(AuthorizationLevel.Function, "get", Route = "programacion/turnos/{id}")]
    HttpRequest req,
    string id,   // segmento crudo de la ruta -- el unico parseo tipado ocurre abajo
    CancellationToken ct)
{
    if (!Guid.TryParse(id, out var turnoId))
        return new BadRequestObjectResult("El id del turno no es un Guid valido");

    await using var session = store.QuerySession(tenantResolver.TenantId);
    var seguimiento = await session.LoadAsync<SeguimientoTurno>(turnoId.ToString(), ct);   // unico ToString(), sin argumentos
    return seguimiento is null ? new NotFoundResult() : new OkObjectResult(seguimiento);
}
```

El `400` se emite con `BadRequestObjectResult` **y un mensaje** -- misma forma que el `IRequestValidator` de los comandos (`agents/implementer.md`), y lo que pide la documentacion oficial citada por el ADR (*"Invalid input should produce a 400 Bad Request with an appropriate error message"*). Un `BadRequestResult` pelado deja al cliente sin saber que componente de la ruta rechazo el endpoint.

**Identidad de UN componente tipado no-`Guid` (un VO unico)**: mismo mecanismo que el caso `Guid` de arriba -- un unico parseo tipado del segmento de ruta con el parser del propio tipo, `400` explicito si lo rechaza, y la unica salida a string es el `ToString()` de ese mismo tipo (punto unico de conversion simetrico a `guid.ToString()`, MEF-ADR-0037 secciones 1 y 2). Que el segmento de ruta y la clave de stream coincidan es consecuencia de que solo hay un componente que convertir, no una excepcion a la regla:

```csharp
// ObtenerFichaColaborador/FunctionEndpoint.cs -- identidad VO unico Identificacion
[Function("ObtenerFichaColaborador")]
public async Task<IActionResult> Run(
    [HttpTrigger(AuthorizationLevel.Function, "get", Route = "rrhh/colaboradores/{identificacion}")]
    HttpRequest req,
    string identificacion,   // segmento crudo de la ruta -- el unico parseo tipado ocurre abajo
    CancellationToken ct)
{
    if (!Identificacion.TryParse(identificacion, out var identificacionTipada))
        return new BadRequestObjectResult("La identificacion no es valida");

    await using var session = store.QuerySession(tenantResolver.TenantId);
    var ficha = await session.LoadAsync<FichaColaborador>(identificacionTipada.ToString(), ct);   // unico ToString(), del propio tipo
    return ficha is null ? new NotFoundResult() : new OkObjectResult(ficha);
}
```

Lo que **si** trae de nuevo esta forma frente al `Guid`: su URL-safety no es automatica -- la fija el `ToString()` del propio tipo, no un formato fijo del runtime --, asi que el componente queda sujeto, por viajar en la URL, al charset *unreserved* de RFC 3986 y al criterio de aceptacion de MEF-ADR-0043 secciones 1.1/1.2 (remision explicita de MEF-ADR-0037 seccion 2; este archivo no reabre esas secciones). Si el VO admite algun caracter fuera de ese conjunto, la invariante se gana en un issue previo dedicado (MEF-ADR-0043 seccion 1.3), nunca en el PR que expone la ruta.

**Clave natural compuesta**: la ruta recibe cada componente tipado por separado, y la clave se reconstruye con el mismo `{Aggregate}.ComputarStreamId(...)` que ya usa el write-side (`agents/implementer.md`) -- nunca una concatenacion propia del endpoint. El GET vive en el Function App del dominio, el mismo ensamblado donde vive el aggregate, asi que ese metodo estatico le es alcanzable sin ceremonia (MEF-ADR-0037 seccion 2):

```csharp
// ObtenerResumenAsistenciaDiaria/FunctionEndpoint.cs -- clave compuesta EmpleadoId:Fecha
[Function("ObtenerResumenAsistenciaDiaria")]
public async Task<IActionResult> Run(
    [HttpTrigger(AuthorizationLevel.Function, "get", Route = "rrhh/asistencias/{empleadoId}/{fecha}")]
    HttpRequest req,
    string empleadoId,
    string fecha,
    CancellationToken ct)
{
    if (!Guid.TryParse(empleadoId, out var empleadoIdTipado) || !DateOnly.TryParse(fecha, out var fechaTipada))
        return new BadRequestObjectResult("La ruta lleva un empleadoId o una fecha invalidos");

    var streamId = AsistenciaAggregateRoot.ComputarStreamId(empleadoIdTipado, fechaTipada);
    await using var session = store.QuerySession(tenantResolver.TenantId);
    var resumen = await session.LoadAsync<ResumenAsistenciaDiaria>(streamId, ct);
    return resumen is null ? new NotFoundResult() : new OkObjectResult(resumen);
}
```

**Frontera -- solo cae bajo esta regla el id que ES una identidad de stream** (MEF-ADR-0037 seccion 3). Es el caso de N1, donde el id del read model es el `StreamKey` que Marten resolvio (`TId = string`). Un read model N2 cuyo `TId` lo fija el slicer `Identity<TEvento>(...)` -- un `ResumenEquipo` con `Guid EquipoId`, campo de dominio del payload y no clave de stream ([modelos-marten.md](modelos-marten.md)) -- queda **fuera** del sujeto del ADR: el parseo tipado del borde y su `400` siguen siendo obligatorios, pero lo que recibe `LoadAsync<ResumenEquipo>(equipoId, ct)` es el valor **tipado**, sin `ToString()`. El tipo del argumento lo fija el `TId` de la proyeccion, no esta regla: agregarle un `ToString()` ahi no es una precaucion extra, es pasarle a Marten un id del tipo equivocado.

**Proscrito**: un parametro de ruta `string` cuyo valor viaje sin parsear hasta el store, el bus o `LoadAsync`/`AggregateStreamAsync`/`FetchStreamAsync` -- sea la identidad de uno o de varios componentes. Proscrito ademas, con la misma severidad, que una clave de **varios** componentes viaje ya concatenada en un unico segmento: ahi el llamador pasa a ser dueno del separador y del orden de los componentes, exactamente lo que el punto unico de conversion existe para evitar -- esta segunda proscripcion nunca alcanza a una identidad de **un solo** componente, donde no hay separador ni orden que el llamador pueda torcer. Un route constraint (`{id:guid}`) no sustituye este parseo: produce `404` en vez de `400` y no normaliza el casing -- advertencia literal de la documentacion oficial de ASP.NET Core sobre route constraints (MEF-ADR-0037 seccion 2). Declararlo por su proposito real -- desambiguar rutas parecidas -- sigue siendo legitimo, pero entonces el parseo con `400` va igual (MEF-ADR-0037 Alt 4).

## Metodo QUERY (RFC 10008): filtros estructurados y paginacion por cursor

MEF-ADR-0042 fija cuando `Listar{Concepto}s` (via (a')) se expone sobre GET y cuando sobre **QUERY** (RFC 10008): GET para filtros planos de igualdad en query string; QUERY para filtros estructurados (combinaciones AND/OR, rangos, listas de valores) y paginacion por cursor. El nombre de la Function y su `Route` no cambian entre uno y otro (MEF-ADR-0006) -- solo el verbo del `HttpTriggerAttribute`.

**Ejemplo canonico** (el trigger `"query"` esta verificado por POC contra .NET 10 + Azure Functions Core Tools 4.6.0 -- el host registra el trigger `[QUERY]`, enruta el verbo y entrega el body intacto):

```csharp
// ListarSeguimientosTurno/FunctionEndpoint.cs -- filtros estructurados + paginacion por cursor via QUERY
public sealed record FiltroListarSeguimientosTurno(
    string? Estado,
    IReadOnlyList<string>? Estados,
    DateOnly? DesdeFecha,
    DateOnly? HastaFecha,
    string? Cursor,
    int Take = 50);

private const int TakeMaximo = 200;   // cota del servidor -- el Take del cliente nunca llega crudo a Marten

[Function("ListarSeguimientosTurno")]
public async Task<IActionResult> Run(
    [HttpTrigger(AuthorizationLevel.Function, "query", Route = "programacion/turnos")]
    HttpRequest req,
    CancellationToken ct)
{
    // 415 ANTES de leer el body: ReadFromJsonAsync lanza si el Content-Type no es un tipo JSON conocido,
    // y esa excepcion NO es JsonException -- sin este guard se escaparia como 500 (RFC 10008 seccion 2.1: 415).
    if (!req.HasJsonContentType())
        return new ObjectResult("La query exige Content-Type: application/json")
            { StatusCode = StatusCodes.Status415UnsupportedMediaType };

    FiltroListarSeguimientosTurno? filtro;
    try
    {
        filtro = await req.ReadFromJsonAsync<FiltroListarSeguimientosTurno>(ct);
    }
    catch (JsonException)
    {
        return new BadRequestObjectResult("El body de la query no es un JSON valido"); // RFC 10008 seccion 2.1: 400
    }

    if (filtro is null)
        return new BadRequestObjectResult("El body de la query es obligatorio");

    if (filtro.DesdeFecha is not null && filtro.HastaFecha is not null && filtro.DesdeFecha > filtro.HastaFecha)
        return new ObjectResult("DesdeFecha no puede ser posterior a HastaFecha")
            { StatusCode = StatusCodes.Status422UnprocessableEntity };   // RFC 10008 seccion 2.1: 422

    // Sesion acotada al tenant del resolver -- identico al GET (MEF-ADR-0028), nunca a un tenant del body.
    await using var session = store.QuerySession(tenantResolver.TenantId);
    IQueryable<SeguimientoTurno> query = session.Query<SeguimientoTurno>();
    if (filtro.Estado is not null) query = query.Where(t => t.Estado == filtro.Estado);          // AND por defecto -- MEF-ADR-0042
    if (filtro.Estados is { Count: > 0 }) query = query.Where(t => filtro.Estados.Contains(t.Estado)); // OR explicito: campo propio
    if (filtro.DesdeFecha is not null) query = query.Where(t => t.FechaInicio >= filtro.DesdeFecha);
    if (filtro.HastaFecha is not null) query = query.Where(t => t.FechaInicio <= filtro.HastaFecha);
    if (filtro.Cursor is not null) query = query.Where(t => t.Id.CompareTo(filtro.Cursor) > 0);  // keyset -- ver caveat abajo

    var pagina = await query.OrderBy(t => t.Id).Take(Math.Clamp(filtro.Take, 1, TakeMaximo)).ToListAsync(ct);
    return new OkObjectResult(pagina);
}
```

- **`Content-Type: application/json` obligatorio** (RFC 10008 seccion 2), y el guard va **antes** del parseo: la doc oficial de `HttpRequestJsonExtensions.ReadFromJsonAsync` dice *"If the request's content-type is not a known JSON type then an error will be thrown"* -- ese error **no** es un `JsonException`, asi que envolver solo el parseo en `try/catch` deja escapar un `500` donde el RFC pide `415`. `req.HasJsonContentType()` es el chequeo que la propia doc de ASP.NET Core ofrece para eso. El `400` posterior sigue el mismo patron `BadRequestObjectResult` **con mensaje** que MEF-ADR-0037 ya fija para el parseo del id de ruta.
- **AND por defecto** entre los campos no nulos del filtro: un `OR` explicito exige su propio campo tipado en el DTO (`Estados` como lista, en vez de repetir `Estado` con semantica ambigua), nunca una convencion implicita de nombres de query param.
- **Paginacion keyset/cursor es el default** (MEF-ADR-0042 seccion 2): una coleccion event-sourced crece sin cota, y offset (`Skip(n)`) sobre ella produce lecturas inconsistentes entre paginas. El cursor viaja **dentro del formato de query** (el campo `Cursor` del DTO), respaldado por RFC 10008 seccion 2.8. Offset (`ToPagedListAsync`/`Stats(out QueryStatistics)`) es la excepcion documentada bajo Rule of Three (MEF-ADR-0018), no una segunda via por defecto.
- **El `Take` del cliente se acota en el servidor** (`Math.Clamp(filtro.Take, 1, TakeMaximo)`): un `Take` que viaja en el body es entrada del cliente como cualquier otra -- pasarlo crudo a Marten deja pedir una pagina sin cota.
- **404, no 405, ante un verbo no coincidente**: un cliente que intente `GET` sobre una ruta que solo declara `"query"` recibe `404` -- el host no distingue "recurso existe, verbo no soportado" de "recurso no existe".
- **415/422 se mapean a la misma forma que el `400`**: `new ObjectResult(mensaje) { StatusCode = StatusCodes.Status415UnsupportedMediaType }` / `...Status422UnprocessableEntity` -- nunca un codigo pelado sin cuerpo. El `406` del RFC queda fuera del camino feliz del marco (toda respuesta es JSON).
- **NO VERIFICADO -- traduccion LINQ del predicado de cursor y de la lista de valores**: la doc de Marten para campos string lista `StartsWith`/`EndsWith`/`Contains`/`Equals`/`Regex.IsMatch`/`EqualsIgnoreCase`; ni `CompareTo` ni el `>` de orden sobre string figuran en esa superficie. El primer dominio que pagine por keyset sobre un `Id` string debe **verificar por ejecucion** que la comparacion traduce a SQL -- o mover el cursor a un campo naturalmente comparable (fecha/numero) con desempate por `Id`. Mismo caveat para el `Contains` de la lista de valores (`IsOneOf` es la alternativa de Marten si no traduce). Registrado como gate en MEF-ADR-0042 seccion 6.

## Resolucion de `TView` en el write-side: sin registro adicional, bajo dos condiciones (tenancy + `mt_version`)

La sesion de query del Function App del write-side y el schema del worker comparten el mismo Postgres/schema (MEF-ADR-0034 seccion 2). El `DocumentStore` del write-side **resuelve el mapping** de `TView` sin **declararlo** (`Schema.For<TView>()`) y **sin** registrar la proyeccion, que solo vive en el named store del worker: Marten lo resuelve por convencion la primera vez que se le pregunta por el tipo (MEF-ADR-0035 seccion 4).

**Que el mapping resuelva en ambos lados no significa que resuelva igual.** Esa convergencia depende de **dos** condiciones, ambas instancias del **par de compatibilidad 2** de MEF-ADR-0034 seccion 6 (worker -- materializa los documentos -- -> query-side del Function App). Ninguna de las dos es algo que reverifiques al implementar -- la verificacion completa de esa compatibilidad corre bajo gate del reviewer (MEF-ADR-0034 seccion 6):

1. **Tenancy**: ambos lados deben aplicar la misma politica de tenancy documental (`Policies.AllDocumentsAreMultiTenanted()`). Si diverge, ninguna excepcion avisa: el worker materializa vistas sin scope de tenant que el Function App despues consulta filtrando por tenant. Las mediciones que respaldan este hecho viven en MEF-ADR-0035 seccion 4.

2. **`mt_version` (receta canonica -- issue #718, Bitakora.ControlAsistencia issues #294 y #448)**: Marten impone *numeric revisions* al documento target de toda proyeccion registrada, verificado contra la documentacion oficial -- *"all projected aggregation documents are automatically marked as being revisioned"* ("Optimistic Concurrency", https://martendb.io/documents/concurrency.html). Esa politica (`ProjectionDocumentPolicy`) fija la forma fisica de la columna `mt_version bigint` en la tabla que el worker materializa. El mapping por convencion del write-side, en cambio, **no** hereda esa politica: al no declarar `Schema.For<TView>()`, Marten resuelve `TView` como un documento regular, con optimistic concurrency Guid-based por defecto (`mt_version uuid`).

   A diferencia de la divergencia de tenancy (silenciosa, sin excepcion), esta si truena -- pero en el peor momento posible: con `AutoCreate` en `CreateOrUpdate` (MEF-ADR-0034 seccion 11), la **primera** query del write-side contra ese documento dispara un `ALTER COLUMN` que Postgres rechaza -- `42804: cannot be cast automatically` -- y el DDL fallido tumba **toda** la sesion del store del Function App, command handlers incluidos, no solo la query nueva que lo disparo.

   **Receta canonica**: por **cada documento** consultado desde el write-side via (a)/(a') -- nunca via una policy global, a diferencia de tenancy: no existe un `AllDocumentsAreMultiTenanted()` equivalente para numeric revisions -- el `ComposicionServicios{Dominio}.cs` del Function App declara, como condicion hermana de la de tenancy:

   ```csharp
   opts.Schema.For<ResumenAsistenciaDiaria>().UseNumericRevisions(true);
   ```

   una linea por cada `TView` que el dominio consulte con `Query<TView>()`/`LoadAsync<TView>()`. **No contradice el parrafo de arriba**: ese `Schema.For<TView>()` no declara el mapping -- Marten ya lo resolvio por convencion, con el mismo `IdMember` y la misma tabla `mt_doc_{tipo}` en ambos lados (MEF-ADR-0035 seccion 4) -- sino que corrige la unica faceta de ese mapping que la convencion deja distinta de la que el worker impone: el par de columnas de version (`Revision`/`Version`), que Marten habilita en bloque -- una u otra, nunca las dos (medido en MEF-ADR-0034 referencia [25]).

   **Simetria en el mismo issue**: la mitad del Function App de este par se escribe en el **mismo issue** que agrega la superficie de consulta (`Query<`/`LoadAsync<`) -- nunca en un issue posterior. Bitakora #448 es la evidencia de lo que pasa si no: la mitad del worker (la proyeccion ya registrada) existia, la mitad del Function App (este `UseNumericRevisions(true)`) nunca se escribio, y el gap quedo invisible hasta el primer GET en produccion. Ver [config-test.md](config-test.md) para el par de config-tests espejo que guarda esta receta en cada `dotnet test`, sin depender de que el gate del reviewer note el gap en el diff -- un PR que solo agrega una Function GET nueva no lo dispara.

## El GET serializa la vista; el DTO de respuesta es excepcion (MEF-ADR-0041 decision 4)

El endpoint HTTP GET retorna el record de `ReadModels` directamente como cuerpo de la respuesta -- `new OkObjectResult(vista)`, como en los dos ejemplos de arriba -- sin un tipo de DTO de respuesta intermedio por defecto. Es la consecuencia directa de que la forma del read model ya salio de la necesidad de lectura (MEF-ADR-0041 decision 1): envolverla en un segundo tipo con el mismo shape es una capa sin proposito.

Un DTO de respuesta HTTP separado es una **excepcion**, sujeta a la misma Rule of Three de MEF-ADR-0018 que gobierna cualquier abstraccion del marco: se introduce solo con evidencia real de que el contrato HTTP debe divergir del shape del read model -- ocultar un campo interno que la vista necesita para su propia logica de proyeccion pero que no debe salir por HTTP, componer varias vistas en una sola respuesta, o adaptar el shape a un contrato publico versionado que el read model interno no debe atarse a mantener. Sin esa evidencia, el GET no introduce el DTO "por si acaso".

## Time-travel: diferido

Marten soporta parametros `version`/`timestamp` en `AggregateStreamAsync` para reconstruir el aggregate en un punto del pasado, pero ningun caso de uso real del marco lo necesita hoy. Aplicando Rule of Three (MEF-ADR-0018), esta superficie **no** se expone en el scaffolding por defecto.

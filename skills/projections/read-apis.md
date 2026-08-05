# Read APIs: como consultar una proyeccion o un aggregate

Fuente: MEF-ADR-0035 secciones 3-5. Toda API de esta pagina esta disponible sobre `IQuerySession` salvo donde se indique lo contrario.

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

**Colision deliberada entre (a) y (b1)**: cuando el read model y el aggregate comparten concepto (`TurnoView` proyecta `TurnoAggregateRoot`), ambas vias producirian el mismo nombre de Function (`ObtenerTurno`) -- un dominio expone **una sola** via de lectura por id a la vez (la materializada (a) es la default; (b1) es la excepcion). Ver [naming.md](naming.md).

## `FetchLatest`: opt-in, no default

*"For internal reasons, the `FetchLatest()` API is only available off of `IDocumentSession` and not `IQuerySession`"*. Adoptarlo para un endpoint de lectura significa abrir una sesion de **escritura** (`LightweightSession`) solo para leer -- el mismo tipo de excepcion-opt-in que MEF-ADR-0034 ya aplica a `Inline` frente a `Async`. Util cuando se necesita el comportamiento adaptativo por ciclo de vida (`Live` -> `AggregateStreamAsync`; `Inline` -> documento persistido; `Async` -> snapshot + eventos no aplicados en memoria), pero **no** es el camino feliz por defecto.

## Patron de seguridad: sesion acotada al tenant resuelto, nunca al id de la ruta

Toda `QuerySession` de un endpoint de lectura se abre **acotada al tenant que resolvio `ITenantResolver`** (MEF-ADR-0028) -- **nunca** a un tenant id que llegue en la ruta, el query string o el body de la request:

```csharp
// CORRECTO: el tenant viene del resolver, no de la request.
// ITenantResolver expone TenantId/UserId como PROPIEDADES, no metodos (MEF-ADR-0028 seccion 1).
await using var session = store.QuerySession(tenantResolver.TenantId);
var turno = await session.LoadAsync<TurnoView>(turnoId); // turnoId SI viene de la ruta -- es el recurso, no el tenant
                                                        // (ya parseado tipado -- MEF-ADR-0037, seccion de abajo)

// INCORRECTO: confiar en un tenant id que el cliente puede falsificar
await using var sesionInsegura = store.QuerySession(request.Query["tenantId"]); // BOLA/IDOR
```

Esto no es un detalle de conveniencia: es la mitigacion estructural del marco contra **BOLA/IDOR** (Broken Object Level Authorization / Insecure Direct Object Reference). Marten filtra por una columna `tenant_id` a nivel de sesion, pero **no lo garantiza a nivel de acceso a base de datos** -- *"Marten does not guarantee or enforce data isolation via database access privileges"*. La responsabilidad de abrir la sesion con el tenant **correcto** es enteramente del codigo de la aplicacion.

## Identidad del stream en la ruta del GET: un unico parseo tipado (MEF-ADR-0037)

El `id` de un item por la via (a)/(b1)/(b2) llega del segmento de ruta como texto. MEF-ADR-0037 fija que ese texto crudo **nunca** viaja sin parsear hasta `LoadAsync`/`AggregateStreamAsync`/`FetchStreamAsync`: el endpoint hace un unico parseo tipado y, si resuelve, la unica salida a string de toda la request es la del punto unico de conversion del ADR (`ToString()` sin argumentos) -- nunca una reconstruccion propia.

**Identidad nacida `Guid`** (el caso comun -- `TurnoId`, `EmpleadoId`): el endpoint parsea el segmento de ruta una sola vez (`Guid.TryParse`) y responde `400` explicito si falla; si resuelve, pasa `idTipado.ToString()` a la read API que corresponda:

```csharp
// ObtenerTurno/FunctionEndpoint.cs
[Function("ObtenerTurno")]
public async Task<IActionResult> Run(
    [HttpTrigger(AuthorizationLevel.Function, "get", Route = "Programacion/Turnos/{id}")]
    HttpRequest req,
    string id,   // segmento crudo de la ruta -- el unico parseo tipado ocurre abajo
    CancellationToken ct)
{
    if (!Guid.TryParse(id, out var turnoId))
        return new BadRequestObjectResult("El id del turno no es un Guid valido");

    await using var session = store.QuerySession(tenantResolver.TenantId);
    var turno = await session.LoadAsync<TurnoView>(turnoId.ToString(), ct);   // unico ToString(), sin argumentos
    return turno is null ? new NotFoundResult() : new OkObjectResult(turno);
}
```

El `400` se emite con `BadRequestObjectResult` **y un mensaje** -- misma forma que el `IRequestValidator` de los comandos (`agents/implementer.md`), y lo que pide la documentacion oficial citada por el ADR (*"Invalid input should produce a 400 Bad Request with an appropriate error message"*). Un `BadRequestResult` pelado deja al cliente sin saber que componente de la ruta rechazo el endpoint.

**Clave natural compuesta**: la ruta recibe cada componente tipado por separado, y la clave se reconstruye con el mismo `{Aggregate}.ComputarStreamId(...)` que ya usa el write-side (`agents/implementer.md`) -- nunca una concatenacion propia del endpoint. El GET vive en el Function App del dominio, el mismo ensamblado donde vive el aggregate, asi que ese metodo estatico le es alcanzable sin ceremonia (MEF-ADR-0037 seccion 2):

```csharp
// ObtenerAsistencia/FunctionEndpoint.cs -- clave compuesta EmpleadoId:Fecha
[Function("ObtenerAsistencia")]
public async Task<IActionResult> Run(
    [HttpTrigger(AuthorizationLevel.Function, "get", Route = "RRHH/Asistencias/{empleadoId}/{fecha}")]
    HttpRequest req,
    string empleadoId,
    string fecha,
    CancellationToken ct)
{
    if (!Guid.TryParse(empleadoId, out var empleadoIdTipado) || !DateOnly.TryParse(fecha, out var fechaTipada))
        return new BadRequestObjectResult("La ruta lleva un empleadoId o una fecha invalidos");

    var streamId = AsistenciaAggregateRoot.ComputarStreamId(empleadoIdTipado, fechaTipada);
    await using var session = store.QuerySession(tenantResolver.TenantId);
    var asistencia = await session.LoadAsync<AsistenciaView>(streamId, ct);
    return asistencia is null ? new NotFoundResult() : new OkObjectResult(asistencia);
}
```

**Frontera -- solo cae bajo esta regla el id que ES una identidad de stream** (MEF-ADR-0037 seccion 3). Es el caso de N1, donde el id del read model es el `StreamKey` que Marten resolvio (`TId = string`). Un read model N2 cuyo `TId` lo fija el slicer `Identity<TEvento>(...)` -- un `ResumenEquipoView` con `Guid EquipoId`, campo de dominio del payload y no clave de stream ([modelos-marten.md](modelos-marten.md)) -- queda **fuera** del sujeto del ADR: el parseo tipado del borde y su `400` siguen siendo obligatorios, pero lo que recibe `LoadAsync<ResumenEquipoView>(equipoId, ct)` es el valor **tipado**, sin `ToString()`. El tipo del argumento lo fija el `TId` de la proyeccion, no esta regla: agregarle un `ToString()` ahi no es una precaucion extra, es pasarle a Marten un id del tipo equivocado.

**Proscrito**: un parametro de ruta `string` cuyo valor -- simple o ya concatenado -- viaje sin parsear hasta el store, el bus o `LoadAsync`/`AggregateStreamAsync`/`FetchStreamAsync`. Un route constraint (`{id:guid}`) no sustituye este parseo: produce `404` en vez de `400` y no normaliza el casing -- advertencia literal de la documentacion oficial de ASP.NET Core sobre route constraints (MEF-ADR-0037 seccion 2). Declararlo por su proposito real -- desambiguar rutas parecidas -- sigue siendo legitimo, pero entonces el parseo con `400` va igual (MEF-ADR-0037 Alt 4).

## Resolucion de `TView` en el write-side: sin registro adicional, bajo condicion de tenancy

La sesion de query del Function App del write-side y el schema del worker comparten el mismo Postgres/schema (MEF-ADR-0034 seccion 2). El `DocumentStore` del write-side resuelve `Query<TView>()`/`LoadAsync<TView>()` **sin** `Schema.For<TView>()` y **sin** registrar la proyeccion: Marten resuelve el mapping del documento por convencion, aunque la proyeccion en si solo se registre en el named store del worker.

La condicion que sostiene esa convergencia: ambos lados deben aplicar la misma politica de tenancy documental (`Policies.AllDocumentsAreMultiTenanted()`) -- es el **par de compatibilidad 2** de MEF-ADR-0034 seccion 6, y si diverge ninguna excepcion avisa: el worker materializa vistas sin scope de tenant que el Function App despues consulta filtrando por tenant. No es algo que reverifiques al implementar -- la verificacion completa de esa compatibilidad corre bajo gate del reviewer (MEF-ADR-0034 seccion 6). Las mediciones que respaldan ambos hechos viven en MEF-ADR-0035 seccion 4.

## Time-travel: diferido

Marten soporta parametros `version`/`timestamp` en `AggregateStreamAsync` para reconstruir el aggregate en un punto del pasado, pero ningun caso de uso real del marco lo necesita hoy. Aplicando Rule of Three (MEF-ADR-0018), esta superficie **no** se expone en el scaffolding por defecto.

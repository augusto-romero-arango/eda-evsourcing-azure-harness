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

// INCORRECTO: confiar en un tenant id que el cliente puede falsificar
await using var sesionInsegura = store.QuerySession(request.Query["tenantId"]); // BOLA/IDOR
```

Esto no es un detalle de conveniencia: es la mitigacion estructural del marco contra **BOLA/IDOR** (Broken Object Level Authorization / Insecure Direct Object Reference). Marten filtra por una columna `tenant_id` a nivel de sesion, pero **no lo garantiza a nivel de acceso a base de datos** -- *"Marten does not guarantee or enforce data isolation via database access privileges"*. La responsabilidad de abrir la sesion con el tenant **correcto** es enteramente del codigo de la aplicacion.

## Punto abierto para el implementador

La sesion de query del Function App del write-side y el schema del worker comparten el mismo Postgres/schema (MEF-ADR-0034 seccion 2), pero si el `DocumentStore` del write-side necesita algun registro adicional del tipo de documento (`TView`) para resolverlo via `Query<TView>()`/`LoadAsync<TView>()` -- dado que la proyeccion en si solo se registra en el named store del worker, nunca en el write-side --, es un detalle de la superficie exacta de `StoreOptions` que el agente implementador debe reverificar empiricamente antes de generar el primer read model real.

## Time-travel: diferido

Marten soporta parametros `version`/`timestamp` en `AggregateStreamAsync` para reconstruir el aggregate en un punto del pasado, pero ningun caso de uso real del marco lo necesita hoy. Aplicando Rule of Three (MEF-ADR-0018), esta superficie **no** se expone en el scaffolding por defecto.

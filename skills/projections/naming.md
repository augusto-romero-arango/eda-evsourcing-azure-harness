# Naming: Functions de query y artefactos de proyeccion

Fuente: MEF-ADR-0006 (enmienda issue #363, hermano de MEF-ADR-0035). Aqui solo se fija el **naming**; el estilo de codigo y la superficie de consulta los fija MEF-ADR-0035 (ver [modelos-marten.md](modelos-marten.md) y [read-apis.md](read-apis.md)).

## Functions HTTP de query (GET)

Una Function de query se nombra igual que un comando -- **verbo infinitivo espanol + sustantivo** -- pero con dos verbos fijos segun la cardinalidad del resultado:

| Cardinalidad | Patron | Ejemplo |
|---|---|---|
| Un item, por id | `Obtener{X}` | `ObtenerTurno` |
| Coleccion/filtro | `Listar{X}s` | `ListarTurnos` |

El `s` de `Listar{X}s` es el **plural correcto del espanol**, no un sufijo literal: `Perfil` -> `ListarPerfiles`, `Mes` -> `ListarMeses`, nunca `ListarPerfils`. Es la misma palabra plural que nombra el recurso en la ruta HTTP.

`{X}` es el **concepto** que la Function devuelve, segun la via de MEF-ADR-0035 (ver [read-apis.md](read-apis.md)):

- **(a) Proyeccion materializada**: `Obtener{Concepto}` por id, `Listar{Concepto}s` por filtro/lista -- `{Concepto}` es el nombre base del read model (`TurnoView` -> `ObtenerTurno`).
- **(b1) Aggregate en vivo**: `Obtener{Aggregate}` -- `{Aggregate}` es el nombre del aggregate sin el sufijo `AggregateRoot` (`TurnoAggregateRoot` -> `ObtenerTurno`).
- **(b2) Eventos crudos del stream**: `ListarEventosDe{Aggregate}` (`ListarEventosDeTurno`).

**Colision deliberada entre (a) y (b1)**: cuando el read model y el aggregate comparten concepto, ambas vias producen el **mismo** nombre de Function -- y dos Functions con identico `[Function("...")]` no pueden coexistir. Un dominio expone **una sola** via de lectura por id a la vez ((a) es la default; (b1) la excepcion cuando no existe proyeccion materializada). Un dominio que de verdad necesite ambas vias sobre el mismo concepto debe desambiguar el nombre explicitamente en el issue que lo pida (Rule of Three, MEF-ADR-0018).

## Ruta HTTP: REST por recurso, nunca el nombre de la Function

Toda Function HTTP -- comando y query -- declara su `Route` explicitamente; el default del atributo nunca se usa. Una query reutiliza **el mismo segmento de recurso que ya usa el comando de ese recurso**, sumando `{id}` para el caso de un item:

```csharp
// ObtenerTurno/FunctionEndpoint.cs
[Function("ObtenerTurno")]
public async Task<IActionResult> Run(
    [HttpTrigger(AuthorizationLevel.Function, "get", Route = "Programacion/Turnos/{id}")]
    HttpRequest req,
    Guid id,
    CancellationToken ct)

// ListarTurnos/FunctionEndpoint.cs  <- clase y namespace distintos: una carpeta por query
[Function("ListarTurnos")]
public async Task<IActionResult> Run(
    [HttpTrigger(AuthorizationLevel.Function, "get", Route = "Programacion/Turnos")]
    HttpRequest req,
    CancellationToken ct)
```

El tipo de la request es `HttpRequest` y el retorno `IActionResult` -- la integracion ASP.NET Core del worker aislado --, no `HttpRequestData`/`HttpResponseData` (modelo alterno, mantenido solo por compatibilidad hacia atras).

**Por que `Route` explicito**: el `Route` del `HttpTriggerAttribute` es opcional y *"the default value if none is provided is `<functionname>`"* -- sin el atributo, la ruta seria `/api/ObtenerTurno`, no el recurso REST.

**Cada Function declara su verbo, siempre**: el GET y el POST del mismo recurso se distinguen por el **metodo HTTP**, nunca por el nombre de la Function -- y eso obliga a declarar el metodo en **ambos** lados (`Methods` es opcional y responde a todos los verbos si se omite).

**Nunca `Route = ""`**: fijar la ruta vacia para que una query quede en la raiz de `/api` produce 404 en el worker aislado -- regla operativa hasta que un issue puntual la reverifique empiricamente.

## Organizacion vertical: una carpeta por query, sin sufijo `Function`

```
src/Bitakora.ControlAsistencia.{Dominio}/
  ObtenerTurno/                          <- feature folder por query GET (sin sufijo Function)
    FunctionEndpoint.cs                  <- [Function("ObtenerTurno")], Route = "Programacion/Turnos/{id}"
  ListarTurnos/
    FunctionEndpoint.cs                  <- [Function("ListarTurnos")], Route = "Programacion/Turnos"
```

- `FunctionEndpoint.cs` como nombre de clase en cada directorio -- no colisiona porque cada directorio es un namespace diferente.
- Sin sufijo `Function` (ese sufijo es solo para comandos, que si tienen un record colisionante en su propio directorio).
- **Nunca** agrupar todas las queries de un dominio en una unica clase (`XQueriesEndpoint`, patron descartado del proyecto de referencia ControlPlane): rompe el mismo invariante de organizacion vertical que ya rige comandos y reacciones a evento (una carpeta = un namespace = una responsabilidad).

## Tabla de convenciones C# (artefactos de proyeccion)

| Concepto | Convencion | Ejemplo |
|---|---|---|
| Query (Function/metodo GET) | `Obtener{X}` (item por id) / `Listar{X}s` (coleccion) | `ObtenerTurno`, `ListarTurnos` |
| Read model (view) | `{Concepto}View` | `TurnoView` |
| Clase de proyeccion (companion, N2) | `{Concepto}Projection` (`partial`, mismo stem que su View) | `ResumenEquipoProjection` -> `ResumenEquipoView` |
| Marker del named store de proyecciones | `I{Dominio}ProjectionStore` | `IVentasProjectionStore` |
| Seam de composicion de proyecciones (por dominio) | `ConfiguracionMartenProjections{Dominio}`, metodo `Configurar{Dominio}` | `ConfiguracionMartenProjectionsVentas.ConfigurarVentas()` |

El seam de proyecciones es el hermano read-side del seam de composicion del write-side (MEF-ADR-0029: `ComposicionServicios{Dominio}`/`AgregarServicios{Dominio}`) -- misma idea de fuente unica de wiring por dominio, distinto proceso y distinto nombre para no confundirlos al leer un `Program.cs`.

Las clases son en espanol. Los sufijos de patrones reconocidos (Endpoint, View, Projection, ProjectionStore) son en ingles.

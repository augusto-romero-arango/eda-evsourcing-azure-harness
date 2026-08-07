# Naming: Functions de query y artefactos de proyeccion

Fuente: MEF-ADR-0006 (enmienda issue #363, hermano de MEF-ADR-0035; naming del read model reenmendado por MEF-ADR-0041, issue #581). Aqui solo se fija el **naming**; el estilo de codigo y la superficie de consulta los fija MEF-ADR-0035 (ver [modelos-marten.md](modelos-marten.md) y [read-apis.md](read-apis.md)); la forma de la vista (que campos, que nombres) la fija MEF-ADR-0041, no este documento.

## Functions HTTP de query (GET)

Una Function de query se nombra igual que un comando -- **verbo infinitivo espanol + sustantivo** -- pero con dos verbos fijos segun la cardinalidad del resultado:

| Cardinalidad | Patron | Ejemplo |
|---|---|---|
| Un item, por id | `Obtener{X}` | `ObtenerTurno` |
| Coleccion/filtro | `Listar{X}s` | `ListarTurnos` |

El `s` de `Listar{X}s` es el **plural correcto del espanol**, no un sufijo literal: `Perfil` -> `ListarPerfiles`, `Mes` -> `ListarMeses`, nunca `ListarPerfils`. Es la misma palabra plural que nombra el recurso en la ruta HTTP.

`{X}` es el **concepto** que la Function devuelve, segun la via de MEF-ADR-0035 (ver [read-apis.md](read-apis.md)):

- **(a) Proyeccion materializada**: `Obtener{X}` por id, `Listar{X}s` por filtro/lista -- aqui `{X}` es el nombre del read model: un termino del lenguaje ubicuo sin sufijo de implementacion (MEF-ADR-0041 decision 3), derivado de la necesidad de lectura y no del evento ni del aggregate (`ResumenAsistenciaDiaria` -> `ObtenerResumenAsistenciaDiaria`).
- **(b1) Aggregate en vivo**: `Obtener{Aggregate}` -- `{Aggregate}` es el nombre del aggregate sin el sufijo `AggregateRoot` (`TurnoAggregateRoot` -> `ObtenerTurno`).
- **(b2) Eventos crudos del stream**: `ListarEventosDe{Aggregate}` (`ListarEventosDeTurno`).

**Colision entre (a) y (b1), ahora infrecuente por construccion (MEF-ADR-0041 decision 3)**: antes de que el read model tuviera nombre propio, cuando compartia concepto con el aggregate ambas vias producian el **mismo** nombre de Function -- y dos Functions con identico `[Function("...")]` no pueden coexistir. Con un read model nombrado por su necesidad de lectura (`ResumenAsistenciaDiaria`, no `Asistencia`), `Obtener{X}` deja de coincidir con `Obtener{Aggregate}` en el caso comun. La colision sigue siendo posible en el caso residual de una vista genuinamente 1:1 cuyo termino coincide con el del aggregate -- ahi un dominio expone **una sola** via de lectura por id a la vez ((a) es la default; (b1) la excepcion cuando no existe proyeccion materializada), y debe desambiguar el nombre explicitamente en el issue que lo pida (Rule of Three, MEF-ADR-0018).

## Ruta HTTP: REST por recurso, nunca el nombre de la Function

Toda Function HTTP -- comando y query -- declara su `Route` explicitamente; el default del atributo nunca se usa. Una query reutiliza **el mismo segmento de recurso que ya usa el comando de ese recurso**, sumando `{id}` para el caso de un item:

```csharp
// ObtenerTurno/FunctionEndpoint.cs
[Function("ObtenerTurno")]
public async Task<IActionResult> Run(
    [HttpTrigger(AuthorizationLevel.Function, "get", Route = "Programacion/Turnos/{id}")]
    HttpRequest req,
    string id,
    CancellationToken ct)

// ListarTurnos/FunctionEndpoint.cs  <- clase y namespace distintos: una carpeta por query
[Function("ListarTurnos")]
public async Task<IActionResult> Run(
    [HttpTrigger(AuthorizationLevel.Function, "get", Route = "Programacion/Turnos")]
    HttpRequest req,
    CancellationToken ct)
```

**El `{id}` de la ruta se declara `string` en la firma y se parsea dentro del metodo** -- no se tipa el parametro ni la plantilla. La razon no es que el segmento no pueda enlazarse tipado (eso queda **no verificado** para el worker aislado, y no cambia la regla: un fallo de enlace no es un `400` bajo control del endpoint), sino que el `400` con mensaje que la documentacion oficial de ASP.NET Core pide para entrada invalida lo produce el parseo explicito, y un route constraint (`{id:guid}`) daria `404` sin normalizar el casing -- MEF-ADR-0037 seccion 2 y Alt 4. Asi que **recibirlo como `string` no autoriza a pasarlo sin parsear a `LoadAsync`/`AggregateStreamAsync`**: MEF-ADR-0037 exige un unico parseo tipado dentro del metodo antes de tocar cualquier read API -- `Guid.TryParse` si la identidad nacio `Guid` (el caso comun), o cada componente de una clave compuesta parseado por separado y reconstruido con `ComputarStreamId(...)` -- con `400` explicito si el parseo falla. Ver [read-apis.md](read-apis.md) para el patron completo, la frontera de los read models N2 (cuyo `TId` no es un stream key) y la proscripcion de recibir la clave ya armada.

El tipo de la request es `HttpRequest` y el retorno `IActionResult` -- la integracion ASP.NET Core del worker aislado --, no `HttpRequestData`/`HttpResponseData` (modelo alterno, mantenido solo por compatibilidad hacia atras).

**Por que `Route` explicito**: el `Route` del `HttpTriggerAttribute` es opcional y *"the default value if none is provided is `<functionname>`"* -- sin el atributo, la ruta seria `/api/ObtenerTurno`, no el recurso REST.

**Cada Function declara su verbo, siempre**: el GET y el POST del mismo recurso se distinguen por el **metodo HTTP**, nunca por el nombre de la Function -- y eso obliga a declarar el metodo en **ambos** lados (`Methods` es opcional y responde a todos los verbos si se omite, asi que un comando que omita su `"post"` captura tambien el GET del mismo segmento y se pisa con la query).

**NO VERIFICADO -- dos Functions con plantilla de ruta identica y verbos disjuntos**: que convivan sin conflicto en el host de Azure Functions no esta verificado contra la documentacion oficial (MEF-ADR-0006 lo registra explicitamente como tal). La query por id no depende de esto (su plantilla lleva `{id}` y no coincide con la del POST de creacion); el par que **si** comparte plantilla (`ListarTurnos` GET vs `CrearTurno` POST) debe verificarse empiricamente en el primer dominio que lo implemente, antes de asumir que arranca.

**Nunca `Route = ""`**: fijar la ruta vacia para que una query quede en la raiz de `/api` produce 404 en el worker aislado -- comportamiento observado en campo, **no verificado** contra un caso reproducible de la documentacion oficial. Regla operativa hasta que un issue puntual la reverifique empiricamente.

## Organizacion vertical: una carpeta por query, sin sufijo `Function`

```
src/<RootNamespace>.{Dominio}/
  ObtenerTurno/                          <- feature folder por query GET (sin sufijo Function)
    FunctionEndpoint.cs                  <- [Function("ObtenerTurno")], Route = "Programacion/Turnos/{id}"
  ListarTurnos/
    FunctionEndpoint.cs                  <- [Function("ListarTurnos")], Route = "Programacion/Turnos"
```

(`<RootNamespace>` se resuelve leyendo el `CLAUDE.md` raiz del consumidor, seccion "Tokens del harness".)

- `FunctionEndpoint.cs` como nombre de clase en cada directorio -- no colisiona porque cada directorio es un namespace diferente.
- Sin sufijo `Function` (ese sufijo es solo para comandos, que si tienen un record colisionante en su propio directorio).
- **Nunca** agrupar todas las queries de un dominio en una unica clase (`XQueriesEndpoint`, patron descartado del proyecto de referencia ControlPlane): rompe el mismo invariante de organizacion vertical que ya rige comandos y reacciones a evento (una carpeta = un namespace = una responsabilidad).

## Tabla de convenciones C# (artefactos de proyeccion)

| Concepto | Convencion | Ejemplo |
|---|---|---|
| Query (Function/metodo GET) | `Obtener{X}` (item por id) / `Listar{X}s` (coleccion) | `ObtenerTurno`, `ListarTurnos` |
| Read model (vista de lectura) | Termino del lenguaje ubicuo, sin sufijo de implementacion (MEF-ADR-0041 decision 3) | `ResumenAsistenciaDiaria` |
| Clase de proyeccion (companion, N1/N2) | `{TerminoVista}Projection` (`partial`, en el worker, mismo stem que la vista) | `ResumenAsistenciaDiariaProjection` -> `ResumenAsistenciaDiaria` |
| Marker del named store de proyecciones | `I{Dominio}ProjectionStore` | `IVentasProjectionStore` |
| Seam de composicion de proyecciones (por dominio) | `ConfiguracionMartenProjections{Dominio}`, metodo `Configurar{Dominio}` | `ConfiguracionMartenProjectionsVentas.ConfigurarVentas()` |

El seam de proyecciones es el hermano read-side del seam de composicion del write-side (MEF-ADR-0029: `ComposicionServicios{Dominio}`/`AgregarServicios{Dominio}`) -- misma idea de fuente unica de wiring por dominio, distinto proceso y distinto nombre para no confundirlos al leer un `Program.cs`.

Las clases son en espanol. Los sufijos de patrones reconocidos (Endpoint, Projection, ProjectionStore) son en ingles. El read model es la **excepcion deliberada**: no lleva sufijo tecnico -- su nombre es un termino del lenguaje ubicuo, derivado de la necesidad de lectura y nunca del evento ni del aggregate (MEF-ADR-0041).

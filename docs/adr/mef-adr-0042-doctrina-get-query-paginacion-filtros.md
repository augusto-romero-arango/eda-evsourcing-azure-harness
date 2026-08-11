# MEF-ADR-0042: Doctrina GET vs QUERY, paginación y filtros múltiples de las read APIs

- **Fecha**: 2026-08-11
- **Estado**: aceptado
- **Aplica a**: doctrina read-side del marco que fija (1) el criterio decidible para elegir el método HTTP de una Function de query (GET vs QUERY, RFC 10008), (2) la estrategia de paginación de `Listar{Concepto}s` sobre `QuerySession` de Marten, y (3) la convención de filtros múltiples/combinados. Extiende MEF-ADR-0035 (que fija `Obtener{Concepto}` por id y `Listar{Concepto}s` por filtro/lista, sección 3, sin definir paginación ni filtros combinados) y enmienda MEF-ADR-0006 (naming: `Listar{X}s` conserva nombre y ruta cuando su verbo es QUERY). Cross-referencia MEF-ADR-0041 (forma de la vista -- esta doctrina no contradice su decisión 4, el DTO de respuesta sigue siendo excepción), MEF-ADR-0028 (tenancy -- la sesión QUERY se abre acotada al tenant del resolver, idéntico al GET), MEF-ADR-0032 (fuente del patrón "NO VERIFICADO + gate empírico" que la sección 6 replica), MEF-ADR-0018 (Rule of Three -- offset como excepción documentada) y MEF-ADR-0037 (identidad del stream, sin cambios: el `id` de ruta de un GET por id sigue el mismo parseo tipado; esta doctrina no introduce una segunda vía). No decide nada del lado APIM/CORS -- ese touchpoint vive en el issue de seguimiento que este ADR bloquea.

## Contexto

MEF-ADR-0035 fija `Obtener{Concepto}` por id y `Listar{Concepto}s` por filtro/lista (sección 3) y su tabla de read APIs (sección 4) cubre `session.LoadAsync<TView>(id)` / `session.Query<TView>()`. Pero no define **paginación** (¿keyset? ¿offset? ¿cuál es el default sobre una colección event-sourced que crece sin cota?) ni una convención para **filtros múltiples/combinados** (varios criterios a la vez, rangos, listas de valores, combinaciones AND/OR) -- exactamente el terreno donde el query string de un GET se degrada: no tiene una representación canónica sin ambigüedad para un filtro estructurado, y forzarlo produce serializaciones ad-hoc que cada dominio inventaría distinto.

En junio de 2026, IETF publicó **RFC 10008, "The HTTP QUERY Method"** (Reschke/Snell/Bishop, WG httpbis, ex `draft-ietf-httpbis-safe-method-w-body-14`), **Proposed Standard** -- verificado contra `rfc-editor.org/rfc/rfc10008.json` [1]. QUERY es un método **seguro e idempotente con body**: un vehículo estándar para un filtro estructurado que un GET no puede expresar sin desbordar el query string. La sesión de refinamiento de este issue (2026-08-11) verificó, contra el RFC y contra POCs propios sobre el stack del marco (.NET 10, Azure Functions Core Tools 4.6.0), que el host lo soporta sin cambios de código. Sin una doctrina que fije **cuándo GET y cuándo QUERY**, cada dominio con un filtro combinado resolvería distinto (query string serializado a mano, un POST semánticamente incorrecto, un GET con body no estándar) -- el mismo tipo de decisión que MEF-ADR-0035 ya evitó para el estilo de proyección, pero fuera del alcance que ese ADR se fijó.

### RFC 10008: semántica clave verificada

- **Seguro e idempotente con body**: puede reintentarse tras un fallo de conexión, igual que GET -- a diferencia de POST.
- **`Content-Type` obligatorio**: *"Servers MUST fail the request if the Content-Type request field is missing or is inconsistent with the request content"* [1].
- **Tabla de códigos de error** (sección 2): `400` (falta de media type o inconsistencia contenido-tipo), `415` (media type no soportado), `422` (contenido sintácticamente correcto pero no procesable), `406` (respuesta en el formato solicitado no soportado) [1].
- **Cacheable**, pero el cache key *"MUST incorporate the request content and related metadata"* (sección 2.7) [1] -- irrelevante para el marco: no hay CDN entre APIM y la Function App.
- **Sección 2.8 respalda la paginación en el formato de query, no en HTTP Range**: *"Query formats often define their own way of limiting or paging through result sets ... It is expected that these built-in features will be used instead of HTTP Range Requests"* [1].
- **Sección 4: QUERY siempre dispara preflight CORS** -- *"A QUERY request from user agents implementing Cross-Origin Resource Sharing (CORS) will require a 'preflight' request, as QUERY does not belong to the set of CORS-safelisted methods"* [1].

### Soporte del stack verificado empíricamente (POCs 2026-08-11, .NET 10 + Azure Functions Core Tools 4.6.0, local)

| Eslabón | Resultado |
|---|---|
| Azure Functions isolated worker: `HttpTrigger(AuthorizationLevel.Function, "query", Route = ...)` | Funciona: el host registra `[QUERY]`, enruta el verbo, el body llega intacto. Un GET no coincidente responde **404**, no 405 |
| ASP.NET Core / Kestrel (`MapMethods`) | Funciona (200 con body) |
| `HttpClient` con `new HttpMethod("QUERY")` (el que usan los smoke tests del marco) | Funciona end-to-end contra el host de Functions |
| curl `-X QUERY` | Funciona |

### Soporte verificado documentalmente

- **APIM**: el campo `method` de una operación es *"A Valid HTTP Operation Method. Typical Http Methods like GET, PUT, POST but not limited by only them"* [2] -- QUERY no queda excluido por el contrato de la API.
- **OpenAPI 3.2**: el Path Item Object declara un campo `query` dedicado (*"A definition of a QUERY operation"*) más `additionalOperations` [3] -- QUERY tiene representación de primera clase en el formato de especificación que el marco ya usaría para documentar sus APIs.

### Qué queda fuera de este ADR

El wiring de APIM/CORS para que un SPA consuma un endpoint QUERY sin que el preflight se caiga -- la política global del `apim-gateway-scaffolder` no enumera `QUERY` en `<allowed-methods>` hoy -- es alcance del issue de seguimiento que este ADR bloquea, no de este documento.

## Decisión

### 1. Frontera GET vs QUERY: criterio decidible (CA-1)

| Superficie | Método | Condición |
|---|---|---|
| `Obtener{Concepto}` por id | **GET** | Siempre -- un id de ruta nunca necesita body (MEF-ADR-0037). |
| `Listar{Concepto}s` con filtros **planos de igualdad** en query string | **GET** | Cada filtro es un par `campo=valor` independiente (`?estado=Abierto&fecha=2026-08-11`), sin necesidad de expresar rangos, listas ni combinaciones lógicas. |
| `Listar{Concepto}s` con filtros **estructurados** (combinaciones AND/OR, rangos, listas de valores) | **QUERY** (RFC 10008) | El filtro no cabe en un par `campo=valor` sin ambigüedad -- p. ej. `FechaInicio` entre dos fechas, `Estado` en una lista de valores, o dos condiciones combinadas con OR. |
| `Listar{Concepto}s` con **paginación por cursor** | **QUERY** (RFC 10008) | El cursor viaja en el body estructurado (sección 2), no en el query string. |

**Verificación de decidibilidad**: dado cualquier endpoint de lectura hipotético, la pregunta "¿el filtro es un conjunto de pares `campo=valor` en igualdad, sin rango ni combinación lógica?" tiene una única respuesta objetiva -- si sí, GET; si no, QUERY. No hay zona gris: un filtro que hoy es un solo `campo=valor` y mañana gana un segundo campo sigue siendo GET (sigue siendo AND implícito de pares planos); el cruce a QUERY ocurre solo cuando aparece un rango, una lista de valores, una combinación OR, o un cursor.

**Un `Listar{Concepto}s` que empieza en GET puede migrar a QUERY sin romper su identidad**: MEF-ADR-0006 (enmienda, ver sección 5 abajo) fija que el nombre de la Function y su `Route` no cambian al cruzar esta frontera -- solo el segundo argumento del `HttpTriggerAttribute` (`"get"` → `"query"`).

### 2. Doctrina de paginación: keyset/cursor como default, offset como excepción documentada (CA-2)

**Keyset/cursor es el default** para `Listar{Concepto}s`. Una colección event-sourced crece sin cota superior conocida, y `Skip(n)` (offset) sobre una tabla que sigue creciendo produce lecturas inconsistentes entre páginas: una fila insertada mientras el cliente pagina puede desplazar el resto y hacer que la página siguiente repita o salte filas -- exactamente el modo de falla que RFC 10008 sección 2.8 anticipa al preferir que el propio formato de query resuelva la paginación en vez de HTTP Range Requests [1].

**Mecánica sobre `QuerySession`**: LINQ estándar sobre `session.Query<TView>()` (la vía (a') que ya fija MEF-ADR-0035 sección 4) -- `Where` para los filtros, `OrderBy` sobre un campo monótono (típicamente el propio `Id`, ya que en N1 es el `StreamKey`, MEF-ADR-0035 sección 2), y `Take(n)` acotando el tamaño de página. El cursor es el último valor de ese campo monótono devuelto en la página anterior; la página siguiente filtra `Where(t => t.Id.CompareTo(cursor) > 0)` antes de aplicar `OrderBy`/`Take`. El cursor viaja **dentro del formato de query** -- un campo del DTO de filtro tipado (sección 3) -- consistente con RFC 10008 sección 2.8, nunca como un header `Range` de HTTP.

**Offset es la excepción documentada, no una segunda vía por defecto** (Rule of Three, MEF-ADR-0018): Marten expone paginación por número de página sobre cualquier `IQueryable<T>` -- `session.Query<TView>().ToPagedListAsync(pageNumber, pageSize)` (también `ToPagedList` síncrono), que devuelve un resultado con `TotalItemCount`/`PageCount`/`IsFirstPage`/`IsLastPage`/`HasNextPage`/`HasPreviousPage`; o, para control manual, `session.Query<TView>().Stats(out QueryStatistics stats).Where(...).Take(n)` [4]. La documentación oficial de Marten advierte que la función ventana que `ToPagedListAsync` usa por defecto *"won't perform well for large dataset with millions of records"* [4] -- admite un tercer parámetro (`useCountQuery: true`) para forzar un `count(*)` separado en vez de la función ventana, pero no elimina el problema estructural de fondo (offset sobre una colección creciente). Un dominio adopta offset solo con evidencia real de necesidad -- p. ej. un panel administrativo con navegación "página N de M" sobre una colección acotada y de bajo crecimiento, no un listado directo de streams event-sourced -- documentada en su propio issue.

**Filtro y paginación conviven en el mismo DTO** (sección 3): el cursor y el `Take` son campos más del filtro tipado, no un mecanismo aparte.

### 3. Doctrina de filtros múltiples: DTO tipado, AND por defecto, mapeo de códigos de error (CA-3)

**El filtro es un DTO tipado**, deserializado del body de la request QUERY:

```csharp
public sealed record FiltroListarTurnos(
    string? Estado,
    IReadOnlyList<string>? Estados,
    DateOnly? DesdeFecha,
    DateOnly? HastaFecha,
    string? Cursor,
    int Take = 50);
```

- **`Content-Type: application/json` es obligatorio** (RFC 10008 sección 2 [1]) -- pero el host de Azure Functions/ASP.NET Core no lo rechaza automáticamente antes de que el endpoint corra (**no verificado**, fuera del alcance de los POCs de este issue): la responsabilidad recae en el parseo explícito del filtro (`req.ReadFromJsonAsync<FiltroListarTurnos>(ct)`), que falla si el body no deserializa como el DTO esperado.
- **Combinación AND por defecto**: cada campo no nulo del DTO se aplica como una condición `Where` adicional. Un `OR` explícito exige su propio campo tipado (p. ej. `Estados` como lista, en vez de repetir `Estado` con semántica ambigua) -- nunca una convención implícita de nombres de query param o de un operador embebido en un string.
- **Mapeo de los códigos de la sección 2.1 del RFC a la forma que el marco ya usa**: cada código se emite como un `ObjectResult` explícito con ese `StatusCode` y un mensaje en el body -- la misma forma (status + mensaje) que MEF-ADR-0037 ya fija para el `400` del parseo del id de ruta (`BadRequestObjectResult` con mensaje), nunca un código pelado sin cuerpo:

  | Código RFC | Causa | Forma en el marco |
  |---|---|---|
  | `400` | Body ausente, no es JSON válido, o inconsistente con `Content-Type` | `new BadRequestObjectResult("<mensaje>")` |
  | `415` | `Content-Type` no soportado (ni `application/json`) | `new ObjectResult("<mensaje>") { StatusCode = StatusCodes.Status415UnsupportedMediaType }` |
  | `422` | JSON sintácticamente válido pero semánticamente inconsistente (p. ej. `DesdeFecha > HastaFecha`) | `new ObjectResult("<mensaje>") { StatusCode = StatusCodes.Status422UnprocessableEntity }` |
  | `406` | Fuera del camino feliz del marco -- toda respuesta es JSON, ningún endpoint del marco negocia `Accept` hoy | No aplica; no se implementa hasta que un caso real lo exija (Rule of Three, MEF-ADR-0018) |

### 4. Ejemplo canónico y mecánica del endpoint (CA-4)

El ejemplo completo, con `HttpTrigger(..., "query")`, el parseo tipado del filtro, la sesión acotada al tenant idéntica al GET (MEF-ADR-0028), y la nota de que el host responde `404` (no `405`) ante un verbo no coincidente, vive en `skills/projections/read-apis.md` -- no se duplica aquí (mismo principio de "el ADR fija doctrina, el Skill fija la receta copiable" que ya aplican MEF-ADR-0035/0041 frente al Agent Skill `projections`).

### 5. Naming: `Listar{X}s` conserva nombre y ruta; el verbo distingue (CA-5)

MEF-ADR-0006 se enmienda (control de cambios de ese ADR) para fijar que cruzar la frontera de la sección 1 -- de GET a QUERY, o viceversa -- **no** cambia el nombre de la Function (`[Function("Listar{X}s")]`) ni su `Route`: el único elemento que distingue un método de otro es el segundo argumento del `HttpTriggerAttribute` (`"get"` vs `"query"`), exactamente el mismo principio que ya distingue GET de POST sobre el mismo segmento de recurso (MEF-ADR-0006, "Cada Function declara su verbo, siempre"). `skills/projections/naming.md` reenmienda con la misma nota.

### 6. Puntos NO VERIFICADO: gate empírico obligatorio antes de asumir que arranca en Azure real (CA-6)

Mismo patrón que MEF-ADR-0032 sección 8: los puntos siguientes son verificaciones empíricas **obligatorias** antes de asumir que QUERY funciona end-to-end en un entorno real -- nunca se asumen por analogía con el POC local.

| Punto | Estado | Gate |
|---|---|---|
| Front-end de App Service en Azure real | **NO VERIFICADO** -- el POC valida el host local (Core Tools) y Kestrel; el front-end de App Service podría filtrar verbos HTTP desconocidos antes de que lleguen al worker | Smoke test en dev, la primera vez que un dominio real exponga un endpoint QUERY desplegado |
| APIM Consumption reenviando QUERY end-to-end vía `forward-request` de la política global | **NO VERIFICADO** -- MEF-ADR-0032 no documenta el comportamiento de APIM Consumption frente a un método no estándar en el `<backend>` | Verificación empírica contra una instancia APIM real, antes de exponer un endpoint QUERY detrás del gateway |
| CORS del gateway | **NO VERIFICADO como bloqueante conocido, no hipotético**: la política global del `apim-gateway-scaffolder` (MEF-ADR-0032 sección 3, B3) enumera `<allowed-methods>` sin `QUERY` -- un SPA se cae en el preflight (RFC 10008 sección 4) hoy mismo | Fix en el issue de seguimiento de este ADR (fuera de alcance aquí); no instalar un endpoint QUERY consumido desde un SPA sin resolver ese issue primero |

**Regla operativa**: un agente o desarrollador que implemente el primer endpoint QUERY real de un consumidor debe tratar los tres puntos de la tabla como gates bloqueantes de ese primer despliegue, no como notas informativas -- mismo criterio que MEF-ADR-0032 sección 8 ya fija para sus propios puntos NO VERIFICADO de WorkOS.

## Alternativas consideradas

### Alt 1: seguir usando GET con filtros serializados en query string para todo caso (rangos, listas, combinaciones)

**Descartada**: query string no tiene una representación canónica sin ambigüedad para un rango (`?desdeFecha=X&hastaFecha=Y` es legible, pero una lista de valores o una combinación OR fuerza convenciones ad-hoc -- `?estado=A,B` vs `?estado[]=A&estado[]=B` vs `?estado=A&estado=B`) que cada implementador resolvería distinto sin una doctrina. QUERY con un DTO tipado en el body elimina esa ambigüedad por construcción: el shape del filtro es un tipo C#, no una convención de serialización de string.

### Alt 2: POST para filtros combinados en vez de QUERY

**Descartada**: POST no es seguro ni idempotente -- semánticamente incorrecto para una operación de lectura pura, y **no** puede cachearse por definición del método. Adoptar POST para un `Listar{X}s` estructurado rompería la propiedad "las queries no tienen efectos secundarios" que el marco ya asume implícitamente en toda su superficie de lectura (MEF-ADR-0035 sección 4, exclusivamente `QuerySession`). QUERY preserva exactamente la semántica de GET (seguro, idempotente, cacheable) mientras admite el body que GET no puede llevar de forma estándar.

### Alt 3: offset como default de paginación, con keyset como excepción

**Descartada** (invierte la sección 2): offset es la vía más familiar e intuitiva ("página 3 de 12"), pero degrada estructuralmente sobre una colección que crece sin cota -- exactamente el caso común del marco (streams event-sourced). Fijarlo como default institucionalizaría el modo de falla (lecturas inconsistentes entre páginas) en el camino feliz, en vez de reservarlo para el caso excepcional donde de verdad se necesita navegación por número de página sobre una colección acotada.

### Alt 4: un tercer verbo/convención propia del marco en vez de adoptar RFC 10008

**Descartada**: RFC 10008 ya resuelve el problema exacto (safe+idempotent+body) como estándar propuesto de IETF, con soporte verificado en el stack del marco (.NET/Azure Functions, APIM, OpenAPI 3.2). Inventar una convención propia -- p. ej. un header custom que reinterprete un POST como lectura -- duplicaría trabajo ya resuelto por un estándar en proceso de adopción, sin ninguna ventaja concreta, y perdería la interoperabilidad con herramientas (clientes HTTP, proxies, documentación OpenAPI) que ya reconocen QUERY como método de primera clase.

## Consecuencias

### Positivas

- **Frontera decidible sin ambigüedad** entre GET y QUERY: dos lectores distintos del ADR llegan al mismo verbo para el mismo endpoint hipotético (CA-1).
- **Paginación robusta por default**: keyset/cursor no degrada con el crecimiento de la colección -- ni bajo carga, ni con escrituras concurrentes durante la navegación entre páginas -- eliminando por construcción el modo de falla que offset introduce sobre streams event-sourced.
- **Filtros combinados con shape tipado**: un DTO C# reemplaza la serialización ad-hoc de query string, con el mismo beneficio de verificación en tiempo de compilación que MEF-ADR-0035 ya aporta a las clases de proyección.
- **Migrar de GET a QUERY no rompe la identidad de la Function**: el nombre y la ruta sobreviven el cruce de la frontera de la sección 1 (CA-5) -- ningún cliente existente que invoque `Listar{X}s` por nombre/ruta se rompe si el filtro gana complejidad y el endpoint migra de método.
- **Riesgo de producción explícito, no oculto**: los tres puntos NO VERIFICADO (sección 6) quedan como gates citables, en vez de descubrirse recién en el primer despliegue real -- mismo beneficio que MEF-ADR-0032 ya demostró para su propio catálogo de trampas.

### Negativas

- **QUERY es un método reciente (RFC de junio 2026, Proposed Standard)**: herramientas, proxies y middlewares de terceros pueden no reconocerlo todavía -- el marco asume el riesgo de adoptar un estándar en una etapa temprana de su ciclo de vida, mitigado por el soporte ya verificado en el stack propio (.NET, APIM, OpenAPI 3.2), pero sin garantía sobre herramientas fuera de ese stack.
- **Tres gates de producción sin resolver** (sección 6): ningún consumidor puede exponer un endpoint QUERY real detrás de APIM o consumido desde un SPA hasta que el issue de seguimiento cierre el punto de CORS, y hasta que el primer despliegue real verifique App Service y APIM Consumption -- este ADR fija doctrina, no un camino de producción completo.
- **Paginación por cursor exige un campo monótono en el read model**: un `Listar{X}s` sobre una vista sin ningún campo naturalmente ordenable y único (p. ej. una vista donde el `Id` no es un `StreamKey` sino un campo de negocio no monótono, caso N2) necesita elegir o introducir un campo de ordenamiento estable -- costo que offset no exige, y que este ADR no dispensa.
- **El DTO de filtro es una superficie nueva a mantener por endpoint**: a diferencia de un GET con query string (sin tipo dedicado), cada `Listar{X}s` sobre QUERY declara su propio record de filtro -- consistente con el resto del estilo tipado del marco (MEF-ADR-0012), pero un archivo más que MEF-ADR-0035 no exigía para la vía GET.

## Referencias

- **[1]** RFC 10008, "The HTTP QUERY Method" -- J. Reschke, J. M. Snell, M. Bishop, IETF, junio 2026, Proposed Standard (verificado contra `rfc-editor.org/rfc/rfc10008.json`). Secciones citadas: 2 (`Content-Type` obligatorio, tabla de códigos de error 400/415/422/406), 2.1 (detalle de la tabla de errores), 2.7 (cache key debe incorporar el body), 2.8 (paginación respaldada en el formato de query, no en HTTP Range Requests), 4 (QUERY siempre dispara preflight CORS -- no es un método CORS-safelisted). https://www.rfc-editor.org/rfc/rfc10008.html
- **[2]** "ApiOperation" -- REST API reference de Azure API Management, campo `method`: *"A Valid HTTP Operation Method. Typical Http Methods like GET, PUT, POST but not limited by only them."* https://learn.microsoft.com/rest/api/apimanagement/current-ga/api-operation
- **[3]** OpenAPI Specification v3.2.0, "Path Item Object": campo `query` dedicado (*"A definition of a QUERY operation"*) y `additionalOperations` para métodos fuera del set fijo. https://spec.openapis.org/oas/v3.2.0
- **[4]** "Paging" -- Marten docs (martendb.io), verificado 2026-08-11: `Query<T>().ToPagedListAsync(pageNumber, pageSize)` (también síncrono `ToPagedList`), resultado con `TotalItemCount`/`PageCount`/`IsFirstPage`/`IsLastPage`/`HasNextPage`/`HasPreviousPage`; advertencia oficial *"won't perform well for large dataset with millions of records"* sobre la función ventana `count(*) OVER()` por defecto, con el parámetro `useCountQuery: true` como mitigación parcial (fuerza un `count(*)` separado); alternativa manual `Query<T>().Stats(out QueryStatistics stats).Where(...).Take(n)`. https://martendb.io/documents/querying/linq/paging.html
- MEF-ADR-0006 (convenciones de nombramiento de Functions Azure): **enmendado por este ADR** -- `Listar{X}s` conserva nombre y ruta cuando cruza de GET a QUERY (sección 5).
- MEF-ADR-0018 (heurísticas de evolución y reuso, Rule of Three): fundamenta offset como excepción documentada (sección 2), no un segundo default.
- MEF-ADR-0028 (estrategia de tenancy): la `QuerySession` de un endpoint QUERY se abre acotada al tenant del resolver, idéntico al patrón que ya fija MEF-ADR-0035 sección 5 para el GET.
- MEF-ADR-0032 (identidad y autenticación en el borde, WorkOS + APIM): fuente del patrón "catálogo NO VERIFICADO + gate empírico obligatorio" que la sección 6 de este ADR replica; su catálogo B1-B10 documenta además el estado actual de `<allowed-methods>` sin `QUERY` que motiva el issue de seguimiento de CORS.
- MEF-ADR-0035 (doctrina de proyección y query read-side): este ADR extiende su sección 3 (superficie de consulta) con paginación y filtros múltiples; no reabre el estilo de código ni la tabla de read APIs de ese ADR.
- MEF-ADR-0037 (identidad del stream y su representación string canónica): el patrón `400` con mensaje (`BadRequestObjectResult`) que la sección 3 de este ADR generaliza a `415`/`422` ya lo fija ese ADR para el parseo del id de ruta de un GET.
- MEF-ADR-0041 (forma propia de la vista read-side): esta doctrina no contradice su decisión 4 -- el GET/QUERY sigue sirviendo el record de `ReadModels` directamente; el DTO de filtro de la sección 3 de este ADR es un tipo de **request**, no de respuesta, y no reabre la excepción del DTO de respuesta que MEF-ADR-0041 ya acota bajo Rule of Three.
- `skills/projections/read-apis.md`: aloja el ejemplo canónico completo de un endpoint QUERY (sección 4 de este ADR).
- `skills/projections/naming.md`: reenmendado en paralelo a MEF-ADR-0006 (sección 5 de este ADR).
- Issue #587 (este ADR); issue de seguimiento del CORS de APIM (creado en la misma sesión de refinamiento, bloqueado por este ADR); issue #583 (receta del planner que captura paginación/filtros/cadencia en el handoff -- relacionado, no bloqueante).

## Control de cambios

- 2026-08-11: creación como `aceptado` (issue #587). Fija la frontera decidible GET vs QUERY (RFC 10008) para las Functions de query del marco -- GET para `Obtener{X}` y para `Listar{X}s` con filtros planos de igualdad en query string; QUERY para filtros estructurados (AND/OR, rangos, listas de valores) y paginación por cursor --, la doctrina de paginación (keyset/cursor como default sobre `QuerySession`, offset como excepción documentada bajo Rule of Three vía `ToPagedListAsync`/`Stats(out QueryStatistics)`), la doctrina de filtros múltiples (DTO tipado deserializado del body, `Content-Type: application/json` obligatorio, combinación AND por defecto, mapeo de los códigos 400/415/422/406 del RFC a `ObjectResult` con mensaje) y el naming (`Listar{X}s` conserva nombre y ruta al cruzar de GET a QUERY, enmienda de MEF-ADR-0006). Registra tres puntos NO VERIFICADO como gates empíricos obligatorios antes de producción real (front-end de App Service, APIM Consumption reenviando QUERY, CORS del gateway sin `QUERY` en `<allowed-methods>`), con el patrón de MEF-ADR-0032 sección 8. No decide nada del lado APIM/CORS -- ese fix vive en el issue de seguimiento que este ADR bloquea.

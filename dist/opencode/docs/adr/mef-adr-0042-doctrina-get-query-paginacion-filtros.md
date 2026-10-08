# MEF-ADR-0042: Doctrina GET vs QUERY, paginación y filtros múltiples de las read APIs

- **Fecha**: 2026-08-11
- **Estado**: aceptado
- **Aplica a**: doctrina read-side del marco que fija (1) el criterio decidible para elegir el método HTTP de una Function de query (GET vs QUERY, RFC 10008), (2) la estrategia de paginación de `Listar{Concepto}s` sobre `QuerySession` de Marten (keyset siempre, `Take` opcional, sobre de respuesta con cursor opaco), y (3) la convención de filtros múltiples/combinados. No decide el wiring del borde (APIM/CORS): ese touchpoint lo materializó el issue #608 sobre el `apim-gateway-scaffolder` (MEF-ADR-0032, B3/B11). Extiende MEF-ADR-0035 (que fija `Obtener{Concepto}` por id y `Listar{Concepto}s` por filtro/lista, sección 3, sin definir paginación ni filtros combinados) y enmienda MEF-ADR-0006 (naming: `Listar{X}s` conserva nombre y ruta cuando su verbo es QUERY). Cross-referencia MEF-ADR-0041 (forma de la vista -- esta doctrina no contradice su decisión 4, el DTO de respuesta sigue siendo excepción), MEF-ADR-0028 (tenancy -- la sesión QUERY se abre acotada al tenant del resolver, idéntico al GET), MEF-ADR-0032 (fuente del patrón "NO VERIFICADO + gate empírico" que la sección 6 replica), MEF-ADR-0018 (Rule of Three -- criterio por el que no se mantiene offset como segunda vía), MEF-ADR-0043 (sección 7: régimen de aplicabilidad "solo endpoints nuevos" que la sección 8 replica) y MEF-ADR-0037 (identidad del stream, sin cambios: el `id` de ruta de un GET por id sigue el mismo parseo tipado; esta doctrina no introduce una segunda vía). No decide nada del lado APIM/CORS -- ese touchpoint vive en el issue de seguimiento que este ADR bloquea.

## Contexto

MEF-ADR-0035 fija `Obtener{Concepto}` por id y `Listar{Concepto}s` por filtro/lista (sección 3) y su tabla de read APIs (sección 4) cubre `session.LoadAsync<TView>(id)` / `session.Query<TView>()`. Pero no define **paginación** (¿keyset? ¿offset? ¿cuál es el default sobre una colección event-sourced que crece sin cota?) ni una convención para **filtros múltiples/combinados** (varios criterios a la vez, rangos, listas de valores, combinaciones AND/OR) -- exactamente el terreno donde el query string de un GET se degrada: no tiene una representación canónica sin ambigüedad para un filtro estructurado, y forzarlo produce serializaciones ad-hoc que cada dominio inventaría distinto.

En junio de 2026, IETF publicó **RFC 10008, "The HTTP QUERY Method"** (Reschke/Snell/Bishop, WG httpbis, ex `draft-ietf-httpbis-safe-method-w-body-14`), **Proposed Standard** -- verificado contra `rfc-editor.org/rfc/rfc10008.json` [1]. QUERY es un método **seguro e idempotente con body**: un vehículo estándar para un filtro estructurado que un GET no puede expresar sin desbordar el query string. La sesión de refinamiento de este issue (2026-08-11) verificó, contra el RFC y contra POCs propios sobre el stack del marco (.NET 10, Azure Functions Core Tools 4.6.0), que el host lo soporta sin cambios de código. Sin una doctrina que fije **cuándo GET y cuándo QUERY**, cada dominio con un filtro combinado resolvería distinto (query string serializado a mano, un POST semánticamente incorrecto, un GET con body no estándar) -- el mismo tipo de decisión que MEF-ADR-0035 ya evitó para el estilo de proyección, pero fuera del alcance que ese ADR se fijó.

### RFC 10008: semántica clave verificada

- **Seguro e idempotente con body**: puede reintentarse tras un fallo de conexión, igual que GET -- a diferencia de POST.
- **`Content-Type` obligatorio**: *"Servers MUST fail the request if the Content-Type request field is missing or is inconsistent with the request content"* [1].
- **Tabla de códigos de error** (sección 2.1): `400` (falta de media type o inconsistencia contenido-tipo), `415` (media type no soportado), `422` (contenido sintácticamente correcto pero no procesable), `406` (respuesta en el formato solicitado no soportado) [1].
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

El wiring de APIM/CORS para que un SPA consuma un endpoint QUERY sin que el preflight se caiga fue alcance del issue de seguimiento que este ADR bloqueaba (#608, ya cerrado: la política global del `apim-gateway-scaffolder` enumera `QUERY` en `<allowed-methods>` y sus operaciones wildcard de APIM incluyen el verbo), no de este documento.

## Decisión

### 1. Frontera GET vs QUERY: criterio decidible (CA-1)

| Superficie | Método | Condición |
|---|---|---|
| `Obtener{Concepto}` por id | **GET** | Siempre -- un id de ruta nunca necesita body (MEF-ADR-0037). |
| `Listar{Concepto}s` con filtros **planos de igualdad** en query string | **GET** | Cada filtro es un par `campo=valor` independiente (`?estado=Abierto&fecha=2026-08-11`), sin necesidad de expresar rangos, listas ni combinaciones lógicas. `take` y `cursor` (sección 2) son también parámetros planos de query (`?take=50&cursor=...`) y no fuerzan QUERY. |
| `Listar{Concepto}s` con filtros **estructurados** (combinaciones AND/OR, rangos, listas de valores) | **QUERY** (RFC 10008) | El filtro no cabe en un par `campo=valor` sin ambigüedad -- p. ej. `FechaInicio` entre dos fechas, `Estado` en una lista de valores, o dos condiciones combinadas con OR. |

**Verificación de decidibilidad**: dado cualquier endpoint de lectura hipotético, la pregunta "¿el filtro es un conjunto de pares `campo=valor` en igualdad, sin rango ni combinación lógica?" tiene una única respuesta objetiva -- si sí, GET; si no, QUERY. No hay zona gris: un filtro que hoy es un solo `campo=valor` y mañana gana un segundo campo sigue siendo GET (sigue siendo AND implícito de pares planos); el cruce a QUERY ocurre solo cuando aparece un rango, una lista de valores o una combinación OR.

**Un `Listar{Concepto}s` que empieza en GET puede migrar a QUERY sin romper su identidad**: MEF-ADR-0006 (enmienda, ver sección 5 abajo) fija que el nombre de la Function y su `Route` no cambian al cruzar esta frontera -- solo el segundo argumento del `HttpTriggerAttribute` (`"get"` → `"query"`).

### 2. Doctrina de paginación: keyset/cursor siempre, `Take` opcional, sobre con cursor opaco (CA-2)

**Toda** lista pagina por keyset/cursor, incluidos los catálogos chicos: no hay una segunda vía. En un `GET`, `take` y `cursor` son parámetros planos de query (sección 1); en un QUERY, son campos del body (sección 3). Una colección event-sourced crece sin cota superior conocida, y `Skip(n)` (offset) sobre una tabla que sigue creciendo produce lecturas inconsistentes entre páginas: una fila insertada mientras el cliente pagina puede desplazar el resto y hacer que la página siguiente repita o salte filas -- exactamente el modo de falla que RFC 10008 sección 2.8 anticipa al preferir que el propio formato de query resuelva la paginación en vez de HTTP Range Requests [1].

**Mecánica sobre `QuerySession`**: LINQ estándar sobre `session.Query<TView>()` (la vía (a') que ya fija MEF-ADR-0035 sección 4) -- `Where` para los filtros, `OrderBy` sobre un campo monótono (típicamente el propio `Id`, ya que en N1 es el `StreamKey`, MEF-ADR-0035 sección 2), y `Take(n)` acotando el tamaño de página. La página siguiente filtra por el valor keyset que el servidor decodifica del cursor recibido -- el de la última fila de la página anterior -- (`Where(t => t.Id.CompareTo(cursor) > 0)` en el caso de `Id` string) antes de aplicar `OrderBy`/`Take`. El cursor viaja **dentro del formato de query** -- un parámetro plano en GET o un campo del DTO de filtro tipado en QUERY (sección 3) -- consistente con RFC 10008 sección 2.8, nunca como un header `Range` de HTTP.

**`Take` es opcional.**

- **Sin `Take`**, el endpoint devuelve **todo** lo que cumple el filtro, dentro de la cota de rango si la hay (sección 7). Es la vía de la composición interna (un endpoint o tool que necesita la colección completa) y rige para cualquier llamador.
- **Con `Take`**, devuelve una página acotada en el servidor a un máximo de **200**: el tamaño de página es entrada del cliente como cualquier otra, y el endpoint la pasa por una cota propia (`Math.Clamp(take, 1, 200)`) antes de dárselo a Marten. `Take` mayor a 200 se recorta a 200, no se rechaza.

**Sobre de respuesta.** La respuesta de toda lista es un sobre, nunca un arreglo directo:

```json
{ "elementos": [ ... ], "siguienteCursor": "..." }
```

- La lista se llama `elementos` en todos los endpoints.
- `siguienteCursor` es **opaco**: el servidor serializa los campos keyset (p. ej. base64url) y **solo lo incluye si hay más elementos**; ausente significa fin de la lista (mismo contrato que `nextCursor` en la spec MCP "Pagination" [7]). Para saber si hay más, el servidor pide `Take + 1` a Marten, devuelve `Take` elementos y deriva el cursor del último devuelto. Sin `Take` no hay más páginas, así que `siguienteCursor` nunca aparece.
- El cliente reenvía `siguienteCursor` tal cual en `cursor` y **nunca lo arma ni lo interpreta**. Un cursor que no decodifica responde `400` con mensaje.

**El campo keyset debe ser comparable por el proveedor LINQ de Marten.** Si el keyset es el `Id` string de N1 (el `StreamKey`), la traducción a SQL de `CompareTo`/`>` sobre string **no está documentada** en la superficie de métodos string que Marten declara traducibles [6] -- es el cuarto gate de la sección 6, que se conserva. El cursor opaco habilita la vía que no depende de ese gate: ordenar por un campo naturalmente comparable de la vista (una fecha, un número) con desempate por `Id`, serializando ambos campos en el cursor sin exponer la clave al cliente.

**Sin total.** Ninguna lista devuelve total de elementos, ni exacto ni estimado: sin offset no existe "página N de M", y un conteo sobre una colección creciente es el costo que la paginación keyset evita. Si un consumidor necesita un conteo, se diseña como dato propio de la vista (MEF-ADR-0041), no como atributo de la respuesta de lista.

**Lista vacía y detalle.** Una lista vacía responde `200` con `elementos: []`, nunca `404`. El detalle (`GET .../{id}`) responde la entidad o `404`.

**Filtro y paginación conviven** en el mismo contrato de entrada (sección 3 para QUERY): el cursor y el `Take` son parte del filtro, no un mecanismo aparte.

### 3. Doctrina de filtros múltiples: DTO tipado, AND por defecto, mapeo de códigos de error (CA-3)

**El filtro es un DTO tipado**, deserializado del body de la request QUERY:

```csharp
public sealed record FiltroListarTurnos(
    string? Estado,
    IReadOnlyList<string>? Estados,
    DateOnly? DesdeFecha,
    DateOnly? HastaFecha,
    string? Cursor,
    int? Take);
```

- **`Content-Type: application/json` es obligatorio** (RFC 10008 sección 2 [1]), y el chequeo es responsabilidad explícita del endpoint: que el host de Azure Functions rechace por sí solo un media type no-JSON antes de que el endpoint corra queda **no verificado** (fuera del alcance de los POCs de este issue). No basta con envolver el parseo en un `try/catch`: la doc oficial de `ReadFromJsonAsync` advierte que *"If the request's content-type is not a known JSON type then an error will be thrown"* [5], y ese error **no** es un `JsonException` -- un `catch (JsonException)` lo dejaría escapar como `500` donde el RFC pide `415`. El endpoint verifica primero `req.HasJsonContentType()` [5] (`415` si falla) y solo después deserializa el DTO dentro del `try/catch` que produce el `400`.
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

Mismo patrón que MEF-ADR-0032 sección 8: los puntos siguientes son verificaciones empíricas **obligatorias** antes de asumir que QUERY funciona end-to-end en un entorno real -- nunca se asumen por analogía con el POC local. Los tres primeros son de plataforma (los registró el refinamiento de este issue); el cuarto es del proveedor LINQ de Marten y lo detectó la revisión de este ADR. El tercero (CORS del gateway) ya está **resuelto** por el issue #608 y se conserva en la tabla con su estado actual, para que el rastro del bloqueante y de su cierre viva en un solo lugar.

| Punto | Estado | Gate |
|---|---|---|
| Front-end de App Service en Azure real | **NO VERIFICADO** -- el POC valida el host local (Core Tools) y Kestrel; el front-end de App Service podría filtrar verbos HTTP desconocidos antes de que lleguen al worker | Smoke test en dev, la primera vez que un dominio real exponga un endpoint QUERY desplegado |
| APIM Consumption reenviando QUERY end-to-end vía `forward-request` de la política global | **NO VERIFICADO** -- MEF-ADR-0032 no documenta el comportamiento de APIM Consumption frente a un método no estándar en el `<backend>` | Verificación empírica contra una instancia APIM real, antes de exponer un endpoint QUERY detrás del gateway -- operacionalizado (issue #608) como ítem del checklist post-deploy del `apim-gateway-scaffolder`, de `/install-apim` y de `/install-auth`: `QUERY` con token válido y `Content-Type: application/json` no debe responder `404`/`405` en el borde |
| CORS del gateway | **RESUELTO (issue #608)**: la política global que genera el `apim-gateway-scaffolder` enumera `QUERY` en `<allowed-methods>` (enumeración explícita, nunca `*` -- MEF-ADR-0032 sección 3, B3), así que el preflight del SPA (RFC 10008 sección 4) queda cubierto en toda instalación nueva | Nada pendiente en un gateway nuevo. En uno provisionado antes del #608 el agente **no** edita el módulo existente (aditividad): reporta el delta manual de `<allowed-methods>` en su reporte final, y ese delta debe aplicarse -- y aplicarse en CI -- antes de exponer el endpoint QUERY a un SPA |
| Traducción LINQ del predicado de cursor sobre un `Id` string | **NO VERIFICADO** -- la documentación de Marten declara traducibles, para campos string, `StartsWith`/`EndsWith`/`Contains`/`Equals`/`Regex.IsMatch`/`EqualsIgnoreCase` [6]; ni `CompareTo` ni los operadores de orden (`>`/`<`) sobre string figuran en esa superficie | Verificación por ejecución (test de integración contra Postgres real) en el primer dominio que pagine por keyset sobre un `Id` string; alternativa sin gate: cursor sobre un campo naturalmente comparable (fecha/número) con desempate por `Id` |

**Regla operativa**: un agente o desarrollador que implemente el primer endpoint QUERY real de un consumidor debe tratar todo punto de la tabla que siga **NO VERIFICADO** como gate bloqueante de ese primer despliegue, no como notas informativas -- mismo criterio que MEF-ADR-0032 sección 8 ya fija para sus propios puntos NO VERIFICADO de WorkOS.

### 7. Ventanas temporales, sobre ampliado y alcance del sobre

Una lista cuyo filtro es una **ventana temporal** conserva su cota de rango (el máximo de días o de elementos que el dominio tolera por consulta). El sobre agrega la ventana efectivamente aplicada:

```json
{ "elementos": [ ... ], "desde": "2026-10-01", "hasta": "2026-10-31", "rangoRecortado": true }
```

`desde` y `hasta` son la ventana aplicada tras la cota y `rangoRecortado` indica que el servidor la acotó respecto de la pedida. El cursor sigue la sección 2 (`siguienteCursor`, solo si hay más). El sobre es contrato HTTP: la forma de la vista de `ReadModels` no cambia (MEF-ADR-0035 sección 4, MEF-ADR-0041 decisión 4).

### 8. Aplicabilidad: solo endpoints nuevos

Mismo régimen que MEF-ADR-0043 sección 7. Los endpoints de lista **nuevos** (los que nacen a partir de esta enmienda) cumplen la doctrina de las secciones 2 y 7. Los **preexistentes** no se migran de oficio: devolver un arreglo directo, no devolver cursor o paginar por offset puede tener consumidores ya integrados, y pasar al sobre es un cambio de contrato. Migrarlos exige un issue propio, con inventario de los endpoints afectados y aviso a los consumidores del contrato antes de cambiarlo. Un diff que solo toca un endpoint preexistente no conforme **no es hallazgo bloqueante** de un reviewer.

## Alternativas consideradas

### Alt 1: seguir usando GET con filtros serializados en query string para todo caso (rangos, listas, combinaciones)

**Descartada**: query string no tiene una representación canónica sin ambigüedad para un rango (`?desdeFecha=X&hastaFecha=Y` es legible, pero una lista de valores o una combinación OR fuerza convenciones ad-hoc -- `?estado=A,B` vs `?estado[]=A&estado[]=B` vs `?estado=A&estado=B`) que cada implementador resolvería distinto sin una doctrina. QUERY con un DTO tipado en el body elimina esa ambigüedad por construcción: el shape del filtro es un tipo C#, no una convención de serialización de string.

### Alt 2: POST para filtros combinados en vez de QUERY

**Descartada**: POST no es seguro ni idempotente -- semánticamente incorrecto para una operación de lectura pura, y **no** puede cachearse por definición del método. Adoptar POST para un `Listar{X}s` estructurado rompería la propiedad "las queries no tienen efectos secundarios" que el marco ya asume implícitamente en toda su superficie de lectura (MEF-ADR-0035 sección 4, exclusivamente `QuerySession`). QUERY preserva exactamente la semántica de GET (seguro, idempotente, cacheable) mientras admite el body que GET no puede llevar de forma estándar.

### Alt 3: offset (`ToPagedListAsync`/`Stats`) como default o como excepción documentada

**Descartada**: el único valor de offset es la navegación "página N de M", y eso exige un total. Como ninguna lista devuelve total (sección 2), sin total no hay página N de M y offset no aporta nada que keyset no dé. Además degrada estructuralmente sobre una colección que crece sin cota -- el caso común del marco (streams event-sourced): una fila insertada mientras el cliente pagina desplaza el resto y la página siguiente repite o salta filas, y la función ventana de `ToPagedListAsync` *"won't perform well for large dataset with millions of records"* [4]. Mantenerlo como excepción habría dejado dos vías y tres formas de respuesta por dominio.

### Alt 4: un tercer verbo/convención propia del marco en vez de adoptar RFC 10008

**Descartada**: RFC 10008 ya resuelve el problema exacto (safe+idempotent+body) como estándar propuesto de IETF, con soporte verificado en el stack del marco (.NET/Azure Functions, APIM, OpenAPI 3.2). Inventar una convención propia -- p. ej. un header custom que reinterprete un POST como lectura -- duplicaría trabajo ya resuelto por un estándar en proceso de adopción, sin ninguna ventaja concreta, y perdería la interoperabilidad con herramientas (clientes HTTP, proxies, documentación OpenAPI) que ya reconocen QUERY como método de primera clase.

## Consecuencias

### Positivas

- **Frontera decidible sin ambigüedad** entre GET y QUERY: dos lectores distintos del ADR llegan al mismo verbo para el mismo endpoint hipotético (CA-1).
- **Una sola forma de lista**: sobre `{ elementos, siguienteCursor }`, cursor opaco que el cliente reenvía sin interpretarlo y `Take` opcional -- un llamador interno o externo sabe siempre si hay más y qué pedir a continuación (CA-3).
- **Paginación robusta**: keyset/cursor no degrada con el crecimiento de la colección -- ni bajo carga, ni con escrituras concurrentes durante la navegación entre páginas -- eliminando por construcción el modo de falla que offset introduce sobre streams event-sourced.
- **Filtros combinados con shape tipado**: un DTO C# reemplaza la serialización ad-hoc de query string, con el mismo beneficio de verificación en tiempo de compilación que MEF-ADR-0035 ya aporta a las clases de proyección.
- **Migrar de GET a QUERY no rompe la identidad de la Function**: el nombre y la ruta sobreviven el cruce de la frontera de la sección 1 (CA-5) -- ningún cliente existente que invoque `Listar{X}s` por nombre/ruta se rompe si el filtro gana complejidad y el endpoint migra de método.
- **Riesgo de producción explícito, no oculto**: los puntos NO VERIFICADO (sección 6) quedan como gates citables, en vez de descubrirse recién en el primer despliegue real -- mismo beneficio que MEF-ADR-0032 ya demostró para su propio catálogo de trampas.

### Negativas

- **Sin `Take`, el volumen no tiene cota de página**: el endpoint devuelve todo lo que cumple el filtro, así que una colección que crece puede volver la respuesta lenta o pesada. Criterio de revisión: si un endpoint sin `Take` supera de forma sostenida unos pocos miles de elementos por respuesta o su latencia p95 se degrada, se acota con una cota de rango (sección 7) o se obliga a paginar con `Take`, en un issue propio.
- **Sin total**: ninguna lista expone "página N de M" ni conteo; una necesidad de conteo exige un dato propio en la vista.
- **El cursor opaco oculta la clave**: depurar una paginación exige decodificar el cursor del lado del servidor; el cliente no puede saltar a una posición arbitraria.
- **Los endpoints preexistentes quedan con el contrato anterior** hasta que un issue propio los migre (sección 8): conviven dos formas de respuesta durante la transición.
- **QUERY es un método reciente (RFC de junio 2026, Proposed Standard)**: herramientas, proxies y middlewares de terceros pueden no reconocerlo todavía -- el marco asume el riesgo de adoptar un estándar en una etapa temprana de su ciclo de vida, mitigado por el soporte ya verificado en el stack propio (.NET, APIM, OpenAPI 3.2), pero sin garantía sobre herramientas fuera de ese stack.
- **Gates de producción sin resolver** (sección 6): ningún consumidor puede exponer un endpoint QUERY real hasta que el primer despliegue real verifique el front-end de App Service y el reenvío de APIM Consumption -- el punto de CORS lo cerró el issue #608 -- este ADR fija doctrina, no un camino de producción completo.
- **La paginación por cursor exige un campo monótono en el read model**: un `Listar{X}s` sobre una vista sin ningún campo naturalmente ordenable y único (p. ej. una vista donde el `Id` no es un `StreamKey` sino un campo de negocio no monótono, caso N2) necesita elegir o introducir un campo de ordenamiento estable -- costo que este ADR no dispensa.
- **El DTO de filtro es una superficie nueva a mantener por endpoint**: a diferencia de un GET con query string (sin tipo dedicado), cada `Listar{X}s` sobre QUERY declara su propio record de filtro -- consistente con el resto del estilo tipado del marco (MEF-ADR-0012), pero un archivo más que MEF-ADR-0035 no exigía para la vía GET.

## Referencias

- **[1]** RFC 10008, "The HTTP QUERY Method" -- J. Reschke, J. M. Snell, M. Bishop, IETF, junio 2026, Proposed Standard (verificado contra `rfc-editor.org/rfc/rfc10008.json`). Secciones citadas: 2 (`Content-Type` obligatorio, tabla de códigos de error 400/415/422/406), 2.1 (detalle de la tabla de errores), 2.7 (cache key debe incorporar el body), 2.8 (paginación respaldada en el formato de query, no en HTTP Range Requests), 4 (QUERY siempre dispara preflight CORS -- no es un método CORS-safelisted). https://www.rfc-editor.org/rfc/rfc10008.html
- **[2]** "ApiOperation" -- REST API reference de Azure API Management, campo `method`: *"A Valid HTTP Operation Method. Typical Http Methods like GET, PUT, POST but not limited by only them."* https://learn.microsoft.com/rest/api/apimanagement/current-ga/api-operation
- **[3]** OpenAPI Specification v3.2.0, "Path Item Object": campo `query` dedicado (*"A definition of a QUERY operation"*) y `additionalOperations` para métodos fuera del set fijo. https://spec.openapis.org/oas/v3.2.0
- **[4]** "Paging" -- Marten docs (martendb.io), verificado 2026-08-11: `Query<T>().ToPagedListAsync(pageNumber, pageSize)` (también síncrono `ToPagedList`), resultado con `TotalItemCount`/`PageCount`/`IsFirstPage`/`IsLastPage`/`HasNextPage`/`HasPreviousPage`; advertencia oficial *"won't perform well for large dataset with millions of records"* sobre la función ventana `count(*) OVER()` por defecto, con el parámetro `useCountQuery: true` como mitigación parcial (fuerza un `count(*)` separado); alternativa manual `Query<T>().Stats(out QueryStatistics stats).Where(...).Take(n)`. https://martendb.io/documents/querying/linq/paging.html
- **[5]** "HttpRequestJsonExtensions.ReadFromJsonAsync" -- doc oficial de ASP.NET Core (.NET 10, `Microsoft.AspNetCore.App.Ref` v10.0.0), verificada 2026-08-11: *"Read JSON from the request and deserialize to the specified type. If the request's content-type is not a known JSON type then an error will be thrown."* El chequeo previo que la propia API ofrece es `HasJsonContentType` (*"The new `HasJsonContentType` extension method can also check if a request has a JSON content type"*, release notes de ASP.NET Core). https://learn.microsoft.com/dotnet/api/microsoft.aspnetcore.http.httprequestjsonextensions.readfromjsonasync?view=aspnetcore-10.0
- **[6]** "Searching on String Fields" -- Marten docs (martendb.io), verificado 2026-08-11: los métodos string que el proveedor LINQ declara traducibles son `StartsWith`, `EndsWith`, `Contains`, `Equals`, `Regex.IsMatch` y la extensión `EqualsIgnoreCase` (más las variantes con `StringComparison.OrdinalIgnoreCase`); `CompareTo`, `string.Compare` y los operadores de orden sobre string no figuran en esa superficie -- base del cuarto punto NO VERIFICADO de la sección 6. https://martendb.io/documents/querying/linq/strings.html
- **[7]** "Pagination" -- Model Context Protocol, specification: cursor opaco que el cliente no debe interpretar ni persistir entre sesiones, y `nextCursor` ausente indica el fin de los resultados. https://modelcontextprotocol.io/specification/2025-06-18/server/utilities/pagination
- CA-ADR-0039 "Doctrina de consultas -- endpoints de lista y tools MCP" (Bitakora.ControlAsistencia, issue #877) y CA-ADR-0038 "Las llamadas internas de composición no paginan": origen de campo del sobre, el cursor opaco, `Take` opcional y la eliminación de offset.
- MEF-ADR-0006 (convenciones de nombramiento de Functions Azure): **enmendado por este ADR** -- `Listar{X}s` conserva nombre y ruta cuando cruza de GET a QUERY (sección 5).
- MEF-ADR-0018 (heurísticas de evolución y reuso, Rule of Three): criterio por el que offset no se mantiene como segunda vía (Alt 3).
- MEF-ADR-0043 (doctrina HTTP de comandos), sección 7: precedente del régimen "solo endpoints nuevos" que la sección 8 replica.
- MEF-ADR-0030 (esquema de identificación de ADRs): citas `CA-ADR-` del consumidor.
- MEF-ADR-0028 (estrategia de tenancy): la `QuerySession` de un endpoint QUERY se abre acotada al tenant del resolver, idéntico al patrón que ya fija MEF-ADR-0035 sección 5 para el GET.
- MEF-ADR-0032 (identidad y autenticación en el borde, WorkOS + APIM): fuente del patrón "catálogo NO VERIFICADO + gate empírico obligatorio" que la sección 6 de este ADR replica; su catálogo B1-B11 aloja además, en B3, la enumeración explícita de `<allowed-methods>` con `QUERY` que el issue #608 instaló en el gateway, y en B11 el verbo `QUERY /*` entre las operaciones wildcard del módulo `apim-function-api`.
- MEF-ADR-0035 (doctrina de proyección y query read-side): este ADR extiende su sección 3 (superficie de consulta) con paginación y filtros múltiples; no reabre el estilo de código ni la tabla de read APIs de ese ADR.
- MEF-ADR-0037 (identidad del stream y su representación string canónica): el patrón `400` con mensaje (`BadRequestObjectResult`) que la sección 3 de este ADR generaliza a `415`/`422` ya lo fija ese ADR para el parseo del id de ruta de un GET.
- MEF-ADR-0041 (forma propia de la vista read-side): esta doctrina no contradice su decisión 4 -- el GET/QUERY sigue sirviendo el record de `ReadModels` directamente; el DTO de filtro de la sección 3 de este ADR es un tipo de **request**, no de respuesta, y no reabre la excepción del DTO de respuesta que MEF-ADR-0041 ya acota bajo Rule of Three.
- `skills/projections/read-apis.md`: aloja el ejemplo canónico completo de un endpoint QUERY (sección 4 de este ADR).
- `skills/projections/naming.md`: reenmendado en paralelo a MEF-ADR-0006 (sección 5 de este ADR).
- Issue #1982 (enmienda de paginación, sobre y aplicabilidad); issue #587 (este ADR); issue #608 (consecuencias del verbo QUERY en el gateway APIM -- CORS, operación wildcard del verbo y gate empírico end-to-end; cerró el punto de CORS de la sección 6); issue #583 (receta del planner que captura paginación/filtros/cadencia en el handoff -- relacionado, no bloqueante).

## Control de cambios

- 2026-08-11: creación como `aceptado` (issue #587). Fija la frontera decidible GET vs QUERY (RFC 10008) para las Functions de query del marco -- GET para `Obtener{X}` y para `Listar{X}s` con filtros planos de igualdad en query string; QUERY para filtros estructurados (AND/OR, rangos, listas de valores) y paginación por cursor --, la doctrina de paginación (keyset/cursor como default sobre `QuerySession`, offset como excepción documentada bajo Rule of Three vía `ToPagedListAsync`/`Stats(out QueryStatistics)`), la doctrina de filtros múltiples (DTO tipado deserializado del body, `Content-Type: application/json` obligatorio, combinación AND por defecto, mapeo de los códigos 400/415/422/406 del RFC a `ObjectResult` con mensaje) y el naming (`Listar{X}s` conserva nombre y ruta al cruzar de GET a QUERY, enmienda de MEF-ADR-0006). Registra cuatro puntos NO VERIFICADO como gates empíricos obligatorios antes de producción real (front-end de App Service, APIM Consumption reenviando QUERY, CORS del gateway sin `QUERY` en `<allowed-methods>` y la traducción LINQ del predicado de cursor sobre un `Id` string), con el patrón de MEF-ADR-0032 sección 8. No decide nada del lado APIM/CORS -- ese fix vive en el issue de seguimiento que este ADR bloquea.
- 2026-08-11: enmendada (issue #608). El gate "CORS del gateway" de la sección 6 pasa a **RESUELTO**: la política global que genera el `apim-gateway-scaffolder` enumera `QUERY` en `<allowed-methods>` (enumeración explícita, nunca `*`) y las operaciones wildcard de APIM del módulo `apim-function-api` incluyen el verbo, así que el preflight de un SPA queda cubierto en toda instalación nueva; en un gateway provisionado antes del #608 el agente reporta el delta manual en vez de editarlo (aditividad). El gate "APIM Consumption reenviando QUERY end-to-end" sigue **NO VERIFICADO**, pero queda operacionalizado como ítem del checklist post-deploy del agente y de `/install-apim`/`/install-auth` (`QUERY` con token válido y `Content-Type: application/json` no debe responder `404`/`405` en el borde). La doctrina de este ADR (frontera GET/QUERY, paginación, filtros, naming) no cambia.
- 2026-10-08: enmendada (issue #1982). La sección 2 fija que toda lista pagina por keyset (incluidos los catálogos chicos), con `take` y `cursor` como parámetros planos en GET o campos del body en QUERY; `Take` es opcional (sin `Take` se devuelve todo lo que cumple el filtro; con `Take`, página acotada a 200); la respuesta es el sobre `{ elementos, siguienteCursor }` con cursor opaco, presente solo si hay más (se pide `Take + 1`); ninguna lista devuelve total; lista vacía es `200` con `elementos: []`. Se elimina la excepción de offset (`ToPagedListAsync`/`Stats`): sin total no hay página N de M. La sección 1 deja de exigir QUERY por usar cursor. Secciones nuevas: 7 (ventanas temporales con `desde`/`hasta`/`rangoRecortado`) y 8 (aplicabilidad: solo endpoints nuevos, régimen de MEF-ADR-0043 sección 7). Referencias suma la spec MCP "Pagination" y CA-ADR-0039 como origen de campo. El gate NO VERIFICADO de `CompareTo` sobre `Id` string se conserva. Origen: CA-ADR-0039 del consumidor Bitakora.ControlAsistencia.

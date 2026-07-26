# MEF-ADR-0035: Doctrina de proyección y query read-side

- **Fecha**: 2026-07-26
- **Estado**: aceptado
- **Aplica a**: doctrina de las recetas de proyección, el estilo de código y la superficie de consulta que el `planner` propone y que los futuros subagentes read-side generan. Es la **fuente** del futuro Skill `projections` (issue #364), de los agentes `projection-test-writer`/`projection-implementer` (issue #365) y `projections-scaffolder` (issue #367), de la receta del planner para `tipo:projection` (issue #366) y de su variante de Definition of Ready (issue #373) -- ninguno de esos artefactos existe todavía; este ADR fija la doctrina que consumirán. Cross-referencia MEF-ADR-0034 (worker de proyecciones: fija **dónde** corre el daemon y qué lifecycle es default; este ADR fija **cómo** se escribe cada proyección y **cómo** se consulta, explícitamente diferido por ese ADR en sus secciones 3 y 5), MEF-ADR-0018 (Rule of Three: justifica diferir la receta N3 y el time-travel), MEF-ADR-0012 (records sin invariantes → read models inmutables), MEF-ADR-0002/MEF-ADR-0016 (testing y naming de tests, aplican sin cambios a los tests de proyecciones), MEF-ADR-0015 (Live como default de rehidratación del aggregate de escritura -- la superficie de consulta (b1) de este ADR reutiliza el mismo mecanismo), MEF-ADR-0028 (`ITenantResolver`, base del patrón de seguridad) y MEF-ADR-0006 (naming de Functions -- la enmienda que fija el naming exacto de las Functions de query queda para el issue #363, fuera de alcance aquí).

## Contexto

Marten ofrece, hoy (versión pinneada `9.12.0`, MEF-ADR-0003), **5 recetas de proyección**, **3 ciclos de vida** y **2 estilos de código** para escribirlas, más varias APIs distintas para leer el resultado. Sin una doctrina única, cada consumidor -- y cada agente de IA que genere código para él -- elige una combinación distinta: un dominio podría escribir sus read models como clases mutables con proyecciones explícitas registradas por `Add<T>()`, otro como records inmutables con métodos convencionales registrados por `Snapshot<T>()`, un tercero podría exponer sus queries sobre `FetchLatest()` y otro sobre `Query<T>()` directo. Cada elección diverge silenciosamente y ninguna conversación de diseño arranca con un punto de partida compartido.

MEF-ADR-0034 (worker de proyecciones y read models) ya resolvió la mitad de este problema: fija **dónde** corre el daemon asíncrono (worker `.NET` de larga duración, Container App sin ingress) y **cuál** ciclo de vida es el canónico para toda proyección **materializada** (`Async` por defecto, `Inline` como excepción opt-in registrada en el write-side). Pero ese ADR delimitó explícitamente su alcance dos veces: su sección "Contexto" dice que la doctrina de uso de `Live` (hidratar un aggregate a demanda) "es alcance del ADR de doctrina read-side (issue #362), no de este documento"; su sección 5 dice que "el estilo de autoría de los read models y el diseño de las APIs de consulta sobre ellos son alcance del ADR de doctrina read-side (issue hermano #362)". Este ADR es ese documento: fija el **estilo de código** con el que se escribe cada proyección y la **superficie de consulta** (query APIs) con la que un endpoint HTTP GET la lee.

Relación con MEF-ADR-0015 (snapshots de Marten como excepción, no regla): ese ADR ya fija que el `AggregateRoot` del **write-side** rehidrata siempre en modo `Live` -- vía `AggregateStreamAsync`, reaplicando todos los eventos del stream --, sin snapshot salvo excepción justificada con tres criterios. Este ADR no reabre esa decisión: una de las tres superficies de consulta que fija abajo (sección 3, vía b1) es el **mismo mecanismo `Live`**, invocado ahora desde un endpoint de lectura en vez de desde un command handler. Es la misma receta aplicada al mismo tipo de dato (el aggregate), solo que del lado de query en vez del lado de escritura.

**No calcar Cosmos.ControlPlane.** A diferencia de MEF-ADR-0032 y MEF-ADR-0034 (que sí usan ese consumidor como referencia validada en producción), este ADR se funda **únicamente** en la documentación oficial de Marten -- el naming y las read APIs que ControlPlane haya elegido para su propio read-side son preliminares y no están verificados como el patrón correcto a copiar.

**Fuentes verificadas** (martendb.io, todas re-confirmadas contra la versión pinneada Marten `9.12.0` de MEF-ADR-0003 donde la doctrina depende de la versión): `events/projections/` (recetas y lifecycles), `events/projections/aggregate-projections.html` (estilo convencional, records inmutables), `events/projections/conventions` (fuente-generador y requisito `partial`), `events/projections/multi-stream-projections` (correlación entre streams), `events/projections/event-projections` (escape hatch), `events/projections/custom-aggregates` (nota de eliminación de recetas en 8.0), `events/projections/single-stream-projections` (APIs de registro), `events/projections/read-aggregates.html` (`FetchLatest` vs `Query`/`LoadAsync`/`AggregateStreamAsync`/`FetchStreamAsync`), `documents/sessions.html` (`QuerySession`) y `documents/multi-tenancy.html` (sesión por tenant). Además, GitHub `JasperFx/marten` issue #4557, que documenta empíricamente el requisito `partial` para tipos auto-agregantes en Marten 9 -- un detalle que la página oficial de ejemplos no deja claro por sí sola (ver sección 2).

## Decisión

### 1. Recetas en tres niveles, con árbol de decisión N1/N2 (CA-1)

De las 5 recetas que Marten documenta -- `SingleStreamProjection`, `MultiStreamProjection`, `EventProjection`, y las ya fusionadas `CustomAggregation`/`CustomProjection` --, el marco las agrupa en **tres niveles** de adopción:

| Nivel | Receta Marten | Cuándo aplica | ¿Auto-generada por el scaffolder? |
|---|---|---|---|
| **N1** | `SingleStreamProjection<T, TId>` (auto-agregante, `Snapshot<T>()`) | El read model solo necesita eventos de **un** stream -- el mismo `AggregateId` que ya identifica al aggregate de escritura. | **Sí** -- default del futuro `projections-scaffolder` (issue #367). |
| **N2** | `MultiStreamProjection<T, TId>` | El read model correlaciona eventos de **varios** streams -- múltiples instancias del mismo tipo de aggregate, o aggregates de tipos distintos. | Sí, cuando el árbol de decisión (abajo) lo indica -- requiere declarar explícitamente la correlación (`Identity`/`Identities`/`CustomGrouping`/`IEventSlicer`). |
| **N3** | `EventProjection` (operaciones de documento ad-hoc por evento) o un `IProjection` completamente custom | Ninguna de las anteriores encaja: se necesita control fino por evento, o lógica que no cabe en ningún patrón de agregación. | **No** -- escape hatch manual, nunca generado por defecto. Requiere justificación explícita en el issue, aplicando MEF-ADR-0018 (Rule of Three): sin evidencia de que N1/N2 no alcanzan, no se abre esta puerta. |

**Árbol de decisión (para el `planner` y el futuro `projections-scaffolder`):**

1. ¿El read model deriva únicamente de eventos de un solo stream (el mismo `AggregateId`)? → **N1**.
2. Si no: ¿correlaciona eventos de streams distintos, pero el mapeo de cada evento a su documento agregado es una proyección directa de un campo del evento (p. ej. `e => e.EquipoId`)? → **N2** con `Identity<TEvento>(...)`/`Identities<TEvento>(...)` [5].
3. Si la correlación **no** es una proyección directa de campo (necesita una consulta a base de datos, o agrupar por una regla que no es un campo del evento) → **N2** con `CustomGrouping`/`IEventSlicer` [5] -- sigue siendo N2, pero con la variante de correlación más compleja.
4. Si ni N1 ni N2 alcanzan (se necesitan operaciones de documento arbitrarias por evento, o lógica que ninguna agregación cubre) → **N3**, documentando en el issue por qué N1/N2 no sirven. Marten mismo advierte contra llegar aquí sin necesidad real: *"If you find yourself wanting this feature, maybe look to use one of the aggregation projection recipes instead that are heavily optimized for this use case"* [6].

**Nota de versión verificada:** las recetas `CustomAggregation` y `CustomProjection` (anteriores a Marten 8.0) fueron **eliminadas** en esa versión y fusionadas en "código explícito" dentro de `SingleStreamProjection`/`MultiStreamProjection`, o en un `IProjection` completamente custom [7]. Como el marco pinea Marten `9.12.0` (MEF-ADR-0003), el nivel N3 de este ADR agrupa `EventProjection` + `IProjection` custom -- no una "CustomAggregation" que ya no existe como tipo separado en la versión vigente.

### 2. Estilo canónico: record inmutable + métodos convencionales estáticos; `partial` obligatorio por el source generator (CA-2)

Marten soporta **2 estilos de código** para escribir una `SingleStreamProjection`/`MultiStreamProjection`: el **convencional** (métodos reconocidos por nombre -- `Create`, `Apply`, `ShouldDelete` -- descubiertos por el source generator en tiempo de compilación) y el **explícito** (override manual de `Evolve`/`EvolveAsync`/`DetermineAction`/`DetermineActionAsync`, o un `switch` sobre el tipo de evento). El marco fija el **convencional** como estilo canónico -- es el estilo "original" de Marten, el que menos código boilerplate exige, y el que un source generator puede verificar en tiempo de compilación (cobertura de ramas de evento) en vez de en runtime.

**Estilo canónico N1 (self-hosting, `Snapshot<T>()`):** el read model es un **record inmutable** (mismo criterio de MEF-ADR-0012: "si el objeto no tiene invariantes de construcción → `record`" -- un read model es una proyección de lectura, no protege invariantes de dominio) que declara sus propios métodos estáticos `Create`/`Apply`/`ShouldDelete`:

```csharp
public sealed partial record TurnoView(Guid Id, string Estado, DateOnly FechaInicio)
{
    public static TurnoView Create(TurnoCreado e) =>
        new(e.TurnoId, "Abierto", e.FechaInicio);

    public static TurnoView Apply(TurnoCerrado e, TurnoView view) =>
        view with { Estado = "Cerrado" };

    // ShouldDelete es opcional -- solo si el read model debe desaparecer ante algún evento
    public static bool ShouldDelete(TurnoAnulado e) => true;
}

// Registro en el named store del worker de proyecciones (MEF-ADR-0034 seccion 2),
// nunca en el write-side -- Async es el ciclo de vida canonico (MEF-ADR-0034 seccion 3):
opts.Projections.Snapshot<TurnoView>(SnapshotLifecycle.Async);
```

Verificado contra la documentación oficial [2][8]: el ejemplo canónico de Marten para este estilo (`QuestParty`) es exactamente esta forma -- un `record` con `Create`/`Apply` estáticos que retornan `party with { ... }` --, y `Projections.Snapshot<T>(SnapshotLifecycle.Async)` es la API de registro específica para tipos auto-agregantes (a diferencia de `Projections.Add<T>(...)`, reservada para una clase de proyección companion -- ver N2 abajo).

**El `partial` es obligatorio, y es un gotcha real, poco documentado.** Verificado contra la documentación oficial de convenciones [3]: *"To make changes to an existing aggregate, declare `Apply()` methods on a `partial` projection class. The `JasperFx.Events.SourceGenerator` discovers them at compile time and emits a `[GeneratedEvolver]` dispatcher with no runtime reflection."* El propio issue de GitHub del proyecto [4] confirma empíricamente que esto aplica **también** a tipos auto-agregantes (self-hosting, no solo a una clase de proyección companion separada): un consumidor que actualizó a Marten 9 sin marcar su tipo `partial` obtuvo el error *"No source-generated dispatcher found for Marten.Events.Aggregation.SingleStreamProjection<MyType, System.Guid>"* -- el mismo síntoma que aplicaría a `TurnoView` de este ADR si se omite `partial`. **Caveat de verificación**: el ejemplo oficial `QuestParty` que muestra la página de `aggregate-projections.html` [2] **no** declara `partial` -- posible desalineamiento entre esa página ilustrativa y el comportamiento real de la versión pinneada. El agente que implemente el primer read model real (`projection-implementer`, issue #365) debe reverificar esto empíricamente con un build antes de asumir que el ejemplo de este ADR compila tal cual -- mismo principio de re-verificación que MEF-ADR-0034 sección 6 exige para su propio config-test.

**Estilo canónico N2 (companion class, `Add<T>()`):** a diferencia de N1, la correlación entre streams (`Identity`/`Identities`/`CustomGrouping`) necesita un constructor -- Marten no soporta auto-agregación para `MultiStreamProjection`, así que el read model vive en una **clase companion** separada, marcada `partial` por la misma razón que N1:

```csharp
// El read model sigue siendo un record inmutable (mismo criterio que N1) --
// solo los datos, sin comportamiento de correlacion.
public sealed record ResumenEquipoView(Guid EquipoId, int TurnosCerrados);

public sealed partial class ResumenEquipoProjection : MultiStreamProjection<ResumenEquipoView, Guid>
{
    public ResumenEquipoProjection()
    {
        Identity<TurnoCreado>(e => e.EquipoId);
        Identity<TurnoCerrado>(e => e.EquipoId);
    }

    public static ResumenEquipoView Create(TurnoCreado e) => new(e.EquipoId, 0);

    public static ResumenEquipoView Apply(TurnoCerrado e, ResumenEquipoView view) =>
        view with { TurnosCerrados = view.TurnosCerrados + 1 };
}

opts.Projections.Add<ResumenEquipoProjection>(ProjectionLifecycle.Async);
```

**Nota de estilo deliberada**: el ejemplo oficial de Marten para `MultiStreamProjection` [5] usa una clase mutable con métodos de instancia (`view.Id = @event.UserId`). Marten soporta ambos estilos por igual -- *"Marten happily supports immutable data types for the aggregate documents produced by projections, but also happily supports mutable types as well"* [2] --; este ADR fija records inmutables también en N2 (la clase companion solo aloja la configuración de correlación y métodos `Apply`/`Create` que retornan `with { ... }`, igual que N1) para mantener un único criterio en todo el marco, consistente con MEF-ADR-0012.

### 3. Superficie de consulta: tres vías, todas expuestas por Function GET; time-travel diferido (CA-3)

Un endpoint de lectura del dominio (Azure Function HTTP GET en el Function App del **write-side** -- el worker de proyecciones de MEF-ADR-0034 no tiene ingress y no puede exponer HTTP) resuelve su dato de una de tres formas:

- **(a) Sobre una proyección materializada** (`Inline`/`Async`, MEF-ADR-0034 sección 3): consulta el documento que el daemon ya mantiene actualizado. Es la vía más barata -- no reaplica eventos en el momento de la consulta.
- **(b1) Hidratando el aggregate a demanda** (`Live`): reconstruye el estado actual reaplicando todos los eventos del stream, sin pasar por ninguna proyección persistida. Es el **mismo mecanismo** que MEF-ADR-0015 ya fija como default del `AggregateRoot` de escritura -- este ADR no introduce un segundo modelo de rehidratación, reutiliza el que ya existe.
- **(b2) Eventos crudos del stream**: para un consumidor que necesita el historial de eventos en sí (auditoría, debugging, un cliente que reconstruye su propia vista), sin que el marco le imponga ninguna forma agregada.

**Naming de las Functions de query queda fuera de alcance aquí** -- la enmienda de MEF-ADR-0006 que fija el patrón de nombre exacto de estas Functions GET es el issue #363, hermano de este.

**Time-travel queda explícitamente diferido.** Marten soporta parámetros `version`/`timestamp` en `AggregateStreamAsync` para reconstruir el aggregate en un punto del pasado [9], pero ningún caso de uso real del marco lo necesita hoy. Aplicando MEF-ADR-0018 (Rule of Three: "no extraer/adoptar sin evidencia de necesidad real"), este ADR **no** expone esa superficie en el scaffolding por defecto; queda documentada como capacidad existente de Marten, disponible el día que un issue concreto la justifique.

### 4. Tabla de read APIs canónicas -- todas sobre `QuerySession` (CA-4)

| Superficie | API canónica | Tipo de sesión |
|---|---|---|
| (a) Proyección materializada, por id | `session.LoadAsync<TView>(id)` | `QuerySession` |
| (a') Proyección materializada, por filtro/lista | `session.Query<TView>()` (LINQ) | `QuerySession` |
| (b1) Hidratar aggregate a demanda (`Live`) | `session.Events.AggregateStreamAsync<T>(id)` | `QuerySession` |
| (b2) Eventos crudos del stream | `session.Events.FetchStreamAsync(id)` | `QuerySession` |
| Opt-in documentado (no default) | `session.FetchLatest<T>(id)` | requiere `IDocumentSession` (p. ej. `LightweightSession`) -- **no disponible en `QuerySession`** |

`QuerySession` es la sesión de solo lectura de Marten -- *"For strictly read-only querying, the `QuerySession` is a lightweight session that is optimized for reading"* [10], sin identity map ni dirty checking. Las cuatro APIs canónicas de la tabla ((a), (a'), (b1), (b2)) están disponibles sobre ella -- `Events` es una propiedad tanto de `IQuerySession` como de `IDocumentSession` [1][9], así que ninguna de las cuatro exige una sesión de escritura.

**`FetchLatest` es opt-in, no default, por una razón concreta y verificada**: *"For internal reasons, the `FetchLatest()` API is only available off of `IDocumentSession` and not `IQuerySession`"* [9]. Adoptarlo para un endpoint de lectura significa abrir una sesión de **escritura** (`LightweightSession`) solo para leer -- el mismo tipo de excepción-opt-in que MEF-ADR-0034 ya aplica a `Inline` frente a `Async`: útil cuando se necesita el comportamiento adaptativo de `FetchLatest` por ciclo de vida (`Live` → `AggregateStreamAsync`; `Inline` → documento persistido; `Async` → snapshot + eventos no aplicados en memoria [9]), pero no el camino feliz por defecto de este ADR.

**Punto abierto para el implementador (issues #365/#367/#375): la sesión de query del Function App del write-side y el schema del worker.** MEF-ADR-0034 sección 2 fija que el named store del worker de proyecciones "solo re-declara, del lado lectura, la conexión y el schema que el dominio ya posee del lado escritura" -- el mismo Postgres, el mismo schema. Este ADR fija que el endpoint GET vive en el Function App del **write-side** (no en el worker, que no tiene ingress) y abre su `QuerySession` desde el `IDocumentStore` **ya configurado** en ese Function App (`ComposicionServicios{Dominio}.cs`, MEF-ADR-0029) -- no desde el named store del worker, que vive en un proceso distinto e inalcanzable desde ahí. Si ese `DocumentStore` del write-side necesita algún registro adicional del tipo de documento (`TView`) para poder resolverlo vía `Query<TView>()`/`LoadAsync<TView>()` -- dado que la proyección en sí (sección 3 de MEF-ADR-0034) solo se registra en el named store del worker, nunca en el write-side --, es un detalle de la superficie exacta de `StoreOptions` de la versión vigente de Marten que el agente implementador debe reverificar empíricamente antes de generar el primer read model real. Este ADR fija el contrato de la API de lectura (tabla arriba); no resuelve ese detalle de configuración cruzada entre dos procesos sobre el mismo schema físico.

### 5. Patrón de seguridad: sesión acotada al tenant resuelto, nunca al id de la ruta (CA-5)

Toda `QuerySession` de un endpoint de lectura se abre **acotada al tenant que resolvió `ITenantResolver`** (MEF-ADR-0028) -- **nunca** a un tenant id que llegue en la ruta, el query string o el body de la request:

```csharp
// CORRECTO: el tenant viene del resolver, no de la request
var tenantId = tenantResolver.Resolver(); // MEF-ADR-0028
await using var session = store.QuerySession(tenantId);
var turno = await session.LoadAsync<TurnoView>(turnoId); // turnoId SI viene de la ruta -- es el recurso, no el tenant

// INCORRECTO: confiar en un tenant id que el cliente puede falsificar
await using var session = store.QuerySession(request.Query["tenantId"]); // BOLA/IDOR
```

Esto no es un detalle de conveniencia: es la mitigación estructural del marco contra **BOLA/IDOR** (Broken Object Level Authorization / Insecure Direct Object Reference) en el read-side. Marten implementa el aislamiento multi-tenant filtrando por una columna `tenant_id` a nivel de sesión [11] -- `store.QuerySession(tenantId)` -- pero **no lo garantiza a nivel de acceso a base de datos**: *"Marten does not guarantee or enforce data isolation via database access privileges"* [11]. La responsabilidad de abrir la sesión con el tenant **correcto** es enteramente del código de la aplicación; un endpoint que confía en un tenant id que el cliente puede enviar (en vez de uno que el propio servidor resolvió vía `ITenantResolver`, MEF-ADR-0028) rompe el aislamiento aunque Marten esté configurado correctamente. El id que sí viaja en la ruta (`turnoId` en el ejemplo) es el identificador del **recurso** dentro de ese tenant -- eso es lo que un GET normalmente parametriza --, nunca el tenant en sí.

### 6. Qué NO fija este ADR

- **Naming exacto de las Functions de query** (verbo, patrón de nombre) -- MEF-ADR-0006, enmienda del issue #363.
- **El Skill `projections`** que empaqueta esta doctrina para el `planner` -- issue #364.
- **Los agentes `projection-test-writer`/`projection-implementer`** que generan el código siguiendo este estilo -- issue #365.
- **La receta del `planner` para `tipo:projection`** y su variante de Definition of Ready -- issues #366/#373.
- **El agente `projections-scaffolder`** y el skill `/scaffold-projections` -- issue #367.
- **La clasificación de las Functions GET frente al coverage gate** (MEF-ADR-0014) -- issue #371, hermano del carve-out que MEF-ADR-0034 sección 9 ya dejó fuera de su propio alcance.

## Alternativas consideradas

### Alt 1: adoptar las 5 recetas de Marten como opciones igualmente válidas, sin agrupar en niveles

**Descartada**: es precisamente el problema que motiva este ADR -- sin una jerarquía de "cuándo usar cada una", cada agente/consumidor elige distinto y la decisión se relitiga en cada issue. Agrupar en 3 niveles con un árbol de decisión (sección 1) convierte una elección abierta entre 5 recetas en un checklist de 2-3 preguntas.

### Alt 2: estilo explícito (switch-based / override de `Evolve`) como estilo canónico

**Descartada**: el estilo explícito exige más código boilerplate por cada tipo de evento y pierde la verificación en tiempo de compilación que el source generator aplica sobre el estilo convencional (dispatcher generado, `[GeneratedEvolver]` [3]) a cambio de mayor flexibilidad que el marco no necesita en el caso general -- el estilo convencional ya es, según la propia documentación de Marten, el "original" pensado para el caso común [2].

### Alt 3: `FetchLatest` como API canónica por defecto para toda lectura

**Descartada** (sección 4): exige abrir una sesión de **escritura** (`IDocumentSession`) para cualquier consulta, ensanchando innecesariamente la superficie de una operación que solo necesita leer -- rompe la disciplina de `QuerySession` de solo lectura que este ADR fija como default. Queda como excepción opt-in, documentada, para el caso concreto donde su comportamiento adaptativo por ciclo de vida se necesite.

### Alt 4: exponer time-travel (`AggregateStreamAsync` con `version`/`timestamp`) desde el día 1

**Descartada** (sección 3, MEF-ADR-0018): ningún issue real del marco lo necesita hoy. Documentar/exponer esa superficie sin un caso concreto es especular sobre un requisito que no existe -- la Rule of Three aplica igual a superficie de API que a código.

## Consecuencias

### Positivas

- **Un solo estilo de código conocido por el `planner` y los futuros agentes read-side**: elimina la discusión de diseño "¿record o clase? ¿convencional o explícito?" en cada issue nuevo.
- **Tres niveles con árbol de decisión** reducen la elección entre 5 recetas a un checklist corto, replicando el mismo alivio cognitivo que MEF-ADR-0012 ya logró para objetos de dominio del write-side.
- **Seguridad por diseño**: el patrón "sesión acotada al tenant resuelto, nunca al id de la ruta" (sección 5) es estructural -- todo agente que genere un endpoint de lectura sigue el mismo patrón, en vez de que cada dominio reinvente (o se olvide de) su propia mitigación de BOLA/IDOR.
- **Consistencia con MEF-ADR-0015**: la superficie (b1) reutiliza exactamente el mismo mecanismo `Live` que ya rige la rehidratación del aggregate de escritura -- no se introduce un tercer modelo de "cómo se reconstruye un aggregate desde eventos" en el marco.
- **N3 deliberadamente sin scaffold automático** evita generar código "por si acaso" para el caso menos común -- mismo principio de costo cero hasta que se demuestre necesidad que MEF-ADR-0015 ya aplica a los snapshots del write-side.

### Negativas

- **El requisito `partial` del estilo convencional es un gotcha de compilador poco documentado**: el propio ejemplo oficial de Marten (`QuestParty`) no lo muestra, y solo queda claro combinando la página de convenciones con un issue de GitHub del proyecto (sección 2). Un agente que generé el primer read model real sin reverificarlo empíricamente puede producir código que no compila.
- **N3 (escape hatch) exige más fricción manual** que N1/N2 cuando de verdad se necesita -- trade-off aceptado explícitamente por MEF-ADR-0018: preferible pagar esa fricción puntual a automatizar un camino que casi nunca se usa.
- **`FetchLatest` y el time-travel quedan fuera del camino feliz**: un consumidor que los necesite deberá justificarlos explícitamente y salirse del scaffolding por defecto, en vez de tenerlos disponibles de entrada.
- **El cruce de configuración entre el Function App del write-side (que abre la `QuerySession`) y el named store del worker (que materializa la proyección, en otro proceso, MEF-ADR-0034) queda como punto abierto** (sección 4) -- el agente implementador deberá resolverlo empíricamente contra la superficie exacta de `StoreOptions` de la versión vigente de Marten antes del primer read model real.

## Referencias

- **[1]** "Projections" -- Marten docs: las 5 recetas (`SingleStreamProjection`, `MultiStreamProjection`, `EventProjection`, `CustomAggregation`/`CustomProjection`) y los 3 ciclos de vida (`Live`, `Inline`, `Async`), y que `Events` es una propiedad común de sesión. https://martendb.io/events/projections/
- **[2]** "Aggregate Projections" -- Marten docs: estilo convencional vs explícito, ejemplo `QuestParty` (record inmutable + `Create`/`Apply` estáticos con `with {}`), y *"Marten happily supports immutable data types for the aggregate documents produced by projections, but also happily supports mutable types as well"*. https://martendb.io/events/projections/aggregate-projections.html
- **[3]** "Aggregation with Conventional Methods" -- Marten docs: *"To make changes to an existing aggregate, declare `Apply()` methods on a `partial` projection class. The `JasperFx.Events.SourceGenerator` discovers them at compile time and emits a `[GeneratedEvolver]` dispatcher with no runtime reflection."* Ejemplo `TripProjection: SingleStreamProjection<Trip, Guid>`. https://martendb.io/events/projections/conventions
- **[4]** `JasperFx/marten` issue #4557 -- *"No source-generated dispatcher found for Marten.Events.Aggregation.SingleStreamProjection<MyType, System.Guid>"*: confirma empíricamente que el requisito `partial` de [3] aplica también a tipos auto-agregantes (self-hosting), no solo a una clase de proyección companion; alternativa documentada: override manual de `Evolve`/`EvolveAsync`/`DetermineAction`/`DetermineActionAsync`. https://github.com/JasperFx/marten/issues/4557
- **[5]** "Multi-Stream Projections" -- Marten docs: `Identity<TEvento>(...)`/`Identities<TEvento>(...)` (mapeo directo de campo), `CustomGrouping`/`IEventSlicer` (correlación no trivial), y que las `MultiStreamProjection` se registran async por defecto. https://martendb.io/events/projections/multi-stream-projections
- **[6]** "Event Projections" -- Marten docs: `EventProjection`, operaciones de documento ad-hoc por evento, y la advertencia *"If you find yourself wanting this feature, maybe look to use one of the aggregation projection recipes instead that are heavily optimized for this use case"*. https://martendb.io/events/projections/event-projections
- **[7]** "Custom Aggregations" (nota de eliminación) -- Marten docs: *"The < 8.0 `CustomProjection` was eliminated in Marten 8.0 and replaced with the explicit code option"* dentro de `SingleStreamProjection`/`MultiStreamProjection`. https://martendb.io/events/projections/custom-aggregates
- **[8]** "Single Stream Projections and Snapshots" -- Marten docs: `Projections.Snapshot<T>(SnapshotLifecycle...)` (self-hosting) vs `Projections.Add<T>(ProjectionLifecycle...)` (clase de proyección companion) vs `Projections.LiveStreamAggregation<T>()`. https://martendb.io/events/projections/single-stream-projections
- **[9]** "Reading Aggregates" -- Marten docs: `FetchLatest<T>()` adapta su comportamiento por lifecycle (`Live` → `AggregateStreamAsync`; `Inline` → documento persistido; `Async` → snapshot + eventos no aplicados en memoria); *"For internal reasons, the `FetchLatest()` API is only available off of `IDocumentSession` and not `IQuerySession`"*; `AggregateStreamAsync`/`FetchStreamAsync` sobre `IQuerySession.Events`, con parámetros `version`/`timestamp` para time-travel. https://martendb.io/events/projections/read-aggregates.html
- **[10]** "Managing Sessions" -- Marten docs: *"For strictly read-only querying, the `QuerySession` is a lightweight session that is optimized for reading"* -- sin identity map ni dirty checking. https://martendb.io/documents/sessions.html
- **[11]** "Multi-Tenancy" -- Marten docs: `store.QuerySession(tenantId)`/`store.LightweightSession(tenantId)`, tenancy "conjoined" vía columna `tenant_id`, y *"Marten does not guarantee or enforce data isolation via database access privileges"*. https://martendb.io/documents/multi-tenancy.html
- MEF-ADR-0003 (stack ES Marten+Wolverine): fija la versión pinneada `9.12.0` de Marten contra la que se verificó el requisito `partial` de la sección 2.
- MEF-ADR-0006 (naming de Functions Azure): el naming exacto de las Functions de query queda para su enmienda, issue #363 -- fuera de alcance de este ADR.
- MEF-ADR-0012 (heurísticas de modelado de objetos de dominio): origen del criterio "record sin invariantes" que este ADR aplica a los read models (secciones 2).
- MEF-ADR-0015 (snapshots de Marten como excepción): la superficie (b1) de este ADR (sección 3/4) reutiliza el mismo mecanismo `Live` que ese ADR ya fija como default de rehidratación del aggregate de escritura.
- MEF-ADR-0018 (heurísticas de evolución y reuso -- Rule of Three): justifica diferir la receta N3 (sección 1) y el time-travel (sección 3).
- MEF-ADR-0028 (estrategia de tenancy): origen de `ITenantResolver`, base del patrón de seguridad de la sección 5.
- MEF-ADR-0034 (worker de proyecciones y read models): fija dónde corre el daemon y el ciclo de vida canónico (`Async`); este ADR es su hermano explícito de doctrina read-side, referenciado en sus secciones "Contexto" y 5.
- Issue #362 (este ADR) y sus issues consumidores directos: #363 (enmienda de naming MEF-ADR-0006), #364 (Skill `projections`), #365 (agentes `projection-test-writer`/`projection-implementer`), #366 (receta del planner para `tipo:projection`), #367 (skill `/scaffold-projections` y agente `projections-scaffolder`), #371 (carve-out de coverage del endpoint GET), #373 (label `tipo:projection` y su variante de DoR).

## Control de cambios

- 2026-07-26: creación como `aceptado` (issue #362). Fija las recetas de proyección en 3 niveles con árbol de decisión (N1 `SingleStreamProjection` auto-generada, N2 `MultiStreamProjection` con árbol, N3 `EventProjection`/`IProjection` custom como escape hatch no auto-generado), el estilo canónico (record inmutable + métodos convencionales estáticos `Create`/`Apply`/`ShouldDelete`, con la nota verificada del `partial` obligatorio por el source generator de Marten 9), la superficie de consulta (proyección materializada, aggregate en vivo, eventos crudos -- todas sobre `QuerySession`, con `FetchLatest`/`LightweightSession` como excepción opt-in documentada, y time-travel diferido por Rule of Three), y el patrón de seguridad (sesión acotada al tenant resuelto por `ITenantResolver`, nunca al id de la ruta, previniendo BOLA/IDOR). Deja un punto abierto explícito para el implementador (issues #365/#367/#375): el detalle de configuración exacto que permite al `QuerySession` del Function App del write-side resolver el tipo de documento que el named store del worker de proyecciones materializa en otro proceso (MEF-ADR-0034).

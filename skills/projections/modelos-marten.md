# Modelos de proyeccion Marten: arbol N1/N2/N3

Fuente: MEF-ADR-0035 secciones 1-2. Version pinneada: Marten `9.12.0` (MEF-ADR-0003).

## Arbol de decision

1. El read model deriva unicamente de eventos de **un solo stream** (el mismo `AggregateId` del aggregate de escritura)? -> **N1**.
2. Si no: correlaciona eventos de streams distintos, pero el mapeo de cada evento a su documento agregado es una proyeccion directa de un campo del evento (p. ej. `e => e.EquipoId`)? -> **N2** con `Identity<TEvento>(...)`/`Identities<TEvento>(...)`.
3. Si la correlacion **no** es una proyeccion directa de campo (necesita una consulta a base de datos, o agrupar por una regla que no es un campo del evento) -> **N2** con `CustomGrouping`/`IEventSlicer` -- sigue siendo N2, variante mas compleja.
4. Si ni N1 ni N2 alcanzan (operaciones de documento arbitrarias por evento, o logica que ninguna agregacion cubre) -> **N3**, documentando en el issue por que N1/N2 no sirven (Rule of Three, MEF-ADR-0018). Marten mismo advierte: *"If you find yourself wanting this feature, maybe look to use one of the aggregation projection recipes instead that are heavily optimized for this use case"*.

**Nota de version**: `CustomAggregation`/`CustomProjection` (anteriores a Marten 8.0) fueron **eliminadas** en 8.0 y fusionadas en codigo explicito dentro de `SingleStreamProjection`/`MultiStreamProjection`, o en un `IProjection` completamente custom. En la version pinneada, N3 agrupa `EventProjection` + `IProjection` custom -- no una "CustomAggregation" que ya no existe como tipo separado.

## Estilo canonico unico N1+N2 -- clase de proyeccion companion `partial`, `Add<T>()`

El read model es un **record inmutable plano** (mismo criterio de MEF-ADR-0012: sin invariantes de construccion -> `record`), **sin** `partial` ni metodos propios -- vive en `<RootNamespace>.ReadModels` (MEF-ADR-0034 seccion 5), biblioteca que no referencia Marten ni transitivamente. El comportamiento de proyeccion vive en una **clase companion separada**, `partial`, que declara los metodos estaticos `Create`/`Apply`/`ShouldDelete`, descubiertos por nombre por el source generator (estilo **convencional**, canonico del marco frente al estilo explicito por `Evolve`/`switch`) -- y que vive en el **worker** (`<RootNamespace>.Projections`, MEF-ADR-0034 seccion 5), el ensamblado que si referencia Marten y el analizador `JasperFx.Events.SourceGenerator`.

## N1 -- un solo stream

```csharp
// Read model: record plano, sin comportamiento ni partial. Vive en <RootNamespace>.ReadModels.
public sealed record TurnoView(Guid Id, string Estado, DateOnly FechaInicio);

// Clase de proyeccion: vive en el worker (<RootNamespace>.Projections) -- el ensamblado
// que si referencia Marten y el analizador JasperFx.Events.SourceGenerator.
public sealed partial class TurnoProjection : SingleStreamProjection<TurnoView, Guid>
{
    public static TurnoView Create(TurnoCreado e) =>
        new(e.TurnoId, "Abierto", e.FechaInicio);

    public static TurnoView Apply(TurnoCerrado e, TurnoView view) =>
        view with { Estado = "Cerrado" };

    // ShouldDelete es opcional -- solo si el read model debe desaparecer ante algun evento
    public static bool ShouldDelete(TurnoAnulado e) => true;
}

// Registro en el named store del worker de proyecciones (MEF-ADR-0034 seccion 2),
// nunca en el write-side -- Async es el ciclo de vida canonico (MEF-ADR-0034 seccion 3):
opts.Projections.Add<TurnoProjection>(ProjectionLifecycle.Async);
```

**Por que N1 deja de ser auto-agregante.** El estilo anterior fijaba, para N1, un record self-hosting que declaraba sus propios `Create`/`Apply` y se registraba con `Snapshot<T>()`. Es la consecuencia forzosa de que `<RootNamespace>.ReadModels` no lleve Marten, ni transitivamente (MEF-ADR-0034 seccion 5): mover el record al worker no es opcion -- el Function App del dominio lo necesita para el GET (`session.LoadAsync<TView>()`) --, asi que el comportamiento de proyeccion se traslada a la clase companion y el record se queda como dato puro. Beneficio colateral: **un solo estilo** de N1 y N2 en el marco, en vez de dos.

## N2 -- correlacion entre streams

Marten no soporta auto-agregacion para `MultiStreamProjection`: la correlacion entre streams necesita un constructor, asi que la clase companion tambien declara la correlacion. Mismo estilo que N1 -- el read model sigue siendo un record inmutable plano, solo los datos, sin comportamiento de correlacion:

```csharp
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

**Nota de estilo deliberada**: el ejemplo oficial de Marten para `MultiStreamProjection` usa una clase mutable con metodos de instancia. Marten soporta ambos estilos por igual, pero el marco fija records inmutables tambien en N2 (la clase companion solo aloja la configuracion de correlacion y metodos `Apply`/`Create` que retornan `with { ... }`) para mantener un unico criterio, consistente con MEF-ADR-0012.

## El `partial` es obligatorio -- gotcha real, poco documentado

Verificado contra la documentacion oficial de convenciones de Marten: *"To make changes to an existing aggregate, declare `Apply()` methods on a `partial` projection class. The `JasperFx.Events.SourceGenerator` discovers them at compile time and emits a `[GeneratedEvolver]` dispatcher with no runtime reflection."* El requisito aplica a la **subclase de proyeccion** con metodos convencionales (`{Concepto}Projection`, arriba) -- **no** al record de read model, que ahora es siempre un dato plano sin `partial` en ambos niveles. Confirmado empiricamente por el issue `JasperFx/marten` #4557: una subclase sin `partial` produce en runtime *"No source-generated dispatcher found for Marten.Events.Aggregation.SingleStreamProjection<MyType, System.Guid>"*.

**El `partial` no alcanza solo**: el mensaje de error completo fija **dos** condiciones -- *"the projection class must be declared `partial` in an assembly that references the JasperFx.Events.SourceGenerator analyzer, or alternatively override Evolve / EvolveAsync / DetermineAction / DetermineActionAsync directly"*. El ensamblado que debe arrastrar ese analizador es el **worker** (`<RootNamespace>.Projections`, MEF-ADR-0034 seccion 5) -- donde vive la clase de proyeccion `partial` --, no `<RootNamespace>.ReadModels`, que no aloja ningun tipo `partial` y por eso no necesita el analizador. Un `partial` correcto en un ensamblado sin analizador falla en **runtime**, no en build.

**Caveat resuelto**: el ejemplo oficial `QuestParty` de la documentacion de Marten **no** declara `partial` porque es un tipo auto-agregante (`Snapshot<T>`/`SingleStreamProjection<T>`/`AggregateStream<T>`), no una clase de proyeccion companion con metodos convencionales -- el requisito nunca le aplico, y no hay ningun desalineamiento entre esa pagina ilustrativa y el comportamiento real de la version pinneada. Verificado en campo por el consumidor de referencia (Cosmos.ControlPlane, Marten `9.12.0`, SDK .NET 10): al remover el `partial` de una clase companion, Marten distingue explicitamente los dos casos en su mensaje de error -- *"A self-aggregating type registered via `Snapshot<T>` / `SingleStreamProjection<T>` / `AggregateStream<T>` does NOT need to be 'partial'; a projection subclass that uses convention methods DOES need to be declared 'partial'"*. Ese mismo mensaje nombra ademas el ensamblado del **documento** (*"Ensure that analyzer runs in the assembly that defines ...View"*), no el de la clase de proyeccion -- con el layout de este Skill (companion en el worker, record en `ReadModels`) ese mensaje es enganoso: seguir su indicacion literal llevaria a agregar Marten a `ReadModels`, exactamente la inversion que MEF-ADR-0034 seccion 5 evita. Lo que el analizador necesita es el ensamblado de la clase `partial`, no el del tipo que produce.

**No confundir los dos `partial` del read-side**: este es el `partial` de la *clase de proyeccion* (habilita el source generator de Marten). El "guarda del `partial`" de [config-test.md](config-test.md) es otro -- el *metodo* `partial` del seam de composicion `ConfiguracionMartenProjections{Dominio}`, que puede desaparecer en silencio si nadie lo implementa. Son requisitos independientes y ambos aplican.

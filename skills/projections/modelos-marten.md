# Modelos de proyeccion Marten: arbol N1/N2/N3

Fuente: MEF-ADR-0035 secciones 1-2. Version pinneada: Marten `9.12.0` (MEF-ADR-0003).

## Arbol de decision

1. El read model deriva unicamente de eventos de **un solo stream** (el mismo `AggregateId` del aggregate de escritura)? -> **N1**.
2. Si no: correlaciona eventos de streams distintos, pero el mapeo de cada evento a su documento agregado es una proyeccion directa de un campo del evento (p. ej. `e => e.EquipoId`)? -> **N2** con `Identity<TEvento>(...)`/`Identities<TEvento>(...)`.
3. Si la correlacion **no** es una proyeccion directa de campo (necesita una consulta a base de datos, o agrupar por una regla que no es un campo del evento) -> **N2** con `CustomGrouping`/`IEventSlicer` -- sigue siendo N2, variante mas compleja.
4. Si ni N1 ni N2 alcanzan (operaciones de documento arbitrarias por evento, o logica que ninguna agregacion cubre) -> **N3**, documentando en el issue por que N1/N2 no sirven (Rule of Three, MEF-ADR-0018). Marten mismo advierte: *"If you find yourself wanting this feature, maybe look to use one of the aggregation projection recipes instead that are heavily optimized for this use case"*.

**Nota de version**: `CustomAggregation`/`CustomProjection` (anteriores a Marten 8.0) fueron **eliminadas** en 8.0 y fusionadas en codigo explicito dentro de `SingleStreamProjection`/`MultiStreamProjection`, o en un `IProjection` completamente custom. En la version pinneada, N3 agrupa `EventProjection` + `IProjection` custom -- no una "CustomAggregation" que ya no existe como tipo separado.

## N1 -- self-hosting, `Snapshot<T>()`

El read model es un **record inmutable** (mismo criterio de MEF-ADR-0012: sin invariantes de construccion -> `record`) que declara sus propios metodos estaticos `Create`/`Apply`/`ShouldDelete`, descubiertos por nombre por el source generator (estilo **convencional**, canonico del marco frente al estilo explicito por `Evolve`/`switch`):

```csharp
public sealed partial record TurnoView(Guid Id, string Estado, DateOnly FechaInicio)
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
opts.Projections.Snapshot<TurnoView>(SnapshotLifecycle.Async);
```

## N2 -- companion class, `Add<T>()`

Marten no soporta auto-agregacion para `MultiStreamProjection`: la correlacion entre streams necesita un constructor, asi que el read model vive en una **clase companion** separada, `partial` por la misma razon que N1. El read model sigue siendo un record inmutable -- solo los datos, sin comportamiento de correlacion:

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

Verificado contra la documentacion oficial de convenciones de Marten: *"To make changes to an existing aggregate, declare `Apply()` methods on a `partial` projection class. The `JasperFx.Events.SourceGenerator` discovers them at compile time and emits a `[GeneratedEvolver]` dispatcher with no runtime reflection."* Esto aplica **tambien** a tipos auto-agregantes (N1, self-hosting), confirmado empiricamente por el issue `JasperFx/marten` #4557: un tipo sin `partial` produce en runtime *"No source-generated dispatcher found for Marten.Events.Aggregation.SingleStreamProjection<MyType, System.Guid>"*.

**El `partial` no alcanza solo**: el mensaje de error completo fija **dos** condiciones -- *"the projection class must be declared `partial` in an assembly that references the JasperFx.Events.SourceGenerator analyzer, or alternatively override Evolve / EvolveAsync / DetermineAction / DetermineActionAsync directly"*. El `.csproj` de `<RootNamespace>.ReadModels` (MEF-ADR-0034 seccion 5) es el que debe arrastrar ese analizador -- un `partial` correcto en un ensamblado sin analizador falla en **runtime**, no en build.

**Caveat de verificacion**: el ejemplo oficial `QuestParty` de la documentacion de Marten **no** declara `partial` -- posible desalineamiento entre esa pagina ilustrativa y el comportamiento real de la version pinneada. El agente que implemente el primer read model real debe reverificar esto empiricamente con un build antes de asumir que un ejemplo de este Skill compila tal cual.

**No confundir los dos `partial` del read-side**: este es el `partial` de la *clase de proyeccion/read model* (habilita el source generator de Marten). El "guarda del `partial`" de [config-test.md](config-test.md) es otro -- el *metodo* `partial` del seam de composicion `ConfiguracionMartenProjections{Dominio}`, que puede desaparecer en silencio si nadie lo implementa. Son requisitos independientes y ambos aplican.

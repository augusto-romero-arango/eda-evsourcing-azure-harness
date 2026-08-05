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

## Namespaces verificados de las clases base -- gotcha de `using`

| Tipo | Namespace | Assembly |
|---|---|---|
| `SingleStreamProjection<,>` | `Marten.Events.Aggregation` | `Marten` |
| `MultiStreamProjection<,>` | `Marten.Events.Projections` | `Marten` |
| `ProjectionLifecycle` | `JasperFx.Events.Projections` | `JasperFx.Events` |
| `IEvent` / `IEvent<TEvento>` | `JasperFx.Events` | `JasperFx.Events` |

Los tres primeros, verificados por reflexion propia (Marten `9.12.0`, SDK .NET 10.0.201, issue #495): `typeof(Marten.Events.Aggregation.SingleStreamProjection<,>).Namespace` y equivalentes (MEF-ADR-0035 ref. [19]); `IEvent`, contra el codigo fuente del paquete (MEF-ADR-0035 ref. [16]). Esta tabla cubre **todos** los `using` de los ejemplos N1/N2 de abajo -- si un ejemplo necesita un simbolo que no esta aqui, resuelve su namespace verificando, no por analogia.

**`ProjectionLifecycle` no vive bajo `Marten.*`** -- es otra instancia de la regla generica que MEF-ADR-0034 seccion 6 ya fija para `DaemonMode`/`StreamIdentity`/`TenancyStyle` (tambien aplicada por `agents/reviewer.md`, "Proyecciones y read-side"): ningun enum de esta superficie vive en `Marten.*`. Ver esa seccion para la regla completa y el modo de falla `CS0103`; no se repite aqui.

**Matiz que esa regla no cubre**: `SingleStreamProjection<,>` y `MultiStreamProjection<,>` si estan bajo `Marten.*` -- pero en **subnamespaces distintos entre si** (`Aggregation` vs `Projections`). Nadie adivina cual receta esta en cual subnamespace: ese `using` tambien se resuelve verificando (`Console.WriteLine(typeof(...).Namespace)` o `strings -a Marten.dll | grep -x "<namespace>"`), nunca por analogia entre las dos clases.

## N1 -- un solo stream

```csharp
using JasperFx.Events;             // IEvent<T>
using JasperFx.Events.Projections; // ProjectionLifecycle
using Marten.Events.Aggregation;   // SingleStreamProjection<,>

// Read model: record plano, sin comportamiento ni partial. Vive en <RootNamespace>.ReadModels.
// Id es string, no Guid: el store del dominio fija StreamIdentity.AsString (MEF-ADR-0034 ref. [19]),
// y en N1 la identidad del documento ES la del stream de origen -- ambas deben coincidir.
public sealed record TurnoView(string Id, string Estado, DateOnly FechaInicio);

// Clase de proyeccion: vive en el worker (<RootNamespace>.Projections) -- el ensamblado
// que si referencia Marten y el analizador JasperFx.Events.SourceGenerator.
public sealed partial class TurnoProjection : SingleStreamProjection<TurnoView, string>
{
    // Create toma IEvent<TurnoCreado>, no TurnoCreado a secas: la identidad (un string) no viaja
    // en el payload del evento -- IEvent<T>.StreamKey es quien la expone.
    public static TurnoView Create(IEvent<TurnoCreado> e) =>
        new(e.StreamKey!, "Abierto", e.Data.FechaInicio);

    public static TurnoView Apply(TurnoCerrado e, TurnoView view) =>
        view with { Estado = "Cerrado" };

    // ShouldDelete es opcional -- solo si el read model debe desaparecer ante algun evento
    public static bool ShouldDelete(TurnoAnulado e) => true;
}

// Registro en el named store del worker de proyecciones (MEF-ADR-0034 seccion 2),
// nunca en el write-side -- Async es el ciclo de vida canonico (MEF-ADR-0034 seccion 3):
opts.Projections.Add<TurnoProjection>(ProjectionLifecycle.Async);
```

**Si el `TId` no coincide con el `StreamIdentity` del store la falla es ruidosa, pero tardia**: declarar `SingleStreamProjection<TurnoView, Guid>` sobre un store `AsString` lanza `InvalidProjectionException: Id type mismatch...` al **resolver el named store** del contenedor, nunca en build (MEF-ADR-0035 seccion 2) -- la guarda 1 del config-test ([config-test.md](config-test.md)) es lo unico que la caza antes del primer despliegue.

**Por que N1 deja de ser auto-agregante.** El estilo anterior fijaba, para N1, un record self-hosting que declaraba sus propios `Create`/`Apply` y se registraba con `Snapshot<T>()`. Es la consecuencia forzosa de que `<RootNamespace>.ReadModels` no lleve Marten, ni transitivamente (MEF-ADR-0034 seccion 5): mover el record al worker no es opcion -- el Function App del dominio lo necesita para el GET (`session.LoadAsync<TView>()`) --, asi que el comportamiento de proyeccion se traslada a la clase companion y el record se queda como dato puro. Beneficio colateral: **un solo estilo** de N1 y N2 en el marco, en vez de dos.

## Firmas admitidas en un metodo convencional -- y la proscrita

Un `Create`/`Apply`/`ShouldDelete` solo admite estos parametros: el tipo del evento (`TEvento`), `IEvent<TEvento>`, `IEvent`, `IQuerySession`, `CancellationToken` y `TView` (solo en `Apply`/`ShouldDelete`, ya con el estado previo). **Ningun tipo de identidad esta en esa lista**: `Create`/`Apply(TEvento, TId)` -- la firma intuitiva para pasarle el id a mano -- no es una firma que Marten reconozca.

**Namespace**: `IEvent`/`IEvent<TEvento>` viven en `JasperFx.Events`, no en `Marten.Events` -- ese es el `using` que necesita el archivo de la clase de proyeccion (tabla de namespaces de arriba, MEF-ADR-0035 ref. [16]).

**Modo de falla, no un error de build**: el dispatcher se genera igual, con 0 errores y 0 advertencias, pero el evento creador desaparece de `EventTypes` -- el documento nunca se crea, sin ninguna senal en el build ni en el arranque.

**Regla de procedencia (forma corta)**: un metodo de proyeccion solo puede leer lo que sale del evento persistido (`StreamKey`/`StreamId`/`Version`/`Timestamp`/`TenantId`/`CorrelationId`/`CausationId` o el payload) -- nunca de estado externo (una consulta, el reloj, configuracion). `IQuerySession` es sintacticamente valido pero rompe esa regla; adoptarlo exige justificacion explicita en el issue.

## N2 -- correlacion entre streams

**El `TId` de N2 no hereda la restriccion de N1**: es independiente de `StreamIdentity` -- lo determina el tipo que retorna `Identity<TEvento>(...)`/`Identities<TEvento>(...)`, no el store. `EquipoId` sigue siendo `Guid` en el ejemplo de abajo porque es un campo de dominio del payload, no el stream key de Marten. No generalizar el fix de N1 (arriba) a N2.

Marten no soporta auto-agregacion para `MultiStreamProjection`: la correlacion entre streams necesita un constructor, asi que la clase companion tambien declara la correlacion. Mismo estilo que N1 -- el read model sigue siendo un record inmutable plano, solo los datos, sin comportamiento de correlacion:

```csharp
using JasperFx.Events.Projections; // ProjectionLifecycle
using Marten.Events.Projections;   // MultiStreamProjection<,>

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

**El analizador no requiere ningun `PackageReference` adicional -- viaja dentro del propio paquete `Marten`.** Verificado en el paquete local (issue #495, MEF-ADR-0035 ref. [18]): `~/.nuget/packages/marten/9.12.0/analyzers/dotnet/cs/JasperFx.Events.SourceGenerator.dll`. Cualquier ensamblado con `PackageReference Include="Marten"` ya lo trae -- no hay que agregar `JasperFx.Events.SourceGenerator` como dependencia separada. El modo de falla accionable, si el dispatcher no se genera, no es "falta el paquete": la segunda mitad del mismo mensaje de error lo advierte -- *"...for Marten consumers the generator ships inside the Marten NuGet package, so verify the project reference does not exclude the 'analyzers' asset"*.

**Los dos chequeos concretos cuando el dispatcher no aparece** (MEF-ADR-0035 seccion 2, verificado contra la doc oficial de NuGet, ref. [20]): (1) que el `.csproj` **del worker** -- el ensamblado que declara la clase `partial`, no otro -- tenga su propio `PackageReference Include="Marten"`; recibir Marten por referencia de proyecto no alcanza, porque `analyzers` esta en el default de `PrivateAssets` (`contentfiles;analyzers;build`) y no fluye al proyecto padre. (2) que ese `PackageReference` no lleve `ExcludeAssets="analyzers"` (ni `ExcludeAssets="all"`), lo unico que le quita el generador al proyecto que lo declara. **No confundir los dos atributos**: `ExcludeAssets` es lo que el proyecto no consume; `PrivateAssets`, lo que consume pero no propaga hacia arriba.

**Caveat resuelto**: el ejemplo oficial `QuestParty` de la documentacion de Marten **no** declara `partial` porque es un tipo auto-agregante (`Snapshot<T>`/`SingleStreamProjection<T>`/`AggregateStream<T>`), no una clase de proyeccion companion con metodos convencionales -- el requisito nunca le aplico, y no hay ningun desalineamiento entre esa pagina ilustrativa y el comportamiento real de la version pinneada. Verificado en campo por el consumidor de referencia (Cosmos.ControlPlane, Marten `9.12.0`, SDK .NET 10): al remover el `partial` de una clase companion, Marten distingue explicitamente los dos casos en su mensaje de error -- *"A self-aggregating type registered via `Snapshot<T>` / `SingleStreamProjection<T>` / `AggregateStream<T>` does NOT need to be 'partial'; a projection subclass that uses convention methods DOES need to be declared 'partial'"*. Ese mismo mensaje nombra ademas el ensamblado del **documento** (*"Ensure that analyzer runs in the assembly that defines ...View"*), no el de la clase de proyeccion -- con el layout de este Skill (companion en el worker, record en `ReadModels`) ese mensaje es enganoso: seguir su indicacion literal llevaria a agregar Marten a `ReadModels`, exactamente la inversion que MEF-ADR-0034 seccion 5 evita. Lo que el analizador necesita es el ensamblado de la clase `partial`, no el del tipo que produce.

**No confundir los dos `partial` del read-side**: este es el `partial` de la *clase de proyeccion* (habilita el source generator de Marten). El "guarda del `partial`" de [config-test.md](config-test.md) es otro -- el *metodo* `partial` del seam de composicion `ConfiguracionMartenProjections{Dominio}`, que puede desaparecer en silencio si nadie lo implementa. Son requisitos independientes y ambos aplican.

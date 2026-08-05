# Config-test del worker de proyecciones

Fuente: MEF-ADR-0034 seccion 6 (plantilla del PR 134 de Cosmos.ControlPlane, consumidor de referencia). Hermano directo del test de composicion de MEF-ADR-0029, pero **no identico**: no valida un grafo de DI generico, sino la configuracion especifica de Marten que cada named store arma.

**`<RootNamespace>.Projections.Tests` aloja dos cosas**: el config-test de este documento, un unico archivo a nivel raiz del proyecto (`ConfiguracionMartenProjectionsTests.cs`), y los **unit tests de proyeccion** (`Create`/`Apply`/`ShouldDelete` de cada `{Concepto}Projection`), estos si en una subcarpeta por dominio -- `tests/<RootNamespace>.Projections.Tests/{Dominio}/{Concepto}ProjectionTests.cs`. El proyecto ya lleva `ProjectReference` al worker y ve `ReadModels` transitivamente (MEF-ADR-0034 seccion 5), asi que ningun `.csproj` cambia por alojar ambas cosas.

## Fuente unica de composicion

`Program.cs` del worker (`<RootNamespace>.Projections`) y el config-test comparten la misma fuente de composicion: cada dominio contribuye su propio metodo de extension `ConfiguracionMartenProjections{Dominio}.Configurar{Dominio}()` (ver [naming.md](naming.md)) que registra su named store; `Program.cs` invoca uno por dominio, y el test invoca los mismos metodos.

## Construccion sin Postgres real

El config-test (`<RootNamespace>.Projections.Tests`) construye el `IServiceCollection` invocando esos metodos de extension con una **cadena de conexion dummy** -- sin necesidad de Postgres real. Verificado contra la documentacion oficial de Marten: desde Marten 7, el `DocumentStore` ya no se inicializa forzadamente durante el bootstrapping del `IHost` (para evitar IO sincronico ahi); la conexion se abre recien en la primera operacion real contra la base.

```csharp
var services = new ServiceCollection();
services.AddLogging();

ConfiguracionMartenProjectionsVentas.ConfigurarVentas(services, dummyConnectionString: "Host=localhost;Database=dummy");
// ... un ConfigurarXxx por dominio del BC

var provider = services.BuildServiceProvider();
```

## Que verifica el test

1. **Guarda del `partial`**: que el store de **cada** dominio conocido del BC efectivamente resuelve desde el contenedor.

   Un metodo `partial` **puede** quedar sin implementacion sin romper el build, y en ese caso desaparece en silencio -- ocurre exactamente cuando la declaracion no lleva modificadores de acceso, retorna `void`, no tiene parametros `out` y no es `virtual`/`override`/`sealed`/`new`/`extern`. Cualquier otra forma (p. ej. `public static partial IServiceCollection ...`) si exige implementacion y el compilador la reclama (`CS8795`). El seam de composicion del worker cae en el primer grupo -- es la forma que hace util el hook de un dominio que aun no existe --, asi que un dominio nuevo que olvide su llamada de registro compila limpio y su daemon simplemente nunca corre. Este test es el primero en notarlo:

   ```csharp
   var store = provider.GetRequiredService<IVentasProjectionStore>();
   Assert.NotNull(store);
   ```

   Si el seam se declara con modificadores de acceso o retorno no-`void`, el compilador ya cubre esta guarda y el test conserva valor solo por los puntos 2 y 3.

   **Esta misma resolucion caza gratis un segundo modo de falla independiente: la clase de proyeccion sin `partial`** (el `partial` de la clase companion, MEF-ADR-0035 seccion 2 -- no el metodo del seam de arriba; son dos requisitos distintos y ambos aplican). Verificado por ejecucion propia (Marten `9.12.0`, SDK .NET 10.0.201, sin Postgres): una clase de proyeccion sin `partial` compila con 0 errores y 0 advertencias, y estalla exactamente al resolver el named store del contenedor -- la misma llamada `GetRequiredService<I{Dominio}ProjectionStore>()` de arriba -- con:

   ```
   InvalidProjectionException: No source-generated dispatcher found for {Proyeccion}.
   Conventional Apply/Create/ShouldDelete methods are dispatched by the compile-time
   JasperFx.Events.SourceGenerator; there is no runtime fallback. [...] the projection
   class must be declared `partial` in an assembly that references the
   JasperFx.Events.SourceGenerator analyzer, or alternatively override Evolve /
   EvolveAsync / DetermineAction / DetermineActionAsync directly [...] for Marten
   consumers the generator ships inside the Marten NuGet package, so verify the
   project reference does not exclude the 'analyzers' asset.
   ```

   Los `[...]` marcan el pegamento elidido entre fragmentos verbatim, no texto inventado. **La ultima frase es la que cierra el gotcha del analizador**: el generador viaja **dentro** del paquete `Marten` -- no hay ningun `PackageReference` que agregar --, y el modo de falla accionable no es "falta el paquete" sino un `ExcludeAssets="analyzers"` (o `="all"`) en el `PackageReference` de Marten **del ensamblado que declara la clase `partial`**, que es el worker (MEF-ADR-0035 seccion 2 e issue #495; ver tambien `modelos-marten.md`). Si esta guarda se pone roja, ese es el segundo lugar donde mirar despues del `partial` faltante.

   **El assert de la guarda 1 no cambia: sigue siendo el `Assert.NotNull(store)` de arriba.** El config-test **no** escribe un test que espere la excepcion -- un assert asi solo pasaria con el defecto presente. Lo que gobierna el envoltorio es otra cosa: (a) **como se lee el rojo** -- xUnit reporta un `TargetInvocationException` y la causa real vive en su `InnerException`, no en el mensaje de primer nivel, asi que quien diagnostique el fallo tiene que desenvolver; y (b) cualquier test que si afirme sobre el **tipo** de la excepcion (un diagnostico deliberado, fuera de estas tres guardas), que debe desenvolver antes de comparar:

   ```csharp
   // Diagnostico deliberado -- NO es la guarda 1, que sigue siendo el Assert.NotNull de arriba.
   using System.Reflection;            // TargetInvocationException
   using JasperFx.Events.Projections;  // InvalidProjectionException -- no vive bajo Marten.*

   var ex = Record.Exception(() => provider.GetRequiredService<IVentasProjectionStore>());
   var raiz = ex is TargetInvocationException { InnerException: { } inner } ? inner : ex;
   Assert.IsType<InvalidProjectionException>(raiz);
   ```

   **Gotcha de namespace del propio assert**: `InvalidProjectionException` vive en `JasperFx.Events.Projections` (ensamblado `JasperFx.Events`), **no** bajo `Marten.*` -- verificado por decompilacion del ensamblado (`ilspycmd -l c` sobre `JasperFx.Events` 2.18.1, la version que arrastra Marten `9.12.0`). Es el mismo patron que la regla generica de MEF-ADR-0034 seccion 6 fija para los enums de la superficie de configuracion, con su modo de falla caracteristico: `Marten.Events.Projections` **tambien existe** (ahi vive `MultiStreamProjection<,>`), asi que el `using` equivocado no da error propio y el build muere despues con `CS0103` sobre el simbolo sin resolver.

   **Esta segunda cobertura solo aplica cuando el dominio ya tiene al menos una proyeccion registrada** -- un dominio sin proyecciones no ejercita este camino, y la guarda sigue cubriendo unicamente el metodo `partial` del seam. Por el mismo camino, esta guarda tambien caza el `Id type mismatch` de MEF-ADR-0035 seccion 2 (un `TId` que no coincide con `Events.StreamIdentity`): cualquier `InvalidProjectionException` que Marten lance al ensamblar el named store sale a la luz aqui, sin Postgres y sin escribir un assert nuevo.

   **Dato negativo verificado: `ValidateConfiguration` no es la via.** `ProjectionOptions` **no expone ningun `ValidateConfiguration` publico** en la version pinneada (`error CS1061`) -- no es que devuelva una coleccion vacia con o sin `partial`, es que esa API no existe. La unica via verificada para cazar el gotcha del `partial` (de metodo o de clase) sigue siendo resolver el named store del contenedor, como hace esta guarda.

2. **Ciclo de vida `Async`**: que ninguna proyeccion registrada en el named store del worker haya quedado con lifecycle `Inline` -- si aparece una `Inline` ahi, es una proyeccion mal ubicada (deberia vivir en el write-side) o una regresion de copy-paste. Superficie verificada por ejecucion propia (Marten `9.12.0`): `store.Options.Events.Projections()` devuelve los elementos registrados, cada uno con `.Name` y `.Lifecycle`:

   ```csharp
   using JasperFx.Events.Projections;  // ProjectionLifecycle -- tampoco vive bajo Marten.*

   var lifecycles = store.Options.Events.Projections().Select(p => p.Lifecycle);
   Assert.All(lifecycles, l => Assert.Equal(ProjectionLifecycle.Async, l));
   ```

   **Trampa medida: `.Name` es el nombre del read model (la vista), no el de la clase de proyeccion.** Ejemplo medido: para la clase de proyeccion `ProyeccionOk` (companion de la vista `TurnoView`), `.Name` vale `'TurnoView'`, nunca `'ProyeccionOk'` -- una guarda que afirme por nombre de clase de proyeccion falla siempre.

3. **Guarda barata de metadata (subconjunto de la compatibilidad, no toda ella)**: que `Events.MetadataConfig.CorrelationIdEnabled`/`CausationIdEnabled`/`HeadersEnabled` esten en `true` en el named store del worker, exactamente como en la configuracion Marten del write-side de ese mismo dominio:

   ```csharp
   opts.Events.MetadataConfig.CorrelationIdEnabled = true;
   opts.Events.MetadataConfig.CausationIdEnabled = true;
   opts.Events.MetadataConfig.HeadersEnabled = true;
   ```

   Una divergencia entre ambos lados (p. ej. alguien habilita una columna nueva en el write-side y olvida replicarla aca) rompe la proyeccion en runtime con una excepcion de metadata ausente, no en el build. Estas tres columnas estan deshabilitadas por defecto en Marten -- *"the database table columns for this data will not be created unless you opt-in"* -- y es requisito del **writer**, no de este worker: sin el flag, la columna ni siquiera existe en la tabla de eventos.

   **Esta guarda no cubre toda la compatibilidad write-side/read-side** (MEF-ADR-0034 seccion 6, issue #447): el paquete `Cosmos.EventSourcing.CritterStack` fija diez atributos de Marten del lado write, no solo estos tres. La verificacion completa -- los otros siete atributos y el par read models/query-side -- es responsabilidad del **reviewer**, bajo el gate y las tablas de clasificacion que fija `agents/reviewer.md` ("Proyecciones y read-side").

## Que NO sustituye

- El test de composicion de MEF-ADR-0029, que sigue viviendo en cada dominio sobre su propio `ComposicionServicios{Dominio}.cs` del write-side.
- El DSL Given/When/Then de MEF-ADR-0002, que sigue validando comportamiento de negocio del aggregate, no del read-side.
- La verificacion de compatibilidad Marten que corre el **reviewer** bajo gate (MEF-ADR-0034 seccion 6): cubre los diez atributos que el paquete fija del lado write y el par read models/query-side, alcance que ningun test automatizado puede tener sin decompilar el paquete.

Son tres categorias de test complementarias, cada una sobre una capa distinta -- mas la verificacion del reviewer, que no es un test y por eso no corre en cada `dotnet test`.

## Clasificacion frente al coverage gate (MEF-ADR-0014)

- `<RootNamespace>.Projections` (el worker): **medido** -- su `Program.cs` y los `ConfiguracionMartenProjections{Dominio}.cs` siguen siendo composicion pura y quedan **excluidos** (cubiertos por este config-test, no por cobertura de linea), pero las clases de proyeccion (`{Concepto}Projection.cs`) llevan logica real (que evento aplica, como transforma el documento) y pasan a **medidas** -- las cubren los unit tests de proyeccion que ubica el encabezado de este documento, complementados -- no sustituidos -- por este config-test.
- `<RootNamespace>.ReadModels`: **excluido** uniformemente -- con las clases de proyeccion movidas al worker, lo unico que queda aqui son records de read model sin comportamiento, categoria "records DTO sin metodos" que MEF-ADR-0014 ya excluye.
- `<RootNamespace>.Projections.Tests` (config-test y unit tests de proyeccion): vive en `tests/`, fuera del alcance del gate.

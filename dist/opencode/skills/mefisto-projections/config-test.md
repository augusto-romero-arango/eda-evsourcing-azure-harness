# Config-test del worker de proyecciones

Fuente: MEF-ADR-0034 seccion 6 (plantilla del PR 134 de Cosmos.ControlPlane, consumidor de referencia). Hermano directo del test de composicion de MEF-ADR-0029, pero **no identico**: no valida un grafo de DI generico, sino la configuracion especifica de Marten que cada named store arma.

**`<RootNamespace>.Projections.Tests` aloja dos cosas**: el config-test de este documento, un unico archivo a nivel raiz del proyecto (`ConfiguracionMartenProjectionsTests.cs`), y los **unit tests de proyeccion** (`Create`/`Apply`/`ShouldDelete` de cada `{TerminoVista}Projection`), estos si en una subcarpeta por dominio -- `tests/<RootNamespace>.Projections.Tests/{Dominio}/{TerminoVista}ProjectionTests.cs`. El proyecto ya lleva `ProjectReference` al worker y ve transitivamente `ReadModels` (MEF-ADR-0034 seccion 5) y cada `{Dominio}.DomainEvents` que el worker referencia (MEF-ADR-0039 decision 2 -- de ahi salen los tipos de evento que tipan los `Create`/`Apply` bajo prueba), asi que ningun `.csproj` cambia por alojar ambas cosas.

## Fuente unica de composicion

`Program.cs` del worker (`<RootNamespace>.Projections`) y el config-test comparten la misma fuente de composicion: cada dominio contribuye su propio metodo de extension `ConfiguracionMartenProjections{Dominio}.Configurar{Dominio}()` (ver [naming.md](naming.md)) que registra su named store; `Program.cs` invoca uno por dominio, y el test invoca los mismos metodos.

Ese mismo metodo tambien registra, dentro del mismo `AddMartenStore`, los tipos de evento persistidos del dominio (`opts.Events.AddEventTypes(IdentidadEventos{Dominio}.TiposPersistidos)`, procedentes de `<RootNamespace>.{Dominio}.DomainEvents` -- MEF-ADR-0039 decision 5) antes de la primera lectura. **Ninguna de las tres guardas de abajo cubre ese registro, y este documento no agrega una cuarta**: la ausencia de esa linea no produce ninguna excepcion al resolver el store del contenedor -- el named store se arma igual --, sino el fallback por `mt_dotnet_type` al leer streams preexistentes, que degrada en `UnknownEventTypeException` cuando el tipo se movio de namespace o de ensamblado (MEF-ADR-0036; es el defecto que el consumidor de referencia pago en su issue #277). No la busques como una `InvalidProjectionException` mas de la guarda 1: esa excepcion es de otro sujeto (dispatcher ausente o `Id type mismatch`). Lo unico que si falla temprano es la **procedencia** de esos tipos: sin la `ProjectReference` del worker hacia `{Dominio}.DomainEvents`, el `using` del seam no resuelve `IdentidadEventos{Dominio}` y el build muere con `CS0246`.

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

## Plantilla del par espejo (issue #722)

Los tres puntos de arriba verifican la configuracion **interna** del worker; ninguno la compara contra la del write-side. Esa comparacion es el **par 2** de compatibilidad Marten (MEF-ADR-0034 seccion 6: worker que materializa los documentos -> query-side del Function App), y necesita su propia guarda siempre-activa porque el gate del reviewer no se dispara con un PR que solo agrega una Function GET nueva (exactamente el PR que introduce el defecto tipico: Bitakora.ControlAsistencia issues #294 y #448). Con la tercera instancia conocida del par 2 verificada en el consumidor de referencia -- `mt_version` y tabla/tenancy/id, las dos que traen par espejo propio, sobre la de tenancy documental que el par 2 ya tenia enumerada --, el patron "oraculo literal espejo" que introdujo el issue #718 deja de ser una receta puntual y se generaliza a **plantilla**.

**Por que se extrae con dos aplicaciones y no con tres.** MEF-ADR-0018 fija la Rule of Three -- *"con dos sitios, la duplicacion se mantiene; recien al tercer caso vale la pena evaluar si la abstraccion es estable y aporta"* -- y esta plantilla se extrae en la **segunda** aplicacion del mecanismo. La justificacion no es esa fila sino las dos vecinas del mismo ADR: "costo de la duplicacion estable" (*"si los sitios cambian en sincronia un par de veces sin diverger, la duplicacion deja de ser estable y entra en el camino de la extraccion"*) y la excepcion que fija "autoridad de extraccion" (*"cuando un cambio reciente toco simultaneamente los dos sitios y los dejo identicos -- ese es el momento natural para proponer la extraccion en el mismo PR"*). Las dos aplicaciones no divergen en nada estructural: mismo `FindOrResolveDocumentType`, misma asimetria de autoridad, los mismos dos proyectos de test, el mismo modo de falla silencioso -- solo cambia el trio de literales. Si una tercera aplicacion divergiera de esa forma, la plantilla se revisa; el propio MEF-ADR-0018 advierte que la regla *"no es mecanica"*.

### Mecanica comun a toda instancia

**Un test por lado, cada uno en su propio proyecto sobre su propio store** -- `ComposicionServicios{Dominio}Tests` del dominio (write-side) <-> `ConfiguracionMartenProjectionsTests` de `<RootNamespace>.Projections.Tests` (read-side) --, afirmando los mismos oraculos literales via `Options.FindOrResolveDocumentType(typeof(TView))` (`IReadOnlyStoreOptions`, alcanzable sin downcast -- misma superficie que ya usa MEF-ADR-0034 seccion 6 para `Events.MetadataConfig`) contra su **propio** store, nunca contra el resultado del otro.

**Sin comparacion cruzada, y no por eleccion de estilo.** `<RootNamespace>.Projections.Tests` y `<RootNamespace>.{Dominio}.Tests` no pueden referenciarse entre si sin abrir la misma brecha que el reviewer ya vigila en el `.csproj` del worker (MEF-ADR-0039 decision 4: las unicas `<ProjectReference>` validas del worker son `*.DomainEvents` y `ReadModels`, nunca un Function App ni su proyecto de tests) -- un test que comparara ambos lados exigiria exactamente esa referencia prohibida.

**Asimetria de autoridad.** El worker no declara nada por su cuenta: Marten impone la forma fisica (columna de version, nombre de tabla, particion por tenant) al registrar la proyeccion en el named store (ver `read-apis.md` y MEF-ADR-0034 seccion 2). El Function App, en cambio, **replica** esa forma a mano, porque su mapping por convencion no hereda ninguna politica del worker. Por eso los dos tests no se comparan entre si: cada uno afirma el mismo literal **contra su propio store**.

**Simetria en el mismo issue.** El issue que agrega la superficie de consulta o la condicion de compatibilidad que motiva una instancia nueva de esta plantilla escribe **las dos mitades** del par -- nunca solo la del worker. Bitakora #448 es la evidencia de lo que pasa si no: la mitad del worker ya existia, la mitad del Function App nunca se escribio, y el gap quedo invisible hasta el primer GET en produccion.

### Criterio de seleccion de atributos

Que atributos entran en el oraculo literal de una instancia lo fija una **regla, no una lista cerrada** -- la misma regla de corte que MEF-ADR-0034 seccion 6 fija para todo el par 2: entran los que determinan **como se interpreta lo ya persistido** (forma fisica de columna, nombre de tabla, politica de particion por tenant, identidad del documento); nunca una propiedad del **proceso** (conexion, modo del daemon, logging, `AutoCreateSchemaObjects`). Ante un atributo nuevo del paquete que ninguna instancia de abajo enumere, aplica la regla, no busques la fila.

### Instancia conocida: `mt_version` (segunda del par 2, issue #718)

La receta de [read-apis.md](read-apis.md) (seccion "Resolucion de `TView` en el write-side") exige `opts.Schema.For<TView>().UseNumericRevisions(true)` en el Function App por cada documento consultado. El oraculo que este par espejo afirma:

```csharp
var documento = store.Options.FindOrResolveDocumentType(typeof(ResumenAsistenciaDiaria));

Assert.True(documento.Metadata.Revision.Enabled);
Assert.Equal("bigint", documento.Metadata.Revision.Type);
Assert.False(documento.Metadata.Version.Enabled);
```

**Cual de los tres discrimina, medido** (ejecucion propia al revisar el issue #718: SDK .NET 10.0.201, Marten `9.12.0`, sin Postgres, sobre `DocumentStore.For(...)` en las tres configuraciones). El trio se afirma completo, pero sus miembros no pesan igual:

| Store medido | `Revision.Enabled` | `Revision.Type` | `Version.Enabled` |
|---|---|---|---|
| Worker (proyeccion registrada `Async`) | `true` | `bigint` | `false` |
| Write-side desnudo (**el defecto**) | `false` | `bigint` | `true` |
| Write-side con `UseNumericRevisions(true)` | `true` | `bigint` | `false` |

`Revision.Type` vale `"bigint"` en las tres -- es el tipo fijo de la columna `mt_version` **cuando la revision numerica esta habilitada**, no un discriminador: quien lo afirme solo, cree tener guarda y no la tiene. Los que separan el defecto de la receta son `Revision.Enabled` y `Version.Enabled`, que se mueven en bloque (Marten cambia de optimistic concurrency Guid-based a revision numerica, no habilita las dos a la vez). `Revision.Type` se conserva en el trio porque fija la **forma fisica** que el `ALTER COLUMN` fallido pone en juego -- si una version futura de Marten la moviera a `integer`, el par seguiria alineado entre lados pero el diagnostico de esta doctrina dejaria de aplicar, y esta linea es la que lo caza.

- **Mitad write-side** (`tests/<RootNamespace>.{Dominio}.Tests/ComposicionServicios{Dominio}Tests.cs`), sobre el `IDocumentStore` que arma `ComposicionServicios{Dominio}.Agregar{Dominio}(...)`: `AgregarServicios{Dominio}_EsperaLaMismaColumnaDeVersionQueMaterializaraElWorker_Para{Vista}`.
- **Mitad read-side** (`tests/<RootNamespace>.Projections.Tests/ConfiguracionMartenProjectionsTests.cs`), sobre el `I{Dominio}ProjectionStore` que ya resuelve la guarda 1 de este documento: `Configurar{Dominio}_Materializa{Vista}ConRevisionNumerica`.

Nombres de referencia y receta validados en produccion por el consumidor (Bitakora.ControlAsistencia, issue #328, PR #441).

### Instancia conocida: tabla/tenancy/id (tercera del par 2, issue #722)

Tercera instancia conocida del par 2 -- y **segunda aplicacion de esta plantilla** --, verificada en produccion por el consumidor de referencia (Bitakora.ControlAsistencia): un trio distinto que tambien determina como se interpreta lo ya persistido -- la tabla fisica (schema incluido) donde vive el documento, si esa tabla esta particionada por tenant, y que miembro hace de identidad:

```csharp
var documento = store.Options.FindOrResolveDocumentType(typeof(TurnoVigente));

Assert.Equal("asistencia.mt_doc_turnovigente", documento.TableName.QualifiedName);
Assert.Equal(TenancyStyle.Conjoined, documento.TenancyStyle);
Assert.Equal(nameof(TurnoVigente.Id), documento.IdMember.Name);
```

**`QualifiedName` incluye el schema** -- medido: `"asistencia.mt_doc_turnovigente"`, no `"mt_doc_turnovigente"` (ese es `.Name`). Es el accesor correcto justamente por eso: arrastra al oraculo el `DatabaseSchemaName` del dominio, la primera fila de la tabla "Debe coincidir" del reviewer. Un literal sin schema hace fallar las dos mitades del par.

**Cual de los tres discrimina, medido** (ejecucion propia al revisar este issue: SDK .NET 10.0.201, Marten `9.12.0`, sin Postgres, sobre `DocumentStore.For(...)` con `DatabaseSchemaName = "asistencia"`):

| Store medido | `TableName.QualifiedName` | `TenancyStyle` | `IdMember.Name` |
|---|---|---|---|
| Worker (proyeccion `Async` + `AllDocumentsAreMultiTenanted()`) | `asistencia.mt_doc_turnovigente` | `Conjoined` | `Id` |
| Write-side por convencion, con la policy que trae el paquete | `asistencia.mt_doc_turnovigente` | `Conjoined` | `Id` |
| Write-side **sin** `AllDocumentsAreMultiTenanted()` (**la divergencia**) | `asistencia.mt_doc_turnovigente` | `Single` | `Id` |

El discriminador del trio es `TenancyStyle`: `Conjoined` cuando la policy esta, `Single` cuando falta. `QualifiedName` e `IdMember.Name` no se mueven con **esta** divergencia -- se conservan por la misma razon que `Revision.Type` en la instancia de arriba: fijan la forma fisica que la compatibilidad pone en juego, y cazan una divergencia distinta (un `DatabaseSchemaName` que se separe entre lados, o un `IdMember` que cambie al renombrar el miembro de identidad del read model).

**Superficie y namespaces, verificados en la misma ejecucion**: `TableName` se declara como `Weasel.Core.DbObjectName` (en runtime, `Weasel.Postgresql.PostgresqlObjectName`) -- de ahi `.QualifiedName`; `TenancyStyle` es del tipo `JasperFx.MultiTenancy.TenancyStyle` -- mismo gotcha de namespace que ya fija MEF-ADR-0034 seccion 6 como regla generica, no vive bajo `Marten.*` y sin su `using` el assert falla con `CS0103`; `IdMember` se declara como `System.Reflection.MemberInfo` (runtime `PropertyInfo`) -- de ahi el `.Name` del assert.

- **Mitad write-side** (`tests/<RootNamespace>.{Dominio}.Tests/ComposicionServicios{Dominio}Tests.cs`): `...ResuelveTurnoVigenteSobreLaTablaQueMaterializaElWorker...`.
- **Mitad read-side** (`tests/<RootNamespace>.Projections.Tests/ConfiguracionMartenProjectionsTests.cs`): `...MaterializaTurnoVigenteSobreLaTablaQueConsultaElWriteSide...`.

Nombres de referencia validados en produccion por el consumidor (Bitakora.ControlAsistencia, par de tests espejo de tabla/tenancy/id).

**Convierte la primera instancia del par 2 en guarda siempre-activa.** `TenancyStyle.Conjoined` de este trio **es** la condicion que `Policies.AllDocumentsAreMultiTenanted()` fija (tenancy documental, la primera instancia conocida del par 2, MEF-ADR-0034 seccion 6), hasta ahora verificada **solo** por el reviewer bajo el gate condicional de compatibilidad Marten -- y "si diverge ninguna excepcion avisa" ([read-apis.md](read-apis.md), seccion "Resolucion de `TView`"). Con esta instancia instalada, esa condicion queda cubierta ademas por un test que corre en cada `dotnet test`, sin depender de que un diff dispare ese gate -- mismo argumento que ya justifica la instancia de `mt_version` de arriba, y ahora con el oraculo que efectivamente la discrimina identificado (`TenancyStyle`, tabla de arriba).

**Que parte de la divergencia es silenciosa, medido.** Marten no calla siempre. Si el worker conserva `Events.TenancyStyle = Conjoined` -- lo que el **par 1** ya le exige -- pero pierde la policy documental, registrar una proyeccion de agregacion falla al construir el store: `InvalidProjectionException: Tenancy storage style mismatch between the events (Conjoined) and the aggregate type <TView> (Single) but the TenancyGrouping is RespectTenant`. Esa divergencia se cae sola. La **silenciosa** -- la que este par espejo caza -- es la simetrica: un worker que diverge en bloque (eventos *y* documentos en `Single`) construye su store sin una queja, y el Function App, `Conjoined` en ambos porque el paquete se lo fija, termina consultando con filtro de tenant una tabla que el worker materializo sin esa particion. Ningun lado lanza nada; los dos literales del par espejo si difieren.

## Que NO sustituye

- El test de composicion de MEF-ADR-0029, que sigue viviendo en cada dominio sobre su propio `ComposicionServicios{Dominio}.cs` del write-side.
- El DSL Given/When/Then de MEF-ADR-0002, que sigue validando comportamiento de negocio del aggregate, no del read-side.
- La verificacion de compatibilidad Marten que corre el **reviewer** bajo gate (MEF-ADR-0034 seccion 6): cubre los diez atributos que el paquete fija del lado write y el par read models/query-side, alcance que ningun test automatizado puede tener sin decompilar el paquete.

Son tres categorias de test complementarias, cada una sobre una capa distinta -- mas la verificacion del reviewer, que no es un test y por eso no corre en cada `dotnet test`.

## Clasificacion frente al coverage gate (MEF-ADR-0014)

- `<RootNamespace>.Projections` (el worker): **medido** -- su `Program.cs` y los `ConfiguracionMartenProjections{Dominio}.cs` siguen siendo composicion pura y quedan **excluidos** (cubiertos por este config-test, no por cobertura de linea), pero las clases de proyeccion (`{TerminoVista}Projection.cs`) llevan logica real (que evento aplica, como transforma el documento) y pasan a **medidas** -- las cubren los unit tests de proyeccion que ubica el encabezado de este documento, complementados -- no sustituidos -- por este config-test.
- `<RootNamespace>.ReadModels`: **excluido** uniformemente -- con las clases de proyeccion movidas al worker, lo unico que queda aqui son records de read model sin comportamiento, categoria "records DTO sin metodos" que MEF-ADR-0014 ya excluye.
- `<RootNamespace>.Projections.Tests` (config-test y unit tests de proyeccion): vive en `tests/`, fuera del alcance del gate.

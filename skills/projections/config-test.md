# Config-test del worker de proyecciones

Fuente: MEF-ADR-0034 seccion 6 (plantilla del PR 134 de Cosmos.ControlPlane, consumidor de referencia). Hermano directo del test de composicion de MEF-ADR-0029, pero **no identico**: no valida un grafo de DI generico, sino la configuracion especifica de Marten que cada named store arma.

**`<RootNamespace>.Projections.Tests` aloja dos cosas, en subcarpetas por dominio**: el config-test de este documento (a nivel raiz del proyecto) y los **unit tests de proyeccion** (`Create`/`Apply`/`ShouldDelete` de cada `{Concepto}Projection`, `tests/<RootNamespace>.Projections.Tests/{Dominio}/{Concepto}ProjectionTests.cs`). El proyecto ya lleva `ProjectReference` al worker y ve `ReadModels` transitivamente (MEF-ADR-0034 seccion 5), asi que ningun `.csproj` cambia por alojar ambas cosas.

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

2. **Ciclo de vida `Async`**: que ninguna proyeccion registrada en el named store del worker haya quedado con lifecycle `Inline` -- si aparece una `Inline` ahi, es una proyeccion mal ubicada (deberia vivir en el write-side) o una regresion de copy-paste. Reverificar la superficie exacta de `StoreOptions.Projections` de la version vigente del paquete Marten antes de escribir este assert.

3. **Replica exacta de la configuracion de metadata del write-side**: que `Events.MetadataConfig.CorrelationIdEnabled`/`CausationIdEnabled`/`HeadersEnabled` esten en `true` en el named store del worker, exactamente como en la configuracion Marten del write-side de ese mismo dominio:

   ```csharp
   opts.Events.MetadataConfig.CorrelationIdEnabled = true;
   opts.Events.MetadataConfig.CausationIdEnabled = true;
   opts.Events.MetadataConfig.HeadersEnabled = true;
   ```

   Una divergencia entre ambos lados (p. ej. alguien habilita una columna nueva en el write-side y olvida replicarla aca) rompe la proyeccion en runtime con una excepcion de metadata ausente, no en el build. Estas tres columnas estan deshabilitadas por defecto en Marten -- *"the database table columns for this data will not be created unless you opt-in"* -- y es requisito del **writer**, no de este worker: sin el flag, la columna ni siquiera existe en la tabla de eventos.

## Que NO sustituye

- El test de composicion de MEF-ADR-0029, que sigue viviendo en cada dominio sobre su propio `ComposicionServicios{Dominio}.cs` del write-side.
- El DSL Given/When/Then de MEF-ADR-0002, que sigue validando comportamiento de negocio del aggregate, no del read-side.

Son tres categorias de test complementarias, cada una sobre una capa distinta.

## Clasificacion frente al coverage gate (MEF-ADR-0014)

- `<RootNamespace>.Projections` (el worker): **medido** -- su `Program.cs` y los `ConfiguracionMartenProjections{Dominio}.cs` siguen siendo composicion pura y quedan **excluidos** (cubiertos por este config-test, no por cobertura de linea), pero las clases de proyeccion (`{Concepto}Projection.cs`) llevan logica real (que evento aplica, como transforma el documento) y pasan a **medidas** -- las cubren los unit tests de proyeccion de la seccion anterior, complementados por este config-test.
- `<RootNamespace>.ReadModels`: **excluido** uniformemente -- con las clases de proyeccion movidas al worker, lo unico que queda aqui son records de read model sin comportamiento, categoria "records DTO sin metodos" que MEF-ADR-0014 ya excluye.
- `<RootNamespace>.Projections.Tests` (config-test y unit tests de proyeccion): vive en `tests/`, fuera del alcance del gate.

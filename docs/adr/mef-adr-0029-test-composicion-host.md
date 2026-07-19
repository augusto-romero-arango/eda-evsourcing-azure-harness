# MEF-ADR-0029: Test de composicion del contenedor DI del host

- **Fecha**: 2026-07-19
- **Estado**: aceptado
- **Aplica a**: `domain-scaffolder` (plantilla de `Program.cs` y generacion del proyecto de tests de cada dominio scaffoldeado). Cross-referencia MEF-ADR-0002 (estrategia de testing ES), MEF-ADR-0003 (stack Marten+Wolverine), MEF-ADR-0014 (coverage gate) y MEF-ADR-0028 (estrategia de tenancy, dependencia directa del incidente que origina este ADR).

## Contexto

Los tests unitarios de event sourcing (Given/When/Then, MEF-ADR-0002) construyen sus escenarios
contra el DSL del harness (`Cosmos.EventSourcing.Testing.Utilities`): nunca levantan el contenedor
de DI real del host de Azure Functions. Un registro faltante en ese contenedor no lo detecta
ningun test unitario -- solo revienta cuando el host arranca de verdad.

Eso paso en el consumidor Bitakora.ControlAsistencia: un upgrade de
`Cosmos.EventSourcing.CritterStack` dejo de auto-registrar `ITenantResolver` (refs #207 upgrade,
#219 fix). El build compilo limpio y los tests unitarios quedaron en verde -- ninguno construye el
grafo de DI -- y el problema solo se detecto **post-deploy**, en los smoke tests contra el entorno
dev (issue #221, guardrail creado en el consumidor). El feedback loop para un registro de DI
faltante fue el mas caro posible: build + tests verdes + deploy (~4 minutos) + smoke tests, cuando
un test de composicion lo hubiera detectado en segundos, en la misma corrida que el resto de la
suite.

Este ADR hornea ese guardrail en el scaffold de Mefisto (issue #319) para que todo dominio nuevo lo
tenga por defecto, en vez de reintroducirlo repo por repo. Depende de MEF-ADR-0028 (issue #318):
resolver los routers del dominio arrastra `ITenantResolver` en sus constructores (ver "Verificacion
empirica" abajo), asi que el test de composicion solo puede quedar en verde sobre un scaffold que ya
registra ese resolver.

### Por que hoy no es testeable: `Program.cs` con wiring inline

Antes de este ADR, `domain-scaffolder` generaba `Program.cs` como top-level statements con todo el
wiring de DI inline (Wolverine, Marten, routers, tenancy, OpenTelemetry, validacion). Un
`Program.cs` de top-level statements no es una unidad invocable desde un test: no hay forma de
construir ese mismo `IServiceCollection` sin ejecutar el proceso completo del host.

### Verificacion empirica: por que la resolucion explicita de routers es necesaria y suficiente

Decompilando (`ilspycmd`) los ensamblados `Cosmos.EventSourcing.CritterStack` 2.1.0 y
`Cosmos.EventDriven.CritterStack` 2.1.0 (paquetes privados del marco, sin codigo fuente publico):

- `AgregarWolverineCommandRouter()` registra `services.AddScoped<ICommandRouter,
  WolverineCommandRouter>()`.
- `AgregarWolverineEventSender()` registra `services.AddScoped<IPublicEventSender,
  WolverinePublicEventSender>()` y `services.AddScoped<IPrivateEventSender,
  WolverinePrivateEventSender>()`.
- `AgregarWolverinePrivateEventRouter()` registra `services.AddScoped<IPrivateEventRouter,
  WolverinePrivateEventRouter>()`.

Las tres son registros **por tipo mapeado** (`AddScoped<TService, TImplementation>`), no por
factory-lambda. Y las tres implementaciones concretas dependen **directamente** de
`ITenantResolver` en su constructor:

```csharp
public class WolverineCommandRouter(IMessageBus messageBus, ITenantResolver tenantResolver) : ICommandRouter
public class WolverinePrivateEventSender(IMessageBus messageBus, ITenantResolver tenantResolver) : IPrivateEventSender
public class WolverinePrivateEventRouter(IMessageBus messageBus, ITenantResolver tenantResolver) : IPrivateEventRouter
```

Esta es exactamente la forma del incidente que origina este ADR: si `ITenantResolver` no esta
registrado, construir cualquiera de estos tres tipos falla. Por tratarse de registros por tipo
mapeado, `ValidateOnBuild` ya recorre su arbol de constructor y detecta la ausencia de
`ITenantResolver` sin necesidad de resolver nada explicitamente (ver seccion siguiente). La
resolucion explicita de los tres routers (CA-3) es un complemento deliberado, no una compensacion
de un hueco de cobertura de `ValidateOnBuild` sobre estos tipos puntuales -- ver "Decision, punto 3"
para el motivo real por el que se mantiene.

## Decision

### 1. Extraer la composicion de servicios a un metodo de extension compartido

`domain-scaffolder` genera `Infraestructura/ComposicionServicios{Dominio}.cs` con el metodo
`AgregarServicios{Dominio}(this IServiceCollection, string martenConnectionString, string
serviceBusInterno, string serviceBus<Alias> (uno por alias del backbone compartido), bool isDev)`.
Ahi vive **todo** el wiring que antes eran top-level statements de `Program.cs`: Wolverine, Marten,
los tres routers, el `ITenantResolver` transitorio (MEF-ADR-0028), OpenTelemetry y la
configuracion de JSON/validacion. `Program.cs` pasa a invocar unicamente ese metodo -- una sola
fuente de verdad del wiring, sin duplicacion entre `Program.cs` y el test.

### 2. Test de composicion con `BuildServiceProvider(ValidateOnBuild, ValidateScopes)`

`domain-scaffolder` genera `tests/.../Infraestructura/ComposicionContenedorTests.cs`: construye un
`IServiceCollection` nuevo, invoca el mismo `AgregarServicios{Dominio}` con cadenas de conexion
dummy (no se abre ninguna conexion real -- eso ocurre al arrancar el host, no al construir el
`ServiceProvider`), y valida con:

```csharp
services.BuildServiceProvider(new ServiceProviderOptions
{
    ValidateOnBuild = true,
    ValidateScopes = true
});
```

Ademas resuelve explicitamente, desde un scope (`ValidateScopes = true` prohibe resolver un
servicio `Scoped` desde el proveedor raiz), los tres routers que todo dominio registra:
`ICommandRouter`, `IPrivateEventSender`, `IPrivateEventRouter`.

### 3. Limites conocidos de `ValidateOnBuild` y por que la resolucion explicita se mantiene igual

**Verificado contra la documentacion oficial** [1]: *"Open generics services aren't validated."*
`ValidateOnBuild` no valida servicios genericos abiertos.

**Verificado contra el codigo fuente de `dotnet/runtime`** [2]: al construir el proveedor,
`ValidateService(descriptor)` arma el arbol de *call sites* con `CallSiteFactory.GetCallSite(...)`
para cada descriptor registrado, sin invocar ningun delegado. Para un registro **por
factory-lambda** (`AddScoped<T>(sp => ...)`), el *call site* resultante es una hoja opaca: el
arbol no recorre el cuerpo del lambda, asi que una dependencia que ese lambda resuelva
internamente (`sp.GetRequiredService<X>()`) con `X` sin registrar **no** se detecta en el build --
solo al invocar el lambda de verdad, en resolucion real. Wolverine y Marten registran
internamente muchos servicios asi (via `AddWolverine(...)`/`AddMarten(...)`), fuera del control de
este scaffold.

Esto explica por que la resolucion explicita de los tres routers (CA-3) es una garantia
**estrictamente mas fuerte** que dejar que `ValidateOnBuild` los cubra por ser tipo-mapeados (ver
"Verificacion empirica" arriba): `scope.ServiceProvider.GetRequiredService<ICommandRouter>()`
**invoca de verdad** la cadena completa de construccion, incluyendo cualquier dependencia
transitiva registrada por factory-lambda dentro de Wolverine (p. ej. `IMessageBus`) que
`ValidateOnBuild` deja sin ejercitar. Es ademas una proteccion que no depende de que
`WolverineCommandRouter`/`WolverinePrivateEventSender`/`WolverinePrivateEventRouter` sigan siendo
tipo-mapeados en una version futura del paquete: si algun dia cambiaran a factory-lambda,
`ValidateOnBuild` dejaria de cubrirlos en silencio, pero la resolucion explicita seguiria
protegiendo igual.

El codigo generado documenta este limite con un comentario junto a la clase de test (ver plantilla
en `agents/domain-scaffolder.md`, Paso 2 punto 9), para que no se lea como garantia total.

### 4. Categoria complementaria y distinta de MEF-ADR-0002

El test de composicion valida **wiring del contenedor**: que el grafo de DI construye sin
excepciones y que los routers resuelven. No valida comportamiento de negocio ni el DSL
Given/When/Then de MEF-ADR-0002 (eventos emitidos, estado del aggregate). Ambas categorias son
necesarias y no se sustituyen entre si: un test de composicion en verde no dice nada sobre si un
command handler emite el evento correcto, y un test ES en verde no dice nada sobre si el host
arranca.

### 5. No distorsiona el coverage gate (MEF-ADR-0014)

`ComposicionContenedorTests.cs` vive en `tests/`, fuera del alcance del gate (que mide `src/`).
`Infraestructura/ComposicionServicios{Dominio}.cs` vive en `src/.../Infraestructura/`, categoria ya
excluida de medicion en la tabla de MEF-ADR-0014 (*"`Infraestructura/` wiring puro"*): no es logica
de dominio, es composicion. El test de composicion no infla ni exige cobertura adicional del gate.

## Alternativas consideradas

### Alt 1: test de host real (levantar el proceso del worker)

**Descartada**: Azure Functions isolated worker no tiene un equivalente al `WebApplicationFactory`
de ASP.NET Core para pruebas in-process. Levantar el proceso real del host reintroduce el mismo
feedback loop caro (segundos-minutos, requiere el runtime de Functions disponible en CI) que este
ADR busca eliminar.

### Alt 2: duplicar el wiring en el test, sin extraerlo a un metodo compartido

**Descartada**: el test y `Program.cs` quedarian como dos copias del mismo wiring. La primera vez
que alguien edite una y no la otra, el test deja de ser una garantia real -- puede quedar en verde
validando un grafo que ya no es el que `Program.cs` arma en produccion. Rompe el principio de
fuente unica de verdad (CA-1).

### Alt 3: confiar solo en `ValidateOnBuild`, sin resolucion explicita de routers

**Descartada**: aunque los tres routers son hoy tipo-mapeados (ver "Verificacion empirica") y por
tanto ya cubiertos por el recorrido de `ValidateOnBuild`, esa cobertura es incidental a como estan
implementados hoy los paquetes `Cosmos.EventSourcing.CritterStack`/`Cosmos.EventDriven.CritterStack`,
no una garantia contractual. La resolucion explicita ejercita la invocacion real (incluidas
dependencias transitivas por factory-lambda como `IMessageBus`) y no depende de que esa forma de
registro no cambie en una version futura del paquete.

## Consecuencias

### Positivas

- **Un registro de DI faltante se detecta en segundos, en la misma corrida de tests**, en vez de
  build + deploy + smoke tests (~4 minutos, el feedback loop que origino el incidente real).
- **Fuente unica de verdad del wiring**: `Program.cs` y el test invocan el mismo metodo de
  extension; no hay wiring duplicado que pueda desincronizarse.
- **Auto-mantenido**: si un upgrade futuro de `Cosmos.Event*`/Wolverine/Marten rompe el wiring
  manteniendo la firma publica del metodo de extension, el test se pone rojo solo, sin que nadie
  tenga que recordar actualizarlo.
- **No distorsiona el coverage gate** (MEF-ADR-0014): ni el archivo de wiring ni el test de
  composicion caen en la categoria medida.

### Negativas

- **Un parametro mas por alias del backbone compartido** en la firma de `AgregarServicios{Dominio}`
  cuando el BC agrega su primer evento publico -- churn menor, ya mitigado por la misma regla
  dinamica que `domain-scaffolder` ya aplicaba en `Program.cs` antes de este ADR.
- **No cubre el arranque real del host** (conexiones reales, bindings de Azure Functions,
  `host.json`, variables de entorno de produccion): eso lo sigue cubriendo exclusivamente el smoke
  test post-deploy (MEF-ADR-0013). El test de composicion reduce el costo de detectar un registro
  faltante; no elimina la necesidad de smoke tests.

## Referencias

- **[1]** `ServiceProviderOptions.ValidateOnBuild` -- Microsoft Learn (.NET API docs). Remarks:
  "Open generics services aren't validated."
  https://learn.microsoft.com/dotnet/api/microsoft.extensions.dependencyinjection.serviceprovideroptions.validateonbuild
- **[2]** `ServiceProvider.cs` -- codigo fuente publico de `dotnet/runtime`
  (`src/libraries/Microsoft.Extensions.DependencyInjection/src/ServiceProvider.cs`): el constructor
  invoca `ValidateService(descriptor)` para cada `ServiceDescriptor` cuando `ValidateOnBuild` es
  `true`, que arma el *call site* via `CallSiteFactory.GetCallSite(...)` sin invocar el delegado de
  un registro por factory-lambda. https://github.com/dotnet/runtime/blob/main/src/libraries/Microsoft.Extensions.DependencyInjection/src/ServiceProvider.cs
- ASP.NET Core Minimal APIs -- Microsoft Learn, seccion "ValidateScopes and ValidateOnBuild": ambas
  opciones estan habilitadas por defecto en `Development`, deshabilitadas en el resto de entornos
  por rendimiento. `ValidateScopes` lanza `InvalidOperationException` si se resuelve un servicio
  `Scoped` desde el proveedor raiz; `ValidateOnBuild` lanza `AggregateException` con el detalle de
  los servicios que no pudieron construirse.
  https://learn.microsoft.com/aspnet/core/fundamentals/minimal-apis
- `Cosmos.EventSourcing.CritterStack` / `Cosmos.EventDriven.CritterStack` 2.1.0: paquetes privados
  del marco sin documentacion publica; los registros de `AgregarWolverineCommandRouter()`,
  `AgregarWolverineEventSender()`, `AgregarWolverinePrivateEventRouter()` y los constructores de
  `WolverineCommandRouter`/`WolverinePrivateEventSender`/`WolverinePrivateEventRouter` citados en
  este ADR se verificaron decompilando con `ilspycmd` los ensamblados de la version 2.1.0 (misma
  version que fija MEF-ADR-0003/issue #312 para el resto del stack `Cosmos.Event*`).
- MEF-ADR-0002 (estrategia de testing ES): el test de composicion es una categoria distinta y
  complementaria; no sustituye el DSL Given/When/Then.
- MEF-ADR-0003 (stack ES Marten+Wolverine): documenta el patron de configuracion en `Program.cs`
  que este ADR extrae a un metodo de extension compartido con el test.
  MEF-ADR-0014 (coverage gate): el test de composicion y el archivo de wiring que ejercita quedan
  fuera del alcance medido por el gate.
- MEF-ADR-0028 (estrategia de tenancy): el `ITenantResolver` que este ADR verifica que este
  registrado es el que fija ese ADR; sin el, el test de composicion se pondria rojo sobre un
  dominio recien scaffoldeado (dependencia del issue #319 sobre el issue #318).
- Bitakora.ControlAsistencia issues #207 (upgrade que rompio el registro), #219 (fix del incidente)
  y #221 (guardrail creado en el consumidor, origen real de este ADR).

## Control de cambios

- 2026-07-19: creacion como `aceptado` (issue #319). Fija la extraccion de la composicion de DI a
  un metodo de extension compartido entre `Program.cs` y el test, el test de composicion con
  `BuildServiceProvider(ValidateOnBuild, ValidateScopes)` + resolucion explicita de los tres
  routers, y delimita la categoria frente a MEF-ADR-0002 y MEF-ADR-0014.

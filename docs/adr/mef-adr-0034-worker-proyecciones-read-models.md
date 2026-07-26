# MEF-ADR-0034: Worker de proyecciones y read models por Bounded Context

- **Fecha**: 2026-07-26
- **Estado**: aceptado
- **Aplica a**: doctrina de materializacion de read models via el async daemon de Marten. Ancla del futuro skill `/scaffold-projections` y del agente `projections-scaffolder` (issue #367), de los agentes `projection-test-writer`/`projection-implementer` (issue #365), de la extension de `domain-scaffolder` para registrar el store de cada dominio en el worker (issue #370), del token `projections` en `harness.config.json` (issue #369), del ruteo de `tipo:projection` (issue #372) y de los modulos Terraform de Container App del `infra-base-scaffolder` (issue #368, gating opt-in). **Enmienda MEF-ADR-0021** (infraestructura base). Cross-referencia MEF-ADR-0003 (stack ES Marten+Wolverine), MEF-ADR-0015 (snapshots como excepcion, mismo patron de "default vs excepcion justificada"), MEF-ADR-0020 (hosting de Functions, contraste de unidad de despliegue), MEF-ADR-0023/MEF-ADR-0024 (Bounded Context y topologia de Service Bus), MEF-ADR-0025 (custodia de secretos) y MEF-ADR-0029 (test de composicion del host, hermano directo del config-test que fija este ADR).

## Contexto

El marco materializa el write-side de cada dominio como una Function App con Marten como event store (MEF-ADR-0003): cada dominio persiste sus eventos en su propio schema, dentro de la unica base PostgreSQL compartida por el Bounded Context (MEF-ADR-0021, modulo `postgresql`, instanciado una sola vez por entorno). Hasta hoy el marco no tiene ninguna doctrina sobre como materializar **read models** -- proyecciones derivadas de esos eventos, pensadas para queries eficientes fuera del propio aggregate -- ni sobre donde corre el mecanismo que las mantiene actualizadas.

Marten resuelve la materializacion de proyecciones con dos ciclos de vida [1]: `Inline` (la proyeccion se actualiza en la misma sesion/transaccion que agrega el evento, sincronico con el escritor) y `Async` (un daemon separado, fuera del proceso que agrega el evento, procesa los eventos y actualiza la proyeccion de forma desacoplada). El daemon asincronico necesita un **proceso continuo** que lo mantenga corriendo -- no es un job de una sola invocacion. Las Function Apps del marco (Azure Functions, MEF-ADR-0020) estan optimizadas para invocaciones triggereadas (HTTP, Service Bus, timer), no para hostear un proceso de larga duracion: el patron correcto para un daemon continuo es un **worker .NET clasico** (`Microsoft.NET.Sdk.Worker`, `BackgroundService`/`IHostedService`), no una Function App.

El consumidor **Cosmos.ControlPlane** ya valido este patron en produccion: un worker `Cosmos.ControlPlane.Projections`, con un named store de Marten por dominio (`AddMartenStore<I{Dominio}ProjectionStore>`) que corre el daemon en modo `HotCold`, con los read models en un proyecto de biblioteca aparte (`Cosmos.ControlPlane.ReadModels`), desplegado como Azure Container App **sin ingress** (nadie le hace requests HTTP; solo lee eventos de Postgres y escribe proyecciones). Ese seam de composicion (`ConfiguracionMartenProjections`, PR 134 de ese consumidor) es la fuente de referencia de este ADR, igual que el patron de MEF-ADR-0032 (edge-auth) se fundo en codigo del mismo consumidor. **Nota de verificacion**: a diferencia de MEF-ADR-0032 (donde el codigo de ControlPlane fue inspeccionado directamente), este ADR no tuvo acceso directo al repositorio de ControlPlane -- los detalles citados provienen de la descripcion tecnica del issue #361. Cualquier divergencia frente al codigo real debe reconciliarse cuando el agente implementador (issue #367 y sucesores) lo inspeccione.

Adoptar Container Apps para el worker introduce infraestructura que el `infra-base-scaffolder` no genera hoy: MEF-ADR-0021 fija **8 modulos base** (`resource-group`, `monitoring`, `postgresql`, `service-bus`, `service-plan`, `storage`, `function-app`, `key-vault`); ninguno cubre un Container App, su entorno (`azurerm_container_app_environment`) ni el registro de contenedores del que extrae la imagen (`azurerm_container_registry`). Sin este ADR, no hay doctrina que fije la forma del worker, el ciclo de vida canonico de sus proyecciones, ni el contrato de esos 3 modulos Terraform nuevos -- y el `infra-base-scaffolder` (issue #368) no tiene contra que generarlos.

## Decision

### 1. Un worker de proyecciones por Bounded Context, no por dominio

El marco adopta **un unico worker .NET** (`<RootNamespace>.Projections`, `Microsoft.NET.Sdk.Worker`) **por Bounded Context** -- no uno por dominio -- que hostea el daemon asincronico de Marten para todos los dominios del BC. Es la misma logica de agrupacion que ya fija MEF-ADR-0023 para el namespace interno de Service Bus y el Key Vault del BC: una pieza de infraestructura compartida a nivel de BC, no replicada por dominio. Contrasta deliberadamente con MEF-ADR-0020 (un App Service Plan **por dominio** para las Function Apps del write-side): el write-side escala y se despliega por dominio porque cada Function App es una unidad de negocio independiente; el read-side, en cambio, es un unico proceso de infraestructura que agrega el trabajo de mantenimiento de proyecciones de todos los dominios del BC -- fragmentarlo por dominio multiplicaria por N el costo fijo de un Container App siempre encendido (seccion 8) sin ningun beneficio de aislamiento adicional (ese aislamiento ya lo da el named store, seccion 2).

### 2. Un named store por dominio, sobre el mismo Postgres del write-side; daemon `HotCold`

Dentro de ese unico worker, cada dominio del BC registra su propio **named store** de Marten -- el mecanismo de Marten para correr multiples `IDocumentStore` independientes en el mismo proceso, cada uno detras de una interfaz marcadora publica que extiende `IDocumentStore` [2]:

```csharp
public interface IVentasProjectionStore : IDocumentStore;

services.AddMartenStore<IVentasProjectionStore>(opts =>
{
    opts.Connection(martenConnectionString); // mismo secreto `marten-connection` del BC (MEF-ADR-0025)
    opts.DatabaseSchemaName = "ventas"; // mismo schema que ya usa el write-side de ese dominio (MEF-ADR-0003)
    // ... Events.MetadataConfig, Projections.Add<...>(ProjectionLifecycle.Async) -- ver seccion 3 y 7
})
.AddAsyncDaemon(DaemonMode.HotCold);
```

No hay una base de datos ni una connection string nueva por dominio: el named store del read-side apunta a la **misma** base PostgreSQL y al **mismo** schema que el write-side de ese dominio ya usa para su event store (MEF-ADR-0003, "nombre del schema de Marten para ese dominio"). El named store solo re-declara, del lado lectura, la conexion y el schema que el dominio ya posee del lado escritura. Por eso el worker reutiliza el secreto compuesto `marten-connection` que `infra-base-scaffolder` ya custodia en el Key Vault del BC (MEF-ADR-0025) -- no se crea ningun secreto nuevo.

El daemon corre en modo **`HotCold`** [1][3], no `Solo`: `HotCold` usa eleccion de lider sobre advisory locks de PostgreSQL para garantizar que cada proyeccion corre en exactamente un proceso activo -- la garantia correcta para un Container App que Azure puede, momentaneamente, correr con mas de una replica activa (durante un rolling deploy de una revision nueva, o si un consumidor decide escalar el worker por alta disponibilidad). `Solo` asume una unica instancia activa siempre y no protege contra procesamiento duplicado si esa asuncion deja de cumplirse.

### 3. `Async` es el ciclo de vida canonico; `Inline` es una excepcion opt-in que vive en el write-side, no en el worker

Marten permite registrar cada proyeccion como `Inline` (se actualiza en la misma sesion que agrega el evento, sincronico) o `Async` (el daemon la actualiza fuera de esa transaccion) [1]. Este ADR fija **`Async` como el ciclo de vida por defecto** de toda proyeccion de un dominio: se registra en el named store del worker de proyecciones (seccion 2), nunca en el write-side.

`Inline` es una **excepcion opt-in**, no un default alternativo -- mismo principio que MEF-ADR-0015 fija para los snapshots de Marten (una capacidad de la libreria que existe, pero que el marco no adopta por defecto sin justificacion): un dominio solo registra una proyeccion `Inline` cuando necesita **consistencia inmediata** de esa proyeccion especifica dentro del mismo request/mensaje que la genero (por ejemplo, un command handler que necesita leer el resultado ya proyectado antes de responder). Cuando esa necesidad exista, la proyeccion `Inline` se registra en la configuracion de Marten del **write-side** de ese dominio (`ComposicionServicios{Dominio}.cs`, MEF-ADR-0029) -- **nunca** ademas en el named store del worker de proyecciones. Una misma proyeccion nunca tiene doble registro (`Inline` en el write-side y `Async` en el worker a la vez): el daemon del worker reconstruiria la misma proyeccion por una segunda via, con doble costo y sin garantia de orden entre ambas escrituras.

### 4. El worker no toca Azure Service Bus

El daemon asincronico de Marten lee directamente los eventos ya persistidos en PostgreSQL -- no consume mensajes de ningun bus [1]. El worker de proyecciones, por tanto, **no** registra `IPrivateEventSender`/`IPublicEventSender` ni ningun wiring de Wolverine (MEF-ADR-0003), y no participa de ninguno de los namespaces de Service Bus del BC (MEF-ADR-0023/MEF-ADR-0024): su unica dependencia externa es la connection string de PostgreSQL. El futuro `projections-scaffolder` (issue #367) no debe generar ningun wiring de Service Bus para este worker -- seria infraestructura sin proposito, y una fuente de confusion sobre que parte del sistema consume eventos via bus (los dominios, MEF-ADR-0001/0023) y cual via lectura directa del event store (este worker).

### 5. Read models en un proyecto de biblioteca aparte

Los tipos de read model (los documentos que las proyecciones `Async` producen) y las clases de proyeccion viven en `<RootNamespace>.ReadModels`, una biblioteca de clases separada que el worker (`<RootNamespace>.Projections`) referencia -- misma separacion que valido el consumidor de referencia (`Cosmos.ControlPlane.ReadModels`). Este ADR fija solo la ubicacion del proyecto; el estilo de autoria de los read models y el diseno de las APIs de consulta sobre ellos son alcance del ADR de doctrina read-side (issue hermano #362), no de este documento.

### 6. Doctrina de config-test: guarda del `partial`, ciclo de vida `Async` y replica de metadata -- hermana de MEF-ADR-0029

MEF-ADR-0029 fija, para el write-side, un test de composicion que construye el `IServiceCollection` real y valida con `BuildServiceProvider(ValidateOnBuild, ValidateScopes)` que el grafo de DI arranca. El worker de proyecciones necesita su propio config-test, hermano de ese patron pero **no identico**: no valida un grafo de DI generico, sino la configuracion especifica de Marten que cada named store arma.

**La composicion es una fuente unica compartida entre `Program.cs` del worker y el test**, igual que MEF-ADR-0029 exige para el write-side: cada dominio contribuye su propio metodo de extension (`ConfiguracionMartenProjections{Dominio}.cs`, siguiendo el seam verificado en el consumidor de referencia) que registra su named store; `Program.cs` del worker invoca uno por dominio.

El config-test (`<RootNamespace>.Projections.Tests`) construye el `IServiceCollection` invocando esos mismos metodos de extension con una cadena de conexion dummy -- **sin necesidad de Postgres real**: verificado contra la documentacion oficial de Marten [4], desde Marten 7 el `DocumentStore` ya no se inicializa forzadamente durante el bootstrapping del `IHost` (para evitar IO sincronico ahi); la conexion se abre recien en la primera operacion real contra la base. El test resuelve cada named store y verifica tres cosas:

1. **Guarda del `partial`**: que el store de **cada** dominio conocido del BC efectivamente resuelve desde el contenedor. Un metodo `partial` sin implementacion no falla en tiempo de compilacion -- desaparece en silencio; si un dominio nuevo olvida su llamada de registro en `Program.cs` del worker, este test es el primero en notarlo (resolviendo `I{Dominio}ProjectionStore` y fallando si no esta registrado), en vez de descubrirlo cuando el daemon de ese dominio simplemente nunca corre en produccion.
2. **Ciclo de vida `Async`**: que ninguna proyeccion registrada en el named store del worker haya quedado con lifecycle `Inline` -- si aparece una `Inline` ahi, es una proyeccion mal ubicada (deberia vivir en el write-side, seccion 3) o una regresion de copy-paste.
3. **Replica exacta de la configuracion de metadata del write-side**: que `Events.MetadataConfig.CorrelationIdEnabled`/`CausationIdEnabled`/`HeadersEnabled` esten en `true` en el named store del worker, exactamente como en la configuracion Marten del write-side de ese mismo dominio (seccion 7) -- una divergencia entre ambos lados (p. ej. alguien habilita una columna nueva en el write-side y olvida replicarla aca) rompe la proyeccion en runtime con una excepcion de metadata ausente, no en el build.

El agente que implemente este test (issue #365, `projection-test-writer`) debe reverificar la superficie exacta de `StoreOptions.Projections` de la version vigente del paquete Marten contra la documentacion oficial antes de escribir el assert del punto 2 -- mismo principio de re-verificacion que MEF-ADR-0029 seccion 3 exige para tipos que puedan cambiar de forma entre versiones.

Este config-test **no sustituye** el test de composicion de MEF-ADR-0029 (que sigue viviendo en cada dominio, sobre su propio `ComposicionServicios{Dominio}.cs` del write-side) ni el DSL Given/When/Then de MEF-ADR-0002 (que sigue validando comportamiento de negocio del aggregate, no del read-side). Son tres categorias de test complementarias, cada una sobre una capa distinta.

### 7. Las columnas de metadata son requisito del writer, independiente de cualquier middleware de trazas

Para que el config-test de la seccion 6 tenga algo que replicar, el write-side de cada dominio debe habilitar explicitamente, en su propia configuracion de Marten (`ComposicionServicios{Dominio}.cs`), las tres columnas de metadata de evento que Marten deja deshabilitadas por defecto [5]:

```csharp
opts.Events.MetadataConfig.CorrelationIdEnabled = true;
opts.Events.MetadataConfig.CausationIdEnabled = true;
opts.Events.MetadataConfig.HeadersEnabled = true;
```

Verificado contra la documentacion oficial de Marten [5]: *"the database table columns for this data will not be created unless you opt-in"* -- sin este flag, la columna ni siquiera existe en la tabla de eventos, y ninguna proyeccion (`Inline` o `Async`) puede leer un `CorrelationId`/`CausationId`/header que nunca se persistio. Este es un requisito **del writer** (referencia: issues #116/#122 del consumidor, que lo introdujeron como necesidad de auditoria/correlacion de eventos), fijado aqui porque el config-test de la seccion 6 lo hace verificable, pero la habilitacion misma es responsabilidad de cada dominio en su propio write-side -- no de este worker, que solo lee lo que el writer ya persistio.

**Es independiente de cualquier middleware de propagacion de trazas.** Marten puede poblar `CorrelationId`/`CausationId` automaticamente a partir de un `Activity` de OpenTelemetry activo cuando existe uno, pero tambien permite asignarlos explicitamente -- verificado contra la documentacion oficial [5]: `theSession.CorrelationId = "..."; theSession.CausationId = "...";`, ademas de `session.SetHeader(...)` para `Headers`. La obligacion que fija este ADR es estructural (las tres columnas deben estar habilitadas en el schema del evento, siempre), no condicional a que el dominio tenga o no un middleware de trazas distribuidas instalado: un dominio sin ningun `Activity`/span activo igual debe habilitar las tres columnas, y puede poblar `CorrelationId`/`CausationId`/`Headers` explicitamente por asignacion directa en la sesion si no depende de OpenTelemetry para ese dato.

### 8. Despliegue como Container App sin ingress; enmienda de MEF-ADR-0021 (3 modulos opt-in)

El worker se despliega como **Azure Container App sin ingress**: nadie le hace requests HTTP ni TCP -- ninguna configuracion de ingress, dominio ni certificado aplica. Verificado contra la documentacion oficial de Azure Container Apps [6][7]: una Container App sin ingress puede correr un proceso continuo -- la guia oficial de background jobs lo fija explicitamente (*"For background tasks that run continuously, like a service that constantly processes messages from a queue, deploy a container app instead of a job"*), a diferencia de un Container Apps Job (pensado para tareas que terminan, no para un daemon que debe permanecer escuchando indefinidamente).

**Trampa verificada (mismo espiritu que el catalogo B1-B10 de MEF-ADR-0032): sin ingress, `min_replicas` debe ser >= 1.** La documentacion oficial de Azure Container Apps lo fija como advertencia explicita [8]: *"Make sure you create a scale rule or set minReplicas to 1 or more if you don't enable ingress. If ingress is disabled and you don't define a minReplicas or a custom scale rule, your container app scales to zero and has no way of starting back up."* Sin ingress no hay trafico HTTP que dispare un scale-out desde cero (la regla de escala por defecto es HTTP-based, minimo 0): un Container App de este worker con `min_replicas` en su default (`0`) y sin una regla de escala custom se apaga la primera vez que llega a cero replicas y **nunca vuelve a levantar** -- el daemon de proyecciones deja de correr sin ningun error visible, silenciosamente. El modulo `container-app` que fija este ADR **exige** `min_replicas >= 1` explicitamente, sin excepcion.

Esto exige **3 modulos Terraform nuevos** bajo `infra/modules/`, que no existen en el conjunto de 8 modulos base que fija MEF-ADR-0021:

| Modulo | Recursos | Inputs principales | Outputs | `prevent_destroy` |
|---|---|---|---|---|
| `container-registry` | `azurerm_container_registry` (SKU `Basic`) | `name`, `resource_group_name`, `location`, `tags` | `id`, `name`, `login_server` | no |
| `container-app-environment` | `azurerm_container_app_environment` | `name`, `resource_group_name`, `location`, `log_analytics_workspace_id`, `tags` | `id`, `name`, `default_domain` | no |
| `container-app` | `azurerm_container_app` (identidad `SystemAssigned`, **sin bloque `ingress`**, `min_replicas >= 1`) | `name`, `resource_group_name`, `container_app_environment_id`, `image`, `min_replicas`, `max_replicas`, `cpu`, `memory`, `env_vars`, `registry_server`, `tags` | `id`, `name`, `principal_id` | no |

`container-registry` y `container-app-environment` se instancian **una sola vez por entorno** (compartidos por todo el BC, igual que `postgresql`/`service-bus`/`key-vault` en el esqueleto de MEF-ADR-0021); `container-app` tambien se instancia **una vez** (un solo worker por BC, seccion 1) -- a diferencia de `function-app`, que el `domain-scaffolder` instancia una vez por dominio. Ningun modulo requiere `prevent_destroy`: a diferencia de PostgreSQL/Storage/Service Bus/Key Vault (que guardan estado que no se puede regenerar), un Container App y su registro de imagenes son recreables sin perdida de datos -- las proyecciones se reconstruyen desde los eventos ya persistidos en Postgres, que es lo unico con estado real.

La identidad administrada (`SystemAssigned`) del `container-app` recibe el mismo tipo de acceso de lectura al Key Vault del BC que ya reciben las Function Apps (MEF-ADR-0025), para leer `marten-connection` sin que la cadena viaje en texto plano por variables de entorno del Container App.

**Estos 3 modulos son opt-in, no parte incondicional de los 8 modulos base.** MEF-ADR-0021 fija los 8 modulos base que `infra-base-scaffolder` genera **siempre**; los 3 modulos de este ADR se generan **solo** cuando el BC declara que adopta el worker de proyecciones (mecanismo de deteccion: token `projections` en `harness.config.json`, a materializar por el issue #369 -- este ADR no lo fija, solo documenta que la generacion de esta infraestructura es condicional a el). El `infra-base-scaffolder` (issue #368) es el mismo agente que ya genera los 8 modulos base; estos 3 se suman a su alcance, gateados por ese token. Esto es lo que enmienda a MEF-ADR-0021: su contrato ("genera los 8 modulos base") sigue vigente sin cambios, pero deja de ser el limite superior de lo que ese agente puede generar.

## Alternativas consideradas

### Alt 1: proyecciones `Inline` para todo, sin worker ni daemon async

**Descartada**: acopla el costo de mantener cada read model al tiempo de respuesta del command handler que genera el evento (Function App con limites de ejecucion), y no permite reconstruir/recomputar proyecciones de forma independiente del write-side. El patron de referencia (Cosmos.ControlPlane) ya probo en produccion que `Async` + worker dedicado es el default correcto; `Inline` queda como excepcion (seccion 3).

### Alt 2: el worker como Azure Function con timer trigger que "bombea" el daemon periodicamente

**Descartada**: el async daemon de Marten esta disenado para correr como un proceso continuo con su propio ciclo de vida (`IHostedService`), no como una invocacion periodica corta -- una Function App con timer trigger reiniciaria el daemon en cada tick (perdiendo el estado de `HotCold`/eleccion de lider entre invocaciones) y quedaria sujeta a los limites de duracion de ejecucion de Functions. Un worker continuo es el modelo que la propia libreria asume.

### Alt 3: un worker de proyecciones por dominio, en vez de uno por BC

**Descartada** (seccion 1): multiplicaria por N dominios el costo fijo de un Container App siempre encendido (`min_replicas >= 1`), sin ningun beneficio de aislamiento adicional -- el daemon ya aisla cada dominio en su propio named store dentro del mismo proceso (seccion 2), y los recursos compartidos del BC (Postgres, Key Vault) ya son compartidos a ese mismo nivel (MEF-ADR-0023).

### Alt 4: Container Apps Job en vez de Container App continua

**Descartada**: un Container Apps Job corre hasta terminar y se detiene [7] -- pensado para tareas puntuales (migraciones, batch), no para un daemon que debe permanecer escuchando indefinidamente. El daemon asincronico de Marten no tiene un punto de "terminado" natural.

## Consecuencias

### Positivas

- **Un solo patron probado en produccion** (Cosmos.ControlPlane) para materializar read models, en vez de que cada consumidor reinvente su propio mecanismo.
- **Config-test barato** (segundos, sin Postgres real) detecta drift de metadata write-side/read-side y dominios sin registrar antes de que el daemon falle en produccion -- mismo beneficio de feedback loop que MEF-ADR-0029 documenta para el write-side.
- **Los 3 modulos de infraestructura son opt-in**: un BC que no necesita read models no paga el costo fijo de un Container App siempre encendido.
- **`Async` como default mantiene el write-side rapido** y desacoplado del costo de mantener proyecciones; `Inline` queda disponible como excepcion justificada, sin bloquear casos de consistencia inmediata.

### Negativas

- **Costo fijo continuo**: un Container App con `min_replicas >= 1` corre siempre, a diferencia de las Function Apps del write-side, que escalan a demanda -- aceptado porque un daemon de proyecciones no tiene un modelo de "invocacion" que active un cold start.
- **Tercera unidad de despliegue por BC** (ademas de N Function Apps y, opcionalmente, APIM) con su propio pipeline de imagen (Container Registry, build de imagen Docker) -- infraestructura que el marco no necesitaba antes de este ADR.
- **El seam de composicion compartido exige disciplina**, igual que MEF-ADR-0029: si alguien edita el named store del worker sin actualizar el config-test (o viceversa), el test puede quedar validando una configuracion que ya no es la real -- mismo riesgo que MEF-ADR-0029 ya documenta para su propio patron, mitigado por la misma fuente unica de verdad.
- **La implementacion concreta queda diferida**: el agente `projections-scaffolder`, la extension de `domain-scaffolder`, el token `projections` y los modulos Terraform reales son alcance de los issues listados en "Aplica a" -- este ADR fija la doctrina, no el codigo generado.

## Referencias

- **[1]** "Async Daemon" -- Marten docs (martendb.io): ciclos de vida `Inline`/`Async` de proyecciones, `AddAsyncDaemon(DaemonMode)` y modos `Solo`/`HotCold`; el daemon lee eventos ya persistidos en Postgres, no un bus de mensajeria. https://martendb.io/events/projections/async-daemon.html
- **[2]** Registro de multiples `IDocumentStore` con `AddMartenStore<T>` y una interfaz marcadora publica que extiende `IDocumentStore`, cada uno con su propia connection string/schema y su propio `AddAsyncDaemon` independiente -- `JasperFx/marten` (`src/CoreTests/Examples/MultipleDocumentStores.cs`) y Jeremy D. Miller, "Working with Multiple Marten Databases in One Application" (jeremydmiller.com, 2022-03-29). https://github.com/JasperFx/marten/blob/master/src/CoreTests/Examples/MultipleDocumentStores.cs
- **[3]** "HotCold mode ensures that each projection is running on exactly one running process" -- Marten docs (async daemon, modos `Solo`/`HotCold`, eleccion de lider sobre advisory locks de PostgreSQL). https://martendb.io/events/projections/async-daemon.html
- **[4]** "Bootstrapping Marten" -- Marten docs: *"as of Marten 7, it is no longer possible to force the DocumentStore to be initialized during IHost bootstrapping... to avoid using any synchronous IO during bootstrapping"* -- la conexion se abre en el primer uso real, no al registrar/resolver el store. https://martendb.io/configuration/hostbuilder
- **[5]** "Working with Event Metadata" -- Marten docs: `Events.MetadataConfig.{CorrelationIdEnabled,CausationIdEnabled,HeadersEnabled}`, deshabilitadas por defecto (*"the database table columns for this data will not be created unless you opt-in"*), poblacion automatica desde un `Activity` de OpenTelemetry activo, y asignacion manual (`theSession.CorrelationId = ...`, `theSession.CausationId = ...`, `session.SetHeader(...)`). https://martendb.io/events/metadata.html
- **[6]** "Ingress in Azure Container Apps" -- Microsoft Learn: habilitar/deshabilitar ingress por Container App; sin ingress, la app no es alcanzable por HTTP/TCP externo. https://learn.microsoft.com/azure/container-apps/ingress-overview
- **[7]** "Recommendations for developing background jobs" -- Microsoft Learn (Azure Well-Architected Framework): *"For background tasks that run continuously, like a service that constantly processes messages from a queue, deploy a container app instead of a job"* -- contraste Container App continua vs Container Apps Job (tarea que termina). https://learn.microsoft.com/azure/well-architected/design-guides/background-jobs
- **[8]** "Set scaling rules in Azure Container Apps" -- Microsoft Learn: *"Make sure you create a scale rule or set minReplicas to 1 or more if you don't enable ingress. If ingress is disabled and you don't define a minReplicas or a custom scale rule, your container app scales to zero and has no way of starting back up."* https://learn.microsoft.com/azure/container-apps/scale-app
- MEF-ADR-0003 (stack ES Marten+Wolverine): el schema de Marten por dominio que este ADR reutiliza para el named store del read-side; origen de `IPublicEventSender`/`IPrivateEventSender`, que este worker deliberadamente no usa (seccion 4).
- MEF-ADR-0015 (snapshots de Marten como excepcion): mismo principio de "default vs excepcion justificada" que este ADR aplica a `Async` vs `Inline` (seccion 3).
- MEF-ADR-0020 (un App Service Plan por dominio): contraste de unidad de despliegue -- el write-side escala por dominio, el worker de proyecciones es una unica pieza por BC (seccion 1).
- MEF-ADR-0021 (infraestructura base, 8 modulos): **enmendado por este ADR** -- los 3 modulos de Container App (seccion 8) son opt-in, generados por el mismo `infra-base-scaffolder`, sin alterar el contrato incondicional de los 8 modulos base.
- MEF-ADR-0023/MEF-ADR-0024 (Bounded Context, topologia de Service Bus): el worker vive en el resource group del BC (MEF-ADR-0023) pero no participa de ninguno de los namespaces de Service Bus que esos ADRs fijan (seccion 4).
- MEF-ADR-0025 (custodia de secretos): el named store del worker reutiliza el secreto compuesto `marten-connection` ya custodiado en el Key Vault del BC; su identidad administrada recibe el mismo patron de acceso de lectura que las Function Apps.
- MEF-ADR-0029 (test de composicion del contenedor DI del host): patron hermano directo del config-test que fija la seccion 6 de este ADR -- misma filosofia (fuente unica compartida entre `Program.cs` y el test), aplicada a una superficie distinta (configuracion de Marten, no grafo generico de DI).
- Issue #361 (este ADR) y sus issues consumidores directos: #362 (doctrina read-side de autoria y query APIs, explicitamente fuera de alcance aqui), #364 (skill `/scaffold-projections`), #365 (agentes `projection-test-writer`/`projection-implementer`), #366 (receta del planner para `tipo:projection`), #367 (agente `projections-scaffolder`), #368 (modulos Terraform de Container App en `infra-base-scaffolder`, gating opt-in), #369 (token `projections` en `harness.config.json`), #370 (registro del store de cada dominio en `domain-scaffolder`), #372 (enrutamiento `tipo:projection`), #374 (skills en `reviewer`/`smoke-test-writer`), #375 (extension del scaffolder para `ReadModels`/`Projections.Tests`).
- Cosmos.ControlPlane: `Cosmos.ControlPlane.Projections` (worker, seam `ConfiguracionMartenProjections`, PR 134) y `Cosmos.ControlPlane.ReadModels` -- consumidor de referencia que valido este patron en produccion, mismo rol que jugo para MEF-ADR-0032 (edge-auth). Ver nota de verificacion en "Contexto": los detalles citados provienen de la descripcion del issue #361, no de inspeccion directa del codigo.

## Control de cambios

- 2026-07-26: creacion como `aceptado` (issue #361). Fija el worker de proyecciones por Bounded Context (Container App sin ingress, named store por dominio, daemon `HotCold`), `Async` como ciclo de vida canonico (`Inline` como excepcion opt-in registrada en el write-side), la doctrina de config-test hermana de MEF-ADR-0029, y el requisito estructural de las columnas de metadata de evento independiente de cualquier middleware de trazas. Enmienda MEF-ADR-0021 sumando 3 modulos Terraform opt-in (`container-registry`, `container-app-environment`, `container-app`).

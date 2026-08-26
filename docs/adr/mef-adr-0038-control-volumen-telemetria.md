# MEF-ADR-0038: Control de volumen de telemetria

- **Fecha**: 2026-08-04
- **Estado**: aceptado
- **Aplica a**: los seams de observabilidad que `domain-scaffolder` genera para el write-side
  (`Program.cs`, `host.json`, el callback de `AgregarWolverineParaComandosServerless`) y que
  `projections-scaffolder` genera para el read-side (`ConfiguracionObservabilidadProjections`,
  MEF-ADR-0034 seccion 10). Fija la doctrina; la propagacion al codigo generado por esos agentes es
  alcance de los issues #511 (orden del sampler en `domain-scaffolder`), #512 (durability metrics
  off en `domain-scaffolder`), #513 (sampler del worker en `projections-scaffolder`) y #514
  (chequeos del reviewer) -- este ADR no toca ningun agente. Muda integramente la seccion
  "Observabilidad" de MEF-ADR-0003 (que queda como referencia, sin doctrina duplicada) y enmienda
  MEF-ADR-0034 (seccion 10 punto 4, y la aceptacion del costo del Container App 24/7). Cross-referencia
  MEF-ADR-0015 (precedente de delegacion mecanismo-del-marco/valor-del-consumidor), MEF-ADR-0018
  (heuristica de "unico proceso con daemon", que hace exclusivo del worker el filtro de la seccion 5),
  MEF-ADR-0029 (guardrails de composicion, tecnica que sostiene la seccion 4) y MEF-ADR-0030 (esquema
  de numeracion con prefijo).

## Contexto

Este ADR nacio como draft del refinamiento de #457 (seam de observabilidad del worker de
proyecciones), que decidio no instalar ningun sampler en ese seam y fijo el criterio: si el marco
llega a tener una MEF-ADR de observabilidad, que nazca con este issue (ver MEF-ADR-0034 seccion 10
punto 4, version previa a esta enmienda). La evidencia de campo del consumidor
Bitakora.ControlAsistencia confirmo la necesidad y amplio el alcance: el problema no es solo
"sampling" -- es **control de volumen de telemetria**, y los tres defectos que ese consumidor
encontro son propiedades del stack que el marco elige y scaffoldea, no fallas de su dominio:

1. **El sampler configurado nunca se instala.** Si `SetSampler` se encadena antes de
   `UseAzureMonitorExporter()`, el exporter (`Azure.Monitor.OpenTelemetry.Exporter` 1.8.x) llama
   internamente `SetSampler(new RateLimitedSampler(TracesPerSecond: 5.0))` y pisa el del consumidor
   sin avisar. Es una falla silenciosa: compila, pasa los tests, se despliega, y sobrevivio dos
   meses en produccion antes de detectarse.
2. **El daemon `HotCold` del worker de proyecciones es la mayoria del ruido read-side.** MEF-ADR-0034
   acepto el costo de **compute** de un Container App 24/7 (`min_replicas >= 1`, seccion 8 de ese
   ADR) pero nunca evaluo el costo de **ingesta** de telemetria de ese mismo proceso siempre
   encendido.
3. **El durability agent de Wolverine es la mayoria del ruido write-side.** `FetchCountsAsync()`
   corre cada 5 segundos por dominio y genera metricas que ningun dashboard ni alerta consume.
   Apagable en origen con una linea, sin perder ninguna senal en uso.

Ademas, el `host.json` que `domain-scaffolder` genera para el write-side conserva un bloque
`logging.applicationInsights.samplingSettings` que es **inerte** bajo `telemetryMode: "OpenTelemetry"`
(MEF-ADR-0003, seccion "Observabilidad", mudada integra a este ADR en la seccion 2) -- un bloque de
JSON no admite comentarios que digan "esto no hace nada", y ese silencio se lee como si el bloque
filtrara de verdad.

## Evidencia de campo (Bitakora.ControlAsistencia)

Bitakora.ControlAsistencia investigo y corrigio los tres defectos en su propio repositorio, con
verificacion por decompilacion, reproduccion en runtime y mutation testing:

- **Issue #308** (read-side + sampler nunca instalado): de la ingesta total de telemetria del
  consumidor, el **84%** era polling, no trabajo de negocio. Desglosado por proceso: el daemon
  `HotCold` del worker de proyecciones genero **68.977 de 72.242 spans/dia** contra Postgres bajo el
  nombre `marten.daemon.highwatermark`, frente a **~118 spans** de proyeccion real -- **95% del
  volumen read-side es el propio polling del daemon**. La causa raiz del sampler nunca instalado
  (`SetSampler` pisado por `UseAzureMonitorExporter()`) se verifico decompilando
  `Azure.Monitor.OpenTelemetry.Exporter` 1.8.1 (`OpenTelemetryBuilderExtensions.UseAzureMonitorExporter`).
  Resuelto en el **PR #311** (mergeado 2026-08-04).
- **Issue #309** (write-side, durability agent): el **56%** del polling write-side era
  `FetchCountsAsync()` de Wolverine -- 4 consultas cada 5 segundos por dominio (17.280 invocaciones/dia,
  86.400s/dia / 5s), es decir **69.120 spans/dia por dominio** sin ningun consumidor de esa metrica.
  Verificado decompilando `Wolverine` 6.16.0 / `Cosmos.EventSourcing.CritterStack` 2.3.1 para
  confirmar que el callback de configuracion corre **antes** de que CritterStack fije `Mode = Solo`
  -- la bandera `DurabilityMetricsEnabled` sobrevive esa asignacion posterior, `Mode` no. Resuelto en
  el **PR #312** (mergeado 2026-08-04).

Ambos PRs verificaron ademas, por lectura de fuente de OpenTelemetry, la cascada de decision de
`ParentBasedSampler` (delega a `PropagateOrIgnoreData`/`RecordOnly` sobre el span padre) que hace
`ParentBased` obligatorio para que un span en `Drop` en la raiz efectivamente evite que Marten
instancie el span hijo de Npgsql -- un `Sampler` plano sin ese envoltorio no logra el mismo efecto
(verificado empiricamente por el consumidor: con `Drop` en el span raiz sin `ParentBased`, el hijo
Npgsql se instancia igual).

El `CA-ADR-0009` (control de costos) de ese consumidor es el precedente que motivo la investigacion;
este ADR generaliza sus hallazgos como doctrina del marco para que ningun otro consumidor tenga que
redescubrirlos.

## Decision

### 1. Frontera: el marco garantiza el mecanismo; el consumidor decide el valor

El marco genera, por defecto, **el wiring correcto** (orden de composicion, seccion 3), **los
filtros de ruido en origen** (secciones 5 y 6) y **el desacople de los logs de la decision de
muestreo de trazas** (seccion 9) sin que ningun consumidor tenga que pedirlos. Lo que el marco
**no** fija es el **valor del ratio de sampling** (`TELEMETRY_SAMPLING_RATIO`) ni **el nivel de
`ILogger`** que decide que logs existen antes de que este seam los vea (seccion 9): son politica de
costos propia de cada consumidor.

El **default del marco es `1.0`** (sin descartar ningun span por ratio, solo los filtros
estructurales de las secciones 5/6 siguen activos) cuando esa variable no esta declarada. La
alternativa de un default fraccionario (p. ej. `0.2`) es deliberadamente rechazada para greenfield:
con un ratio menor a 1.0 desde el primer despliegue, "no veo mi span en Application Insights" queda
ambiguo entre dos causas indistinguibles para quien recien esta iterando -- el wiring esta roto, o el
muestreo tuvo mala suerte con ese trace puntual. `1.0` elimina esa ambiguedad en el momento en que
mas se necesita diagnosticar: la primera integracion. Un consumidor que ya paso ese punto y quiere
reducir costo de ingesta declara `TELEMETRY_SAMPLING_RATIO` con el valor que decida.

### 2. Wiring base de OpenTelemetry (mudado de MEF-ADR-0003)

Esta seccion era, hasta este ADR, la seccion "Observabilidad" de MEF-ADR-0003; se muda aqui
integra porque este ADR es ahora el punto unico de doctrina de observabilidad del marco (criterio
fijado al abrir el draft de este issue durante el refinamiento de #457). MEF-ADR-0003 conserva solo
una referencia, sin duplicar el contenido.

Se configura OpenTelemetry con `AddSource` para `"Wolverine"`, `"Marten"` y el namespace del
dominio, en lugar del SDK propietario de ApplicationInsights. Para Azure Functions en modo worker
aislado no existe una ingesta automatica del host: sin un exporter explicito, OpenTelemetry recolecta
esos traces/metrics/logs y los descarta, y a Application Insights solo llegan los `requests` que
emite el propio host. El camino oficial (Microsoft Learn, "Use OpenTelemetry with Azure Functions" --
el Azure Monitor OpenTelemetry Exporter es el metodo **recomendado** para apps nuevas y existentes,
ver "Monitor executions in Azure Functions") exige tres piezas:

1. El trio de paquetes `Microsoft.Azure.Functions.Worker.OpenTelemetry`, `OpenTelemetry.Extensions.Hosting`
   y `Azure.Monitor.OpenTelemetry.Exporter` (tabla de paquetes de MEF-ADR-0003) -- no
   `Azure.Monitor.OpenTelemetry.AspNetCore` (la distro de ASP.NET Core, no soportada para Functions
   isolated worker: trae `AspNetCoreInstrumentation` y duplica la telemetria de requests que el host
   de Functions ya emite).
2. En `Program.cs`, encadenar `.UseFunctionsWorkerDefaults()` y `.UseAzureMonitorExporter()` sobre
   `AddOpenTelemetry()`, junto al `.WithTracing(...).AddSource(...)` de siempre.
3. En `host.json`, `"telemetryMode": "OpenTelemetry"` en la raiz, para que el host tambien emita
   OpenTelemetry y se correlacione con el worker.

El exporter lee `APPLICATIONINSIGHTS_CONNECTION_STRING` (no soporta instrumentation key); ese valor
lo provee el `site_config.application_insights_connection_string` del modulo Terraform `function-app`
(MEF-ADR-0021), como referencia `@Microsoft.KeyVault(...)` versionless (MEF-ADR-0025).

**Nota de compatibilidad de versiones (issue #263):** `Microsoft.Azure.Functions.Worker.OpenTelemetry`
1.2.0 exige `Microsoft.Azure.Functions.Worker.Core >= 2.52.0` (nuspec del paquete, api.nuget.org). Por
eso el metapaquete `Microsoft.Azure.Functions.Worker` se fija explicitamente en `2.52.0` (tabla de
paquetes de MEF-ADR-0003): si queda en una version menor -- por ejemplo la que trae por defecto una
plantilla `func init` desactualizada --, `Worker.Core` sube a esa version minima por resolucion
transitiva pero `Worker.Grpc` puede quedar rezagado, y el desalineamiento entre ambos dispara
`MissingMethodException` en `DefaultTraceContext..ctor` al arrancar el host -- HTTP 500 en toda
funcion del dominio (verificado por el consumidor Cosmos.ControlPlane, PR #46).

### 3. Orden del wiring: `SetSampler` siempre despues de `UseAzureMonitorExporter()`

El defecto raiz del sampler que nunca se instala (ver "Contexto", punto 1) es de **orden**, no de
API: `UseAzureMonitorExporter()` (`Azure.Monitor.OpenTelemetry.Exporter` 1.8.x) llama internamente
`SetSampler(new RateLimitedSampler(TracesPerSecond: 5.0))` sobre el mismo `TracerProviderBuilder` --
verificado por decompilacion del consumidor (issue #308, PR #311). `SetSampler` no acumula: la ultima
llamada gana. Si el codigo del dominio encadena su propio `SetSampler` **antes** de
`.UseAzureMonitorExporter()` (el orden que parece natural leyendo de arriba a abajo), el exporter lo
sobreescribe sin ninguna advertencia -- ni en build, ni en tests, ni en logs de arranque.

El fix es encadenar un **segundo** `.WithTracing(...)` **despues** de `.UseAzureMonitorExporter()`,
para ambos lados del marco (write-side y read-side):

```csharp
services.AddOpenTelemetry()
    .ConfigureResource(r => r.AddService(nombreDelServicio))
    .WithTracing(tracing => tracing
        .AddSource("Wolverine")
        .AddSource("Marten")
        .AddSource(nombreDelDominio))
    .UseAzureMonitorExporter()
    .WithTracing(tracing => tracing
        .SetSampler(/* seccion 5 (read-side) o seccion 6 (write-side) */));
```

El snippet ilustra **unicamente el orden**: el contenido del primer `.WithTracing(...)` y del
`ConfigureResource(...)` **no** es identico en los dos lados y no debe copiarse literal de aqui -- el
write-side no configura `service.name` explicitamente y registra `Wolverine`/`Marten` (seccion 2),
mientras el worker de proyecciones si lo configura y registra `Marten`/`Npgsql`/su propia fuente
(MEF-ADR-0034 seccion 10, asimetria deliberada). Lo unico que este ADR fija para ambos lados es que
el `.SetSampler(...)` viaje en un segundo `.WithTracing(...)` posterior a
`.UseAzureMonitorExporter()`.

Este orden **no es contrato publico del paquete**: `Azure.Monitor.OpenTelemetry.Exporter` no
documenta ni promete que `UseAzureMonitorExporter()` fije un sampler propio -- es un detalle de
implementacion observado por decompilacion en la version pinneada (1.8.x, MEF-ADR-0003). Una version
futura del paquete podria dejar de hacerlo, o hacerlo de otra forma, sin que eso sea un breaking
change segun su propio versionado semantico. Por eso este ADR no se apoya solo en "encadenar en el
orden correcto una vez" -- fija ademas un guardrail que lo verifica en cada build (seccion 4).

### 4. Guardrail de composicion: el orden no es contrato del paquete, la verificacion es determinista

Como el orden de la seccion 3 depende de un detalle de implementacion no documentado del paquete,
la garantia de que sigue vigente no puede ser "nadie lo cambio a mano" -- tiene que ser un test que
falle solo si el sampler efectivamente instalado deja de ser el que el marco pretende, sin importar
si la regresion la introduce un desarrollador o un upgrade de paquete.

La tecnica, hermana del test de composicion de MEF-ADR-0029 (mismo principio: construir el grafo
real y verificarlo, no confiar en que "se ve bien" en el codigo): tras invocar el seam de composicion
con `BuildServiceProvider`, resolver el `TracerProvider` y usar reflection para leer su propiedad
interna `Sampler` (`TracerProviderSdk.Sampler`, tipo interno del SDK de OpenTelemetry -- no hay API
publica que lo exponga directamente) y comparar su `Sampler.Description` (propiedad **publica**)
contra el valor esperado. `Description` de un `TraceIdRatioBasedSampler` embebe el ratio en el propio
texto (p. ej. `"TraceIdRatioBasedSampler{1}"`); si el exporter pisara el sampler del marco con su
`RateLimitedSampler`, la `Description` resuelta seria otra, y el guardrail lo detecta sin necesidad de
desplegar nada ni de inspeccionar Application Insights.

El **texto exacto** de `Description` depende de la composicion: un `ParentBasedSampler` que envuelve
al de ratio compone su propia descripcion a partir de la del hijo, y el filtro de la seccion 5 suma
otra capa. Asi que el guardrail debe fijar el valor esperado **reverificado por ejecucion contra la
version pinneada del SDK**, no de memoria: el literal de arriba ilustra el principio (el ratio viaja
en el texto, por eso `Description` alcanza para distinguir un sampler de otro), no es una cadena que
este ADR haya verificado.

**El borde critico a verificar es el default**, no un valor arbitrario: el guardrail debe correr
exactamente en el camino que se ejecuta cuando `TELEMETRY_SAMPLING_RATIO` **no** esta declarada (el
estado de cualquier consumidor nuevo, y el mas comun en produccion para quien nunca toco la variable)
-- es el camino de mayor probabilidad de regresion silenciosa, porque es el que menos se ejercita
manualmente.

### 5. Read-side: sampler que filtra el polling del daemon en origen

Exclusivo del worker de proyecciones (MEF-ADR-0034): es, por diseno del marco, el **unico proceso
con un daemon asincronico corriendo** -- ninguna Function App del write-side tiene un equivalente,
asi que ningun otro proceso necesita este filtro, y generalizarlo a los dos lados seria abstraer un
mecanismo para un solo sitio de uso (heuristica de MEF-ADR-0018).

El wiring de la seccion 3, para este lado, encadena:

```csharp
.WithTracing(tracing => tracing
    .SetSampler(new FiltroPollingDaemonSampler(
        interno: new ParentBasedSampler(new TraceIdRatioBasedSampler(ratio)))));
```

`FiltroPollingDaemonSampler` (nombre ilustrativo -- la clase real es alcance de #513) es el sampler
**mas externo**: descarta por nombre el span de polling del daemon (`marten.daemon.highwatermark`, la
actividad medida en el 95% del volumen read-side, ver "Evidencia de campo") y delega todo lo demas al
`ParentBasedSampler(TraceIdRatioBasedSampler(ratio))` interno. El filtro va afuera y no como
`rootSampler` de un `ParentBasedSampler` externo: `ParentBasedSampler` consulta su `rootSampler`
**solo para spans sin padre**, asi que invertir el anidamiento dejaria fuera del filtro cualquier span
de polling que llegara colgado de otro span.

**`ParentBased` es esencial, no un envoltorio decorativo**: verificado empiricamente por el
consumidor (issue #308) -- sin el como delegado interno, un `Sampler` plano que devuelve `Drop` para
el span raiz del daemon no evita que Marten instancie de todas formas el span hijo de la consulta
Npgsql subyacente; solo `ParentBasedSampler` propaga la decision `Drop` del padre al hijo antes de que
este se cree (cascada `PropagateOrIgnoreData` de OpenTelemetry). Sin `ParentBased`, el filtro por
nombre elimina el span visible pero no el ruido real -- el hijo Npgsql sigue generandose y
facturandose igual.

### 6. Write-side: sampler de solo ratio, y durability agent de Wolverine apagado en origen

**El sampler del write-side es unicamente la capa de ratio.** Cada Function App instala
`ParentBasedSampler(new TraceIdRatioBasedSampler(ratio))` -- el mismo `ratio` leido de
`TELEMETRY_SAMPLING_RATIO` con default `1.0` (seccion 1), encadenado con el orden de la seccion 3 --
y **no** el filtro por nombre de la seccion 5: ninguna Function App corre un daemon, asi que no hay
span de polling que descartar (de ahi que ese filtro sea exclusivo del worker). El envoltorio
`ParentBasedSampler` se conserva en este lado por **simetria de doctrina** -- una sola forma de
sampler en los dos lados, que difieren solo en el filtro exclusivo del worker -- y para no
contradecir aguas abajo la decision de muestreo de un trace que el host de Functions ya inicio (el
span de `request`) antes de que el worker aislado componga su propio `TracerProvider`. A diferencia
del read-side, **aqui el envoltorio no lo sostiene ninguna medicion de campo**: es una decision de
consistencia de este ADR, no un hallazgo verificado.

**El durability agent se apaga en origen, no se muestrea despues.** El durability agent
(`FetchCountsAsync()`, medido en el 56% del ruido write-side, ver "Evidencia de campo") no tiene
ningun consumidor de sus metricas hoy -- ni dashboard, ni alerta. Recortar en origen evita generar el
span y facturar su ingesta, mientras que muestrear solo reduce cuantos de esos spans ya generados se
exportan.

El punto de wiring es el callback de configuracion de `AgregarWolverineParaComandosServerless`
(MEF-ADR-0003 seccion "Patron de configuracion en Program.cs"):

```csharp
builder.Services.AgregarWolverineParaComandosServerless(
    typeof(IDominioAssemblyMarker).Assembly,
    martenConnectionString,
    "nombre_schema",
    builder.Environment.IsDevelopment(),
    options =>
    {
        options.Durability.DurabilityMetricsEnabled = false;
        options.HabilitarAzureServiceBusParaServerLess(serviceBusConnectionString);
        options.PublicarEventoServerless<MiEvento>("eventos-dominio");
    });
```

**El orden dentro de ese callback importa por una razon distinta a la de la seccion 3**: verificado
por decompilacion del consumidor (`Wolverine` 6.16.0 / `Cosmos.EventSourcing.CritterStack` 2.3.1,
issue #309, PR #312), este callback corre **antes** de que `Cosmos.EventSourcing.CritterStack` fije
`Mode = Solo` (el modo serverless del marco, MEF-ADR-0003). `DurabilityMetricsEnabled` es una bandera
independiente de `Mode`: se fija dentro del callback y sobrevive la asignacion posterior de `Mode`
que hace el paquete -- a diferencia de otras opciones de `Durability` que si dependen del `Mode`
resultante y que este ADR no toca.

### 7. `host.json`: eliminar el bloque inerte de `samplingSettings`

El `host.json` que `domain-scaffolder` genera conserva, hasta este ADR, un bloque
`logging.applicationInsights.samplingSettings`. Verificado contra la documentacion oficial de Azure
Functions ("Monitor executions in Azure Functions", MEF-ADR-0003 seccion "Observabilidad"): *"If you
set telemetryMode to OpenTelemetry, the configuration in the logging.applicationInsights section of
host.json doesn't apply"* -- con `telemetryMode: "OpenTelemetry"` en la raiz (seccion 2, punto 3),
ese bloque nunca filtra nada.

JSON no admite comentarios que digan "este bloque no hace nada": un bloque muerto que se lee como
vivo es deuda de diagnostico -- alguien que ajuste `samplingSettings` esperando reducir volumen no
va a ver ningun efecto, y va a perder tiempo antes de descubrir por que. Se elimina del scaffold. La
explicacion de por que no se necesita (el sampler real vive en `Program.cs`, secciones 3/5/6, no en
`host.json`) queda documentada aqui y debe quedar tambien en el agente que genere el archivo
(`domain-scaffolder`, issue #511).

### 8. Costo asumido: `TraceIdRatioBasedSampler` no extrapola conteos en Application Insights

`TraceIdRatioBasedSampler` (el sampler que las secciones 5/6 usan como capa de ratio) no escribe el
atributo `sampleRate` en los spans que deja pasar -- verificado por lectura de fuente de OpenTelemetry
por el consumidor (issues #308/#309). Sin ese atributo, Application Insights **no extrapola** los
conteos de la muestra al total real: un `ratio` de `0.2`, por ejemplo, no hace que Application
Insights multiplique por 5 los conteos observados para estimar el volumen real -- los conteos
mostrados quedan **subcontados** frente al trafico real.

La alternativa que si escribe `sampleRate` y permite esa extrapolacion, `ApplicationInsightsSampler`
(del propio SDK de Azure Monitor), es una clase **`internal`** del paquete -- no instanciable ni
componible desde el codigo del marco, y por tanto tampoco componible con el filtro por nombre de la
seccion 5 (`FiltroPollingDaemonSampler` necesita envolver un `Sampler` que el marco pueda instanciar).
Este ADR **acepta la subcuenta** como costo del control de volumen: es preferible un conteo
subestimado y consistente a no tener ningun control de volumen porque la unica alternativa que
extrapola no es componible con el resto de la doctrina de este ADR.

### 9. Read-side: logs de error desacoplados del sampler de trazas (`EnableTraceBasedLogsSampler`)

Exclusivo del worker de proyecciones, mismo alcance que la seccion 5: el filtro de esa seccion
resuelve el volumen de **trazas** del polling del daemon, pero deja un efecto colateral no evaluado
hasta ahora sobre los **logs** -- llamadas a `ILogger` emitidas mientras un span descartado esta
activo.

`Azure.Monitor.OpenTelemetry.Exporter` (`UseAzureMonitorExporter()`) expone
`AzureMonitorExporterOptions.EnableTraceBasedLogsSampler`, con default `true` -- verificado por
lectura de fuente publica de la version pinneada por este agente (`AzureMonitorExporterOptions.cs`,
tag `Azure.Monitor.OpenTelemetry.Exporter_1.8.3`, github.com/Azure/azure-sdk-for-net; mismo default
confirmado en la 1.8.1 que decompilo originalmente el consumidor, issue #414 de
Bitakora.ControlAsistencia -- el defecto no se corrigio entre versiones). Con ese default,
`ExporterRegistrationHostedService.Initialize` instala `LogFilteringProcessor` -- una subclase de
`BatchLogRecordExportProcessor` -- en vez de un `BatchLogRecordExportProcessor` plano:

```csharp
BaseProcessor<LogRecord> baseProcessor = exporterOptions.EnableTraceBasedLogsSampler
    ? new LogFilteringProcessor(exporter)
    : new BatchLogRecordExportProcessor(exporter);
```

Y `LogFilteringProcessor.OnEnd` solo reenvia el `LogRecord` al exporter si `logRecord.SpanId ==
default || logRecord.TraceFlags == ActivityTraceFlags.Recorded` -- descarta en silencio cualquier
log emitido mientras el span activo tiene padre y no quedo `Recorded`. Ese es exactamente el caso
del span de polling del daemon que la seccion 5 descarta (`SamplerQueDescartaPollingDelDaemon` ->
`Drop`): `HighWaterAgent` (JasperFx) emite sus `LogError` **dentro** de ese span, asi que esos
`LogRecord` heredan su `SpanId`/`TraceFlags` no grabados y `LogFilteringProcessor` los descarta antes
de que lleguen a `exceptions` -- se pierden enteros, no truncados.

**Evidencia de campo (Bitakora.ControlAsistencia, falla inducida, Postgres detenido ~14 min, issue
#680):**

| Familia de error | Consola | `exceptions` | Tasa |
|---|---|---|---|
| `Error trying to attain a lock...` | 87 | 87 | 100% (1:1) |
| `Failed while trying to detect high water statistics...` | 35 | 0 | **0%** |

Ambas familias las emite el mismo `HighWaterAgent`, con el mismo nivel de log -- la unica diferencia
es que la segunda ocurre con el span de polling del daemon activo (y descartado) como padre; la
primera no. El sampler de trazas de la seccion 5 se escribio para recortar costo de **trazas** y
termina, como efecto colateral no evaluado hasta este issue, suprimiendo **logs de error** -- justo
la senal de fondo que la alerta `exception_spike` (modulo `monitoring` de `infra-base-scaffolder`)
existe para ver.

**Decision: el seam desactiva el flip.** El punto de wiring es el mismo `UseAzureMonitorExporter()`
de la seccion 3, con su overload de opciones -- ya publico en el paquete, sin mecanismo ni paquete
nuevo:

```csharp
services.AddOpenTelemetry()
    .ConfigureResource(...)
    .WithTracing(...)
    .UseAzureMonitorExporter(o => o.EnableTraceBasedLogsSampler = false)
    .WithTracing(tracing => tracing.SetSampler(/* seccion 5 */));
```

Con el flip en `false`, `ExporterRegistrationHostedService` instala un `BatchLogRecordExportProcessor`
plano: ningun `LogRecord` se descarta por la decision de muestreo de su span padre -- los logs quedan
gobernados unicamente por el nivel de `ILogger` antes de que este seam los vea.

**Extension de la frontera mecanismo/valor (seccion 1).** Este flip es **mecanismo del marco**, no
opt-in -- misma clase que el filtro de la seccion 5, y por la misma razon (MEF-ADR-0018: unico
proceso con daemon, el unico donde este acoplamiento logs-trazas produce perdida real): ningun
consumidor deberia tener que pedirlo, y ninguno deberia poder revertirlo declarando una opcion. Lo
que **si** sigue siendo valor del consumidor son dos ejes ahora independientes entre si: el ratio de
trazas (`TELEMETRY_SAMPLING_RATIO`, seccion 1, sin cambios -- el flip no toca la decision de muestreo
de trazas, solo si los logs la heredan) y el nivel de `ILogger` (filtering estandar de .NET), que a
partir de este flip es el **unico** control de volumen de logs que le queda al consumidor.

**Por que el volumen no se dispara con los defaults del canon.** Con `TELEMETRY_SAMPLING_RATIO=1.0`
(default, seccion 1) y `ILogger` en `Information` (default de la plantilla `dotnet new worker`), el
flip apenas mueve volumen: todo span salvo el de polling del daemon ya queda `Recorded` con ratio
`1.0` (sus logs ya pasaban el filtro viejo igual), y el chatter del daemon bajo ese nivel de
`ILogger` es mayormente `Debug` -- `ILogger` lo descarta antes de que exista un `LogRecord` que
filtrar, sin llegar nunca a `LogFilteringProcessor`. El escenario donde el volumen si importa es un
consumidor con `TELEMETRY_SAMPLING_RATIO` fraccionario: antes de este flip, un ratio bajo tambien
recortaba logs (por herencia de la decision de trazas); despues, los logs quedan desacoplados del
ratio por completo, y acotarlos pasa a ser exclusivamente valor del consumidor via el filtering de
niveles de `ILogger` -- coherente con la frontera de la seccion 1, no una excepcion a ella.

**Guardrail.** Mismo principio que la seccion 4 -- la garantia no es el comentario del seam, es un
test que falla si el flip desaparece: el config-test del worker
(`ConfiguracionObservabilidadProjectionsTests`, `projections-scaffolder`) resuelve
`IOptions<AzureMonitorExporterOptions>` desde el `ServiceProvider` real (construido invocando el
seam, no un objeto armado a mano) y afirma `EnableTraceBasedLogsSampler == false` -- el valor
RESUELTO que el exporter usa, no el texto del `.cs`.

## Alternativas consideradas

### Alt 1: apagar `DaemonSettings.ActivitySource` en vez de filtrar por nombre

**Descartada**: apagar la fuente de actividad del daemon completa produce un `NullReferenceException`
en `JasperFx SubscriptionMetrics` (verificado por el consumidor por reproduccion en runtime) y, ademas
de romper, borraria tambien los spans de proyeccion real con valor diagnostico (los ~118 spans/dia
que la seccion 5 preserva) -- un apagado total, no un filtro selectivo.

### Alt 2: `BaseProcessor<Activity>` como punto de filtrado

**Descartada**: un `BaseProcessor<Activity>` intercepta actividades ya iniciadas, en el punto de
`OnStart`/`OnEnd` -- para entonces Marten ya instancio el span hijo de la consulta Npgsql subyacente.
No evita la creacion del span hijo (el mismo problema que la seccion 5 resuelve con `ParentBased`),
solo podria evitar su exportacion -- sin ahorrar el costo de instanciacion ni, dependiendo de la
implementacion del exporter, garantizar que no se facture.

### Alt 3: subir `UpdateMetricsPeriod` en vez de apagar el durability agent

**Descartada**: reducir la frecuencia de `FetchCountsAsync()` (en vez de apagar
`DurabilityMetricsEnabled`, seccion 6) seguiria generando una metrica que, por la misma premisa del
"Contexto" (nadie la consume), no justifica ningun costo de ingesta -- ni al ritmo original ni a uno
mas lento. El criterio "si nadie mira una metrica, no se conserva por si acaso a un costo reducido:
se apaga" lo fija **este** ADR; MEF-ADR-0018 no lo enuncia (su tabla de heuristicas cubre duplicacion
y extraccion de codigo, no telemetria), pero es el mismo espiritu de no pagar hoy por un valor que
todavia no se manifesto.

## Consecuencias

### Positivas

- **La falla silenciosa del sampler queda cerrada por construccion**: el orden correcto (seccion 3)
  mas el guardrail determinista (seccion 4) detectan una regresion de orden en el mismo build, en vez
  de descubrirla dos meses despues en produccion (el incidente real que origino este ADR).
- **Reduccion de volumen medida sin perder capacidad de diagnostico**: los filtros de las secciones
  5 y 6 eliminan el ruido estructural (95%/56% medidos) sin tocar el ratio de sampling -- que sigue en
  `1.0` por defecto, greenfield-friendly.
- **Recorte en origen, no aguas abajo**: apagar el durability agent (seccion 6) y descartar el span
  del daemon antes de que su hijo Npgsql se instancie (seccion 5, via `ParentBased`) ahorra tambien el
  costo de CPU/memoria de generar esos spans, no solo el de exportarlos.
- **Frontera mecanismo/valor reusable**: establece, para futura doctrina de observabilidad del marco,
  el mismo patron que MEF-ADR-0015 ya fijo para snapshots -- el marco resuelve el mecanismo por
  defecto, el consumidor decide el valor cuando aplica.

### Negativas

- **Subcuenta de Application Insights aceptada** (seccion 8): con `TELEMETRY_SAMPLING_RATIO < 1.0`,
  los conteos mostrados en Application Insights subestiman el trafico real, sin extrapolacion. Un
  consumidor que necesite conteos exactos debe usar otra fuente (metricas propias, logs) para esa
  necesidad especifica.
- **El filtro por nombre de span es fragil a un rename de la actividad en una version futura de
  Marten**: si `marten.daemon.highwatermark` cambia de nombre en una version posterior del paquete, el
  filtro deja de coincidir y el ruido del daemon vuelve a fluir sin que nada lo senale -- exige
  reverificar el nombre exacto al subir la version pinneada de Marten (mismo tipo de riesgo que
  MEF-ADR-0034 ya documenta para otras superficies de la libreria).
- **Un segundo `.WithTracing(...)` es un patron menos obvio que uno solo**: alguien que "limpie" el
  codigo fusionando ambos bloques en una sola llamada reintroduce el defecto de la seccion 3 sin
  ningun error de compilacion -- el codigo generado debe documentar por que estan separados (mismo
  tipo de nota que MEF-ADR-0034 deja junto a su propio `using OpenTelemetry;`).
- **Los logs quedan desacoplados del ratio de trazas** (seccion 9): antes del flip, un
  `TELEMETRY_SAMPLING_RATIO` fraccionario tambien recortaba volumen de logs por herencia de la
  decision de muestreo; despues, el ratio solo gobierna trazas, y acotar logs es exclusivamente
  responsabilidad del filtering de niveles de `ILogger` del consumidor -- un consumidor que bajaba
  su ratio esperando bajar tambien su volumen de logs debe ahora ajustar `ILogger` por separado.

## Referencias

- Microsoft Learn, "Monitor executions in Azure Functions": *"If you set telemetryMode to
  OpenTelemetry, the configuration in the logging.applicationInsights section of host.json doesn't
  apply"* -- fundamento de la seccion 7. https://learn.microsoft.com/azure/azure-functions/functions-monitoring#telemetry-export-options
- Microsoft Learn, "Use OpenTelemetry with Azure Functions" -- camino oficial de las tres piezas de
  la seccion 2. https://learn.microsoft.com/azure/azure-functions/opentelemetry-howto
- Decompilacion del consumidor Bitakora.ControlAsistencia de `Azure.Monitor.OpenTelemetry.Exporter`
  1.8.1 (`OpenTelemetryBuilderExtensions.UseAzureMonitorExporter`, seccion 3), `Wolverine` 6.16.0 /
  `Cosmos.EventSourcing.CritterStack` 2.3.1 (orden callback/`Mode`, seccion 6) -- issues #308/#309,
  PRs #311/#312 (mergeados 2026-08-04), con verificacion adicional por reproduccion en runtime y
  mutation testing.
- MEF-ADR-0003 (stack ES Marten+Wolverine): fuente de la seccion 2 (mudada integra a este ADR) y del
  callback de `AgregarWolverineParaComandosServerless` que la seccion 6 extiende.
- MEF-ADR-0015 (snapshots de Marten como excepcion): precedente directo del principio de la seccion 1
  -- el marco fija el mecanismo por defecto, el consumidor decide el valor/la excepcion bajo
  criterios explicitos.
- MEF-ADR-0018 (heuristicas de evolucion y reuso): su criterio de no abstraer un mecanismo que hoy
  tiene un solo sitio de uso es el fundamento de que el filtro de la seccion 5 sea exclusivo del
  worker (unico proceso con daemon). El criterio de apagar una metrica sin consumidor en vez de
  desacelerarla (Alt 3) **no** esta escrito en ese ADR -- su tabla de heuristicas cubre duplicacion y
  extraccion de codigo, no telemetria --; lo fija este ADR, en el mismo espiritu.
- MEF-ADR-0021 (infraestructura base): `site_config.application_insights_connection_string` del
  modulo `function-app`, que provee el valor que el exporter de la seccion 2 lee en runtime.
- MEF-ADR-0025 (custodia de secretos): la connection string de Application Insights viaja como
  referencia `@Microsoft.KeyVault(...)` versionless, nunca en claro.
- MEF-ADR-0029 (test de composicion del contenedor DI): tecnica hermana del guardrail de la seccion
  4 -- construir el grafo real y verificarlo, en vez de confiar en revision visual del codigo.
- MEF-ADR-0030 (esquema de identificacion de ADRs): numeracion de este documento.
- MEF-ADR-0034 (worker de proyecciones y read models): seccion 10 (seam de observabilidad read-side)
  es el punto de aplicacion de la seccion 5 de este ADR; enmendada por este mismo cambio.
- `CA-ADR-0009` (control de costos de Application Insights, Bitakora.ControlAsistencia): precedente
  consumidor de esta doctrina; motivo original de la investigacion que produjo la evidencia de campo.
- Lectura de fuente publica de `Azure.Monitor.OpenTelemetry.Exporter` (github.com/Azure/azure-sdk-for-net,
  tag `Azure.Monitor.OpenTelemetry.Exporter_1.8.3`): `AzureMonitorExporterOptions.EnableTraceBasedLogsSampler`
  (default `true`), `ExporterRegistrationHostedService.Initialize` (selecciona `LogFilteringProcessor`
  vs `BatchLogRecordExportProcessor` segun ese flag) e `Internals/LogFilteringProcessor.cs`
  (`SpanId == default || TraceFlags == ActivityTraceFlags.Recorded`) -- fundamento de la seccion 9.

## Control de cambios

- 2026-08-04: creacion como `aceptado` (issue #463, draft nacido del refinamiento de #457). Fija la
  frontera mecanismo-del-marco/valor-del-consumidor (`TELEMETRY_SAMPLING_RATIO`, default `1.0`), el
  orden correcto de composicion del sampler frente al exporter de Azure Monitor (`SetSampler` despues
  de `UseAzureMonitorExporter()`, via un segundo `.WithTracing(...)`) con su guardrail de composicion
  determinista (reflection sobre `TracerProviderSdk.Sampler` + `Sampler.Description` publica), el
  filtro de ruido del daemon en el read-side (`ParentBasedSampler` envolviendo un filtro por nombre de
  span mas `TraceIdRatioBasedSampler`, exclusivo del worker de proyecciones), el sampler de solo ratio
  del write-side (`ParentBasedSampler(TraceIdRatioBasedSampler(ratio))`, sin el filtro del daemon
  porque ninguna Function App corre uno), el apagado del durability agent de Wolverine en origen en el
  write-side (`Durability.DurabilityMetricsEnabled = false`) y la
  eliminacion del bloque inerte `samplingSettings` de `host.json`. Documenta la evidencia de campo del
  consumidor Bitakora.ControlAsistencia (issues #308/#309, PRs #311/#312) y descarta tres alternativas
  con razones tecnicas verificadas (apagar `DaemonSettings.ActivitySource`, `BaseProcessor<Activity>`,
  subir `UpdateMetricsPeriod`). Muda integra la seccion "Observabilidad" de MEF-ADR-0003 a la seccion
  2 de este documento, dejando en 0003 solo una referencia. Enmienda MEF-ADR-0034 seccion 10 punto 4 y
  su aceptacion del costo del Container App 24/7 (ver control de cambios de ese ADR).
- 2026-08-04: corregido el anidamiento del snippet de la seccion 5 (issue #513, al propagar esta
  doctrina a `projections-scaffolder`). El snippet de la creacion mostraba el filtro por nombre como
  `rootSampler` de un `ParentBasedSampler` externo; el anidamiento correcto -- y el unico que la
  seccion 5 fija ahora -- es el inverso: el filtro es el sampler **mas externo** y
  `ParentBasedSampler(TraceIdRatioBasedSampler(ratio))` su delegado interno. Es la forma que ya
  enunciaba MEF-ADR-0034 seccion 10 punto 4 (*"un sampler que envuelve
  `ParentBasedSampler(TraceIdRatioBasedSampler(ratio))`, descartando antes por nombre el span de
  polling del daemon"*) y la que corre verificada en produccion en el consumidor de referencia (PR
  #311); la forma invertida deja el filtro fuera de juego para cualquier span con padre, porque
  `ParentBasedSampler` consulta su `rootSampler` solo cuando no hay padre. Sin cambio de decision: la
  frontera mecanismo/valor, el orden frente al exporter, el guardrail de composicion y el default
  `1.0` quedan como estaban.
- 2026-08-26: enmendada la seccion 1 (frontera) y sumada la seccion 9 (issue #680, propagada a
  `projections-scaffolder` en el mismo issue): `EnableTraceBasedLogsSampler` de
  `Azure.Monitor.OpenTelemetry.Exporter` -- default `true`, reverificado contra la version pinneada
  `1.8.3` -- se desactiva en el seam del worker para desacoplar los logs de la decision de muestreo
  de trazas. Sin el flip, `LogFilteringProcessor` descartaba los `LogError` que `HighWaterAgent`
  emite dentro del span de polling del daemon que la seccion 5 ya descarta (medido en
  Bitakora.ControlAsistencia: 35/35 errores de "high water statistics" perdidos, 0% en `exceptions`,
  frente a 87/87 de una familia de error emitida fuera de ese span). El flip es mecanismo del marco,
  no opt-in -- mismo criterio que el filtro de la seccion 5 -- con guardrail propio sobre el valor
  resuelto de `AzureMonitorExporterOptions`; el ratio de trazas y el filtering de niveles de
  `ILogger` siguen siendo valor del consumidor, ahora como ejes independientes entre si.

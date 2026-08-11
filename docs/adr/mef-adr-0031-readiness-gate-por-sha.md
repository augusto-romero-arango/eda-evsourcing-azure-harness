# MEF-ADR-0031: Readiness gate por SHA (deploy -> smoke)

- **Fecha**: 2026-07-19
- **Estado**: aceptado
- **Aplica a**: `domain-scaffolder` (templates `deploy-*.yml`, `smoke-tests-dominio.yml`, endpoint `/api/version`, `Fixtures/ApiFixture.cs`); y, desde la seccion 5 (issue #462), `projections-scaffolder` (Dockerfile del worker de proyecciones, seam `ConfiguracionObservabilidadProjections`, `deploy-projections.yml`). Cross-referencia MEF-ADR-0013 (smoke tests, contexto relacionado, no enmendado), MEF-ADR-0006 (naming del endpoint), MEF-ADR-0020 (hosting, ancla `WEBSITE_RUN_FROM_PACKAGE` y el piso de SKU), MEF-ADR-0022 (autenticacion CI, orden infra -> deploy) y MEF-ADR-0034 (worker de proyecciones sin ingress, seam de observabilidad que consume la seccion 5).

## Contexto

El scaffold genera un job de smoke tests cuya unica compuerta previa era que `/api/health` devolviera
HTTP 200. `/api/health` es un endpoint estatico: responde 200 sin importar que version del codigo esta
sirviendo el host.

El paso `Deploy to Azure Functions` (`Azure/functions-action`) reporta exito al **subir** el paquete a
Azure, no cuando el runtime ya sirve el codigo nuevo. Con `WEBSITE_RUN_FROM_PACKAGE=1` (fijado por
`infra-base-scaffolder` en el modulo `function-app`, ver MEF-ADR-0020), la documentacion oficial
confirma que cada deploy dispara un reinicio del host: *"When a deployment occurs, a restart of the
function app is triggered"* **[1]**. Ese reinicio/swap tarda segundos, y durante la ventana el host
sigue respondiendo 200 en `/api/health` con el codigo **viejo**.

El job de smoke arrancaba inmediatamente despues de que `Deploy to Azure Functions` reportara exito,
sin ninguna gate consciente de esa ventana: el gate abria contra codigo viejo y el smoke corria antes
de tiempo -> **falso rojo**. Evidencia empirica del incidente real en el consumidor
`Bitakora.ControlAsistencia` (issue #224): deploy fin `00:54:13Z` -> smoke inicio `00:54:18Z` (5
segundos despues), paquete nuevo vivo recien ~`00:55` (casi un minuto de ventana).

Este ADR promueve al harness el fix ya validado en ese consumidor (issue #325): un readiness gate
consciente de la version desplegada, generado por el scaffold, para que todo dominio nuevo lo tenga
por defecto.

## Decision

### 1. Hornear el SHA del commit en el ensamblado al compilar, no al publicar

`deploy-{kebab}.yml` agrega `-p:SourceRevisionId=<sha resuelto>` al paso `dotnet build` del job
`deploy` (nunca al paso `Publish`, que corre con `--no-build` y no vuelve a compilar nada).

**Mecanismo verificado contra fuente oficial**: desde el SDK de .NET 8, `IncludeSourceRevisionInInformationalVersion`
(default `true`) hace que el valor de `SourceRevisionId` se agregue al atributo de ensamblado
`AssemblyInformationalVersion` **[2][3]**. El target `AddSourceRevisionToInformationalVersion`
(`Microsoft.NET.GenerateAssemblyInfo.targets`, `dotnet/sdk`) concatena con `+` si el valor de
`InformationalVersion` todavia no contiene uno (nuestro caso: `{Version}+{SourceRevisionId}`), o con
`.` si ya lo contiene -- sigue las reglas de SemVer 2.0 **[4]**. El SDK ya popula `SourceRevisionId`
automaticamente via Source Link cuando detecta el repo git, pero fijarlo explicito por MSBuild
(`-p:SourceRevisionId=...`) es mas robusto que depender de esa auto-deteccion en el runner de CI (que
hace checkout superficial) y, sobre todo, mas robusto que un app setting `DEPLOYED_SHA`: un app
setting se actualiza en un ciclo de reinicio **distinto** al del swap del paquete y podria dar falso
positivo (el setting ya reporta el SHA nuevo mientras el binario todavia sirve el viejo).

**El SHA horneado usa la misma expresion que el `ref:` del checkout, no `github.sha` a secas**:
`${{ github.event.workflow_run.head_sha || github.sha }}`. En un run disparado por `workflow_run`
(el encadenamiento tras `Infra CD`, MEF-ADR-0022), `github.sha` no es el commit que este run esta
construyendo -- es la punta de la rama por defecto en el momento del evento `workflow_run`, que puede
diferir del commit que el `apply` de infra acaba de mergear. Hornear `github.sha` a secas horneria un
SHA que no corresponde al binario que en verdad se esta construyendo y desplegando en ese run, dejando
el gate del punto 3 en timeout permanente para ese disparador. Usar la misma expresion que ya resuelve
el `ref:` del `actions/checkout` de ese job garantiza que el SHA horneado siempre sea el del commit
efectivamente compilado.

### 2. Endpoint HTTP nuevo y dedicado `/api/version`

`domain-scaffolder` genera `VersionCheck.cs` en la raiz del proyecto (mismo nivel que `HealthCheck.cs`):
un trigger HTTP anonimo (`[Function("version")]`, convencion de naming de MEF-ADR-0006, mismo patron
que `[Function("health")]`) que lee el SHA de su **propio ensamblado**
(`Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()`) y
extrae la subcadena posterior al primer `+`.

`/api/health` (`HealthCheck.cs`) **queda intacto**: sigue siendo la unica verificacion de liveness
basica del host. `/api/version` es exclusivamente el mecanismo del gate por version; ambos endpoints
coexisten con responsabilidades distintas.

### 3. Warmup por poll contra `/api/version`, no una unica llamada 200

`Fixtures/ApiFixture.cs` (el "warmup" del proyecto de smoke tests) deja de conformarse con un unico
`GET /api/health == 200`. Cuando el smoke test run recibe un `Api:ExpectedSha` (ver punto 4), hace poll
de `/api/version` hasta que el `sha` de la respuesta coincida con el esperado o se agote un timeout de
120s (el doble de la ventana real observada en el incidente, ~1 minuto, como margen de seguridad;
ajustable por el implementer si un dominio concreto necesita mas margen). Tolera `HttpRequestException`
transitorias durante el reinicio del host (el swap puede dejar el endpoint momentaneamente
inalcanzable) y reintenta hasta el timeout.

### 4. Fallback a "solo 200" -- correcto solo si ningun deploy concurrente toca el FA bajo prueba

El input `expected_sha` (opcional, `type: string`, `default: ''` -- sintaxis valida de
`on.workflow_call.inputs` **[5]**) se agrega al workflow reutilizable `smoke-tests-dominio.yml` y se
propaga como variable de entorno `Api__ExpectedSha` al proceso de smoke tests (mismo mecanismo de
`Api__BaseUrl` ya existente). `ApiFixture` interpreta un `Api:ExpectedSha` vacio o ausente como
"degradar a solo 200 contra `/api/health`".

**La invariante que sostiene ese fallback, no nombrada en la version original de este ADR**: solo
puede gatear por version quien despliega el Function App que prueba, porque solo ese invocador tiene
un SHA propio que esperar en `/api/version`. Que `expected_sha` llegue vacio dice unicamente "este
invocador no tiene un SHA al que atarse" -- no dice nada sobre si **otro** deploy, de otro workflow,
esta tocando el mismo FA en ese instante. "Solo 200" es benigno unicamente cuando **ningun** deploy
concurrente toca el FA bajo prueba; cuando si lo hay, degradar a "solo 200" reintroduce exactamente el
falso verde que motiva este ADR -- `/api/health` responde 200 con el binario viejo mientras el deploy
ajeno todavia esta en vuelo (issue #604, diagnosticado en el consumidor `Bitakora.ControlAsistencia`:
4 de 4 corridas de `Deploy Projections` se solaparon con el `Deploy ControlHoras` concurrente que
desplegaba el FA bajo prueba, con ventanas de 7 a 31 segundos entre el fin del deploy ajeno y el
arranque del smoke).

Quien pasa `expected_sha`, y cuando, distingue **tres** clases de invocador -- la version original de
este ADR solo nombraba dos:

- **`deploy-{kebab}.yml` (job `smoke-tests`, encadenado tras un deploy real)**: pasa
  `expected_sha: ${{ needs.deploy.outputs.sha }}`, el mismo SHA horneado en el punto 1 (job output del
  `deploy`, para no duplicar la expresion). Esto cubre los tres disparadores de este workflow (`push`,
  `workflow_run` tras `Infra CD`, y `workflow_dispatch` manual del propio deploy): los tres saben con
  certeza que SHA acaban de construir y desplegar en ese mismo run, asi que el gate es siempre
  significativo, nunca degradado -- esta clase cumple la invariante por construccion.
- **`smoke-tests.yml` (global, Paso 6.2 -- `workflow_dispatch` manual o `schedule` diario, MEF-ADR-0013)**:
  no pasa `expected_sha` en absoluto. Este workflow no esta atado a ningun deploy que acabe de ocurrir
  -- es una verificacion periodica de salud de todos los dominios registrados -- asi que no hay un "SHA
  del deploy" real que darle. Pero su `schedule` cron corre desatendido: una corrida puede caer sobre
  un deploy real en vuelo sin que nadie la este mirando, rompiendo la invariante en la practica aunque
  el workflow en si no dispare ningun deploy.
- **Un workflow de deploy que prueba un Function App ajeno** (tercera clase; issue #604): un workflow
  que despliega un componente propio pero ejerce la suite de smoke de **otro** dominio, porque el
  componente que despliega no tiene el endpoint HTTP que un smoke test pueda probar. El caso real
  observado es el `deploy-projections.yml` del consumidor `Bitakora.ControlAsistencia`: despliega el
  worker de proyecciones, que corre sin ingress (MEF-ADR-0034 seccion 8), y por eso ejerce la suite de
  un Function App concreto que si tiene proyecciones activas. **La plantilla que emite
  `projections-scaffolder` hoy no tiene job de smoke** (sus jobs son `build-and-test` y `publish`): esa
  tercera clase existe en el marco como forma legitima que un consumidor puede adoptar a mano, y como
  la clase que la guarda de abajo debe cubrir, no como algo que el scaffolder genere. No tiene un SHA
  propio del FA bajo prueba que pasar -- igual que
  `smoke-tests.yml` -- pero, a diferencia de ese global, **si** corre disparado por el mismo push a
  `main` que puede estar desplegando ese FA en paralelo: la carrera no es una posibilidad remota de un
  cron desatendido, es estructural en cada push que toca ambos componentes a la vez.

Las clases 2 y 3 comparten la misma condicion (`expected_sha == ''`) y la misma correccion: un paso
previo al warmup, en `smoke-tests-dominio.yml`, que espera a que termine el **job** `deploy` (nunca el
run completo -- ver la nota de deadlock mas abajo) de cualquier otro run de este mismo commit cuyo
nombre de workflow empiece con `Deploy `. La condicion identifica la clase "no despliego el FA que
pruebo" sin enumerar dominios ni workflows, asi que no crece al scaffoldear un dominio nuevo. Con esa
guarda, "solo 200" vuelve a ser seguro: para cuando el warmup corre, o no hay ningun deploy ajeno
tocando el FA, o ya termino -- la invariante que este ADR no nombraba queda restaurada por
construccion en vez de asumida.

**Por que el job, nunca el run completo.** El run ajeno (p. ej. el propio `deploy-{kebab}.yml` del FA
bajo prueba) corre su propio job de smoke tests **despues** de su `deploy`: esperar el run entero es
esperar una suite que no gatea nada del lado que espera. Y en cualquier repo que serialice los smoke
con un grupo `concurrency` -- lo hace el consumidor de origen con `smoke-tests-dev`; las plantillas
del marco no declaran ninguno -- es directamente un **deadlock**, no una carrera que a veces se
pierde: el job de smoke del run ajeno no puede arrancar hasta que el job que espera libere el grupo, y
ese job no termina hasta que el run ajeno complete. Un job `deploy` con conclusion `skipped` (el caso
de `determinar-alcance` cuando el PR no toco ese dominio) ya reporta `status: completed`, asi que no
bloquea, sin codigo extra. Si un run ajeno no expone ningun job llamado `deploy`, la guarda falla
explicitamente (`::error::` + exit distinto de cero) en vez de asumir que ya termino: degradar en
silencio ante una consulta que no devuelve lo esperado reintroduce la carrera sin dejar ninguna senal
de que la guarda dejo de ver a ese invocador.

**El precio de fallar en vez de adivinar: el filtro de runs tiene que ser exacto.** Como un run
`Deploy *` sin job `deploy` aborta la guarda, todo workflow del marco que comparta ese prefijo de
nombre **sin** desplegar una Function App debe quedar fuera del filtro. Hoy hay exactamente uno:
`Deploy Projections Worker` (`.github/workflows/deploy-projections.yml`, `projections-scaffolder`),
que publica la imagen del Container App del worker (jobs `build-and-test`/`publish`) y no toca ningun
FA -- no hay nada que esperar de el. La guarda lo excluye por su `path` exacto, no por su nombre: el
path lo genera el scaffolder, el `name:` es texto libre que el consumidor puede editar. Sin esa
exclusion, cada corrida de smoke con `expected_sha` vacio que coincidiera con una publicacion del
worker del mismo commit moriria en `exit 1` por un run que nunca tuvo nada que esperar.

**Permisos del token (`actions: read`).** La guarda consulta la API de Actions
(`GET /repos/{owner}/{repo}/actions/runs` y `.../jobs`), que requiere el scope `actions: read` en el
`GITHUB_TOKEN` del job que la ejecuta. Un workflow llamado (`uses:`) no puede pedir mas permisos que
los que su invocador concede en el job que hace esa llamada -- sin esa concesion explicita, el run
muere en `startup_failure` antes de crear un solo job, sin ninguna annotation que lo explique
(verificado en un run real del consumidor de origen). La concesion va a nivel de **job**, no de
workflow completo, para no alterar los permisos de otros jobs del mismo workflow que ya declaran los
suyos (`pull-requests: read` de `determinar-alcance`, `id-token: write` de `deploy`).

### 5. Extension al read-side: el worker de proyecciones hornea el mismo SHA, pero lo consume `service.version` de OpenTelemetry, no un endpoint HTTP (issue #462)

Los puntos 1-4 asumen una Function App con un endpoint HTTP que un smoke test puede consultar tras
el deploy. El worker de proyecciones (`{RootNamespace}.Projections`, MEF-ADR-0034) no tiene esa
opcion: corre **sin ingress** (MEF-ADR-0034 seccion 8), asi que ningun smoke test ni humano puede
hacerle una peticion HTTP para preguntarle que SHA esta sirviendo. Se reutiliza el **mismo
mecanismo de horneado** del punto 1 (`SourceRevisionId` -> `AssemblyInformationalVersionAttribute`),
pero el **consumidor** cambia: en vez de un endpoint HTTP dedicado, es el atributo de recurso
`service.version` que el seam de observabilidad del worker (`ConfiguracionObservabilidadProjections`,
MEF-ADR-0034 seccion 10) agrega a cada traza exportada a Application Insights -- la unica via de
atribucion posible para ese proceso, mismo rol que cumple `/api/version` para el write-side.

**El valor es el SHA a secas, extraido con el mismo patron del punto 2.** El seam lee
`AssemblyInformationalVersionAttribute` por reflexion y toma la subcadena posterior al `+` --
identico a lo que hace `VersionCheck.cs` para responder `/api/version` --, no el
`InformationalVersion` completo: asi `service.version` queda byte a byte igual al tag
`projections:{sha}` con el que `deploy-projections.yml` publica la imagen, y correlacionar una traza
con la imagen desplegada no necesita ninguna traduccion. Sin el separador `+` (build local sin
`--build-arg`) degrada a la version desnuda (`1.0.0`) en vez de a `null` como devuelve el endpoint
del punto 2 -- unica diferencia deliberada entre ambos: un `serviceVersion` null **omite** el
atributo del recurso, y la telemetria no distinguiria "el seam no corrio" de "el SHA no se horneo".
Ese valor desnudo es, por si mismo, el modo de falla a vigilar. En Application Insights el atributo
aterriza en la propiedad **Application Version** (columna `application_Version` de las tablas de
Logs) **[7]**: ahi se verifica el circuito, no en `customDimensions`.

**Se hornea en `dotnet publish`, no en `dotnet build` (a diferencia del punto 1).** El worker
publica dentro de un Dockerfile multi-stage (`projections-scaffolder`, Paso 2): la etapa `build`
corre `dotnet build ... -o /app/build`, cuya salida **no** llega a la imagen final -- esta copia el
resultado de la etapa `publish`, que corre `dotnet publish` **sin** `--no-build` (recompila desde el
codigo fuente copiado al build context). El comando que efectivamente produce el ensamblado
embarcado en la imagen es entonces ese `dotnet publish`, no el `dotnet build` de la etapa anterior:
por eso el Dockerfile declara `ARG SOURCE_REVISION_ID` en la etapa `publish` (lo mas tarde posible,
para no invalidar el cache de capas del `restore`/`build` de la etapa previa) y lo pasa como
`-p:SourceRevisionId=$SOURCE_REVISION_ID` a ese `dotnet publish`. Con el `ARG` en su default vacio
(`docker build` local sin `--build-arg`), la propiedad `SourceRevisionId` queda vacia y el target de
MSBuild `AddSourceRevisionToInformationalVersion` se salta por completo (`Condition="'$(SourceRevisionId)'
!= ''"`, verificado por lectura de fuente del mismo target que cita el punto 1) -- no deja un `+`
colgante, `InformationalVersion` cae de vuelta a la version desnuda.

Las dos mitades del parrafo anterior estan **verificadas empiricamente** contra el SDK `10.0.201`
(linea `10.0`, la que sirve el tag flotante `mcr.microsoft.com/dotnet/sdk:10.0` del Dockerfile), no
solo por lectura del target: con `-p:SourceRevisionId=` vacio, `InformationalVersion` queda en
`1.0.0` sin `+`; y un `dotnet publish -p:SourceRevisionId=<sha>` ejecutado **despues** de un
`dotnet build` sin la propiedad -- el orden exacto de las dos etapas del Dockerfile -- vuelve a
compilar y hornea `1.0.0+<sha>` en el ensamblado publicado. Esto ultimo es lo que no era obvio: un
build incremental podria haber reusado el ensamblado de la etapa anterior y dejado el SHA fuera en
silencio. No lo hace, porque el `AssemblyInfo` generado cambia y arrastra la recompilacion.

`deploy-projections.yml` (issue
#453) pasa `--build-arg SOURCE_REVISION_ID=${{ github.sha }}` en su paso `docker build`, reutilizando
el mismo valor con el que ese workflow ya taggea la imagen del ACR: por construccion, el tag de la
imagen desplegada y el `service.version` que reporta la telemetria quedan identicos, sin tabla de
traduccion.

**`github.sha` a secas, no la expresion larga del punto 1.** El punto 1 usa
`${{ github.event.workflow_run.head_sha || github.sha }}` porque `deploy-{kebab}.yml` se encadena
tras `Infra CD` via `workflow_run` (MEF-ADR-0022), disparador en el que `github.sha` no es
necesariamente el commit que ese run esta construyendo. `deploy-projections.yml` **no** se encadena
asi -- su trigger es `push` a `main` mas `workflow_dispatch` (MEF-ADR-0034 seccion 8) --, asi que
`github.event.workflow_run.head_sha` seria siempre nulo ahi: usar la expresion larga solo
sugeriria un encadenamiento inexistente. `github.sha` a secas es correcto especificamente porque
este workflow no tiene ese disparador, no porque el punto 1 estuviera sobre-especificado.

**Sin poll ni timeout (a diferencia del punto 3).** El worker no tiene un smoke test que haga poll
de un endpoint de version: no existe la misma "ventana de swap" que motiva el punto 3 (el Container
App corre `revision_mode = "Single"`, MEF-ADR-0034 seccion 8 -- una revision nueva reemplaza a la
anterior en su propio ciclo, sin el patron `WEBSITE_RUN_FROM_PACKAGE` del punto 3). La verificacion
de que el circuito quedo bien cableado es manual, por inspeccion de Application Insights --
documentada en `projections-scaffolder.md` junto al paso que genera `deploy-projections.yml`.

## Alternativas consideradas

### Alt 1: `sleep` fijo antes del smoke

**Descartada**: fragil (cualquier variacion en la duracion real del swap lo rompe) y no prueba nada --
un `sleep` que "por suerte" alcanza no es una señal de que el codigo nuevo esta sirviendo, solo retrasa
ciegamente el smoke.

### Alt 2: enriquecer `/api/health` con el SHA en vez de un endpoint nuevo

**Descartada**: el issue que origina este ADR fija explicitamente que `/api/health` debe quedar
intacto. Ademas mezclar liveness ("¿el host responde?") con version/readiness ("¿el host sirve el
codigo que espero?") en un mismo endpoint hace mas dificil razonar sobre cada verificacion por
separado y complica cualquier consumidor externo que ya dependa del shape actual de `/api/health`.

### Alt 3: app setting `DEPLOYED_SHA` en vez de hornear en el ensamblado

**Descartada**: un app setting se resuelve/actualiza en un ciclo de reinicio potencialmente distinto
al del swap del paquete (`WEBSITE_RUN_FROM_PACKAGE`) -- podria reportar el SHA nuevo mientras el
binario que efectivamente atiende requests sigue siendo el viejo, dando un falso positivo del gate
(exactamente el problema opuesto al que este ADR resuelve). Hornear el SHA dentro del propio binario
(`AssemblyInformationalVersion`) ata el dato al mismo artefacto que el runtime esta sirviendo: no
puede haber divergencia entre "que SHA reporta" y "que codigo corre".

### Alt 4: slots de despliegue con swap + warmup nativo de Azure App Service

Azure App Service soporta *deployment slots* con swap y warmup nativo, la forma "gold standard" de
evitar servir codigo viejo/a medio desplegar. **Descartada por ahora**: los *staging slots* requieren
el tier **Standard o superior** -- Basic (SKU `B1`, el piso que fija MEF-ADR-0020 para cada plan
dedicado del marco) no soporta ningun slot **[6]**. Adoptarlos exigiria subir de tier a todos los
dominios del marco, un cambio de costo e infraestructura que excede el alcance de este ADR (un fix de
timing del gate CI). Se anota como alternativa valida a evaluar aparte si el marco decide subir el
piso de SKU en el futuro.

## Consecuencias

### Positivas

- **El gate deploy -> smoke prueba lo que dice probar**: el smoke test corre contra el codigo
  efectivamente nuevo, no contra el codigo viejo que todavia responde 200 durante la ventana de swap.
  Elimina la clase de falso rojo documentada en el incidente de origen.
- **Funciona igual en los tres disparadores reales de `deploy-{kebab}.yml`** (`push`, `workflow_run`
  encadenado, `workflow_dispatch` manual): los tres conocen el SHA que acaban de desplegar en su propio
  run, asi que el gate nunca queda degradado quando si hay un deploy real.
- **Degrada con gracia cuando no aplica**: el workflow global de smoke tests (sin un deploy al que
  atarse) seguiria funcionando exactamente igual que antes de este ADR -- no se le exige informacion
  que no tiene.
- **No modifica `/api/health`**: cero riesgo de romper un consumidor externo del liveness check
  existente.
- **El fallback a "solo 200" ya no es una degradacion silenciosa (issue #604)**: cuando `expected_sha`
  llega vacio, la guarda de deploys ajenos garantiza que ningun `deploy-{kebab}.yml` concurrente del
  mismo commit siga tocando el FA bajo prueba antes de dejar correr el warmup -- la invariante que la
  version original de este ADR no nombraba queda restaurada por construccion, no por suerte de timing.

### Negativas

- **El job de smoke puede tardar hasta ~120s mas** en el peor caso (timeout del poll) cuando antes
  bastaba una sola llamada HTTP. En el caso feliz (swap ya completado) el costo adicional es
  minimo -- unos pocos ciclos de poll de 5s.
- **Depende de que el SDK de .NET siga soportando `SourceRevisionId`/`AssemblyInformationalVersion`**
  como hoy (comportamiento estable desde .NET 8, sin señales de deprecacion, pero es una dependencia de
  la toolchain que este ADR no controla).
- **El workflow global de smoke tests y cualquier deploy que prueba un FA ajeno siguen sin gate por
  SHA propio**: no hay un SHA al que atarse en ese contexto (decision original de este punto,
  deliberada, no un descuido) -- lo que la enmienda del issue #604 agrega es la guarda de deploys
  ajenos, no un SHA sustituto.
- **La guarda de deploys ajenos puede añadir hasta ~10 minutos al job de smoke** en el peor caso (120
  intentos x 5s, issue #604) cuando algun run ajeno nunca termina su job `deploy` -- mismo timeout
  defensivo que ya acepta el punto 3 para el poll de `/api/version`, aplicado ahora tambien a runs
  ajenos concurrentes.
- **Depende de tres convenciones de nombres acopladas entre dos agentes (issue #604)**: el prefijo
  `Deploy ` del nombre del workflow de deploy, el nombre exacto `deploy` de su job, y el path del
  workflow del worker de proyecciones que la guarda excluye. Un cambio a cualquiera de las tres sin
  actualizar la guarda de `smoke-tests-dominio.yml` la deja sin ver a un invocador, o la hace abortar
  contra un run que no tenia nada que esperar. Mitigacion doble: la guarda falla explicitamente en vez
  de degradar en silencio, y el bloque `[H]` de `scripts/tests/test-guards.sh` afirma la
  correspondencia entre las plantillas de `domain-scaffolder` y `projections-scaffolder` y los
  literales de la guarda, de modo que la deriva rompe la suite del marco en vez de aparecer como un
  rojo intermitente en el consumidor.
- **La guarda se ancla al `head_sha` del run que la ejecuta**, asi que solo ve deploys **de ese mismo
  commit**: en la corrida global por `schedule`, un deploy disparado por un push posterior al arranque
  del cron queda fuera del filtro y su carrera sigue abierta. Es un residuo estrecho (la ventana es el
  intervalo entre el disparo del cron y el push siguiente) y cerrarlo pediria esperar deploys de
  cualquier commit, que es otra decision -- se documenta, no se resuelve aqui.

## Referencias

- **[1]** "Run your functions from a package file in Azure" -- Microsoft Learn. *"When a deployment
  occurs, a restart of the function app is triggered. Function executions currently running during the
  deploy are terminated."*
  https://learn.microsoft.com/azure/azure-functions/run-functions-from-deployment-package
- **[2]** "MSBuild reference for .NET SDK projects" -- Microsoft Learn, seccion "Assembly attribute
  properties": `SourceRevisionId` e `IncludeSourceRevisionInInformationalVersion` (default `true`).
  https://learn.microsoft.com/dotnet/core/project-sdk/msbuild-props#assembly-attribute-properties
- **[3]** "Source Link included in the .NET SDK" -- Microsoft Learn (breaking change, .NET 8 Preview
  4): *"Starting in .NET 8, `InformationalVersion` includes the `SourceRevisionId` property in all
  cases."* https://learn.microsoft.com/dotnet/core/compatibility/sdk/8.0/source-link
- **[4]** Target `AddSourceRevisionToInformationalVersion`,
  `Microsoft.NET.Build.Tasks/targets/Microsoft.NET.GenerateAssemblyInfo.targets` (`dotnet/sdk`,
  codigo fuente publico): concatena `$(InformationalVersion)+$(SourceRevisionId)` si
  `InformationalVersion` no contiene ya un `+`, o `$(InformationalVersion).$(SourceRevisionId)` en
  caso contrario -- sigue las reglas de SemVer 2.0.
  https://github.com/dotnet/sdk/blob/main/src/Tasks/Microsoft.NET.Build.Tasks/targets/Microsoft.NET.GenerateAssemblyInfo.targets
- **[5]** "Workflow syntax for GitHub Actions", seccion `on.workflow_call.inputs.<input_id>` --
  GitHub Docs: claves `type` (requerida), `description`, `default` y `required` (opcionales); un
  input `string` sin `default` explicito vale `""`.
  https://docs.github.com/actions/reference/workflows-and-actions/workflow-syntax#onworkflow_callinputs
- **[6]** "Azure subscription limits and quotas" -- Microsoft Learn, tabla de limites de App Service:
  *Staging slots per app* -- Basic: sin soporte (celda vacia); Standard: 5; Premium/PremiumV2/V3:
  20. https://learn.microsoft.com/azure/azure-resource-manager/management/azure-subscription-service-limits#azure-app-service-limits
- **[7]** "Create and configure Application Insights resources" -- Microsoft Learn, seccion "Version
  and release tracking": la propiedad **Application Version** es la que separa la telemetria de
  builds distintos, y para instrumentacion basada en OpenTelemetry se fija *"by using resource
  attributes"* (es decir, `service.version` -- lo que hace la seccion 5 de este ADR).
  https://learn.microsoft.com/azure/azure-monitor/app/create-workspace-resource#version-and-release-tracking
  La columna destino en las tablas de Logs la nombra explicitamente la nota equivalente de la
  configuracion del agente de Java: *"if you add a custom dimension named `service.version`, the
  value is stored in the `application_Version` column in the Application Insights Logs table"*.
  https://learn.microsoft.com/azure/azure-monitor/app/java-standalone-config#custom-dimensions
- Bitakora.ControlAsistencia issue #224 (incidente real que origina este ADR: deploy fin `00:54:13Z`
  -> smoke inicio `00:54:18Z`, paquete nuevo vivo ~`00:55`) y field note
  `docs/bitacora/field-notes/2026-07-18-2027-bug-investigation.md` (repo consumidor).
- Bitakora.ControlAsistencia issue #362 (incidente que origina la enmienda de la seccion 4, issue #604
  de este repo: `Deploy Projections` en rojo desde 2026-08-07 porque su job de smoke -- la suite de
  ControlHoras -- corria concurrente con `Deploy ControlHoras`; 4 de 4 corridas solapadas, ventanas de
  7 a 31 segundos). PR de referencia verificado en runner real: `augusto-romero-arango/Bitakora.ControlAsistencia#362`.
- MEF-ADR-0013 (smoke tests contra entorno dev): contexto relacionado; este ADR no lo enmienda.
- MEF-ADR-0006 (convenciones de naming de funciones Azure): ancla `[Function("version")]`, mismo
  patron que `[Function("health")]`.
- MEF-ADR-0020 (hosting, un App Service Plan dedicado por dominio): ancla `WEBSITE_RUN_FROM_PACKAGE=1`
  (`agents/infra-base-scaffolder.md`) y el piso de SKU `B1` que descarta, por ahora, la Alt 4
  (deployment slots).
- MEF-ADR-0022 (autenticacion CI por OIDC, orden infra -> deploy): el job `deploy` de
  `deploy-{kebab}.yml` que este ADR modifica, y el disparador `workflow_run` cuyo `github.sha` motiva
  la nota del punto 1 sobre `github.event.workflow_run.head_sha || github.sha`.
- MEF-ADR-0034 (worker de proyecciones y read models): seccion 8 (Container App sin ingress, motivo
  por el que la seccion 5 de este ADR no puede replicar el patron `/api/version`) y seccion 10 (seam
  `ConfiguracionObservabilidadProjections`, el consumidor de `SourceRevisionId` en el read-side).

## Control de cambios

- 2026-07-19: creacion como `aceptado` (issue #325). Fija el mecanismo de readiness gate por SHA:
  `SourceRevisionId` horneado en el paso `dotnet build`, endpoint `/api/version` dedicado y anonimo,
  warmup por poll en `ApiFixture` con timeout de 120s, e input opcional `expected_sha` que degrada a
  "solo 200" cuando no hay un deploy real al que atar el SHA esperado.
- 2026-07-29: suma la seccion 5 (issue #462). Extiende el alcance al read-side: el worker de
  proyecciones (sin ingress, MEF-ADR-0034) reutiliza el mismo mecanismo de horneado de
  `SourceRevisionId`, pero horneado en el `dotnet publish` del Dockerfile (no en `dotnet build`, a
  diferencia del punto 1) y consumido como `service.version` de OpenTelemetry en vez de un endpoint
  HTTP -- el worker no tiene ninguno que exponer. El valor expuesto es el SHA **extraido** con el
  mismo patron del punto 2 (subcadena posterior al `+`), no el `InformationalVersion` completo: asi
  coincide byte a byte con el tag de la imagen del ACR; sin `+` degrada a la version desnuda y no a
  `null`, porque un `serviceVersion` null omite el atributo del recurso y borraria la senal de falla.
  `github.sha` a secas (no la expresion larga del punto 1): `deploy-projections.yml` no se encadena
  por `workflow_run`. Sin poll ni timeout: no hay smoke test que abra una compuerta contra este
  worker. Suma la referencia [7] (propiedad **Application Version** / columna `application_Version`,
  donde aterriza el atributo y donde se verifica el circuito).
- 2026-08-11: enmienda de la seccion 4 y de "Consecuencias" (issue #604). El fallback a "solo 200" no
  es benigno cuando un deploy concurrente del mismo commit toca el FA bajo prueba: nombra la
  invariante que la version original no nombraba ("solo puede gatear por version quien despliega el
  FA que prueba") y la tercera clase de invocador que la viola sin saberlo -- un workflow de deploy
  que ejerce la suite de un FA ajeno porque el componente que despliega no tiene endpoint HTTP propio
  (`deploy-projections.yml`). Agrega la correccion: un paso previo al warmup en
  `smoke-tests-dominio.yml`, condicionado a `expected_sha == ''`, que espera el **job** `deploy`
  (nunca el run completo -- esperar el run es un deadlock, ese run ajeno pide el mismo `concurrency`
  que el job que espera ya tiene tomado) de cualquier run del mismo commit cuyo workflow empiece con
  `Deploy ` -- excluyendo `.github/workflows/deploy-projections.yml`, que comparte ese prefijo pero
  publica el Container App del worker (jobs `build-and-test`/`publish`, ningun FA que esperar) y
  abortaria la guarda por no exponer un job `deploy`. Requiere `actions: read` en el job que hace
  `uses:` de los invocadores (`deploy-{kebab}.yml`, `smoke-tests.yml`, y cualquier deploy de otro
  componente que invoque el reutilizable a mano) y en el propio reutilizable -- sin esa concesion el
  run muere en `startup_failure` sin annotation visible. El acoplamiento de los tres literales de
  nombres queda afirmado por el bloque `[H]` de `scripts/tests/test-guards.sh`.

# MEF-ADR-0031: Readiness gate por SHA (deploy -> smoke)

- **Fecha**: 2026-07-19
- **Estado**: aceptado
- **Aplica a**: `domain-scaffolder` (templates `deploy-*.yml`, `smoke-tests-dominio.yml`, endpoint `/api/version`, `Fixtures/ApiFixture.cs`). Cross-referencia MEF-ADR-0013 (smoke tests, contexto relacionado, no enmendado), MEF-ADR-0006 (naming del endpoint), MEF-ADR-0020 (hosting, ancla `WEBSITE_RUN_FROM_PACKAGE` y el piso de SKU) y MEF-ADR-0022 (autenticacion CI, orden infra -> deploy).

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

### 4. Fallback a "solo 200" cuando no hay un deploy al que atar el SHA esperado

El input `expected_sha` (opcional, `type: string`, `default: ''` -- sintaxis valida de
`on.workflow_call.inputs` **[5]**) se agrega al workflow reutilizable `smoke-tests-dominio.yml` y se
propaga como variable de entorno `Api__ExpectedSha` al proceso de smoke tests (mismo mecanismo de
`Api__BaseUrl` ya existente). `ApiFixture` interpreta un `Api:ExpectedSha` vacio o ausente como
"degradar a solo 200 contra `/api/health`" -- el comportamiento previo a este ADR, sin cambios.

Quien pasa `expected_sha`, y cuando, separa los dos casos reales:

- **`deploy-{kebab}.yml` (job `smoke-tests`, encadenado tras un deploy real)**: pasa
  `expected_sha: ${{ needs.deploy.outputs.sha }}`, el mismo SHA horneado en el punto 1 (job output del
  `deploy`, para no duplicar la expresion). Esto cubre los tres disparadores de este workflow (`push`,
  `workflow_run` tras `Infra CD`, y `workflow_dispatch` manual del propio deploy): los tres saben con
  certeza que SHA acaban de construir y desplegar en ese mismo run, asi que el gate es siempre
  significativo, nunca degradado.
- **`smoke-tests.yml` (global, Paso 6.2 -- `workflow_dispatch` manual o `schedule` diario, MEF-ADR-0013)**:
  no pasa `expected_sha` en absoluto. Este workflow no esta atado a ningun deploy que acabe de ocurrir
  -- es una verificacion periodica de salud de todos los dominios registrados -- asi que no hay un "SHA
  del deploy" real que darle. Degrada correctamente a "solo 200", exactamente el comportamiento previo
  a este ADR.

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

### Negativas

- **El job de smoke puede tardar hasta ~120s mas** en el peor caso (timeout del poll) cuando antes
  bastaba una sola llamada HTTP. En el caso feliz (swap ya completado) el costo adicional es
  minimo -- unos pocos ciclos de poll de 5s.
- **Depende de que el SDK de .NET siga soportando `SourceRevisionId`/`AssemblyInformationalVersion`**
  como hoy (comportamiento estable desde .NET 8, sin señales de deprecacion, pero es una dependencia de
  la toolchain que este ADR no controla).
- **El workflow global de smoke tests no se beneficia del gate**: sigue en modo "solo 200" heredado,
  porque no hay un deploy al que atar el SHA esperado en ese contexto (decision #4, deliberada, no un
  descuido).

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
- Bitakora.ControlAsistencia issue #224 (incidente real que origina este ADR: deploy fin `00:54:13Z`
  -> smoke inicio `00:54:18Z`, paquete nuevo vivo ~`00:55`) y field note
  `docs/bitacora/field-notes/2026-07-18-2027-bug-investigation.md` (repo consumidor).
- MEF-ADR-0013 (smoke tests contra entorno dev): contexto relacionado; este ADR no lo enmienda.
- MEF-ADR-0006 (convenciones de naming de funciones Azure): ancla `[Function("version")]`, mismo
  patron que `[Function("health")]`.
- MEF-ADR-0020 (hosting, un App Service Plan dedicado por dominio): ancla `WEBSITE_RUN_FROM_PACKAGE=1`
  (`agents/infra-base-scaffolder.md`) y el piso de SKU `B1` que descarta, por ahora, la Alt 4
  (deployment slots).
- MEF-ADR-0022 (autenticacion CI por OIDC, orden infra -> deploy): el job `deploy` de
  `deploy-{kebab}.yml` que este ADR modifica, y el disparador `workflow_run` cuyo `github.sha` motiva
  la nota del punto 1 sobre `github.event.workflow_run.head_sha || github.sha`.

## Control de cambios

- 2026-07-19: creacion como `aceptado` (issue #325). Fija el mecanismo de readiness gate por SHA:
  `SourceRevisionId` horneado en el paso `dotnet build`, endpoint `/api/version` dedicado y anonimo,
  warmup por poll en `ApiFixture` con timeout de 120s, e input opcional `expected_sha` que degrada a
  "solo 200" cuando no hay un deploy real al que atar el SHA esperado.

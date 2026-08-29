# CLAUDE.md — mefisto

Harness opinionado para Claude Code (nombre interno: `mefisto`, repo: `eda-evsourcing-azure-harness`): orquesta el desarrollo asistido de aplicaciones .NET 10 serverless en Azure con Event Driven Architecture y Event Sourcing.

## Principios de respuesta

- Comunícate siempre en **español**.
- **Cita fuentes verificables** al afirmar una best practice o recomendación técnica — documentación oficial, libro, RFC, ADR del harness o del proyecto consumidor. Si es conocimiento general sin fuente, dilo explícitamente.

## Qué es este repo

Es un **Claude Code Plugin** (ver `.claude-plugin/plugin.json`) que empaqueta:

- **Skills** (slash commands) en `commands/`
- **Agentes** especializados en `agents/`
- Pipelines bash en `scripts/` (TDD, IaC, tooling, scaffolding, pr-sync, etc.)
- **ADRs** del marco arquitectónico en `docs/adr/`
- Hooks en `hooks/hooks.json`
- Un **servidor MCP bundleado** en `.claude-plugin/plugin.json` (`mcpServers.microsoft-learn`, endpoint HTTP remoto de Microsoft Learn, sin autenticación — ningún secreto viaja en la configuración, MEF-ADR-0025): lo usa el `planner` para verificar documentación oficial de Azure/.NET/C# al redactar issues

Está pensado para instalarse vía marketplace en cualquier proyecto que adopte el marco (EDA + Event Sourcing + Azure Functions + Marten + Wolverine + Postgres).

## Stack tecnológico del marco

- **Runtime**: .NET 10, C#, Azure Functions isolated worker
- **Persistencia**: PostgreSQL + Marten (event store)
- **Mediación de comandos**: Wolverine en modo serverless
- **Mensajería entre dominios**: Azure Service Bus (topic por evento — ver MEF-ADR-0001)
- **Testing**: xUnit v3 + `Cosmos.EventSourcing.Testing.Utilities` (DSL Given/When/Then/And — ver MEF-ADR-0002)
- **IaC**: Terraform
- **CI/CD**: GitHub Actions

## Contrato con el proyecto consumidor

El plugin asume que el repo consumidor cumple lo siguiente:

### 1. Archivo `.claude/harness.config.json`

Tokens operativos consumidos por los scripts shell. Estructura:

```json
{
  "projectName": "<nombre legible del proyecto>",
  "namespacePrefix": "<prefijo de namespace .NET>",
  "solutionFile": "<nombre>.slnx",
  "infraResourceGroupPrefix": "rg-<proyecto>",
  "terraformStateStorage": "<storage account del tfstate>",
  "githubServicePrincipalName": "github-<proyecto>-ci",
  "appInsightsApp": "<app-insights-component>",
  "domainLabels": ["<dominio1>", "<dominio2>", "..."],
  "boundedContext": {
    "name": "<NombreDelBC>",
    "domains": ["<dominio1>", "<dominio2>", "..."]
  },
  "serviceBus": {
    "internal": { "secretName": "<nombre del secreto KV de la cadena interna>" },
    "external": [
      { "alias": "COSMOS", "alcance": "compartido", "secretName": "<nombre del secreto KV>" }
    ]
  },
  "tenancy": { "strategy": "mono-tenant-transitorio" },
  "projections": { "enabled": true },
  "azureRegionShort": "eus2",
  "resourceSequence": "001",
  "secrets": [
    {
      "name": "<nombre del secreto en Key Vault>",
      "source": { "type": "output", "value": "<nombre del output de terraform>" }
    },
    {
      "name": "<nombre del secreto en Key Vault>",
      "source": { "type": "github-secret", "value": "<NOMBRE_DEL_GITHUB_SECRET>" }
    }
  ]
}
```

Los scripts del harness consumen estos tokens (validación y variables derivadas viven en `scripts/`).

Notas sobre campos concretos:

- **`boundedContext`** (**obligatorio**, MEF-ADR-0023): declara el Bounded Context del proyecto. Subfields:
  - **`name`**: nombre del BC; puede coincidir o no con `projectName`.
  - **`domains`**: dominios del BC; subconjunto de `domainLabels`.
- **`serviceBus`** (opcional, MEF-ADR-0024): registro de los Azure Service Bus que el BC toca. `internal.secretName` (obligatorio si se declara `serviceBus`) nombra el secreto de Key Vault del ASB propio del BC; `external` lista los ASB compartidos/externos que consume o publica. Ningún secreto viaja en claro (MEF-ADR-0025).
- **`tenancy`** (opcional, MEF-ADR-0028): declara la etapa vigente del `ITenantResolver` del BC. `strategy` es `"mono-tenant-transitorio"` (etapa a, greenfield sin autenticación instalada) o `"multi-tenant-header"` (etapa b, ya existe una autenticación que produce un `TenantContext`). **Ausente equivale a `"mono-tenant-transitorio"`** (retrocompatible). Lo consume `domain-scaffolder` inline con `jq` en su Paso 0 (mismo patrón que `serviceBus.external`) para elegir el resolver que registra en el `Program.cs` generado; `/onboard` lo reporta de forma informativa (nunca `FALTA`) y puede escribirlo/actualizarlo en un paso opt-in bajo confirmación explícita.
- **`secrets`** (opcional, issue #256): registro declarativo de todo secreto del BC que el step de siembra de `infra-cd.yml` itera en runtime (data-driven, sin líneas hardcodeadas por secreto). Cada entrada declara `name` (el secreto en Key Vault) y `source.type`/`source.value` — de dónde CI toma el valor a sembrar: `output` (un único `terraform output`, derivable) o `github-secret` (un único GitHub secret, no derivable). El tipo `composite` (fórmula fija reservada para `marten-connection`, el único secreto compuesto de varios outputs + un GitHub secret) lo escribe únicamente `infra-base-scaffolder`; el skill `/seed-secret` (que registra secretos nuevos post-greenfield) solo emite `output`/`github-secret`. `infra-base-scaffolder` registra idempotentemente los secretos fijos del BC (interno de ASB, `app-insights-connection`, `marten-connection`, uno por alias de `serviceBus.external[]`) la primera vez que genera `infra-cd.yml`.
- **`projections`** (opcional, MEF-ADR-0034, issue #369): declara si el BC adopta el worker de proyecciones (`{RootNamespace}.Projections`, daemon `HotCold` de Marten). Único subfield, `enabled` (booleano). **Ausente, `null`, `false`, o cualquier valor/tipo distinto del booleano `true` equivale a deshabilitado** (retrocompatible: sin este campo, la salida del harness no cambia). `load_harness_config` expone la variable derivada `HARNESS_PROJECTIONS_ENABLED` (nunca aborta la carga por este campo). Lo consumen inline `infra-base-scaffolder` (los 3 módulos Terraform opt-in del Container App, MEF-ADR-0034 sección 8) y `/scaffold-projections`/`projections-scaffolder` (el worker en sí); `domain-scaffolder` no lee el token sino su consecuencia — si el worker ya existe en el repo, registra el named store del dominio nuevo en él (Paso 3b, issue #370); `/onboard` lo reporta de forma informativa (nunca `FALTA` si está deshabilitado) y, si está habilitado pero el worker todavía no existe, ofrece encadenar `/scaffold-projections` bajo confirmación explícita.
- **`azureRegionShort`** (opcional, MEF-ADR-0045, issue #729): abreviatura de la región Azure (ej. `"eus2"` para East US 2) que el estándar de nombramiento de recursos usa como componente `{region}` del patrón CAF `{abrev-tipo}-[{uso}-]{app}-{env}-{region}-{seq}`. String libre (el CAF no publica una tabla oficial de abreviaturas de región) declarado por el consumidor, no derivado de `azureLocation`. **Ausente**: retrocompatible — los scaffolders conservan el comportamiento actual (sin `{region}` en el nombre). `load_harness_config` expone la variable derivada `HARNESS_AZURE_REGION_SHORT` (nunca aborta la carga por este campo). Primer consumidor (issue #732): `scripts/bootstrap-backend.sh`, que con el token declarado nombra el backend del tfstate como `rg-tfstate-{app}-{env}-{region}-{seq}` + `sttfstate{app}{env}{region}{seq}` (sin sufijo aleatorio) e **ignora el contenido de `terraformStateStorage`**, que solo sigue rigiendo el naming legacy; un backend ya escrito en `backend.tf` se reusa tal cual (solo greenfield, MEF-ADR-0045 sección 3). El reporte del token en `/onboard` — informativo, nunca `FALTA`, igual que `tenancy`/`projections` — queda para el issue dependiente que alinea los scaffolders (MEF-ADR-0045 sección 5).
- **`resourceSequence`** (opcional, MEF-ADR-0045, issue #729): secuencia `{seq}` del mismo patrón, string zero-padded (ej. `"001"`). **Ausente**: default `"001"`, expuesto por `load_harness_config` como `HARNESS_RESOURCE_SEQUENCE`.
- **`terraformStateStorage`** es el nombre **base** de la Storage Account del tfstate. Debe cumplir el naming de Azure Storage (3-24 caracteres, solo minúsculas y dígitos — [reglas de nombres de recursos, `Microsoft.Storage`](https://learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules#microsoftstorage)); para nombres largos abrevia el prefijo. Detalle en README §3.
- **`repoSlug`** (opcional): slug `owner/repo` del fork de Mefisto al que se enrutan los drafts cross-repo (`estado:borrador`). Default: `augusto-romero-arango/eda-evsourcing-azure-harness`.
- **`azureLocation`** (opcional): región de Azure por defecto para `bootstrap-backend.sh`.

### 2. Secciones "Tokens del harness" y "Verificación de fuentes" en `CLAUDE.md` raíz del consumidor

Necesaria porque los agentes/skills del harness no pueden hacer sustitución de variables. Los placeholders `<RootNamespace>`, `<SolutionFile>`, `<ProjectDisplayName>`, `<BoundedContext>` y `<BoundedContextDomains>` se resuelven leyendo `CLAUDE.md` del proyecto. Ejemplo mínimo:

```markdown
### Tokens del harness

- **RootNamespace**: MiProyecto.Nombre
- **SolutionFile**: MiProyecto.slnx
- **ProjectDisplayName**: MiProyecto
- **BoundedContext**: Principal  (nombre del BC; corresponde a `boundedContext.name` en harness.config.json)
- **BoundedContextDomains**: dominio1, dominio2  (lista separada por comas; corresponde a `boundedContext.domains`)
```

`BoundedContext` es el nombre del Bounded Context declarado en `harness.config.json` (MEF-ADR-0023); puede coincidir o no con `ProjectDisplayName`.

Además de "Tokens del harness", el `CLAUDE.md` mínimo del consumidor debe incluir la siguiente sección, verbatim, propagando al consumidor el principio de verificación de fuentes del propio harness (ver "Principios de respuesta" arriba):

```markdown
### Verificación de fuentes (obligatorio para agentes)

Antes de proponer o aplicar un ajuste técnico, verifica el enfoque contra la
**documentación oficial y vigente** de las tecnologías del stack (.NET, Azure
Functions, Marten, Wolverine, Azure Service Bus, Terraform, …). No te apoyes en
conocimiento memorizado: puede estar desactualizado. Al afirmar una best practice
o recomendación, **cita la fuente** (URL oficial, versión del paquete, ADR). Si un
dato no pudiste verificarlo contra la fuente, decláralo como *no verificado* en
tu propuesta en vez de darlo por cierto.
```

### 3. Estructura de carpetas esperada

- `src/<RootNamespace>.{Dominio}/` — Function App por dominio
- `src/<RootNamespace>.{Dominio}.DomainEvents/` — eventos persistidos del dominio en el event store, uno por dominio (MEF-ADR-0039)
- `src/<RootNamespace>.PublicEvents/` — eventos que salen del BC, uno por Bounded Context (MEF-ADR-0039)
- `src/<RootNamespace>.PrivateEvents/` — eventos del bus interno del BC, uno por Bounded Context (MEF-ADR-0039)
- Los tres ensamblados de eventos de arriba son **tres islas**: cada uno con cero `ProjectReference` (MEF-ADR-0039 decision 2); el Function App del dominio referencia los tres, el worker de proyecciones solo `{Dominio}.DomainEvents` + `ReadModels`
- `tests/<RootNamespace>.{Dominio}.Tests/` — tests unitarios ES por dominio
- `tests/<RootNamespace>.{Dominio}.SmokeTests/` — smoke tests black-box (opcional)
- `tests/<RootNamespace>.PublicEvents.Tests/` — tests del ensamblado `PublicEvents`, uno por BC (MEF-ADR-0039)
- `tests/<RootNamespace>.PrivateEvents.Tests/` — tests del ensamblado `PrivateEvents`, uno por BC (MEF-ADR-0039)
- `infra/environments/{env}/` — Terraform por ambiente
- `.claude/pipeline/` — estado runtime de los pipelines (lo crea el harness en primer arranque, y nunca viaja en un commit del consumidor); incluye `sessions.jsonl`, un log append-only que el hook `SessionStart` del plugin anota con `session_id`/`transcript_path`/`cwd`/`source`/`timestamp`/`harness_version` en **cada** arranque de sesion de Claude Code sobre el repo — las headless de `claude -p` que corren los stages y tambien las interactivas, con `source` distinguiendo `startup`/`resume`/`clear`/`compact` y `harness_version` tomando el basename de `${CLAUDE_PLUGIN_ROOT}` (`null` si esa variable llega vacia o no definida) —, para correlacionar un stage con su transcript completo en `~/.claude/projects/` y con la version de Mefisto que lo ejecuto; e incluye tambien `.plugin-root.previous`, el marker por sesion que `/upgrade` escribe con la version del plugin que la sesion cargo (y que el mismo hook `SessionStart` limpia en cada arranque) para no borrarla al podar el cache
- `docs/bitacora/field-notes/` — output de los agentes investigadores
- `docs/ddd/ubiquitous-language.yaml` — glosario de lenguaje ubicuo (terminos, actores, preguntas abiertas), custodiado por el `planner` (MEF-ADR-0040)

## Catálogo de skills

| Skill | Propósito |
|---|---|
| `/onboard` | Diagnostica el onboarding del consumidor (config, labels, CI) y reporta un checklist; provisión opt-in bajo confirmación |
| `/upgrade` | Actualiza el plugin (marketplace + `mefisto`) sin interacción, reescribe `.plugin-root` a la última versión, muestra el delta de `CHANGELOG.md` y poda el cache de versiones viejas bajo confirmación (nunca borra la versión cargada en la sesión activa) |
| `/draft` | Captura una idea como issue `estado:borrador` |
| `/implement` | Pipeline TDD para un issue `estado:listo` |
| `/tooling` | Pipeline de tooling (scripts, fixtures, config, agentes) |
| `/infra` | Pipeline IaC con Terraform (write → review → apply) |
| `/infra-base` | Genera la infraestructura base (8 módulos + esqueleto del entorno) en greenfield; suma los 3 módulos del worker de proyecciones si `projections.enabled` |
| `/seed-secret` | Registra y cablea un secreto nuevo post-greenfield (Key Vault + Function App de un dominio) |
| `/install-workos` | Guia el dashboard de WorkOS AuthKit (cuenta, client_id, API key, rol admin) y cablea el adapter (agente de identidad) + la custodia de la API key (`/seed-secret`) |
| `/install-apim` | Instala/actualiza el gateway APIM (agente `apim-gateway-scaffolder`), cablea `TF_VAR_workos_client_id`/`TF_VAR_cors_allowed_origins` y ejecuta la transicion a->b de tenancy (MEF-ADR-0028 seccion 4): flip de `tenancy.strategy` + migracion del `ITenantResolver` de todos los dominios ya scaffoldeados a `AgregarTenantResolverHibrido()` |
| `/install-auth` | Orquesta el camino completo de auth: encadena `/install-workos` -> gate humano (verifica `WORKOS_CLIENT_ID`/`WORKOS_API_KEY` via `gh`) -> `/install-apim`, stateless (delega en la idempotencia de ambos) |
| `/parallel` | Corre varios issues en worktrees aislados |
| `/sequential` | Cadena de issues con merge automático |
| `/scaffold` | Crea el scaffold de un nuevo dominio |
| `/scaffold-projections` | Genera el worker de proyecciones (`{RootNamespace}.Projections`), `{RootNamespace}.ReadModels`, el config-test base `{RootNamespace}.Projections.Tests`, el seam de observabilidad `ConfiguracionObservabilidadProjections` (con el sampler que descarta el polling del daemon, MEF-ADR-0038), el workflow de deploy `deploy-projections.yml` y el `.dockerignore` del build context cuando el BC habilita el token `projections.enabled` (fase 1+2+3+4+5+6, agente `projections-scaffolder`) |
| `/bug` | Investiga un síntoma (bug-investigator o tooling-investigator) |
| `/fix-review` | Resuelve comentarios pendientes de un PR |
| `/health-check` | Dashboard del entorno desplegado |
| `/work-status` | Progreso de los pipelines activos en tmux |
| `/eraser-diagram` | Genera diagrama para Eraser |
| `/merge` | Mergea uno o varios PRs a main |
| `/bitacora` | Invoca al agente `historiador` y, si crea PR, encadena `/merge` automaticamente |
| `/purge-store` | Diagnostica con evidencia (App Insights, smoke tests), confirma y valida la purga del store de un dominio en dev (mecanismo canonico de MEF-ADR-0036 seccion 5; los pasos destructivos los ejecuta `scripts/purge-store.sh`) |

## Agent Skills disponibles

Doctrina pesada empaquetada con *progressive disclosure* (MEF-ADR-0033); no son slash commands. Un agente las precarga con el frontmatter `skills:`, o Claude las dispara solo cuando la tarea coincide con su `description`.

| Agent Skill | Doctrina que empaqueta |
|---|---|
| `projections` (`skills/projections/`) | Read-side: recetas de proyección Marten (N1/N2/N3), estilo canónico de read model, read APIs sobre `QuerySession` tenant-scoped, naming de Functions de query y config-test del worker (MEF-ADR-0035/0034/0006) |
| `comment-cleanup` (`skills/comment-cleanup/`) | Mecánica de limpieza de comentarios en `.cs`: clasificar, aplicar el umbral doble Context Delta/Decision Delta, codificar en el código, comprimir los sobrevivientes y releer (MEF-ADR-0044) |

## Agentes

El catálogo y propósito de cada agente vive en el frontmatter `description` de `agents/*.md` (listables con `ls agents/`).

## ADRs del marco

Los ADRs en `docs/adr/` son la fuente de verdad arquitectónica del harness, identificados con el prefijo `MEF-ADR-` (esquema de identificación con prefijo por proyecto, ver **MEF-ADR-0030**). Los agentes los consultan, los aplican y documentan cuando se desvían.

El proyecto consumidor puede tener sus propios ADRs adicionales (sobre dominio o configuración específica). Adoptar el mismo esquema de prefijo es **opcional**: un consumidor nuevo puede elegir su propio código corto (p. ej. `CA-ADR-` para Control de Asistencias, `CPC-ADR-` para Cosmos ControlPlane) para desambiguar sus ADRs frente a los del marco; un consumidor con ADRs legados puede quedarse citándolos como `ADR-XXXX` a secas, sin conflicto — `ADR-XXXX` nunca coincide textualmente con `MEF-ADR-XXXX`.

### Índice temático

> Esta tabla NO se edita a mano por-PR (issue #380): un issue que añade o enmienda un ADR anota su fila como fragmento en `changelog.d/<issue>.adr-index.md` (ver `changelog.d/README.md`), y `/mefisto-release` la consolida aquí en su propia rama de release.

| Tema | ADR |
|---|---|
| Topics de Service Bus por evento | MEF-ADR-0001 |
| Estrategia de testing con event sourcing (Given/When/Then) | MEF-ADR-0002 |
| Stack ES: Marten + Wolverine + Postgres | MEF-ADR-0003 |
| Manejo de errores en ES (eventos de fallo vs excepciones) | MEF-ADR-0004 |
| Naming y versionado de eventos | MEF-ADR-0005 |
| Convenciones de nombramiento de funciones Azure (comando, ServiceBus, fan-in, query GET) y de artefactos de proyeccion | MEF-ADR-0006 |
| Gestión de proyecto con GitHub Issues | MEF-ADR-0007 |
| Knowledge Crunching como propósito del planner | MEF-ADR-0008 |
| Mensajes en `.resx` por aggregate/handler | MEF-ADR-0009 |
| Pipeline de conocimiento del dominio | MEF-ADR-0010 |
| Definition of Ready por tipo de issue | MEF-ADR-0011 |
| Encapsulamiento, Tell-don't-Ask, value objects, frontera de serialización (event store Marten vs bus) | MEF-ADR-0012 |
| Smoke tests contra entorno dev | MEF-ADR-0013 |
| Coverage gate en pipeline TDD | MEF-ADR-0014 |
| Snapshots de Marten como excepción | MEF-ADR-0015 |
| Convención de naming para métodos de test | MEF-ADR-0016 |
| Archivo señal de refactor puro vive fuera de `.claude/` | MEF-ADR-0017 |
| Heurísticas de evolución y reuso del código (Rule of Three, etc.) | MEF-ADR-0018 |
| Separación física de skills publicados vs internos | MEF-ADR-0019 |
| Hosting de Azure Functions (un App Service Plan por dominio) | MEF-ADR-0020 |
| Infraestructura base (8 módulos + entorno) generada por agente | MEF-ADR-0021 |
| Autenticación de CI hacia Azure por OIDC (Workload Identity Federation) | MEF-ADR-0022 |
| Bounded Context, namespace interno de ASB y frontera publico/privado | MEF-ADR-0023 |
| Modelo de eventos de bus (privado propio, publico via backbone compartido, externo diferido) | MEF-ADR-0024 |
| Custodia de secretos (ningun secreto/key en texto plano; Key Vault o identidad administrada) | MEF-ADR-0025 |
| Colas de Service Bus con sesion para fan-in y serializacion por clave de aggregate | MEF-ADR-0026 |
| Enrutamiento multi-destinatario de un evento por correlation filter de igualdad | MEF-ADR-0027 |
| Estrategia de tenancy (mono-tenant transitorio en greenfield + resolver real basado en TenantContext) | MEF-ADR-0028 |
| Test de composicion del contenedor DI del host generado por el scaffold | MEF-ADR-0029 |
| Esquema de identificación de ADRs con prefijo por proyecto (adopción opcional para consumidores) | MEF-ADR-0030 |
| Readiness gate por SHA (endpoint `/api/version` + gate deploy->smoke) | MEF-ADR-0031 |
| Identidad y autenticación en el borde: WorkOS AuthKit + Azure API Management | MEF-ADR-0032 |
| Adopción de Agent Skills (progressive disclosure) para doctrina pesada del marco | MEF-ADR-0033 |
| Worker de proyecciones y read models por Bounded Context (Container App sin ingress, named store por dominio, config-test) | MEF-ADR-0034 |
| Doctrina de proyección y query read-side (recetas en 3 niveles, estilo record inmutable, superficie de consulta sobre QuerySession tenant-scoped) | MEF-ADR-0035 |
| Lista canonica de resource providers de Azure que el provider `azurerm` del entorno debe registrar | MEF-ADR-0021 |
| Compatibilidad de configuracion Marten entre write-side y read-side (los dos pares, criterio de corte, verificacion bajo gate del reviewer) | MEF-ADR-0034 |
| Doctrina de etiquetado del worker de proyecciones (`tipo:projection` para issues de configuracion del read-side, razonamiento continente/contenido de `dom:X`) | MEF-ADR-0011 |
| Observabilidad del worker de proyecciones (`service.name` obligatorio, fuentes de traza read-side, punto de extension del sampler) | MEF-ADR-0034 |
| Extension del readiness gate por SHA al read-side (`service.version` del worker de proyecciones, sin ingress) | MEF-ADR-0031 |
| Control de volumen de telemetria (sampler efectivo, filtros de ruido en origen, ratio del consumidor) | MEF-ADR-0038 |
| Wiring base de OpenTelemetry del write-side (paquetes, composicion en `Program.cs`, `telemetryMode` de `host.json`): doctrina mudada a MEF-ADR-0038 | MEF-ADR-0003 |
| Costo de ingesta de telemetria del daemon 24/7 y sampler read-side instalado por defecto con filtro del polling (doctrina en MEF-ADR-0038) | MEF-ADR-0034 |
| Identidad del evento persistido en el event store (alias vs `mt_dotnet_type`, proscripciones de registro, guardrails, protocolo de refactor) | MEF-ADR-0036 |
| Firmas admitidas de Create/Apply, tipo de identidad de N1 (StreamIdentity.AsString) y límite de fan-out en N2 | MEF-ADR-0035 |
| Origen del analizador de Marten (paquete, no `PackageReference` adicional) y namespaces de las clases base de proyección | MEF-ADR-0035 |
| Doble cobertura de la guarda 1 del config-test del worker (metodo `partial` del seam y clase de proyeccion sin `partial`) y superficie verificada de la guarda 2 | MEF-ADR-0034 |
| Resolución de `TView` en el `DocumentStore` del write-side sin registro adicional, y condición de política de tenancy documental compartida con el worker | MEF-ADR-0035 |
| Auto-creacion de tablas de read model por el worker de proyecciones (`AutoCreateSchemaObjects`, sin migracion de despliegue) | MEF-ADR-0034 |
| Identidad del stream y su representacion string canonica (Guid/clave compuesta, borde HTTP, store/bus/read-side) | MEF-ADR-0037 |
| Composicion canonica de ensamblados por rol del evento (particion PublicEvents/PrivateEvents/{Dominio}.DomainEvents; Contracts fuera del canon) | MEF-ADR-0039 |
| Acceso del worker de proyecciones a los tipos de evento persistidos via `{Dominio}.DomainEvents`, sin referenciar el `.csproj` de ningun Function App | MEF-ADR-0034 |
| Envelope de eventos referencia el ensamblado de eventos de bus que corresponda, no "el proyecto Contracts" | MEF-ADR-0005 |
| Csproj de smoke tests referencia PublicEvents/PrivateEvents en vez de Contracts | MEF-ADR-0013 |
| Referencia al shared kernel de Contracts reemplazada por la particion canonica de ensamblados de evento por rol | MEF-ADR-0010 |
| Mencion de Contracts en la fila `dom:X` del DoR actualizada a la particion de ensamblados de evento por rol | MEF-ADR-0011 |
| Referencia a un ADR de Contracts del consumidor reemplazada por la particion canonica de ensamblados de evento por rol | MEF-ADR-0012 |
| Regla simetrica de referencia unica en los proyectos de tests de eventos de bus (`PublicEvents.Tests`/`PrivateEvents.Tests`, cada uno referencia solo su propio ensamblado) | MEF-ADR-0039 |
| Cero referencias entre ensamblados de eventos (tres islas), payload por rol y enforcement por tests de arquitectura | MEF-ADR-0039 |
| Fuentes de conocimiento del dominio vigentes tras el retiro de la capa de modelado EDA (codigo por rol, glosario custodiado por el planner, field notes/bitacora, ADRs del consumidor) | MEF-ADR-0040 |
| Pipeline de conocimiento del dominio en tres fases (event-stormer/eda-modeler/planner): superseded por MEF-ADR-0040 | MEF-ADR-0010 |
| Forma propia de la vista read-side derivada de la necesidad de lectura; `ReadModels` como cuarta isla (cero `ProjectReference`) y naming sin sufijo `View` | MEF-ADR-0041 |
| Presentacion de los archivos "sin clasificar" del coverage gate (marcador de atencion y nota propios, distintos de una exclusion deliberada) | MEF-ADR-0014 |
| Patron de logica del coverage gate cubre el EventHandler directo (`*EventHandler.cs`, patron 2.1.0) | MEF-ADR-0014 |
| Frontera GET vs QUERY, paginacion y filtros multiples de las read APIs (RFC 10008) | MEF-ADR-0042 |
| `Listar{X}s` conserva nombre y ruta cuando su verbo es QUERY (solo cambia el verbo del `HttpTriggerAttribute`) | MEF-ADR-0006 |
| Enmienda a MEF-ADR-0031: el fallback a "solo 200" no es seguro con un deploy concurrente tocando el FA bajo prueba; tercera clase de invocador (deploy de un componente que prueba un FA ajeno) | MEF-ADR-0031 |
| Consecuencias del verbo QUERY en el borde APIM: `<allowed-methods>` por enumeracion explicita con `QUERY` (B3), operacion wildcard del verbo (B11) y gate empirico end-to-end | MEF-ADR-0032 |
| Trampa B11 de APIM: sin operaciones declaradas el gateway responde 404 a todo el trafico; fix con operacion wildcard por verbo, trade-off documentado frente a OWASP API5:2023 | MEF-ADR-0032 |
| Doctrina HTTP de comandos: test de precedencia (POST coleccion/PUT/DELETE/`POST {recurso}:{verbo}`), ids URL-safe, casing kebab-case y simetria CQRS | MEF-ADR-0043 |
| Casing kebab-case minusculo de las rutas HTTP y remision a MEF-ADR-0043 para el verbo y forma de ruta de comandos | MEF-ADR-0006 |
| Contrato HTTP de comandos (verbo + ruta + precedencia aplicada) como campo Critico del Definition of Ready | MEF-ADR-0011 |
| Politica de aceptacion de ids/codigos de negocio en segmentos de URI (charset RFC 3986 unreserved, criterio rechazar-vs-normalizar por propiedad del dato, momento de la invariante en issue previo dedicado) | MEF-ADR-0043 |
| Doctrina de comentarios de código mínimos (jerarquía código/comentario/documentación, umbral doble Context Delta + Decision Delta, proscripción de provenance `// HU-XX`, regla de precedencia de citas a ADR, alcance por lenguaje y frontera de limpieza del reviewer) | MEF-ADR-0044 |
| Default `always_on = true` unico del marco (sin distincion dev/prod) y su fundamento de costo real en tiers dedicados | MEF-ADR-0020 |
| Wiring de `always_on` desde el output del modulo `service-plan` hasta `site_config.always_on`, via el input nuevo del modulo `function-app` | MEF-ADR-0021 |
| Enmienda a MEF-ADR-0031: cobertura de la capa de datos con el endpoint dedicado `/api/ready` (defensa en profundidad, probe sin cache del positivo, `ApplyAllDatabaseChangesOnStartup` diferida) | MEF-ADR-0031 |
| Alerta dedicada de spike de excepciones del worker de proyecciones (umbral calibrado empiricamente, gate de deteccion parcial) | MEF-ADR-0034 |
| Desacople de logs de error del sampler de trazas en el read-side (EnableTraceBasedLogsSampler, LogFilteringProcessor) | MEF-ADR-0038 |
| Camino de resolucion de la connection string del worker bajo el overload de opciones del exporter (IConfiguration poblada por el host) | MEF-ADR-0034 |
| Correccion en MEF-ADR-0043 seccion 1.1: lectura por alcances del charset de segmentos de ruta frente a la identidad de stream de MEF-ADR-0037 (Guid por construccion, componente tipado no-Guid sujeto a 1.2/1.3, clave compuesta fuera del sujeto porque nunca viaja entera en un segmento) | MEF-ADR-0043 |
| Precision de MEF-ADR-0037 seccion 2: la unidad del borde HTTP es el componente tipado, no la clave (identidad de un componente vs. de varios) | MEF-ADR-0037 |
| Extension del desacople de logs de error del sampler de trazas al write-side (supresion ratio-dependiente, sin el filtro estructural del worker) | MEF-ADR-0038 |
| Cierre del gap de `mt_version` en la doctrina read-side (receta `UseNumericRevisions` + par de config-tests espejo write-side/read-side, segunda instancia del par de compatibilidad 2) | MEF-ADR-0034 |
| Estándar de nombramiento de recursos Azure (patrón CAF + región + secuencia) | MEF-ADR-0045 |
| Remision del naming de infraestructura base al estandar CAF + region + secuencia (MEF-ADR-0045) | MEF-ADR-0021 |
| Correccion en la nota del issue #245 de MEF-ADR-0006: el nombre del recurso Azure citado pasa a `func-{kebab}-{prefix_func}` (el dominio es el `{uso}` del patron CAF) | MEF-ADR-0006 |
| Generalizacion del par de config-tests espejo a plantilla del par 2 (tabla/tenancy/id como tercera instancia; guarda siempre-activa de la tenancy documental) | MEF-ADR-0034 |
| Enmienda a MEF-ADR-0036: el skill `/purge-store` como mecanismo canonico de ejecucion de la purga deliberada en dev (regla del mismo despliegue intacta) | MEF-ADR-0036 |
| Enriquecimiento coreografiado por el dueño del dato (Content Enricher preferido sobre réplica local) | MEF-ADR-0046 |

## Convenciones del marco

### Issues (gestionados con GitHub)

- **Títulos**: `[verbo infinitivo] [qué cosa]` — sin prefijos.
- **Labels obligatorios**: `tipo:X` + `dom:X` + `estado:{borrador|listo}` (asignados por el planner).
- **Dependencias**: declaradas en sección `## Dependencias`.
- **Bloqueados**: label `bloqueado` cuando dependen de otro no cerrado.
- **Definition of Ready**: ver MEF-ADR-0011 — los skills de pipeline lo validan antes de ejecutar.

### Flujo de entrega

- **Nunca trabajar contra `main` directo.** Toda edición de archivos en este repo se hace en una rama nueva y se entrega vía Pull Request.
- Antes de editar, si la rama activa es `main`, crear una nueva con `git switch -c <rama>` usando un slug descriptivo (`docs/<slug>`, `feat/<slug>`, `fix/<slug>`).
- Si por error ya se hicieron cambios sin commitear en `main`, mover a rama con `git switch -c <rama>` (preserva los cambios) antes de commitear.
- Al terminar: `git push -u origin <rama>` + `gh pr create` apuntando a `main`.
- **Los cambios notables se anotan como fragmento en `changelog.d/`, nunca editando `CHANGELOG.md` ni el índice temático de ADRs de arriba** (issue #380). Un archivo por issue (`changelog.d/<issue>.<categoria>.md`, y `changelog.d/<issue>.adr-index.md` si el issue toca `docs/adr/`); ver `changelog.d/README.md`. Editar esos dos archivos-índice por-PR es la contención que colisionaba entre PRs paralelos: sólo `/mefisto-release` los consolida, y sólo en su rama de release.

### Código C#

- **Caracteres prohibidos en `.cs`**: nunca `─` (U+2500) ni decorativos Unicode. Solo guión ASCII `-`.
- **Comentarios**: mínimos, ver MEF-ADR-0044 (umbral doble Context Delta + Decision Delta; default sin comentario).
- **Commits**: en español, descriptivos, frecuentes.
- **Ramas de trabajo**: `worktree-issue-<num>-<slug>` (los pipelines las crean para el proyecto consumidor).
- **PRs**: deben incluir `Closes #<número>` cuando resuelven un issue.

## Notas para definir agentes y skills

- Las herramientas MCP requieren declaración explícita cuando un agente usa allowlist `tools:`. Usa wildcard: `mcp__<servidor>__*`.
- Cuando el servidor MCP lo provee un **plugin** (declarado en `mcpServers` de `.claude-plugin/plugin.json`, propio o de terceros), el nombre real de sus tools va scoped con el prefijo del plugin, así que la allowlist se escribe `mcp__plugin_<plugin>_<servidor>__*`, no `mcp__<servidor>__*`. Fuente: [code.claude.com/docs/en/plugins-reference](https://code.claude.com/docs/en/plugins-reference) — *"Tool matchers and `if` fields take the scoped tool name `mcp__plugin_<plugin-name>_<server-name>__<tool>` … A matcher written against the bare server key never fires"*. Ejemplo: el servidor `microsoft-learn` bundleado por este plugin (`mefisto`) se declara en `tools:` como `mcp__plugin_mefisto_microsoft-learn__*`.
- Si el agente **no** define `tools:`, hereda todas incluyendo MCP.
- Para **doctrina extensa** que solo aplica a algunas tareas, usa un **Agent Skill** (`skills/<nombre>/SKILL.md` publicado, `.claude/skills/<nombre>/SKILL.md` interno) en vez de otra sección en el body del agente: el Skill se carga por niveles y no se paga cuando la tarea no lo necesita. Un agente lo precarga con el campo frontmatter `skills:` (no requiere la tool `Skill` en `tools:`). Doctrina completa y caveats de versión en MEF-ADR-0033.

## Dos paquetes de tooling: publicado vs interno

Mefisto mantiene **dos sets** de skills/agentes/pipelines físicamente separados (doctrina completa en MEF-ADR-0019):

- **Publicados** (`commands/`, `skills/`, `agents/`, `scripts/`, `hooks/`): se distribuyen vía marketplace y operan únicamente sobre archivos del consumidor.
- **Internos** (`.claude/commands/`, `.claude/skills/`, `.claude/agents/`, `.claude/scripts/`): no se publican; Claude Code los carga al abrir este repo. Llevan prefijo `mefisto-` y operan solo sobre archivos del propio plugin.

`skills/` y `.claude/skills/` son las ubicaciones de Agent Skills (MEF-ADR-0033) y ya están registradas en los gates de scope; el primero publicado es `skills/projections/` (ver "Agent Skills disponibles"), y del lado interno todavía no hay ninguno. La integridad de todo Skill nuevo (su `name` frontmatter, sus recursos de Nivel 3 y las referencias `skills:` de los agentes) la valida el bloque `[F]` de `scripts/tests/test-guards.sh`: un `skills:` mal escrito degrada en silencio, sin error visible en un pipeline headless. **Todo tipo de artefacto nuevo del plugin debe registrarse a mano** en el blocklist publicado (`is_path_in_consumer_blocklist`) y en la allowlist interna (`is_path_in_mefisto_scope`): ambos enumeran rutas explícitamente. Ese registro y el uso de la ruta son **dos PRs distintos, y el de registro va primero** — el gate que juzga un PR se carga fuera de su worktree, así que un PR que registra una ruta y la puebla a la vez se autobloquea (regla completa en MEF-ADR-0019, sección E).

La única operación cross-repo desde el consumidor hacia Mefisto es **crear drafts** (`estado:borrador`); el refinamiento y demás gestión de issues ocurre con `/mefisto-plan` dentro de este repo.

## Instalación en un proyecto

Ver `README.md`.

## Trabajar sobre el propio plugin

Si estás clonando este repo (Mefisto) para evolucionarlo, **no necesitas instalar el plugin sobre sí mismo**. Claude Code carga automáticamente los skills internos desde `.claude/commands/` y `.claude/agents/` del repo activo. Los pipelines internos viven bajo `.claude/scripts/`.

Workflow típico:

1. Captura una idea: `/mefisto-plan` (modo draft) o `gh issue create --label "estado:borrador,tipo:tooling" --title "..."`.
2. Refina: `/mefisto-plan` (modo refinar) hasta `estado:listo`.
3. Implementa: `/mefisto-tooling <issue>`. El pipeline crea worktree, ejecuta writer+reviewer, valida scope y abre PR. Para seguir la corrida en vivo con el visor abierto en un tercer pane, usa `/mefisto-tooling-verbose <issue>` en su lugar (delega integramente en `/mefisto-tooling`, solo lanza con `--verbose`).
4. Revisa: comentarios del PR → `/mefisto-fix-review <pr>`.
5. Mergea: `/mefisto-merge <pr>` (squash + delete-branch, sin `pr-sync.sh`).
6. Pon al dia la bitacora: `/mefisto-bitacora` (invoca al agente `mefisto-historiador` y encadena `/mefisto-merge` automaticamente sobre el PR resultante).

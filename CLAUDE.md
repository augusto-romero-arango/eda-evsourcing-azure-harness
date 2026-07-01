# CLAUDE.md — mefisto

Harness opinionado para Claude Code (nombre interno: `mefisto`, repo: `eda-evsourcing-azure-harness`): orquesta el desarrollo asistido de aplicaciones .NET 10 serverless en Azure con Event Driven Architecture y Event Sourcing.

## Principios de respuesta

- Comunícate siempre en **español**.
- **Cita fuentes verificables** al afirmar una best practice o recomendación técnica — documentación oficial, libro, RFC, ADR del harness o del proyecto consumidor. Si es conocimiento general sin fuente, dilo explícitamente.

## Qué es este repo

Es un **Claude Code Plugin** (ver `.claude-plugin/plugin.json`) que empaqueta:

- 16 **skills** (slash commands) en `commands/`
- 17 **agentes** especializados en `agents/`
- Pipelines bash en `scripts/` (TDD, IaC, tooling, scaffolding, pr-sync, etc.)
- 22 **ADRs** del marco arquitectónico en `docs/adr/`
- Hooks en `hooks/hooks.json`

Está pensado para instalarse vía marketplace en cualquier proyecto que adopte el marco (EDA + Event Sourcing + Azure Functions + Marten + Wolverine + Postgres).

## Stack tecnológico del marco

- **Runtime**: .NET 10, C#, Azure Functions isolated worker
- **Persistencia**: PostgreSQL + Marten (event store)
- **Mediación de comandos**: Wolverine en modo serverless
- **Mensajería entre dominios**: Azure Service Bus (topic por evento — ver ADR-0001)
- **Testing**: xUnit v3 + `Cosmos.EventSourcing.Testing.Utilities` (DSL Given/When/Then/And — ver ADR-0002)
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
  }
}
```

`scripts/_pipeline-common.sh` carga este archivo con `jq` y exporta variables `HARNESS_*` que el resto de scripts consumen.

Notas sobre campos concretos:

- **`boundedContext`** (**obligatorio**, ADR-0023): declara el Bounded Context del proyecto. Un BC es un grupo de dominios relacionados que comparte un resource group de Azure y dos namespaces de Azure Service Bus (interno e integración). Tiene dos subfields:
  - **`name`**: nombre del BC, 1-63 caracteres alfanuméricos y guiones. Puede coincidir o no con `projectName` (ej: un proyecto "ControlAsistencias" puede tener BC "Principal"). `load_harness_config` valida `^[a-zA-Z0-9-]{1,63}$` y exporta `HARNESS_BC_NAME`.
  - **`domains`**: lista de dominios del BC, no vacía. Cada elemento debe estar presente en `domainLabels` (los dominios del BC son un subconjunto de todos los dominios del proyecto). `load_harness_config` valida la pertenencia y exporta `HARNESS_BC_DOMAINS` (lista separada por espacios).
  - El **resource group** del BC se genera como `infraResourceGroupPrefix`+`-`+`name` (ej: `rg-miproyecto-principal`). Lo computa el `infra-base-scaffolder` al provisionar la infraestructura base.
  - El **context map** (registro de BCs externos consumidos por este BC) es trabajo diferido a futuras evoluciones; hoy el BC solo se nombra a sí mismo. Ver nota en `load_harness_config`.
- **`serviceBus`** (opcional, ADR-0024 decisiones #1 y #6): registro de los Azure Service Bus que el BC toca, clasificados por **alcance**. El harness provisiona siempre el ASB **propio del BC** (interno, alias reservado `INTERNO`, decision #1); este registro declara su secreto de Key Vault y, opcionalmente, los ASB **compartidos del producto** o **verdaderamente externos** (decision #5, diferido) que el BC consume/publica. Subfields:
  - **`internal.secretName`**: nombre del secreto de Key Vault con la cadena de conexion del ASB propio del BC. **Obligatorio si se declara `serviceBus`**; `load_harness_config` aborta con mensaje accionable si esta vacio. La cadena de conexion **nunca** aparece en `harness.config.json` (decision #6).
  - **`external`** (opcional): lista de entradas `{ alias, alcance, secretName }`. `alias` identifica el ASB (no vacio, unico, distinto de `INTERNO` que queda reservado); `alcance` es `compartido` (backbone del producto) o `externo` (integracion verdaderamente externa, decision #5, diferida); `secretName` es el nombre del secreto de Key Vault de esa cadena (nunca en claro). Su ausencia no aborta la carga de config: un BC puede no consumir/publicar publico todavia.
  - `load_harness_config` valida la forma completa (secreto interno no vacio; cada entrada externa con alias/alcance/secretName no vacios y alcance en el enum; aliases unicos; `INTERNO` no reutilizable) y aborta temprano con mensaje explicito si es invalida. Exporta `HARNESS_SB_INTERNAL_SECRET` y, para `external`, tres listas paralelas separadas por espacios con el mismo orden posicional: `HARNESS_SB_EXTERNAL_ALIASES`, `HARNESS_SB_EXTERNAL_ALCANCES`, `HARNESS_SB_EXTERNAL_SECRETS`.
  - **Patron oficial del app setting**: cada cadena (interna o externa) se referencia en la Function App como `SERVICE_BUS_CONNECTION_<ALIAS>` — patron, no un token fijo; `INTERNO` es el alias reservado de la interna. La **clave de broker de Wolverine es el mismo alias** (ej. broker `"cosmos"` <-> `SERVICE_BUS_CONNECTION_COSMOS` <-> secreto de Key Vault del alias `COSMOS`). Reemplaza al viejo `SERVICE_BUS_CONNECTION_INTEGRACION` (namespace de integracion por BC, superado por ADR-0024). Esta es la convencion ancla que consumen `implementer`, `infra-base-scaffolder`, `domain-scaffolder` y el issue de Key Vault; no la reinventan.
  - El **diseño fino de wiring/provision** del alcance verdaderamente externo (ambas direcciones) queda diferido y default-off (ADR-0024 decision #5): este registro solo lo nombra, no lo materializa.
- **`terraformStateStorage`** es el nombre **base** de la Storage Account del tfstate. Azure exige **3-24 caracteres, solo minúsculas y dígitos** ([reglas de nombres de recursos, `Microsoft.Storage`](https://learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules#microsoftstorage)); `load_harness_config` valida `^[a-z0-9]{3,24}$` y aborta temprano si no cumple. El patrón `st<proyecto>tfstate<env>` deja ~12 chars para `<proyecto>`, así que para nombres largos abrevia el prefijo (p. ej. `stmicontrolplanetfstatedev` = 26 chars **inválido** → `stmcptfstatedev` = 15 válido). `bootstrap-backend.sh` le añade además un sufijo de unicidad global (detalle en README §3).
- **`repoSlug`** (opcional): slug `owner/repo` del fork de Mefisto al que se enrutan los drafts cross-repo (`estado:borrador`) que crean el `planner` y el `tooling-investigator`. Default: `augusto-romero-arango/eda-evsourcing-azure-harness`. **No** se exporta como `HARNESS_*`; se lee inline con `jq` donde se necesita (`_pipeline-common.sh`, `agents/planner.md`, `agents/tooling-investigator.md`).
- **`azureLocation`** (opcional): región de Azure para `bootstrap-backend.sh`; el flag `--location` la sobrescribe.

### 2. Sección "Tokens del harness" en `CLAUDE.md` raíz del consumidor

Necesaria porque los agentes/skills del harness no pueden hacer sustitución de variables. Los placeholders `<RootNamespace>`, `<SolutionFile>`, `<ProjectDisplayName>`, `<BoundedContext>` y `<BoundedContextDomains>` se resuelven leyendo `CLAUDE.md` del proyecto. Ejemplo mínimo:

```markdown
### Tokens del harness

- **RootNamespace**: MiProyecto.Nombre
- **SolutionFile**: MiProyecto.slnx
- **ProjectDisplayName**: MiProyecto
- **BoundedContext**: Principal  (nombre del BC; corresponde a `boundedContext.name` en harness.config.json)
- **BoundedContextDomains**: dominio1, dominio2  (lista separada por comas; corresponde a `boundedContext.domains`)
```

`BoundedContext` es el nombre del Bounded Context declarado en `harness.config.json` (ADR-0023): grupo de dominios relacionados que comparte un resource group de Azure y dos namespaces de Azure Service Bus (interno e integración). El nombre puede coincidir o no con `ProjectDisplayName`.

### 3. Estructura de carpetas esperada

- `src/<RootNamespace>.{Dominio}/` — Function App por dominio
- `tests/<RootNamespace>.{Dominio}.Tests/` — tests unitarios ES por dominio
- `tests/<RootNamespace>.{Dominio}.SmokeTests/` — smoke tests black-box (opcional)
- `infra/environments/{env}/` — Terraform por ambiente
- `.claude/pipeline/` — estado runtime de los pipelines (lo crea el harness en primer arranque)
- `docs/bitacora/field-notes/` — output de los agentes investigadores y de event-storming

## Catálogo de skills

| Skill | Propósito |
|---|---|
| `/onboard` | Diagnostica el onboarding del consumidor (config, labels, CI) y reporta un checklist; por defecto solo diagnostica, con provision opt-in (bajo confirmacion) de los labels faltantes y del CI hacia Azure (OIDC, ADR-0022) |
| `/draft` | Captura una idea como issue `estado:borrador` |
| `/implement` | Pipeline TDD para un issue `estado:listo` |
| `/tooling` | Pipeline de tooling (scripts, fixtures, config, agentes) |
| `/infra` | Pipeline IaC con Terraform (write → review → apply) |
| `/infra-base` | Genera la infraestructura base (8 módulos + esqueleto del entorno) en greenfield |
| `/parallel` | Corre varios issues en worktrees aislados |
| `/sequential` | Cadena de issues con merge automático |
| `/scaffold` | Crea el scaffold de un nuevo dominio |
| `/bug` | Investiga un síntoma (bug-investigator o tooling-investigator) |
| `/fix-review` | Resuelve comentarios pendientes de un PR |
| `/health-check` | Dashboard del entorno desplegado |
| `/work-status` | Progreso de los pipelines activos en tmux |
| `/show-flow` | Renderiza un flujo de `docs/eda/flows/` |
| `/eraser-diagram` | Genera diagrama para Eraser |
| `/merge` | Mergea uno o varios PRs a main |

## Agentes disponibles

| Agente | Cuándo usarlo |
|---|---|
| `planner` | Knowledge crunching, crear/refinar issues, organizar backlog |
| `event-stormer` | Sesión de descubrimiento de dominio (genera field notes) |
| `eda-modeler` | Formaliza flujos y aggregates en `docs/eda/` |
| `historiador` | Consolida field notes en la bitácora del día |
| `domain-scaffolder` | Crea scaffold de un nuevo dominio |
| `infra-base-scaffolder` | Genera la infraestructura base del consumidor (8 módulos + entorno) en greenfield |
| `test-writer` | Fase roja del pipeline TDD |
| `implementer` | Fase verde del pipeline TDD |
| `reviewer` | Revisión antes de crear PR |
| `smoke-test-writer` | Smoke tests contra entorno dev |
| `infra-writer` / `infra-reviewer` / `infra-applier` / `infra-bootstrap` | Etapas del pipeline IaC |
| `pr-sync` | Integra PRs de un batch paralelo |
| `bug-investigator` | Investiga errores del entorno desplegado |
| `tooling-investigator` | Investiga errores del tooling local |

## ADRs del marco

Los ADRs en `docs/adr/` son la fuente de verdad arquitectónica del harness. Los agentes los consultan, los aplican y documentan cuando se desvían. El proyecto consumidor puede tener sus propios ADRs adicionales (sobre dominio o configuración específica).

### Índice temático

| Tema | ADR |
|---|---|
| Topics de Service Bus por evento | ADR-0001 |
| Estrategia de testing con event sourcing (Given/When/Then) | ADR-0002 |
| Stack ES: Marten + Wolverine + Postgres | ADR-0003 |
| Manejo de errores en ES (eventos de fallo vs excepciones) | ADR-0004 |
| Naming y versionado de eventos | ADR-0005 |
| Convenciones de nombramiento de funciones Azure | ADR-0006 |
| Gestión de proyecto con GitHub Issues | ADR-0007 |
| Knowledge Crunching como propósito del planner | ADR-0008 |
| Mensajes en `.resx` por aggregate/handler | ADR-0009 |
| Pipeline de conocimiento del dominio | ADR-0010 |
| Definition of Ready por tipo de issue | ADR-0011 |
| Encapsulamiento, Tell-don't-Ask, value objects, frontera de serialización (event store Marten vs bus) | ADR-0012 |
| Smoke tests contra entorno dev | ADR-0013 |
| Coverage gate en pipeline TDD | ADR-0014 |
| Snapshots de Marten como excepción | ADR-0015 |
| Convención de naming para métodos de test | ADR-0016 |
| Archivo señal de refactor puro vive fuera de `.claude/` | ADR-0017 |
| Heurísticas de evolución y reuso del código (Rule of Three, etc.) | ADR-0018 |
| Separación física de skills publicados vs internos | ADR-0019 |
| Hosting de Azure Functions (un App Service Plan por dominio) | ADR-0020 |
| Infraestructura base (8 módulos + entorno) generada por agente | ADR-0021 |
| Autenticación de CI hacia Azure por OIDC (Workload Identity Federation) | ADR-0022 |
| Bounded Context, namespace interno de ASB y frontera publico/privado | ADR-0023 |
| Modelo de eventos de bus (privado propio, publico via backbone compartido, externo diferido) | ADR-0024 |

## Convenciones del marco

### Issues (gestionados con GitHub)

- **Títulos**: `[verbo infinitivo] [qué cosa]` — sin prefijos.
- **Labels obligatorios**: `tipo:X` + `dom:X` + `estado:{borrador|listo}` (asignados por el planner).
- **Dependencias**: declaradas en sección `## Dependencias`.
- **Bloqueados**: label `bloqueado` cuando dependen de otro no cerrado.
- **Definition of Ready**: ver ADR-0011 — los skills de pipeline lo validan antes de ejecutar.

### Flujo de entrega

- **Nunca trabajar contra `main` directo.** Toda edición de archivos en este repo se hace en una rama nueva y se entrega vía Pull Request.
- Antes de editar, si la rama activa es `main`, crear una nueva con `git switch -c <rama>` usando un slug descriptivo (`docs/<slug>`, `feat/<slug>`, `fix/<slug>`).
- Si por error ya se hicieron cambios sin commitear en `main`, mover a rama con `git switch -c <rama>` (preserva los cambios) antes de commitear.
- Al terminar: `git push -u origin <rama>` + `gh pr create` apuntando a `main`.

### Código C#

- **Caracteres prohibidos en `.cs`**: nunca `─` (U+2500) ni decorativos Unicode. Solo guión ASCII `-`.
- **Commits**: en español, descriptivos, frecuentes.
- **Ramas de trabajo**: `worktree-issue-<num>-<slug>` (los pipelines las crean para el proyecto consumidor).
- **PRs**: deben incluir `Closes #<número>` cuando resuelven un issue.

## Notas para definir agentes y skills

- Las herramientas MCP requieren declaración explícita cuando un agente usa allowlist `tools:`. Usa wildcard: `mcp__<servidor>__*`.
- Si el agente **no** define `tools:`, hereda todas incluyendo MCP.

## Dos paquetes de tooling: publicado vs interno

Mefisto distingue **dos sets** de skills/agentes/pipelines físicamente separados:

### Skills publicados (top-level del repo)

- Viven en `commands/`, `agents/`, `scripts/`, `hooks/`.
- Se distribuyen vía marketplace de Claude Code y son los que ve el proyecto consumidor cuando instala `mefisto`.
- **Operan únicamente sobre archivos del consumidor**. Nunca tocan archivos del propio plugin.
- Cada uno tiene un **guard defensivo** al inicio que aborta si `.claude-plugin/plugin.json` existe en el cwd (es decir, si por error alguien los invoca dentro del repo de Mefisto).
- El skill `/tooling` publicado tiene además un **gate de scope** (`validate_consumer_scope_changes` en `scripts/_pipeline-common.sh`) que rechaza el PR si el agente toca rutas reservadas al plugin (`commands/`, `agents/`, `hooks/`, `.claude-plugin/`, `docs/adr/`).
- El planner publicado y el `tooling-investigator` pueden **crear drafts** en el repo de Mefisto vía `gh -R …` cuando detectan que un problema descubierto en el consumidor pertenece al harness. Solo `estado:borrador`; el refinamiento ocurre dentro del repo de Mefisto.

### Skills internos (en `.claude/` del repo de Mefisto)

- Viven en `.claude/commands/`, `.claude/agents/`, `.claude/scripts/`.
- **NO se publican vía marketplace**. Claude Code los carga automáticamente cuando se abre el repo de Mefisto, porque `.claude/commands/` y `.claude/agents/` son convenciones de configuración por-repo del propio Claude Code (separadas del plugin instalado).
- Llevan prefijo `mefisto-` para distinguirlos en pantalla: `/mefisto-tooling`, `/mefisto-sequential`, `/mefisto-plan`, `/mefisto-bug`, `/mefisto-fix-review`, `/mefisto-merge`, `/mefisto-work-status`, `/mefisto-release`.
- Cada uno tiene un **guard inverso**: aborta si `.claude-plugin/plugin.json` NO está en el cwd (i.e. si alguien los invoca fuera del repo de Mefisto).
- Operan exclusivamente sobre archivos del propio plugin: `commands/`, `agents/`, `scripts/`, `hooks/`, `docs/`, `.claude-plugin/`, `.claude/{commands,agents,scripts}/`, archivos de gobierno (`README.md`, `CLAUDE.md`, etc.).
- El pipeline interno (`.claude/scripts/mefisto-tooling-pipeline.sh`) usa `validate_mefisto_scope_changes` (definido en `.claude/scripts/_mefisto-common.sh`) para rechazar cambios fuera del scope.

### Skills sin equivalente interno

Mefisto es un harness, no un producto: no tiene aggregates, no es TDD .NET, no tiene infraestructura Terraform/Azure, no genera dominios, no se despliega y no modela flujos EDA. Por tanto **estos skills publicados NO tienen versión interna**:

- `/implement` — TDD .NET de dominio.
- `/infra` — Terraform/Azure.
- `/infra-base` — infraestructura base Terraform del consumidor.
- `/scaffold` — crear nuevo dominio.
- `/health-check` — App Insights.
- `/onboard` — diagnostica el onboarding del consumidor (su `harness.config.json`, sus labels, su CI hacia Azure); Mefisto no es un consumidor del harness, así que no hay nada que diagnosticar en su repo.
- `/show-flow`, `/eraser-diagram` — flujos EDA y diagramas.

Aún así, todos tienen guard defensivo "cwd != Mefisto" como cinturón + tirantes.

### Routing cross-repo: solo drafts

La única operación cross-repo permitida desde el consumidor hacia Mefisto es **crear un draft** (`estado:borrador`). El refinamiento (`estado:listo`), desglose, oleadas, backlog y limpieza de issues de Mefisto se hacen exclusivamente con `/mefisto-plan` dentro del repo del plugin.

### Grupos de trabajo homogéneos

`/parallel`, `/sequential` y `scripts/batch-pipeline.sh` validan al inicio que **no estamos en Mefisto** y se asumen homogéneos: todos los issues del grupo se consultan con `gh issue view N` sin `-R`, así que solo se procesan los del repo activo. No se admiten grupos mixtos.

## Instalación en un proyecto

Ver `README.md`.

## Trabajar sobre el propio plugin

Si estás clonando este repo (Mefisto) para evolucionarlo, **no necesitas instalar el plugin sobre sí mismo**. Claude Code carga automáticamente los skills internos desde `.claude/commands/` y `.claude/agents/` del repo activo. Los pipelines internos viven bajo `.claude/scripts/`.

Workflow típico:

1. Captura una idea: `/mefisto-plan` (modo draft) o `gh issue create --label "estado:borrador,tipo:tooling" --title "..."`.
2. Refina: `/mefisto-plan` (modo refinar) hasta `estado:listo`.
3. Implementa: `/mefisto-tooling <issue>`. El pipeline crea worktree, ejecuta writer+reviewer, valida scope y abre PR.
4. Revisa: comentarios del PR → `/mefisto-fix-review <pr>`.
5. Mergea: `/mefisto-merge <pr>` (squash + delete-branch, sin `pr-sync.sh`).

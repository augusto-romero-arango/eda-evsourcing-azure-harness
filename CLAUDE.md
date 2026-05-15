# CLAUDE.md — eda-evsourcing-azure-harness

Harness opinionado para Claude Code: orquesta el desarrollo asistido de aplicaciones .NET 10 serverless en Azure con Event Driven Architecture y Event Sourcing.

## Principios de respuesta

- Comunícate siempre en **español**.
- **Cita fuentes verificables** al afirmar una best practice o recomendación técnica — documentación oficial, libro, RFC, ADR del harness o del proyecto consumidor. Si es conocimiento general sin fuente, dilo explícitamente.

## Qué es este repo

Es un **Claude Code Plugin** (ver `.claude-plugin/plugin.json`) que empaqueta:

- 14 **skills** (slash commands) en `commands/`
- 16 **agentes** especializados en `agents/`
- Pipelines bash en `scripts/` (TDD, IaC, tooling, scaffolding, pr-sync, etc.)
- 18 **ADRs** del marco arquitectónico en `docs/adr/`
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
  "domainLabels": ["<dominio1>", "<dominio2>", "..."]
}
```

`scripts/_pipeline-common.sh` carga este archivo con `jq` y exporta variables `HARNESS_*` que el resto de scripts consumen.

### 2. Sección "Tokens del harness" en `CLAUDE.md` raíz del consumidor

Necesaria porque los agentes/skills del harness no pueden hacer sustitución de variables. Los placeholders `<RootNamespace>`, `<SolutionFile>`, `<ProjectDisplayName>` se resuelven leyendo `CLAUDE.md` del proyecto. Ejemplo mínimo:

```markdown
### Tokens del harness

- **RootNamespace**: MiProyecto.Nombre
- **SolutionFile**: MiProyecto.slnx
- **ProjectDisplayName**: MiProyecto
```

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
| `/draft` | Captura una idea como issue `estado:borrador` |
| `/implement` | Pipeline TDD para un issue `estado:listo` |
| `/tooling` | Pipeline de tooling (scripts, fixtures, config, agentes) |
| `/infra` | Pipeline IaC con Terraform (write → review → apply) |
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
| Encapsulamiento, Tell-don't-Ask, value objects, serialización Marten | ADR-0012 |
| Smoke tests contra entorno dev | ADR-0013 |
| Coverage gate en pipeline TDD | ADR-0014 |
| Snapshots de Marten como excepción | ADR-0015 |
| Convención de naming para métodos de test | ADR-0016 |
| Archivo señal de refactor puro vive fuera de `.claude/` | ADR-0017 |
| Heurísticas de evolución y reuso del código (Rule of Three, etc.) | ADR-0018 |

## Convenciones del marco

### Issues (gestionados con GitHub)

- **Títulos**: `[verbo infinitivo] [qué cosa]` — sin prefijos.
- **Labels obligatorios**: `tipo:X` + `dom:X` + `estado:{borrador|listo}` (asignados por el planner).
- **Dependencias**: declaradas en sección `## Dependencias`.
- **Bloqueados**: label `bloqueado` cuando dependen de otro no cerrado.
- **Definition of Ready**: ver ADR-0011 — los skills de pipeline lo validan antes de ejecutar.

### Código C#

- **Caracteres prohibidos en `.cs`**: nunca `─` (U+2500) ni decorativos Unicode. Solo guión ASCII `-`.
- **Commits**: en español, descriptivos, frecuentes.
- **Ramas de trabajo**: `worktree-issue-<num>-<slug>` (los pipelines las crean).
- **PRs**: deben incluir `Closes #<número>`.

## Notas para definir agentes y skills

- Las herramientas MCP requieren declaración explícita cuando un agente usa allowlist `tools:`. Usa wildcard: `mcp__<servidor>__*`.
- Si el agente **no** define `tools:`, hereda todas incluyendo MCP.

## Instalación en un proyecto

Ver `README.md`.

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
- **`secrets`** (opcional, issue #256): registro declarativo de todo secreto del BC que el step de siembra de `infra-cd.yml` itera en runtime (data-driven, sin líneas hardcodeadas por secreto). Cada entrada declara `name` (el secreto en Key Vault) y `source.type`/`source.value` — de dónde CI toma el valor a sembrar: `output` (un único `terraform output`, derivable) o `github-secret` (un único GitHub secret, no derivable). El tipo `composite` (fórmula fija reservada para `marten-connection`, el único secreto compuesto de varios outputs + un GitHub secret) lo escribe únicamente `infra-base-scaffolder`; el skill `/seed-secret` (que registra secretos nuevos post-greenfield) solo emite `output`/`github-secret`. `infra-base-scaffolder` registra idempotentemente los secretos fijos del BC (interno de ASB, `app-insights-connection`, `marten-connection`, uno por alias de `serviceBus.external[]`) la primera vez que genera `infra-cd.yml`.
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
- `tests/<RootNamespace>.{Dominio}.Tests/` — tests unitarios ES por dominio
- `tests/<RootNamespace>.{Dominio}.SmokeTests/` — smoke tests black-box (opcional)
- `infra/environments/{env}/` — Terraform por ambiente
- `.claude/pipeline/` — estado runtime de los pipelines (lo crea el harness en primer arranque)
- `docs/bitacora/field-notes/` — output de los agentes investigadores y de event-storming

## Catálogo de skills

| Skill | Propósito |
|---|---|
| `/onboard` | Diagnostica el onboarding del consumidor (config, labels, CI) y reporta un checklist; provisión opt-in bajo confirmación |
| `/draft` | Captura una idea como issue `estado:borrador` |
| `/implement` | Pipeline TDD para un issue `estado:listo` |
| `/tooling` | Pipeline de tooling (scripts, fixtures, config, agentes) |
| `/infra` | Pipeline IaC con Terraform (write → review → apply) |
| `/infra-base` | Genera la infraestructura base (8 módulos + esqueleto del entorno) en greenfield |
| `/seed-secret` | Registra y cablea un secreto nuevo post-greenfield (Key Vault + Function App de un dominio) |
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
| `infra-writer` / `infra-reviewer` / `infra-bootstrap` | Etapas del pipeline IaC (escritura y revision estatica local; el plan y el apply corren en CI, MEF-ADR-0022) |
| `pr-sync` | Integra PRs de un batch paralelo |
| `bug-investigator` | Investiga errores del entorno desplegado |
| `tooling-investigator` | Investiga errores del tooling local |

## ADRs del marco

Los ADRs en `docs/adr/` son la fuente de verdad arquitectónica del harness, identificados con el prefijo `MEF-ADR-` (esquema de identificación con prefijo por proyecto, ver **MEF-ADR-0030**). Los agentes los consultan, los aplican y documentan cuando se desvían.

El proyecto consumidor puede tener sus propios ADRs adicionales (sobre dominio o configuración específica). Adoptar el mismo esquema de prefijo es **opcional**: un consumidor nuevo puede elegir su propio código corto (p. ej. `CA-ADR-` para Control de Asistencias, `CPC-ADR-` para Cosmos ControlPlane) para desambiguar sus ADRs frente a los del marco; un consumidor con ADRs legados puede quedarse citándolos como `ADR-XXXX` a secas, sin conflicto — `ADR-XXXX` nunca coincide textualmente con `MEF-ADR-XXXX`.

### Índice temático

| Tema | ADR |
|---|---|
| Topics de Service Bus por evento | MEF-ADR-0001 |
| Estrategia de testing con event sourcing (Given/When/Then) | MEF-ADR-0002 |
| Stack ES: Marten + Wolverine + Postgres | MEF-ADR-0003 |
| Manejo de errores en ES (eventos de fallo vs excepciones) | MEF-ADR-0004 |
| Naming y versionado de eventos | MEF-ADR-0005 |
| Convenciones de nombramiento de funciones Azure | MEF-ADR-0006 |
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

### Código C#

- **Caracteres prohibidos en `.cs`**: nunca `─` (U+2500) ni decorativos Unicode. Solo guión ASCII `-`.
- **Commits**: en español, descriptivos, frecuentes.
- **Ramas de trabajo**: `worktree-issue-<num>-<slug>` (los pipelines las crean para el proyecto consumidor).
- **PRs**: deben incluir `Closes #<número>` cuando resuelven un issue.

## Notas para definir agentes y skills

- Las herramientas MCP requieren declaración explícita cuando un agente usa allowlist `tools:`. Usa wildcard: `mcp__<servidor>__*`.
- Si el agente **no** define `tools:`, hereda todas incluyendo MCP.

## Dos paquetes de tooling: publicado vs interno

Mefisto mantiene **dos sets** de skills/agentes/pipelines físicamente separados (doctrina completa en MEF-ADR-0019):

- **Publicados** (`commands/`, `agents/`, `scripts/`, `hooks/`): se distribuyen vía marketplace y operan únicamente sobre archivos del consumidor.
- **Internos** (`.claude/commands/`, `.claude/agents/`, `.claude/scripts/`): no se publican; Claude Code los carga al abrir este repo. Llevan prefijo `mefisto-` y operan solo sobre archivos del propio plugin.

La única operación cross-repo desde el consumidor hacia Mefisto es **crear drafts** (`estado:borrador`); el refinamiento y demás gestión de issues ocurre con `/mefisto-plan` dentro de este repo.

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

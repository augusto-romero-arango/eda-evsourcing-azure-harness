# CLAUDE.md — mefisto

Harness opinionado para Claude Code (nombre interno: `mefisto`, repo: `eda-evsourcing-azure-harness`): orquesta el desarrollo asistido de aplicaciones .NET 10 serverless en Azure con Event Driven Architecture y Event Sourcing.

## Principios de respuesta

- Comunícate siempre en **español**.
- **Cita fuentes verificables** al afirmar una best practice o recomendación técnica — documentación oficial, libro, RFC, ADR del harness o del proyecto consumidor. Si es conocimiento general sin fuente, dilo explícitamente.

## Qué es este repo

Es un **Claude Code Plugin** (ver `.claude-plugin/plugin.json`) que empaqueta skills, agentes,
pipelines bash, ADRs y hooks (ver `ls` en la raíz del repo para el layout exacto). Además incluye:

- Un **servidor MCP bundleado** en `.mcp.json` en la raíz del plugin (`mcpServers.microsoft-learn`, endpoint HTTP remoto de Microsoft Learn, sin autenticación — ningún secreto viaja en la configuración, MEF-ADR-0025): lo usa el `planner` para verificar documentación oficial de Azure/.NET/C# al redactar issues

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

Esquema completo de `.claude/harness.config.json`, secciones obligatorias del `CLAUDE.md` del
consumidor y estructura de carpetas esperada: ver skill interno `harness-config-contract`
(`.claude/skills/harness-config-contract/SKILL.md`).

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
| `/install-apim` | Instala/actualiza el gateway APIM (agente `apim-gateway-scaffolder`), cablea `TF_VAR_workos_client_id`/`TF_VAR_cors_allowed_origins` y ejecuta la transicion a->b de tenancy (MEF-ADR-0028 seccion 4): flip de `tenancy.strategy` + scaffold de la biblioteca `src/{RootNamespace}.TenantResolver/` (patron AsyncLocal + middleware) + migracion del `ITenantResolver` de todos los dominios ya scaffoldeados a esa biblioteca; expone ademas en el mismo flip los servidores MCP ya scaffoldeados del BC (modulo `apim-mcp-api` + enrutador del PRM, gate OAuth de la variante MCP/Connect) |
| `/install-auth` | Orquesta el camino completo de auth: encadena `/install-workos` -> gate humano (verifica `WORKOS_CLIENT_ID`/`WORKOS_API_KEY` via `gh`) -> `/install-apim`, stateless (delega en la idempotencia de ambos) |
| `/parallel` | Corre varios issues en worktrees aislados |
| `/sequential` | Cadena de issues con merge automático |
| `/scaffold` | Crea el scaffold de un nuevo dominio |
| `/scaffold-mcp` | Genera el proyecto de un servidor MCP (`{RootNamespace}.Mcp.{Proposito}`): Azure Functions isolated worker sin `ProjectReference` al BC, seams de HttpClients tipados y observabilidad, el propagador de identidad tenant/usuario y los componentes OAuth app-side de defensa en profundidad (PRM, validador de token, middleware), tool de ejemplo con el patron completo, endpoints de gate `VersionCheck`/`ReadyCheck`, unit tests base, el Terraform del servidor (Service Plan + Storage + Function App), el workflow de deploy encadenado tras el apply de infra y la suite `SmokeTests` e2e (cinco verificaciones canonicas) con el reusable `smoke-tests-mcp.yml` encadenado tras el deploy (fases 1+2+3 + identidad/OAuth app-side #819, agente `mcp-scaffolder`, MEF-ADR-0047/MEF-ADR-0048) |
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

Ver `docs/adr/INDICE-TEMATICO.md` (migrado fuera de este archivo por tamaño: era el 34% del
CLAUDE.md raíz). Mismo régimen de edición: `/mefisto-release` es el único que la consolida,
por fragmento en `changelog.d/<issue>.adr-index.md`.

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
- **Los cambios notables se anotan como fragmento en `changelog.d/`, nunca editando `CHANGELOG.md` ni el índice temático de ADRs (`docs/adr/INDICE-TEMATICO.md`)** (issue #380). Un archivo por issue (`changelog.d/<issue>.<categoria>.md`, y `changelog.d/<issue>.adr-index.md` si el issue toca `docs/adr/`); ver `changelog.d/README.md`. Editar esos dos archivos-índice por-PR es la contención que colisionaba entre PRs paralelos: sólo `/mefisto-release` los consolida, y sólo en su rama de release.

### Código C#

- **Caracteres prohibidos en `.cs`**: nunca `─` (U+2500) ni decorativos Unicode. Solo guión ASCII `-`.
- **Comentarios**: mínimos, ver MEF-ADR-0044 (umbral doble Context Delta + Decision Delta; default sin comentario).
- **Commits**: en español, descriptivos, frecuentes.
- **Ramas de trabajo**: `worktree-issue-<num>-<slug>` (los pipelines las crean para el proyecto consumidor).
- **PRs**: deben incluir `Closes #<número>` cuando resuelven un issue.

## Notas para definir agentes y skills

Declaración de tools MCP en allowlists (incluido el prefijo scoped cuando el servidor lo provee
un plugin) y cuándo envolver doctrina extensa en un Agent Skill: ver skill interno
`agent-skill-authoring` (`.claude/skills/agent-skill-authoring/SKILL.md`).

## Dos paquetes de tooling: publicado vs interno

Mefisto mantiene **dos sets** de skills/agentes/pipelines físicamente separados (doctrina completa en MEF-ADR-0019):

- **Publicados** (`commands/`, `skills/`, `agents/`, `scripts/`, `hooks/`): se distribuyen vía marketplace y operan únicamente sobre archivos del consumidor.
- **Internos** (`.claude/commands/`, `.claude/skills/`, `.claude/agents/`, `.claude/scripts/`): no se publican; Claude Code los carga al abrir este repo. Llevan prefijo `mefisto-` y operan solo sobre archivos del propio plugin.

`skills/` y `.claude/skills/` son las ubicaciones de Agent Skills (MEF-ADR-0033) y ya están registradas en los gates de scope; el primero publicado es `skills/projections/` (ver "Agent Skills disponibles"), y del lado interno están `harness-config-contract` y `agent-skill-authoring` (migrados desde este mismo `CLAUDE.md`). La integridad de todo Skill nuevo (su `name` frontmatter, sus recursos de Nivel 3 y las referencias `skills:` de los agentes) la valida el bloque `[F]` de `scripts/tests/test-guards.sh`: un `skills:` mal escrito degrada en silencio, sin error visible en un pipeline headless. **Todo tipo de artefacto nuevo del plugin debe registrarse a mano** en el blocklist publicado (`is_path_in_consumer_blocklist`) y en la allowlist interna (`is_path_in_mefisto_scope`): ambos enumeran rutas explícitamente. Ese registro y el uso de la ruta son **dos PRs distintos, y el de registro va primero** — el gate que juzga un PR se carga fuera de su worktree, así que un PR que registra una ruta y la puebla a la vez se autobloquea (regla completa en MEF-ADR-0019, sección E).

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

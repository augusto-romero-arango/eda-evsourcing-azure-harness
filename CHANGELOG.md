# Changelog

Todo cambio notable a este proyecto se documenta aquí. Sigue [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y [Semantic Versioning](https://semver.org/lang/es/).

## [Unreleased]

### Added

- **Microconvencion de estilo "condiciones en positivo"** en `implementer.md`: prescribe preferir `if (existe)` sobre `if (!existe)`, ordenar las ramas `if`/`else` para que la guarda quede afirmativa, y documenta la excepcion de las guard clauses / early-return. El `reviewer` la verifica en fase refactor bajo el lente "Legible". Tambien se corrigio el ejemplo canonico de crear-o-actualizar que mostraba la guarda negada.
- **Recordatorio de CHANGELOG en `/mefisto-tooling`**: el pipeline interno verifica al final (warning, no gate) si el PR anadio contenido bajo `## [Unreleased]` en `CHANGELOG.md` y, de no ser asi, emite un recordatorio accionable. El PR se crea igual. Evita que los cambios lleguen a `main` con `[Unreleased]` vacio y rompan la fase *prepare* de `/mefisto-release` (issue #36).
- **ADR-0020** "Hosting de Azure Functions - un App Service Plan por dominio" (issue #44): fija la directiva canonica del marco de **un App Service Plan dedicado por Function App (dominio)**, no compartido. Documenta la restriccion dura de `DurabilityMode.Solo` (un solo nodo -> prohibido escalar horizontal -> solo eje vertical -> aislar por app), el sintoma noisy-neighbor de los agentes de durabilidad always-on, las proscripciones (no Consumption `Y1` con .NET 10+, no Wolverine `Serverless` mode), los defaults (`B1`, `worker_count = 1`, `always_on` OFF en dev / evaluar ON en prod) y el contrato del modulo `modules/service-plan` del consumidor. Se registra en el indice de `CLAUDE.md` (junto con ADR-0019, antes omitido) y se corrige el conteo de ADRs en `README.md` (18 -> 20).

### Changed

- **Scaffolder emite un App Service Plan dedicado por Function App** (issue #43): el agente `domain-scaffolder` (Paso 4) ahora genera un `module service_plan_<dominio>` propio por dominio (`source ../../modules/service-plan`, `name = asp-...-<dominio>`, `sku_name`, `worker_count = 1`, `os_type`, `always_on`) y enlaza la Function App a ese plan (`service_plan_id = module.service_plan_<dominio>.id`), en lugar de apuntar todas a un `module.service_plan` compartido (la causa del noisy-neighbor que origino el #43). El flujo de aprovisionamiento (Parametros de entrada y Paso 0) **pide/acepta los parametros de hosting** (SKU default `B1`, `always_on` OFF en dev) con override del usuario y los muestra en el resumen de confirmacion. Se anade un aviso si el modulo `modules/service-plan` del consumidor no acepta esos inputs (mismo patron que el aviso de `module.postgresql`). El `infra-writer` actualiza el naming de Service Plans a `asp-<proyecto>-<env>-<dominio>`, el `infra-reviewer` agrega al checklist de Arquitectura "cada Function App tiene su Service Plan dedicado" y lo refleja en el resumen del plan, y `/scaffold` incluye el Service Plan dedicado en el resumen de "lo que se va a crear". Alinea el harness con ADR-0020 (#44). Aplica a dominios nuevos; no migra infra existente.
- **Fase 5 de `/fix-review` (publicado) adaptada al modelo plugin** (issue #38): las mejoras a agentes/skills del harness ya no se editan en la rama del PR del consumidor (esos archivos viven read-only en el cache del plugin), sino que se enrutan como **draft** (`estado:borrador`) al repo de Mefisto via `gh -R`, reutilizando el routing cross-repo del `planner` y el `tooling-investigator`. La edicion en-rama queda reservada a lo que realmente vive en el consumidor (ADR local, convenciones de su `CLAUDE.md`). Se documenta la deteccion de modelo plugin y la field note sigue generandose en el consumidor.
- **`bug-investigator` detecta el noisy-neighbor y verifica el aislamiento por Service Plan** (issue #45): el paso de verificacion de infra del triage de deploy se **re-ancla a ADR-0020 del harness** como fuente de verdad del aislamiento por plan (antes apuntaba vagamente "al ADR de hosting del proyecto consumidor"; el consumidor puede tener un ADR local complementario que no la contradiga) e incorpora el chequeo de que cada Function App corre en su propio App Service Plan dedicado (`asp-<proyecto>-<env>-<dominio>`), con comando de verificacion (`az appservice plan show --query numberOfSites`) y su equivalente en Terraform (`service_plan_id` por dominio). Se anade la seccion **"Patron de diagnostico: noisy neighbor por plan compartido"** que ensena a reconocer la firma del sintoma (CPU del plan alta en reposo con 0 requests y 0 mensajes de Service Bus), su verificacion (`az monitor metrics list --metric CpuPercentage` cruzado con el trafico real), la causa raiz (`DurabilityMode.Solo` con su agente de durabilidad always-on) y el eje de mitigacion critico (solo vertical o aislar por app; **nunca** escalar out con `Solo`). Alinea el agente con ADR-0020 (#44); origen #43.

## [0.3.0] - 2026-06-17

### Added

- **Set de skills, agentes y pipelines internos** para evolucionar el propio harness (no se publican vía marketplace; viven en `.claude/`): agentes `mefisto-planner` y `mefisto-investigator`, y comandos `/mefisto-plan`, `/mefisto-tooling`, `/mefisto-bug`, `/mefisto-fix-review`, `/mefisto-merge`, `/mefisto-work-status`, con sus pipelines `_mefisto-common.sh`, `mefisto-tmux-pipeline.sh` y `mefisto-tooling-pipeline.sh`.
- **Skill interno `/mefisto-release`** para versionar y publicar el plugin siguiendo SemVer y Keep a Changelog (fases prepare y publish).
- **Skill interno `/mefisto-sequential`** para procesar varios issues internos en cadena dentro de una sesión tmux, con `mefisto-batch-pipeline.sh`.
- **Routing de drafts cross-repo**: el `planner` y el `tooling-investigator` publicados pueden crear drafts (`estado:borrador`) en el repo de Mefisto cuando detectan que un problema del consumidor pertenece al harness.
- **Slug del repo de Mefisto configurable** en `validate_consumer_scope_changes`, en lugar de estar hardcoded.
- **Guards defensivos "cwd != Mefisto"** en todos los skills publicados, en los pipelines TDD/IaC/scaffold/tmux y en los scripts auxiliares (`appinsights-query`, `eda-lint`, `setup-github-*`), para que el tooling publicado nunca opere por error sobre el repo del propio plugin.
- **Scope-gate del `/tooling` publicado**, que lo restringe a archivos del consumidor y rechaza el PR si toca rutas reservadas al plugin.
- **ADR-0019** "Skills publicados vs internos", que formaliza la separación entre el paquete distribuido y el tooling interno.
- **Suite de tests de guards y scope** en `scripts/tests/test-guards.sh`.
- **LICENSE MIT** al publicar el repositorio.

### Changed

- **Documentado el modelo de skills publicados vs internos** en `CLAUDE.md` y `README.md`.
- **Regla de entrega**: todo cambio se hace en rama y se entrega vía Pull Request; nunca contra `main` directo (documentado en `CLAUDE.md`).
- **`eda-modeler`**: eliminados los dominios y contratos hardcoded de un consumidor concreto.
- **`tooling-investigator`**: aclarados sus límites y retirada la etiqueta `dom:tooling` (inexistente en Mefisto).
- **Eliminado el `git push` directo a `main`** en el agente `historiador` y en los skills `fix-review` / `mefisto-fix-review`; ahora pasan por rama + PR.
- **README**: añadida la sección "El nombre" con la cita de Fausto que origina el nombre interno `mefisto`.

### Fixed

- **Resolución del repo objetivo del consumidor** en `tmux-pipeline.sh` y `eda-lint.sh`: ya no se deriva de la ubicación del script (`$SCRIPT_DIR/..`, que bajo el modelo de plugin apunta al propio harness) sino del toplevel del repo activo vía `git rev-parse --show-toplevel`.
- **Referencias rotas** en los skills `draft`, `health-check` y `show-flow`, y en el ADR-0007.
- **Referencias a ADRs con numeración del consumidor** en los agentes publicados (`planner`, `reviewer`, `test-writer`) y en `implement`.
- **Resolución del pane del script en tmux** vía `pane_id` en lugar del índice de pane, frágil ante reordenamientos.

## [0.2.0] — 2026-05-15

### Changed (BREAKING)

- **Renombrar el plugin de `eda-evsourcing-azure-harness` a `mefisto`** para acortar el namespace de los skills. Los skills ahora son `/mefisto:implement`, `/mefisto:scaffold`, `/mefisto:infra`, etc. (antes `/eda-evsourcing-azure-harness:implement`, etc.).
- `.claude-plugin/plugin.json.name`: `eda-evsourcing-azure-harness` → `mefisto`.
- `.claude-plugin/marketplace.json.plugins[0].name`: `eda-evsourcing-azure-harness` → `mefisto`.

El nombre del marketplace (`augusto-romero-arango-harness`) y la URL del repositorio (`eda-evsourcing-azure-harness`) no cambian.

### Migración para consumidores

Quien tuviera v0.1.x instalado debe reinstalar:

```
/plugin uninstall eda-evsourcing-azure-harness@augusto-romero-arango-harness
/plugin marketplace update augusto-romero-arango-harness
/plugin install mefisto@augusto-romero-arango-harness
```

Y reemplazar referencias en `CLAUDE.md` del proyecto: `/eda-evsourcing-azure-harness:*` → `/mefisto:*`.

## [0.1.2] — 2026-05-15

### Fixed

- `hooks/hooks.json`: el contenido debía estar envuelto en `{ "hooks": {...} }` en lugar de tener los eventos como root. Sin este fix, `claude plugin doctor` reporta: `Hook load failed: expected record, received undefined at path "hooks"`.

## [0.1.1] — 2026-05-15

### Fixed

- `.claude-plugin/marketplace.json`: el `source` del plugin pasa de `"."` (no soportado, falla con "This plugin uses a source type your Claude Code version does not support") a `"./"`, formato esperado por el schema (pattern `^\.\/.*`). Sin este fix, `/plugin install` falla.

## [0.1.0] — 2026-05-15

### Added

- Extracción inicial del harness desde el repo `Bitakora.ControlAsistencia` como Claude Code Plugin independiente.
- **14 skills** (slash commands) en `commands/`: scaffold, implement, tooling, sequential, show-flow, draft, fix-review, infra, parallel, health-check, work-status, bug, merge, eraser-diagram.
- **16 agentes** en `agents/`: planner, test-writer, implementer, reviewer, smoke-test-writer, domain-scaffolder, eda-modeler, event-stormer, historiador, infra-writer, infra-reviewer, infra-applier, infra-bootstrap, pr-sync, bug-investigator, tooling-investigator.
- **Pipelines bash** en `scripts/`: tdd, tooling, iac, scaffold, parallel, batch, tmux, pr-sync, eda-lint, appinsights-query, setup-github-ci, setup-github-labels, _pipeline-common.
- **`scripts/_pipeline-common.sh`** con `load_harness_config()` que parsea `.claude/harness.config.json` del consumidor y exporta variables `HARNESS_*`.
- **18 ADRs** del marco en `docs/adr/`, renumerados secuencialmente:
  - ADR-0001 Service Bus topics por evento
  - ADR-0002 Estrategia de testing con event sourcing
  - ADR-0003 Event Sourcing con Marten y Wolverine
  - ADR-0004 Manejo de errores en ES
  - ADR-0005 Naming y versionado de eventos
  - ADR-0006 Convenciones de nombramiento de funciones Azure
  - ADR-0007 Gestión de proyecto con GitHub Issues
  - ADR-0008 Knowledge Crunching como propósito del planner
  - ADR-0009 Mensajes con .resx per-aggregate
  - ADR-0010 Pipeline de conocimiento del dominio
  - ADR-0011 Definition of Ready
  - ADR-0012 Estilo de modelado de objetos de dominio
  - ADR-0013 Smoke tests contra entorno dev
  - ADR-0014 Coverage gate en pipeline TDD
  - ADR-0015 Snapshots de Marten como excepción
  - ADR-0016 Convención de naming de tests
  - ADR-0017 Archivo señal de refactor fuera de `.claude/`
  - ADR-0018 Heurísticas de evolución y reuso
- **`hooks/hooks.json`** con PostToolUse para logging de archivos modificados, tests y operaciones Terraform.
- **`.claude-plugin/plugin.json`** y **`marketplace.json`** con metadata del plugin y catálogo del marketplace `augusto-romero-arango-harness`.
- **`CLAUDE.md`** y **`README.md`** documentando el harness, su contrato con el consumidor y la instalación.

### Contrato con el consumidor (nuevo)

- `.claude/harness.config.json` con campos: `projectName`, `namespacePrefix`, `solutionFile`, `infraResourceGroupPrefix`, `terraformStateStorage`, `githubServicePrincipalName`, `appInsightsApp`, `domainLabels`.
- Sección "Tokens del harness" en `CLAUDE.md` raíz del consumidor declarando `RootNamespace`, `SolutionFile`, `ProjectDisplayName`.

### Notas

- Algunos ADRs referencian ADRs del proyecto consumidor (Function App por dominio, Contracts, control de costos de App Insights, hosting de Azure Functions). Esas referencias quedan como "ADR del proyecto consumidor sobre X" hasta que cada proyecto las nombre.
- Los agentes `reviewer` e `implementer` mantienen el placeholder literal `ADR-XXXX` en sus plantillas de reporte (no es un bug; el agente lo sustituye en tiempo de ejecución por el número real del ADR aplicable).
- Los ejemplos de código en `test-writer.md`, `implementer.md` y `smoke-test-writer.md` conservan nombres concretos de un proyecto consumidor (`Programacion`, `ControlHoras`) anotados en el "Contrato con el consumidor" de cada agente como ejemplos pedagógicos.

[Unreleased]: https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/compare/v0.2.0...v0.3.0
[0.1.0]: https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/releases/tag/v0.1.0

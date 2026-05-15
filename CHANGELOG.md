# Changelog

Todo cambio notable a este proyecto se documenta aquí. Sigue [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y [Semantic Versioning](https://semver.org/lang/es/).

## [Unreleased]

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

[Unreleased]: https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/releases/tag/v0.1.0

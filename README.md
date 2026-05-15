# mefisto

> Repositorio: `eda-evsourcing-azure-harness` · Nombre del plugin: `mefisto`

Plugin de [Claude Code](https://code.claude.com/docs/en/plugins) que provee un harness opinionado para construir aplicaciones .NET 10 serverless en Azure con Event Driven Architecture y Event Sourcing.

> Estado: **v0.1.0 (internal alpha)** — extraído del proyecto Bitakora.ControlAsistencia el 2026-05-15. La API del harness puede cambiar entre versiones menores hasta `v1.0.0`.

## Qué incluye

- **14 skills** (slash commands): `/implement`, `/tooling`, `/infra`, `/scaffold`, `/parallel`, `/sequential`, `/bug`, `/draft`, `/fix-review`, `/health-check`, `/work-status`, `/show-flow`, `/eraser-diagram`, `/merge`.
- **16 agentes** especializados: `planner`, `test-writer`, `implementer`, `reviewer`, `smoke-test-writer`, `domain-scaffolder`, `eda-modeler`, `event-stormer`, `historiador`, `infra-writer`, `infra-reviewer`, `infra-applier`, `infra-bootstrap`, `pr-sync`, `bug-investigator`, `tooling-investigator`.
- **Pipelines bash** que orquestan el ciclo TDD, IaC y tooling sobre `tmux` y `git worktree`.
- **18 ADRs** del marco arquitectónico.
- **Hooks** para logging del pipeline.

## Stack supuesto en el consumidor

- .NET 10 + Azure Functions isolated worker
- Marten (event store) + Wolverine (mediador) sobre PostgreSQL
- Azure Service Bus (topic por evento)
- xUnit v3 + `Cosmos.EventSourcing.Testing.Utilities`
- Terraform para IaC
- GitHub Actions para CI/CD

Si tu proyecto no encaja con este stack, este harness no es para ti.

## Instalación

### 1. Registrar el marketplace en `.claude/settings.json` del repo consumidor

```json
{
  "extraKnownMarketplaces": {
    "augusto-romero-arango-harness": {
      "source": {
        "type": "github",
        "repo": "augusto-romero-arango/eda-evsourcing-azure-harness"
      }
    }
  }
}
```

### 2. Instalar el plugin (desde Claude Code)

```
/plugin marketplace add augusto-romero-arango-harness
/plugin install mefisto@augusto-romero-arango-harness
```

### 3. Configurar el consumidor

Crea `.claude/harness.config.json` en la raíz del proyecto consumidor:

```json
{
  "projectName": "MiProyecto",
  "namespacePrefix": "MiOrg.MiProyecto",
  "solutionFile": "MiProyecto.slnx",
  "infraResourceGroupPrefix": "rg-miproyecto",
  "terraformStateStorage": "stmiproyectotfstatedev",
  "githubServicePrincipalName": "github-miproyecto-ci",
  "appInsightsApp": "miproyecto-dev-ai",
  "domainLabels": ["dominio1", "dominio2"]
}
```

Y añade una sección a `CLAUDE.md` raíz del consumidor declarando los tokens:

```markdown
### Tokens del harness

- **RootNamespace**: MiOrg.MiProyecto
- **SolutionFile**: MiProyecto.slnx
- **ProjectDisplayName**: MiProyecto
```

### 4. Verificar instalación

```
/mefisto:show-flow
/mefisto:work-status
```

Si responden sin errores, está listo.

## Uso

Los skills aparecen con el namespace del plugin: `/mefisto:implement <issue>`, `/mefisto:scaffold <dominio>`, etc.

Flujo típico:

```
/draft "registrar marcaciones biométricas"     # captura idea como issue borrador
# planner refina el issue a estado:listo
/implement <issue>                              # pipeline TDD
# pr-sync mergea el PR
```

## Estructura del plugin

```
.claude-plugin/
  plugin.json          # metadata (name, version, author)
  marketplace.json     # catálogo
commands/              # 14 skills
agents/                # 16 agentes
scripts/               # pipelines + utilidades bash
hooks/hooks.json       # PostToolUse para logging
docs/
  adr/                 # 18 ADRs del marco
  tmux-cheatsheet.md
  testing/harness-cheatsheet.md
CLAUDE.md              # documentación viva para Claude Code
CHANGELOG.md
```

## Compatibilidad y versionado

Sigue [SemVer](https://semver.org/):

- **MAJOR**: cambios incompatibles del schema de `harness.config.json` o de paths/contratos esperados del consumidor.
- **MINOR**: nuevos skills/agentes/scripts.
- **PATCH**: fixes.

Cambios al schema de `harness.config.json` ⇒ MAJOR + nota de migración en `CHANGELOG.md`.

## Actualizar a una versión nueva

```
/plugin update mefisto
```

Revisa el `CHANGELOG.md` para notas de migración antes de actualizar entre majors.

## Requisitos del entorno

- `bash` 3.2+ (compatible con macOS nativo)
- `jq` (parser JSON, usado por `_pipeline-common.sh`)
- `gh` CLI autenticado
- `dotnet` 10.x
- `terraform` 1.6+
- `tmux` (para pipelines paralelos)
- `git` 2.x con soporte de worktrees

## Licencia

PROPRIETARY (uso interno).

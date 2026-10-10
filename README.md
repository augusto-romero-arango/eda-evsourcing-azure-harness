# mefisto

> Repositorio: `eda-evsourcing-azure-harness` · Nombre del plugin: `mefisto`

Plugin de [Claude Code](https://code.claude.com/docs/en/plugins) que provee un harness opinionado para construir aplicaciones .NET 10 serverless en Azure con Event Driven Architecture y Event Sourcing.

> Estado: **v0.1.0 (internal alpha)** — extraído del proyecto Bitakora.ControlAsistencia el 2026-05-15. La API del harness puede cambiar entre versiones menores hasta `v1.0.0`.

## El nombre

`mefisto` es un guiño a Mefistófeles, el espíritu de *Fausto* de Goethe. La analogía es simple: quien invoca el harness encarna a Fausto — fija la intención y firma el pacto —; el plugin, como Mefisto, ejecuta esa voluntad bajo las reglas del marco (EDA, Event Sourcing, Azure Functions, TDD).

> «Ich will mich hier zu deinem Dienst verbinden,
> auf deinen Wink nicht rasten und nicht ruhn».
>
> — Mefistófeles, *Fausto* I, escena «Studierzimmer», vv. 1656-1657
>
> *«Aquí me ataré a tu servicio, a tu menor seña no descansaré ni cesaré».*

## Qué incluye

- **Skills** (slash commands): `/onboard`, `/upgrade`, `/runtimes`, `/implement`, `/tooling`, `/infra`, `/infra-base`, `/scaffold`, `/scaffold-projections`, `/scaffold-mcp`, `/seed-secret`, `/install-workos`, `/install-apim`, `/install-auth`, `/parallel`, `/batch-stop`, `/next-order`, `/sequential`, `/bug`, `/draft`, `/fix-review`, `/health-check`, `/eraser-diagram`, `/merge`, `/bitacora`, `/purge-store`.
- **Agentes** especializados: `planner`, `test-writer`, `implementer`, `projection-test-writer`, `projection-implementer`, `projections-scaffolder`, `reviewer`, `smoke-test-writer`, `domain-scaffolder`, `infra-base-scaffolder`, `apim-gateway-scaffolder`, `workos-identity-scaffolder`, `historiador`, `infra-writer`, `infra-reviewer`, `infra-bootstrap`, `pr-sync`, `bug-investigator`, `tooling-investigator`.
- **Pipelines bash** que orquestan el ciclo TDD, IaC y tooling sobre `tmux` y `git worktree`.
- **ADRs** del marco arquitectónico (prefijo `MEF-ADR-`, ver [índice temático](docs/adr/INDICE-TEMATICO.md)).
- **Hooks** para logging del pipeline.
- Un **servidor MCP bundleado**: `microsoft-learn` (endpoint remoto oficial `https://learn.microsoft.com/api/mcp`, HTTP sin autenticación). En Claude Code se declara en `.mcp.json`; en OpenCode se proyecta globalmente como plugin local, sin modificar `opencode.json`. Terraform permanece externo: su instalación y los permisos por artefacto no forman parte de este bundle (la traducción de permisos OpenCode llega en #1145). Discovery certificado; invocación real no certificada — ver el veredicto de [`docs/testing/opencode-consumer-cutover.md`](docs/testing/opencode-consumer-cutover.md#veredicto-final-del-corte-vertical-1066).

## Soporte OpenCode: alcance certificado

Movida a [docs/guia-del-consumidor.md](docs/guia-del-consumidor.md#soporte-opencode-alcance-certificado).

## Stack supuesto en el consumidor

Movida a [docs/guia-del-consumidor.md](docs/guia-del-consumidor.md#stack-supuesto-en-el-consumidor).

## Instalación

Movida a [docs/guia-del-consumidor.md](docs/guia-del-consumidor.md#instalación).

## Primeros pasos con el harness (greenfield)

Movida a [docs/guia-del-consumidor.md](docs/guia-del-consumidor.md#primeros-pasos-con-el-harness-greenfield).

## Uso

Movida a [docs/guia-del-consumidor.md](docs/guia-del-consumidor.md#uso).

## Estructura del plugin

Movida a [docs/desarrollo-del-plugin.md](docs/desarrollo-del-plugin.md#estructura-del-plugin).

## Desarrollo del propio plugin

Movida a [docs/desarrollo-del-plugin.md](docs/desarrollo-del-plugin.md#desarrollo-del-propio-plugin).

## Migración para consumidores existentes

Movida a [docs/migracion-y-versionado.md](docs/migracion-y-versionado.md#migración-para-consumidores-existentes).

## Compatibilidad y versionado

Movida a [docs/migracion-y-versionado.md](docs/migracion-y-versionado.md#compatibilidad-y-versionado).

## Actualizar a una versión nueva

Movida a [docs/migracion-y-versionado.md](docs/migracion-y-versionado.md#actualizar-a-una-versión-nueva).

## Requisitos del entorno

- `bash` 3.2+ (compatible con macOS nativo)
- `jq` (parser JSON, usado por `_pipeline-common.sh`)
- `gh` CLI autenticado
- `dotnet` 10.x
- `terraform` 1.6+
- `tmux` (para pipelines paralelos)
- `git` 2.x con soporte de worktrees

## Licencia

Apache-2.0. Ver [`LICENSE`](LICENSE) y [`NOTICE`](NOTICE).

Se permite uso, modificacion y uso comercial conservando los avisos de licencia y atribucion.

---
fecha: 2026-09-23
hora: 16:33
sesion: mefisto-planner
tema: Porte de /infra a OpenCode con paridad (tmux + herdr)
---

## Contexto
El usuario pidio planear el porte de `/infra` a OpenCode manteniendo los estandares de Claude (logs y control del lote) en tmux y herdr.

## Descubrimientos
- `iac-pipeline.sh` es el ultimo pipeline de un issue atado a Claude: `claude -p`, hold con `claude -c`, copia de `.claude/settings.json` y estado en `.claude/pipeline`.
- `tmux-pipeline.sh` excluye `--infra` de la resolucion de runtime y no le pasa `MEFISTO_RUNTIME` al pane; herdr ya lo propaga via `--_pane-runner`.
- `infra-writer`/`infra-reviewer` no tienen fuente neutral; el MCP `terraform` ya esta registrado como `external`.
- En Claude, `tipo:infra` nunca entra en lotes (`SKIP:infra`), asi que `/batch-stop` no aplica a infra.

## Decisiones
- Alcance = paridad (opcion a): infra sigue siendo de un solo issue, visible en `/work-status`, fuera de `/sequential`/`/parallel`.
- Runner neutral y hold en un mismo issue: separarlos haria retroceder el hold de los consumidores Claude entre PRs.
- Perfiles: infra-writer -> balanced, infra-reviewer -> deep.

## Descartado
- Incluir `tipo:infra` en lotes y `--models`/`--variant` para `--infra` (Claude tampoco los tiene).

## Preguntas abiertas
- Consumidor sintetico con `infra/modules` base para la certificacion #1629.

## Referencias
Issues creados: #1624, #1625, #1626, #1627, #1628, #1629

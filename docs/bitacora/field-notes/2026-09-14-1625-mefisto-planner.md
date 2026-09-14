---
fecha: 2026-09-14
hora: 16:25
sesion: mefisto-planner
tema: Refinar #1360 y #1361 (tdd-pipeline.sh al runner neutral); brecha --agent del adaptador Claude
---

## Contexto
Refinar los drafts #1360 y #1361, primeros eslabones de la serie que migra `scripts/tdd-pipeline.sh` al runner neutral (`src/runtime/mefisto-run-agent.sh`) tras el veredicto PASA de #1066. Ambos drafts venian con template completo; la sesion se dedico a verificar cada afirmacion contra el codigo, resolver contradicciones de alcance y, al revisar el adaptador Claude, detectar una brecha que bloquea toda la serie.

## Descubrimientos
- **El adaptador Claude del runner no pasa `--agent`.** `runtime_claude_build_cmd` compone `claude -p <prompt> --permission-mode bypassPermissions --output-format stream-json --verbose [--model] [--append-system-prompt] [--resume]` y su cabecera declara que `<agent>` no participa del argv. Decision explicita de #879 ("El adaptador Claude no los usa en headless"), valida para tooling porque `agents/tooling-{writer,reviewer}.md` pesan ~1.3 KB y la doctrina viaja en el prompt. En TDD la doctrina vive en el agente (`test-writer` 78 KB, `implementer` 109 KB, `reviewer` 106 KB con `skills:`, `smoke-test-writer` 44 KB, `domain-scaffolder` 265 KB): migrar sin corregir el adaptador habria corrido esos stages bajo Claude sin doctrina, `tools:` ni skills (regresion silenciosa, contraria a MEF-ADR-0053 §5).
- `scripts/tdd-pipeline.sh` **no** esta en la clausura publicada: `generate-published-adapters.sh` solo lista `_pipeline-common.sh`, `tmux-pipeline.sh`, `herdr-pipeline.sh`, `stream-watch.sh` y `tooling-pipeline.sh`. Se edita en sitio; empaquetarlo es #1365.
- `mefisto-neutrality-gate.sh` excluye el arbol publicado `scripts/` (`scope_excluded` en `neutrality-allowlist.json`): listarlo como gate de un cambio en `scripts/` es ruido.
- Tests con acoplamiento estatico a tdd que rompen con la migracion: `test-agent-resume.sh` [2], `test-agent-failure-hold.sh` [10], `test-stream-json-trace.sh` [H], `test-stage-models.sh` [10b] (run_agent, #1360) y [10c] (remediacion 4b/4c, #1361). Los drafts no listaban `test-stage-models.sh` ni `test-stream-json-trace.sh` para #1361.
- `test-stage-metrics.sh` [K] sigue verde sin cambios si se conservan `compute_stage_metrics`, la ruta `$PIPELINE_DIR_ABS/metrics/tdd-...` y la cosecha por stage. Baseline 2026-09-14: 40/0, `test-stage-models.sh` 138/0, `test-stream-json-trace.sh` 25/0.
- `PIPELINE_CAPTURE_STREAM` vive en 8 sitios fuera de `run_agent` (Stage 0, remediacion, `abort()`, history final) mas su bloque jq: no puede eliminarse en #1360 sin tocar codigo de #1361.
- Stage 0 de tdd no emite hoy linea `MODELS:` (4b/4c si); `scaffold-pipeline.sh` si la emite para `domain-scaffolder`.
- La sonda de hold en tdd degrada con `SUMMARY_FILE` en `$WORKTREE_PATH/.claude/pipeline/summaries/` (ruta legacy); la canonica via `mefisto_state_path` es #1364.

## Decisiones
- **Nuevo #1368 "Pasar --agent al adaptador Claude del runner neutral"** (`estado:listo`): una linea en `runtime_claude_build_cmd`, cabecera, `src/runtime/contract/README.md`, asserts en `.claude/scripts/tests/test-runtime-claude.sh` [A]/[F] y test estatico de existencia de los agentes que hoy pasan por el runner. #1360 pasa a depender de el (`bloqueado`); #1361-#1365 heredan la dependencia.
- **Opcion A** para `PIPELINE_CAPTURE_STREAM` en #1360: se conserva la variable y su bloque jq; solo deja de referenciarse dentro de `run_agent`. #1361 la retira por completo (bloque jq, `abort()`, history final).
- **No partir CA-4/CA-5 de #1360** (hold+resume+denials): un estado intermedio "runner neutral sin hold" regresa MEF-ADR-0051 y la sonda `-c` legacy no puede reanudar sesiones del runner. Precedente: #1062/PR #1142 hizo el mismo alcance en un PR.
- #1360: CA-3 explicita el gate por stage del atajo de recuperacion (1 -> `dotnet build`; 2/3/merge -> `run_tests_projects`); CA-5 usa el criterio de trabajo util que tdd ya tiene (`status --porcelain -- tests/ src/`); CA-6 retira `mefisto-neutrality-gate.sh` y agrega `test-stage-models.sh` [10b].
- #1361: helper `invoke_agent_once` (opcion A) recomendado, con contrato explicito; Stage 0 gana linea `MODELS: stage 0/domain-scaffolder -> ...` (frontmatter|heredado, nunca `--model`); timeouts unificados en `MEFISTO_AGENT_TIMEOUT_SECONDS` sin cambio de comportamiento (los tres fijaban 1800); `CG_TIMEOUT_MEASURE` se conserva (no es agente); CA-6 corrige [10b] -> [10c] y agrega `test-stream-json-trace.sh` [H].
- #1360 y #1361 pasan a `estado:listo` (#1361 sigue `bloqueado` por #1360; #1360 `bloqueado` por #1368).

## Descartado
- Opcion B para `PIPELINE_CAPTURE_STREAM` (eliminarla en #1360): ampliaba el scope a l.525-560 y l.1836-1960, declaradas intocables por el propio issue.
- Inyectar la doctrina de los agentes TDD por `--system-file` en vez de corregir el adaptador: 265 KB de system prompt y se pierden `tools:` y `skills:`.

## Preguntas abiertas
- Bajo OpenCode, `opencode run --agent test-writer` exige que el consumidor tenga los agentes TDD proyectados en `.opencode/agents/`; hoy solo `tooling-*` estan renderizados. Pertenece a #1365 (clausura publicada) o a un issue propio de proyeccion; no se abordo en esta sesion.
- Orden sugerido del batch: #1368 -> #1360 -> #1361 (lo confirma `/mefisto-next-order`).

## Referencias
Issues creados: #1368.
Issues refinados: #1360, #1361 (`estado:borrador` -> `estado:listo`).

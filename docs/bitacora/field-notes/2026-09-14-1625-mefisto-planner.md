---
fecha: 2026-09-14
hora: 16:25
sesion: mefisto-planner
tema: Refinar #1360 (run_agent de tdd-pipeline.sh al runner neutral)
---

## Contexto
Refinar el draft #1360, primer eslabon de la serie que migra `scripts/tdd-pipeline.sh` al runner neutral (`src/runtime/mefisto-run-agent.sh`) tras el veredicto PASA de #1066. El draft ya venia con template completo; la sesion se dedico a verificar cada afirmacion contra el codigo y a resolver una contradiccion de alcance.

## Descubrimientos
- `scripts/tdd-pipeline.sh` **no** esta en la clausura publicada: `generate-published-adapters.sh` solo lista `_pipeline-common.sh`, `tmux-pipeline.sh`, `herdr-pipeline.sh`, `stream-watch.sh` y `tooling-pipeline.sh`. Se edita en sitio; empaquetarlo es #1365.
- `mefisto-neutrality-gate.sh` excluye el arbol publicado `scripts/` (`scope_excluded` en `neutrality-allowlist.json`): listarlo como gate de un cambio en `scripts/` es ruido.
- Tests con acoplamiento estatico a `run_agent` de tdd que rompen con la migracion: `test-agent-resume.sh` [2] (exige `agent_resume_prompt` + `claude $RESUME_ARGS`), `test-agent-failure-hold.sh` [10] (exige `classify_agent_failure`; tooling ya tiene excepcion), `test-stream-json-trace.sh` [H], `test-stage-models.sh` [10b] (cuenta 4 argv `--agent "$agent" $MODEL_ARGS`). El draft no listaba `test-stage-models.sh`.
- `test-stage-metrics.sh` [K] sigue verde sin cambios si se conservan `compute_stage_metrics`, la ruta `$PIPELINE_DIR_ABS/metrics/tdd-...` y la cosecha por stage.
- `PIPELINE_CAPTURE_STREAM` vive en 8 sitios fuera de `run_agent` (Stage 0, remediacion, `abort()`, history final): no puede eliminarse sin tocar codigo de #1361.
- La sonda de hold en tdd degrada con `SUMMARY_FILE` en `$WORKTREE_PATH/.claude/pipeline/summaries/` (ruta legacy); la canonica via `mefisto_state_path` es #1364.

## Decisiones
- **Opcion A** para `PIPELINE_CAPTURE_STREAM`: se conserva la variable y su bloque jq; solo deja de referenciarse dentro de `run_agent`. #1361 la retira al migrar Stage 0 + remediacion.
- **No partir CA-4/CA-5** (hold+resume+denials) en issue propio: un estado intermedio "runner neutral sin hold" regresa MEF-ADR-0051 y la sonda `-c` legacy no puede reanudar sesiones del runner. Precedente: #1062/PR #1142 hizo el mismo alcance en un PR.
- CA-3 explicita el gate por stage del atajo de recuperacion (1 -> `dotnet build`; 2/3/merge -> `run_tests_projects`) y las variables de metricas a conservar.
- CA-5 usa el criterio de trabajo util que tdd ya tiene (`status --porcelain -- tests/ src/`), no `PIPELINE_OWN_WRITES` (no existe en tdd).
- CA-6 retira `mefisto-neutrality-gate.sh`, agrega `test-stage-models.sh` [10b] a los actualizados y aclara que `generate-published-adapters.sh --check` solo aplica si cambia `_pipeline-common.sh`.
- #1360 pasa a `estado:listo`.

## Descartado
- Opcion B (eliminar `PIPELINE_CAPTURE_STREAM` en todo el archivo ahora): ampliaba el scope a l.525-560 y l.1836-1960, declaradas intocables por el propio issue.

## Preguntas abiertas
- Ninguna para #1360. Los drafts #1361-#1365 siguen `estado:borrador,bloqueado` a la espera de este PR.

## Referencias
Issues creados: ninguno.
Issues refinados: #1360 (`estado:borrador` -> `estado:listo`).

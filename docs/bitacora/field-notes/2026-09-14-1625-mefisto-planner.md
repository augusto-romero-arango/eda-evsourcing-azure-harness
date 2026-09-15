---
fecha: 2026-09-14
hora: 16:25
sesion: mefisto-planner
tema: Refinar #1360 y #1361 (tdd-pipeline.sh al runner neutral); brecha --agent del adaptador Claude; drafts de agentes TDD neutrales; politica bash OpenCode
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

## Descubrimientos (agentes TDD como fuente neutral)
- El contrato `published-artifact.schema.json` ya admite todo lo que los agentes TDD necesitan (`profile`, `capabilities`, `skills`, `mode`; `additionalProperties:false`): la migracion no toca el generador, solo agrega entradas a `CLAUDE_ROOT_MIRRORS`.
- Renderer Claude (`src/published/scripts/lib/adapter-claude.sh`): `profile`->`model` (balanced->sonnet, deep->opus), `capabilities`->`tools`, `skills`->`skills: [...]` validando `skills/<name>/SKILL.md`; solo procesa placeholders `{{mefisto:...}}`, asi que las 35 expresiones `${{ }}` de GitHub Actions en `domain-scaffolder` deben sobrevivir (CA explicito).
- `resolve_declared_agent_model` (`_pipeline-common.sh` l.590) no quita comillas: con el frontmatter generado `model: "sonnet"` devolveria `"sonnet"`. Riesgo concreto para `test-stage-models.sh`; lo corrige #1369.
- Los cuerpos de los 7 agentes referencian `.claude/pipeline/...` (1-8 veces cada uno): se conservan; neutralizarlos es #1364.
- Confirmado ejecutando el resolver: `resolve_declared_agent_model tooling-writer` devuelve `"sonnet"` con comillas (bug latente; ningun pipeline lo consulta hoy para agentes generados). El generador descubre fuentes con `find` (l.166); solo el mirror a la raiz necesita `CLAUDE_ROOT_MIRRORS`. `dist/` esta commiteado (46 archivos).
- **La politica bash de OpenCode niega el toolchain TDD**: `capability_map.shell` es `catch_all: deny` con allow solo para git/gh/jq/cat/ls/find/grep/sort/scripts/mkdir/mktemp. Inventario de la doctrina: `dotnet` en los 7 agentes (2-35 ocurrencias), `func` 11 y `terraform` 6 en domain-scaffolder, `rm` 9 y `curl` 1 en domain-scaffolder (deny explicito hoy), `az` 1 en implementer/reviewer/smoke-test-writer. Bajo Claude no afecta (`tools: Bash` sin patrones).

## Decisiones (agentes TDD)
- Recomendacion aceptada: issues propios, no dentro de #1365, y como dependencia de #1365 (publicar `tdd-pipeline.sh` sin sus agentes dejaria un flujo que falla en Stage 1 bajo OpenCode).
- Cuatro drafts (`estado:borrador`) agrupados por stage/eje homogeneo: #1369 test-writer + implementer (fija el patron, corrige el resolver, crea `test-tdd-agents.sh`); #1370 reviewer (perfil deep, skills `projections` + `comment-cleanup`); #1371 smoke-test-writer + projection-test-writer + projection-implementer (skill `projections`); #1372 domain-scaffolder (265 KB, conteo de `${{`). #1370-#1372 dependen de #1369 (`bloqueado`). #1365 pasa a depender de los cuatro.
- CA comun: cuerpo generado identico al actual salvo la linea del guard `{{mefisto:assert-consumer-repo}}`; `model`/`tools`/`skills` equivalentes; tests acoplados al contenido de cada agente verdes sin cambios.
- #1369 refinado a `estado:listo` (unico draft sin dependencias: entra ya a la cola lanzable). Notas verificadas: bug del resolver real, `find` del generador, `_pipeline-common.sh` en la clausura (regenerar `dist/*/scripts/_pipeline-common.sh`).
- **Nuevo draft #1373 "Extender la politica bash de OpenCode para el toolchain de los agentes TDD"**, dependencia de #1365 (no de #1369). Deja abiertas dos opciones: A) extender `capability_map.shell.rules` global con `dotnet *`/`func *`/`terraform *`; B) nueva capacidad (`toolchain`) en el schema, declarada solo por agentes TDD. `rm *`/`curl *`/`az *` siguen deny salvo decision explicita.

## Preguntas abiertas
- Orden sugerido del batch: #1369 y #1368 (sin dependencias) -> #1360 -> #1361 -> {#1370, #1371, #1372} -> #1373 -> #1365 (lo confirma `/mefisto-next-order`; hoy la cola lanzable es #1262, #1368, #1369, #1360, #1361).
- #1373: decidir opcion A (reglas globales) vs B (capacidad nueva) y si la doctrina de domain-scaffolder debe dejar de pedir `rm`/`curl` (#1372) o se acota la regla.
- #1362 (modelo por perfil) deberia usar el mismo mapeo sonnet->balanced / opus->deep que fijan los frontmatters neutrales de #1369-#1372.

## Referencias
Issues creados: #1368, #1369 (listos); #1370, #1371, #1372, #1373 (borradores).
Issues refinados: #1360, #1361, #1369 (`estado:borrador` -> `estado:listo`).

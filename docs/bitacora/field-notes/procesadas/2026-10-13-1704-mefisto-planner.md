---
fecha: 2026-10-13
hora: 17:04
sesion: mefisto-planner
tema: Refinar #2408, #2412, #2411 y #2410 (cero warnings nuevos: reviewer, /fix-review, scaffolders e IaC)
---

## Contexto
Refinamiento de cuatro borradores de la cadena de MEF-ADR-0056 (#2404-#2418).

## Descubrimientos
- El prompt del Stage 3 del TDD solo trae titulo y body del issue (`ISSUE_CONTEXT`), no labels: el reviewer debe consultarlos con `gh issue view`.
- Los resumenes de los escritores viven en `.mefisto/pipeline/summaries/stage-{1,2}-*.md` del worktree.
- Los agentes y comandos publicados corren con cwd = consumidor: los scripts del plugin se invocan por `{{mefisto:package-root}}/scripts/`. Los borradores #2407 y #2409 aun citan `scripts/warnings-diff.sh` relativo: corregir al refinarlos.
- `scaffold-pipeline.sh` solo invoca `domain-scaffolder`; los demas scaffolders se invocan desde comandos interactivos, y `/install-apim`, `/install-workos` e `/install-auth` abren su propio PR.
- `infra-bootstrap` orquesta y no genera codigo.
- El helper exige `--path` relativo, pero `iac-pipeline.sh` solo pasa al prompt la ruta absoluta del ambiente (`INFRA_ENV_DIR_ABS`).
- `test-iac-pipeline-state-paths.sh` ya corre el pipeline IaC e2e con stubs de `gh`/`terraform`/runner: molde para verificar el body del PR.
- La version del harness para un agente sale de `{{mefisto:package-root}}/mefisto-manifest.json`.

## Decisiones
- #2408: `render_warning_remnants_section <worktree>` imprime la seccion (patron `${..._SECTION}`), acepta `#N`, `N` y `owner/repo#N`; fallo de `gh` no bloquea; #2407 pasa a `Relacionado`. Listo.
- #2412: el diferencial cubre Fase 3 y Fase 5.4 (decision del usuario), base = HEAD antes de editar; toolchain por tipo de archivo; enlace por `gh pr comment`; labels del `Closes #N` del PR. Listo.
- #2411: 6 scaffolders (sin `infra-bootstrap`); base = HEAD antes de escribir; remanente cross-repo con version del manifiesto; los PRs de `/install-apim`, `/install-workos` e `/install-auth` enlazan los remanentes (decision del usuario). Listo.
- #2410: prompts de ambos stages con `Commit base` y dir relativo del ambiente; titulo del remanente con el `summary` del diagnostico (Terraform no emite codigo); linea REVISION ESTATICA con conteo; test e2e con stubs. Listo.

## Descartado
- Pasar los labels del issue en el prompt del Stage 3 (#2408).
- Enlazar remanentes de /fix-review dentro de las respuestas a review comments.
- Partir #2411 en agentes vs comandos.

## Preguntas abiertas
Ninguna.

## Referencias
Issues refinados: #2408, #2412, #2411, #2410

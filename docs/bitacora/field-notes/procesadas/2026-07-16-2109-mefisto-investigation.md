---
fecha: 2026-07-16
hora: 21:09
sesion: mefisto-investigation
tema: Por que un issue tipo:refactor abortaba el pipeline TDD (#294) y la familia de bugs harness-consumidor que salio al validar (#295/#299/#302/#305/#308)
---

## Contexto

Arranco con una pregunta del mantenedor: "¿no se supone que Mefisto, al implementar un issue con label refactor, no genera error porque el test-writer no genera ningun test fallando?". El sintoma concreto: el batch del consumidor `Cosmos-SincoERP/Cosmos.ControlPlane` aborto el issue #65 del consumidor ("Reclasificar TenantCreated como evento ES, quitar `IPublicEvent`", label `tipo:refactor`) en el Stage 1 con:

```
Stage 1 fallido: todos los tests pasan (exit code: 0) — el test-writer pudo haber escrito implementacion real en lugar de stubs
```

La sesion empezo como diagnostico de ese fallo y termino destapando una familia entera de bugs del harness, todos visibles solo al dogfoodearlo contra un consumidor real.

## Descubrimientos

- **El label `tipo:refactor` NO activa el carril de refactor.** Solo enruta al pipeline TDD (`scripts/_pipeline-common.sh:606`, junto a `tipo:feature`). Dentro de `tdd-pipeline.sh` el label nunca se lee. Lo que activa `IS_REFACTOR=true` es exclusivamente el archivo senal `pipeline-state/refactor-signal.md` que escribe el **test-writer** cuando el mismo clasifica la tarea como refactor puro (ADR-0017). Al test-writer ni siquiera le llega el label: el contexto que recibe es solo titulo + cuerpo del issue (`tdd-pipeline.sh:296-298`).

- **El test-writer violo su propio contrato en #65.** Su definicion es tajante (`agents/test-writer.md:8,34,830`: "nunca escribes implementacion real", "los tests DEBEN fallar"). Pero hizo el refactor completo el mismo (borro `Contracts/Public/TenantCreated.cs`, lo recreo en el dominio, quito `IPublicEventSender` del handler, borro `TenantCreatedPortabilidadTests`), dejando la suite verde -> el Gate 1b anti-trampa (`tdd-pipeline.sh:663-665`) aborto. En su resumen documento que descarto la senal "porque el issue exige trabajo de test-writer real (borrar/ajustar tests)" y que sabia que quedaria verde. Lectura estrecha del carril: borrar tests obsoletos NO descalifica el refactor puro; en ese carril los edits los hace el reviewer en Stage 3.

- **Un refactor a nivel de firma de tipo no tiene estado rojo que compile.** Quitar una interfaz marker o un parametro de constructor obliga a que produccion y tests cambien juntos para siquiera compilar. Por eso el carril TDD normal es imposible para esta clase de refactor y el de senal es el unico valido — matiz que la guia del test-writer no contemplaba.

- **Habia un SEGUNDO gate rigido, no solo el rojo.** Aun emitiendo la senal, el gate "no deben perderse tests" de Stage 3 (`tdd-pipeline.sh:906-911`) habria abortado, porque el refactor borra legitimamente `XPortabilidadTests.cs` (sin marker de bus no hay canal que testear) y el conteo baja. Toda la tanda de "reclasificar eventos" reduce el conteo, asi que el patron se repetia.

- **Familia de bugs por deriva harness-consumidor (los 5 que siguieron a #294):** todos son scripts publicados que corren desde el cache del plugin pero asumen el layout del harness o la presencia de archivos del consumidor, o asimetrias entre los tres gates de tests que fueron divergiendo:
  - **#295/#297**: `batch-pipeline.sh:275` invocaba `pr-sync.sh` con ruta relativa (rota tras `cd "$REPO_ROOT"` al consumidor); `tooling-pipeline.sh` hacia `sed` sobre `.claude/settings.json` sin guard `[ -f ]` que `tdd-pipeline.sh` si tenia.
  - **#299**: `pr-sync.sh` mergeaba con `--merge` hardcodeado -> fallaba en repos squash-only (el consumidor tiene ruleset linear-history + `allow_merge_commit=false`), y el retry ocultaba la causa real repitiendo "estado: CLEAN".
  - **#302**: el gate de tests de `tooling-pipeline.sh` corria toda la solucion (`--solution`), incluidos los `*.SmokeTests` (black-box contra dev, sin credenciales -> 401/404). `tdd-pipeline.sh` ya los excluia via `run_tests_projects`; tooling no.
  - **#305**: mismo bug en `pr-sync.sh` (el tercer gate, el ultimo sin el fix). Al arreglarlo descubrimos que `run_tests_projects` y `extract_test_count` estaban **duplicadas byte a byte** en `tdd` y `tooling` -> se consolidaron en `_pipeline-common.sh` para que los tres compartan la misma exclusion.
  - **#308**: `local` fuera de funcion (bash: `local: can only be used in a function`) en `tooling-pipeline.sh:493` y — hallado por barrido con `shellcheck` SC2168 — tambien en `tdd-pipeline.sh:334`. Con `set -e` mataba el pipeline antes del `abort()` limpio, dejando el status en `running` y worktree/tmux huerfanos.

## Decisiones

- **Fix de #294 fiel a ADR-0017 (Opcion A, no B):** el test-writer NUNCA toca produccion; senaliza y se detiene; el reviewer ejecuta el refactor. Se amplia el criterio de refactor puro (borrar/ajustar tests existentes ya no descalifica), se hace mandatorio el carril de senal para refactors a nivel de firma, y se agrega el campo `REMOVED_TESTS=<n>` a la senal. El gate "no deben perderse tests" pasa a `allowed_min = BASELINE_TEST_COUNT - REMOVED_TESTS`, tolerando la caida declarada y preservando el backstop contra caidas no declaradas. Se descarto la Opcion B (dejar que el test-writer haga el cambio y solo senalice): contradecia las lineas 8/34/830 y debilitaba el Gate 1b anti-trampa.
- **No enrutar por label** (se mantuvo explicito fuera de scope): `tipo:refactor` solo elige pipeline; la clasificacion refactor-vs-TDD sigue siendo juicio por-issue del agente (ADR-0017). Un `tipo:refactor` puede necesitar tests nuevos.
- **Consolidacion en `_pipeline-common.sh` (#305)** en vez de anadir una tercera copia de `run_tests_projects`: una sola fuente para los tres gates, parametrizando la ruta del worktree.
- **#308 usa `shellcheck` (SC2168) como guard autoritativo**, no un grep hand-rolled: se documento el pitfall de que `awk` BSD/macOS no soporta `\b`, dando falsos "OK". Nuevo `scripts/tests/test-no-toplevel-local.sh` como guard estatico permanente.
- **CA-3 de #308 (limpiar worktree/tmux huerfanos) sacada de scope:** `abort()` deja el worktree a proposito (post-mortem) y el ciclo de tmux lo maneja `tmux-pipeline.sh`. Endurecerlo seria otro issue.
- **Cadencia de release por bug, no acumulada:** cada fix se libero apenas se cerro (v0.14.0 -> v0.14.4) porque cada uno desbloqueaba el siguiente paso de la validacion del consumidor (p. ej. sin #299 el merge del batch seguia roto en squash-only; sin #302/#305 el gate abortaba por smoke tests ajenos).

## Descartado

- **Opcion B para #294** (test-writer hace el refactor + senaliza): ver arriba; rompe el contrato del agente y el anti-trampa.
- **Cerrar #295 con solo #297:** se reabrio deliberadamente porque #299 destapo el tercer bug (metodo de merge) — el objetivo "el merge del batch funciona end-to-end" no estaba cumplido hasta que los tres estuvieran liberados. Se cerro tras v0.14.2/0.14.3.
- **Documentar el `local` top-level como "no hacer"** en vez de arreglarlo: descartado; se elimino en ambas ocurrencias (asignaciones globales inocuas) + guard estatico.

## Preguntas abiertas

- **Validacion end-to-end en el consumidor pendiente (CA-6 de varios issues):** actualizar Cosmos.ControlPlane a v0.14.4 y reprocesar la tanda (#65/63/64/74 del consumidor, PR #84) para confirmar que ni el carril de refactor ni los gates abortan por causas falsas. Es la prueba real de que la familia quedo cerrada.
- **¿Hay mas asimetrias entre los tres gates?** El barrido de #305 unifico `run_tests_projects`/`extract_test_count`; el de #308 unifico la ausencia de `local` top-level. Vale una auditoria proactiva de otras divergencias tdd/tooling/pr-sync antes de que las encuentre otro consumidor.

## Referencias

- Issues cerrados esta sesion (repo Mefisto): #294, #295, #305, #308 (implementados por pipeline/PR); #299, #302 (fixes directos del mantenedor).
- Releases: v0.14.0 (#294 + #295), v0.14.1 (#299), v0.14.2 (#302), v0.14.3 (#305), v0.14.4 (#308).
- ADR-0017 (enmendado en #294: alcance ampliado + campo `REMOVED_TESTS` + nueva seccion Control de cambios). ADR-0019 (separacion publicado/interno: todos los fixes son lado publicado; mirror interno verificado libre de estas clases de bug).
- Origen cross-repo: `Cosmos-SincoERP/Cosmos.ControlPlane` (issue #65 del consumidor y el batch `batch-221650`).

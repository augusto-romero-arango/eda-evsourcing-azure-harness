---
fecha: 2026-09-20
hora: 18:47
sesion: mefisto-planner
tema: Refinar los drafts #1550 y #1551 del consumidor de certificacion (coverage-gate, historial TDD, falso fallo de merge en pr-sync)
---

## Contexto
Dos drafts creados desde el consumidor `mefisto-consumer-certification` durante la
certificacion TDD multi-runtime (#1464). #1550: el Stage 4 de `tdd-pipeline.sh` salta el
coverage-gate con "instrumentacion fallo" y, tras crear el PR, el pipeline muere con
`jq: invalid JSON text passed to --argjson` sin dejar historial. #1551: `pr-sync.sh --merge`
reporta "No se pudo mergear despues de reintentos" con el PR ya en main.

## Descubrimientos
- `measure_coverage` recolecta con `dotnet test --solution`, unico punto del pipeline que
  ejecuta `*.SmokeTests/`; los gates 1-3 usan `run_tests_projects` (glob `*.Tests/`).
- El SKIP del coverage-gate colapsa "sin XML" y "tests fallaron bajo cobertura"; el subshell
  `( measure_coverage ) &` pierde el exit code real.
- La hipotesis del draft sobre `COV_GAPS_REMAINING`/`COV_PATCH_APPLIED` vacias es falsa:
  estan inicializadas en l.117-118.
- Causa real del `--argjson`: `extract_test_count` no reconoce el resumen de
  Microsoft.Testing.Platform (`succeeded: N`) -> `PIPELINE_TESTS="?"` -> `--argjson tests "?"`
  aborta bajo `set -e`. Regresion de #1389. Afecta a `tdd` y `tooling` en toda corrida MTP,
  independientemente del coverage-gate. `update_status` tambien escribe `"tests": ?`.
- En `merge_pr_with_retry` el primer intento SI ejecuta `gh pr merge` con estado CLEAN; el
  falso fallo nace de que `gh pr merge --delete-branch` devuelve != 0 tras mergear (paso
  post-merge, probablemente el borrado de rama: carrera que explica por que otros PRs del
  mismo dia pasaron) y de que el bucle nunca consulta `state == MERGED`: un PR mergeado
  reporta `mergeStateStatus: UNKNOWN` y agota los reintentos. El mensaje "aun no reporta
  mergeable (estado: CLEAN)" describe el estado previo, no el fallo de gh, cuya salida solo
  va al log.
- `batch-pipeline.sh:392-399` toma el exit != 0 de pr-sync como eslabon fallido: el falso
  negativo tambien golpea a `/sequential`, no solo a `/merge`.

## Decisiones
- #1550 se partio en dos issues independientes, ambos `bug` + `tipo:tooling` + `estado:listo`:
  #1550 (Stage 4: recolectar solo `*.Tests/` + distinguir causa del SKIP) y
  #1552 (`extract_test_count` MTP + `tests` saneado a entero/null + bookkeeping post-PR
  no aborta la corrida).
- Ante tests fallidos bajo cobertura con XML presente, el gate sigue en SKIP (no evalua un
  reporte parcial) pero con causa explicita en el events log.
- #1551 refinado como un solo issue sobre `merge_pr_with_retry`: consultar `state == MERGED`
  tras un `gh pr merge` fallido y al inicio de cada reintento, mensaje de reintento con la
  salida real de gh, test con stub de `gh`/`sleep` bajo `/bin/bash` (patron de
  `test-pr-sync-desbloqueo.sh`). El borrado tolerante de la rama remota queda opcional.
- Sin cambios de ADR: MEF-ADR-0014, MEF-ADR-0013 y MEF-ADR-0019 se aplican tal cual.

## Descartado
- Tolerar `null` en `gaps`/`patch_applied` del historial: no era la causa.
- Filtrar smoke tests con flags MTP sobre `--solution`: el proyecto sin tests devolveria rc 8
  y romperia la recoleccion; se prefiere el loop por proyecto `*.Tests/`.
- "El sondeo trata CLEAN como no mergeable" (#1551): refutado leyendo el codigo.

## Preguntas abiertas
- Confirmar en el consumidor, tras #1552, si alguna corrida TDD bajo MTP habia logrado
  registrar historial desde #1389 (la hipotesis es que ninguna).
- Confirmar en el log de pr-sync del consumidor la salida exacta de `gh pr merge` en los
  PRs #21/#25 (hipotesis: fallo del borrado de rama post-merge).

## Referencias
Issues creados: #1552
Issues refinados: #1550, #1551 (borrador -> listo)

---
fecha: 2026-09-20
hora: 18:47
sesion: mefisto-planner
tema: Refinar #1550 (coverage-gate ejecuta smoke tests / historial TDD aborta tras el PR)
---

## Contexto
Draft #1550 creado desde el consumidor `mefisto-consumer-certification`: el Stage 4 de
`tdd-pipeline.sh` salta el coverage-gate con "instrumentacion fallo" y, tras crear el PR,
el pipeline muere con `jq: invalid JSON text passed to --argjson` sin dejar entrada en
`pipeline-history.jsonl`. El reporte atribuia ambos sintomas al mismo SKIP.

## Descubrimientos
- `measure_coverage` recolecta con `dotnet test --solution`, unico punto del pipeline que
  ejecuta `*.SmokeTests/`; los gates 1-3 usan `run_tests_projects` (glob `*.Tests/`).
- El SKIP colapsa "sin XML" y "tests fallaron bajo cobertura"; el subshell
  `( measure_coverage ) &` pierde el exit code real.
- La hipotesis del draft sobre `COV_GAPS_REMAINING`/`COV_PATCH_APPLIED` vacias es falsa:
  estan inicializadas en l.117-118.
- Causa real del `--argjson`: `extract_test_count` no reconoce el resumen de
  Microsoft.Testing.Platform (`succeeded: N`) -> `PIPELINE_TESTS="?"` -> `--argjson tests "?"`
  aborta bajo `set -e`. Regresion de #1389. Afecta a `tdd` y `tooling` en toda corrida MTP,
  independientemente del coverage-gate. `update_status` tambien escribe `"tests": ?`.

## Decisiones
- Partir en dos issues independientes, ambos `bug` + `tipo:tooling` + `estado:listo`:
  #1550 (Stage 4: recolectar solo `*.Tests/` + distinguir causa del SKIP) y
  #1552 (`extract_test_count` MTP + `tests` saneado a entero/null + bookkeeping post-PR
  no aborta la corrida).
- Ante tests fallidos bajo cobertura con XML presente, el gate sigue en SKIP (no evalua un
  reporte parcial) pero con causa explicita en el events log.
- Sin cambios de ADR: MEF-ADR-0014 y MEF-ADR-0013 se aplican tal cual.

## Descartado
- Tolerar `null` en `gaps`/`patch_applied` del historial: no era la causa.
- Filtrar smoke tests con flags MTP sobre `--solution`: el proyecto sin tests devolveria rc 8
  y romperia la recoleccion; se prefiere el loop por proyecto `*.Tests/`.

## Preguntas abiertas
- Confirmar en el consumidor, tras #1552, si alguna corrida TDD bajo MTP habia logrado
  registrar historial desde #1389 (la hipotesis es que ninguna).

## Referencias
Issues creados: #1552
Issues refinados: #1550 (borrador -> listo)

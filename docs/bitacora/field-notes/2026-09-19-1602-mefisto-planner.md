---
fecha: 2026-09-19
hora: 16:02
sesion: mefisto-planner
tema: Estado de la neutralizacion TDD (Claude + OpenCode) y reapertura de la certificacion
---

## Contexto
El usuario pregunto si los agentes TDD, scripts y skills estan listos para
desarrollar en el consumidor bajo ambos runtimes (Claude Code y OpenCode).

## Descubrimientos
- Toda la superficie de `/mefisto:implement` ya es fuente neutral en
  `src/published/` (test-writer, implementer, reviewer, projection-test-writer,
  projection-implementer, implement/tooling/runtimes) y se proyecta a
  `agents/`+`commands/` (Claude) y `dist/opencode/` (OpenCode); los pipelines
  resuelven el runtime via `runtime-{claude,opencode}.sh`.
- 13 agentes y 24 comandos publicados siguen escritos a mano solo para Claude
  (planner, bug-investigator, historiador, infra-*, scaffolders, pr-sync,
  tooling-investigator; scaffold*, infra*, parallel, sequential, bug, merge,
  onboard, upgrade, etc.).
- `generate-published-adapters.sh --check` reporta 14 rutas `distinta` en
  `dist/`: esperado, `dist/` solo lo regenera `/mefisto-release` y sigue en
  v0.37.16. Hay 103 commits y ~80 fragmentos de `changelog.d/` sin release.
- #1464 quedo cerrado por el `Closes` automatico del PR #1482 pese a que el
  reviewer exigio reabrirlo; las tablas de #1435/#1436 siguen
  `PENDIENTE DE EJECUCION` y #1411 es `NO PASA`.

## Decisiones
- Reabrir #1464 (comentario con la causa).
- Crear #1487 como borrador bloqueado: issue de veredicto equivalente a #1411
  que audita las cuatro corridas reales y cierra #1464 al resolverse (CA-5).
- Crear #1489 (`estado:listo`): label `cierre:manual` que hace que
  `mefisto-tooling-pipeline.sh` emita `Refs #N` en vez de `Closes #N`, para
  issues cuyo cierre valido no es el PR del pipeline. Solo lado interno
  (MEF-ADR-0019); el lado publicado seria otro issue.

## Descartado
- Rellenar las tablas de certificacion o emitir veredicto sin corridas reales
  (MEF-ADR-0031).

## Preguntas abiertas
- Cuando se corta la release candidata que habilita el preflight CA-1 de #1464.
- Si el lado publicado (`scripts/tooling-pipeline.sh`, `tdd-pipeline.sh`)
  necesita la misma senal `cierre:manual`; hoy no hay caso que lo exija.

## Referencias
Issues creados: #1487, #1489
Issues reabiertos: #1464

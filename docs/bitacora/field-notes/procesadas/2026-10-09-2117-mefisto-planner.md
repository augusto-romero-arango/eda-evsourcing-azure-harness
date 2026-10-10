---
fecha: 2026-10-09
hora: 21:17
sesion: mefisto-planner
tema: paridad de experiencia, mascota, merge y lote de sequential en fausto-blood-pact
---

## Contexto
Continuacion de la sesion de las 20:40 (PR #2197): refinar #2192/#2193 y definir los siguientes incrementos de la consola publicada para la etapa de desarrollo del consumidor.

## Descubrimientos
- El consumidor no hace release: el analisis de capacidades de la consola debe partir de los skills del consumidor (desarrollo: tdd, tooling, infra), no de los del repo de Mefisto.
- En infra el merge dispara el `apply` en CI y ese job cierra el issue (MEF-ADR-0022): sin merge en la consola, el ciclo de infra no se cierra ahi.
- `batch-pipeline.sh` publicado guarda la cola solo en memoria con estados en texto libre; el interno ya escribe `pipeline-status-mefisto-batch.json`.
- La ruta de `events.jsonl` publicada es deterministica: `<prefijo>stage-<stage>-<started>-issue-<n>[-variant]-attempt-<k>`, prefijo `""`/`tooling-`/`iac-`.

## Decisiones
- La paridad entre mods es una referencia de experiencia, no una camisa de fuerza: sin issues espejo; apartarse se declara en el issue (#2192, listo).
- #2193 (mascota) listo, alineado con divine-wager (sin "dormido" en hold).
- Merge en dos issues: desde la corrida terminada (#2198) y PRs abiertos en reposo con tecla `3` (#2199).
- Sequential como lote: el lote ocupa la banda, como la referencia (#2203), con status de lote nuevo en el pipeline (#2202), `status` normalizado + `detail`.

## Descartado
- Agregar la regla de paridad a la doctrina del agente `mefisto-planner`.
- El lote como una fila mas entre corridas.
- Release y bitacora como capacidades de la consola del consumidor.

## Preguntas abiertas
- Patron de rama de los PRs de field notes en el consumidor (para filtrarlos en #2199).
- Incrementos restantes: fix-review, log en vivo, issues del reviewer.

## Referencias
Issues: #2192 (listo), #2193 (listo, bloqueado), #2198, #2199, #2202, #2203 (borradores; #2203 bloqueado por #2202)

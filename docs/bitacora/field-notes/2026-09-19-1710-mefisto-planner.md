---
fecha: 2026-09-19
hora: 17:10
sesion: mefisto-planner
tema: Refinar #1495/#1496 (drift de dist/ tras v0.38.0) -- reestructuracion alrededor del gate de neutralidad
---

## Contexto
Refinar los dos drafts nacidos del incidente de v0.38.0: `dist/` desactualizado (heredado de #1478) detectado solo en publish; tres PRs extra (#1491/#1493/#1494) para recuperar.

## Descubrimientos
- El unico `--check` del ciclo de release vivia en `package-opencode-release.sh:48` (publish). `prepare_metadata()` corre el generador en modo escritura y stagea solo dos manifests: con drift, el resto queda como working tree sucio.
- `mefisto-neutrality-gate.sh` YA tiene la regla estructural `adapters-check` (generador interno del propio `--root`), con remedio en `mefisto_neutrality_remedy`, intento de correccion (#1473) en `run_neutrality_gate` y cableado en los dos stages de tooling y en prepare de release (tras `git switch -c ... origin/main`, con rollback). Solo falta la misma regla para el generador publicado.
- `generate-published-adapters.sh --check` tarda 98-109 s en el repo real (modo escritura 49 s; gate de neutralidad 3 s; validador 0,6 s; render 0,08/0,43 s por fuente). Causa: tres bucles cuadraticos que lanzan un `jq` por plan de asset acumulado (174 assets -> ~15-20k procesos).
- Ningun test ejercita "gate en rojo en prepare -> rama deshecha": `[wiring]` es estatico y los tests de release stubean el gate con `exit 0`.
- `is_path_changelog_exempt` no exime tests: un PR de solo tests requiere fragmento.

## Decisiones
- Nuevo #1499 (bug, listo): eliminar los bucles cuadraticos con jq; objetivo `--check` <= 15 s con salida byte-identica.
- #1496 reescrito: anadir `published-adapters-check` al gate de neutralidad (espejo de `adapters-check`), remedio, tests, doc (cabecera del gate, MEF-ADR-0050 seccion 5, `mefisto-release.md`); sin tocar pipelines. Bloqueado por #1499.
- #1495 reconvertido: test `test-release-neutrality-rollback.sh` del rollback de prepare con el gate en rojo (usa `adapters-check`, independiente de #1496/#1499).
- Orden de batch sugerido: #1495 y #1499 en cualquier orden; #1496 despues de #1499.

## Descartado
- Gate propio de `dist/` en prepare de release (primera version de #1495): el gate de neutralidad ya ocupa esa posicion.
- Gate propio en el pipeline de tooling con intento de correccion (primera version de #1496): duplicaba la mecanica de #1473 y pagaba ~2 min por stage.
- Correr el `--check` antes de ramificar sobre el arbol local: no juzga lo que entra a la release.
- Incluir `generate-internal-adapters.sh --check` en un gate nuevo: ya lo hace `adapters-check`.

## Preguntas abiertas
- Si tras #1499 el `--check` publicado queda cerca de 15 s, el gate total (~18 s) roza el umbral del test `[perf]` (20 s); la siguiente palanca es `adapter-opencode.sh render` (0,43 s por fuente, 32 `jq`).

## Referencias
Issues creados: #1499. Issues refinados: #1495 (borrador -> listo, reconvertido), #1496 (borrador -> listo, bloqueado por #1499).

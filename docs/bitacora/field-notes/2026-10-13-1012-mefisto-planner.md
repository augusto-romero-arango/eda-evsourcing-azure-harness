---
fecha: 2026-10-13
hora: 10:12
sesion: mefisto-planner
tema: Conteo de PRs de field notes en las bandas, smoke sin topes de pagina y nightly roja por test-tdd-agents
---

## Contexto
Esta sesión continúa la anterior (nota previa en el PR #2364). Hubo tres pedidos:
- La banda de Bitakora mostraba `PRs 1` con 6 PRs abiertos.
- Refinar el borrador #2366, que nació en el consumidor (Bitakora #955).
- Diagnosticar la nightly roja.

## Descubrimientos
- Las dos bandas dejan fuera de `2: PRs N` los PRs de field notes, que ya cuentan en `bitácora N`. Pero "Todos" pasa `--all`, y tanto `pr-sync.sh --all` como `/mefisto-merge --all` mergean todos los PRs abiertos, field notes incluidos. El número mostrado no coincidía con lo que se mergeaba.
- Ningún agente pide smoke de tope, pero ninguna regla los excluye. MEF-ADR-0048 §2 los invita con "verificaciones adicionales bienvenidas".
- La nightly está roja desde el 2026-10-08 por una sola aserción. `test-tdd-agents.sh` exige exactamente 2 menciones de `blockage-report.md` en el implementer, y el PR #2064 agregó una tercera legítima.
- El writer de `mefisto-tooling` busca tests en `scripts/tests/` y `.claude/scripts/tests/`. Ahí la suite publicada es solo un shim; la real vive en `src/published/scripts/tests/`, que el `grep -l` no recorre.
- En zsh, `"$c:src/..."` aplica el modificador `:s`; hay que escribir `"${c}:src/..."` con `git cat-file`.

## Decisiones
- #2368 y #2369: `PRs N` cuenta el total simple, field notes incluidos. Va en los dos lados por paridad (MEF-ADR-0055 decisión 11), y `bitácora N` no cambia.
- #2366: los smoke no cubren tamaño de página ni topes de cantidad, aunque afirmen un mensaje; eso va a unit/endpoint.
  - Siguen en smoke: la llamada real, el cursor, la validación de forma y el error path `.resx`, incluido el "largo máximo" del scaffold MCP.
  - El reviewer lo marca como sugerencia y el planner no los pide en los CAs.
- #2376: la aserción pasa a ser robusta: 0 menciones para los agentes sin bloqueo y al menos 1 para el implementer y el reviewer.
- #2377: el writer y el reviewer de tooling buscan también en `src/published/scripts/tests/`.

## Descartado
- `PRs 6 (5 docs)` y un botón `docs N` aparte.
- Smoke de topes con mensaje; el usuario los excluyó también.
- Reviewer bloqueante o con hallazgo mayor para los smoke de tope.
- Subir el conteo del test a 3.

## Preguntas abiertas
- Lanzar `/mefisto-sequential 2366 2368 2369 2376 2377`, publicar el release y hacer `/mefisto:upgrade` en Bitakora.
- #1908 se cierra solo cuando la nightly vuelva a verde.

## Referencias
Issues en estado:listo: #2366, #2368, #2369, #2376, #2377.

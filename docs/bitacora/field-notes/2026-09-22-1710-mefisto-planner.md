---
fecha: 2026-09-22
hora: 17:10
sesion: mefisto-planner
tema: Cierre de la certificacion TDD multi-runtime (/mefisto:implement) sobre v0.38.2
---

## Contexto
Las cuatro corridas reales de certificacion TDD (write/read x Claude/OpenCode) ya se habian ejecutado en `mefisto-consumer-certification` el 2026-09-21 sobre v0.38.2. Faltaba trasladar la evidencia a Mefisto y dejar listo el veredicto.

## Descubrimientos
- El expediente sanitizado vive en el consumidor, ignorado por Git: `.mefisto/pipeline/certification/tdd-v0.38.2/` (coordination, celdas, sentinels, final-handoff; intento 1 en `intento-1/`).
- El intento 1 fallo por un defecto del protocolo: los templates de fixture omiten `## ADRs aplicables`, que `agents/implementer.md` 1b exige (OpenCode bloqueo conforme a doctrina; Claude se aparto de ella).
- El consumidor no tiene CI sobre `pull_request` para codigo (solo `infra-cd.yml` filtrado a `infra/**`): checks `NO_APLICAN`.
- `mefisto-tooling-pipeline.sh` solo emite `Closes #<issue>` del propio issue; no cierra issues relacionados.

## Decisiones
- La evidencia se registro por PR manual (#1559, `Refs #1464`, mergeado) en vez de por pipeline, porque exige acceso al consumidor privado.
- La desviacion de fixture (intento 2 con `## ADRs aplicables`) se juzga como desviacion justificada (opcion a del usuario); el defecto es del template (#1560).
- #1487 refinado a `estado:listo`; #1464 se cierra a mano tras el merge del veredicto.

## Descartado
- Lectura estricta (NO PASA hasta repetir la matriz con templates corregidos).
- Intento 1 (#28-#31) como evidencia de paridad.

## Preguntas abiertas
- Veredicto final: pendiente de `/mefisto-tooling 1487`.
- Refinar los drafts #1560-#1563.

## Referencias
PR: #1559 (mergeado). Issue refinado: #1487. Drafts creados: #1560 (templates ADRs aplicables), #1561 (blockage-report continua al reviewer), #1562 (Stage 2b skip silencioso por ruta tests/), #1563 (herdr-pipeline sin verificar arranque en pane reutilizado).

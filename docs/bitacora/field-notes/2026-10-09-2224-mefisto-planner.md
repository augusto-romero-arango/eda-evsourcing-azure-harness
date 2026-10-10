---
fecha: 2026-10-09
hora: 22:24
sesion: mefisto-planner
tema: refinar mejoras de los tableros y titulo en el resumen del sequential
---

## Contexto
Continuacion de la sesion de las 22:03 (PR #2219): refinar #2214, #2215, #2217 y #2218, y una mejora al resumen del lote de la consola interna.

## Descubrimientos
- Al crear un borrador, los tableros solo programan el refresco de `SETTLE_MS`: la lista apareceria sin el recien creado justo cuando se quiere refinar.
- `isIssueChange` reconoce `gh issue close` pero no extrae el numero; hace falta un detector `issueClosed` para la quita optimista.
- `fausto-board` resuelve ambos focos en un solo `if (focus)` y pide confirmacion de cierre (`si, cerrar`); el mod publicado no tiene README propio.
- El resumen del sequential de `mefisto-divine-wager` sale de `pipeline-history.jsonl`, que ya trae el `title` de cada issue.
- GitHub tardo en reflejar el label de #2215 en `next-order`: el mismo retraso que corrige #2214.

## Decisiones
- #2214, #2215, #2217 y #2218 refinados y en `estado:listo` (refresco inmediato al crear un borrador incluido en ambos tableros).
- Titulo del issue entre el numero y el PR en el resumen del lote, recortado y alineado (#2220).

## Descartado
- Nada nuevo.

## Preguntas abiertas
- Abrir el par de #2220 para el resumen del lote de `fausto-blood-pact`.

## Referencias
Issues: #2214, #2215, #2217, #2218 (listos); #2220 (borrador)

---
fecha: 2026-09-22
hora: 18:23
sesion: mefisto-planner
tema: Refinar #1562 (Stage 2b saltado en silencio por match en tests/)
---

## Descubrimientos
- `SNAPSHOT_COMMIT` se toma antes de Stage 1: el diff de deteccion de Stage 2b incluye los tests del test-writer, y `Function/` no estaba anclado a `src/`.

## Decisiones
- Opcion A: filtrar a `^src/`; derivacion fallida = warn + `SMOKE_ANOMALY` en events.log + nota en PR, manteniendo `AGENT_ST_RES="skipped"`.

## Descartado
- Abort fail-closed (B) y resultado nuevo `anomaly` (C).

## Referencias
Issues refinados: #1562.

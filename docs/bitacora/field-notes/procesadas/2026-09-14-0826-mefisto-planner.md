---
fecha: 2026-09-14
hora: 08:26
sesion: mefisto-planner
tema: Verificacion E2E del costo estimado de OpenCode
---

## Contexto
Se reporto que las metricas de costo de OpenCode no se capturaban
correctamente. La evidencia inicial fue la tabla del PR #1351: writer Terra y
reviewer Sol tenian tokens de entrada/salida, pero cache, reasoning y costo
estimado aparecian como `-`.

## Descubrimientos
- El PR #1350, que implemento `estimated_cost_usd` para OpenCode mediante el
  issue #1324, se fusiono a las `01:02:50Z` del 2026-09-14 (`af9a366`).
- El writer de #1351 termino a las `00:56:44Z` y el reviewer ya estaba en curso
  antes del merge de #1350. Aunque #1351 se creo a las `01:03:37Z`, sus dos
  procesos usaron el adaptador previo a #1324.
- El merge posterior de `main` en el worktree no reemplaza el adaptador ya
  cargado por los procesos de los stages. Por ello #1351 no es evidencia
  posterior al rollout del estimador.
- El PR #1354 si se ejecuto despues de #1350, pero uso Claude Code y no
  certifica OpenCode.
- La suite actual `.claude/scripts/tests/test-runtime-opencode.sh` pasa 156 de
  156 checks, incluidos Terra, Sol, cache, reasoning, tiers y los importes de
  referencia de MEF-ADR-0054.
- Falta una corrida real OpenCode iniciada completamente despues de #1324 que
  pruebe el recorrido adaptador -> contrato neutral -> metricas de stage ->
  tabla del PR.

## Decisiones
- No se abrio un bug de implementacion con #1351 como causa, porque su evidencia
  es temporalmente anterior al cambio que pretendia validar.
- Se creo el issue listo #1355 para ejecutar una certificacion E2E interna,
  fail-closed y con una precondicion explicita sobre el SHA del launcher.
- La certificacion exige tokens completos y `estimated_cost_usd > 0` en writer
  y reviewer, una tabla final no parcial por ausencia de costo, y verificacion
  del importe contra el snapshot Models.dev usado.
- La evidencia se registra en `docs/testing/opencode-dogfooding.md`, que aun
  describe como vigentes el `cost_usd: 0` anterior a MEF-ADR-0054 y el bloqueo
  ya resuelto por #879.
- Si la corrida falla, #1355 no corrige scripts: debe registrar `NO PASA`, abrir
  un draft `bug` con evidencia sanitizada y permanecer abierto.

## Descartado
- Tratar #1351 como una regresion posterior a #1324: los timestamps demuestran
  que writer y reviewer arrancaron antes del merge de la implementacion.
- Dar por certificada la funcionalidad solo con los 156 tests del adaptador:
  no cubren una corrida real completa ni la tabla generada en el PR.
- Usar #1354 como control: sus dos stages corrieron bajo Claude Code.

## Preguntas abiertas
- Resultado de la primera corrida E2E OpenCode lanzada desde un `main` que ya
  contenga `af9a366` antes de iniciar el writer.

## Referencias
Issues creados: #1355 — Certificar el costo estimado de OpenCode en el pipeline
interno.

PRs analizados: #1350, #1351 y #1354.

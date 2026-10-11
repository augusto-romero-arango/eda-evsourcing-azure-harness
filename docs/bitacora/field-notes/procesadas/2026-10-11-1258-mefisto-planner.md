---
fecha: 2026-10-11
hora: 12:58
sesion: mefisto-planner
tema: Pane del sequential en otro workspace, orden de refinamiento, cierre de cintas y cinta de merge del consumidor
---

## Contexto
Continuación de la sesión del 2026-10-10 (field note del PR #2278). Hubo varios síntomas en el uso diario: el wager se perdía tras `/clear`, un sequential lanzado desde Claude abrió un pane en el workspace de otro repo, la cinta del release se quedaba fija al terminar y faltaba una cinta de merge del lado del consumidor.

## Descubrimientos
- Un sequential lanzado desde Claude abría el pane en otro workspace por dos razones: el comando no llevaba `MEFISTO_UI=mod` y el wrapper confiaba en el `HERDR_PANE_ID` heredado, que estaba obsoleto porque venía del `claude daemon` o de otra sesión. `should_delegate_to_herdr` no verificaba que el pane fuera el propio.
- El wager interno pierde la banda tras `/clear` porque `executionAtom` solo se fija en `session.start`. El arreglo es el mismo de #2277: reactivar en `classic.SessionStart`.
- La cinta del release se cerraba sola solo vía `$.clock.after` a los 120 s y no tenía botón para cerrarla. Si el temporizador se pierde, queda fija.
- El consumidor ya puede mergear desde el reposo (`3 PRs N`, desde v0.45.0). Lo que faltaba era la cinta en vivo.
- En el consumidor, `pr-sync.sh` mergea en una sola llamada Bash. El avance por PR solo se ve consultando `gh pr view`.

## Decisiones
- Claude, con `MEFISTO_UI` sin definir: corre en modo detached y la cinta de la sesión lo sigue. OpenCode no cambia: usa siempre el pane a la derecha del Mefisto que ejecuta, tanto en Mefisto como en el consumidor. Un `MEFISTO_UI` explícito tiene prioridad. Guard herdr: el wrapper debe descender del `shell_pid` de `HERDR_PANE_ID`; si no, aborta sin tocar panes (#2284 interno, #2285 publicado).
- El orden de refinamiento va del más reciente al más antiguo, y la dependencia manda (#2282).
- Las cintas terminadas se cierran solas a los 15 s. El vencimiento se calcula al dibujar, sin depender del temporizador. Brief para mods internos.
- La cinta de merge del consumidor (#2289) tiene la mascota cosiendo ramas, consulta GitHub cada 5 s y el lote de sequential tiene precedencia sobre ella.

## Descartado
- Volver a crear el menú de merge desde el reposo: ya existía.
- Importar el sprite de merge desde `.claude/mods/`: el lado publicado lleva código propio (MEF-ADR-0019).

## Preguntas abiertas
- Briefs de mods internos pendientes de aplicar: reactivar el wager y el planner-board tras `/clear`, y el cierre a 15 s de la cinta del release.

## Referencias
Issues: #2282 (cerrado), #2284 (cerrado), #2285 (cerrado), #2289 (estado:listo). Release v0.46.1.

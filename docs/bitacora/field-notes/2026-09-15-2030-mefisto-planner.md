---
fecha: 2026-09-15
hora: 20:30
sesion: mefisto-planner
tema: Refinar #1394 (costo de la suite de tests vs watchdog) con verificacion factual de sus aseveraciones
---

## Contexto
El mantenedor pidio refinar el draft #1394 ("Reducir el costo de la suite de tests, que por si sola supera el watchdog de stage") verificando factualmente cada aseveracion sobre el codigo. El draft nacio de la perdida de 5 de 6 eslabones del batch `/mefisto-sequential 1362 1363 1365 1386 1364 1387` (2026-09-15) por `TIMEOUT (exit 124)` del watchdog de 1800 s.

## Descubrimientos
- **Verificado del draft**: watchdog default 1800 s (`mefisto-tooling-pipeline.sh:306`); 5/6 eslabones por TIMEOUT (`mefisto-batch-20260915-095510.log`: 1363w 1861 s, 1365w 1840 s, 1386w 1855 s, 1364r 1861 s, 1387r 1861 s); tabla de esperas Bash (transcripts: 1387r 1543 s, 1364r 1227 s, 1365w 1125 s, 1386w 698 s); 12 invocaciones `bash "$GENERATOR"` en `test-release-identity-claude.sh` (6 `--out`, 6 `--check`); 86-90 s por invocacion; shim de 4 lineas con `exec`; 4 tests relevantes al diff de #1364 en 13 s.
- **Falso para los agentes: "la suite lo corre dos veces"**. El prompt del pipeline define la suite como `scripts/tests/` + `.claude/scripts/tests/` (124 scripts, no 141/143) y el reviewer de #1364 uso exactamente ese glob. Los 19 tests de `src/published/scripts/tests/` corren una vez, via shim. La duplicacion solo afecta a quien recorra los tres directorios (la medicion del draft).
- **Hotspot real: `validate-published-artifacts.sh` = 74 de los 86 s del generador.** Bucle `while read` por linea (8353 lineas en 11 fuentes) con >=3 `printf | grep` por linea (~50k procesos; `sys` 37 s).
- **El generador ya acepta fuentes posicionales** (`FILES+=("$1")`) y aun asi renderiza los assets del adaptador (`mefisto-manifest.json`, `.mefisto-generated-assets.json`): restringido a una fuente de 24 lineas, `--out` 5.3 s y `--check` 8.8 s, y `--check` sigue detectando `modo divergente` (rc=1).
- **Doctrina desactualizada** en el bloque `ECONOMIA DE TURNOS` (`mefisto-tooling-pipeline.sh:1125,1127,1211,1213`): "las 22 suites completas 25 s" (escrito en #482, 2026-07-31) y "Correrla al cerrar es obligatorio". Los reruns OpenCode que si pasaron (1364, 1387) corrieron ~10 tests relevantes, no la suite completa.
- 18 invocaciones full-cost del generador en la suite doctrinal (~26 min solo de generador). `test-published-artifact-contract.sh` tarda 72 s por el mismo validador.
- El conteo 141 del draft era correcto al medir; #1390 (15/09 15:18) sumo 2 tests -> 143 hoy.
- `STAGE1_PROMPT`/`STAGE2_PROMPT` son cadenas con expansion: se puede interpolar `${MEFISTO_AGENT_TIMEOUT_SECONDS}` en el prompt.

## Decisiones
- Partir el draft en tres issues independientes, un componente cada uno, sin `## Dependencias` entre si:
  - **#1394 (refinado, `estado:listo`)**: restringir las 12 invocaciones del generador en `src/published/scripts/tests/test-release-identity-claude.sh` a una fuente explicita (17 min -> <2 min). Lado publicado.
  - **#1396 (`estado:listo`)**: validar el cuerpo de las fuentes publicadas en una sola pasada en `validate-published-artifacts.sh` (74 s -> <10 s; `--check` del generador <25 s). Lado publicado.
  - **#1397 (`estado:listo`)**: actualizar `ECONOMIA DE TURNOS` en `src/internal/scripts/mefisto-tooling-pipeline.sh`: quitar la cifra "22 suites 25 s", ordenar `test-guards.sh` + tests relevantes al diff, prohibir la suite completa en el stage, interpolar el presupuesto del watchdog. Lado interno.
- Preservar en `## Origen` de #1394 la aclaracion de que "deduplicar" no aplica al pipeline.

## Descartado
- **Eje 1 del draft (deduplicar shim + destino)**: los agentes no lo corren dos veces; los shims de `scripts/tests/` son la compatibilidad de MEF-ADR-0049 hasta completar la migracion. No se crea issue.
- Mantener #1394 como un solo issue con los cuatro ejes: viola "un componente principal por issue" y mezcla lado publicado con interno.
- Incluir en #1394 los otros 6 tests con `--check` completo sin fuentes: verifican "esta al dia" sobre el repo real (semantica distinta); los abarata #1396.

## Preguntas abiertas
- Donde corre la suite completa si el stage ya no la corre: Mefisto no tiene `.github/workflows/`; hoy nadie la ejecuta de forma automatica salvo el agente. Tras #1397 queda en manos del mantenedor o de `/mefisto-release`.
- #1395 (4 tests en rojo permanente) sigue en borrador; no se reviso en esta sesion.
- La medicion por test del draft quedo en 49/141; no se midio la suite completa (estimacion: >30 min).

## Referencias
Issues creados: #1396, #1397
Issues refinados: #1394 (borrador -> listo)
Evidencia: `.mefisto/pipeline/logs/mefisto-batch-20260915-095510.log`, transcripts Claude de los worktrees 1364/1365/1386/1387, mediciones sobre `main` a466a72.

---
fecha: 2026-09-15
hora: 20:30
sesion: mefisto-planner
tema: Refinar #1394 (costo de la suite vs watchdog) y #1395 (tests en rojo permanente) con verificacion factual de sus aseveraciones
---

## Contexto
El mantenedor pidio refinar dos drafts nacidos del batch `/mefisto-sequential 1362 1363 1365 1386 1364 1387` (2026-09-15), en el que 5 de 6 eslabones murieron por `TIMEOUT (exit 124)` del watchdog de 1800 s: #1394 (la suite de tests supera el watchdog) y #1395 (cuatro tests en rojo permanente). En ambos casos con la consigna de verificar factualmente cada aseveracion sobre el codigo antes de darlas por ciertas.

## Descubrimientos

### #1394 (costo de la suite)
- **Verificado del draft**: watchdog default 1800 s (`mefisto-tooling-pipeline.sh:306`); 5/6 eslabones por TIMEOUT (`mefisto-batch-20260915-095510.log`: 1363w 1861 s, 1365w 1840 s, 1386w 1855 s, 1364r 1861 s, 1387r 1861 s); tabla de esperas Bash (transcripts: 1387r 1543 s, 1364r 1227 s, 1365w 1125 s, 1386w 698 s); 12 invocaciones `bash "$GENERATOR"` en `test-release-identity-claude.sh` (6 `--out`, 6 `--check`); 86-90 s por invocacion; shim de 4 lineas con `exec`; 4 tests relevantes al diff de #1364 en 13 s.
- **Falso para los agentes: "la suite lo corre dos veces"**. El prompt del pipeline define la suite como `scripts/tests/` + `.claude/scripts/tests/` (124 scripts, no 141/143) y el reviewer de #1364 uso exactamente ese glob. Los 19 tests de `src/published/scripts/tests/` corren una vez, via shim. La duplicacion solo afecta a quien recorra los tres directorios (la medicion del draft).
- **Hotspot real: `validate-published-artifacts.sh` = 74 de los 86 s del generador.** Bucle `while read` por linea (8353 lineas en 11 fuentes) con >=3 `printf | grep` por linea (~50k procesos; `sys` 37 s).
- **El generador ya acepta fuentes posicionales** (`FILES+=("$1")`) y aun asi renderiza los assets del adaptador (`mefisto-manifest.json`, `.mefisto-generated-assets.json`): restringido a una fuente de 24 lineas, `--out` 5.3 s y `--check` 8.8 s, y `--check` sigue detectando `modo divergente` (rc=1).
- **Doctrina desactualizada** en el bloque `ECONOMIA DE TURNOS` (`mefisto-tooling-pipeline.sh:1125,1127,1211,1213`): "las 22 suites completas 25 s" (escrito en #482, 2026-07-31) y "Correrla al cerrar es obligatorio". Los reruns OpenCode que si pasaron (1364, 1387) corrieron ~10 tests relevantes, no la suite completa.
- 18 invocaciones full-cost del generador en la suite doctrinal (~26 min solo de generador). `test-published-artifact-contract.sh` tarda 72 s por el mismo validador.
- El conteo 141 del draft era correcto al medir; #1390 (15/09 15:18) sumo 2 tests -> 143 hoy.
- `STAGE1_PROMPT`/`STAGE2_PROMPT` son cadenas con expansion: se puede interpolar `${MEFISTO_AGENT_TIMEOUT_SECONDS}` en el prompt.

### #1395 (tests en rojo)
- **release-identity**: verificado. Literales `0.37.0`/`cb54ee43` en las lineas 32 **y 58** (el draft solo veia la 31). Identidad vigente `0.37.16`/`e9054d5f`; 17 releases desde #1166. La proteccion que el bootstrap buscaba ya la da fail-closed `adapter-claude.sh:83-84` mas las 8 `assert_failure` del test.
- **stream-watch**: la causa primaria es `LIB_DIR="$REPO_ROOT/src/internal/scripts/lib"` (linea 887); las libs viven en `src/runtime/lib/` desde #1105 (2026-09-08). Con la ruta corregida quedan **dos fallos reales**: O-3 es un **bug del visor** (`mefisto-stream-watch.sh:194` lee `cost_usd`; los adaptadores emiten `estimated_cost_usd` desde #1337, MEF-ADR-0054) y O-5 es una **asercion obsoleta** (espera `costo_usd=0` para OpenCode; MEF-ADR-0054 seccion 1 prohibe propagar el cero de OAuth).
- **watchdog**: la hipotesis del draft (herramienta ausente en el PATH stubbeado, `control-1` como dependencia de entorno) es **falsa**. Causa unica: `RUNNER` y `FAKE_LIB` (lineas 52-54) apuntan a `src/internal/scripts/`; el runner y `runtime-fake.sh` viven en `src/runtime/` desde #1105. Los bloques de control tambien ejecutan `bash "$FAKE_LIB"`. Con las rutas corregidas: **16 pass, 0 fail** (probado en copia aislada con symlinks, sin tocar el checkout). Hoy son 7 fails, no 4: los bloques `945-*` dependen de tiempos.
- `test-tooling-runtime-neutral.sh:113-120` ya exige que las rutas viejas no existan: el test de watchdog era el unico que seguia apuntando ahi.
- Tecnica util para verificar un arreglo sin ensuciar el checkout: raiz falsa en el scratchpad con symlinks a `src/`, `.claude-plugin/` y `.claude/scripts/*`, y el test parcheado con `sed` dentro de `.claude/scripts/tests/` de esa raiz; `REPO_ROOT` (`../../..`) resuelve correctamente.

## Decisiones
- Partir cada draft en tres issues independientes, un componente y una causa cada uno, sin `## Dependencias` entre si:
  - **#1394 (refinado, `estado:listo`)**: restringir las 12 invocaciones del generador en `src/published/scripts/tests/test-release-identity-claude.sh` a una fuente explicita (17 min -> <2 min). Lado publicado.
  - **#1396 (`estado:listo`)**: validar el cuerpo de las fuentes publicadas en una sola pasada en `validate-published-artifacts.sh` (74 s -> <10 s; `--check` del generador <25 s). Lado publicado.
  - **#1397 (`estado:listo`)**: actualizar `ECONOMIA DE TURNOS` en `src/internal/scripts/mefisto-tooling-pipeline.sh`: quitar la cifra "22 suites 25 s", ordenar `test-guards.sh` + tests relevantes al diff, prohibir la suite completa en el stage, interpolar el presupuesto del watchdog. Lado interno.
  - **#1395 (refinado, `estado:listo`, `bug`)**: derivar la identidad esperada de `release-identity.json`/`plugin.json` en las lineas 32 y 58 del test. Lado publicado.
  - **#1399 (`estado:listo`, `bug`)**: `LIB_DIR` -> `src/runtime/lib` en `test-stream-watch.sh`, el visor lee `estimated_cost_usd // cost_usd`, O-5 reescrito segun MEF-ADR-0054, asercion nueva para el evento legacy con solo `cost_usd`. Lado interno (visor + su test).
  - **#1400 (`estado:listo`, `bug`)**: `RUNNER`/`FAKE_LIB` -> `src/runtime/` en `test-watchdog-tty-isolation.sh`. Lado interno.
- Preservar en `## Origen` de #1394 la aclaracion de que "deduplicar" no aplica al pipeline, y en `## Origen` de #1395 el reparto de causas.
- #1394 y #1395 modifican el mismo archivo en lineas distintas; sin relacion de orden declarada.

## Descartado
- **Eje 1 de #1394 (deduplicar shim + destino)**: los agentes no lo corren dos veces; los shims de `scripts/tests/` son la compatibilidad de MEF-ADR-0049 hasta completar la migracion. No se crea issue.
- Mantener #1394 o #1395 como un solo issue con varios ejes: viola "un componente principal por issue" y mezcla lado publicado con interno.
- Incluir en #1394 los otros 6 tests con `--check` completo sin fuentes: verifican "esta al dia" sobre el repo real (semantica distinta); los abarata #1396.
- Hipotesis del draft #1395 sobre el watchdog (PATH stubbeado; `control-1` como dependencia de pty/tmux) y la idea de degradar a SKIP: no hay dependencia de entorno, era una ruta rota.
- Unir #1399 y #1400 en un solo issue "rutas a src/runtime": #1399 tiene ademas el bug del visor y la asercion obsoleta; mezclarlos oscurece la causa.

## Preguntas abiertas
- Donde corre la suite completa si el stage ya no la corre: Mefisto no tiene `.github/workflows/`; hoy nadie la ejecuta de forma automatica salvo el agente. Tras #1397 queda en manos del mantenedor o de `/mefisto-release`.
- Quedan comentarios en `mefisto-stream-watch.sh` (lineas 132, 427, 468, 479) que siguen hablando de `cost_usd`; #1399 pide que dejen de afirmar que ese es el contrato, sin exigir renombrar el parametro.
- La medicion por test del draft #1394 quedo en 49/141; no se midio la suite completa (estimacion: >30 min).

## Referencias
Issues creados: #1396, #1397, #1399, #1400
Issues refinados: #1394, #1395 (borrador -> listo)
Evidencia: `.mefisto/pipeline/logs/mefisto-batch-20260915-095510.log`, transcripts Claude de los worktrees 1364/1365/1386/1387, mediciones y reproducciones sobre `main` a466a72.

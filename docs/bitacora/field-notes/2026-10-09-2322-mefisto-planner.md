---
fecha: 2026-10-09
hora: 23:22
sesion: mefisto-planner
tema: Refinar #2240 y #2237; diagnosticar /upgrade en ControlAsistencia; titulos vacios en el resumen del sequential
---

## Contexto
Refinamiento de #2240 y #2237. Diagnostico de un /mefisto:upgrade en ControlAsistencia que se quedo en 0.44.1 con la 0.45.0 publicada. Diagnostico y arreglo de la columna de titulo vacia en el resumen del sequential de mefisto-divine-wager.

## Descubrimientos
- `/fausto-blood-pact lanzar` no pinta lista: devuelve texto. La unica otra vista de lanzables es la pagina con `0`.
- Los tests de hooks y mods corren con `claude plugin test` (`claude-code/testing`), no bun.
- `install-opencode-release.sh` extrae el tarball completo en `<data_root>/releases/<v>/`: lo que el empaquetado agregue al staging llega a la instalacion.
- `upgrade.sh --status` no consulta la ultima version publicada y su `loadedVersion` sale de `.plugin-root`, ya reescrito por el update: tras un upgrade aparenta estar al dia. El agente `fast` se salto la actualizacion.
- `/reload-plugins` no parece disparar SessionStart: `.plugin-root.previous` y `.mefisto/pipeline/.plugin-root` quedan desactualizados (sin verificar en docs).
- `mefisto-divine-wager`: `withStats` solo releia el historial para issues sin estadisticas; cacheadas sin titulo, la columna quedaba vacia. Historial y `issueStatsFromHistory` estaban bien (prueba en sandbox con el historial real).

## Decisiones
- #2240: la consola importa `typeBadge`/`reasonOf` de `../logic`; CA-3 recortado a la pagina siguiente. Pasa a listo.
- #2237: LICENSE/NOTICE se copian en el staging de `package-opencode-release.sh`; `manifest_valid` no los exige. Pasa a listo, conserva `bloqueado` por #2231.
- Defectos del upgrade capturados como 4 borradores separados (#2247-#2250).
- #2247: `--status` sigue sin red; `loadedVersion` -> `installedVersion` (schemaVersion 2); regla en upgrade.md: el paso 2 corre siempre una vez por invocacion. Pasa a listo.
- Arreglo del mod directo por rama + PR (#2251), sin issue: `statsPending` trata titulo null como faltante.

## Descartado
- Reimplementar `typeBadge` en la consola.
- Incluir LICENSE/NOTICE desde el generador de `dist/opencode/`.

## Preguntas abiertas
- Causa exacta de las estadisticas cacheadas sin titulo en divine-wager (sospecha: hot-reload tras #2229).

## Referencias
Issues refinados: #2240, #2237, #2247
Issues creados: #2247, #2248, #2249, #2250
PR: #2251

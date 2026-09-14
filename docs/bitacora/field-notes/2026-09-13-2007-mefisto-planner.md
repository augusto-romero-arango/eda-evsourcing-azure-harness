---
fecha: 2026-09-13
hora: 20:07
sesion: mefisto-planner
tema: Refinar #1066, veredicto del corte vertical tooling multi-runtime
---

## Contexto
Se pidio refinar #1066 (veredicto del corte vertical `/mefisto:tooling` en
Claude Code y OpenCode) tras el cierre de sus dependencias #1179, #1180 y
#1181. El issue conservaba `estado:borrador` y `bloqueado`, y su body seguia
fijando `v0.37.12` como release candidata.

## Descubrimientos
- Los dos expedientes `PASA` no comparten release: #1180 certifico
  instalacion/identidad/discovery sobre `v0.37.14` (fuente `e8f6043`) y #1181
  certifico las corridas E2E/Herdr/observabilidad/limpieza sobre `v0.37.16`
  (fuente `e9054d5`). MEF-ADR-0053 seccion 6.1 exige "misma version/tag".
- `git diff --stat e8f6043..e9054d5` no toca `skills/`, `hooks/` ni
  `.mcp.json`; si toca `commands/tooling.md`, `agents/tooling-reviewer.md`,
  `scripts/tooling-pipeline.sh`, `runtime-claude.sh` y `adapter-claude.sh`,
  superficies que #1181 volvio a ejercitar bajo ambos runtimes.
- En `origin/main` la seccion #1180 de `docs/testing/opencode-consumer-cutover.md`
  sigue diciendo "Bloqueada antes de instalar (2026-09-10)": el expediente
  `PASA` de #1180 vive solo en el comentario de cierre del issue (PR #1292 solo
  agrego una field note; no existe `changelog.d/1180.*`). El doc se contradice
  con su propia seccion #1181 `PASA`.
- `README.md:27` y `docs/testing/opencode-global-projection.md:60,71` prometen
  para #1066 un "smoke real" de conexion MCP y carga de la tool `skill`; el
  gate de MEF-ADR-0053 seccion 6 solo exige discovery de esas capacidades.
- Verificado desde Mefisto: `v0.37.14` tag `b5facdd` con padre unico
  `e8f6043`; `v0.37.16` tag `51cdd55` con padre unico `e9054d5`; ambos con
  tarball OpenCode + `.sha256` y digest publicado por GitHub.

## Decisiones
- El mantenedor decidio no repetir el discovery de #1180 sobre `v0.37.16`:
  el veredicto se emite sobre la cadena `v0.37.14` -> `v0.37.16` y declara esa
  diferencia como desviacion documentada de MEF-ADR-0053 seccion 6.1, sin
  enmendar el ADR.
- #1066 absorbe la reconciliacion de la seccion #1180 del doc (CA-3) y la
  re-domiciliacion de las referencias que sobre-prometen en README y
  `opencode-global-projection.md` (CA-5).
- CA-4 conserva el regimen fail-closed para cualquier gap distinto de la
  desviacion ya declarada.
- #1066 pasa a `estado:listo`, se retira `bloqueado`; sigue bloqueando #1262.

## Descartado
- Opcion A: issue pequeno para repetir discovery e identidad sobre `v0.37.16`
  (rechazada por el mantenedor: tooling ya funciona en ambos runtimes).
- Opcion C: repetir #1180 y #1181 completos sobre una release nueva.
- Enmendar MEF-ADR-0053 seccion 6.1 para admitir cadenas de releases.

## Preguntas abiertas
- Si un futuro corte publicado vuelve a certificarse en dos releases, conviene
  decidir si la desviacion se vuelve regla del ADR o sigue siendo excepcional.

## Referencias
Issues creados: ninguno.
Issues refinados: #1066 (`estado:borrador`+`bloqueado` -> `estado:listo`).

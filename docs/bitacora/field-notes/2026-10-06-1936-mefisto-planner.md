---
fecha: 2026-10-06
hora: 19:36
sesion: mefisto-planner
tema: Refinar #2024 (restaurar doctrina de enrutamiento de eventos publicados tras la purga a v0.40.2)
---

## Contexto
La purga a v0.40.2 (#2021/#2022) revirtio los PRs #1809-#1812 (issues #1803-#1806), sin relacion con la capa de autonomia OpenCode. #2024 era el borrador para recuperarlos.

## Descubrimientos
- "No aplica limpio" era solo por artefactos generados (`dist/*/.mefisto-generated-assets.json` y copias `agents/`, `dist/*/agents/`). La parte fuente (`git show <sha> -- src/published`) aplica limpio sobre main 6d69f831.
- Solo 26d831e7 (#1804) depende de f4c9c97c (#1803); 0581edc7 (#1805) y e0343b31 (#1806) aplican solos y en cualquier orden.
- Los diffs fuente no arrastran piezas del frente de autonomia; no hubo follow-ups posteriores sobre esta doctrina.

## Decisiones
- Primero se refino #2024 como un solo issue; el usuario decidio partirlo en cuatro: #2028 (implementer), #2031 (domain-scaffolder, depende de #2028, `bloqueado`), #2029 (reviewer), #2030 (planner). Todos `estado:listo` + `tipo:tooling` + `bug`.
- Cada uno: CA de agente, CA de regeneracion (`generate-published-adapters.sh --check`), fragmento `changelog.d/<issue>.fixed.md` (categoria provisional), PR con `Refs #180X` y `Closes #<nuevo>`.
- #2024 cerrado como not planned apuntando a los cuatro.

## Descartado
- Reabrir los issues originales: referencias de linea obsoletas y CA-1 de #1804 obligaria a repetir la decompilacion ya evidenciada.

## Preguntas abiertas
- Categoria del changelog de las restauraciones: el usuario eligio `fixed`.

## Referencias
Issues creados: #2028, #2029, #2030, #2031. Cerrado: #2024. Originales: #1803-#1806. Refinado: #2036 (restaura #1977, umbrales de rendimiento configurables de la nightly; a4a8b89a aplica limpio, sin adaptadores que regenerar). #1746 de vuelta a estado:listo con cierre:manual (purga revirtio PR #1913; 5946e0b3 aplica limpio; fragmento changelog.d/1746.fixed.md).
#2026 partido en #2037 (guardas workflow_run, original #1828; 402e7d78 aplica con -C1) y #2038 (permisos minimos, original #1923; a03946b0 limpio), independientes; excluir dist/opencode/{agent-execution,command-entry}-manifest.json (frente de autonomia). #2026 cerrado not planned.
#2025 partido en #2042 (ADR-0047 dec 2 + 0048, #1848; 8f4a01a9 contiene la enmienda, no solo regen), #2043 (ADR-0047 dec 3/6/7 + 0032, #1927; dep textual de #2042), #2044 (/scaffold-mcp, #1924; dep doctrinal #2042), #2045 (planner, #1925; dep doctrinal #2042), #2046 (plantilla identidad, #1934; dep #2043; a6a61094 con -C1 por capability web de #1905). #1800 depende de #2046 (+bloqueado). Simulado sobre main bd733339 con regeneracion y tests en verde.

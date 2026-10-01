---
fecha: 2026-10-01
hora: 15:48
sesion: mefisto-planner
tema: CI de tests en PR, espera de checks antes de merge, coverage y proteccion de main
---

## Contexto
El usuario quiere un workflow de CI que corra los tests en cada PR de Mefisto, que los caminos de merge esperen al CI, que main quede protegida y medir coverage sin gate. El alcance es solo el repo de Mefisto, no los consumidores.

## Descubrimientos
- No hay `.github/workflows/` y main no tiene proteccion (404). El repo es publico.
- `.github/*` no esta en `is_path_in_mefisto_scope`: hay que registrarlo en un PR previo (MEF-ADR-0019 sec. E).
- pr-sync.sh no aplica en Mefisto. Los caminos de merge internos son /mefisto-merge (que tambien usa /mefisto-bitacora), mefisto-batch-pipeline.sh y mefisto-release.sh.
- Un workflow saltado por `paths:` deja el check requerido en Pending.

## Decisiones
- Espera sincrona (`gh pr checks --watch` y despues merge), no `--auto`.
- En el batch, un CI rojo se trata como merge fallido (respeta --stop-on-error).
- Suite completa en todos los PRs, sin filtro de paths. Se mide la duracion y luego se decide.
- Ruleset: 0 aprobaciones, check `tests`, sin up-to-date estricto, bypass solo del admin, versionado y aplicado a mano (cierre:manual).
- Coverage con kcov, directo, con un CA que verifica la cobertura de subprocesos. Workflow aparte, no requerido, en push a main.

## Descartado
- Issue de pr-sync para consumidores.
- Que el pipeline aplique el ruleset.
- Spike previo de kcov.

## Preguntas abiertas
- Duracion real de la suite en CI (impacta los PRs de field notes y bitacora).
- Si kcov sigue los subprocesos bash.

## Referencias
Issues creados: #1742, #1743, #1744, #1745, #1746

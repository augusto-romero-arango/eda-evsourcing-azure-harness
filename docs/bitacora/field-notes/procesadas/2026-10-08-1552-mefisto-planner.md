---
fecha: 2026-10-08
hora: 15:52
sesion: mefisto-planner
tema: Portar el tablero del planner (mod) al consumidor
---

## Contexto
Explorar como llevar `mefisto-planner-board` (mod interno, MEF-ADR-0055 decision 8) al planner publicado del consumidor.

## Descubrimientos
- `claude plugin validate` acepta `hooks` clasicos y `modules` en el mismo `hooks/hooks.json`.
- El `hooks/hooks.json` publicado se genera con `src/published/scripts/generate-claude-hooks.sh`: `modules` debe salir del generador.
- `hooks/*` ya esta en `is_path_in_consumer_blocklist` y en `is_path_in_mefisto_scope`: si todo el mod vive bajo `hooks/`, no hace falta PR previo de registro de rutas (MEF-ADR-0019 E).
- `scripts/next-order.sh` publicado no tiene `--json` ni `--refinement`.

## Decisiones
- El mod va dentro del plugin `mefisto`, no como plugin aparte.
- Version minima de Claude Code 2.1.287 para el plugin, verificada por `/onboard` (no se prueba si versiones previas ignoran `modules`).
- El tablero publicado no lanza nada (ni implement, tooling, infra, sequential ni parallel); solo foco y listas. El interno ya se ajusto igual.

## Descartado
- Plugin opt-in aparte en el marketplace.
- Comando de lanzamiento por item en `next-order.sh --json` y filtrado de `tipo:infra` del batch (sin objeto al quitar el lanzamiento).

## Preguntas abiertas
- Como declarar el modulo en el `hooks.json` generado antes de que exista `hooks/register.tsx` (#2081).

## Referencias
Issues creados: #2079, #2080, #2081, #2082, #2083 (todos `estado:borrador`).

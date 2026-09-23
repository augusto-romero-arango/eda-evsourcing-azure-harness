---
fecha: 2026-09-20
hora: 08:21
sesion: mefisto-planner
tema: refinar #1511, #1534, #1512 y #1518 (rutas legacy del contrato del consumidor: repoSlug, prompts de tooling-pipeline, prosa y README)
---

## Contexto
Refinar el draft #1511 (`validate_consumer_scope_changes` lee `repoSlug` de `.claude/harness.config.json` relativo al cwd; en un consumidor canonico, MEF-ADR-0053 decision 4, el diagnostico cae al slug default aunque haya fork). Al refinarlo aparecio el mismo patron en prompts (#1534), luego se refino #1512 (partido en dos) y por ultimo #1518 (README).

## Descubrimientos
- El unico caller real del gate es `tooling-pipeline.sh` (730/821), que ya carga `load_harness_config` (linea 48): `HARNESS_CONFIG_PATH` siempre esta exportada cuando el gate corre.
- `dist/{claude,opencode}/scripts/*` estan identicos a la fuente; el inventario con sha256 es `.mefisto-generated-assets.json` (el `mefisto-manifest.json` de Claude solo trae commit/version); `test-tooling-agents.sh` es el test que falla si no se regenera.
- Lectores de `repoSlug` en todo el repo: `_pipeline-common.sh:2164` (#1511) y tres bloques identicos en `planner.md:98`, `tooling-investigator.md:125` y `commands/fix-review.md:301` (#1534). Ningun test los cubria.
- El "indice tematico" que `planner.md:410/826` busca en `CLAUDE.md` vive en el plugin (`$PLUGIN_ROOT/docs/adr/INDICE-TEMATICO.md`, marketplace `source: ./`), y la seccion "Routing cross-repo: solo drafts" que cita `fix-review.md:298` es la seccion C de MEF-ADR-0019, no un `CLAUDE.md`.
- El README no tiene ninguna mencion canonica del config, manda crear el legacy en la instalacion, no dice como ignorar `.mefisto/pipeline/` sin ignorar el config (`onboard-diagnose.sh:302`) y no ofrece migracion del config, aunque los escritores (`upsert_harness_secret`, `_pipeline-common.sh:537-538`) rechazan un consumidor solo-legacy.
- `is_path_in_consumer_blocklist` no bloquea ni `.mefisto/harness.config.json` ni `.claude/harness.config.json`: el problema de los prompts de `tooling-pipeline.sh` es solo textual.

## Decisiones
- #1511, opcion (a): reutilizar `"${HARNESS_CONFIG_PATH:-}"` sin segundo resolver; default silencioso si esta vacia (criterio de #1503, MEF-ADR-0018). Test dedicado con el fixture git de `test-guards.sh [D]`; regenerar `dist/` con el generador.
- #1534: bloque inline identico en los tres artefactos (`CONFIG` canonico -> legacy, patron de `infra-base-scaffolder.md:45-48`) que **no aborta** sin config porque `repoSlug` es opcional; pliega `commands/draft.md:44`; un test extrae y ejecuta los tres bloques y exige que sean identicos.
- #1512 partido por componente: #1512 queda con los prompts de `tooling-pipeline.sh` (tiene `dist/` y gate); #1536 (nuevo) reune la prosa residual (11 lineas, 6 archivos, sin `dist/`) con un test de lista cerrada de greps.
- #1518: ademas de renombrar las 5 menciones, sumar la linea de `.gitignore` y una subseccion "Migrar el config al canonico" paralela a la de directivas (con `git mv`, sin herramienta automatica porque no existe); reutilizar la redaccion de #1508.
- Separar por contrato: config (#1511/#1534/#1512) vs instrucciones (#1536), aunque compartan archivos; el motor secuencial sincroniza main entre eslabones, asi que compartir archivo no impone orden.

## Descartado
- Opcion (b) para #1511 (`resolve_harness_config_path read "$wt"` dentro de la funcion): solo cubre sourcear la lib sin config, que no ocurre en runtime.
- Un unico issue para #1512 con prompts + prosa: 8 archivos de 3 tipos; partir es reversible.
- Dejar en #1518 solo "una frase" sobre el fallback (propuesta del draft): insuficiente, porque los escritores rechazan al consumidor solo-legacy y este necesita el camino de migracion.
- Barrer todo `agents/`/`commands/` en el test de #1536: los bloques `MEFISTO_INSTRUCTIONS_PATH` legitimos contienen `if [ -f "CLAUDE.md" ]` y darian falsos positivos; la lista de archivos es cerrada.

## Preguntas abiertas
- `agents/planner.md:17` lee `.claude/pipeline/.plugin-root` (mirror transitorio, enmienda #1099 de MEF-ADR-0053): fuera de alcance aqui; su retiro exige el inventario de lectores que la enmienda pide.

## Referencias
Issues refinados: #1511, #1534, #1512, #1518 (los cuatro `estado:listo`). Issues creados: #1534, #1536 (`estado:listo`). No quedan drafts pendientes de este eje.

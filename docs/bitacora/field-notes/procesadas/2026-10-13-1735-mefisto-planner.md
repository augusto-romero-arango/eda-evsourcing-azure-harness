---
fecha: 2026-10-13
hora: 17:35
sesion: mefisto-planner
tema: Refinar #2409 y #2407 (cero warnings nuevos en tooling y escritores TDD)
---

## Contexto
Refinamiento de los borradores #2409 y #2407, parte de la serie MEF-ADR-0056 (#2404-#2417).

## Descubrimientos
- `tooling-writer`/`tooling-reviewer` son agentes delgados: la receta vive en `STAGE1_PROMPT`/`STAGE2_PROMPT` y ambos agentes restringen la verificacion a "los comandos permitidos en el mensaje inicial". Doctrina nueva en el agente exige tambien autorizarla en el prompt.
- `## Pendiente/bloqueos` del summary del writer de tooling lo extrae el pipeline como motivo de aborto: no sirve para remanentes de warnings.
- El `smoke-test-writer` corre en el stage `2b` y escribe `stage-2b-smoke-test-writer.md`: un glob `stage-2-*.md` no lo ve.
- El gate de salida del `smoke-test-writer` exigia "sin warnings" absoluto, en conflicto con el diferencial de MEF-ADR-0056.
- La politica OpenCode ya permite `${MEFISTO_PACKAGE_ROOT}/scripts/*`.

## Decisiones
- Nombre comun de seccion para remanentes de escritores: `## Warnings no remediados` (#2407, #2409, leido por #2408).
- Tokens `{{mefisto:package-root}}` y `{{mefisto:state-path ...}}` en los agentes, alineados con #2408.
- #2408 (ya listo) ajustado para leer tambien `stage-2b-*` y buscar esa seccion; comentario de trazabilidad en el issue.
- Test estructural en tooling; el comportamiento de `render_warning_remnants_section` lo cubre #2408.
- Stage `merge` del TDD fuera de alcance de #2407.
- #2409 y #2407 pasan a `estado:listo` (siguen `bloqueado`).

## Descartado
- Test funcional del body del PR de tooling (exigiria correr el pipeline).
- Cubrir el hueco de stage 2b dentro de #2407 (mezclaria escritores y reviewer).

## Preguntas abiertas
Ninguna.

## Referencias
Issues refinados: #2409, #2407. Issue ajustado: #2408.

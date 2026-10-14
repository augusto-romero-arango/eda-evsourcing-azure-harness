---
fecha: 2026-10-13
hora: 17:35
sesion: mefisto-planner
tema: Refinar #2409, #2407 (cero warnings nuevos), #2435 (Take = tope + 1 en MEF-ADR-0047) y crear #2438 (issue de tests ajustados por el reviewer)
---

## Contexto
Refinamiento de los borradores #2409 y #2407, parte de la serie MEF-ADR-0056 (#2404-#2417), y de #2435, defecto de paginacion en MEF-ADR-0047 reportado desde Bitakora.ControlAsistencia. Ademas, el usuario pidio desactivar los issues de revision de tests que crea el pipeline TDD (#2062) por ruido.

## Descubrimientos
- `tooling-writer`/`tooling-reviewer` son agentes delgados: la receta vive en `STAGE1_PROMPT`/`STAGE2_PROMPT` y ambos agentes restringen la verificacion a "los comandos permitidos en el mensaje inicial". Doctrina nueva en el agente exige tambien autorizarla en el prompt.
- `## Pendiente/bloqueos` del summary del writer de tooling lo extrae el pipeline como motivo de aborto: no sirve para remanentes de warnings.
- El `smoke-test-writer` corre en el stage `2b` y escribe `stage-2b-smoke-test-writer.md`: un glob `stage-2-*.md` no lo ve.
- El gate de salida del `smoke-test-writer` exigia "sin warnings" absoluto, en conflicto con el diferencial de MEF-ADR-0056.
- La politica OpenCode ya permite `${MEFISTO_PACKAGE_ROOT}/scripts/*`.
- MEF-ADR-0047 decision 4 (`Take = tope + 1` + cursor reenviado) choca con MEF-ADR-0042 seccion 2 (el backend ya pide `Take + 1` y arma el cursor con el ultimo devuelto): se pierde un elemento por pagina. El defecto vive solo en el texto del ADR y sus copias en `dist/`.
- El issue de #2062 se dispara con cualquier test que el reviewer modifique, renombre o borre en Stage 3, no solo al destrabar rojos: de ahi el ruido.

## Decisiones
- Nombre comun de seccion para remanentes de escritores: `## Warnings no remediados` (#2407, #2409, leido por #2408).
- Tokens `{{mefisto:package-root}}` y `{{mefisto:state-path ...}}` en los agentes, alineados con #2408.
- #2408 (ya listo) ajustado para leer tambien `stage-2b-*` y buscar esa seccion; comentario de trazabilidad en el issue.
- Test estructural en tooling; el comportamiento de `render_warning_remnants_section` lo cubre #2408.
- Stage `merge` del TDD fuera de alcance de #2407.
- #2435 adopta la regla del consumidor (#1057): catalogo/ventana piden `Take = tope` y deducen "hay mas" de `siguienteCursor`; la desambiguacion conserva `tope + 1`.
- #2438: sin issue; los tests ajustados por el reviewer se listan en una seccion del PR (`render_reviewer_touched_tests_section`). Se borra `create_reviewer_tests_review_issue` y su mencion en MEF-ADR-0055.
- #2409 y #2407 pasan a `estado:listo` (siguen `bloqueado`); #2435 pasa a `estado:listo` con `bug`; #2438 creado y pasado a `estado:listo`.

## Descartado
- Test funcional del body del PR de tooling (exigiria correr el pipeline).
- Quitar la senal del todo o limitar el issue al caso de bloqueo resuelto (#2438): el usuario eligio moverla al PR.
- Cubrir el hueco de stage 2b dentro de #2407 (mezclaria escritores y reviewer).

## Preguntas abiertas
Ninguna.

## Referencias
Issues refinados: #2409, #2407, #2435. Issue ajustado: #2408. Issue creado: #2438.

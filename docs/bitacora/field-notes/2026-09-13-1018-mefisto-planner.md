---
fecha: 2026-09-13
hora: 10:18
sesion: mefisto-planner
tema: Refinamiento del alcance documental del tooling publicado
---

## Contexto
Se refino el draft #1315, originado por corridas de certificacion donde el writer respeto una allowlist de prompt que excluia `docs/testing/` aunque el gate real la permitia.

## Descubrimientos
- La causa raiz esta en los prompts de writer y reviewer de `scripts/tooling-pipeline.sh`; `validate_consumer_scope_changes` ya permite todo `docs/` salvo `docs/adr/mef-adr-*`.
- El summary canonico ya existe bajo `.mefisto/pipeline/summaries/`, pero el aborto sin cambios no expone su seccion `## Pendiente/bloqueos`.
- El pipeline raiz es la fuente del asset copiado a ambas distribuciones por `generate-published-adapters.sh`; los archivos de `dist/` y sus inventarios deben regenerarse.
- El cierre reprodujo el defecto ya capturado en #1310: `mefisto-field-note.sh` invoca `gh repo view --repo`, flag no admitido por el CLI instalado; la primera entrega aborto antes de crear worktree.

## Decisiones
- #1315 queda `estado:listo`, `tipo:tooling` y `bug`, con cinco CAs sobre un unico pipeline publicado.
- Se preserva la frontera de MEF-ADR-0019/0030 y se exige paridad Claude/OpenCode conforme a MEF-ADR-0050/0053.
- #1181 declara ahora que depende de #1315 antes de repetir la certificacion.

## Descartado
- No se modifica el gate de scope: ya expresa la frontera correcta.
- El posible stale de panes interactivos tras una actualizacion queda fuera de #1315.

## Preguntas abiertas
- Evaluar por separado si el stale de version en panes existentes amerita un issue propio.
- Dar curso a #1310 para retirar la incompatibilidad de `gh repo view --repo` del entregador de field notes.

## Referencias
Issues creados: ninguno. Issue refinado: #1315. Issues enlazados: #1181, #1310.

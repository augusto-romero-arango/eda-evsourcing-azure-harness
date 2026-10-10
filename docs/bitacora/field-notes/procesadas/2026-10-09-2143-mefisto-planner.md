---
fecha: 2026-10-09
hora: 21:43
sesion: mefisto-planner
tema: refinar merge/lote de fausto-blood-pact y bug del reposo visto en el consumidor
---

## Contexto
Continuacion de la sesion de las 21:17 (PR #2204): refinar #2198, #2199, #2202 y #2203, y revisar una captura del consumidor donde la consola ocultaba los listos.

## Descubrimientos
- `/mefisto:merge` no pide segunda confirmacion; `--all` mergearia PRs ajenos (borradores, field notes): la consola pasa numeros explicitos.
- Ramas documentales del consumidor: `docs/planner-field-notes-<sesion>` (field-note.sh) y `docs/bitacora-hasta-<fecha>` (historiador).
- `batch-pipeline.sh` publicado no registra estado para los issues saltados y no tiene estado "en curso".
- `/batch-stop` escribe la senal en `--show-toplevel`: desde un worktree no detiene el lote (#2206).
- En `Bitakora.ControlAsistencia`, la consola mostraba `0 activas` con fallos viejos de `.claude/pipeline/` (#9999x inventados del 25-ago, #413 infra del 30-ago) y ocultaba los listos reales #896 y #893: la regla de #2183 (resultados sin descartar reemplazan a los listos) es un defecto.
- Tres digitos llegaron como mensaje en vez de activar teclas del tablero del planner; el "1" con foco explorar era "cerrar sesion".

## Decisiones
- #2198, #2199, #2202, #2203 y #2206 refinados y en `estado:listo`.
- Las corridas solo toman la banda con alguna activa; sin activas, listos + resultados al pie; la consola ignora `.claude/pipeline/` para corridas (#2208).
- La consola escribe la senal de parada en la raiz del checkout principal (como `requestStop` interno).

## Descartado
- Ignorar fallos por antiguedad (24 h).
- Comando `lote` en la consola.

## Preguntas abiertas
- "Descartar" vs "ocultar" como texto del boton (#2208).
- Causa de las teclas del tablero que llegan como texto (#2210).

## Referencias
Issues: #2198, #2199, #2202, #2203, #2206 (listos); #2208, #2210 (borradores, bug)

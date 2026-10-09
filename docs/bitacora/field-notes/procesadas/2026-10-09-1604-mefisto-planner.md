---
fecha: 2026-10-09
hora: 16:04
sesion: mefisto-planner
tema: Descarte del gate de preguntas abiertas (#2149, #2150) y refinamiento de #2159, #2161 y #2162
---

## Contexto
Refinar el borrador #2149, que proponia rechazar en tdd/tooling/iac-pipeline los issues con `## Preguntas abiertas`.

## Decisiones
- Se redacto el cuerpo completo (helper en `_pipeline-common.sh`, gate antes del worktree y antes del gate de bloqueados de iac, 6 CAs).
- Al revisarlo, el usuario decidio no implementarlo: #2149 cerrado como not planned.
- Tambien se descarto #2150 (mismo gate en `mefisto-tooling-pipeline`, lado interno).
- #2146: se borraron `Bloquea #2149` y `Bloquea #2150` de `## Dependencias` y la nota tecnica que los mencionaba.

- #2159 refinado y pasado a estado:listo (+bug): /mefisto-merge deja --delete-branch y borra la rama remota explicitamente; la local solo si ningun worktree la usa (eleccion del usuario frente a activar delete_branch_on_merge o tolerar el error de gh).
- #2161 refinado y pasado a estado:listo: se elimina /mefisto-work-status; los pipelines no dejan de escribir nada (la consola mefisto-divine-wager lee los tres archivos de estado) y se enmienda MEF-ADR-0055 decision 5 (observacion sin el mod: pane herdr, tmux, panel de logs de OpenCode).
- #2162 refinado y pasado a estado:listo: se elimina /work-status publicado ahora, sin esperar a fausto-blood-pact; work-status-collect.sh se conserva con su nombre (lo usa tooling-investigator); el CA-4 de la certificacion de infra pasa a verificarse con el colector. Bump recomendado: minor.

## Descubrimientos
- `gh pr merge --delete-branch` borra la local antes que la remota y sale con error si la local esta en un worktree: la remota sobrevive y /mefisto-merge reporta un falso 'Fallo' y salta la reconciliacion.
- `mefisto-batch-pipeline.sh` y `mefisto-release.sh` usan el mismo flag (fuera del alcance de #2159).
- generate-internal-adapters.sh no borra adaptadores huerfanos: --check los reporta y hay que eliminarlos con git rm.
- Las lineas [archivo] de events.log las escribe src/runtime/mefisto-run-agent.sh (compartido con los pipelines publicados); tras #2161 y #2162 sigue leyendolas work-status-collect.sh (tooling-investigator), asi que nadie deja de escribirlas.

## Descartado
- Gate programatico de preguntas abiertas en los pipelines publicados (#2149) e internos (#2150). La doctrina queda en MEF-ADR-0011 (#2146) y en el planner (#2147/#2148).

## Preguntas abiertas
- Ninguna.

## Referencias
Issues cerrados: #2149, #2150. Refinados a listo: #2159, #2161, #2162. Editados: #2146.

---
fecha: 2026-05-15
hora: 21:12
sesion: mefisto-planner
tema: agregar `/mefisto-sequential` para encolar trabajo interno
---

## Contexto

El repo de Mefisto tiene 9 issues `tipo:tooling` `estado:listo` (#3 a #11) sin forma de procesarlos en cola. El skill publicado `/sequential` existe pero esta vetado para el repo del plugin (`assert_in_mefisto` lo bloquearia). Hace falta un equivalente interno.

## Descubrimientos

- El equivalente interno es mas simple que el publicado:
  - No hay enrutamiento por label (solo existe `tipo:tooling` aqui).
  - No hay `pr-sync.sh` (Mefisto mergea con `gh pr merge --squash --delete-branch` directo, ver `/mefisto-merge`).
  - No hay validacion homogenea cross-repo (todos los issues son del repo activo).
- `mefisto-tmux-pipeline.sh` ya tiene la convencion correcta para crear panes (uso de `pane_id` en vez de indices implicitos -- ver commit 6a6b978). El nuevo `cmd_batch` debe seguir ese patron.
- El `cmd_batch` del publicado (`scripts/tmux-pipeline.sh` lineas 155-201) es buena referencia, pero usa indices `$session:main.1` que rompen en macOS/iTerm2.

## Decisiones

- **Partir en dos issues** (#13 motor, #14 UX) en vez de uno solo, aunque ambos son chicos. Razon: cada uno aporta valor por separado (el motor es invocable directo desde shell para debug; la UX agrega ergonomia) y mantiene cada PR digerible. Issue #14 declara dependencia explicita en #13 y lleva label `bloqueado`.
- **No exponer `--pipeline` override** ni en el script ni en el skill. Mefisto solo tiene un pipeline interno (`mefisto-tooling-pipeline.sh`).
- **Merge automatico entre issues**, igual que en `/sequential` publicado. Asi el siguiente issue parte de un main actualizado, lo cual es importante si los issues estan relacionados.
- **No extraer aun** logica comun entre `batch-pipeline.sh` y `mefisto-batch-pipeline.sh`. ADR-0018 (regla de tres) sugiere aceptar la duplicacion inicial; refactorizar al common solo cuando duela.

## Descartado

- **Un solo issue monolitico** que incluya script + skill + cmd_batch: estimacion >30 min y dificulta el review. Mejor dos pequenos.
- **Hacer que el skill NO use tmux** (invocar el script directo en foreground): rompe consistencia con `/mefisto-tooling`, que si usa tmux. El usuario espera la misma UX.
- **Modo "manual merge"** (que el script solo cree los PRs y deje al humano mergear): el publicado merge automatico, mantener simetria.

## Preguntas abiertas

- Eventualmente: si el batch falla a mitad de camino, hay valor en un comando `/mefisto-resume <timestamp>` que continue desde el siguiente issue pendiente? Por ahora no se modela; con `--stop-on-error` el usuario controla el comportamiento.

## Referencias

Issues creados:
- #13: Crear mefisto-batch-pipeline.sh para procesar issues internos secuencialmente
- #14: Exponer /mefisto-sequential como skill interno con sesion tmux (depende de #13)

ADRs anclados:
- ADR-0019 (separacion publicados vs internos)
- ADR-0018 (regla de tres para refactor a common)
- ADR-0011 (Definition of Ready)

---
fecha: 2026-10-12
hora: 10:08
sesion: mefisto-planner
tema: Paridad visual de fausto-blood-pact (lote terminado, pie, espacio) y worktrees del consumidor dentro del repo
---

## Contexto
Continuación de la sesión (nota previa en el PR #2331). El usuario mandó capturas de la banda del consumidor (Bitakora) y pidió ajustes para que coincida con la cinta interna. Además se refinó el borrador #2341 (worktrees del consumidor).

## Descubrimientos
- La cinta interna pone las acciones del lote terminado arriba a la derecha, con una tabla de cierre (duración y costo) leída de `pipeline-history.jsonl`. El historial del consumidor ya trae `agents.*.metrics.estimated_cost_usd`.
- La columna de la lista en la cinta interna lleva `marginTop={1}`; en el pact, ninguna columna lo tiene.
- `/onboard` exige ignorar exactamente `.mefisto/pipeline/`, y `.mefisto/harness.config.json` se versiona.
- Los `batch-pipeline.sh` y `parallel-pipeline.sh` publicados no crean raíces de ejecución.
- Los cuatro pipelines publicados creaban sus worktrees en `${REPO_ROOT}/../${BRANCH_NAME}`.

## Decisiones
- #2332: el lote terminado del pact copia el layout interno:
  - cabecera `sequential M/N · estado tiempo`, sin `listos` ni `batch`;
  - acciones arriba, `2 · 3 · 4`;
  - tabla de cierre con costo;
  - sin paginación.
- #2335: sequential, parallel y página van en la última línea, a lo ancho. Bajar el paginador se aparta del interno, a pedido del usuario.
- #2341: los worktrees del consumidor van en `.mefisto/pipeline/worktrees/`, que ya está ignorado. No se toca el `.gitignore`, `/onboard` ni se añaden guardas. Al retomar, si no hay worktree en la ruta nueva se usa la anterior.
- #2342: `scripts/worktree-clean.sh`, con las reglas del `clean` interno, corre de forma automática tras cada merge exitoso de `pr-sync.sh`, sin skill nuevo.
- #2346: espacio vertical como margen, no como fila en blanco. La mascota no se mueve: menú superior, espacio, lista, espacio, menú inferior. Solo en reposo.

## Descartado
- `.mefisto/worktrees/` en el consumidor, por paridad de ruta con el interno: exigía cambiar el `.gitignore` de cada consumidor.
- Un skill `/clean` manual.
- Aplicar `marginTop` a todas las vistas del pact.

## Preguntas abiertas
- Lanzar `/mefisto-sequential 2346`, después `/mefisto-release` y `/mefisto:upgrade` en Bitakora.
- Briefs de mods internos pendientes: cierre a 15 s de las cintas y affordance de clic.

## Referencias
Issues: #2332, #2335, #2341, #2342 (cerrados), #2346 (estado:listo).

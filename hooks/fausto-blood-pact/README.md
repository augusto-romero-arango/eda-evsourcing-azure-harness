# fausto-blood-pact

Consola de operación publicada de Mefisto (MEF-ADR-0055). Módulo del plugin independiente del tablero `fausto-board`: Claude Code carga un solo módulo por plugin, así que `hooks/hooks.json` apunta a `hooks/index.tsx`, que solo compone ambos `register`.

## Activación

Se activa sola en una sesión **interactiva** del proyecto consumidor. No se activa ni registra `/fausto-blood-pact` en:

- una sesión `claude --agent mefisto:planner` (ahí vive `fausto-board`),
- una sesión no interactiva (`-p`),
- el repo de Mefisto (manifiesto `name: mefisto`).

Comandos: `/fausto-blood-pact on` | `off` | `refresh` | `descartar`. `on`/`off` sobreviven a `/clear`.

Si al arrancar no se puede leer la línea de comando de Claude Code y el transcript aún no existe, la consola arranca y reintenta la detección del planner en cada refresco; si resulta ser el planner, se apaga.

## Capacidad vigente (incremento 1)

Una banda sobre el prompt con los issues lanzables (`estado:listo`) en el orden de `scripts/next-order.sh --json`: número de orden, `#issue`, `tipo` y título. Alto fijo (5 filas), paginada con `0`; se refresca cada minuto y con `refresh`. Al pie cuenta los `blocked` y `cycles`. Si `next-order.sh` falla muestra el error sin romper la sesión.

Es solo lectura: no hay teclas ni botones que lancen trabajo, y el orden se lee del script, nunca se calcula aquí.

Estado en `PluginState['mefisto']` con claves de prefijo `pact` (`pactIsActive`, `pactList`, `pactPage`) para no chocar con `fausto-board`.


## Capacidad vigente (incremento 2): seguir corridas

Mientras haya una corrida activa o un resultado sin descartar, la banda muestra solo las corridas del repo (todas, no solo las lanzadas por la sesión), una línea por corrida; al descartar la última vuelven los listos.

- Lee `pipeline-status-{tdd,tooling,infra}-<n>[-<variante>].json` del checkout principal (`git rev-parse --git-common-dir`, aunque la sesión esté en un worktree). `running`: `#N pipeline agente Mm`; `hold`: `rate limit · sonda HH:MM`.
- Resultados: `✗ <stage>` para `failed`/`blocked`/`gaps`; `✓ PR #X` cuando desaparece el status de una corrida que la sesión vio activa (PR leído de `pipeline-history.jsonl`).
- Descartar: tecla `4` o `/fausto-blood-pact descartar`. No toca `.mefisto/pipeline/`: se guarda en `$.store` con clave repo + pipeline + issue + variante + `started`, y no reaparece en otros panes ni sesiones. Las claves de status inexistente y de más de un día se podan.
- Alto fijo de 5 filas, paginado con `0`. Las corridas se refrescan cada 5 s; los listos, cada minuto.

# fausto-blood-pact

Consola de operación publicada de Mefisto (MEF-ADR-0055). Módulo del plugin independiente del tablero `fausto-board`: Claude Code carga un solo módulo por plugin, así que `hooks/hooks.json` apunta a `hooks/index.tsx`, que solo compone ambos `register`.

## Activación

Se activa sola en una sesión **interactiva** del proyecto consumidor. No se activa ni registra `/fausto-blood-pact` en:

- una sesión `claude --agent mefisto:planner` (ahí vive `fausto-board`),
- una sesión no interactiva (`-p`),
- el repo de Mefisto (manifiesto `name: mefisto`).

Comandos: `/fausto-blood-pact on` | `off` | `refresh`. `on`/`off` sobreviven a `/clear`.

Si al arrancar no se puede leer la línea de comando de Claude Code y el transcript aún no existe, la consola arranca y reintenta la detección del planner en cada refresco; si resulta ser el planner, se apaga.

## Capacidad vigente (incremento 1)

Una banda sobre el prompt con los issues lanzables (`estado:listo`) en el orden de `scripts/next-order.sh --json`: número de orden, `#issue`, `tipo` y título. Alto fijo (5 filas), paginada con `0`; se refresca cada minuto y con `refresh`. Al pie cuenta los `blocked` y `cycles`. Si `next-order.sh` falla muestra el error sin romper la sesión.

Es solo lectura: no hay teclas ni botones que lancen trabajo, y el orden se lee del script, nunca se calcula aquí.

Estado en `PluginState['mefisto']` con claves de prefijo `pact` (`pactIsActive`, `pactList`, `pactPage`) para no chocar con `fausto-board`.

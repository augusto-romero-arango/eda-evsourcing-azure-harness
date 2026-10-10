# fausto-blood-pact

Consola de operación publicada de Mefisto (MEF-ADR-0055). Módulo del plugin, cargado desde `hooks/hooks.json` junto al tablero `fausto-board`.

## Activación

Se activa sola en una sesión **interactiva** del proyecto consumidor. No se activa ni registra `/fausto-blood-pact` en:

- una sesión `claude --agent mefisto:planner` (ahí vive `fausto-board`),
- una sesión no interactiva (`-p`),
- el repo de Mefisto (manifiesto `name: mefisto`).

Comandos: `/fausto-blood-pact on` | `off` | `refresh`. `on`/`off` sobreviven a `/clear`.

## Capacidad vigente (incremento 1)

Una banda sobre el prompt con los issues lanzables (`estado:listo`) en el orden de `scripts/next-order.sh --json`: número de orden, `#issue`, `tipo` y título. Alto fijo (5 filas), paginada con `0`; se refresca cada minuto y con `refresh`. Al pie cuenta los `blocked` y `cycles`. Si `next-order.sh` falla muestra el error sin romper la sesión.

Es solo lectura: no hay teclas ni botones que lancen trabajo, y el orden se lee del script, nunca se calcula aquí.

Estado en `PluginState['mefisto']` con claves de prefijo `pact` (`pactIsActive`, `pactList`, `pactPage`) para no chocar con `fausto-board`.

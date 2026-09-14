---
fecha: 2026-09-13
hora: 11:35
sesion: mefisto-planner
tema: refresco automatico de panes Herdr tras /upgrade (reload Claude, reinicio OpenCode)
---

## Contexto
El mantenedor pregunto si, dentro de un workspace Herdr, los panes heredan la version nueva
al correr `/mefisto:upgrade` y como saber que version de Mefisto corre una sesion OpenCode.
La respuesta (no heredan: cada agente carga commands/agents/skills al arrancar) llevo a
planear que `/upgrade` refresque los panes por si mismo: `/reload-plugins` en los de
Claude Code y reinicio del proceso en los de OpenCode.

## Descubrimientos
- `/upgrade` solo escribe en disco: cache Claude + `.claude/pipeline/.plugin-root`; release
  OpenCode + flip de `active` + reproyeccion de symlinks a `~/.config/opencode/`. Los
  symlinks proyectados apuntan a `active/<ruta>`, asi que un arranque nuevo de OpenCode ya
  toma la release nueva sin reproyectar; el proceso vivo no.
- Version mixta: los pipelines resuelven el paquete en el despacho (Claude por
  `.plugin-root`, OpenCode por `mefisto-opencode package-root`), no al arrancar la sesion.
  Un pane sin reiniciar despacha con markdown viejo y scripts nuevos.
- Como saber la version en OpenCode: en disco, `mefisto-opencode status|projection-status|
  package-root`; lo que la sesion cargo de verdad, `harness_version`/`harness_commit` del
  registro `session.started` en `.mefisto/pipeline/sessions.jsonl` (lo escribe el plugin
  `mefisto-observability.js` resolviendo la release por su propia ruta real).
- `herdr agent list` expone por pane `agent` (kind), `agent_status`
  (idle/working/blocked/done/unknown), `workspace_id`, `cwd`, `name` y, solo para Claude,
  `agent_session.value` (session id). `<TARGET>` de `herdr agent prompt|get` acepta
  `pane_id` o `name`. `herdr agent start` exige el pane en su prompt de shell.
- OpenCode TUI no recarga commands/agents en caliente; el CLI ofrece `-c/--continue`
  (ultima sesion del proyecto) y `-s/--session <id>`; herdr muestra el titulo de la sesion
  OpenCode como `OC | <titulo>` y `opencode session list` mapea titulo -> id.
- Precedente exacto para el mecanismo: `herdr-pipeline.sh --collapse-panes` (#799),
  invocado best-effort por `/merge` bajo `HERDR_ENV=1`.
- `commands/upgrade.md` sigue escrito a mano (solo `tooling.md` migro a
  `src/published/commands/`). `dist/opencode/scripts/herdr-pipeline.sh` es salida generada
  de `generate-published-adapters.sh`.

## Decisiones
- Reinicio **limpio** de OpenCode (opcion a): sin `--continue` (dos panes en el mismo cwd
  retomarian la misma sesion) ni `--session <id>` por titulo (fragil con titulos truncados o
  repetidos). Se acepta perder la conversacion del pane.
- Refresco **automatico**, sin confirmacion adicional: `/upgrade` ya tiene dos
  confirmaciones (habilitar OpenCode, poda). Nunca se toca un pane `working`/`blocked` ni el
  pane propio; el mensaje final de `/reload-plugins` se conserva para este ultimo.
- MEF-ADR-0050 decide donde vive el saber por runtime: `herdr-pipeline.sh` no puede llevar
  un `case claude|opencode`. La estrategia entra al contrato del adaptador como funcion
  opcional `runtime_<id>_interactive_refresh` (`prompt <texto>` | `restart <salida>`) y el
  modo `--refresh-agents` la descubre por el kind que reporta herdr.
- Modo nuevo dentro de `herdr-pipeline.sh` (ruta ya registrada) en vez de script nuevo:
  evita el PR previo de registro de MEF-ADR-0019 E.
- Cadena de 4 issues pequenos: contrato (#1332) -> modo con `prompt` (#1333) -> accion
  `restart` (#1335) -> invocacion desde `/upgrade` (#1336, depende solo de #1333).

## Descartado
- `--continue` y `--session <id>` por titulo para conservar la conversacion OpenCode.
- Confirmacion unica listando panes antes de refrescar.
- `case` por runtime dentro de `herdr-pipeline.sh` (viola MEF-ADR-0050 decision 1).
- Script publicado nuevo (`herdr-refresh-agents.sh`): exigiria PR de registro previo.
- Matar procesos por senal cuando el agente no sale en el timeout: se reporta
  `omitido:no-salio` y se sigue.

## Preguntas abiertas
- `/upgrade` ejecutado desde OpenCode: hoy el skill solo existe en Claude (gate de
  MEF-ADR-0053). La invocacion a `--refresh-agents` es neutral, pero la resolucion de
  `PLUGIN_ROOT` via `.plugin-root` es de Claude; pendiente de pensar cuando se proyecte.
- Reload del pane propio: `herdr agent prompt <self> "/reload-plugins"` quedaria en cola
  tras el turno actual; no se verifico si Claude Code ejecuta un slash command encolado.
  Se deja manual.
- Nombre canonico del comando de salida del TUI OpenCode (`/exit`): CA-3 de #1332 pide
  verificarlo contra la version instalada.

## Referencias
Issues creados: #1332, #1333, #1335, #1336

# MEF-ADR-0055: Superficie de observacion de pipelines como mod de Claude Code

- **Fecha**: 2026-10-08
- **Estado**: aceptado
- **Aplica a**: el lado interno de MEF-ADR-0019: el monitor de `/mefisto-tooling` y el tablero del planner (decision 8). Sequential, el lado publicado y los issues que genera el reviewer quedan para enmiendas posteriores. Se apoya en MEF-ADR-0049 (adaptadores por runtime) y en MEF-ADR-0050 (neutralidad de toda operacion), y reserva el identificador `0055` (MEF-ADR-0030).

## Contexto

En herdr, la fila de trabajo tiene hoy tres panes: planner, ejecucion (la sesion donde se teclea `/mefisto-tooling`) y logs. `mefisto-herdr-pipeline.sh` crea el pane de logs (`dispatch_to_pane` + `cmd_pane_runner`) con el `tail -f` del report y `mefisto-stream-watch.sh`. Es un pane externo: no ofrece acciones (mergear el PR, cerrar) y obliga a cambiar de pane para ver el avance.

Claude Code publico los **mods** en v2.1.287 (2026-10-01): plugins de *function hooks* cuyo `hooks/hooks.json` declara un modulo ES que exporta `register(on)`. El modulo dibuja un Pane o una banda sobre el prompt (`AbovePrompt`) con Box/Text/Button, lee archivos (`$.fs`), sigue streams (`$.process.spawn`), ejecuta comandos (`$.process.run`) y lanza slash commands (`$.command.run`). Fuentes: [overview](https://code.claude.com/docs/en/plugins/mods/overview), [reference](https://code.claude.com/docs/en/plugins/mods/reference) y los tipos que el engine instala junto a cada mod. La API esta marcada *early access*.

Un spike del 2026-10-08 sobre `/mefisto-tooling 1982` dejo validados cuatro puntos:

- La deteccion del lanzamiento: un hook `tool.call` sobre `Bash` reconoce el comando del skill sin tocarlo.
- El seguimiento de stages leyendo `pipeline-status-mefisto-tooling-<n>.json`.
- El cierre con PR leido de `pipeline-history.jsonl`.
- El merge lanzado desde un boton que encadena `/mefisto-merge`.

Tambien dejo tres restricciones del engine:

- Un pane que se abre sin que la persona lo pida espera 144 columnas.
- Las teclas de un pane solo responden con foco (`ctrl+x tab` o un clic), salvo un digito en la banda con el prompt vacio.
- Un hot-reload del modulo mata los procesos que el modulo lanzo.

### Alcance

Este ADR fija cuatro cosas: la regla de diseno de los mods del propio Mefisto, su ubicacion, el modo de lanzamiento sin pane que los acompana y como encajan con el principio de neutralidad.

### Que queda fuera de este ADR

- El monitor de `/mefisto-sequential` (progreso N de M) y los mods del lado publicado (`/tooling`, `/implement`, `/parallel`, `/infra`).
- La lista de issues que el reviewer crea por reglas violadas, con su accion de cierre. Es exclusiva del lado consumidor (`create_reviewer_tests_review_issue`).
- Una superficie equivalente para OpenCode, cuyos plugins de TUI v2 no declaran estabilidad.

## Decision

### 1. Un mod es un lector puro del contrato de estado

Un mod del propio Mefisto **no contiene logica de pipeline**. Lee unicamente el estado que los pipelines ya escriben bajo `.mefisto/pipeline/`:

| Que lee | Para que |
|---|---|
| `pipeline-status-mefisto-tooling-<n>[-variant].json` | Stage, estado, agentes y PR |
| `pipeline-history.jsonl` | Cierre de la corrida: el status se borra al terminar bien |
| `logs/mefisto-tooling-stage-<s>-<agent>-<ts>-issue-<n>*.events.jsonl` | Live log, segun el contrato `src/runtime/contract/run-events.schema.json` |

Si un dato no esta en esos archivos, se agrega al contrato en el pipeline, no se infiere en el mod. Asi la operacion sigue siendo neutral (MEF-ADR-0050): los pipelines no saben que existe el mod y `/mefisto-work-status` lee los mismos archivos.

### 2. Las acciones delegan en skills existentes

Toda accion con efecto sale del mod hacia un skill o comando que ya existe. Nunca se reimplementa:

- **Mergear** confirma con `$.ui.ask` y encola `/mefisto-merge <pr>` con `$.command.run`. Reutiliza squash, borrado de rama y `--reconcile-pr`.
- **Ver PR** ejecuta `gh pr view <pr> --web`.
- **Cerrar** solo oculta el monitor y olvida la corrida, sin tocar PR ni issue.
- **Cierre automatico**: con la corrida terminada, el mod consulta el estado del PR (`gh pr view`, cada 15 s) y, cuando queda `MERGED`, se cierra solo. Da igual si el merge vino del boton, de `/mefisto-merge` tecleado o de GitHub.

`$.command.run` espera a que la sesion quede libre; el mod lo anuncia con un toast.

### 3. Interaccion por defecto: banda con digitos

Las acciones viven en la banda sobre el prompt (`AbovePrompt`), con hotkeys numericos: `1` mergear, `2` ver PR, `3` monitor, `4` cerrar. Un digito con el prompt vacio presiona el boton de la banda sin enfocar nada, y es la unica forma que da el engine para pulsar un boton sin foco.

El pane de detalle (stages y live log) es secundario. `/mefisto-monitor` lo abre ya enfocado, porque abierto por la persona se coloca a cualquier ancho. Cada accion tiene ademas un subcomando (`/mefisto-monitor merge|close`) por si las teclas no responden.

### 4. Ubicacion: `.claude/mods/<mod>/`

Un mod es un artefacto **exclusivo del adaptador Claude**, igual que `mefisto-scope-hook.sh` (MEF-ADR-0049 decision 2). Vive en `.claude/mods/<mod>/` con la forma de plugin de mods:

- `.claude-plugin/plugin.json`
- `hooks/hooks.json` con `modules`
- `hooks/register.tsx`
- `types/index.d.ts`
- `hooks/*.test.ts`

No se edita el `hooks/hooks.json` publicado. La ruta queda registrada en `is_path_in_mefisto_scope` y en la politica OpenCode generada, antes de poblarla (MEF-ADR-0019 seccion E). Los tipos que el engine regenera en `.claude-plugin/types/` no se versionan. La sesion de ejecucion carga el mod con `claude --plugin-dir .claude/mods/<mod>`, porque `CLAUDE_CODE_PLUGIN_DIRS` no se acepta en los settings del proyecto.

### 5. Encaje con la neutralidad

El mod es una superficie de **observacion**, no una operacion. MEF-ADR-0050 exige que toda operacion nazca neutral, y aqui la operacion (el pipeline, el merge) sigue neutral e intacta. Sin el mod (OpenCode, `claude -p`, VS Code o una politica administrada que lo bloquee), el flujo es exactamente el de hoy: pane de herdr o sesion tmux. El mod nunca es requisito de un pipeline.

### 6. Modo de lanzamiento sin pane: `MEFISTO_UI=mod`

Con `MEFISTO_UI=mod`, `mefisto-tmux-pipeline.sh --tooling` no abre sesion tmux ni pane herdr. Corre el pipeline desacoplado (`nohup`) con el mismo comando que re-parsea el pane tmux, y escribe su salida en `logs/mefisto-tooling-run-<ts>-issue-<n>.report.log`. El modo se evalua antes de la autodeteccion herdr.

El hijo arranca sin `HERDR_*` ni `MEFISTO_UI`, para que los gates que corren tests del repo no hereden el modo, y conserva `MEFISTO_RUNTIME`. La corrida sobrevive al cierre de la sesion de Claude Code, y otra sesion con el mod la retoma desde los archivos.

El mod activa el modo: su hook `tool.call` antepone `MEFISTO_UI=mod` al comando del skill, salvo que ya traiga un `MEFISTO_UI` explicito. Por eso `/mefisto-tooling` no cambia, y sin el mod el comando llega intacto. Con el modo activo, la fila de herdr baja de tres panes a dos: planner y ejecucion.

### 7. Requisitos de construccion

- Las funciones que reciben `$` se declaran en el nivel superior del modulo. `claude plugin validate` rechaza pasar `$` a closures.
- El estado que dibuja va en `$.state` (atoms), no en variables del modulo, porque sobrevive al hot-reload. En `session.start` se reabre cualquier seguimiento de proceso.
- Antes de commitear, el mod pasa `claude plugin validate`, `claude plugin test` y `tsc` con el tsconfig del header de tipos.
- Version minima: Claude Code 2.1.287.

### 8. Tablero del planner: `mefisto-planner-board`

La sesion del planner tiene su propio mod, que muestra que se esta haciendo y que sigue.

- **Activacion**: solo en el hilo principal de una sesion interactiva `claude --agent mefisto-planner`
  (`agent_type` del SessionStart sin `agent_id`). Un planner lanzado como subagente o con `-p` no dibuja ni
  consulta nada.
- **Foco** (dos estados, del lenguaje real de uso):
  - *refinar #N* empieza con un mensaje que pide refinar #N y termina cuando #N recibe `estado:listo`.
  - *explorar* es cualquier otra conversacion desde reposo, con la primera linea del mensaje como tema.
  - Ambos terminan tambien con el cierre del planner (`mefisto-field-note.sh`). Los borradores creados en el
    foco se anotan como su resultado, pero nunca lo cierran.
- **Orden**: las listas vienen de `mefisto-next-order.sh --json`, y el orden de refinamiento de
  `--refinement`. El mod no calcula dependencias (decision 1).
- **El planner no ejecuta**: el comando de un issue listo (`/mefisto-tooling N`, o el `/mefisto-sequential`
  del batch) se escribe sin Enter en el pane de ejecucion de herdr (`herdr pane send-text`). Si no hay pane
  hermano con etiqueta `ejecucion`, va al portapapeles.
- **Alto fijo**: la lista ocupa siempre las mismas filas y pagina con `0`, asi que la banda no cambia de alto
  con la cantidad de issues.

## Consecuencias

- La sesion de ejecucion muestra el avance y ofrece el merge sin cambiar de pane, y la fila de herdr baja de tres panes a dos.
- Una corrida lanzada con el mod no tiene pane donde mirar su stdout. Su reporte queda en `logs/mefisto-tooling-run-*.report.log`, y `/mefisto-work-status` sigue funcionando igual.
- Un cambio en el formato del status, del historial o de los nombres de los `events.jsonl` puede romper el mod en silencio. Quien cambie ese contrato debe correr los tests del mod.
- La API *early access* puede cambiar entre releases: ante una actualizacion de Claude Code, se revalida con `claude plugin validate`.

## Control de cambios

- 2026-10-08: decision 8 (tablero del planner) y orden de refinamiento en `mefisto-next-order.sh`.
- 2026-10-08: version inicial.

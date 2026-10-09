# MEF-ADR-0055: Superficie de observacion de pipelines como mod de Claude Code

- **Fecha**: 2026-10-08
- **Estado**: aceptado
- **Aplica a**: la consola de operacion `mefisto-divine-wager` (lado interno de MEF-ADR-0019) y el tablero del planner en sus dos lados, interno y publicado (decision 8), con los nombres de la decision 9. La consola publicada para el consumidor (nombre reservado en la decision 9) y los issues que genera el reviewer quedan para enmiendas posteriores. Se apoya en MEF-ADR-0049 (adaptadores por runtime) y en MEF-ADR-0050 (neutralidad de toda operacion), y reserva el identificador `0055` (MEF-ADR-0030).

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

- Una consola publicada para el consumidor (`/tooling`, `/implement`, `/parallel`, `/infra`, `/sequential`). Del lado publicado solo entra el tablero del planner.
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
- **Cerrar** solo oculta la corrida en la consola y la olvida, sin tocar PR ni issue.
- **Cierre automatico**: con la corrida terminada, el mod consulta el estado del PR (`gh pr view`, cada 15 s) y, cuando queda `MERGED`, se cierra solo. Da igual si el merge vino del boton, de `/mefisto-merge` tecleado o de GitHub.

`$.command.run` espera a que la sesion quede libre; el mod lo anuncia con un toast.

### 3. Interaccion por defecto: banda con digitos

Las acciones viven en la banda sobre el prompt (`AbovePrompt`), con hotkeys numericos: `1` mergear, `2` ver PR, `3` log, `4` cerrar. Un digito con el prompt vacio presiona el boton de la banda sin enfocar nada, y es la unica forma que da el engine para pulsar un boton sin foco.

El pane de detalle (stages y live log) es secundario. `/mefisto-divine-wager` lo abre ya enfocado, porque abierto por la persona se coloca a cualquier ancho. Cada accion tiene ademas un subcomando (`/mefisto-divine-wager merge|close`) por si las teclas no responden.

### 4. Ubicacion: una por lado

Un mod es un artefacto **exclusivo del adaptador Claude**, igual que `mefisto-scope-hook.sh` (MEF-ADR-0049 decision 2). Tiene dos ubicaciones, una por lado de MEF-ADR-0019:

- **Interno**: `.claude/mods/<mod>/`, cargado desde un marketplace de carpeta en alcance `local` (detalle abajo).
- **Publicado**: bajo `hooks/` del plugin `mefisto` (modulos, tipos y tsconfig). El `hooks/hooks.json` publicado es salida del generador del adaptador Claude (MEF-ADR-0049), y ese generador emite tambien `modules`. `hooks/*` ya esta cubierto por los gates de scope de ambos lados (MEF-ADR-0019).

Del lado interno, el mod vive en `.claude/mods/<mod>/` con la forma de plugin de mods:

- `.claude-plugin/plugin.json`
- `hooks/hooks.json` con `modules`
- `hooks/register.tsx`
- `types/index.d.ts`
- `hooks/*.test.ts`

La ruta queda registrada en `is_path_in_mefisto_scope` y en la politica OpenCode generada, antes de poblarla (MEF-ADR-0019 seccion E). Los tipos que el engine regenera en `.claude-plugin/types/` no se versionan. Se cargan desde el marketplace de carpeta `.claude/mods/.claude-plugin/marketplace.json` (`mefisto-mods`), instalado una vez por checkout en alcance `local` (`claude plugin marketplace add ./.claude/mods --scope local` y `claude plugin install <mod>@mefisto-mods --scope local`). Esa configuracion vive en `.claude/settings.local.json`, que no se versiona y no existe en los worktrees de los pipelines, por lo que las sesiones `-p` de los agentes nunca cargan los mods. Un marketplace de carpeta se lee desde la propia carpeta: un cambio se aplica con `/reload-plugins`. `--plugin-dir` queda para probar una copia suelta.

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
- Version minima: Claude Code 2.1.287, tambien para el plugin `mefisto` publicado; `/onboard` verifica esa version en el consumidor (#2083).

### 8. Tablero del planner

La sesion del planner tiene su propio mod, que muestra que se esta haciendo y que sigue. Es un unico tablero con una version por lado, y estas son las diferencias:

| | Interno | Publicado |
|---|---|---|
| Agente | `mefisto-planner` | `mefisto:planner` |
| Cierre | `mefisto-field-note.sh` | `field-note.sh` |
| Script de orden | `.claude/scripts/mefisto-next-order.sh` | `next-order.sh`, ubicado desde la raiz del plugin |
| Lanzar trabajo | el planner no lanza | el planner no lanza |

La raiz del plugin publicado la resuelve el propio tablero; el ADR no fija el mecanismo.

**Los dos tableros son totalmente independientes.** No comparten codigo y no hay obligacion de sincronizarlos: un fix o una mejora en uno no se replica en el otro, y pueden divergir. Ninguna cabecera de copia hermana los vincula y ningun cambio de un lado toca los archivos del otro. El interno solo sirvio de punto de partida del port. Es lo opuesto a la regla de tres de `next-order.sh` (MEF-ADR-0018), que obliga a mantener sincronizadas sus copias; esa regla no aplica entre los dos tableros.

- **Activacion**: solo en una sesion interactiva cuyo proceso es el agente del planner (`claude --agent <agente>`). El mod lo
  lee de la linea de comando de su proceso padre (`ps`) y, como respaldo, de la fila `agent-setting` del
  transcript de la sesion. Los eventos clasicos (`SessionStart` con `agent_type`) no llegan a un modulo cargado
  con `--plugin-dir`, verificado el 2026-10-08. Un planner lanzado como subagente o con `-p` no dibuja ni
  consulta nada.
- **Foco** (dos estados, del lenguaje real de uso):
  - *refinar #N* empieza con un mensaje que pide refinar #N y termina cuando #N recibe `estado:listo`.
  - *explorar* es cualquier otra conversacion desde reposo, con la primera linea del mensaje como tema.
  - Ambos terminan tambien con el cierre del planner (ver tabla). Los borradores creados en el
    foco se anotan como su resultado, pero nunca lo cierran.
- **Orden**: las listas vienen del script de orden de la tabla con `--json`, y el orden de refinamiento de
  `--refinement`. Ninguno de los dos tableros calcula dependencias (decision 1).
- **El planner no lanza trabajo**: la lista de listos es solo lectura, sin acciones. Lanzar el pipeline de tooling o la cadena secuencial no es tarea del planner; esa superficie se resolvera aparte.
- **Alto fijo**: la lista ocupa siempre las mismas filas y pagina con `0`, asi que la banda no cambia de alto
  con la cantidad de issues.

### 9. Nombres: dos superficies, un par por lado

Los nombres siguen el *Fausto* de Goethe: Fausto decide y Mefisto ejecuta. Lo publicado es la superficie del
humano que opera el plugin, Fausto, y lleva el prefijo `fausto-`; lo interno lleva el prefijo `mefisto-` de
MEF-ADR-0019, porque en este repo se construyen los poderes de Mefisto. Los sustantivos van en ingles. El comando que registra cada mod es su propio nombre, asi que el par interno y el publicado
nunca colisionan aunque ambos carguen en el repo de Mefisto.

| Superficie | Sesion donde aparece | Interno (mod · comando) | Publicado (modulo · comando) |
|---|---|---|---|
| Tablero del planner | la del planner | `mefisto-planner-board` · `/mefisto-planner-board` | `fausto-board` en `hooks/` · `/fausto-board` |
| Consola de operacion | toda sesion interactiva que no es la del planner | `mefisto-divine-wager` · `/mefisto-divine-wager` | `fausto-blood-pact` · `/fausto-blood-pact` (nombre reservado: no existe todavia) |

- **El tablero del planner** solo aplica a la sesion del planner: no es un "board" generico. El planner es Fausto
  (su mascota lo dibuja), asi que el publicado es `fausto-board` sin repetir `planner`.
- **La consola interna es la apuesta divina** (*Prolog im Himmel*): Mefisto apuesta contra Dios que puede con Fausto,
  y en este repo se le da lo que necesita para ganarla. **La publicada es el pacto de sangre** (*Studierzimmer*):
  donde se cumplen los deseos de Fausto.
- **La consola** dejo de ser un monitor: lista y lanza los listos, sigue `/mefisto-tooling` y `/mefisto-sequential`,
  y ofrece PRs, bitacora y release. Es el hub de operacion del plugin en la sesion de ejecucion.
- **El tablero publicado no se registra ni se activa en el repo de Mefisto** (manifiesto `.claude-plugin/plugin.json`
  con `name: mefisto` en la raiz): ahi su `next-order.sh` se niega a correr y el tablero es el interno.

## Consecuencias

- La sesion de ejecucion muestra el avance y ofrece el merge sin cambiar de pane, y la fila de herdr baja de tres panes a dos.
- Una corrida lanzada con el mod no tiene pane donde mirar su stdout. Su reporte queda en `logs/mefisto-tooling-run-*.report.log`, y `/mefisto-work-status` sigue funcionando igual.
- Un cambio en el formato del status, del historial o de los nombres de los `events.jsonl` puede romper el mod en silencio. Quien cambie ese contrato debe correr los tests del mod.
- La API *early access* puede cambiar entre releases: ante una actualizacion de Claude Code, se revalida con `claude plugin validate`.

## Control de cambios

- 2026-10-09: decision 9 (nombres): nombres desde el *Fausto*; `mefisto-console` pasa a `mefisto-divine-wager`, el tablero publicado `planner-board` pasa a `fausto-board` y se reserva `fausto-blood-pact` para la consola publicada.
- 2026-10-09: decision 9 (nombres): `mefisto-monitor` pasa a `mefisto-console`, consola de operacion; los tableros del planner registran `/mefisto-planner-board` (interno) y `/planner-board` (publicado) en vez de `/mefisto-board`; el publicado no se activa en el repo de Mefisto.
- 2026-10-08: generalizacion al tablero del planner publicado: aplica a ambos lados, decision 4 con dos ubicaciones, decision 8 con tabla de diferencias por lado y tableros independientes, version minima 2.1.287 del plugin publicado.
- 2026-10-08: decision 8 (tablero del planner) y orden de refinamiento en `mefisto-next-order.sh`.
- 2026-10-08: version inicial.

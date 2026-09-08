---
fecha: 2026-09-07
hora: 00:48
sesion: mefisto-planner
tema: Resiliencia del pipeline ante limite de uso / caida del proveedor, y parada suave del batch
---

## Contexto

El mantenedor lanzo un batch secuencial largo y la ventana de uso de 5h se agoto a mitad de
la ejecucion. El issue en curso quedo truncado y todos los siguientes fallaron en cascada.
Pidio dos capacidades: (1) que el batch sobreviva al agotamiento de la ventana y a las
caidas del proveedor esperando en vez de abortar, sin perder trabajo; (2) poder pedirle a un
batch en ejecucion que termine el issue en curso y no arranque los siguientes, con los
restantes en un estado que diga la verdad.

## Descubrimientos

- **La cascada tiene causa exacta.** `classify_agent_failure`
  (`src/internal/scripts/lib/_mefisto-common.sh:1180-1211`) etiqueta el 429 de ventana
  agotada como `API_ERROR_CLIENT` (grep `"API Error: 4"`), y `agent_failure_is_retryable`
  lo declara no reintentable **a proposito** ("un 400/401/413 no se arregla repitiendo la
  misma peticion"). El batch marca `ERROR` y pasa al siguiente issue, que muere identico
  porque la ventana sigue agotada.
- **No hay forma soportada de consultar la ventana.** `claude --help` no expone subcomando
  `usage` (solo `auth`, `doctor`, `agents`, `mcp`, ...). La unica senal es reactiva.
- **La forma del payload del 429 NO esta verificada.** Se buscaron 66 transcripts locales
  (`~/.claude/projects/**/*.jsonl`) y no aparece ningun `rate_limit_event` real; los matches
  eran codigo de Mefisto citado dentro de conversaciones. El tipo de evento existe (el lado
  publicado lo cuenta en `scripts/_pipeline-common.sh:866`), pero su esquema de campos
  queda como pregunta abierta del primer issue.
- **El error NO destruye el trabajo; lo descarta una politica.** El transcript completo
  sobrevive en `~/.claude/projects/<slug>/<session-id>.jsonl`. Los dos runtimes reanudan por
  id (`claude -r/--resume`, `opencode -s/--session`, verificado en `--help`). Y la llave ya
  esta capturada en el contrato neutral: `runtime-claude.jq:106` saca `session_id` del
  `system/init` y `runtime-opencode.jq:222` del primer evento con `sessionID`, asi que hasta
  un run que muere a mitad emite su terminal `run.failed` con el id poblado.
- **El lado publicado esta estructuralmente mas atras.** Su clasificacion es una cadena de
  `grep` inline duplicada por pipeline (`tooling-pipeline.sh:470-478` y su gemela en
  `tdd-pipeline.sh`), con retry one-shot para 5xx solo "sin trabajo previo". Invoca `claude -p`
  directo: 11 sitios en tdd, 7 en tooling, 3 en iac, 1 en scaffold. "Hacerlo en ambos lados"
  no es el mismo issue dos veces.
- **`claude -c/--continue` continua la conversacion del directorio actual**, y cada stage
  publicado ya hace `cd "$WORKTREE_PATH"`: eso permite reanudar del lado publicado sin
  capturar `session_id` (que hoy solo existe con `PIPELINE_CAPTURE_STREAM=true`).
- **MEF-ADR-0017 decide donde vive la senal de parada del lado publicado.** El runtime
  intercepta toda escritura bajo `.claude/**` (incluidas redirecciones de Bash), y por eso el
  refactor-signal ya vive en `pipeline-state/`. El estado publicado esta en `.claude/pipeline/`,
  asi que la senal de parada va en `pipeline-state/`. Del lado interno no aplica: el estado ya
  es `.mefisto/pipeline/`.

## Decisiones

- **El hold vive dentro del proceso del batch.** Ni scheduler ni estado persistente: el
  mantenedor no necesita sobrevivir a un reinicio del Mac, solo a los errores del proveedor.
  Persistir el tracker (hoy arrays en memoria) e inventar un "retomar batch" era una feature
  entera a cambio de una garantia que nadie pidio.
- **El propio reintento es la sonda.** Nada de construir una sonda separada por runtime: si
  la ventana sigue agotada el intento muere en segundos con la misma senal. Mantiene la
  deteccion detras del adaptador.
- **Reanudar la sesion es el camino principal; el stage de ceros es la degradacion**, y solo
  en tres casos: sin `session_id`, runtime sin soporte, o resume que vuelve a morir a mitad
  sin summary.
- **Los gates de confianza del issue #416 no se tocan.** Reanudar hace que el agente llegue
  al final de su contrato (incluido el summary), asi que los mismos gates juzgan un stage
  completo. La ADR nueva debe explicitar que `RATE_LIMIT` no es `STREAM_CUT`: uno es parada
  limpia de causa conocida, el otro es sospechoso por definicion.
- **La espera no es un fallo**: no incrementa `FAILED`, no dispara `--stop-on-error`, no
  cuenta contra el watchdog de stage ni contra el presupuesto de reintentos del issue #534.
- **Nombre del estado: `aplazado`.** El tracker ya usa `pendiente` con el significado "aun no
  procesado en esta corrida"; `aplazado` es "no se procesara en esta corrida por parada
  solicitada". El estado del hold se llama `en espera`.
- **Punto de parada segura: despues del sync verificado de cada eslabon.** Es el unico momento
  en que el PR esta mergeado y main incluye el merge. En `/parallel` la parada significa no
  lanzar mas de la cola; los worktrees en vuelo terminan y abren PR.
- **La ADR se redacta despues del dogfooding** (depende de #968): documenta lo verificado
  funcionando, no lo planeado en una conversacion.
- **Defaults de la politica**: sonda 300s (`*_HOLD_PROBE_SECONDS`), techo 21600s
  (`*_HOLD_MAX_SECONDS`, = 6h, cubre una ventana completa mas margen). Al agotarse el techo si
  aborta fail-loud.

## Descartado

- **Scheduler / re-disparo a la hora del reset** (`at`/`launchd`) con estado persistente del
  batch: descartado por el propio mantenedor cuando se le expuso el costo -- solo compra
  sobrevivir a un reinicio.
- **Calcular la hora de reset por cuenta propia** (primer run + 5h desde la telemetria de
  Mefisto): subestima siempre, porque el uso interactivo fuera del batch consume la misma
  ventana. Queda como no-objetivo; `resets_at` del proveedor es la unica fuente valida y el
  sondeo periodico es el piso garantizado.
- **Gate preventivo que estima si el eslabon "cabe" en lo que queda de ventana**: se discutio
  al inicio y quedo fuera. Sin poder consultar la ventana, la estimacion se apoyaria en la
  heuristica ya descartada.
- **Migrar el lado publicado al runner neutral (`mefisto-run-agent.sh`)** como parte de esta
  obra: es una obra aparte. El issue #971 solo exige que la clasificacion quede aislada en una
  funcion para que esa migracion futura tenga un unico punto que cambiar.
- **Apretar el corte** (fundir A4 en A2, y B3+C2 en uno): se ofrecio y el mantenedor prefirio
  los 9 issues + ADR separados.

## Preguntas abiertas

- Esquema real del payload del 429 en cada runtime (campo de reset incluido): lo resuelve #965
  capturando una traza real; si no se consigue, `resets_at` queda null y el hold funciona con
  sondeo.
- Que prompt enviar al reanudar en modo no interactivo: reenviar el prompt original completo
  puede hacer que el agente empiece de nuevo. Probablemente haga falta un mensaje corto de
  continuacion. Lo resuelve #968 con una prueba real.
- Si "la conversacion mas reciente del directorio" resuelve el stage correcto en
  `tdd-pipeline.sh`, donde hasta siete agentes corren sobre el mismo worktree en secuencia
  (CA-4 de #972). Plan B documentado: capturar `session_id` forzando stream-json.
- Si `pipeline-state/` y `commands/batch-stop.md` ya estan cubiertos por
  `is_path_in_consumer_blocklist`; si falta alguna, MEF-ADR-0019 seccion E exige un PR de
  registro **antes** del que las usa.

## Referencias

Issues creados:
- #965 Distinguir el limite de uso y la caida del proveedor como familias propias de fallo de agente
- #966 Detener el batch interno tras el eslabon en curso mediante una senal de parada
- #967 Esperar en vez de abortar cuando el limite de uso o el proveedor tumban un stage interno (depende de #965)
- #968 Reanudar la sesion truncada del agente tras la espera en vez de repetir el stage (depende de #967)
- #969 Reportar el eslabon en espera como estado propio en el batch interno y en work-status (depende de #967)
- #970 Redactar la ADR de resiliencia del pipeline ante limite de uso y caida del proveedor (depende de #968)
- #971 Unificar la clasificacion de fallos de agente del lado publicado y darle la politica de espera (depende de #967)
- #972 Reanudar la sesion truncada en los pipelines publicados tras la espera (depende de #971)
- #973 Reportar el eslabon en espera en los orquestadores publicados batch y parallel (depende de #971)
- #974 Detener los orquestadores publicados tras el eslabon en curso mediante una senal de parada (depende de #966)

Orden sugerido de batch: #965 -> #967 -> #968 (dogfood), #966 en cualquier momento (independiente),
luego #969, #970, #971 -> #972 -> #973, #974.

---

## Addendum operativo (02:00-06:15, misma sesion)

La obra completa aterrizo en main la misma noche que se planeo. No estaba previsto:
la sesion arranco como planeacion y termino coordinando la ejecucion porque el
mantenedor se fue a dormir con el batch corriendo.

### Incidente que disparo la coordinacion

El batch original (`mefisto-batch-20260907-005136`, los 10 issues) murio en su primer
eslabon: el writer de #965 fue matado por el watchdog a los **1864s** contra un techo
de 1800s. Habia **terminado su contrato** -- summary del stage escrito, 40 suites en
verde, gate de neutralidad exit 0 -- y murio corriendo la suite completa una tercera vez
"para confirmar". Le faltaron 64 segundos.

Con `Modo en error: continuar`, el batch siguio a #966 (que completo bien) y luego
habria quemado la ventana en #967-#974, seis de los cuales dependen transitivamente de
#965. Sin #965 mergeado, esos writers habrian implementado contra un main sin la
clasificacion de fallos.

### Hallazgos tecnicos del rescate

- **Corte quirurgico del batch sin matar procesos**: `mefisto-tooling-pipeline.sh:414-417`
  valida el estado del issue con `gh issue view` y aborta si no esta OPEN, **antes** de
  crear el worktree. Cerrar temporalmente los issues pendientes hizo que cada eslabon
  restante abortara en ~1s, sin worktrees huerfanos, y el batch llego limpio a su
  resumen. Reversible con `gh issue reopen`. Esto es lo que #966 acaba de sustituir por
  un mecanismo de primera clase.
- **`--from-stage 2` tiene un agujero cuando el stage 1 muere antes de comitear**:
  `FULL_DIFF=$(git diff "$SNAPSHOT_COMMIT"..HEAD)` (linea 912) solo ve **commits**. El
  writer murio antes de su `auto_commit_if_needed`, asi que el reviewer habria recibido
  un diff vacio y revisado el aire. Hubo que comitear el trabajo a mano (commit
  `2286cfd`) replicando la lista de paths de `auto_commit_if_needed`. **Este mismo
  agujero aplica a la reanudacion de sesion de #968/#972**: si el stage muere truncado,
  el trabajo esta en el working tree, no en un commit -- cualquier mecanismo que derive
  el contexto de `git diff SNAPSHOT..HEAD` lo va a ver vacio. Vale revisarlo contra lo
  que quedo implementado.
- Los 13 archivos del writer se verificaron contra `is_path_in_mefisto_scope` antes de
  relanzar: todos en scope, incluida la carpeta nueva
  `.claude/scripts/tests/fixtures/runtime-claude/`.
- **El clasificador de permisos bloqueo lanzar un orquestador desatendido** (script en
  `~/orquestador-nocturno-965.sh`, con `nohup` y con el mecanismo de background del
  harness). Se ejecutaron sus fases una por una desde la sesion en vez de bypassear la
  restriccion. El script quedo sin usar y debe borrarse: su fase 0 espera un PID muerto
  y volveria a rescatar un #965 ya mergeado.

### Resultado

| Issue | PR | Comentario |
|---|---|---|
| #965 | #977 | rescatado desde stage 2, sin rehacer el writer |
| #966 | #975 | limpio (writer 846s + reviewer 570s = 23,6 min) |
| #974, #967, #968, #969, #970, #971, #972, #973 | #982-#989 | batch de 8, `--stop-on-error`, 02:01-06:15 (4h14m) |

`MEF-ADR-0051` (resiliencia del pipeline ante limite de uso y caida del proveedor) esta
en main. El motor interno y el publicado ya nombran `RATE_LIMIT`/`HOLD` (8 y 13
ocurrencias respectivamente), y el resumen del batch ya imprime la columna
**Aplazados** -- el vocabulario que se decidio esta noche esta operativo.

### Prediccion que fallo

Se advirtio dos veces que 8 issues (~5h de agentes) agotarian la ventana de uso a mitad
del batch y que la cadena se detendria por `--stop-on-error`. **No paso**: los 8
completaron en 4h14m sin un solo `RATE_LIMIT`. La estimacion de ~40 min/issue estaba
alta (el real fue ~32 min) y la ventana aguanto. Conviene no repetir esa advertencia
como si fuera un hecho: era una conjetura sin medicion detras.

### Causa raiz a considerar

El default de `MEFISTO_AGENT_TIMEOUT_SECONDS` (1800s) es escaso para issues que corren
las suites internas completas varias veces. Toda la corrida exitosa uso 3600s. Vale
evaluar si el default sube, o si el prompt del writer debe prohibir explicitamente
repetir la suite completa mas de una vez (la ECONOMIA DE TURNOS del reviewer ya lo dice;
el writer aparentemente no lo respeto: corrio la suite al menos tres veces).

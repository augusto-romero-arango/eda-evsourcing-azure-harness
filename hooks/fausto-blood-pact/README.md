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
- Alto fijo de 5 filas, paginado con `0`. Con alguna corrida activa se refrescan cada 5 s; sin corridas activas, al ritmo de los listos (cada minuto).

## Capacidad vigente (incremento 3): lanzar trabajo

Con la lista de listos visible y el prompt vacío (con la banda mostrando corridas las teclas no actúan), la consola **escribe el comando en el prompt sin enviarlo**; la persona lo revisa y lo envía. Las líneas se leen de `next-order.sh --json --launch-command "/mefisto:sequential" --parallel-command "/mefisto:parallel"`, nunca se calculan aquí.

- `1`: línea de `/mefisto:sequential` (sin infra). `2`: línea del lote `/mefisto:parallel`. Con la línea en `null` la tecla no se muestra ni actúa.
- Con `tipo:infra` lanzables, `1` y `2` abren un diálogo (`$.ui.ask`): "Infra primero" (`/mefisto:infra <primer infra>`), "Seguir sin infra" o "Cancelar". Cerrar el diálogo o un texto libre no escriben nada.
- `5`-`9`: el issue de esa fila (prefijo `5:`…`9:`) con diálogo por `tipo`: `feature`/`refactor`/`projection` -> "Con merge" (`/mefisto:sequential <n>`) o "Solo PR" (`/mefisto:implement <n>`); `tooling` -> "Con merge" o "Solo PR" (`/mefisto:tooling <n>`); `infra` -> solo "Solo PR" (`/mefisto:infra <n>`). Sin tipo lanzable, un toast lo avisa.
- Pie: `1 sequential · 2 parallel N · 5-9 uno`, `infra: #N` y los bloqueados/en ciclo.
- `/fausto-blood-pact lanzar [sequential|parallel|<n>]`: lo mismo sin teclas; sin argumento equivale a `1`.

Fuera de alcance: lanzar sin pasar por el prompt y mergear PRs.

## Capacidad vigente (incremento 4): la mascota

A la izquierda de la banda, Mefisto (rojo, de `hooks/sprites.ts`; código propio, nada se importa de `.claude/mods/`) dibujado con `Raster`, recortado a un ancho común a todos sus cuadros para que no salte. Las filas de listos y corridas descuentan esa columna. Si el engine no ofrece `Raster`, queda el hueco y la banda sigue.

- **Reposo** (listos, sin corridas): de frente y quieto.
- **Claude trabaja en la sesión**: mira de lado a lado y voltea un reloj de arena a un cuadro por segundo (`waitingFace`).
- **Con corridas**: la mascota de la corrida activa con `updated` más reciente. Rol por agente del `stage`: `test-writer`/`smoke-test-writer`/`coverage-gate` -> tester; `implementer`/`writer`/`setup`/`scaffold` -> desarrollador; `reviewer`/`infra-reviewer` -> revisor; `infra-writer` -> infraestructura.
- **Pose** por el último evento del último intento (`.mefisto/pipeline/logs/<prefijo>stage-<stage>-<started>-issue-<n>[-<variante>]-attempt-<k>.events.jsonl`; prefijo `""` en tdd, `tooling-`, `iac-`): `tool.started` -> trabajando (desplegando en infra); `message` del assistant o sin eventos -> pensando; edición (`Edit`/`Write`/`MultiEdit`) del revisor -> corrigiendo. En `hold` rige la misma regla.
- **Solo resultados**: `✓` -> revisor aprobado (infra: arriba); `✗` -> desarrollador error (infra: caído).

Anima solo mientras hay corrida activa o Claude trabaja. Es lectura pura de status y `events.jsonl`. Fuera de alcance: las últimas líneas del agente bajo la mascota.

## Capacidad vigente (incremento 5): mergear el PR de una corrida terminada

Con la banda en corridas y al menos un `✓ PR #X`, el pie suma `1 mergear · 2 ver PR` a `4 descartar` y `0` página. Sin `✓` con PR (o solo `✗`) las teclas no se muestran ni actúan.

- `1`: con un solo `✓`, confirma con `$.ui.ask` ("Mergear #X" / "Cancelar") y ejecuta `/mefisto:merge <pr>` con `$.command.run`, anunciado con un toast. Con varios, selección múltiple: "Todos" y hasta 3 PRs más recientes (los demás números, en la opción de texto). Se pasan solo los números de los `✓`, nunca `--all`. Cancelar o no elegir no ejecuta nada. La confirmación del diálogo es la única.
- `2`: `gh pr view <pr> --web`; con varios `✓`, pregunta cuál.
- Mientras haya `✓` con PR, se consulta su estado cada 15 s; al quedar `MERGED` la línea desaparece sola (se guarda en `$.store`, no toca `.mefisto/pipeline/`). En infra el toast avisa que el issue se cierra al terminar el `apply` de CI (MEF-ADR-0022).
- `/fausto-blood-pact merge [<pr>...]` y `/fausto-blood-pact pr [<pr>]`: lo mismo sin teclas.

Fuera de alcance: mergear PRs que la sesión no vio terminar y resolver comentarios de review.

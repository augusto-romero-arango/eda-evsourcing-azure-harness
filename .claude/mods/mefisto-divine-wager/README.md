# mefisto-divine-wager

Consola de operacion de Mefisto (MEF-ADR-0055): un mod de Claude Code para toda sesion interactiva que no sea la
del planner. Lista los listos y los lanza, sigue `/mefisto-tooling` y `/mefisto-sequential`, y ofrece PRs, bitacora
y release. Solo lee `.mefisto/pipeline/`, `gh` y el repo; sus acciones delegan en los skills internos existentes.
Su par en la sesion del planner es `mefisto-planner-board`.

El nombre viene del *Prolog im Himmel* del *Fausto* de Goethe: la apuesta que Mefisto le hace a Dios de que puede
con Fausto. En este repo se le da a Mefisto lo que necesita para ganarla (MEF-ADR-0055, decision 9).

## Cargarlo

Una sola vez por checkout. Los mods se instalan en alcance `local` (`.claude/settings.local.json`, no
versionado) desde el marketplace de carpeta `.claude/mods/`:

```bash
claude plugin marketplace add ./.claude/mods --scope local
claude plugin install mefisto-divine-wager@mefisto-mods --scope local
claude plugin install mefisto-planner-board@mefisto-mods --scope local
```

Desde ahi cargan solos en toda sesion de este checkout, sin `--plugin-dir`, y se leen de la carpeta: un cambio
se aplica con `/reload-plugins`. Los worktrees de los pipelines no tienen `settings.local.json`, asi que sus
sesiones `-p` no los cargan. Para probar una copia suelta: `claude --plugin-dir .claude/mods/<mod>`.

## Uso

- En reposo, en toda sesion interactiva que no sea la del planner, la banda lista los `estado:listo` en el
  orden de `mefisto-next-order.sh` (se refresca cada minuto y al cerrar una corrida). Con el prompt vacio,
  `1` escribe la linea de `/mefisto-sequential` con todos y `5`-`9` toma un solo issue: el dialogo nativo,
  junto al prompt, pregunta si va con merge (`/mefisto-sequential`) o solo PR (`/mefisto-tooling`). El comando
  queda en el prompt sin Enter para ajustarlo antes de lanzar; `0` pagina. Los bloqueados se ven al final, sin tecla.
  `2` (`PRs N`, los abiertos sin borradores) abre el dialogo nativo para mergear: todos (`--all`) o varios de los
  mas recientes, y otros numeros en la opcion de texto; al aceptar ejecuta `/mefisto-merge` de una vez.
  `3` (`bitácora N`: field notes en `docs/bitacora/field-notes/` mas las de PRs sin mergear) pide integrarlas y le
  encarga a Claude mergear esos PRs, poner `main` al dia y correr `/mefisto-bitacora`. `4` (`release N`: issues con
  fragmentos en `changelog.d/`) ofrece `/mefisto-release` con el bump que sugiere SemVer (`minor` si hay `added`)
  o solo preparar el PR, y lo ejecuta al aceptar. Los PRs de field notes no cuentan en `PRs`.
  `/mefisto-divine-wager refresh` la actualiza a mano.
- `/mefisto-sequential` (`--batch`) corre desacoplado y la banda lo sigue desde
  `pipeline-status-mefisto-batch.json`: avance `N/M`, la cola (`✓` mergeado, `●` en curso, `✗` fallido, `⏸`
  aplazado) y el issue en curso con su mascota, pasos y ultimas lineas. `1` detiene tras el issue en curso
  (confirma en el dialogo nativo junto al prompt; escribe la misma senal que `/mefisto-batch-stop`), `2` abre el PR del issue en curso o del
  ultimo mergeado, `3` el log (acumula todos los issues). Al terminar: resumen (mergeados, fallidos, aplazados,
  espera por rate limit), los PRs de cada issue y `4` cierra. Un toast avisa cada merge.
  `/mefisto-divine-wager batch <issues>` reengancha un sequential ya lanzado.
- Mientras `/mefisto-bitacora` corre al subagente `mefisto-historiador`, la banda de espera muestra al historiador
  escribiendo en su libro (`historiador escribiendo la bitácora MM:SS`) y, al terminar, `bitácora escrita`.
- Mientras corre `/mefisto-release` (lanzado con `4` o escrito a mano), la banda muestra un cohete: en reposo sobre
  su plataforma mientras se prepara, despegando con llama mientras corre `mefisto-release.sh`, y `release terminado`
  al cerrar el turno.
- Si un agente espera por rate limit (la ultima linea de `events.log` es un `[hold]`), la banda de la corrida y la
  del sequential lo dicen: `en espera por RATE_LIMIT · próxima sonda HH:MM · techo HH:MM`.
- Durante la corrida la misma banda muestra la mascota del agente activo (animada), issue, stage, tiempo, los
  pasos y las ultimas lineas del agente; `3` abre el log completo. Al terminar, con el prompt
  vacio: `1` mergea el PR (confirma y encola `/mefisto-merge`), `2` lo abre en GitHub, `3` abre el log y
  `4` cierra la corrida y vuelve a los listos.
- Cuando el PR queda mergeado (desde la banda, `/mefisto-merge` o GitHub), la corrida se cierra sola.
- `/mefisto-divine-wager [issue|batch <issues>|merge|close|refresh]` abre el log enfocado, sigue una corrida o un
  sequential, o ejecuta la accion.
- Dentro del log: `m` mergea, `v` abre el PR, `c` cierra; `ctrl+x tab` lo enfoca y `esc` vuelve al prompt.

## Verificar un cambio

```bash
claude plugin validate .claude/mods/mefisto-divine-wager
claude plugin test .claude/mods/mefisto-divine-wager
```

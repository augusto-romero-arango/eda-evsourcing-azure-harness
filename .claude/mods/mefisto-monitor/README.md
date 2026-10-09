# mefisto-monitor

Mod de Claude Code que sigue `/mefisto-tooling` dentro de la sesion de ejecucion (MEF-ADR-0055).
Solo lee `.mefisto/pipeline/`; sus acciones delegan en `/mefisto-merge` y `gh`.

## Cargarlo

Una sola vez por checkout. Los mods se instalan en alcance `local` (`.claude/settings.local.json`, no
versionado) desde el marketplace de carpeta `.claude/mods/`:

```bash
claude plugin marketplace add ./.claude/mods --scope local
claude plugin install mefisto-monitor@mefisto-mods --scope local
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
  `/mefisto-monitor refresh` la actualiza a mano.
- `/mefisto-sequential` (`--batch`) corre desacoplado y la banda lo sigue desde
  `pipeline-status-mefisto-batch.json`: avance `N/M`, la cola (`✓` mergeado, `●` en curso, `✗` fallido, `⏸`
  aplazado) y el issue en curso con su mascota, pasos y ultimas lineas. `1` detiene tras el issue en curso
  (confirma en el dialogo nativo junto al prompt; escribe la misma senal que `/mefisto-batch-stop`), `2` abre el PR del issue en curso o del
  ultimo mergeado, `3` el log (acumula todos los issues). Al terminar: resumen (mergeados, fallidos, aplazados,
  espera por rate limit), los PRs de cada issue y `4` cierra. Un toast avisa cada merge.
  `/mefisto-monitor batch <issues>` reengancha un sequential ya lanzado.
- Mientras `/mefisto-bitacora` corre al subagente `mefisto-historiador`, la banda de espera muestra al historiador
  escribiendo en su libro (`historiador escribiendo la bitácora MM:SS`) y, al terminar, `bitácora escrita`.
- Mientras corre `/mefisto-release` (lanzado con `4` o escrito a mano), la banda muestra un cohete: en reposo sobre
  su plataforma mientras se prepara, despegando con llama mientras corre `mefisto-release.sh`, y `release terminado`
  al cerrar el turno.
- Si un agente espera por rate limit (la ultima linea de `events.log` es un `[hold]`), la banda de la corrida y la
  del sequential lo dicen: `en espera por RATE_LIMIT · próxima sonda HH:MM · techo HH:MM`.
- Durante la corrida la misma banda muestra la mascota del agente activo (animada), issue, stage, tiempo, los
  pasos y las ultimas lineas del agente; `3` abre el monitor con el log completo. Al terminar, con el prompt
  vacio: `1` mergea el PR (confirma y encola `/mefisto-merge`), `2` lo abre en GitHub, `3` abre el monitor y
  `4` lo cierra y vuelve a los listos.
- Cuando el PR queda mergeado (desde la banda, `/mefisto-merge` o GitHub), el monitor se cierra solo.
- `/mefisto-monitor [issue|merge|close]` abre el monitor enfocado, sigue un issue o ejecuta la accion.
- Dentro del monitor: `m` mergea, `v` abre el PR, `c` cierra; `ctrl+x tab` lo enfoca y `esc` vuelve al prompt.

## Verificar un cambio

```bash
claude plugin validate .claude/mods/mefisto-monitor
claude plugin test .claude/mods/mefisto-monitor
```

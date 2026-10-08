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

- La banda sobre el prompt muestra issue, stage y tiempo. Al terminar, con el prompt vacio:
  `1` mergea el PR (confirma y encola `/mefisto-merge`), `2` lo abre en GitHub, `3` abre el monitor y `4` lo cierra.
- Cuando el PR queda mergeado (desde la banda, `/mefisto-merge` o GitHub), el monitor se cierra solo.
- `/mefisto-monitor [issue|merge|close]` abre el monitor enfocado, sigue un issue o ejecuta la accion.
- Dentro del monitor: `m` mergea, `v` abre el PR, `c` cierra; `ctrl+x tab` lo enfoca y `esc` vuelve al prompt.

## Verificar un cambio

```bash
claude plugin validate .claude/mods/mefisto-monitor
claude plugin test .claude/mods/mefisto-monitor
```

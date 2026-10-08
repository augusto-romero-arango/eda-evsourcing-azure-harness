# mefisto-monitor

Mod de Claude Code que sigue `/mefisto-tooling` dentro de la sesion de ejecucion (MEF-ADR-0055).
Solo lee `.mefisto/pipeline/`; sus acciones delegan en `/mefisto-merge` y `gh`.

## Cargarlo

```bash
claude --plugin-dir .claude/mods/mefisto-monitor
```

Con el mod cargado, `/mefisto-tooling <n>` corre sin pane externo (`MEFISTO_UI=mod`).

## Uso

- La banda sobre el prompt muestra issue, stage y tiempo. Al terminar, con el prompt vacio:
  `1` mergea el PR (confirma y encola `/mefisto-merge`), `2` lo abre en GitHub, `3` abre el monitor y `4` lo cierra.
- `/mefisto-monitor [issue|merge|close]` abre el monitor enfocado, sigue un issue o ejecuta la accion.
- Dentro del monitor: `m` mergea, `v` abre el PR, `c` cierra; `ctrl+x tab` lo enfoca y `esc` vuelve al prompt.

## Verificar un cambio

```bash
claude plugin validate .claude/mods/mefisto-monitor
claude plugin test .claude/mods/mefisto-monitor
```

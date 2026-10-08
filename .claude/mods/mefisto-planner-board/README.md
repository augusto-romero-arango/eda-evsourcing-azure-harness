# mefisto-planner-board

Mod de Claude Code para la sesion del planner (MEF-ADR-0055): una banda sobre el prompt que dice que se esta
haciendo (refinar #N o explorar un tema) y da acceso a los borradores y listos en el orden de
`mefisto-next-order.sh`.

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

Solo se activa en una sesion interactiva cuyo proceso es `claude --agent mefisto-planner` (lo lee de la linea
de comando del proceso, o del transcript como respaldo). Un planner lanzado como subagente o con `-p` no lo ve.
En otra sesion, `/mefisto-board on` lo enciende a mano.

## Estados

- **refinar #N**: empieza con un mensaje que dice `refina #N`; termina cuando #N pasa a `estado:listo` o con
  el cierre del planner (`mefisto-field-note.sh`).
- **explorar**: cualquier otro mensaje desde reposo; el tema es su primera linea. Termina con el cierre.
- Los `gh issue create` de ambos se anotan como `creó #…`.

## Teclas (prompt vacio)

| Tecla | Accion |
|---|---|
| `1` / `2` | En reposo: `Quiero explorar: ` / `Refina el borrador #N` en el prompt |
| `3` / `4` | Abre o cierra la lista de borradores / listos |
| `5`-`9` | Borradores: `Refina el borrador #N` en el prompt |
| `5`-`8`, `9` | Listos: `/mefisto-tooling N` o el `/mefisto-sequential` del batch, escrito sin Enter en el pane `ejecucion` de herdr (portapapeles fuera de herdr) |
| `0` | Siguiente pagina |

`/mefisto-board [refresh|borradores|listos|batch|cerrar|on|off]` cubre lo mismo sin teclas.

## Verificar un cambio

```bash
claude plugin validate .claude/mods/mefisto-planner-board
claude plugin test .claude/mods/mefisto-planner-board
```

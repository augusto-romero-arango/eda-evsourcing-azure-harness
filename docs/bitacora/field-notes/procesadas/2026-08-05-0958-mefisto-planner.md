---
fecha: 2026-08-05
hora: 09:58
sesion: mefisto-planner
tema: Skill de actualizacion del plugin en el consumidor (/mefisto:upgrade)
---

## Contexto
El usuario reporto que actualizar Mefisto en un consumidor es engorroso y propenso a errores: UI de /plugin -> actualizar, editar a mano `.claude/pipeline/.plugin-root`, limpiar el cache de versiones viejas y ejecutar /reload-plugins. Pidio la mejor propuesta para automatizarlo.

## Descubrimientos
- El CLI de Claude Code ya tiene primitivas no-interactivas verificadas localmente: `claude plugin update <plugin> --scope user` (su help declara "restart required to apply") y `claude plugin marketplace update <name>`. La UI de /plugin es innecesaria para actualizar.
- El cache real del usuario acumulaba 5 versiones viejas de mefisto (0.10.0 ... 0.19.0) bajo `~/.claude/plugins/cache/augusto-romero-arango-harness/mefisto/`.
- El hook SessionStart ya reescribe `.plugin-root`, pero solo en el arranque de sesion; nadie lo actualiza dentro de la sesion activa tras un update.
- Convencion de invocacion: los comandos del plugin se namespacian como `/mefisto:<comando>`; el archivo en `commands/` va sin prefijo (correccion aportada por el usuario durante la sesion).

## Decisiones
- Crear skill publicado `commands/upgrade.md` + `scripts/update-plugin.sh` (issue #531, estado:listo).
- La poda del cache conserva exactamente {version nueva, version cargada en la sesion actual} y pide confirmacion: nunca borrar la version cargada (el skill viejo no debe borrarse a si mismo).
- El script detecta el marketplace por glob del cache, sin hardcodear el nombre, para soportar forks via `repoSlug`.
- Reescribir `.plugin-root` dentro del skill para que pipelines headless previos al reload ya resuelvan la version nueva.
- El paso final (reload/restart) queda manual: no es automatizable desde dentro de la sesion segun el propio CLI.

## Descartado
- Podar el cache desde el hook SessionStart: un hook corre en cada sesion (incluidas las headless de pipelines en tmux) y podria borrar la version que un batch en curso tiene cargada.

## Preguntas abiertas
- Ninguna.

## Referencias
Issues creados: #531 (Crear skill publicado /mefisto:upgrade para actualizar el plugin desde el consumidor)

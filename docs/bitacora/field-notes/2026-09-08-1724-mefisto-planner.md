---
fecha: 2026-09-08
hora: 17:24
sesion: mefisto-planner
tema: Refinamiento del comando tooling publicado
---

## Contexto

Tras dejar listos #1054 y #1060 se continuo con #1061, la migracion del unico slash command incluido en el primer corte vertical publicado de MEF-ADR-0053.

## Descubrimientos

- `commands/tooling.md` conserva frontmatter, rutas de estado/cache y ejemplos de modelos propios de Claude, aunque el contrato neutral y ambos adaptadores ya existen.
- El wrapper `tmux-pipeline.sh` es la fuente real del parseo de `--models`/`--variant` y ya delega en Herdr cuando corresponde; el comando solo necesita validar contexto y reenviar `$ARGUMENTS`.
- El comando valida issue abierto, `tipo:tooling` y `bloqueado`; `tooling-pipeline.sh` no replica esas tres decisiones antes de crear el worktree.
- #1049/#1050 no son dependencias directas: el comando no carga configuracion ni estado. #1060 tampoco lo es: writer/reviewer son invocados por el pipeline, no por el slash command.
- Claude sigue cargando `commands/tooling.md` desde la raiz del plugin porque el marketplace aun no apunta a `dist/claude`. Retargetearlo exige una distribucion Claude autocontenida, no solo el Markdown del comando.
- `/work-status` todavia no forma parte del corte OpenCode; mantener esa recomendacion en el nuevo body prometeria un comando no migrado.

## Decisiones

- `src/published/commands/tooling.md` queda como unica fuente editable, con `id: tooling`, perfil `fast`, argumentos declarados y guard de consumidor.
- El body usa `{{mefisto:run tmux-pipeline.sh --tooling $ARGUMENTS}}`; no vuelve a resolver raiz, config o estado.
- El nombre documentado es `/mefisto:tooling` en ambos runtimes; no se inventa un alias `/tooling` que el generador no controle.
- `commands/tooling.md` permanece como mirror byte a byte de la salida Claude generada, con marcador y test de deriva, mientras el marketplace cargue la raiz.
- Las dependencias se leen solo de `## Dependencias` mediante `Depende de #N`/`Bloqueado por #N`; una referencia no consultable se trata como bloqueo visible.
- #1061 pasa a `estado:listo` y conserva `bloqueado` exclusivamente por #1054.

## Descartado

- Retargetear `.claude-plugin/marketplace.json` en #1061: obligaria a empaquetar scripts, hooks, Skills y metadata Claude en el mismo cambio.
- Conservar dos cuerpos editables para Claude y OpenCode.
- Referenciar `/work-status` antes de migrarlo o ampliar el corte vertical a otro comando.
- Duplicar en el prompt la gramatica shell que ya valida `tmux-pipeline.sh`.
- Declarar #1049, #1050 o #1060 como dependencias sin un uso directo desde el comando.

## Preguntas abiertas

- Hace falta una tarea posterior para convertir `dist/claude` en una distribucion completa y retargetear el marketplace; #1061 solo mantiene el mirror transitorio.
- #1054 debe cerrar antes de lanzar #1061, porque la directiva `run` necesita una raiz activa validada.

## Referencias

Issues creados: ninguno

Issue refinado: #1061

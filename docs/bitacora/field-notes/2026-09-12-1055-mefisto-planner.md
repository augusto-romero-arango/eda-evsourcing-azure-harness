---
fecha: 2026-09-12
hora: 10:55
sesion: mefisto-planner
tema: Fallo post-agente del scaffold publicado en v0.37.9
---

## Contexto
La regeneracion de `/scaffold certificacion` con Mefisto `v0.37.9` completo `domain-scaffolder`, produjo el dominio y dejo 25 tests verdes, pero el runner aborto despues en el commit defensivo.

## Descubrimientos
- El hook Claude generado por `src/published/scripts/generate-claude-hooks.sh` compone `.mefisto/pipeline/` relativo al cwd del hook. Al ejecutar Terraform desde `infra/environments/dev`, escribio `infra/environments/dev/.mefisto/pipeline/events.log` en vez del estado canonico de la raiz.
- El adaptador OpenCode ya recibe una raiz absoluta del contexto y compone `pipeline(root)`; no comparte este defecto concreto.
- El patron raiz `.mefisto/pipeline/` de `.gitignore` no cubre la copia anidada porque contiene un slash intermedio y queda anclado a la raiz.
- `scripts/scaffold-pipeline.sh` usa `git add -A -- . ':!.claude/pipeline'`. Cuando existe el marker ignorado `.claude/pipeline/.plugin-root`, Git devuelve exit 1 aunque el pathspec sea negativo.
- La prueba agregada por #1229 no crea el marker que un hook real deja en el worktree, por lo que su camino sano no reproduce el fallo de campo.
- El trabajo del consumidor permanece en la rama/worktree `scaffold-certificacion`, commit `ed31d58`; el unico sobrante reportado es el `events.log` anidado.

## Decisiones
- No limpiar el archivo, pushear ni abrir el PR manualmente: esa recuperacion ocultaria defectos de la release certificada y violaria el regimen fail-closed de MEF-ADR-0053.
- Separar por componente: #1236 corrige el adaptador de hooks Claude; #1237 corrige el pipeline de scaffold.
- #1237 depende de #1236: arreglar solo el pathspec podria stagear el estado canonico anidado en lugar de abortar.
- Mantener los cambios acotados al lado publicado; no hay evidencia de que el adaptador OpenCode necesite la misma correccion.

## Descartado
- Cambiar solo `.gitignore` a un patron recursivo: esconderia el destino incorrecto del hook sin restaurar la unicidad del estado canonico.
- Reemplazar el `|| abort` del commit defensivo por `|| true`: convertiria un fallo real de staging en perdida silenciosa.
- Recuperar el PR consumidor a mano a partir de `ed31d58`.

## Preguntas abiertas
- Tras publicar ambos fixes, decidir si el worktree fallido se elimina y el scaffold se ejecuta desde cero o si el pipeline incorpora en el futuro una reanudacion formal post-agente; hoy no debe improvisarse.
- Revisar por separado si el mismo antipatrón de pathspec negativo sobre un directorio ignorado existe en otros pipelines publicados; no se amplio #1237 sin evidencia ejecutada.

## Referencias
Issues creados: #1236, #1237

---
fecha: 2026-10-08
hora: 17:43
sesion: mefisto-planner
tema: Refinar #2079 y #2082 (tablero del planner publicado)
---

## Contexto
Refinamiento de dos borradores de la cadena que porta el tablero del planner al consumidor (#2079-#2083).

## Descubrimientos
- `scripts/next-order.sh` publicado ya difiere de la copia interna en `--launch-command` y en el `[tipo:X]` por linea; el port de `--json`/`--refinement` debe conservarlos.
- El `SessionStart` publicado ya escribe `.mefisto/pipeline/.plugin-root`: el mod puede ubicar `next-order.sh` desde ese contrato existente.

## Decisiones
- #2079 -> `estado:listo`: los items del `--json` publicado llevan `tipo` (valor sin prefijo, o null); el modo refinar del planner publicado adopta `--refinement` en el mismo issue (dos componentes, por decision del usuario).
- Convencion de tipo en el tablero: una letra en color antes del numero (`F` feature, `R` refactor, `P` projection, `T` tooling, `I` infra, `?` sin tipo), dos columnas. Anotada como CA en #2082.
- #2082 -> `estado:listo` (sigue `bloqueado`): copia hermana deliberada del mod interno (MEF-ADR-0018), no fuente unica compartida.

## Descartado
- Colorear solo el numero del issue (sin leyenda no se lee).
- Fuente unica del mod en el lado publicado importada por el interno (acoplaria el ciclo rapido del mod interno a la release).
- Borrador aparte para que el planner publicado adopte `--refinement`.

## Preguntas abiertas
- Si `.claude-plugin/plugin.json` publicado se genera (declaracion de tipos del mod) y si el comando `mefisto-board` recibe namespace en un plugin de marketplace (#2082).
- Faltan por refinar #2080, #2081 y #2083.

## Referencias
Issues refinados: #2079, #2082.

---
fecha: 2026-10-09
hora: 20:32
sesion: mefisto-planner
tema: lanzamiento sequential/parallel/infra en next-order y paridad de experiencia de los mods
---

## Contexto
Continuacion de la sesion de las 20:02 (PR #2188): refinar #2187 (lanzar desde listos), que destapo que sequential y parallel saltan infra, y la falta de mascota en `fausto-blood-pact` al probarla en el consumidor.

## Descubrimientos
- `batch-pipeline.sh` y `parallel-pipeline.sh` saltan `tipo:infra` y los sin tipo, pero `next-order.sh` los incluia en `launch`: la linea prometia issues que no corren.
- `commands/next-order.md` es salida generada de `src/published/commands/next-order.md`; su test exige el texto del modo `oleadas`.
- `$.ui.ask` acepta 2-4 opciones, rechaza al cerrarse y devuelve el texto libre de "Other".
- La consola interna anima la espera con `waitingFace` (mirada de lado a lado + reloj de arena) y elige la pose de la corrida por el ultimo evento de `events.jsonl`; el lado publicado ya tiene el Mefisto rojo en `hooks/sprites.ts`.

## Decisiones
- Lote parallel: unico criterio las dependencias declaradas (ninguna abierta, ni intra-lote), sin infra ni sin tipo, a lo sumo una projection. Se calcula en `next-order.sh` como funcion propia (#2190), no en un script aparte (evita una tercera copia del parser).
- `launch` excluye infra; los infra se ofrecen antes, sin exigirlos.
- #2187 rehecho: `1` sequential, `2` parallel, dialogo de infra previo; `5`-`9` por tipo (infra solo PR).
- Directiva del usuario: los mods internos y publicados no comparten codigo pero ofrecen experiencia consistente; Mefisto rojo en el consumidor, blanco perla/dorado en lo interno (#2192).
- #2183, #2187 y #2190 en `estado:listo`.

## Descartado
- Script `parallel-order.sh` separado, con o sin parser compartido.
- Criterio de parallel por conflictos de archivos (matriz de oleadas).

## Preguntas abiertas
- Alinear el modo `oleadas` del planner publicado (matriz por archivo) con el criterio de solo dependencias.
- Auditar la consola publicada contra `divine-wager` para detectar otras brechas de experiencia tras #2187.

## Referencias
Issues: #2183 (cerrado), #2187 (listo, bloqueado por #2190), #2190 (listo), #2192 (borrador, ADR paridad), #2193 (borrador, mascota, bloqueado por #2192)

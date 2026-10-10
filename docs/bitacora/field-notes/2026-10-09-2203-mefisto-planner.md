---
fecha: 2026-10-09
hora: 22:03
sesion: mefisto-planner
tema: transiciones de la banda del planner (refinar y explorar) en ambos tableros
---

## Contexto
Continuacion de la sesion de las 21:43 (PR #2211): refinar #2208 y #2210, y dos problemas de experiencia de los tableros del planner observados en esta misma sesion.

## Descubrimientos
- Tras pasar un issue a listo, la lista vieja sigue en pantalla mientras corre el refresco (gh + dos next-order) y hasta el refresco forzado de `SETTLE_MS` (15 s): las teclas por indice apuntan a ella. Misma estructura en `mefisto-planner-board` y `fausto-board`.
- Con foco `explorar` la lista de borradores no es accesible (`toggleList` sale si hay foco) y el foco solo cierra con la field note.
- Un digito en el composer vacio solo pulsa un boton de banda armado; el fallo del "1" fue intermitente y justo tras un mensaje con imagen pegada. Los "6" eran esperados (lista cerrada en reposo).
- La consola publicada lee `.claude/pipeline/` en tres lectores (corridas, eventos, historial).

## Decisiones
- #2208 listo: corridas solo con alguna activa, resultados al pie, sin ruta legada, la accion se llama "ocultar".
- #2210 listo: instrumentar, reproducir y agregar `/mefisto-planner-board cerrar-sesion`.
- Quitar al instante el issue refinado (optimista + filtro de respuestas atrasadas + `actualizando…`), en ambos tableros (#2214, #2215).
- Al crear borradores en una exploracion, navegar sola a la lista de borradores existente, sin elementos nuevos (#2217, #2218).

## Descartado
- "Cargando" con la banda vacia 15-20 s tras refinar.
- Tecla para volver o cerrar la exploracion; marcas para los borradores creados.

## Preguntas abiertas
- Causa real del "1" que llego como texto (#2210, requiere reproduccion interactiva).

## Referencias
Issues: #2208, #2210 (listos); #2214, #2215, #2217, #2218 (borradores)

---
fecha: 2026-10-09
hora: 19:30
sesion: mefisto-planner
tema: /clear apaga el tablero del planner (mefisto-planner-board)
---

## Contexto
El usuario observo que `/clear` apaga el mod `mefisto-planner-board` dentro de una sesion `claude --agent mefisto-planner`. Modo analizar.

## Descubrimientos
- `/clear` no dispara `session.start` (doc del runtime de mods: "never `/clear`"); dispara `session.end` con `reason: 'clear'` y el proceso sigue con otro session id.
- `$.state` (los atoms) vive "por sesion": tras `/clear` `isActive`/`isPlannerSession` vuelven a su valor inicial (hipotesis coherente con el sintoma).
- El transcript nuevo tras `/clear` no tiene filas `agent-setting` (verificado: 6 en la sesion previa, 0 en la posterior), asi que el fallback de deteccion falla.
- La deteccion por `ps $PPID` no reconoce el planner desde el modulo (inferido; probable que el padre del `sh` sea el proceso del modulo y no `claude --agent ...`).

## Decisiones
- Arreglo propuesto: recordar el planner a nivel de proceso (variable del modulo) y reactivar en `prompt.submit`; respetar el apagado manual; cancelar el timer en `session.end` con `clear`.
- A pedido explicito del usuario se creo issue pese a la regla de mods sin issue.

## Descartado
- Revisar `mefisto-divine-wager` en este issue: usa el mismo `ps $PPID`, queda como nota.

## Preguntas abiertas
- Que devuelve realmente `ps -o args= -p "$PPID"` desde el modulo.
- Si `mefisto-divine-wager` tambien se apaga tras `/clear`.

## Referencias
Issues creados: #2176 (Mantener activo el tablero del planner tras /clear, estado:borrador)

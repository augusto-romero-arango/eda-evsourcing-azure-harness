---
fecha: 2026-10-09
hora: 20:02
sesion: mefisto-planner
tema: refinar #2183 y definir el incremento 3 de fausto-blood-pact
---

## Contexto
Continuacion de la sesion de las 19:55 (PR #2184): refinar el incremento 2 (seguir corridas) y definir el 3.

## Descubrimientos
- Los tres pipelines publicados escriben `stage = "<n>-<agente>"` con `state: running`: el agente en curso se deduce sin ampliar el contrato.
- Al fallar, el status no se borra (queda `failed`/`blocked`/`gaps`); solo se borra al terminar bien. `iac-pipeline.sh` cierra con stage `completed`, no `done`.
- `$.store` es del plugin y compartido entre repos (config del usuario): toda clave debe incluir el repo.
- El esqueleto mergeado (#2180) compone ambos modulos en `hooks/index.tsx` (un modulo por plugin) y usa claves `pact*`.
- Ruteo por tipo en el consumidor: implement = feature/refactor/projection, tooling, infra; `/mefisto:sequential` rutea solo.

## Decisiones
- #2183 refinado y en `estado:listo`: descartar un resultado es persistente en `$.store`.
- Incremento 3 = lanzar desde listos (#2187): `1` escribe la linea de `/mefisto:sequential` con todos; `5`-`9` pregunta con merge (`/mefisto:sequential <n>`) o solo PR (skill del tipo); nunca envia.

## Descartado
- Descarte por sesion o solo fallos recientes.
- Incremento 3 como merge desde la corrida, log en vivo o issues del reviewer (quedan para despues).
- Escribir siempre el skill del tipo o siempre sequential sin preguntar.

## Preguntas abiertas
- Orden de los incrementos restantes: merge desde la corrida, log en vivo, issues del reviewer, `/mefisto:parallel`.

## Referencias
Issues: #2183 (listo), #2187 (borrador, bloqueado por #2183). #2179 y #2180 ya cerrados.

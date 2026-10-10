---
fecha: 2026-10-09
hora: 19:55
sesion: mefisto-planner
tema: refinar #2179/#2180 y definir el incremento 2 de fausto-blood-pact
---

## Contexto
Continuacion de la sesion de las 19:42 (PR #2181): refinar la enmienda de MEF-ADR-0055 y el esqueleto de la consola publicada, y definir su segundo incremento.

## Descubrimientos
- Los dos modulos publicados (`fausto-board` y `fausto-blood-pact`) comparten el namespace de estado `PluginState['mefisto']`: las claves de atoms de la consola deben ser propias o colisionan con `isActive` del tablero.
- `next-order.sh --json` ya entrega `tipo` por item y `launch` para la linea de lanzamiento.
- Los tres pipelines publicados (tdd, tooling, infra) escriben el mismo status (`stage`, `state`, `agents`, `pr`, `last_error`, `hold`) en `.mefisto/pipeline/` del checkout principal, lo borran al terminar bien y dejan el cierre en `pipeline-history.jsonl`.

## Decisiones
- #2179 y #2180 refinados y en `estado:listo`.
- El catalogo de capacidades de `fausto-blood-pact` vive en `hooks/fausto-blood-pact/README.md`; el ADR solo fija marco y reglas, sin enmendarse por incremento.
- Incremento 2 = seguir corridas (#2183): cada pane ve todas las corridas del repo, y las corridas reemplazan a los listos en la banda mientras haya activas o resultados sin descartar.

## Descartado
- Incremento 2 como "lanzar desde listos" o "PRs y merge" (quedan para despues).
- Seguir solo las corridas lanzadas por la propia sesion (modelo de divine-wager).
- Banda partida o con pestanas.

## Preguntas abiertas
- Si el status permite deducir el agente en curso; si no, issue aparte para exponerlo.
- Orden de los incrementos siguientes (log en vivo, merge, lanzar, issues del reviewer).

## Referencias
Issues: #2179 (listo), #2180 (listo, bloqueado), #2183 (borrador, bloqueado por #2180)

---
fecha: 2026-10-09
hora: 19:42
sesion: mefisto-planner
tema: refinar #2176 y arrancar fausto-blood-pact por incrementos
---

## Contexto
Continuacion de la sesion de las 19:30 (field note en PR #2177): se refino #2176 y se empezo a dar forma a la consola publicada `fausto-blood-pact`.

## Descubrimientos
- Corrige la field note de las 19:30: la deteccion del planner por `ps $PPID` si funciona. Tras `/clear` el tablero vuelve al enviar el primer mensaje; el defecto es el intervalo entre `/clear` y ese mensaje.
- `/mefisto-planner-board off` no se mantiene: el siguiente `prompt.submit` lo reenciende via `detectPlanner` -> `claimPlanner` -> `activate`.
- `generate-claude-hooks.sh` fija `modules: ["./register.tsx"]` y su validacion exige ese valor: un segundo modulo publicado requiere tocar el generador.
- `hooks/*` en ambos gates de scope cubre subcarpetas (glob de `case`): `hooks/fausto-blood-pact/` no necesita PR de registro.

## Decisiones
- #2176 refinado (reaparecer tras `/clear` sin mensaje, `off` persistente) y pasado a `estado:listo`.
- `fausto-blood-pact` se construye por incrementos, uno por issue, verificado en un consumidor antes del siguiente.
- Incremento 1: esqueleto + listos de `next-order.sh` en solo lectura, en `hooks/fausto-blood-pact/`.
- Sin `cierre:manual`: cada incremento se cierra al mergear para publicarlo y probarlo en el consumidor; lo que falle se itera con issues nuevos.

## Descartado
- Portar de golpe todas las capacidades de `mefisto-divine-wager`.
- Arrancar por seguir corridas o por un esqueleto vacio.

## Preguntas abiertas
- Orden de los incrementos siguientes (lanzar listos, seguir `/tooling`, merge, `/sequential`, `/implement`, `/infra`, issues del reviewer).

## Referencias
Issues: #2176 (refinado, estado:listo), #2179 (enmienda MEF-ADR-0055, borrador), #2180 (esqueleto fausto-blood-pact, borrador, bloqueado por #2179)

---
fecha: 2026-10-09
hora: 09:19
sesion: mefisto-planner
tema: Checkout compartido, confirmacion antes de listo y diferencial del tablero publicado
---

## Contexto
Refinamiento de #2105, #2108-#2112 y diferencial entre el tablero del planner interno y el publicado.

## Descubrimientos
- El push a `main` del 2026-10-08 (`1090d893`) no vino de un skill: el boton de bitacora del mod `mefisto-monitor` (`logic.ts:582`) hace `git switch main` en el checkout compartido, porque `mefisto-historiador` crea su rama ahi. Otra sesion de trabajo directo commiteo y empujo creyendose en su rama.
- Claude Code 2.1.295 trae `claude -w/--worktree`; `herdr worktree` existe; OpenCode no mostro equivalente.
- Ningun flujo del harness empuja a `main`; la politica bash de OpenCode solo ve patrones de comando, no la rama activa.
- El planner pasaba issues a `estado:listo` en el mismo turno de la ultima respuesta, sin mostrar la redaccion (#2079-#2083, #2105, #2108).
- El tablero publicado (#2098) no tiene los arreglos de #2113 (comandos en posicion de ejecucion, cierre combinado).

## Decisiones
- #2105: la bitacora interna trabaja en un worktree aislado (`mefisto-bitacora-worktree.sh prepare|deliver`); el historiador solo edita.
- #2108: cada sesion de trabajo directo trabaja en su propio worktree (`mefisto-worktree.sh new|clean`); regla condicional en AGENTS.md (si estas en el checkout principal, crea worktree; `claude -w` como atajo).
- #2110: hook git `pre-push` neutral que desvia a `rescate/...` + PR los push a `main`, falla cerrada, activacion automatica de `core.hooksPath` sin pisar valores ajenos; via de escape `git push --no-verify`. #2112: remediacion diferida del `main` local con `git reset --keep` solo sobre SHAs rescatados.
- #2109/#2111: `explorar` y `desglosar` crean siempre borrador; `refinar` guarda el cuerpo, muestra resumen y espera confirmacion; los issues creados en un refinamiento pasan a listo juntos con una sola confirmacion.
- #2115 (borrador): portar al tablero publicado los arreglos de #2113.
- La mascota roja del consumidor y la blanco perla del interno son una diferencia intencional.

## Descartado
- Guard en `_mefisto-common.sh` (no cubre sesiones directas); hooks del runtime con paridad Claude/OpenCode; falla abierta del pre-push; remediacion inmediata del `main` dentro del hook.

## Preguntas abiertas
- Si OpenCode permite editar bajo `.mefisto/worktrees/**` desde una sesion lanzada en el checkout principal (#2108).

## Referencias
Refinados a listo: #2105, #2108, #2109, #2110, #2111, #2112. Creados: #2108, #2110, #2111, #2112, #2115 (borrador).

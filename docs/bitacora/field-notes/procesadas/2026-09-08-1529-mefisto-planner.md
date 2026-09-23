---
fecha: 2026-09-08
hora: 15:29
sesion: mefisto-planner
tema: Refinamiento de la resiliencia del sequential interno
---

## Contexto

Se refino el draft #1107 a partir del fallo de #1075 dentro del batch `1046 1075 1052 1053`. La intencion del mantenedor es que el sequential se recupere de condiciones que hoy requieren relanzar manualmente un stage.

## Descubrimientos

- El fallo de #1075 no fue una indisponibilidad de Claude Code, OpenCode ni del proveedor. El batch corria con OpenCode, pero la causa es neutral al runtime.
- #1046 movio el runner neutral canonico de `src/internal/scripts/mefisto-run-agent.sh` a `src/runtime/mefisto-run-agent.sh` y confirmo ese cambio en `origin/main` como `d083bb1`.
- El worktree de #1075 nacio correctamente de `d083bb1`, pero el batch siguio resolviendo `mefisto-tooling-pipeline.sh` y sus dependencias desde el checkout principal, que otra sesion habia cambiado a `docs/field-notes-refinar-1059`.
- El writer uso la maquinaria vieja mientras aun estaba presente; durante sus 381 s otra operacion cambio el arbol visible y el reviewer encontro retirada la ruta vieja. El relanzamiento `--from-stage 2` funciono porque ya tomo el arbol actualizado.
- #566 desacoplo correctamente la garantia de la cadena de la rama activa: `origin/main` es la base real y `main` local puede actualizarse por nombre. Quedo un hueco distinto: el codigo ejecutable de cada eslabon todavia depende del filesystem mutable de esa rama activa.
- La conducta de cierre de esta conversacion no prueba un defecto residual de #1096: las instrucciones activas coinciden con el primer padre de `e2a19d5`, antes de que PR #1103 agregara la custodia y entrega aislada. El archivo vigente en `src/internal/agents/mefisto-planner.md` y ambos adaptadores generados si contienen el contrato nuevo.
- Actualizar `main` durante una conversacion no reemplaza el prompt que el runtime ya cargo. El precedente publicado documenta el mismo limite para una actualizacion del plugin: se necesita recargar o reiniciar la sesion (`README.md`, seccion "Actualizar a una version nueva", y `commands/upgrade.md`).

## Decisiones

- #1107 se renombro a "Aislar los eslabones secuenciales del checkout principal" y se marco `estado:listo`, `tipo:tooling` y `bug`.
- La solucion se delimito a que el batch materialice una raiz de ejecucion propia por revision: inmutable durante un eslabon y actualizada al `origin/main` verificado antes del siguiente.
- No se ampliara `CLI_ERROR` como familia reintentable. MEF-ADR-0051 conserva su taxonomia; la carrera se elimina antes de que pueda degradarse a un fallo de agente sin evento neutral.
- El estado, mapping local de modelos, logs y senal de parada deben seguir perteneciendo al checkout desde el que se lanzo el batch, aunque el codigo ejecutable provenga de la raiz aislada.
- No se abrira otro issue contra #1096: el incumplimiento observado provino de una sesion con la definicion anterior ya cargada, no de divergencia entre la fuente neutral y los adaptadores actuales.

## Descartado

- Reintentar a ciegas cualquier `CLI_ERROR`: no distingue una carrera recuperable de configuraciones permanentes y contradice la politica vigente de MEF-ADR-0051.
- Inferir que `MEFISTO_RUN_AGENT_BIN` introdujo la ruta obsoleta: los logs completos demuestran que el checkout principal expuso codigo de otra revision.
- Hacer fallback entre runners segun runtime: `src/runtime/mefisto-run-agent.sh` es neutral y los adaptadores, no el batch, seleccionan Claude Code, OpenCode o un runtime futuro.
- Reabrir #1096 o crear un bug duplicado sin reproducirlo en una sesion nueva: el prompt activo de esta conversacion es evidencia directa de staleness de sesion.

## Preguntas abiertas

- La implementacion elegira la forma concreta y segura de la raiz aislada reutilizando `git worktree`, con cleanup para exito, error, `--stop-on-error` y parada suave.
- Falta una comprobacion de campo en una sesion nueva de `mefisto-planner` para confirmar el cierre automatico de #1096 de extremo a extremo.

## Referencias

Issues refinados: #1107. Issues revisados: #1096. PRs revisados: #1103.

Evidencia: `.mefisto/pipeline/logs/mefisto-batch-20260908-142729.log`, `mefisto-tooling-stage-2-reviewer-20260908-144302-issue-1075.runner.log`, `mefisto-tooling-pipeline-20260908-151128.log` y `pipeline-history.jsonl`.

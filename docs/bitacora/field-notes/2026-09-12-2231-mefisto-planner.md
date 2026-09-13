---
fecha: 2026-09-12
hora: 22:31
sesion: mefisto-planner
tema: El cierre documental del planner no se ejecuta porque es prosa, no codigo
---

## Contexto

El usuario reporto que los planners (`mefisto-planner` interno y `planner` publicado)
crean la rama documental en el checkout principal y lo dejan parado ahi: le toca pedir
a mano "abre el PR y vuelve a main" en cada sesion, y la instruccion se pierde al
compactar el contexto. Sospechaba que la instruccion del cierre se habia perdido del
prompt o que nunca habia existido.

## Descubrimientos

- **La instruccion existe y esta sincronizada.** Vive en `src/internal/agents/mefisto-planner.md`
  (lineas 288-480, PR #1103) y en `agents/planner.md` (lineas 1099-1216, PR #1101).
  `generate-internal-adapters.sh --check` sale 0, asi que Claude y OpenCode cargan la
  version con el cierre. No se perdio nada.
- **Y funciono durante dias.** Hay ~25 PRs de field notes del planner interno entre el
  2026-09-09 y el 2026-09-12 (#1110, #1114, #1116, #1118, #1122, #1130, #1146, #1148,
  #1150, #1157, #1162, #1182, #1183, #1184, #1189, #1199, #1205, #1209, #1214, #1231, #1238).
- **Causa raiz: el cierre es prosa, y compite con una instruccion rival mas fuerte.**
  `AGENTS.md` seccion "Flujo de entrega" dice *"si la rama activa es main, crear una nueva
  con git switch -c"*. Es corta, memorable y se recarga en cada turno. Las 120 lineas del
  cierre estan sepultadas al final del prompt. Al compactarse sobrevive la directiva de
  proyecto y se pierde la intencion del cierre; el modelo cae al default de AGENTS.md.
- **No existe ningun script de field notes** en el repo (`.claude/scripts/` ni `scripts/`).
  Toda la mecanica -- worktree, idempotencia, checkpoints, recuperacion por fallo -- vive
  como texto en dos prompts.
- **Evidencia de la desviacion**: las tres field notes mas nuevas (incluida
  `2026-09-12-2147-mefisto-planner.md`) entraron como commits directos en la rama
  `docs/field-notes-certificacion-1180`, con titulos a mano, no con el template
  `docs(bitacora): agregar field note de mefisto-planner` ni por PR aislado.
- **El cierre no vuelve a main, por diseno**, y eso genera una expectativa desalineada:
  restaura la rama/commit iniciales (no-op). Si arrancas en una rama de trabajo, terminas
  ahi. El usuario esperaba quedar en `main`.
- `.claude/scripts/*` y `scripts/*` ya estan registrados como **globs de directorio** en
  `is_path_in_mefisto_scope`, no enumerados archivo por archivo: MEF-ADR-0019 seccion E
  no exige PR previo de registro para los scripts nuevos.
- Los bloques `[I]` y `[J]` de `scripts/tests/test-guards.sh` validan el cierre haciendo
  **grep literal de las lineas de prosa del prompt**. Mover la mecanica a bash los rompe:
  hay que reescribirlos, no ajustarlos.

## Decisiones

- **Mover la mecanica del cierre a un pipeline bash.** El prompt se queda con una sola
  linea de invocacion. Una linea sobrevive a la compactacion; 120 de prosa, no. Es ademas
  el patron nativo de Mefisto: la mecanica fragil vive en bash.
- **Dos issues, uno por lado.** Cada uno se lleva su script, su agente y su bloque de test
  guard, y ninguno deja un lado huerfano.
- **El publicado depende del interno por diseno, no tecnicamente.** MEF-ADR-0019 prohibe
  que el lado publicado lea codigo del interno: el script publicado es implementacion
  propia que reutiliza el patron ya validado en casa.
- Marcar ambos con `bug`: el comportamiento documentado es correcto, pero no se cumple.

## Descartado

- **Reforzar la prosa del cierre.** Ya esta escrita con maximo detalle y aun asi pierde
  frente a AGENTS.md. Mas texto no gana esa competencia.
- **Arrancar solo por el lado interno.** El usuario pidio planear los dos de una vez.
- **Incluir en estos issues a los demas agentes que escriben field notes**
  (`historiador`, `bug-investigator`, `tooling-investigator`, `reviewer`, `mefisto-investigator`,
  `mefisto-historiador`). Su adopcion del script queda como issue aparte si resulta reutilizable.

## Preguntas abiertas

- Los otros seis agentes con bloques propios de field note: adoptan el script o mantienen
  su mecanica? Nadie audito si sufren la misma deriva.
- El guard `[C]`/blocklist: `scripts/*` no aparece en `is_path_in_consumer_blocklist`
  (a diferencia de `commands/`, `skills/`, `agents/`, `hooks/`). Posible gap sin revisar.
- Falta un mecanismo que dispare el cierre de forma determinista cuando la sesion termina
  abruptamente (`/clear`, Ctrl-C, cierre de ventana). El script lo hace fiable **cuando se
  invoca**, pero el disparo sigue siendo un juicio del agente.

## Referencias

Issues creados:
- #1295 Extraer el cierre documental del planner interno a un pipeline bash determinista
- #1296 Extraer el cierre documental del planner publicado a un pipeline bash determinista (bloqueado por #1295)

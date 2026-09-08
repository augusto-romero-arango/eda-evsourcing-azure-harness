---
fecha: 2026-09-06
hora: 20:28
sesion: mefisto-planner
tema: Refinar #943 (writer detenido por SIGTTIN bajo set -m) y evaluar la propuesta de supervisor autonomo
---

## Contexto

Sesion arrancada en modo orden-de-batch (10 issues listos -> `/mefisto-sequential 928 930 931 935 936 937 938 939 940 941`) y continuada en modo refinar sobre #943: el writer de #928 quedo 15 min en `STAT=T` durante ese mismo batch. El usuario pidio un arreglo de fondo (no un panito de agua tibia), evidencia de la ejecucion y un juicio sobre la propuesta de "supervisor autonomo" de Claude Insights, con el objetivo explicito de que un batch corra sin vigilancia humana.

## Descubrimientos

- **Mecanismo confirmado por experimento en pty de tmux**: con `set -m` el subshell del agente es un grupo en background de la pty del pane; `read </dev/tty`, `stty` (tcsetattr) y `read` de stdin heredado dejan al grupo entero en `T`. Ni `zsh -c -l` a secas ni el snapshot de Claude Code detienen nada: el disparador es intermitente dentro de la tool Bash de Claude Code y no vale perseguirlo; hay que eliminar la clase.
- **`</dev/null` solo es insuficiente**: no cubre `open("/dev/tty")` ni `tcsetattr` sobre otro fd. La sesion nueva (sin terminal de control) si: `/dev/tty` -> ENXIO, `stty` falla, y `kill -9 -$pid` sigue matando el arbol (3 -> 0 procesos, verificado).
- `setsid(1)` no existe en macOS 26.4 pero `/usr/bin/perl` si (`POSIX::setsid`); en Linux hay `setsid`. Con `exec` en el subshell el PID de `$!` se conserva, asi `wait` y el kill de grupo no cambian. Invocar `setsid(1)` desde un subshell que no sea lider de grupo (sin `set -m`) para que no forkee.
- `script(1)` de macOS no sirve para tests headless (exige tty en su stdin); `tmux new-session -d` + `tmux wait-for` si.
- Tras el `SIGCONT` manual el writer de #928 termino el stage con normalidad (`run.completed`, commit, reviewer): la remediacion correcta para un proceso detenido es reanudarlo, no matarlo.
- Historico: de 27 stages con `.events.jsonl`, solo #928 tiene un hueco >5 min con tool en vuelo. #911 tiene uno de 6 min entre tools (latencia de modelo, no stop).
- El lado publicado (`scripts/tooling-pipeline.sh`, `tdd-pipeline.sh`, `iac-pipeline.sh`) no usa `set -m`: no sufre este bug, pero conserva la grieta de #424 (kill de grupo sobre un no-lider, timeout decorativo).
- `AGENT_TIMEOUT_SECONDS=1800` esta hardcodeado en `mefisto-tooling-pipeline.sh` aunque `mefisto-run-agent.sh --timeout` acepta cualquier valor.

## Decisiones

- **#943 acotado al arreglo de fondo**: sesion nueva + `</dev/null` en `run_agent_with_watchdog`, fallback ordenado `setsid` -> perl -> degradar a `set -m` con WARN explicito en events.log (nunca silencioso, nunca abortar). Repro determinista con guion fake `touch-tty` en pty, con caso de control que demuestra el mecanismo. `set -m` queda solo alrededor del watchdog.
- **#945 (nuevo, bloqueado por #943)**: watchdog en rebanadas que detecta `STAT=T` en el grupo del agente, manda `SIGCONT` y escribe `STOPPED:` en events.log. Defensa en profundidad + observabilidad; no mide progreso ni acorta timeouts (eso seria otra politica).
- **#946 (nuevo)**: `MEFISTO_AGENT_TIMEOUT_SECONDS` con default 1800, validado antes de crear el worktree, mismo patron que `MEFISTO_AGENT_MAX_ATTEMPTS`.
- **Propuesta de supervisor autonomo (Claude Insights): descartada como artefacto**, conservada como checklist. Razones: seria un segundo lazo de control compitiendo con watchdog + retry (en la sesion hubo que desarmar el watchdog a mano para que no decapitara el stage reanimado: dos actores sobre los mismos procesos compiten); SIGKILL + relanzar es peor que la evidencia (SIGCONT recupero in situ); partir issues automaticamente es juicio del planner (MEF-ADR-0011), no de un script; la clasificacion y el log de incidentes ya existen (`classify_agent_failure`, events.log, metricas por stage) y solo les faltaba la clase `STOPPED`, que va en #945. Pane tmux sin paste y scope gate falso: sin evidencia en el repo, merecen issue propio cuando se observen.
- Orden de batch sugerido para los tres: `943 946 945`.

## Descartado

- Quitar `set -m` a secas (rompe el kill de grupo, CA-1 de #424).
- Solo `</dev/null` (cubre un caso de tres).
- Reanimador externo por polling (parche de sesion; la remediacion vive dentro del lazo del watchdog).
- Construir `/supervise` con taxonomia y `pipeline-failures.jsonl`.
- Auto-partir issues o re-encolar con mas presupuesto ante TIMEOUT.

## Preguntas abiertas

- Disparador concreto dentro de la tool Bash de Claude Code que toca la tty de forma intermitente: desconocido y deliberadamente no perseguido.
- Porte del watchdog corregido (lider de grupo + sesion nueva) al lado publicado: sin issue todavia.
- Si `claude -p`/`opencode run` sin terminal de control cambian algun comportamiento observable (p. ej. formato de salida): a verificar en la primera corrida real tras #943.

## Referencias

Issues creados: #945, #946
Issues refinados: #943 (`estado:borrador` -> `estado:listo`)
Orden de batch entregado al inicio: `/mefisto-sequential 928 930 931 935 936 937 938 939 940 941`
Logs del incidente: `.mefisto/pipeline/logs/mefisto-tooling-stage-1-writer-20260906-193858-issue-928.*`

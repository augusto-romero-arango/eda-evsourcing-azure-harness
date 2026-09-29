---
fecha: 2026-09-29
hora: 14:52
sesion: mefisto-planner
tema: Plan completo del porte del lado consumidor (y remanente interno) a OpenCode con paridad de capacidades
---

## Contexto
Continuacion de la sesion del porte de `/infra` (field note del 2026-09-23, PR #1630). El usuario pidio el estado del porte del lado consumidor y fue planeando, bloque a bloque, todo lo que faltaba hasta dejar cada pieza con issue.

## Descubrimientos
- `pr-sync` tiene dos piezas: el script (ya portado) y un agente intermediario roto que invocaba `./scripts/pr-sync.sh` relativo al consumidor.
- La politica bash de OpenCode es comun a todos los agentes con `shell`, sin overrides por agente: ampliar `az`/`curl` para un agente los abre para todos. Patron adoptado: exponer la operacion como script distribuido acotado (`azure-account-info.sh`, subcomandos `plan-sites`/`plan-metrics` de `appinsights-query.sh`, `register-harness-secret.sh`) o usar una alternativa ya permitida (`dotnet package search`, capacidad `web`).
- Los comandos corren en la sesion primaria del usuario (sus permisos); solo los agentes quedan bajo la politica generada. `curl` en `/eraser-diagram` tiene paridad por eso.
- Composicion por lectura de otros comandos (`/install-auth`, `/install-workos`, `/bitacora`, `/onboard`) no era portable: nombre de archivo propio de Claude. Se diseno la directiva `{{mefisto:command-doc <id>}}`.
- `appinsights-query.sh` leia su `.env` y escribia auditoria dentro del paquete del plugin y citaba un template inexistente: defecto en ambos runtimes.
- El lado interno ya estaba casi migrado: todos los `.claude/scripts/*.sh` son shims salvo tres; AGENTS.md estaba desactualizado.
- `herdr-workspace.sh` abria la fila OpenCode sin planner (etiqueta visual del corte vertical).

## Decisiones
- Alcance paridad: infra fuera de lotes, igual que Claude.
- Planner a `profile: deep` (Claude pasa de fable a opus).
- `infra-bootstrap` obtiene la suscripcion solo, via `azure-account-info.sh`, sin pedirla al usuario; paso 7 lanza via `tmux-pipeline.sh --infra` en vez de bloquear.
- Validacion de Dockerfile con `docker info`/`docker build -f src/*` permitidos (sin degradar).
- `/fix-review`: gate de plan neutral, sin `Co-Authored-By` hardcodeado, sin rama "modelo local".
- Puente `CLAUDE.md` requerido solo bajo Claude en `/onboard`.
- `/upgrade` simetrico: `upgrade.sh` neutral con estado del par; OpenCode actualiza OpenCode y alinea Claude.
- `remind-field-notes` a senal neutral de fin de turno, una vez por sesion y solo con cambios.

## Descartado
- Retirar el agente `pr-sync` (el usuario pidio portarlo).
- Duplicar inline los pasos de `/seed-secret` en `/install-workos` (reemplazado por `command-doc`).
- `ask` en lugar de `deny` para agentes interactivos de OpenCode (el usuario prefirio no abrirlo).
- Anadir `az`/`curl` a la politica bash global.

## Preguntas abiertas
- Nombre exacto con que OpenCode proyecta el agente `planner` (#1681).
- Si OpenCode descubre `.claude/skills/` (#1685).
- Si OpenCode devuelve el mensaje final del subagente al comando (#1672) y admite dos `launch-agent` alternativos (#1669).
- Disponibilidad de `websearch` en OpenCode segun proveedor (#1667).

## Referencias
Issues creados: #1638, #1640, #1641, #1644-#1657, #1659-#1685

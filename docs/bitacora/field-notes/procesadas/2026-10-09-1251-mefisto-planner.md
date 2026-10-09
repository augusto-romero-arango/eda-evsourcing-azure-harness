---
fecha: 2026-10-09
hora: 12:51
sesion: mefisto-planner
tema: Refinar #2130 (/upgrade solo actualiza scope user)
---

## Contexto
Refinamiento del borrador #2130, con evidencia de Bitakora.ControlAsistencia: la instalacion de scope project quedo en 0.42.1 tras un /upgrade.

## Descubrimientos
- Solo /implement valida el DoR (lee MEF-ADR-0011 en tiempo de ejecucion); /tooling, /infra, /sequential, /parallel y /mefisto-tooling no.
- Precedencia de scopes de plugins verificada en la doc oficial de Claude Code (discover-plugins, "Choose an install scope"): local > project > user; citada en #2130.
- mefisto-planner es mode primary: en OpenCode ya podia preguntar con la herramienta nativa; el hueco interno era solo el mapeo Claude.
- El contrato publicado no tenia una capacidad para preguntar, y OpenCode niega `question` a los agentes mode all: el planner no podia preguntar con la herramienta nativa en ningun runtime sin editar adaptadores generados.
- `claude plugin list --json` expone scope, projectPath, version, enabled e installPath; tambien lista instalaciones de otros proyectos, asi que hay que filtrar por projectPath.
- Segunda causa del falso exito: update-plugin.sh toma la version destino y `.plugin-root` del directorio mas nuevo de la cache, no de la instalacion efectiva.

## Decisiones
- Actualizar todas las instalaciones aplicables (user + project/local del proyecto), sin migrar ni desinstalar.
- Verificar la version efectiva (local > project > user) y fallar si difiere.
- #2130 pasado a estado:listo.
- Capturar como borrador (#2137) el port al planner publicado de los ajustes del experimento de preguntas nativas (AskUserQuestion, mostrar la redaccion antes de confirmar listo, nombrar el issue en la pregunta).

- #2137 refinado y partido: la capacidad neutral `ask` del contrato publicado y sus adaptadores va en #2139 (Claude: AskUserQuestion; OpenCode: question allow en primary/all, subagent sigue en deny). #2137 queda solo con la doctrina del planner y depende de #2139. Ambos pasados a estado:listo.
- El lado interno se corto igual: capacidad ask del contrato interno en #2142, y #2140 (doctrina de mefisto-planner) depende de el. Solo el planner declara ask; los demas agentes internos quedan fuera. Ambos pasados a estado:listo.

- Regla nueva del usuario: un issue estado:listo no deja preguntas abiertas; el refinamiento las resuelve todas, con prueba de concepto en sandbox si hace falta. Desglosada en borradores: #2146 (MEF-ADR-0011, base), #2147 (planner publicado), #2148 (mefisto-planner), #2149 (gate en pipelines publicados), #2150 (gate en mefisto-tooling-pipeline). Defaults: sandbox en .mefisto/sandbox/<sesion>/, el gate solo detecta el encabezado ## Preguntas abiertas, los planners ganan la capacidad web.

## Descartado
- Spikes como dependencia y decisiones con default para preguntas no resueltas: el usuario quiere postura definitiva antes de desarrollo.
- Mapear AskUserQuestion solo en el adaptador Claude (choca con MEF-ADR-0050).
- Migrar las instalaciones project a user (tocaria .claude/settings.json del consumidor).

## Preguntas abiertas
Ninguna.

## Referencias
Issues refinados: #2130
Issues creados: #2137, #2139, #2140, #2142, #2146, #2147, #2148, #2149, #2150

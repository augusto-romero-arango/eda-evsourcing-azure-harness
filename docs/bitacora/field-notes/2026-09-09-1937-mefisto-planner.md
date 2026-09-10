---
fecha: 2026-09-09
hora: 19:37
sesion: mefisto-planner
tema: Refinamiento de corridas tooling multi-runtime desde Herdr
---

## Contexto

Se refinó #1181 para convertir la ejecución E2E posterior a #1180 en dos corridas espejo, verificables y limpiables, sin confundir una dependencia abierta con falta de Definition of Ready.

## Descubrimientos

- `herdr-workspace.sh` obliga las filas Claude/OpenCode en consumidores aunque existan overrides de runtime; Claude usa `mefisto:planner` y OpenCode arranca sin agente publicado durante este corte.
- `herdr-pipeline.sh` identifica el pool por `(workspace,runtime)` en `.mefisto/pipeline/herdr-report-panes.txt` y conserva un único visor durante writer/reviewer.
- Una tercera corrida no aporta al requisito de MEF-ADR-0053: la separación de pools puede observarse con las dos corridas reales y la poda/reutilización ya tiene cobertura automatizada.
- El pipeline llama al runner con `--redact-observability`, no solicita raw/stderr persistentes y guarda streams neutrales, logs, métricas e history en el estado canónico.
- Los summaries se escriben dentro del worktree y desaparecen con su limpieza automática; su copia durable y verificable queda incluida en el body del PR.
- El camino de modelo heredado y el override explícito pueden cubrirse entre las dos corridas: Claude sin `--models` y OpenCode con modelos verificados para writer/reviewer.
- Los issues del consumidor requieren también label `dom:*`; el template de #1179 omitía esa dimensión.

## Decisiones

- Fijar `dom:certificacion` para ambos issues fixture y corregir #1179 para incluirlo en sus templates.
- Crear los fixtures desde el planner publicado en el consumidor; el planner interno de Mefisto no administra ese backlog cross-repo.
- Ejecutar dos issues, ramas, archivos y PRs diferentes sin `--variant`: Claude por camino heredado y OpenCode con override explícito.
- Verificar la separación de pools mediante el ledger real y los filtros de cada visor, sin agregar una corrida artificial para probar reutilización.
- Cerrar los PRs sin merge y borrar sus ramas remotas; cerrar los issues fixture como `not planned` con comentario de certificación para conservar `main` en el SHA baseline.
- Marcar #1181 `estado:listo` y conservar `bloqueado` por #1179/#1180.

## Descartado

- Mantener #1181 en borrador hasta conocer números, modelos, hashes o URLs producidos durante la ejecución.
- Usar `--variant`, porque no abre PR ni satisface el gate.
- Ejecutar una tercera corrida solo para observar la reutilización o `--collapse-panes`.
- Exigir summaries persistentes después de que el pipeline elimina el worktree.
- Ampliar permisos de los agentes tooling para invocar Skills o MCP.
- Mergear los cambios fixture al consumidor completo.

## Preguntas abiertas

- Números definitivos de los dos issues y PRs fixture.
- Modelos efectivos heredado/override disponibles en las instalaciones certificadas.
- Hashes y URLs que producirán las corridas reales.

## Referencias

Draft refinado: #1181

Issue alineado: #1179

Dependencias y sucesor: #1180, #1066

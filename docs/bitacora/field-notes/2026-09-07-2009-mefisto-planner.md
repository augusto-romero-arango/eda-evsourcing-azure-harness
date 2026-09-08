---
fecha: 2026-09-07
hora: 20:09
sesion: mefisto-planner
tema: Distribucion multi-runtime de Mefisto para consumidores OpenCode
---

## Contexto

Se planifico el rollout del lado publicado para que un consumidor pueda usar Mefisto desde
OpenCode sin perder compatibilidad con Claude Code. El gate interno de MEF-ADR-0049 ya estaba
cerrado por #874, pero seguian pendientes la distribucion global, el layout publicado neutral y
la certificacion de un corte vertical real.

## Descubrimientos

- El catalogo publicado conserva acoplamientos a `CLAUDE_PLUGIN_ROOT`, `claude -p`, `claude
  --agent`, `.claude/harness.config.json`, `.claude/pipeline/` y `CLAUDE.md`.
- El nucleo interno ya ofrece precedentes probados para protocolo JSONL, traduccion de wire
  formats, seleccion runtime/modelo, hold/resume y adaptadores generados.
- `tooling-pipeline.sh` no usa agentes publicados nominados para writer/reviewer: construye sus
  prompts y ejecuta `claude -p` directamente. El corte vertical requiere agentes neutrales
  propios del consumidor, distintos de `mefisto-writer` y `mefisto-reviewer`.
- Los hooks interactivos y el MCP tambien son parte de la superficie distribuible; portar solo
  comandos, agentes y pipelines no alcanza paridad observable.
- MEF-ADR-0019 obliga a registrar `src/published/`, `src/runtime/` y `dist/` antes de poblarlos.

## Decisiones

- Distribuir OpenCode globalmente por usuario desde artefactos versionados en GitHub, con una
  sola version activa, activacion atomica y rollback.
- Mantener una sola version SemVer/tag para adaptadores Claude y OpenCode.
- Usar `src/published/` como fuente neutral publicada, `src/runtime/` como nucleo compartido de
  runner/eventos y `dist/{claude,opencode}/` como salidas generadas.
- Declarar `AGENTS.md`, `.mefisto/harness.config.json` y `.mefisto/pipeline/` canonicos; leer
  indefinidamente `CLAUDE.md` y `.claude/*` como fallback, pero escribir solo al canonico.
- Mantener `/mefisto:*` como namespace visible en ambos runtimes y adaptar nombres de Agent
  Skills OpenCode con prefijo `mefisto-`.
- Certificar primero `/tooling` completo hasta PR, incluidos Skills, MCP, hooks, logs, metricas,
  sesiones y Herdr. El resto del catalogo no se migra antes de superar ese gate.
- En Herdr para consumidores, ubicar Claude arriba y OpenCode abajo, con pools de panes separados
  por runtime. Esto no cambia el grafo de dependencias ni introduce doctrina de oleadas.
- Desglosar el rollout en 25 issues pequenos, sin epic, unidos exclusivamente mediante
  `## Dependencias`; #1042 es el unico inicialmente lanzable y los otros llevan `bloqueado`.

## Descartado

- Mantener dos fuentes manuales independientes para Claude y OpenCode.
- Copiar la instalacion o configuracion OpenCode dentro de cada consumidor.
- Usar `.claude/*` como contrato canonico neutral o migrar/borrar automaticamente estado legacy.
- Leer auth stores de los runtimes, transportar credenciales en el paquete o registrar prompts y
  tool inputs sensibles.
- Migrar todo el catalogo antes de validar un corte vertical real.
- Compartir doctrina, scopes o agentes entre el lado interno y publicado; solo se comparte el
  nucleo mecanico autorizado por MEF-ADR-0018/0019.

## Preguntas abiertas

- Confirmar durante #1042/#1052, contra la documentacion y version minima soportada de OpenCode,
  las rutas globales exactas de descubrimiento para comandos, agentes, Skills, plugins y MCP.
- La migracion del resto de comandos, agentes y pipelines se planificara despues de cerrar la
  certificacion #1066 y usar sus hallazgos como gate.

## Referencias

Issues creados: #1042, #1043, #1044, #1045, #1046, #1047, #1048, #1049, #1050, #1051,
#1052, #1053, #1054, #1055, #1056, #1057, #1058, #1059, #1060, #1061, #1062, #1063,
#1064, #1065 y #1066.

ADRs: MEF-ADR-0018, MEF-ADR-0019, MEF-ADR-0025, MEF-ADR-0033, MEF-ADR-0049,
MEF-ADR-0050, MEF-ADR-0051 y MEF-ADR-0053 (propuesto por #1042).

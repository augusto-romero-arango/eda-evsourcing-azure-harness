---
fecha: 2026-09-07
hora: 02:08
sesion: mefisto-planner
tema: refinamiento multi-runtime del experimento LSP (#976)
---

## Contexto

Se refino el draft #976, originado en el consumidor `Bitakora.ControlAsistencia`, para evaluar con evidencia si LSP aporta un beneficio neto de tokens, tiempo o calidad al navegar codigo C#. El usuario pidio contemplar tanto OpenCode como Claude Code y decidio retirar la dependencia opcional del MCP de Rider porque no lo tiene activo ni quiere exigir licencia o instalacion externa a los consumidores.

## Descubrimientos

- OpenCode 1.18.29 separa tres gates: servidor C# habilitado mediante `lsp`, tool experimental habilitada mediante `OPENCODE_EXPERIMENTAL_LSP_TOOL=true` (o el flag global) y permiso `lsp: allow`. El repo solo tenia resuelto el permiso interno; `opencode.json` no habilita servidores.
- Claude Code ofrece el plugin oficial `csharp-lsp` 1.0.0 sobre `csharp-ls`. Como los pipelines publicados usan `claude -p`, la disponibilidad y frescura deben comprobarse especificamente en headless; reportes abiertos del tracker muestran diferencias respecto del modo interactivo, pero se trataron como senales de riesgo, no como autoridad normativa.
- El baseline real de Mefisto no era puramente textual: `implementer`, `projection-implementer` y `reviewer` declaraban `mcp__jetbrains__*`, y los dos generalistas priorizaban Rider. Ese MCP es user-level y Mefisto no lo instala.
- El pipeline publicado sigue acoplado a `claude -p`. Por eso el piloto OpenCode solo puede evaluar stages aislados con configuracion temporal equivalente; no puede certificar soporte publicado ni paridad de pipeline.
- Las metricas existentes bastan para el efecto neto (tokens totales, duracion y tool calls), pero no transportan el tamano de cada respuesta de tool. Se decidio no ampliar el contrato antes de demostrar necesidad; el volumen bruto queda como diagnostico opcional derivado de la traza.
- El mapping interno actual es asimetrico: la capacidad `read` habilita LSP en OpenCode y no en Claude. Si la evidencia recomienda adopcion, la capacidad semantica debe modelarse aparte de lectura textual.

## Decisiones

- #976 queda acotado a definir protocolo, corpus, preflight, evidencia y umbrales; pasa a `estado:listo` con seis CAs y un unico artefacto principal de documentacion.
- Los deltas se calculan dentro de cada runtime con el mismo modelo, prompt, SHA y estado inicial. No se comparan cifras absolutas entre Claude Code y OpenCode.
- El corpus cubre `planner`, `implementer` y `reviewer`; los roles no probados no reciben LSP por extrapolacion.
- El baseline es textual y sin Rider MCP. #978 retira esa dependencia de los tres agentes publicados antes de los pilotos.
- #979 ejecuta el piloto Claude Code headless con el plugin oficial; #980 ejecuta el piloto OpenCode en stages aislados. Ambos dependen de #976 y #978 y quedan con label `bloqueado`.
- #981 sintetiza ambos resultados en un ADR y solo despues enumera follow-ups de adopcion por componente/runtime.
- Umbral de gobierno del piloto (decision propia de Mefisto, no best practice externa): no inferioridad de calidad y, despues, al menos 10% menos input tokens o 15% menos wall-clock, sin empeorar la otra metrica mas de 10%.

## Descartado

- Conservar todo el experimento, la adopcion y la ADR en #976: excedia la revision de complejidad y mezclaba varios componentes y runtimes.
- Usar Rider MCP como baseline o tercera variante: no representa el entorno disponible del mantenedor y mantendria una expectativa de licencia/configuracion externa.
- Portar primero todo el pipeline publicado a OpenCode: el usuario prefirio un piloto de stage aislado para responder antes la pregunta de valor.
- Comparar Claude Code contra OpenCode por valores absolutos: modelo, servidor, schema y wire format son variables confundentes.
- Ampliar de inmediato el schema neutral con bytes por tool result: los tokens totales ya capturan el costo neto que origino la pregunta.

## Preguntas abiertas

- Si los pilotos son favorables, que combinaciones concretas de runtime/rol superaran el umbral y cuales quedaran sin evidencia.
- Si el plugin `csharp-lsp` permanece disponible y fresco bajo la version headless usada al ejecutar #979.
- Si la naturaleza experimental de la tool OpenCode permite una adopcion normal o exige mantenerla opt-in aun con beneficio medido.
- Que follow-ups por agente, adaptador y configuracion crea #981 despues de conocer el resultado.

## Referencias

Issues creados/refinados: #976, #978, #979, #980, #981.

Fuentes verificadas: documentacion oficial OpenCode `tools.mdx`/`lsp.mdx`; marketplace oficial `anthropics/claude-plugins-official` (`csharp-lsp`); MEF-ADR-0019, MEF-ADR-0031, MEF-ADR-0049 y MEF-ADR-0050.

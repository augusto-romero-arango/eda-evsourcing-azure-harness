# Matriz de adaptación de hooks interactivos

Fecha de verificación: 2026-09-08. Fuentes: [Claude Code Hooks](https://code.claude.com/docs/en/hooks) (documentación oficial, sin versión de API publicada) y [OpenCode Plugins](https://opencode.ai/docs/plugins/) (documentación oficial, OpenCode 1.18.29 como versión mínima registrada por MEF-ADR-0053). Un adaptador debe informar una degradación visible cuando una fila requerida sea `no soportado`; no puede omitir el binding silenciosamente.

| Señal neutral | Claude Code | OpenCode | Clasificación |
|---|---|---|---|
| `session.started` | `SessionStart` | `session.created` de plugin | equivalente |
| `plan.completed` | `PostToolUse` filtrado por `ExitPlanMode` | no hay evento específico de finalización de planificación documentado | no soportado |
| `file.changed` | `PostToolUse` filtrado por `Write|Edit` | `tool.execute.after`, filtrado por herramienta de escritura | sintetizado |
| `dotnet-test.completed` | `PostToolUse` filtrado por `Bash` y clasificación del resultado | `tool.execute.after`, filtrado y clasificado por el adaptador | sintetizado |
| `terraform.completed` | `PostToolUse` filtrado por `Bash` y clasificación del resultado | `tool.execute.after`, filtrado y clasificado por el adaptador | sintetizado |

Los nombres de eventos y herramientas de esta matriz pertenecen únicamente a sus adaptadores; no forman parte de `interactive-hooks.json`. Los límites efectivos de entrega síncrona son los timeouts del hook configurados por Claude Code y de la ejecución de plugin de OpenCode, porque el contrato declara `timeoutSeconds: null`.

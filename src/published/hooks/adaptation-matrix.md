# Matriz de adaptación de hooks interactivos

Fecha de verificación: 2026-09-08. Fuentes: [Claude Code Hooks](https://code.claude.com/docs/en/hooks) (documentación oficial, sin versión de API publicada) y [OpenCode Plugins](https://opencode.ai/docs/plugins/) (documentación oficial, verificada para OpenCode 1.18.29, versión mínima registrada por MEF-ADR-0053). Un adaptador debe informar una degradación visible cuando una celda requerida sea `no soportado`; no puede omitir el binding silenciosamente.

| Binding / señal neutral | Claude Code | Clasificación Claude | OpenCode | Clasificación OpenCode |
|---|---|---|---|---|
| `record-active-release` / `session.started` | evento `SessionStart` | equivalente | evento `session.created` recibido por el hook `event` del plugin | equivalente |
| `append-session` / `session.started` | evento `SessionStart` | equivalente | evento `session.created` recibido por el hook `event` del plugin | equivalente |
| `remind-field-notes` / `plan.completed` | `PostToolUse` filtrado por `ExitPlanMode` | sintetizado | no hay evento ni tool de finalización de planificación documentado | no soportado |
| `append-file-change` / `file.changed` | `PostToolUse` filtrado por `Write|Edit` | sintetizado | `tool.execute.after`, filtrado por herramienta de escritura | sintetizado |
| `append-dotnet-test-result` / `dotnet-test.completed` | `PostToolUse` filtrado por `Bash` y clasificación del resultado | sintetizado | `tool.execute.after`, filtrado y clasificado por el adaptador | sintetizado |
| `append-terraform-result` / `terraform.completed` | `PostToolUse` filtrado por `Bash` y clasificación del resultado | sintetizado | `tool.execute.after`, filtrado y clasificado por el adaptador | sintetizado |

Los nombres de eventos y herramientas de esta matriz pertenecen únicamente a sus adaptadores; no forman parte de `interactive-hooks.json`. Con `timeoutSeconds: null`, Mefisto no agrega un deadline. El límite efectivo de Claude Code es el `timeout` del command hook: la fuente oficial documenta 600 segundos por defecto. La documentación oficial de plugins de OpenCode no publica un timeout específico para callbacks asíncronos; allí el límite efectivo queda en el ciclo de vida del proceso anfitrión. El adaptador debe documentar si una versión futura del runtime introduce un límite distinto.

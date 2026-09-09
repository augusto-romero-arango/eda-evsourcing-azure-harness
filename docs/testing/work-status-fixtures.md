# Fixtures documentales de `/work-status`

Casos de lectura para el dashboard publicado. Todos son solo lectura: ningún caso copia o migra estado.

| Caso | Datos de entrada | Resultado verificable |
|---|---|---|
| Solo canónico | `.mefisto/pipeline/pipeline-status-tooling-18.json` y su historial | Muestra Tooling aunque `.claude/pipeline/` esté ausente. |
| Solo legacy | Status antiguos y `history.jsonl`/`tooling-history.jsonl`/`infra-history.jsonl` solo bajo `.claude/pipeline/` | Infiere el pipeline también para cada historial separado y muestra `runtime: -`. |
| Mezcla Tooling + TDD | Tooling canónico running y TDD legacy running | Muestra ambas filas, no usa un root como fallback excluyente. |
| Duplicados | Los dos roots contienen `(tooling, 18, exp-a)` y el mismo historial con `started` igual | Muestra una sola fila/entrada, la copia canónica. |
| Dos runtimes y un hold | Status canónico `opencode` con hold estructurado y status canónico `claude` sin hold | Solo OpenCode queda `EN ESPERA`; Claude conserva su stage o `SIN NOVEDADES`. |
| Hold textual ambiguo | Dos status legacy `running` del mismo root y distinto runtime, sin hold estructurado; `events.log` anuncia un hold vigente | No atribuye el texto a ninguna fila porque no identifica la corrida; nunca propaga el hold al otro runtime. |
| Status estancado | `running`, sin hold y `updated` de hace 36 minutos | Muestra `SIN NOVEDADES`. |
| Corrida neutral en vuelo | `log` apunta a un `.log` ausente y existe su hermano `*.events.jsonl` | El drill-down abre/remite al JSONL neutral; no interpreta raw del runtime. |
| Paths con espacios | `log: ".mefisto/pipeline/logs/mi corrida.log"` | El primer `Read` usa exactamente ese path declarado. |
| Ningún dato | No hay status ni historial en ninguno de los dos roots | Muestra `(sin pipelines registrados)`. |

Para reconstrucción legacy, el orden obligatorio es `.mefisto/pipeline/logs/` y después `.claude/pipeline/logs/`; un `log` declarado siempre prevalece. El parseo de `events.log` queda limitado al fallback de una fila legacy sin hold estructurado.

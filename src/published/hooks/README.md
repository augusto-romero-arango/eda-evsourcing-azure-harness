# Contrato neutral de hooks interactivos

`interactive-hooks.json` expresa los seis comportamientos publicados que ya existen, sin fijar un runtime ni una forma ejecutable. Los adaptadores de #1058 y #1059 son quienes traducen señales, resuelven los destinos lógicos y reportan cualquier degradación. `timeoutSeconds: null` significa que Mefisto no agrega un plazo: el límite efectivo es el que documente y aplique cada runtime.

La persistencia se rige por allowlist (MEF-ADR-0025). Ningún binding conserva prompts, input completo de herramientas, comandos shell completos, tokens, cookies, headers, variables de credenciales ni auth stores.

| Binding | Inputs mínimos permitidos | Salida/destino lógico permitido | Handler vigente |
|---|---|---|---|
| `record-active-release` | identidad de la distribución activa observable | `release_identity` en `canonical-state` y `release-identity`; exclusivamente como transición, también puede reflejar esa misma identidad en `legacy-release-marker` | `SessionStart`, primer comando |
| `append-session` | `session_id`, `transcript_path`, `cwd`, `source`, `timestamp`, `harness_version` | Esas seis claves, exactamente, en `canonical-state` y `session-registry`; `harness_version` es `null` si no es observable | `SessionStart`, segundo comando |
| `remind-field-notes` | finalización de planificación | Solo el recordatorio visible al usuario en `human-log`; no persiste datos | `PostToolUse` con matcher `ExitPlanMode` |
| `append-file-change` | path del archivo cambiado | `time` (`HH:MM:SS` UTC), familia fija `archivo` y `file_path` en `canonical-state` y `human-log` | `PostToolUse` con matcher `Write|Edit` |
| `append-dotnet-test-result` | resultado resumido de la prueba | `time` (`HH:MM:SS` UTC), familia fija `test` y `result` limitado a `PASS|FAIL` en `canonical-state` y `human-log` | primer comando de `PostToolUse` con matcher `Bash` |
| `append-terraform-result` | subcomando y resultado resumido de Terraform | `time` (`HH:MM:SS` UTC), familia fija `terraform`, `terraform_subcommand` limitado a `plan|apply|init|validate` y `result` limitado a `OK|ERROR` en `canonical-state` y `human-log` | segundo comando de `PostToolUse` con matcher `Bash` |

No se declara comportamiento para fin de sesión, inicio de herramienta, prompt, permiso, notificación ni compactación: no existen handlers vigentes para esas señales.

## Excepción transitoria del marker de release

El destino lógico `legacy-release-marker` está reservado en exclusiva a `record-active-release`. El adaptador Claude de #1058 materializará el reflejo en `.claude/pipeline/.plugin-root` con la identidad/ruta de la distribución cargada observada desde `CLAUDE_PLUGIN_ROOT` y limpiará `.claude/pipeline/.plugin-root.previous`; no copiará en el mirror el valor previo que conserva `/upgrade`. El estado canónico sigue siendo obligatorio y primario: el adaptador no resuelve dos versiones ni usa el release más reciente del cache como fallback, porque ese cache puede haber avanzado y no describir la versión que la sesión ya cargó.

El fallo al mantener el mirror no invalida la sesión (`failure: continue`) ni autoriza dual-write para `sessions.jsonl` o `events.log`, que se escriben solo en el estado canónico. OpenCode no recibe este destino. La excepción se retira únicamente con un issue posterior, después de un inventario verificable sin lectores de `.claude/pipeline/.plugin-root` ni `.claude/pipeline/.plugin-root.previous`; el cierre de #1054 no la retira implícitamente. Véanse MEF-ADR-0053, decisión 4, y la matriz de adaptación.

## Matriz de adaptación

Ver [adaptation-matrix.md](adaptation-matrix.md). La matriz es deliberadamente separada del descriptor: puede nombrar capacidades de runtime y debe conservar la evidencia oficial, mientras el JSON permanece neutral.

## Validación

`../scripts/validate-interactive-hooks.sh` requiere Bash 3.2 y `jq`; valida el descriptor y un archivo alternativo pasado como único argumento. Sus fixtures y el test de inventario no necesitan red ni instalaciones de runtime.

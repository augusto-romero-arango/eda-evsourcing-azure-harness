# Contrato neutral de hooks interactivos

`interactive-hooks.json` expresa los seis comportamientos publicados que ya existen, sin fijar un runtime ni una forma ejecutable. Los adaptadores de #1058 y #1059 son quienes traducen señales, resuelven los destinos lógicos y reportan cualquier degradación. `timeoutSeconds: null` significa que Mefisto no agrega un plazo: el límite efectivo es el que documente y aplique cada runtime.

La persistencia se rige por allowlist (MEF-ADR-0025). Ningún binding conserva prompts, input completo de herramientas, comandos shell completos, tokens, cookies, headers, variables de credenciales ni auth stores.

| Binding | Inputs mínimos permitidos | Salida/destino lógico permitido | Handler vigente |
|---|---|---|---|
| `record-active-release` | identidad de la distribución activa observable | Solo `release_identity` en `canonical-state` y `release-identity`; no fija una ruta heredada | `SessionStart`, primer comando |
| `append-session` | `session_id`, `transcript_path`, `cwd`, `source`, `timestamp`, `harness_version` | Esas seis claves, exactamente, en `canonical-state` y `session-registry`; `harness_version` es `null` si no es observable | `SessionStart`, segundo comando |
| `remind-field-notes` | finalización de planificación | Solo el recordatorio visible al usuario en `human-log`; no persiste datos | `PostToolUse` con matcher `ExitPlanMode` |
| `append-file-change` | path del archivo cambiado | `time` (`HH:MM:SS` UTC), familia fija `archivo` y `file_path` en `canonical-state` y `human-log` | `PostToolUse` con matcher `Write|Edit` |
| `append-dotnet-test-result` | resultado resumido de la prueba | `time` (`HH:MM:SS` UTC), familia fija `test` y `result` limitado a `PASS|FAIL` en `canonical-state` y `human-log` | primer comando de `PostToolUse` con matcher `Bash` |
| `append-terraform-result` | subcomando y resultado resumido de Terraform | `time` (`HH:MM:SS` UTC), familia fija `terraform`, `terraform_subcommand` limitado a `plan|apply|init|validate` y `result` limitado a `OK|ERROR` en `canonical-state` y `human-log` | segundo comando de `PostToolUse` con matcher `Bash` |

No se declara comportamiento para fin de sesión, inicio de herramienta, prompt, permiso, notificación ni compactación: no existen handlers vigentes para esas señales.

## Matriz de adaptación

Ver [adaptation-matrix.md](adaptation-matrix.md). La matriz es deliberadamente separada del descriptor: puede nombrar capacidades de runtime y debe conservar la evidencia oficial, mientras el JSON permanece neutral.

## Validación

`../scripts/validate-interactive-hooks.sh` requiere Bash 3.2 y `jq`; valida el descriptor y un archivo alternativo pasado como único argumento. Sus fixtures y el test de inventario no necesitan red ni instalaciones de runtime.

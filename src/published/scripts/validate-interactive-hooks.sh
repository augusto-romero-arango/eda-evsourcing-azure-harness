#!/usr/bin/env bash
# Valida el contrato neutral de hooks interactivos publicados (Bash 3.2 + jq).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HOOKS_DIR="$REPO_ROOT/src/published/hooks"
SCHEMA="$HOOKS_DIR/interactive-hooks.schema.json"
DEFAULT_CONTRACT="$HOOKS_DIR/interactive-hooks.json"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq no esta instalado" >&2; exit 1; }
[ -f "$SCHEMA" ] || { echo "ERROR: falta schema: $SCHEMA" >&2; exit 1; }
jq empty "$SCHEMA" >/dev/null 2>&1 || { echo "ERROR: schema JSON invalido" >&2; exit 1; }

if [ "$#" -gt 1 ]; then echo "Uso: $(basename "$0") [contrato.json]" >&2; exit 1; fi
CONTRACT="${1:-$DEFAULT_CONTRACT}"
[ -f "$CONTRACT" ] || { echo "$CONTRACT: archivo no existe" >&2; exit 1; }
if ! jq empty "$CONTRACT" >/dev/null 2>&1; then echo "$CONTRACT: JSON invalido" >&2; exit 1; fi

ERRORS=$(jq -r '
  def keys_are($expected): (keys | sort) == ($expected | sort);
  def fail($message): $message;
  def required_binding($id; $signal; $action; $destinations; $fields):
    .bindings[] | select(.id == $id) |
    if .signal != $signal or .action != $action then "binding " + $id + ": par signal/action desconocido"
    elif .destinations != $destinations then "binding " + $id + ": destinos no coinciden con su contrato"
    elif .persistedFields != $fields then "binding " + $id + ": allowlist de campos persistibles divergente"
    else empty end;
  . as $contract |
  (if type != "object" then fail("raiz: debe ser objeto")
  elif keys_are(["$schema", "contractVersion", "bindings"]) | not then fail("raiz: propiedad adicional o faltante")
  elif .["$schema"] != "interactive-hooks.schema.json" then fail("$schema: valor desconocido")
  elif .contractVersion != "1.0" then fail("contractVersion: valor desconocido")
  elif (.bindings | type) != "array" or (.bindings | length) != 6 then fail("bindings: se esperaban exactamente seis bindings")
  else empty end),
  ($contract.bindings[]? |
    if type != "object" then fail("binding: debe ser objeto")
    elif keys_are(["id", "signal", "action", "destinations", "persistedFields", "delivery"]) | not then fail("binding: propiedad adicional o faltante")
    elif (.id | type) != "string" or (.id | test("^[a-z0-9]+(-[a-z0-9]+)*$") | not) then fail("binding: id invalido")
    elif (.signal as $signal | ["session.started", "plan.completed", "file.changed", "dotnet-test.completed", "terraform.completed"] | index($signal)) == null then fail("binding " + .id + ": signal desconocida")
    elif (.action as $action | ["record-active-release", "append-session", "remind-field-notes", "append-file-change", "append-dotnet-test-result", "append-terraform-result"] | index($action)) == null then fail("binding " + .id + ": accion desconocida")
    elif (.destinations | type) != "array" or (.destinations | length) == 0 or any(.destinations[]; . as $destination | (["canonical-state", "session-registry", "human-log", "release-identity"] | index($destination)) == null) then fail("binding " + .id + ": destino desconocido")
    elif (.persistedFields | type) != "array" or any(.persistedFields[]; type != "string" or test("^(prompt|command|token|cookie|header|credential|auth)(_|$)"; "i")) then fail("binding " + .id + ": campo persistible sensible o desconocido")
    elif (.delivery | type) != "object" or (.delivery | keys_are(["mode", "failure", "timeoutSeconds"]) | not) or (.delivery != {"mode":"sync", "failure":"continue", "timeoutSeconds":null}) then fail("binding " + .id + ": delivery divergente")
    else empty end),
  (if ([$contract.bindings[].id] | unique | length) != ($contract.bindings | length) then "bindings: id duplicado" else empty end),
  ($contract | required_binding("record-active-release"; "session.started"; "record-active-release"; ["canonical-state", "release-identity"]; ["release_identity"])),
  ($contract | required_binding("append-session"; "session.started"; "append-session"; ["canonical-state", "session-registry"]; ["session_id", "transcript_path", "cwd", "source", "timestamp", "harness_version"])),
  ($contract | required_binding("remind-field-notes"; "plan.completed"; "remind-field-notes"; ["human-log"]; [])),
  ($contract | required_binding("append-file-change"; "file.changed"; "append-file-change"; ["canonical-state", "human-log"]; ["timestamp", "family", "file_path"])),
  ($contract | required_binding("append-dotnet-test-result"; "dotnet-test.completed"; "append-dotnet-test-result"; ["canonical-state", "human-log"]; ["timestamp", "family", "result"])),
  ($contract | required_binding("append-terraform-result"; "terraform.completed"; "append-terraform-result"; ["canonical-state", "human-log"]; ["timestamp", "family", "terraform_subcommand", "result"])),
  ($contract | [.. | strings | select(test("CLAUDE_PLUGIN_ROOT|\\.claude|\\.opencode|SessionStart|PostToolUse|ExitPlanMode|Write\\|Edit|Bash|claude|opencode|cache|javascript|typescript"; "i"))] | unique[]? | "contrato: referencia a runtime: " + .)
' "$CONTRACT") || { echo "$CONTRACT: no se pudo evaluar el contrato" >&2; exit 1; }

if [ -n "$ERRORS" ]; then printf '%s\n' "$ERRORS" >&2; exit 1; fi
exit 0

#!/usr/bin/env bash
# Valida el registro MCP neutral publicado y su proyeccion Claude.
# Uso: validate-published-mcp.sh [--registry archivo] [--artifact-schema archivo] [--claude-config archivo]
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONTRACT_DIR="$REPO_ROOT/src/published/contract"
REGISTRY="$CONTRACT_DIR/mcp-servers.json"
REGISTRY_SCHEMA="$CONTRACT_DIR/mcp-servers.schema.json"
ARTIFACT_SCHEMA="$CONTRACT_DIR/published-artifact.schema.json"
CLAUDE_CONFIG="$REPO_ROOT/.mcp.json"
JSONSCHEMA_LITE="$SCRIPT_DIR/lib/jsonschema-lite.jq"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq no esta instalado" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
    case "$1" in
        --registry) REGISTRY="$2"; shift 2 ;;
        --artifact-schema) ARTIFACT_SCHEMA="$2"; shift 2 ;;
        --claude-config) CLAUDE_CONFIG="$2"; shift 2 ;;
        *) echo "Uso: $(basename "$0") [--registry archivo] [--artifact-schema archivo] [--claude-config archivo]" >&2; exit 2 ;;
    esac
done
for required in "$REGISTRY" "$REGISTRY_SCHEMA" "$ARTIFACT_SCHEMA" "$CLAUDE_CONFIG" "$JSONSCHEMA_LITE"; do
    [ -f "$required" ] || { echo "ERROR: no existe '$required'" >&2; exit 1; }
done

status=0
fail() { echo "$1" >&2; status=1; }
registry="$(jq -c '.' "$REGISTRY" 2>/dev/null)" || { echo "$REGISTRY: JSON invalido" >&2; exit 1; }
schema="$(jq -c '.' "$REGISTRY_SCHEMA")"
errors="$(jq -n --argjson schema "$schema" --argjson instance "$registry" -f "$JSONSCHEMA_LITE" 2>&1)" || { echo "$REGISTRY: schema: el validador jq fallo: $errors" >&2; exit 1; }
if [ "$(printf '%s' "$errors" | jq 'length')" -gt 0 ]; then
    printf '%s' "$errors" | jq -r --arg file "$REGISTRY" '.[] | "\($file): \(.)"' >&2
    status=1
fi

ids="$(printf '%s' "$registry" | jq -c '[.servers[].id]')"
unique_ids="$(printf '%s' "$ids" | jq -c 'unique')"
[ "$ids" = "$unique_ids" ] || fail "$REGISTRY: servers: ids duplicados no permitidos"

if printf '%s' "$registry" | jq -e '.. | objects | keys_unsorted[]? | select(test("^(headers?|environment|env|oauth|token|secret|credential)s?$"; "i"))' >/dev/null; then
    fail "$REGISTRY: contiene material o configuracion sensible no permitida"
fi
if ! printf '%s' "$registry" | jq -e '.servers[] | select(.provisioning == "bundled") | select(.transport != "remote-http" or (.url | type) != "string" or (.url | test("^https://") | not) or .authentication != "none")' | grep -q .; then :; else
    fail "$REGISTRY: bundled exige transport remote-http, URL HTTPS y authentication none"
fi
if ! printf '%s' "$registry" | jq -e '.servers[] | select(.provisioning == "external") | select(.transport != null or .url != null or .authentication != null)' | grep -q .; then :; else
    fail "$REGISTRY: external exige transport, url y authentication nulos"
fi

artifact="$(jq -c '.' "$ARTIFACT_SCHEMA" 2>/dev/null)" || { echo "$ARTIFACT_SCHEMA: JSON invalido" >&2; exit 1; }
for kind in agent command; do
    enum="$(printf '%s' "$artifact" | jq -c --arg kind "$kind" '.oneOf[] | select(.properties.kind.enum == [$kind]) | .properties.mcp.items.enum')"
    [ -n "$enum" ] && [ "$enum" != "null" ] || { fail "$ARTIFACT_SCHEMA: falta enum mcp para $kind"; continue; }
    [ "$(printf '%s' "$enum" | jq -c 'unique')" = "$enum" ] || fail "$ARTIFACT_SCHEMA: enum mcp para $kind contiene ids duplicados"
    [ "$enum" = "$ids" ] || fail "$ARTIFACT_SCHEMA: enum mcp para $kind difiere del registro MCP"
done

claude="$(jq -c '.' "$CLAUDE_CONFIG" 2>/dev/null)" || { echo "$CLAUDE_CONFIG: JSON invalido" >&2; exit 1; }
projection="$(printf '%s' "$registry" | jq -c '{mcpServers: ([.servers[] | select(.provisioning == "bundled") | select(.transport == "remote-http") | {key: .id, value: {type: "http", url: .url}}] | from_entries)}')"
[ "$claude" = "$projection" ] || fail "$CLAUDE_CONFIG: difiere de la proyeccion Claude derivada del registro MCP"
exit "$status"

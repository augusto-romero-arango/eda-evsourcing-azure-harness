#!/usr/bin/env bash
# Evalua declarativamente las vias de fuente; no abre red ni stores de auth.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
MATRIX="$REPO_ROOT/src/published/contract/source-verification.json"
REGISTRY="$REPO_ROOT/src/published/contract/mcp-servers.json"
FILTER="$REPO_ROOT/src/published/scripts/lib/source-verification.jq"
REQUIRED='[]'
command -v jq >/dev/null 2>&1 || { printf '%s\n' 'ERROR: jq no esta instalado' >&2; exit 1; }
while [ "$#" -gt 0 ]; do case "$1" in --require) [ "$#" -ge 2 ] || { printf '%s\n' 'ERROR: --require necesita rol/caso' >&2; exit 2; }; REQUIRED="$(jq -cn --argjson prior "$REQUIRED" --arg value "$2" '$prior + [$value]')" || exit 2; shift 2 ;; *) printf 'Uso: %s [--require rol/caso]\n' "$(basename "$0")" >&2; exit 2 ;; esac; done
for file in "$MATRIX" "$REGISTRY" "$FILTER"; do [ -f "$file" ] || { printf 'ERROR: falta %s\n' "$file" >&2; exit 1; }; done
roles='[]'
for file in "$REPO_ROOT"/src/published/agents/*.md; do
    [ -f "$file" ] || continue
    frontmatter="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$file")"
    role="$(printf '%s\n' "$frontmatter" | jq -c '{id,capabilities:(.capabilities // []),mcp:(.mcp // [])}')" || { printf 'ERROR: frontmatter invalido: %s\n' "$file" >&2; exit 1; }
    roles="$(jq -cn --argjson prior "$roles" --argjson role "$role" '$prior + [$role]')" || exit 1
done
envelope="$(jq -cn --slurpfile matrix "$MATRIX" --slurpfile registry "$REGISTRY" --argjson roles "$roles" --argjson requiredCases "$REQUIRED" '{matrix:$matrix[0],registry:$registry[0],roles:$roles,requiredCases:$requiredCases}')" || exit 1
printf '%s\n' "$envelope" | jq -f "$FILTER"

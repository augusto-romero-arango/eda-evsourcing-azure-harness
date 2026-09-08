#!/usr/bin/env bash
# Adaptador ejecutable Claude Code de la interfaz publicada.
set -uo pipefail
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$SCRIPT_DIR/../lib/adapter-claude.sh"
error() { printf '%s\n' "$1" >&2; return 1; }
case "${1:-}" in
    root) printf '%s\n' 'dist/claude' ;;
    path) case "${2:-}" in src/published/agents/*.md) printf 'agents/%s\n' "$(basename "$2")" ;; src/published/commands/*.md) printf 'commands/%s\n' "$(basename "$2")" ;; *) error "$2: path: fuente publicada desconocida" ;; esac ;;
    render) [ "$#" -eq 3 ] || error 'render: se esperaban fuente y marcador'; published_claude_render "$2" "$3" "$REPO_ROOT" ;;
    assets) printf '%s\n' '[]' ;;
    *) error 'uso: adapter-claude.sh root|path|render|assets|render-asset' ;;
esac

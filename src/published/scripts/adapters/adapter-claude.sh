#!/usr/bin/env bash
# Adaptador ejecutable Claude Code de la interfaz publicada.
set -uo pipefail
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$SCRIPT_DIR/../lib/adapter-claude.sh"
error() { printf '%s\n' "$1" >&2; return 1; }

release_identity() {
    local identity="$1" plugin="$REPO_ROOT/.claude-plugin/plugin.json" version commit
    [ -f "$identity" ] && [ ! -L "$identity" ] || { error 'release-identity.json: fuente ausente o no regular'; return 1; }
    [ -f "$plugin" ] && [ ! -L "$plugin" ] || { error 'plugin.json: fuente ausente o no regular'; return 1; }
    jq -e '
        (keys | sort) == ["commit", "schemaVersion", "version"] and
        .schemaVersion == 1 and
        (.version | type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$")) and
        (.commit | type == "string" and test("^[0-9a-f]{40}$"))
    ' "$identity" >/dev/null 2>&1 || { error 'release-identity.json: schema, version o commit invalidos'; return 1; }
    version="$(jq -er '.version' "$identity")" || { error 'release-identity.json: version invalida'; return 1; }
    commit="$(jq -er '.commit' "$identity")" || { error 'release-identity.json: commit invalido'; return 1; }
    [ "$(jq -er '.version | strings' "$plugin" 2>/dev/null)" = "$version" ] || { error 'release-identity.json: version distinta de .claude-plugin/plugin.json'; return 1; }
    jq -cn --arg version "$version" --arg commit "$commit" '{schemaVersion:1,runtime:"claude",version:$version,commit:$commit}'
}

case "${1:-}" in
    root) printf '%s\n' 'dist/claude' ;;
    path) case "${2:-}" in src/published/agents/*.md) printf 'agents/%s\n' "$(basename "$2")" ;; src/published/commands/*.md) printf 'commands/%s\n' "$(basename "$2")" ;; *) error "$2: path: fuente publicada desconocida" ;; esac ;;
    render) [ "$#" -eq 3 ] || error 'render: se esperaban fuente y marcador'; published_claude_render "$2" "$3" "$REPO_ROOT" ;;
    assets) printf '%s\n' '[{"id":"mefisto-manifest","source":"src/published/release-identity.json","destination":"mefisto-manifest.json","mode":"0644"}]' ;;
    render-asset)
        [ "$#" -eq 3 ] || { error 'render-asset: se esperaban id y fuente'; exit 1; }
        [ "$2" = 'mefisto-manifest' ] || { error "render-asset: asset desconocido: $2"; exit 1; }
        release_identity "$3" || exit 1 ;;
    *) error 'uso: adapter-claude.sh root|path|render|assets|render-asset' ;;
esac

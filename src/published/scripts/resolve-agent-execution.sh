#!/usr/bin/env bash
# Entrada distribuida del compilador de politica por rol (#1856). Solo calcula:
# no aplica config, no autoriza una sesion y no escribe estado.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RELEASE_ROOT="$(cd "$HERE/.." && pwd -P)"
# Clausura propia: solo la release que contiene este wrapper.
LIBS="$RELEASE_ROOT/src/published/scripts/adapters/lib"
[ -f "$LIBS/opencode-agent-projection.sh" ] && [ -f "$LIBS/opencode-agent-projection.jq" ] && [ -f "$LIBS/opencode-entry-permissions.jq" ] && [ -f "$RELEASE_ROOT/agent-execution-manifest.json" ] && [ -f "$RELEASE_ROOT/src/published/contract/agent-execution.json" ] || {
    printf '%s\n' 'ERROR: la release instalada no contiene la clausura del compilador de politica por rol.' >&2; exit 2
}
[ "$#" -eq 0 ] || { printf '%s\n' 'uso: resolve-agent-execution.sh < envelope.json' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf '%s\n' 'ERROR: jq no esta instalado.' >&2; exit 2; }
source "$LIBS/opencode-agent-projection.sh"
opencode_agent_projection_resolve "$RELEASE_ROOT"
exit $?

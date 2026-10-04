#!/usr/bin/env bash
# Entrada distribuida del resolver de recursos OpenCode. Solo describe y
# verifica el alcance solicitado; no aprueba, no escribe y no concede permisos.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RELEASE_ROOT="$(cd "$HERE/.." && pwd -P)"
# Clausura propia: solo la release que contiene este wrapper, nunca un checkout
# ni una instalacion mas nueva.
LIBS="$RELEASE_ROOT/src/published/scripts"
[ -f "$LIBS/lib/resource-paths.sh" ] && [ -f "$LIBS/adapters/lib/opencode-resource-roots.sh" ] && [ -f "$LIBS/adapters/lib/opencode-resources.sh" ] || {
    printf '%s\n' 'ERROR: la release instalada no contiene la clausura del resolver de recursos.' >&2; exit 2
}
usage() { printf '%s\n' 'uso: resolve-opencode-resources.sh --project-root <raiz-absoluta> --worktree-root <raiz-absoluta> < envelope.json' >&2; exit 2; }
PROJECT_ROOT=''; WORKTREE_ROOT=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --project-root) [ "$#" -ge 2 ] && [ -z "$PROJECT_ROOT" ] || usage; PROJECT_ROOT="$2"; shift 2 ;;
        --worktree-root) [ "$#" -ge 2 ] && [ -z "$WORKTREE_ROOT" ] || usage; WORKTREE_ROOT="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$PROJECT_ROOT" ] && [ -n "$WORKTREE_ROOT" ] || usage
case "$PROJECT_ROOT$WORKTREE_ROOT" in *[[:cntrl:]]*) usage ;; esac
case "$PROJECT_ROOT" in /*) ;; *) usage ;; esac
case "$WORKTREE_ROOT" in /*) ;; *) usage ;; esac
command -v jq >/dev/null 2>&1 || { printf '%s\n' 'ERROR: jq no esta instalado.' >&2; exit 2; }
source "$LIBS/lib/resource-paths.sh"
source "$LIBS/adapters/lib/opencode-resource-roots.sh"
source "$LIBS/adapters/lib/opencode-resources.sh"
opencode_resources_resolve "$RELEASE_ROOT" "$PROJECT_ROOT" "$WORKTREE_ROOT" "$HERE"
exit $?

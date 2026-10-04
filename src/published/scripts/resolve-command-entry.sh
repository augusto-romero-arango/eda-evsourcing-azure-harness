#!/usr/bin/env bash
# Entrada distribuida del ensamblador de la proyeccion de entrada por comando
# (#1836). Solo calcula: no escribe config, consentimiento ni recursos, no
# aprueba ni revoca y no autoriza ejecucion.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RELEASE_ROOT="$(cd "$HERE/.." && pwd -P)"
# Clausura propia: solo la release que contiene este wrapper, nunca un checkout
# ni la instalacion mas reciente.
LIBS="$RELEASE_ROOT/src/published/scripts/adapters/lib"
[ -f "$LIBS/opencode-command-entry.sh" ] && [ -f "$LIBS/opencode-command-entry.jq" ] && [ -f "$LIBS/opencode-entry-permissions.jq" ] \
    && [ -f "$RELEASE_ROOT/command-entry-manifest.json" ] && [ -f "$RELEASE_ROOT/src/published/contract/command-entry.json" ] \
    && [ -x "$HERE/resolve-opencode-resources.sh" ] && [ -x "$HERE/autonomy-profile.sh" ] || {
    printf '%s\n' 'ERROR: la release instalada no contiene la clausura del ensamblador de entrada.' >&2; exit 2
}
usage() { printf '%s\n' 'uso: resolve-command-entry.sh --project-root <raiz-absoluta> < envelope.json' >&2; exit 2; }
PROJECT_ROOT=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --project-root) [ "$#" -ge 2 ] && [ -z "$PROJECT_ROOT" ] || usage; PROJECT_ROOT="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$PROJECT_ROOT" ] || usage
case "$PROJECT_ROOT" in *[[:cntrl:]]*) usage ;; /*) ;; *) usage ;; esac
command -v jq >/dev/null 2>&1 || { printf '%s\n' 'ERROR: jq no esta instalado.' >&2; exit 2; }
source "$LIBS/opencode-command-entry.sh"
opencode_command_entry_resolve "$RELEASE_ROOT" "$PROJECT_ROOT" "$HERE"
exit $?

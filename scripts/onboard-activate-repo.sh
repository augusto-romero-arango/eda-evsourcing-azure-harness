#!/usr/bin/env bash
# onboard-activate-repo.sh -- habilita Mefisto en el repositorio consumidor para
# Claude Code y OpenCode (MEF-ADR-0053 decision 2, issue #2261). Provision opt-in
# de /onboard.
#
# Mefisto se instala por usuario e inerte; estos dos archivos, commiteados, son lo
# que lo activa en el repo y en sus worktrees:
#   .claude/settings.json        fusiona extraKnownMarketplaces y enabledPlugins sin
#                                tocar el resto de claves.
#   .opencode/plugins/mefisto.js cargador que registra la release OpenCode activa; se
#                                escribe si falta o difiere del de esta version.
# No commitea.
#
# Uso: scripts/onboard-activate-repo.sh --preview | --apply   (cwd = raiz del consumidor)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_plugin-scopes.sh"
LOADER_SOURCE="$SCRIPT_DIR/../src/published/opencode/mefisto-loader.js"
LOADER_DEST=".opencode/plugins/mefisto.js"

main() {
    local modo="${1:-}" top mkt fuente archivo actual nuevo claude_pendiente=false loader_pendiente=false
    top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git" >&2; return 1; }
    if [ -f "$top/.claude-plugin/plugin.json" ]; then
        echo "ERROR: /onboard no aplica al repo de Mefisto." >&2
        echo "       scripts/onboard-activate-repo.sh es del plugin publicado y solo aplica al consumidor." >&2
        return 1
    fi
    case "$modo" in
        --preview|--apply) ;;
        *) echo "Uso: $0 --preview | --apply" >&2; return 1 ;;
    esac
    command -v jq >/dev/null 2>&1 || { echo "ERROR: jq es requerido." >&2; return 1; }
    [ -f "$LOADER_SOURCE" ] || { echo "ERROR: falta el cargador OpenCode en el paquete ($LOADER_SOURCE)." >&2; return 1; }

    mkt=$(_mefisto_marketplace "$SCRIPT_DIR/..")
    fuente=$(_fuente_marketplace "$mkt")
    archivo="$top/.claude/settings.json"
    if [ -f "$archivo" ]; then
        actual=$(cat "$archivo")
        printf '%s' "$actual" | jq -e 'type == "object"' >/dev/null 2>&1 || {
            echo "ERROR: $archivo no es un objeto JSON valido; corrigelo a mano." >&2
            return 1
        }
    else
        actual='{}'
    fi
    nuevo=$(printf '%s' "$actual" | jq --arg m "$mkt" --argjson f "$fuente" '
        .extraKnownMarketplaces[$m] = (.extraKnownMarketplaces[$m] // {source: $f})
        | .enabledPlugins["mefisto@" + $m] = true')
    [ "$(printf '%s' "$actual" | jq -S .)" = "$(printf '%s' "$nuevo" | jq -S .)" ] || claude_pendiente=true
    cmp -s "$LOADER_SOURCE" "$top/$LOADER_DEST" || loader_pendiente=true

    if [ "$claude_pendiente" = false ] && [ "$loader_pendiente" = false ]; then
        echo "OK: el repo ya habilita Mefisto (.claude/settings.json y $LOADER_DEST); no hay nada que escribir."
        return 0
    fi
    if [ "$modo" = --preview ]; then
        echo "Plan:"
        if [ "$claude_pendiente" = true ]; then
            echo "  - escribir .claude/settings.json con este contenido (resto de claves intacto):"
            printf '%s\n' "$nuevo" | sed 's/^/      /'
        fi
        if [ "$loader_pendiente" = true ]; then
            if [ -f "$top/$LOADER_DEST" ]; then
                echo "  - reemplazar $LOADER_DEST por el cargador de esta version"
            else
                echo "  - crear $LOADER_DEST (cargador de la release OpenCode activa)"
            fi
        fi
        return 0
    fi
    if [ "$claude_pendiente" = true ]; then
        mkdir -p "$top/.claude"
        printf '%s\n' "$nuevo" > "$archivo" || { echo "ERROR: no se pudo escribir $archivo." >&2; return 1; }
        echo "OK: .claude/settings.json habilita mefisto@$mkt."
    fi
    if [ "$loader_pendiente" = true ]; then
        mkdir -p "$top/.opencode/plugins"
        cp "$LOADER_SOURCE" "$top/$LOADER_DEST" || { echo "ERROR: no se pudo escribir $LOADER_DEST." >&2; return 1; }
        echo "OK: $LOADER_DEST registra la release OpenCode activa."
    fi
    echo "Commitea los archivos y llevalos a main: los worktrees de pipeline nacen de origin/main."
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
    exit $?
fi

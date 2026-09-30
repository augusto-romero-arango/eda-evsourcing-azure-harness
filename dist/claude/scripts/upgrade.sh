#!/usr/bin/env bash
# upgrade.sh -- operacion neutral de actualizacion de Mefisto (issue #1678, MEF-ADR-0050/0053).
#
# Despacha por el runtime activo (MEFISTO_RUNTIME o mefisto_resolve_runtime):
#   claude    delega en update-plugin.sh (autoridad del lado Claude) y alinea el par OpenCode.
#   opencode  actualiza OpenCode a la ultima release publicada mediante el launcher activo.
#             La alineacion del par Claude desde este runtime la cubre un issue hermano.
#
# Uso:
#   scripts/upgrade.sh --status                   JSON versionado con el estado del par
#   scripts/upgrade.sh [--align-peer]             actualiza (y alinea el par si se pide)
#   scripts/upgrade.sh --prune [--keep <n>]       poda (solo tras confirmar en el comando)
#
# Nunca borra nada fuera de --prune. Refrescar panes, el mensaje de reload y la
# confirmacion de poda son responsabilidad del comando, no de este script.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_REPO_SLUG="augusto-romero-arango/eda-evsourcing-azure-harness"
LEGACY_USAGE='ERROR: uso: mefisto-opencode install <semver> | activate <semver> | prune [--keep <n>] [--yes] | project | deactivate | status | diagnose | package-root'

usage() {
    echo "Uso: $0 --status | [--align-peer] | --prune [--keep <n>]" >&2
}

_guard_consumidor() {
    local repo_top
    repo_top=$(git rev-parse --show-toplevel 2>/dev/null) || {
        echo "ERROR: no estas en un repositorio git" >&2
        return 1
    }
    if [ -f "$repo_top/.claude-plugin/plugin.json" ]; then
        echo "ERROR: /mefisto:upgrade no aplica al repo de Mefisto." >&2
        echo "       scripts/upgrade.sh es del plugin publicado y solo aplica al consumidor." >&2
        echo "       Mefisto se actualiza a si mismo por su propio flujo de release (/mefisto-release)." >&2
        return 1
    fi
}

_resolver_runtime() {
    local lib="$SCRIPT_DIR/../src/runtime/lib/mefisto-runtime.sh"
    if [ -n "${MEFISTO_RUNTIME:-}" ]; then
        RUNTIME="$MEFISTO_RUNTIME"
    elif [ -f "$lib" ]; then
        # shellcheck disable=SC1090
        source "$lib"
        RUNTIME=$(mefisto_resolve_runtime) || {
            echo "ERROR: ${MEFISTO_RUNTIME_ERROR:-no se pudo resolver el runtime}" >&2
            return 1
        }
    else
        echo "ERROR: fija MEFISTO_RUNTIME (claude u opencode)." >&2
        return 1
    fi
    case "$RUNTIME" in
        claude|opencode) ;;
        *) echo "ERROR: runtime '$RUNTIME' no soportado por upgrade (solo claude u opencode)." >&2; return 1 ;;
    esac
}

_launcher_path() {
    if [ -n "${MEFISTO_OPENCODE_LAUNCHER:-}" ]; then
        printf '%s\n' "$MEFISTO_OPENCODE_LAUNCHER"
    elif [ -n "${XDG_DATA_HOME:-}" ]; then
        printf '%s\n' "$XDG_DATA_HOME/mefisto/active/bin/mefisto-opencode"
    elif [ "$(uname -s)" = Darwin ]; then
        printf '%s\n' "$HOME/Library/Application Support/mefisto/active/bin/mefisto-opencode"
    else
        printf '%s\n' "$HOME/.local/share/mefisto/active/bin/mefisto-opencode"
    fi
}

# Estado del par OpenCode (contrato projection-status). Setea PEER_STATE y PEER_VERSION.
_peer_opencode() {
    local launcher json rc state
    PEER_STATE=disabled; PEER_VERSION=""
    launcher=$(_launcher_path)
    [ -x "$launcher" ] || return 0
    if json=$("$launcher" projection-status 2>&1); then rc=0; else rc=$?; fi
    PEER_STATE=unavailable
    if [ "$rc" -ne 0 ] && [ "$json" = "$LEGACY_USAGE" ]; then
        PEER_STATE=legacy
    elif printf '%s' "$json" | jq -e '
        .schemaVersion == 1 and
        (.status == "disabled" or .status == "enabled" or .status == "stale" or
         .status == "conflict" or .status == "operation-in-progress") and
        (.configRoot | type == "string") and
        (.activeVersion == null or (.activeVersion | type == "string")) and
        (.ledgerRelease == null or (.ledgerRelease | type == "string"))
    ' >/dev/null 2>&1; then
        state=$(printf '%s' "$json" | jq -r '.status')
        case "$state:$rc" in
            disabled:0|enabled:0|stale:0|conflict:1|operation-in-progress:1)
                PEER_STATE="$state"
                PEER_VERSION=$(printf '%s' "$json" | jq -r '.activeVersion // empty')
                ;;
        esac
    fi
}

_loaded_claude() {
    local root
    root=$(cat .claude/pipeline/.plugin-root 2>/dev/null) || root=""
    [ -n "$root" ] && basename "${root%/}"
}

_loaded_opencode() {
    local launcher json
    launcher=$(_launcher_path)
    [ -x "$launcher" ] || return 0
    json=$("$launcher" projection-status 2>/dev/null) || return 0
    printf '%s' "$json" | jq -r '.activeVersion // empty' 2>/dev/null
}

cmd_status() {
    command -v jq >/dev/null 2>&1 || { echo "ERROR: jq es requerido para --status." >&2; return 1; }
    local loaded="" peer_runtime
    if [ "$RUNTIME" = claude ]; then
        peer_runtime=opencode
        loaded=$(_loaded_claude)
        _peer_opencode
    else
        peer_runtime=claude
        loaded=$(_loaded_opencode)
        PEER_STATE=unavailable; PEER_VERSION=""
    fi
    jq -cn --arg rt "$RUNTIME" --arg loaded "$loaded" --arg prt "$peer_runtime" \
        --arg ps "$PEER_STATE" --arg pv "$PEER_VERSION" '
        {schemaVersion: 1, runtime: $rt,
         loadedVersion: (if $loaded == "" then null else $loaded end),
         peer: {runtime: $prt, state: $ps, version: (if $pv == "" then null else $pv end)}}'
}

_update_claude() {
    local update="$SCRIPT_DIR/update-plugin.sh" args=()
    [ -f "$update" ] || { echo "ERROR: no se hallo update-plugin.sh junto a upgrade.sh." >&2; return 1; }
    if [ "$MODE" = prune ]; then
        args=(--prune)
        local loaded
        loaded=$(_loaded_claude)
        [ -n "$LOADED_OVERRIDE" ] && loaded="$LOADED_OVERRIDE"
        [ -n "$loaded" ] && args+=(--loaded "$loaded")
    elif [ "$ALIGN_PEER" = true ]; then
        args=(--align-opencode)
    fi
    bash "$update" ${args[@]+"${args[@]}"}
}

_repo_slug() {
    local slug=""
    if [ -n "${HARNESS_CONFIG_PATH:-}" ] && [ -f "$HARNESS_CONFIG_PATH" ]; then
        slug=$(jq -r '.repoSlug // empty' "$HARNESS_CONFIG_PATH" 2>/dev/null)
    elif [ -f .claude/harness.config.json ]; then
        slug=$(jq -r '.repoSlug // empty' .claude/harness.config.json 2>/dev/null)
    fi
    printf '%s\n' "${slug:-$DEFAULT_REPO_SLUG}"
}

_prune_opencode() {
    local launcher
    launcher=$(_launcher_path)
    [ -x "$launcher" ] || { echo "ERROR: no hay launcher OpenCode activo; nada que podar." >&2; return 1; }
    "$launcher" prune --keep "$KEEP" --yes
}

_update_opencode() {
    local launcher slug tag version loaded
    command -v gh >/dev/null 2>&1 || { echo "ERROR: gh es requerido para resolver la ultima release." >&2; return 1; }
    launcher=$(_launcher_path)
    [ -x "$launcher" ] || {
        echo "ERROR: no hay launcher OpenCode activo ($launcher)." >&2
        echo "       Instala Mefisto para OpenCode con el bootstrap publicado y reintenta." >&2
        return 1
    }
    slug=$(_repo_slug)
    tag=$(gh release view --repo "$slug" --json tagName --jq .tagName 2>/dev/null) || tag=""
    version="${tag#v}"
    if [ -z "$version" ]; then
        echo "ERROR: no se pudo resolver la ultima release de $slug con 'gh release view'." >&2
        return 1
    fi
    loaded=$(_loaded_opencode)
    echo "Version cargada en esta sesion: ${loaded:-desconocida}"

    if [ -n "$loaded" ] && [ "$loaded" = "$version" ]; then
        echo "Ya estas en la ultima version ($version); no se modifico nada."
        echo "Version destino: $version"
        return 0
    fi

    echo "Instalando OpenCode v$version con el launcher activo (verifica checksum)..."
    "$launcher" install "$version" || { echo "ERROR: install fallo; las releases existentes se conservan." >&2; return 1; }
    "$launcher" activate "$version" || { echo "ERROR: activate fallo; usa el launcher para rollback." >&2; return 1; }
    "$launcher" project || { echo "ERROR: project fallo o conflicto; corrige y reintenta." >&2; return 1; }
    "$launcher" status || { echo "ERROR: status reporto una instalacion incompleta." >&2; return 1; }
    "$launcher" projection-status || { echo "ERROR: projection-status no confirmo la proyeccion." >&2; return 1; }

    echo ""
    echo "Version destino: $version"
    echo "Versiones OpenCode podables (no se borro nada):"
    "$launcher" prune --keep "$KEEP" </dev/null 2>&1 | sed 's/^/  /' || true
    echo "Reinicia OpenCode para descubrir la proyeccion actualizada."
    if [ "$ALIGN_PEER" = true ]; then
        echo "AVISO: la alineacion del par Claude desde OpenCode aun no esta disponible."
    fi
}

main() {
    MODE=update; ALIGN_PEER=false; KEEP=2; LOADED_OVERRIDE=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --status) MODE=status; shift ;;
            --align-peer) ALIGN_PEER=true; shift ;;
            --prune) MODE=prune; shift ;;
            --keep)
                if [ "$#" -lt 2 ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    echo "ERROR: --keep requiere un entero." >&2; usage; return 1
                fi
                KEEP="$2"; shift 2 ;;
            --loaded)
                [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "ERROR: --loaded requiere una version." >&2; return 1; }
                LOADED_OVERRIDE="$2"; shift 2 ;;
            -h|--help) usage; return 0 ;;
            *) echo "ERROR: argumento desconocido '$1'" >&2; usage; return 1 ;;
        esac
    done
    if [ "$MODE" = prune ] && [ "$ALIGN_PEER" = true ]; then
        echo "ERROR: --align-peer no se combina con --prune." >&2; usage; return 1
    fi

    _guard_consumidor || return 1
    _resolver_runtime || return 1

    case "$MODE:$RUNTIME" in
        status:*) cmd_status ;;
        prune:opencode) _prune_opencode ;;
        *:opencode) _update_opencode ;;
        *:claude) _update_claude ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
    exit $?
fi

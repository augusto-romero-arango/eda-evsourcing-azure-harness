#!/usr/bin/env bash
# upgrade.sh -- operacion neutral de actualizacion de Mefisto (issue #1678, MEF-ADR-0050/0053).
#
# Despacha por el runtime activo (MEFISTO_RUNTIME o mefisto_resolve_runtime):
#   claude    delega en update-plugin.sh (autoridad del lado Claude) y alinea el par OpenCode.
#   opencode  actualiza OpenCode a la ultima release publicada mediante el launcher activo.
#             Con --align-peer alinea tambien la instalacion Claude a la misma version (#1679).
#
# Uso:
#   scripts/upgrade.sh --status                   JSON versionado (schemaVersion 2) con la version
#                                                 instalada en disco y el estado del par; es local,
#                                                 no informa si hay una version mas nueva publicada
#   scripts/upgrade.sh [--align-peer]             actualiza (y alinea el par si se pide)
#   scripts/upgrade.sh --prune [--keep <n>] [--only <v>[,<v>...]] [--loaded <v>]
#                                                 poda (solo tras confirmar en el comando);
#                                                 --keep aplica a OpenCode; --only (lista confirmada,
#                                                 obligatoria en Claude) y --loaded a Claude
#
# Nunca borra nada fuera de --prune. Refrescar panes, el mensaje de reload y la
# confirmacion de poda son responsabilidad del comando, no de este script.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_plugin-scopes.sh"
DEFAULT_REPO_SLUG="augusto-romero-arango/eda-evsourcing-azure-harness"
LEGACY_USAGE='ERROR: uso: mefisto-opencode install <semver> | activate <semver> | prune [--keep <n>] [--yes] | project | deactivate | status | diagnose | package-root'

usage() {
    echo "Uso: $0 --status | [--align-peer] | --prune [--keep <n>] [--only <v>[,<v>...]] [--loaded <version>]" >&2
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

# Version instalada en disco (la que cargara la proxima sesion), no la de la sesion viva.
_installed_claude() {
    local root
    root=$(cat .claude/pipeline/.plugin-root 2>/dev/null) || root=""
    [ -n "$root" ] && basename "${root%/}"
}

# Release activa del launcher en disco; no es la version cargada en la sesion viva.
_installed_opencode() {
    local launcher json
    launcher=$(_launcher_path)
    [ -x "$launcher" ] || return 0
    json=$("$launcher" projection-status 2>/dev/null) || return 0
    printf '%s' "$json" | jq -r '.activeVersion // empty' 2>/dev/null
}

# Estado del par Claude. Setea PEER_STATE, PEER_VERSION y PEER_MKT (marketplace de mefisto).
# Solo consulta 'claude plugin list'; no lee configuracion, providers ni credenciales.
_peer_claude() {
    local out rc
    PEER_STATE=disabled; PEER_VERSION=""; PEER_MKT=""
    command -v claude >/dev/null 2>&1 || return 0
    if out=$(claude plugin list 2>&1); then rc=0; else rc=$?; fi
    if [ "$rc" -ne 0 ]; then PEER_STATE=unavailable; return 0; fi
    PEER_MKT=$(printf '%s\n' "$out" | sed -n 's/^[^A-Za-z0-9]*mefisto@\([^[:space:]]*\).*/\1/p' | head -1)
    if [ -n "$PEER_MKT" ]; then
        PEER_STATE=enabled
        PEER_VERSION=$(printf '%s\n' "$out" | awk -v k="mefisto@$PEER_MKT" '
            index($0, k) {f=1; next}
            f && /^[^A-Za-z0-9]*[A-Za-z0-9._-]+@/ {exit}
            f && /Version:/ {sub(/^.*Version:[[:space:]]*/, ""); print; exit}')
    elif printf '%s' "$out" | grep -qiE 'installed plugins|no plugins'; then
        PEER_STATE=disabled
    else
        PEER_STATE=unavailable
    fi
}

# Marketplace donde instalar mefisto cuando el par esta disabled: se deriva de
# 'claude plugin marketplace list' por el slug del repo, sin hardcodear el nombre.
_claude_marketplace_for_install() {
    local slug out
    slug=$(_repo_slug)
    out=$(claude plugin marketplace list 2>/dev/null) || return 1
    printf '%s\n' "$out" | awk -v s="$slug" '
        /^[^A-Za-z0-9]*[A-Za-z0-9._-]+[[:space:]]*$/ {n=$0; gsub(/^[^A-Za-z0-9]*|[[:space:]]*$/, "", n)}
        index($0, s) && n != "" {print n; exit}'
}

cmd_status() {
    command -v jq >/dev/null 2>&1 || { echo "ERROR: jq es requerido para --status." >&2; return 1; }
    local installed="" peer_runtime
    if [ "$RUNTIME" = claude ]; then
        peer_runtime=opencode
        installed=$(_installed_claude)
        _peer_opencode
    else
        peer_runtime=claude
        installed=$(_installed_opencode)
        _peer_claude
    fi
    jq -cn --arg rt "$RUNTIME" --arg installed "$installed" --arg prt "$peer_runtime" \
        --arg ps "$PEER_STATE" --arg pv "$PEER_VERSION" '
        {schemaVersion: 2, runtime: $rt,
         installedVersion: (if $installed == "" then null else $installed end),
         peer: {runtime: $prt, state: $ps, version: (if $pv == "" then null else $pv end)}}'
}

# Version cargada segun MEFISTO_LOADED_ROOT (ruta de la version viva, sustituida por el
# comando). Valida: ruta absoluta existente, plugin.json con name mefisto y version igual
# al nombre del directorio. Vacia, sin sustituir o invalida: imprime nada.
_loaded_from_root() {
    local root="${MEFISTO_LOADED_ROOT:-}" manifest name ver
    [ -n "$root" ] || return 0
    case "$root" in *'${'*|*/..|*/../*) return 0 ;; /*) ;; *) return 0 ;; esac
    root="${root%/}"
    manifest="$root/.claude-plugin/plugin.json"
    [ -d "$root" ] && [ -f "$manifest" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    name=$(jq -r '.name // empty' "$manifest" 2>/dev/null)
    ver=$(jq -r '.version // empty' "$manifest" 2>/dev/null)
    [ "$name" = mefisto ] && [ -n "$ver" ] && [ "$ver" = "$(basename "$root")" ] || return 0
    printf '%s\n' "$ver"
}

_update_claude() {
    local update="$SCRIPT_DIR/update-plugin.sh" args=() loaded
    [ -f "$update" ] || { echo "ERROR: no se hallo update-plugin.sh junto a upgrade.sh." >&2; return 1; }
    loaded="$LOADED_OVERRIDE"
    [ -n "$loaded" ] || loaded=$(_loaded_from_root)
    if [ "$MODE" = prune ]; then
        args=(--prune)
        [ "$ONLY_GIVEN" = false ] || args+=(--only "$ONLY")
    elif [ "$ALIGN_PEER" = true ]; then
        args=(--align-opencode)
    fi
    [ -z "$loaded" ] || args+=(--loaded "$loaded")
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
    loaded=$(_installed_opencode)
    echo "Version cargada en esta sesion: ${loaded:-desconocida}"

    if [ -n "$loaded" ] && [ "$loaded" = "$version" ]; then
        echo "Ya estas en la ultima version ($version); no se modifico nada."
        echo "Version destino: $version"
        TARGET_VERSION="$version"
        return 0
    fi
    TARGET_VERSION="$version"

    echo "Instalando OpenCode v$version con el launcher activo (verifica checksum)..."
    "$launcher" install "$version" || { echo "ERROR: install fallo; las releases existentes se conservan." >&2; return 1; }
    "$launcher" activate "$version" || { echo "ERROR: activate fallo; usa el launcher para rollback." >&2; return 1; }
    "$launcher" project || { echo "ERROR: project fallo o conflicto; corrige y reintenta." >&2; return 1; }
    "$launcher" status || { echo "ERROR: status reporto una instalacion incompleta." >&2; return 1; }
    "$launcher" projection-status || { echo "ERROR: projection-status no confirmo la proyeccion." >&2; return 1; }

    echo ""
    echo "Version destino: $version"
    echo "Versiones OpenCode podables (no se borro nada):"
    # Sin --yes y sin TTY el launcher lista y se niega a borrar: se descarta ese rechazo.
    "$launcher" prune --keep "$KEEP" </dev/null 2>&1 | grep -v '^ERROR:' | sed 's/^/  /' || true
    echo "Reinicia OpenCode para descubrir la proyeccion actualizada."
}

_align_claude() {
    local target="$1" mkt root ver diag opencode_root launcher top efectiva ef_path _s
    _peer_claude
    echo ""
    echo "Par Claude: $PEER_STATE${PEER_VERSION:+ (version $PEER_VERSION)}"
    case "$PEER_STATE" in
        unavailable|conflict|operation-in-progress)
            echo "AVISO: par Claude '$PEER_STATE'; no se muta Claude. OpenCode ya quedo en $target."
            return 0 ;;
        disabled)
            if ! command -v claude >/dev/null 2>&1; then
                echo "AVISO: el CLI claude no existe; no hay instalacion Claude que alinear."
                return 0
            fi
            mkt=$(_claude_marketplace_for_install) || mkt=""
            if [ -z "$mkt" ]; then
                echo "AVISO: no se pudo derivar el marketplace de mefisto; no se instala Claude." >&2
                return 0
            fi
            echo "Instalando mefisto@$mkt en Claude (scope user)..."
            claude plugin marketplace update "$mkt" || { echo "ERROR: 'claude plugin marketplace update $mkt' fallo." >&2; return 1; }
            claude plugin install "mefisto@$mkt" --scope user || { echo "ERROR: 'claude plugin install mefisto@$mkt' fallo." >&2; return 1; }
            ;;
        enabled)
            mkt="$PEER_MKT"
            echo "Actualizando mefisto@$mkt en Claude (scopes aplicables al proyecto)..."
            claude plugin marketplace update "$mkt" || { echo "ERROR: 'claude plugin marketplace update $mkt' fallo." >&2; return 1; }
            top=$(git rev-parse --show-toplevel 2>/dev/null) || top=""
            _actualizar_scopes "$mkt" "$(_plugin_list_json)" "$top" || return 1
            ;;
    esac

    _peer_claude
    ver="$PEER_VERSION"
    top=$(git rev-parse --show-toplevel 2>/dev/null) || top=""
    efectiva=$(_instalacion_efectiva "${PEER_MKT:-$mkt}" "$(_plugin_list_json)" "$top")
    [ -n "$efectiva" ] && IFS=$'\t' read -r _s ver ef_path <<< "$efectiva"
    root="${MEFISTO_CACHE_ROOT:-$HOME/.claude/plugins/cache}/${PEER_MKT:-$mkt}/mefisto/$ver"
    [ -n "${ef_path:-}" ] && [ -d "$ef_path" ] && root="${ef_path%/}"
    launcher=$(_launcher_path)
    # Misma raiz fisica que usa update-plugin.sh; el fallback cubre launchers sin package-root.
    opencode_root=$("$launcher" package-root 2>/dev/null) || opencode_root=""
    [ -n "$opencode_root" ] && [ -d "$opencode_root" ] ||
        opencode_root="$(cd "$(dirname "$launcher")/.." 2>/dev/null && pwd -P)"
    # La release OpenCode empaqueta el diagnostico en su raiz; en el repo vive en src/published.
    diag="$opencode_root/diagnose-installation-identity.sh"
    [ -f "$diag" ] || diag="$SCRIPT_DIR/../src/published/scripts/diagnose-installation-identity.sh"
    if [ -f "$diag" ]; then
        echo "Identidad de instalaciones:"
        bash "$diag" --claude-root "$root" --opencode-root "$opencode_root" || true
    else
        echo "AVISO: no se hallo diagnose-installation-identity.sh; se omite la verificacion de identidad."
    fi
    if [ "$ver" != "$target" ]; then
        echo "DERIVA VISIBLE: Claude quedo en ${ver:-desconocida} y la version destino es $target (el marketplace aun no publico esa version). OpenCode no se revierte."
    else
        echo "Claude alineado en $target. Recarga Claude (/reload-plugins o reinicio)."
    fi
}

main() {
    MODE=update; ALIGN_PEER=false; KEEP=2; LOADED_OVERRIDE=""; ONLY=""; ONLY_GIVEN=false
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
            --only)
                [ "$#" -ge 2 ] || { echo "ERROR: --only requiere una lista de versiones." >&2; return 1; }
                ONLY="$2"; ONLY_GIVEN=true; shift 2 ;;
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
        *:opencode)
            TARGET_VERSION=""
            _update_opencode || return 1
            [ "$ALIGN_PEER" = true ] && { _align_claude "$TARGET_VERSION" || return 1; }
            return 0 ;;
        *:claude) _update_claude ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
    exit $?
fi

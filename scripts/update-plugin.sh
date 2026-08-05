#!/usr/bin/env bash
# update-plugin.sh -- actualiza el plugin Mefisto desde el consumidor (issue #531).
#
# Reemplaza el flujo manual de 4 pasos (UI de /plugin, reescribir .plugin-root a mano,
# podar el cache de versiones viejas, /reload-plugins) por 1 comando + el reload final
# (el reload no es automatizable desde dentro de la sesion: lo declara el propio CLI,
# "restart required to apply").
#
# Que hace, en orden:
#   1. Detecta el marketplace que provee 'mefisto' por glob sobre el cache de plugins
#      (~/.claude/plugins/cache/<marketplace>/mefisto/), sin hardcodear el nombre --
#      asi funciona igual en un fork instalado bajo otro nombre de marketplace (repoSlug).
#   2. Actualiza el catalogo del marketplace y el plugin a la ultima version, ambos
#      sin interaccion ('claude plugin marketplace update' + 'claude plugin update
#      mefisto --scope user').
#   3. Reescribe .claude/pipeline/.plugin-root a la version mas reciente del cache, para
#      que un pipeline headless que arranque antes del /reload-plugins ya resuelva la
#      version nueva (mismo archivo que escribe el hook SessionStart; reescribirlo aqui
#      es idempotente -- el hook lo reconfirma en el siguiente arranque).
#   4. Imprime el delta de CHANGELOG.md entre la version que esta sesion tenia cargada
#      (antes de este update) y la nueva.
#   5. Reporta que versiones del cache quedaron "podables" (ni la cargada en esta sesion
#      ni la nueva) y, solo con --prune, las borra. La poda NUNCA borra la version
#      cargada en la sesion activa (si un skill se borra a si mismo, la sesion rompe):
#      commands/upgrade.md pide confirmacion explicita al usuario antes de invocar
#      este script con --prune.
#
# La version "cargada en esta sesion" se resuelve de .claude/pipeline/.plugin-root ANTES
# de reescribirlo (paso 3), y se persiste en .claude/pipeline/.plugin-root.previous para
# que una invocacion posterior con --prune (una segunda llamada a este mismo script,
# despues de la confirmacion del usuario) siga viendola aunque el paso 3 de la PRIMERA
# invocacion ya haya movido .plugin-root a la version nueva. Sin este archivo puente, la
# segunda invocacion leeria .plugin-root ya reescrito y podria borrar por error la version
# que la sesion activa todavia tiene cargada en memoria. El archivo puente se borra al
# terminar de podar (o al confirmar que no habia nada que podar).
#
# Uso:
#   scripts/update-plugin.sh           # actualiza, reescribe .plugin-root, reporta podables (no borra)
#   scripts/update-plugin.sh --prune   # ademas borra las versiones podables (solo tras confirmar con el usuario)
set -euo pipefail

# Guard defensivo: este script es del lado publicado y solo aplica al consumidor (MEF-ADR-0019).
_REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git" >&2
    exit 1
}
if [ -f "$_REPO_TOP/.claude-plugin/plugin.json" ]; then
    echo "ERROR: scripts/update-plugin.sh es del plugin publicado y solo aplica al consumidor." >&2
    echo "Mefisto se actualiza a si mismo por su propio flujo de release (/mefisto-release)." >&2
    exit 1
fi
unset _REPO_TOP

usage() {
    echo "Uso: $0 [--prune]" >&2
    echo "  (sin flags)  actualiza marketplace + plugin, reescribe .plugin-root, imprime" >&2
    echo "               el delta de CHANGELOG y reporta versiones podables del cache (sin borrar)." >&2
    echo "  --prune      ademas borra las versiones podables (solo tras confirmar con el usuario, CA-4)." >&2
}

PRUNE=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prune) PRUNE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: argumento desconocido '$1'" >&2; usage; exit 1 ;;
    esac
done

if ! command -v claude >/dev/null 2>&1; then
    echo "ERROR: el CLI 'claude' no esta en el PATH. Requerido para actualizar el plugin." >&2
    exit 1
fi

CACHE_ROOT="$HOME/.claude/plugins/cache"
PLUGIN_ROOT_FILE=".claude/pipeline/.plugin-root"
LOADED_MARKER_FILE=".claude/pipeline/.plugin-root.previous"

# --- Paso 1 (CA-2): detectar el marketplace por glob, sin hardcodear el nombre --------
MEFISTO_CACHE_DIR=$(ls -d "$CACHE_ROOT"/*/mefisto 2>/dev/null | sort | head -1) || true
if [ -z "$MEFISTO_CACHE_DIR" ]; then
    echo "ERROR: no se encontro ningun 'mefisto' en el cache de plugins ($CACHE_ROOT/*/mefisto)." >&2
    echo "       Verifica que el plugin este instalado (claude plugin install mefisto@<marketplace> --scope user)." >&2
    exit 1
fi
MARKETPLACE_NAME=$(basename "$(dirname "$MEFISTO_CACHE_DIR")")

# --- Version cargada en esta sesion (previa al update) --------------------------------
#
# El modo default SIEMPRE lee .plugin-root fresco (nunca un archivo puente viejo: si una
# corrida anterior dejo .plugin-root.previous huerfano porque el usuario declino podar,
# esta es una corrida NUEVA y .plugin-root ya refleja la version real que esta sesion
# tiene cargada) y lo persiste en el archivo puente para que la invocacion --prune de
# este mismo ciclo lo reuse. El modo --prune, en cambio, PRIORIZA el puente: es la
# segunda invocacion del mismo ciclo, y .plugin-root ya fue reescrito a la version nueva
# por la primera invocacion (paso 3 de este script) -- leerlo de nuevo aqui perderia la
# version cargada real y podria borrarla por error.
if [ "$PRUNE" = true ] && [ -f "$LOADED_MARKER_FILE" ]; then
    LOADED_PLUGIN_ROOT=$(cat "$LOADED_MARKER_FILE" 2>/dev/null) || true
else
    LOADED_PLUGIN_ROOT=$(cat "$PLUGIN_ROOT_FILE" 2>/dev/null) || true
    mkdir -p .claude/pipeline
    printf '%s' "$LOADED_PLUGIN_ROOT" > "$LOADED_MARKER_FILE"
fi
LOADED_VERSION=""
[ -n "$LOADED_PLUGIN_ROOT" ] && LOADED_VERSION=$(basename "${LOADED_PLUGIN_ROOT%/}")

echo "Marketplace detectado: $MARKETPLACE_NAME"
if [ -n "$LOADED_VERSION" ]; then
    echo "Version cargada en esta sesion: $LOADED_VERSION"
else
    echo "ADVERTENCIA: no se pudo determinar la version cargada en esta sesion (.plugin-root ausente o vacio)."
fi
echo ""

# --- Paso 2 (CA-2): actualizacion no interactiva ---------------------------------------
echo "Actualizando el catalogo del marketplace ($MARKETPLACE_NAME)..."
claude plugin marketplace update "$MARKETPLACE_NAME"

echo ""
echo "Actualizando el plugin mefisto (scope user)..."
claude plugin update mefisto --scope user
echo ""

# --- Paso 3 (CA-3): version mas reciente del cache tras el update, y .plugin-root -----
NEW_VERSION_DIR=$(ls -d "$MEFISTO_CACHE_DIR"/*/ 2>/dev/null | sort -V | tail -1) || true
if [ -z "$NEW_VERSION_DIR" ]; then
    echo "ERROR: no se encontro ninguna version de mefisto en $MEFISTO_CACHE_DIR tras el update." >&2
    exit 1
fi
NEW_VERSION_DIR="${NEW_VERSION_DIR%/}"
NEW_VERSION=$(basename "$NEW_VERSION_DIR")

mkdir -p .claude/pipeline
printf '%s' "$NEW_VERSION_DIR" > "$PLUGIN_ROOT_FILE"
echo "OK: $PLUGIN_ROOT_FILE -> $NEW_VERSION_DIR"
echo ""

# --- Paso 4 (CA-5): delta de CHANGELOG.md entre la version cargada y la nueva ---------
CHANGELOG_FILE="$NEW_VERSION_DIR/CHANGELOG.md"
if [ "$LOADED_VERSION" = "$NEW_VERSION" ]; then
    echo "Ya estabas en la version mas reciente ($NEW_VERSION); no hay delta que mostrar."
elif [ -n "$LOADED_VERSION" ] && [ -f "$CHANGELOG_FILE" ]; then
    echo "--- Delta de CHANGELOG.md ($LOADED_VERSION -> $NEW_VERSION) ---"
    awk -v old_marker="## [$LOADED_VERSION]" '
        $0 ~ /^## \[/ { started = 1 }
        started && index($0, old_marker) == 1 { exit }
        started { print }
    ' "$CHANGELOG_FILE"
    echo "--- fin del delta ---"
else
    echo "ADVERTENCIA: no se pudo calcular el delta de CHANGELOG (version cargada desconocida o CHANGELOG.md ausente)."
fi
echo ""

# --- Paso 5 (CA-4): poda del cache, conservando {version nueva, version cargada} ------
ALL_VERSIONS=$(ls -d "$MEFISTO_CACHE_DIR"/*/ 2>/dev/null | xargs -n1 basename | sort -V) || true

PRUNABLE=()
while IFS= read -r v; do
    [ -z "$v" ] && continue
    [ "$v" = "$NEW_VERSION" ] && continue
    [ -n "$LOADED_VERSION" ] && [ "$v" = "$LOADED_VERSION" ] && continue
    PRUNABLE+=("$v")
done <<< "$ALL_VERSIONS"

if [ ${#PRUNABLE[@]} -eq 0 ]; then
    echo "Cache limpio: solo quedan la version cargada (${LOADED_VERSION:-desconocida}) y la nueva ($NEW_VERSION)."
    rm -f "$LOADED_MARKER_FILE"
elif [ "$PRUNE" = true ]; then
    echo "Borrando versiones podables del cache (--prune)..."
    for v in "${PRUNABLE[@]}"; do
        rm -rf "${MEFISTO_CACHE_DIR:?}/$v"
        echo "  borrada: $v"
    done
    rm -f "$LOADED_MARKER_FILE"
else
    echo "Versiones podables en el cache (ni la cargada en esta sesion ni la nueva):"
    printf '  - %s\n' "${PRUNABLE[@]}"
    echo ""
    echo "No se borro nada. Pide confirmacion al usuario y, si acepta, vuelve a correr:"
    echo "  $0 --prune"
fi
echo ""

echo "Version destino: $NEW_VERSION."
echo "Corre /reload-plugins (o reinicia la sesion) para activar la version $NEW_VERSION."

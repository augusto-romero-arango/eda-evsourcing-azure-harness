#!/usr/bin/env bash
# onboard-provision-appinsights.sh --- Provision de .mefisto/appinsights.env (issue #2387).
#
# Descubre con 'az' (sesion activa) los nombres de App Insights, Service Bus y
# Function Apps del resource group del entorno y escribe las cinco claves que lee
# appinsights-query.sh (MEF-ADR-0053). El descubrimiento es por tipo de recurso dentro
# del RG, agnostico a naming CAF o legacy (MEF-ADR-0045), igual que purge-store.sh.
#
# Uso: onboard-provision-appinsights.sh [--preview | --apply] [--env <env>]
#          [--appinsights-app <nombre>] [--servicebus-namespace <nombre>]
# (cwd = raiz del consumidor). --preview es el modo por defecto y no escribe.
# --apply nunca sobrescribe un .mefisto/appinsights.env existente.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Uso: $(basename "$0") [--preview | --apply] [--env <env>] [--appinsights-app <nombre>] [--servicebus-namespace <nombre>]" >&2
}

MODE=""
ENVIRONMENT="dev"
AI_FLAG=""
SB_FLAG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --preview|--apply)
            if [ -n "$MODE" ] && [ "$MODE" != "$1" ]; then usage; exit 2; fi
            MODE="$1"; shift ;;
        --env) [ $# -ge 2 ] || { usage; exit 2; }; ENVIRONMENT="$2"; shift 2 ;;
        --appinsights-app) [ $# -ge 2 ] || { usage; exit 2; }; AI_FLAG="$2"; shift 2 ;;
        --servicebus-namespace) [ $# -ge 2 ] || { usage; exit 2; }; SB_FLAG="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: argumento desconocido '$1'" >&2; usage; exit 2 ;;
    esac
done
MODE="${MODE:---preview}"
[ -n "$ENVIRONMENT" ] || { echo "ERROR: --env requiere un valor." >&2; exit 2; }

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git" >&2
    exit 1
}
# Guard defensivo: script del lado publicado, solo aplica al consumidor (MEF-ADR-0019).
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: scripts/onboard-provision-appinsights.sh es del plugin publicado y solo aplica al consumidor." >&2
    exit 1
fi

TARGET="$REPO_ROOT/.mefisto/appinsights.env"
if [ "$MODE" = "--apply" ] && [ -e "$TARGET" ]; then
    echo "ERROR: .mefisto/appinsights.env ya existe; no se sobrescribe." >&2
    echo "       Editalo o borralo a mano y reintenta." >&2
    exit 1
fi

for bin in jq az; do
    command -v "$bin" >/dev/null 2>&1 || {
        echo "ERROR: '$bin' no esta instalado o no esta en el PATH (requerido); no se escribio nada." >&2
        exit 1
    }
done
if ! az account show >/dev/null 2>&1; then
    echo "ERROR: no hay sesion activa de Azure CLI. Ejecuta 'az login' primero; no se escribio nada." >&2
    exit 1
fi

source "$SCRIPT_DIR/_pipeline-common.sh"
load_harness_config >/dev/null || {
    echo "ERROR: el config efectivo no es valido; no se escribio nada." >&2
    exit 1
}

# Misma resolucion que resolve_resource_group de purge-store.sh (duplicada a proposito,
# dos usos: Rule of Three no alcanzada, MEF-ADR-0018).
resolve_resource_group() {
    local candidates=() candidate
    if [ -n "${HARNESS_AZURE_REGION_SHORT:-}" ]; then
        candidates+=("${HARNESS_RG_PREFIX}-${ENVIRONMENT}-${HARNESS_AZURE_REGION_SHORT}-${HARNESS_RESOURCE_SEQUENCE}")
    fi
    candidates+=("${HARNESS_RG_PREFIX}-${ENVIRONMENT}")
    for candidate in "${candidates[@]}"; do
        if az group show --name "$candidate" >/dev/null 2>&1; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

RG_NAME=$(resolve_resource_group) || {
    echo "ERROR: no se encontro el resource group de '$ENVIRONMENT' (probado '${HARNESS_RG_PREFIX}-${ENVIRONMENT}'" >&2
    echo "  ${HARNESS_AZURE_REGION_SHORT:+y su variante con sufijo de region/secuencia }en la suscripcion activa); no se escribio nada." >&2
    exit 1
}

list_by_type() {
    az resource list --resource-group "$RG_NAME" --resource-type "$1" --query "[].name" -o tsv 2>/dev/null | sed '/^$/d' | sort
}

# pick <etiqueta> <flag> <candidatos> <nombre-del-flag>: imprime el elegido o aborta.
pick() {
    local label="$1" flag="$2" candidates="$3" flagname="$4" count
    if [ -z "$candidates" ]; then
        echo "ERROR: no se encontro ningun $label en el resource group '$RG_NAME'; no se escribio nada." >&2
        return 1
    fi
    if [ -n "$flag" ]; then
        if printf '%s\n' "$candidates" | grep -Fxq -- "$flag"; then
            printf '%s' "$flag"
            return 0
        fi
        echo "ERROR: $flagname '$flag' no esta entre los candidatos de $label en '$RG_NAME':" >&2
        printf '%s\n' "$candidates" | sed 's/^/  - /' >&2
        return 1
    fi
    count=$(printf '%s\n' "$candidates" | wc -l | tr -d ' ')
    if [ "$count" -gt 1 ]; then
        echo "ERROR: hay $count candidatos de $label en '$RG_NAME'; indica uno con $flagname <nombre>:" >&2
        printf '%s\n' "$candidates" | sed 's/^/  - /' >&2
        return 1
    fi
    printf '%s' "$candidates"
}

AI_CANDIDATES=$(list_by_type "Microsoft.Insights/components")
SB_CANDIDATES=$(list_by_type "Microsoft.ServiceBus/namespaces")
FUNC_NAMES=$(az resource list --resource-group "$RG_NAME" --resource-type "Microsoft.Web/sites" \
    --query "[?kind && contains(kind, 'functionapp')].name" -o tsv 2>/dev/null | sed '/^$/d' | sort | paste -sd, -)

AI_APP=$(pick "App Insights" "$AI_FLAG" "$AI_CANDIDATES" "--appinsights-app") || exit 1
SB_NS=$(pick "namespace de Service Bus" "$SB_FLAG" "$SB_CANDIDATES" "--servicebus-namespace") || exit 1

CONTENT="# Nombres de recursos Azure para appinsights-query.sh (solo nombres, sin secretos). Generado por /onboard (issue #2387).
APPINSIGHTS_APP=$AI_APP
APPINSIGHTS_RG=$RG_NAME
SERVICEBUS_NAMESPACE=$SB_NS
SERVICEBUS_RG=$RG_NAME
FUNCTIONAPP_NAMES=$FUNC_NAMES"

if [ -z "$FUNC_NAMES" ]; then
    echo "AVISO: no hay Function Apps en '$RG_NAME'; FUNCTIONAPP_NAMES queda vacio (function-errors no funcionara hasta el primer /scaffold)." >&2
fi

echo "Resource group: $RG_NAME"
echo "Contenido de .mefisto/appinsights.env:"
printf '%s\n' "$CONTENT" | grep -v '^#'

if [ "$MODE" = "--preview" ]; then
    echo "Previsualizacion: no se escribio ningun archivo. Usa --apply solo tras la confirmacion explicita de /onboard."
    exit 0
fi

mkdir -p "$REPO_ROOT/.mefisto" || { echo "ERROR: no se pudo crear .mefisto/." >&2; exit 1; }
if ! ( set -o noclobber; printf '%s\n' "$CONTENT" > "$TARGET" ) 2>/dev/null; then
    echo "ERROR: no se pudo crear .mefisto/appinsights.env (ya existe o no es escribible); no se sobrescribe." >&2
    exit 1
fi
echo "OK: .mefisto/appinsights.env creado. Commitealo: contiene solo nombres de recursos, sin secretos."
exit 0

#!/usr/bin/env bash
# _pipeline-common.sh --- Funciones compartidas entre scripts de pipeline
#
# Uso: source "$(dirname "${BASH_SOURCE[0]}")/_pipeline-common.sh"
#
# No invocar directamente (prefijo _ = sourceable).

# load_harness_config [config_path]
#
# Carga la configuracion del harness desde .claude/harness.config.json del
# consumidor y exporta las variables HARNESS_* al entorno. Llamar al inicio
# de cualquier script de pipeline que necesite los tokens del proyecto.
#
# Variables exportadas:
#   HARNESS_PROJECT_NAME       - Nombre legible del proyecto (ej: ControlAsistencias)
#   HARNESS_NAMESPACE_PREFIX   - Prefijo de namespace .NET (ej: Bitakora.ControlAsistencia)
#   HARNESS_SOLUTION_FILE      - Nombre del archivo .slnx (ej: ControlAsistencias.slnx)
#   HARNESS_RG_PREFIX          - Prefijo del Resource Group de Azure (ej: rg-controlasistencias)
#   HARNESS_TFSTATE_STORAGE    - Storage account para tfstate (ej: stcatfstatedev)
#   HARNESS_SP_NAME            - Service Principal de GitHub Actions (ej: github-controlasistencias-ci)
#   HARNESS_APP_INSIGHTS_APP   - Application Insights component (ej: controlasistencias-dev-ai)
#   HARNESS_DOMAIN_LABELS      - Lista separada por espacios de labels dom:*
#
# Si no existe el config file, emite mensaje claro de error y retorna 1.
load_harness_config() {
    local config="${1:-.claude/harness.config.json}"

    if [ ! -f "$config" ]; then
        echo "ERROR: no se encontro $config" >&2
        echo "  El harness requiere un archivo .claude/harness.config.json en la raiz" >&2
        echo "  del proyecto consumidor con la forma:" >&2
        echo "    {" >&2
        echo "      \"projectName\": \"...\"," >&2
        echo "      \"namespacePrefix\": \"...\"," >&2
        echo "      \"solutionFile\": \"...\"," >&2
        echo "      \"infraResourceGroupPrefix\": \"...\"," >&2
        echo "      \"githubServicePrincipalName\": \"...\"," >&2
        echo "      \"appInsightsApp\": \"...\"," >&2
        echo "      \"domainLabels\": [\"...\", \"...\"]" >&2
        echo "    }" >&2
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: jq no esta instalado. Requerido para parsear $config" >&2
        return 1
    fi

    export HARNESS_PROJECT_NAME=$(jq -r '.projectName // ""' "$config")
    export HARNESS_NAMESPACE_PREFIX=$(jq -r '.namespacePrefix // ""' "$config")
    export HARNESS_SOLUTION_FILE=$(jq -r '.solutionFile // ""' "$config")
    export HARNESS_RG_PREFIX=$(jq -r '.infraResourceGroupPrefix // ""' "$config")
    export HARNESS_TFSTATE_STORAGE=$(jq -r '.terraformStateStorage // ""' "$config")
    export HARNESS_SP_NAME=$(jq -r '.githubServicePrincipalName // ""' "$config")
    export HARNESS_APP_INSIGHTS_APP=$(jq -r '.appInsightsApp // ""' "$config")
    export HARNESS_DOMAIN_LABELS=$(jq -r '.domainLabels // [] | join(" ")' "$config")

    local missing=()
    [ -z "$HARNESS_PROJECT_NAME" ]     && missing+=("projectName")
    [ -z "$HARNESS_NAMESPACE_PREFIX" ] && missing+=("namespacePrefix")
    [ -z "$HARNESS_SOLUTION_FILE" ]    && missing+=("solutionFile")

    if [ ${#missing[@]} -gt 0 ]; then
        echo "ERROR: campos obligatorios ausentes en $config: ${missing[*]}" >&2
        return 1
    fi
}

# resolve_pipeline <issue_num> [override]
#
# Retorna la ruta del script de pipeline a usar para un issue dado.
# - Sin override: consulta labels del issue via gh y enruta automaticamente
# - Con override "tdd" o "tooling": retorna el pipeline forzado sin consultar labels
# - Issues tipo:infra retornan "SKIP:infra"
# - Issues sin label tipo:* retornan "SKIP:no-tipo"
resolve_pipeline() {
    local issue="$1"
    local override="${2:-}"

    if [ -n "$override" ]; then
        case "$override" in
            tdd)     echo "./scripts/tdd-pipeline.sh" ;;
            tooling) echo "./scripts/tooling-pipeline.sh" ;;
            *)       echo "ERROR: override desconocido '$override'" >&2; return 1 ;;
        esac
        return
    fi

    local labels
    labels=$(gh issue view "$issue" --json labels -q '.labels[].name' 2>/dev/null)

    _resolve_from_labels "$labels"
}

# _resolve_from_labels <labels_text>
# Funcion interna: determina el pipeline a partir de texto de labels (una por linea).
_resolve_from_labels() {
    local labels="$1"
    if echo "$labels" | grep -qE '^tipo:(feature|refactor)$'; then
        echo "./scripts/tdd-pipeline.sh"
    elif echo "$labels" | grep -q '^tipo:tooling$'; then
        echo "./scripts/tooling-pipeline.sh"
    elif echo "$labels" | grep -q '^tipo:infra$'; then
        echo "SKIP:infra"
    else
        echo "SKIP:no-tipo"
    fi
}

# resolve_pipeline_with_state <issue_num> [override]
#
# Retorna "STATE|PIPELINE" en una sola linea (ej: "OPEN|./scripts/tdd-pipeline.sh").
# Combina la consulta de estado y labels en una sola llamada a gh, reduciendo API calls.
resolve_pipeline_with_state() {
    local issue="$1"
    local override="${2:-}"

    local state_and_labels
    state_and_labels=$(gh issue view "$issue" --json state,labels \
        -q '"\(.state)|\(.labels | map(.name) | join("\n"))"' 2>/dev/null) || {
        echo "UNKNOWN|SKIP:no-tipo"
        return
    }

    local state="${state_and_labels%%|*}"
    local labels="${state_and_labels#*|}"

    if [ -n "$override" ]; then
        case "$override" in
            tdd)     echo "$state|./scripts/tdd-pipeline.sh" ;;
            tooling) echo "$state|./scripts/tooling-pipeline.sh" ;;
            *)       echo "ERROR: override desconocido '$override'" >&2; return 1 ;;
        esac
        return
    fi

    local pipeline
    pipeline=$(_resolve_from_labels "$labels")
    echo "$state|$pipeline"
}

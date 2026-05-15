#!/usr/bin/env bash
# appinsights-query.sh - Consultas KQL predefinidas contra Application Insights
#
# Uso:
#   ./scripts/appinsights-query.sh exceptions
#   ./scripts/appinsights-query.sh dead-letters
#   ./scripts/appinsights-query.sh function-errors
#   ./scripts/appinsights-query.sh traces --filter "NullReferenceException"
#   ./scripts/appinsights-query.sh health-summary
#   ./scripts/appinsights-query.sh exceptions --hours 48
#
# Requiere: az cli con sesion activa (az login)
# Configuracion: scripts/.env (ver scripts/.env.template)

set -euo pipefail

# --- Colores -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Logging -----------------------------------------------------------------
log()     { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"; }
success() { echo -e "${GREEN}${BOLD}ok${NC} $1"; }
warn()    { echo -e "${YELLOW}!${NC} $1"; }
error()   { echo -e "${RED}${BOLD}ERROR:${NC} $1" >&2; }

# --- Configuracion -----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [ -f "$ENV_FILE" ]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
else
    error "No se encontro $ENV_FILE"
    echo "  Copia el template y completa los valores:"
    echo "    cp scripts/.env.template scripts/.env"
    exit 1
fi

# --- Verificar az login ------------------------------------------------------
if ! az account show &>/dev/null; then
    error "No hay sesion activa de Azure CLI. Ejecuta 'az login' primero."
    exit 1
fi

# --- Parametros --------------------------------------------------------------
COMMAND="${1:-}"
HOURS=24
FILTER=""
MAX_ROWS=50

if [ -z "$COMMAND" ]; then
    echo -e "${CYAN}${BOLD}appinsights-query.sh${NC} - Consultas KQL contra App Insights"
    echo ""
    echo "Comandos KQL (App Insights):"
    echo "  exceptions         Top 20 excepciones agrupadas por tipo y mensaje"
    echo "  dead-letters       Mensajes dead-lettered en traces"
    echo "  function-errors    Funciones con requests fallidas"
    echo "  traces             Traces (usar con --filter para filtrar)"
    echo "  health-summary     Vista rapida: excepciones + requests fallidas + disponibilidad"
    echo ""
    echo "Comandos ad-hoc:"
    echo "  custom \"QUERY\"    Query KQL ad-hoc con guardrails (take 20, ventana 1h)"
    echo "                     Ej: custom \"exceptions | where type has 'NullRef' | take 5\""
    echo ""
    echo "Comandos Azure Resource Manager:"
    echo "  servicebus-dlq     Conteo de dead letters por subscription en Service Bus"
    echo "  servicebus-dlq-peek  Peek a mensajes en DLQ sin consumirlos (max 5)"
    echo "  function-status    Estado y funciones registradas de cada Function App"
    echo ""
    echo "Opciones:"
    echo "  --hours N          Ventana temporal en horas (default: 24, solo KQL)"
    echo "  --filter TEXT      Filtrar por texto (solo para 'traces')"
    exit 1
fi

shift

# Capturar argumento posicional para el comando custom
CUSTOM_ARG=""
if [ "$COMMAND" = "custom" ] && [[ $# -gt 0 ]] && [[ "$1" != --* ]]; then
    CUSTOM_ARG="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hours)
            if [[ -z "${2:-}" ]]; then
                error "--hours requiere un valor numerico"
                exit 1
            fi
            HOURS="$2"
            shift 2
            ;;
        --filter)
            if [[ -z "${2:-}" ]]; then
                error "--filter requiere un valor de texto"
                exit 1
            fi
            FILTER="$2"
            shift 2
            ;;
        *)
            error "Opcion desconocida: $1"
            exit 1
            ;;
    esac
done

# --- Ejecutar query ----------------------------------------------------------
run_query() {
    local query="$1"
    local description="$2"

    if [ -z "${APPINSIGHTS_APP:-}" ]; then
        error "Variable APPINSIGHTS_APP no definida en $ENV_FILE"
        exit 1
    fi
    if [ -z "${APPINSIGHTS_RG:-}" ]; then
        error "Variable APPINSIGHTS_RG no definida en $ENV_FILE"
        exit 1
    fi

    log "$description (ultimas ${HOURS}h)"

    local result
    if ! result=$(az monitor app-insights query \
        --app "$APPINSIGHTS_APP" \
        --resource-group "$APPINSIGHTS_RG" \
        --analytics-query "$query" \
        --output table 2>&1); then
        error "Fallo la consulta KQL"
        echo "$result" >&2
        exit 1
    fi

    echo "$result"
    success "Consulta completada"
}

# --- Queries KQL predefinidas ------------------------------------------------

# Sanitizar filtro para uso seguro en KQL (escapar comillas simples)
sanitize_kql_filter() {
    echo "${1//\'/\\\'}"
}

case "$COMMAND" in
    exceptions)
        run_query \
            "exceptions | where timestamp > ago(${HOURS}h) | summarize count() by type, outerMessage | order by count_ desc | take 20" \
            "Top 20 excepciones agrupadas por tipo y mensaje"
        ;;

    dead-letters)
        run_query \
            "traces | where timestamp > ago(${HOURS}h) | where message has 'dead' or message has 'deadletter' or message has 'Dead' | project timestamp, message, operation_Name | order by timestamp desc | take ${MAX_ROWS}" \
            "Mensajes dead-lettered en traces"
        ;;

    function-errors)
        run_query \
            "requests | where timestamp > ago(${HOURS}h) | where success == false | summarize failedCount=count() by name, resultCode | order by failedCount desc | take ${MAX_ROWS}" \
            "Funciones con requests fallidas"
        ;;

    traces)
        if [ -n "$FILTER" ]; then
            SAFE_FILTER=$(sanitize_kql_filter "$FILTER")
            run_query \
                "traces | where timestamp > ago(${HOURS}h) | where message has '${SAFE_FILTER}' | project timestamp, message, severityLevel, operation_Name | order by timestamp desc | take ${MAX_ROWS}" \
                "Traces filtradas por '${FILTER}'"
        else
            run_query \
                "traces | where timestamp > ago(${HOURS}h) | project timestamp, message, severityLevel, operation_Name | order by timestamp desc | take ${MAX_ROWS}" \
                "Todas las traces"
        fi
        ;;

    health-summary)
        log "Health summary (ultimas ${HOURS}h)"

        echo -e "\n${CYAN}${BOLD}--- Excepciones ---${NC}"
        run_query \
            "exceptions | where timestamp > ago(${HOURS}h) | summarize totalExceptions=count(), distinctTypes=dcount(type) | project totalExceptions, distinctTypes" \
            "Resumen de excepciones"

        echo -e "\n${CYAN}${BOLD}--- Requests fallidas ---${NC}"
        run_query \
            "requests | where timestamp > ago(${HOURS}h) | summarize totalRequests=count(), failedRequests=countif(success == false), availabilityPct=round(100.0 * countif(success == true) / count(), 2)" \
            "Resumen de requests"

        echo -e "\n${CYAN}${BOLD}--- Top 5 errores ---${NC}"
        run_query \
            "exceptions | where timestamp > ago(${HOURS}h) | summarize count() by type | order by count_ desc | take 5" \
            "Top 5 tipos de error"

        success "Health summary completado"
        ;;

    servicebus-dlq)
        if [ -z "${SERVICEBUS_NAMESPACE:-}" ]; then
            error "Variable SERVICEBUS_NAMESPACE no definida en $ENV_FILE"
            echo "  Agrega SERVICEBUS_NAMESPACE al archivo $ENV_FILE (ver .env.template)"
            exit 1
        fi
        if [ -z "${SERVICEBUS_RG:-}" ]; then
            error "Variable SERVICEBUS_RG no definida en $ENV_FILE"
            echo "  Agrega SERVICEBUS_RG al archivo $ENV_FILE (ver .env.template)"
            exit 1
        fi

        log "Conteo de dead letters en Service Bus namespace: $SERVICEBUS_NAMESPACE"

        topics=$(az servicebus topic list \
            --namespace-name "$SERVICEBUS_NAMESPACE" \
            --resource-group "$SERVICEBUS_RG" \
            --query "[].name" -o tsv 2>&1) || {
            error "Fallo al listar topics de Service Bus"
            echo "$topics" >&2
            exit 1
        }

        if [ -z "$topics" ]; then
            warn "No se encontraron topics en el namespace $SERVICEBUS_NAMESPACE"
        else
            for topic in $topics; do
                subs=$(az servicebus topic subscription list \
                    --namespace-name "$SERVICEBUS_NAMESPACE" \
                    --resource-group "$SERVICEBUS_RG" \
                    --topic-name "$topic" \
                    --query "[].name" -o tsv 2>&1) || {
                    warn "Fallo al listar subscriptions del topic $topic"
                    continue
                }

                for sub in $subs; do
                    dlq_count=$(az servicebus topic subscription show \
                        --namespace-name "$SERVICEBUS_NAMESPACE" \
                        --resource-group "$SERVICEBUS_RG" \
                        --topic-name "$topic" \
                        --name "$sub" \
                        --query "countDetails.deadLetterMessageCount" -o tsv 2>&1) || {
                        warn "Fallo al consultar subscription $topic/$sub"
                        continue
                    }

                    if [ "${dlq_count:-0}" -gt 0 ] 2>/dev/null; then
                        echo -e "${RED}${BOLD}DLQ${NC} $topic/$sub: ${RED}$dlq_count${NC} mensajes"
                    else
                        echo -e "${GREEN}ok${NC}  $topic/$sub: $dlq_count mensajes"
                    fi
                done
            done
        fi

        success "Consulta de dead letters completada"
        ;;

    servicebus-dlq-peek)
        if [ -z "${SERVICEBUS_NAMESPACE:-}" ]; then
            error "Variable SERVICEBUS_NAMESPACE no definida en $ENV_FILE"
            echo "  Agrega SERVICEBUS_NAMESPACE al archivo $ENV_FILE (ver .env.template)"
            exit 1
        fi
        if [ -z "${SERVICEBUS_RG:-}" ]; then
            error "Variable SERVICEBUS_RG no definida en $ENV_FILE"
            echo "  Agrega SERVICEBUS_RG al archivo $ENV_FILE (ver .env.template)"
            exit 1
        fi

        log "Peek a dead letters en Service Bus namespace: $SERVICEBUS_NAMESPACE"

        topics=$(az servicebus topic list \
            --namespace-name "$SERVICEBUS_NAMESPACE" \
            --resource-group "$SERVICEBUS_RG" \
            --query "[].name" -o tsv 2>&1) || {
            error "Fallo al listar topics de Service Bus"
            echo "$topics" >&2
            exit 1
        }

        if [ -z "$topics" ]; then
            warn "No se encontraron topics en el namespace $SERVICEBUS_NAMESPACE"
        else
            for topic in $topics; do
                subs=$(az servicebus topic subscription list \
                    --namespace-name "$SERVICEBUS_NAMESPACE" \
                    --resource-group "$SERVICEBUS_RG" \
                    --topic-name "$topic" \
                    --query "[].name" -o tsv 2>&1) || {
                    warn "Fallo al listar subscriptions del topic $topic"
                    continue
                }

                for sub in $subs; do
                    echo -e "\n${CYAN}${BOLD}--- $topic/$sub/\$deadletterqueue ---${NC}"
                    messages=$(az servicebus topic subscription receive \
                        --namespace-name "$SERVICEBUS_NAMESPACE" \
                        --resource-group "$SERVICEBUS_RG" \
                        --topic-name "$topic" \
                        --subscription-name "$sub" \
                        --is-dead-letter-queue true \
                        --peek-lock \
                        --max-messages 5 \
                        --output json 2>&1) || {
                        warn "Fallo al hacer peek en $topic/$sub DLQ"
                        continue
                    }

                    msg_count=$(echo "$messages" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
                    if [ "$msg_count" = "0" ]; then
                        echo "  (vacio)"
                    else
                        echo "$messages" | python3 -c "
import sys, json
msgs = json.load(sys.stdin)
for i, m in enumerate(msgs):
    body = m.get('body', '(sin body)')
    props = m.get('applicationProperties', {})
    reason = m.get('deadLetterReason', '(sin razon)')
    print(f'  [{i+1}] reason={reason}')
    if props:
        print(f'      props={json.dumps(props, ensure_ascii=False)}')
    body_str = body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)
    if len(body_str) > 200:
        body_str = body_str[:200] + '...'
    print(f'      body={body_str}')
" 2>/dev/null || echo "$messages"
                    fi
                done
            done
        fi

        success "Peek de dead letters completado"
        ;;

    function-status)
        if [ -z "${FUNCTIONAPP_NAMES:-}" ]; then
            error "Variable FUNCTIONAPP_NAMES no definida en $ENV_FILE"
            echo "  Agrega FUNCTIONAPP_NAMES al archivo $ENV_FILE (ver .env.template)"
            exit 1
        fi
        if [ -z "${APPINSIGHTS_RG:-}" ]; then
            error "Variable APPINSIGHTS_RG no definida en $ENV_FILE (usada como resource group de las Function Apps)"
            echo "  Agrega APPINSIGHTS_RG al archivo $ENV_FILE (ver .env.template)"
            exit 1
        fi

        log "Estado de Azure Functions"

        IFS=',' read -ra APPS <<< "$FUNCTIONAPP_NAMES"
        for app_name in "${APPS[@]}"; do
            app_name=$(echo "$app_name" | xargs)  # trim whitespace
            echo -e "\n${CYAN}${BOLD}--- $app_name ---${NC}"

            status=$(az functionapp show \
                --name "$app_name" \
                --resource-group "${APPINSIGHTS_RG}" \
                --query "{state:state, defaultHostName:defaultHostName, kind:kind}" \
                --output json 2>&1) || {
                warn "Fallo al consultar Function App $app_name"
                echo "$status" >&2
                continue
            }

            state=$(echo "$status" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state','unknown'))" 2>/dev/null || echo "unknown")
            if [ "$state" = "Running" ]; then
                echo -e "  Estado: ${GREEN}${BOLD}$state${NC}"
            else
                echo -e "  Estado: ${RED}${BOLD}$state${NC}"
            fi

            functions=$(az functionapp function list \
                --name "$app_name" \
                --resource-group "${APPINSIGHTS_RG}" \
                --query "[].{name:name, isDisabled:isDisabled}" \
                --output json 2>&1) || {
                warn "Fallo al listar funciones de $app_name"
                continue
            }

            func_count=$(echo "$functions" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
            echo "  Funciones registradas: $func_count"

            if [ "$func_count" != "0" ]; then
                echo "$functions" | python3 -c "
import sys, json
funcs = json.load(sys.stdin)
for f in funcs:
    name = f.get('name', '?').split('/')[-1]
    disabled = f.get('isDisabled', False)
    status = 'DISABLED' if disabled else 'ok'
    print(f'    - {name} ({status})')
" 2>/dev/null || echo "$functions"
            fi
        done

        success "Consulta de estado de Functions completada"
        ;;

    custom)
        CUSTOM_QUERY="$CUSTOM_ARG"
        if [ -z "$CUSTOM_QUERY" ]; then
            error "El comando 'custom' requiere una query KQL como argumento"
            echo "  Ejemplo: ./scripts/appinsights-query.sh custom \"exceptions | where type has 'NullRef' | take 5\""
            exit 1
        fi

        # Advertencia de daily cap en stderr
        echo -e "${YELLOW}ADVERTENCIA: query ad-hoc. Daily cap: 0.5GB. Respeta el daily cap configurado por el proyecto consumidor (ver su ADR de control de costos de App Insights).${NC}" >&2

        # Guardrail: inyectar ventana temporal si no contiene ago(
        if ! echo "$CUSTOM_QUERY" | grep -qi 'ago('; then
            if echo "$CUSTOM_QUERY" | grep -q '|'; then
                # Insertar despues del primer pipe: "tabla | where timestamp > ago(1h) | resto"
                CUSTOM_QUERY=$(echo "$CUSTOM_QUERY" | sed 's/|/| where timestamp > ago(1h) |/')
            else
                # Query sin pipes (ej: "exceptions"): agregar filtro al final
                CUSTOM_QUERY="$CUSTOM_QUERY | where timestamp > ago(1h)"
            fi
        fi

        # Guardrail: inyectar take si no contiene take
        if ! echo "$CUSTOM_QUERY" | grep -qi 'take'; then
            CUSTOM_QUERY="$CUSTOM_QUERY | take 20"
        fi

        # Audit log
        AUDIT_LOG="$SCRIPT_DIR/.kql-audit.log"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] QUERY: $CUSTOM_QUERY" >> "$AUDIT_LOG"

        HOURS=1  # Reflejar la ventana real en el log de run_query
        run_query "$CUSTOM_QUERY" "Query ad-hoc"
        ;;

    *)
        error "Comando desconocido: $COMMAND"
        echo "Ejecuta sin argumentos para ver los comandos disponibles."
        exit 1
        ;;
esac

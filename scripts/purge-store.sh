#!/usr/bin/env bash
# purge-store.sh -- purga determinista del store de un dominio en dev (issue #725).
#
# Mitad determinista del mecanismo de purga que MEF-ADR-0036 seccion 5 prescribe
# como operacion manual del experto: dado que la purga pertenece al mismo
# despliegue que un movimiento/renombrado de eventos persistidos, este script
# ejecuta esa purga con guardas codificadas (no sujetas al juicio de un LLM). La
# mitad agentica (diagnostico, confirmacion humana, validacion) es el skill
# /purge-store del issue dependiente -- este script tiene valor por si solo: el
# experto puede correrlo a mano hoy.
#
# Cero tokens nuevos en harness.config.json: el secreto de conexion es siempre
# 'marten-connection' (MEF-ADR-0025), el schema es el dominio en snake_case
# (mismo schema write/read-side, MEF-ADR-0003/MEF-ADR-0034), y server Postgres /
# Key Vault / Container App del worker / Function App del dominio se descubren
# via 'az resource list' en el resource group -- agnostico a que el consumidor
# haya adoptado el naming CAF con {region}-{seq} (MEF-ADR-0045) o el legacy sin
# el.
#
# Uso:
#   scripts/purge-store.sh --domain <dominio> [--env dev] [--dry-run]
#
#   <dominio>    dominio a purgar; debe estar declarado en domainLabels de
#                .claude/harness.config.json (acepta kebab o PascalCase)
#   --env        ambiente objetivo. Unico valor aceptado: 'dev' (default) --
#                guarda anti-prod codificada (CA-1): cualquier otro valor
#                aborta antes de tocar Azure.
#   --dry-run    reporta que se perderia (streams, tablas de read model,
#                checkpoints del daemon) sin ejecutar ningun paso destructivo.
#
# Ejemplo:
#   scripts/purge-store.sh --domain calculo-horas --dry-run
#   scripts/purge-store.sh --domain calculo-horas
#
# Requiere: az cli con sesion activa (az login), jq, psql, curl.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_pipeline-common.sh"

# Guard defensivo: este script es del lado publicado y solo aplica al consumidor (MEF-ADR-0019).
_REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git" >&2
    exit 1
}
if [ -f "$_REPO_TOP/.claude-plugin/plugin.json" ]; then
    echo "ERROR: scripts/purge-store.sh es del plugin publicado y solo aplica al consumidor." >&2
    echo "Mefisto no tiene harness.config.json ni un store desplegado que purgar." >&2
    exit 1
fi
unset _REPO_TOP

usage() {
    echo "Uso: $0 --domain <dominio> [--env dev] [--dry-run]" >&2
    echo "Ejemplo: $0 --domain calculo-horas --dry-run" >&2
}

DOMAIN=""
ENVIRONMENT="dev"
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        --domain)
            DOMAIN="${2:-}"
            shift 2
            ;;
        --env)
            ENVIRONMENT="${2:-}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: argumento desconocido '$1'" >&2
            usage
            exit 1
            ;;
    esac
done

if [ -z "$DOMAIN" ]; then
    echo "ERROR: falta --domain <dominio>." >&2
    usage
    exit 1
fi

# CA-1: guarda anti-prod codificada. Se evalua ANTES de cualquier llamada a Azure
# o de cargar el config -- "aborta con mensaje explicito antes de tocar nada".
if [ "$ENVIRONMENT" != "dev" ]; then
    echo "ERROR: guarda anti-prod (CA-1, MEF-ADR-0036 seccion 5): este script solo opera" >&2
    echo "  sobre el entorno 'dev'. Recibido: '$ENVIRONMENT'." >&2
    echo "  Purgar cualquier otro entorno esta deliberadamente fuera de alcance de este script." >&2
    exit 1
fi

for bin in az jq psql curl; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "ERROR: '$bin' no esta instalado o no esta en el PATH (requerido)." >&2
        exit 1
    fi
done

if ! az account show >/dev/null 2>&1; then
    echo "ERROR: no hay sesion activa de Azure CLI. Ejecuta 'az login' primero." >&2
    exit 1
fi

load_harness_config || exit 1

# --- Validar dominio contra domainLabels (CA-2) -------------------------------
#
# HARNESS_DOMAIN_LABELS ya son slugs kebab-case (los mismos que alimentan el
# label 'dom:X' de GitHub). Acepta --domain en kebab o PascalCase (mismo criterio
# que seed-secret.sh) comparando formas 'aplanadas', pero la forma canonica que
# el resto del script usa (para el schema y el match del Function App) es SIEMPRE
# la que ya esta declarada en domainLabels, nunca la que tecleo el operador.
flatten() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '-'; }

DOMAIN_FLAT=$(flatten "$DOMAIN")
DOMAIN_KEBAB=""
for label in $HARNESS_DOMAIN_LABELS; do
    if [ "$(flatten "$label")" = "$DOMAIN_FLAT" ]; then
        DOMAIN_KEBAB="$label"
        break
    fi
done

if [ -z "$DOMAIN_KEBAB" ]; then
    echo "ERROR: el dominio '$DOMAIN' no esta declarado en domainLabels de .claude/harness.config.json." >&2
    echo "  Dominios declarados: $HARNESS_DOMAIN_LABELS" >&2
    exit 1
fi

# Mismo valor que 'DatabaseSchemaName = "{snake_case}"' en el scaffold del
# dominio (agents/domain-scaffolder.md) -- mismo schema write/read-side
# (MEF-ADR-0003/MEF-ADR-0034 seccion 2).
SCHEMA=$(printf '%s' "$DOMAIN_KEBAB" | tr '-' '_')

# --- Resolver el resource group (CA-1/CA-2) -----------------------------------
#
# Prueba primero el patron CAF con {region}-{seq} (MEF-ADR-0045, si el
# consumidor declaro azureRegionShort) y cae al patron legacy sin sufijo --
# agnostico a cual de los dos adopto el consumidor, sin acoplarse a un unico
# nombre literal.
resolve_resource_group() {
    local candidates=() candidate
    if [ -n "$HARNESS_AZURE_REGION_SHORT" ]; then
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
    echo "  ${HARNESS_AZURE_REGION_SHORT:+y su variante con sufijo de region/secuencia }en la suscripcion activa)." >&2
    echo "  Verifica 'az account show' y que la infraestructura de $ENVIRONMENT ya este desplegada." >&2
    exit 1
}

echo "Resource group: $RG_NAME"

# --- Descubrir recursos via 'az resource list' (CA-2) -------------------------
#
# Ningun nombre de recurso se asume por patron: se descubre por tipo dentro del
# RG, agnostico a naming CAF o legacy (MEF-ADR-0045).
PG_SERVER=$(az resource list --resource-group "$RG_NAME" \
    --resource-type "Microsoft.DBforPostgreSQL/flexibleServers" \
    --query "[0].name" -o tsv 2>/dev/null) || PG_SERVER=""
KV_NAME=$(az resource list --resource-group "$RG_NAME" \
    --resource-type "Microsoft.KeyVault/vaults" \
    --query "[0].name" -o tsv 2>/dev/null) || KV_NAME=""
FUNC_ALL=$(az resource list --resource-group "$RG_NAME" \
    --resource-type "Microsoft.Web/sites" \
    --query "[?kind && contains(kind, 'functionapp')].name" -o tsv 2>/dev/null) || FUNC_ALL=""

# El prefijo exacto 'func-{dominio}-' (el dominio es el {uso} del patron CAF,
# MEF-ADR-0045) desambigua; el patron laxo queda como fallback del naming legacy.
# Un dominio que es sufijo de otro ('horas' dentro de 'calculo-horas') matchea el
# laxo, y este script reinicia lo que matchea: ante mas de un candidato aborta en
# vez de elegir el primero en silencio.
FUNC_MATCHES=$(printf '%s\n' "$FUNC_ALL" | grep -E "^func-${DOMAIN_KEBAB}-" || true)
if [ -z "$FUNC_MATCHES" ]; then
    FUNC_MATCHES=$(printf '%s\n' "$FUNC_ALL" | grep -E "(^|-)${DOMAIN_KEBAB}(-|$)" || true)
fi
FUNC_NAME=$(printf '%s\n' "$FUNC_MATCHES" | head -1)

# El worker de proyecciones (Container App) solo es exigible si el BC lo adopto
# (token opt-in projections.enabled, MEF-ADR-0034) -- ausente/false no es un
# recurso faltante, es un worker que este BC nunca desplego.
#
# La revision activa se resuelve aqui, no en el paso de reinicio: 'az containerapp'
# vive en una extension de la CLI, y descubrir su ausencia (o la falta de permisos)
# despues del DROP dejaria el store purgado y el worker sin reiniciar, con el
# schema recreandose bajo un daemon que sigue en la revision vieja.
CA_NAME=""
ACTIVE_REVISION=""
if [ "$HARNESS_PROJECTIONS_ENABLED" = "true" ]; then
    CA_NAME=$(az resource list --resource-group "$RG_NAME" \
        --resource-type "Microsoft.App/containerApps" \
        --query "[?contains(name, 'projections')].name | [0]" -o tsv 2>/dev/null) || CA_NAME=""
    if [ -n "$CA_NAME" ]; then
        ACTIVE_REVISION=$(az containerapp revision list --name "$CA_NAME" --resource-group "$RG_NAME" \
            --query "[?properties.active] | [0].name" -o tsv 2>/dev/null) || ACTIVE_REVISION=""
    fi
fi

MISSING=()
[ -z "$PG_SERVER" ] && MISSING+=("servidor PostgreSQL (Microsoft.DBforPostgreSQL/flexibleServers)")
[ -z "$KV_NAME" ] && MISSING+=("Key Vault (Microsoft.KeyVault/vaults)")
[ -z "$FUNC_NAME" ] && MISSING+=("Function App del dominio '$DOMAIN_KEBAB' (Microsoft.Web/sites)")
if [ "$HARNESS_PROJECTIONS_ENABLED" = "true" ]; then
    if [ -z "$CA_NAME" ]; then
        MISSING+=("Container App del worker de proyecciones (Microsoft.App/containerApps, projections.enabled=true)")
    elif [ -z "$ACTIVE_REVISION" ]; then
        MISSING+=("revision activa de '$CA_NAME' (revisa 'az extension add --name containerapp' y tus permisos sobre el Container App)")
    fi
fi

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "ERROR: no se encontraron los siguientes recursos en el resource group '$RG_NAME':" >&2
    printf '  - %s\n' "${MISSING[@]}" >&2
    exit 1
fi

FUNC_MATCH_COUNT=$(printf '%s\n' "$FUNC_MATCHES" | wc -l | tr -d ' ')
if [ "$FUNC_MATCH_COUNT" -gt 1 ]; then
    echo "ERROR: el dominio '$DOMAIN_KEBAB' matchea mas de una Function App en '$RG_NAME':" >&2
    printf '  - %s\n' $FUNC_MATCHES >&2
    echo "  Ambiguo: este script reiniciaria la equivocada. Renombra o desambigua antes de purgar." >&2
    exit 1
fi

echo "Postgres: $PG_SERVER | Key Vault: $KV_NAME | Function App: $FUNC_NAME${CA_NAME:+ | Worker: $CA_NAME}"

# --- Firewall temporal (CA-4) --------------------------------------------------
#
# La regla de firewall de Azure PostgreSQL solo acepta IPv4: un cuerpo HTML de
# error o una respuesta IPv6 se descarta aqui en vez de llegar a 'az' como un
# --start-ip-address invalido.
detect_operator_ip() {
    local endpoint ip
    for endpoint in https://ifconfig.me/ip https://api.ipify.org; do
        ip=$(curl -fsS --max-time 10 "$endpoint" 2>/dev/null | tr -d '[:space:]') || ip=""
        if printf '%s' "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

OPERATOR_IP=$(detect_operator_ip) || {
    echo "ERROR: no se pudo determinar la IPv4 publica del operador (necesaria para la regla de firewall temporal)." >&2
    exit 1
}

FW_RULE_NAME="purge-store-temp-$$"
FIREWALL_OPENED=false

cleanup_firewall() {
    if [ "$FIREWALL_OPENED" = true ]; then
        az postgres flexible-server firewall-rule delete \
            --resource-group "$RG_NAME" --name "$PG_SERVER" \
            --rule-name "$FW_RULE_NAME" --yes >/dev/null 2>&1 || true
    fi
}
# EXIT no corre cuando la shell muere por una senal no atrapada, y un Ctrl-C a
# mitad de la purga es justo el caso que CA-4 cubre: INT/TERM se enrutan al mismo
# trap via exit.
trap cleanup_firewall EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Abriendo regla de firewall temporal para $OPERATOR_IP..."
az postgres flexible-server firewall-rule create \
    --resource-group "$RG_NAME" --name "$PG_SERVER" \
    --rule-name "$FW_RULE_NAME" \
    --start-ip-address "$OPERATOR_IP" --end-ip-address "$OPERATOR_IP" >/dev/null
FIREWALL_OPENED=true

# --- Leer 'marten-connection' de Key Vault sin exponerlo (CA-3) ---------------
MARTEN_CONNECTION=$(az keyvault secret show --vault-name "$KV_NAME" --name marten-connection --query value -o tsv)

# Formato Npgsql/EF ('Host=...;Database=...;Username=...;Password=...;SSL Mode=...'),
# el mismo que compone infra-base-scaffolder al sembrar el secreto. Se parsea a
# variables PG* de libpq -- PGPASSWORD nunca se interpola en un comando ni se
# imprime, psql la toma del entorno.
PGHOST=""
PGPORT=""
PGDATABASE=""
PGUSER=""
PGPASSWORD=""
PGSSLMODE_VALUE="require"

# El troceo es puro expansion de parametros: un here-string ('<<<') materializaria
# el secreto en un archivo temporal de $TMPDIR, que CA-3 proscribe.
CONN_REST="$MARTEN_CONNECTION"
while [ -n "$CONN_REST" ]; do
    part="${CONN_REST%%;*}"
    if [ "$part" = "$CONN_REST" ]; then
        CONN_REST=""
    else
        CONN_REST="${CONN_REST#*;}"
    fi
    [ -n "$part" ] || continue
    key="${part%%=*}"
    value="${part#*=}"
    key_lower=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
    case "$key_lower" in
        host) PGHOST="$value" ;;
        port) PGPORT="$value" ;;
        database) PGDATABASE="$value" ;;
        username) PGUSER="$value" ;;
        password) PGPASSWORD="$value" ;;
        "ssl mode") PGSSLMODE_VALUE=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]') ;;
    esac
done
unset MARTEN_CONNECTION CONN_REST part key value key_lower

if [ -z "$PGHOST" ] || [ -z "$PGDATABASE" ] || [ -z "$PGUSER" ] || [ -z "$PGPASSWORD" ]; then
    echo "ERROR: no se pudo parsear el secreto 'marten-connection' (formato esperado:" >&2
    echo "  Host=...;Database=...;Username=...;Password=...;SSL Mode=...)." >&2
    exit 1
fi

export PGPASSWORD
CONNINFO="host=$PGHOST dbname=$PGDATABASE user=$PGUSER sslmode=$PGSSLMODE_VALUE"
[ -n "$PGPORT" ] && CONNINFO="$CONNINFO port=$PGPORT"

# Postgres resuelve las relaciones en el parseo, asi que un 'count(*)' sobre una
# tabla ausente aborta la consulta entera: el dry-run comprueba existencia primero
# para reportar un schema a medias (worker que nunca corrio, apply parcial) en vez
# de morir con un error crudo de psql antes de mostrar nada.
count_rows() {
    local table="$1" exists
    exists=$(psql "$CONNINFO" -tAc "SELECT to_regclass('\"$SCHEMA\".\"$table\"') IS NOT NULL")
    if [ "$exists" = "t" ]; then
        psql "$CONNINFO" -tAc "SELECT count(*) FROM \"$SCHEMA\".\"$table\""
    else
        printf '%s' "n/a (tabla ausente)"
    fi
}

SCHEMA_EXISTS=$(psql "$CONNINFO" -tAc "SELECT 1 FROM information_schema.schemata WHERE schema_name = '$SCHEMA'")
if [ "$SCHEMA_EXISTS" != "1" ]; then
    echo "El schema '$SCHEMA' no existe en $PGDATABASE: no hay nada que purgar."
    exit 0
fi

if [ "$DRY_RUN" = true ]; then
    # CA-6: solo reporta, cero pasos destructivos.
    STREAMS=$(count_rows mt_streams)
    CHECKPOINTS=$(count_rows mt_event_progression)
    READMODEL_TABLES=$(psql "$CONNINFO" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema = '$SCHEMA' AND table_name LIKE 'mt_doc_%'")

    echo ""
    echo "=== DRY RUN: dominio '$DOMAIN_KEBAB' (schema \"$SCHEMA\") en $RG_NAME ==="
    echo "  streams (mt_streams):                          $STREAMS"
    echo "  tablas de read model (mt_doc_%):               $READMODEL_TABLES"
    echo "  checkpoints del daemon (mt_event_progression): $CHECKPOINTS"
    echo ""
    echo "Nada se purgo. Sin --dry-run, este comando ejecuta 'DROP SCHEMA \"$SCHEMA\" CASCADE'"
    echo "y reinicia el Function App del dominio${CA_NAME:+ y el worker de proyecciones}."
    exit 0
fi

# --- Purga real (CA-5) ---------------------------------------------------------
echo "Purgando schema \"$SCHEMA\" (DROP SCHEMA ... CASCADE)..."
psql "$CONNINFO" -v ON_ERROR_STOP=1 -c "DROP SCHEMA \"$SCHEMA\" CASCADE;"

if [ -n "$CA_NAME" ]; then
    echo "Reiniciando worker de proyecciones ($CA_NAME, revision $ACTIVE_REVISION)..."
    az containerapp revision restart --name "$CA_NAME" --resource-group "$RG_NAME" \
        --revision "$ACTIVE_REVISION" >/dev/null
fi

echo "Reiniciando Function App del dominio ($FUNC_NAME)..."
az functionapp restart --name "$FUNC_NAME" --resource-group "$RG_NAME" >/dev/null

echo ""
echo "OK: schema \"$SCHEMA\" purgado. AutoCreateSchemaObjects lo recreara limpio en la"
echo "  primera escritura tras el reinicio (MEF-ADR-0034)."

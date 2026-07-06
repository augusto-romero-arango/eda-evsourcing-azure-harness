#!/usr/bin/env bash
# bootstrap-backend.sh -- Crea el backend remoto de Terraform en Azure (tfstate).
#
# Crea de forma idempotente el Resource Group, la Storage Account y el container
# que alojan el estado de Terraform, y escribe infra/environments/<env>/backend.tf
# con el bloque backend "azurerm" resuelto. Es el prerequisito del pipeline IaC
# (/infra), que recien entonces materializa los App Service Plans y Function Apps
# por dominio (ADR-0020). Este script NO crea planes ni Function Apps: solo el
# backend del tfstate.
#
# Nombre de la Storage Account: el nombre de una Storage Account es un endpoint
# DNS publico (*.blob.core.windows.net) y por tanto UNICO en todo Azure, no solo
# en la suscripcion. Por eso el campo 'terraformStateStorage' del config se trata
# como un nombre BASE: este script le anexa un sufijo aleatorio de unicidad global
# (mismo patron 'random_string' que agents/domain-scaffolder.md aplica a las
# Storage de dominio) y valida la disponibilidad con 'az storage account
# check-name' antes de crear. El nombre FINAL resuelto es el que se escribe en
# backend.tf y se imprime, asi que 'terraform init' usa exactamente la cuenta
# creada. La idempotencia se ancla en dos fuentes durables -no en un archivo de
# estado local-: el storage_account_name ya escrito en backend.tf (versionado) y
# la cuenta ya creada en el RG dedicado del tfstate; una segunda corrida reusa esa
# cuenta en vez de crear otra con un sufijo distinto.
#
# Uso:
#   ./scripts/bootstrap-backend.sh --subscription <id>
#   ./scripts/bootstrap-backend.sh --subscription <id> --env dev
#   ./scripts/bootstrap-backend.sh <id> --env staging --location westeurope
#
# Opciones:
#   --subscription <id>        Suscripcion de Azure donde crear el backend
#                              (requerido; tambien se admite como primer
#                              argumento posicional).
#   --env <dev|staging|prod>   Ambiente. Default: dev.
#   --location <region>        Region de Azure. Si se omite, se lee el campo
#                              opcional 'azureLocation' de
#                              .claude/harness.config.json. Si tampoco existe,
#                              aborta pidiendo el flag o el campo de config.
#
# Es del lado PUBLICADO (ADR-0019): opera sobre el repo consumidor, nunca sobre
# Mefisto, y lleva guard defensivo .claude-plugin/plugin.json igual que
# scripts/setup-github-ci.sh y scripts/iac-pipeline.sh.
#
# Idempotente: re-ejecutable; sale 0 si el backend ya existia por completo.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_pipeline-common.sh"

# Guard defensivo: este script es del lado publicado y solo aplica al consumidor.
# Si detectamos .claude-plugin/plugin.json en la raiz, estamos en el repo de Mefisto.
_REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git" >&2
    exit 1
}
if [ -f "$_REPO_TOP/.claude-plugin/plugin.json" ]; then
    echo "ERROR: scripts/bootstrap-backend.sh es del plugin publicado y solo aplica al consumidor." >&2
    echo "Mefisto no se despliega a Azure ni tiene backend de Terraform." >&2
    echo "Para mejorar el plugin usa /mefisto-tooling." >&2
    exit 1
fi
unset _REPO_TOP

load_harness_config || exit 1

# --- Parseo de argumentos ---
ENVIRONMENT="dev"
LOCATION=""
SUBSCRIPTION_ID=""

usage() {
    cat >&2 <<EOF
Uso: $0 --subscription <id> [--env <dev|staging|prod>] [--location <region>]

  --subscription <id>   Suscripcion de Azure (requerido; tambien se admite como
                        primer argumento posicional).
  --env <env>           Ambiente: dev | staging | prod. Default: dev.
  --location <region>   Region de Azure (ej: eastus2). Si se omite, se lee
                        'azureLocation' de .claude/harness.config.json.

Ejemplo: $0 --subscription 50fc1901-9723-4971-9d63-b3f1a015e8b8 --env dev
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --subscription)
            SUBSCRIPTION_ID="${2:-}"
            [ -z "$SUBSCRIPTION_ID" ] && { echo "ERROR: --subscription requiere un valor" >&2; exit 1; }
            shift 2 ;;
        --env)
            ENVIRONMENT="${2:-}"
            [ -z "$ENVIRONMENT" ] && { echo "ERROR: --env requiere un valor" >&2; exit 1; }
            shift 2 ;;
        --location)
            LOCATION="${2:-}"
            [ -z "$LOCATION" ] && { echo "ERROR: --location requiere un valor" >&2; exit 1; }
            shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        --*)
            echo "ERROR: opcion desconocida '$1'" >&2; usage; exit 1 ;;
        *)
            if [ -z "$SUBSCRIPTION_ID" ]; then
                SUBSCRIPTION_ID="$1"; shift
            else
                echo "ERROR: argumento inesperado '$1'" >&2; usage; exit 1
            fi ;;
    esac
done

# --- Validaciones ---
case "$ENVIRONMENT" in
    dev|staging|prod) ;;
    *) echo "ERROR: --env invalido '$ENVIRONMENT' (usa dev | staging | prod)" >&2; exit 1 ;;
esac

if [ -z "$SUBSCRIPTION_ID" ]; then
    echo "ERROR: falta la suscripcion de Azure." >&2
    usage
    exit 1
fi

# Location: el flag tiene prioridad; si no se paso, se lee inline el campo
# opcional 'azureLocation' del config (mismo patron que 'repoSlug' en
# _pipeline-common.sh). Si tampoco existe, aborta con mensaje claro.
if [ -z "$LOCATION" ]; then
    LOCATION=$(jq -r '.azureLocation // empty' .claude/harness.config.json 2>/dev/null)
fi
if [ -z "$LOCATION" ]; then
    echo "ERROR: no se especifico la region de Azure." >&2
    echo "  Pasa --location <region> (ej: --location eastus2) o agrega el campo" >&2
    echo "  opcional \"azureLocation\" a .claude/harness.config.json." >&2
    exit 1
fi

if [ -z "$HARNESS_RG_PREFIX" ]; then
    echo "ERROR: 'infraResourceGroupPrefix' no esta definido en .claude/harness.config.json." >&2
    exit 1
fi
if [ -z "$HARNESS_TFSTATE_STORAGE" ]; then
    echo "ERROR: 'terraformStateStorage' no esta definido en .claude/harness.config.json." >&2
    exit 1
fi

# --- Nombres resueltos desde el config (sin hardcodear) ---
RG="${HARNESS_RG_PREFIX}-tfstate"
CONTAINER="tfstate"
INFRA_ENV_DIR="infra/environments/${ENVIRONMENT}"
BACKEND_KEY="${ENVIRONMENT}.tfstate"

# Nombre BASE de la Storage Account (del config). El nombre FINAL puede llevar un
# sufijo de unicidad global (ver resolucion mas abajo). Azure exige <= 24 chars;
# reservamos SUFFIX_LEN para el sufijo y truncamos la base si no cabe (mismo
# calculo que agents/domain-scaffolder.md Paso 4: base + 6 chars <= 24).
STORAGE_SUFFIX_LEN=6
STORAGE_MAX_LEN=24
STORAGE_BASE=$(truncate_storage_base "$HARNESS_TFSTATE_STORAGE" "$STORAGE_MAX_LEN" "$STORAGE_SUFFIX_LEN")
if [ "$STORAGE_BASE" != "$HARNESS_TFSTATE_STORAGE" ]; then
    echo "AVISO: 'terraformStateStorage' ('${HARNESS_TFSTATE_STORAGE}', ${#HARNESS_TFSTATE_STORAGE} chars) no deja espacio para el sufijo de ${STORAGE_SUFFIX_LEN} chars dentro del limite de ${STORAGE_MAX_LEN}; se trunca la base a '${STORAGE_BASE}'." >&2
fi

echo "=== Bootstrap del backend de Terraform para ${HARNESS_PROJECT_NAME} ==="
echo "  Ambiente:        ${ENVIRONMENT}"
echo "  Suscripcion:     ${SUBSCRIPTION_ID}"
echo "  Region:          ${LOCATION}"
echo "  Resource Group:  ${RG}"
echo "  Storage (base):  ${STORAGE_BASE}"
echo "  Container:       ${CONTAINER}"
echo ""

# --- Fijar la suscripcion explicitamente antes de operar ---
echo "Fijando la suscripcion activa..."
az account set --subscription "$SUBSCRIPTION_ID" || {
    echo "ERROR: no se pudo fijar la suscripcion '$SUBSCRIPTION_ID'." >&2
    echo "  Verifica que 'az login' este hecho y que la suscripcion exista." >&2
    exit 1
}

# --- Resolver el nombre FINAL de la Storage Account (idempotente + unico) ------
# Precedencia:
#   1. storage_account_name ya declarado en un backend "azurerm" del ambiente
#      (registro versionado y canonico: es lo que usara 'terraform init').
#   2. Cuenta ya creada en el RG dedicado del tfstate cuyo nombre arranca con la
#      base (cubre una corrida previa interrumpida antes de escribir backend.tf).
#   3. Nombre nuevo: base + sufijo aleatorio, validando unicidad GLOBAL con
#      'az storage account check-name' y reintentando si el nombre esta tomado.
resolve_storage_account_name() {
    local from_backend existing candidate suffix attempt available

    from_backend=$(read_backend_storage_account_name "$INFRA_ENV_DIR")
    if [ -n "$from_backend" ]; then
        printf '%s' "$from_backend"
        return 0
    fi

    existing=$(az storage account list \
        --resource-group "$RG" \
        --query "[?starts_with(name, '${STORAGE_BASE}')].name | [0]" \
        -o tsv 2>/dev/null) || existing=""
    if [ -n "$existing" ] && [ "$existing" != "None" ]; then
        printf '%s' "$existing"
        return 0
    fi

    for attempt in {1..10}; do
        suffix=$(gen_storage_suffix "$STORAGE_SUFFIX_LEN")
        candidate="${STORAGE_BASE}${suffix}"
        available=$(az storage account check-name --name "$candidate" \
            --query nameAvailable -o tsv 2>/dev/null) || available=""
        case "$available" in
            [Tt]rue)
                printf '%s' "$candidate"; return 0 ;;
            [Ff]alse)
                continue ;;
            *)
                echo "AVISO: 'az storage account check-name' no fue concluyente para '${candidate}'; se usara de todas formas (si colisiona, el create fallara de forma explicita)." >&2
                printf '%s' "$candidate"; return 0 ;;
        esac
    done

    echo "ERROR: no se pudo resolver un nombre globalmente unico para la Storage Account tras 10 intentos con sufijo aleatorio." >&2
    return 1
}

echo "Resolviendo el nombre de la Storage Account (base '${STORAGE_BASE}')..."
STORAGE=$(resolve_storage_account_name) || exit 1
echo "  Storage Account: ${STORAGE}"
echo ""

# --- 1. Resource Group (idempotente) ---
RG_EXISTS=$(az group exists --name "$RG" 2>/dev/null || echo "false")
case "$RG_EXISTS" in
    [Tt]rue)
        echo "Resource Group '${RG}' ya existe. Omitiendo." ;;
    *)
        echo "Creando Resource Group '${RG}' en ${LOCATION}..."
        az group create --name "$RG" --location "$LOCATION" -o none ;;
esac

# --- 2. Storage Account (idempotente, endurecido) ---
if az storage account show --name "$STORAGE" --resource-group "$RG" -o none 2>/dev/null; then
    echo "Storage Account '${STORAGE}' ya existe. Omitiendo creacion."
else
    echo "Creando Storage Account '${STORAGE}'..."
    az storage account create \
        --name "$STORAGE" \
        --resource-group "$RG" \
        --location "$LOCATION" \
        --sku Standard_LRS \
        --kind StorageV2 \
        --min-tls-version TLS1_2 \
        --https-only true \
        --allow-blob-public-access false \
        -o none
fi

# Versioning + soft-delete de blobs (idempotente: fija el estado deseado, se
# aplica aunque la cuenta ya existiera).
echo "Asegurando versioning y soft-delete de blobs..."
az storage account blob-service-properties update \
    --account-name "$STORAGE" \
    --resource-group "$RG" \
    --enable-versioning true \
    --enable-delete-retention true \
    --delete-retention-days 7 \
    -o none

# --- 3. Container del tfstate (idempotente, auth-mode login) ---
CONTAINER_EXISTS=$(az storage container exists \
    --name "$CONTAINER" \
    --account-name "$STORAGE" \
    --auth-mode login \
    --query exists -o tsv 2>/dev/null || echo "false")
case "$CONTAINER_EXISTS" in
    [Tt]rue)
        echo "Container '${CONTAINER}' ya existe. Omitiendo." ;;
    *)
        echo "Creando container '${CONTAINER}' (auth-mode login)..."
        az storage container create \
            --name "$CONTAINER" \
            --account-name "$STORAGE" \
            --auth-mode login \
            -o none || {
            echo "ERROR: no se pudo crear el container '${CONTAINER}'." >&2
            echo "  Con --auth-mode login necesitas el rol 'Storage Blob Data Contributor'" >&2
            echo "  sobre la Storage Account. Tras asignarlo, la propagacion RBAC puede" >&2
            echo "  tardar unos minutos; re-ejecuta este script (es idempotente)." >&2
            exit 1
        } ;;
esac

# --- 4. Escribir backend.tf (opcion (a)) de forma idempotente ---
mkdir -p "$INFRA_ENV_DIR"
BACKEND_FILE="${INFRA_ENV_DIR}/backend.tf"

# Si ya hay un bloque backend "azurerm" en OTRO .tf del ambiente, no escribimos
# backend.tf para evitar una doble definicion (Terraform falla con dos backends).
EXISTING_BACKEND=$(grep -l 'backend[[:space:]]*"azurerm"' "$INFRA_ENV_DIR"/*.tf 2>/dev/null \
    | grep -v "/backend.tf$" || true)
if [ -n "$EXISTING_BACKEND" ]; then
    echo "AVISO: ya existe un bloque backend \"azurerm\" en:" >&2
    echo "$EXISTING_BACKEND" | sed 's/^/  - /' >&2
    echo "  No se escribe ${BACKEND_FILE} para no duplicar la definicion del backend." >&2
else
    cat > "$BACKEND_FILE" <<EOF
# Generado por scripts/bootstrap-backend.sh -- no editar a mano.
# Backend remoto del estado de Terraform para el ambiente '${ENVIRONMENT}'.
# 'use_azuread_auth = true': acceso keyless por AAD/RBAC, nunca por access key
# (ADR-0025, ADR-0022; developer.hashicorp.com/terraform/language/backend/azurerm).
terraform {
  backend "azurerm" {
    resource_group_name  = "${RG}"
    storage_account_name = "${STORAGE}"
    container_name       = "${CONTAINER}"
    key                  = "${BACKEND_KEY}"
    use_azuread_auth     = true
  }
}
EOF
    echo "Escrito ${BACKEND_FILE}."
fi

# --- 5. Imprimir el bloque backend resultante (cuadra con 'terraform init') ---
echo ""
echo "=== Backend listo. Bloque backend \"azurerm\" resultante: ==="
cat <<EOF
terraform {
  backend "azurerm" {
    resource_group_name  = "${RG}"
    storage_account_name = "${STORAGE}"
    container_name       = "${CONTAINER}"
    key                  = "${BACKEND_KEY}"
    use_azuread_auth     = true
  }
}
EOF
echo ""
echo "El backend es keyless (AAD/RBAC, ADR-0025): ningun access key se emite ni se"
echo "persiste para el tfstate. El principal que hace 'terraform apply' en CI"
echo "requiere el rol 'Storage Blob Data Contributor' (lectura+escritura, no solo"
echo "lectura) sobre esta Storage Account -- lo asigna scripts/setup-github-ci.sh"
echo "(issue #195), no este script."
echo ""
echo "Siguiente paso: el pipeline IaC ejecuta 'terraform init' en ${INFRA_ENV_DIR}"
echo "y reutiliza este backend. Lanzalo con /infra o scripts/iac-pipeline.sh."
echo "Listo."

#!/bin/bash
# Configura la autenticacion de GitHub Actions hacia Azure para el deploy de CI.
# Usa OIDC (Workload Identity Federation, ADR-0022): crea el Service Principal SIN
# secret y le anade un federated credential que confia en los tokens que GitHub emite
# para la rama main del repo. El workflow de deploy del scaffolder se autentica con
# azure/login pasando client-id / tenant-id / subscription-id (sin AZURE_CREDENTIALS ni
# secret que expire). Asigna ademas Contributor a nivel suscripcion y lectura del tfstate.
#
# Uso: ./scripts/setup-github-ci.sh <subscription-id> [<owner/repo>]
# Ejemplo: ./scripts/setup-github-ci.sh 50fc1901-9723-4971-9d63-b3f1a015e8b8 acme/mi-proyecto
#
# El slug owner/repo del repositorio (subject del federated credential) se resuelve
# automaticamente con 'gh repo view' o el remote 'origin'; pasalo como 2do argumento
# para forzarlo.
#
# Resuelve el nombre REAL de la Storage Account del tfstate (que bootstrap-backend.sh
# pudo crear con un sufijo de unicidad global, issue #92) antes de asignar el rol,
# para no apuntar a una cuenta inexistente. Correr DESPUES de bootstrap-backend.sh.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_pipeline-common.sh"

# Guard defensivo: este script es del lado publicado y solo aplica al consumidor.
# Si detectamos .claude-plugin/plugin.json en la raiz, estamos en el repo de Mefisto.
_REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "ERROR: no estas en un repositorio git" >&2
    exit 1
}
if [ -f "$_REPO_TOP/.claude-plugin/plugin.json" ]; then
    echo "ERROR: scripts/setup-github-ci.sh es del plugin publicado y solo aplica al consumidor." >&2
    echo "Mefisto no se despliega a Azure ni necesita Service Principal." >&2
    exit 1
fi
unset _REPO_TOP

load_harness_config || exit 1

if [ -z "${1:-}" ]; then
    echo "Uso: $0 <subscription-id> [<owner/repo>]"
    echo "Ejemplo: $0 50fc1901-9723-4971-9d63-b3f1a015e8b8 acme/mi-proyecto"
    exit 1
fi

SUBSCRIPTION_ID="$1"
SP_NAME="$HARNESS_SP_NAME"
TFSTATE_RG="${HARNESS_RG_PREFIX}-tfstate"
SCOPE="/subscriptions/${SUBSCRIPTION_ID}"

# Slug owner/repo para el subject del federated credential de OIDC. Precedencia:
#   1. 2do argumento explicito.
#   2. 'gh repo view' (resuelve el repo del cwd via la API de GitHub; gh es dependencia
#      dura del harness, ya se usa para issues/PRs).
#   3. parseo del remote 'origin' (https o ssh), por si 'gh' no esta autenticado.
REPO_SLUG="${2:-}"
if [ -z "$REPO_SLUG" ]; then
    REPO_SLUG=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || REPO_SLUG=""
fi
if [ -z "$REPO_SLUG" ]; then
    _origin=$(git remote get-url origin 2>/dev/null) || _origin=""
    REPO_SLUG=$(printf '%s' "$_origin" | sed -E 's#^(https://[^/]+/|git@[^:]+:)##; s#\.git$##')
    unset _origin
fi
if [ -z "$REPO_SLUG" ] || [ "$REPO_SLUG" = "None" ]; then
    echo "ERROR: no se pudo resolver el slug owner/repo del repositorio." >&2
    echo "Pasalo como 2do argumento ($0 $SUBSCRIPTION_ID <owner/repo>) o configura un" >&2
    echo "remote 'origin' de GitHub / autentica 'gh', y reintenta." >&2
    exit 1
fi

# Nombre de la Storage Account del tfstate: bootstrap-backend.sh le anexa un
# sufijo de unicidad global (issue #92), asi que el nombre REAL puede no coincidir
# con el campo base 'terraformStateStorage' del config. Resolver el nombre FINAL
# para no asignar 'Storage Blob Data Reader' sobre una cuenta inexistente (este
# script corre DESPUES del bootstrap; ver README "Primeros pasos", paso 2). Mismo
# orden de precedencia durable que usa el bootstrap, con los helpers compartidos:
#   1. storage_account_name escrito en algun infra/environments/*/backend.tf
#      (lo que el bootstrap acaba de escribir; es lo que usara 'terraform init').
#   2. cuenta ya creada en el RG dedicado cuyo nombre arranca con la base truncada.
#   3. fallback: el nombre base del config (compat con backends pre-#92 sin sufijo).
resolve_tfstate_storage_name() {
    local dir from_backend base existing
    for dir in infra/environments/*/; do
        from_backend=$(read_backend_storage_account_name "$dir")
        if [ -n "$from_backend" ]; then
            printf '%s' "$from_backend"; return 0
        fi
    done
    base=$(truncate_storage_base "$HARNESS_TFSTATE_STORAGE")
    existing=$(az storage account list \
        --subscription "$SUBSCRIPTION_ID" \
        --resource-group "$TFSTATE_RG" \
        --query "[?starts_with(name, '${base}')].name | [0]" \
        -o tsv 2>/dev/null) || existing=""
    if [ -n "$existing" ] && [ "$existing" != "None" ]; then
        printf '%s' "$existing"; return 0
    fi
    printf '%s' "$HARNESS_TFSTATE_STORAGE"
}
TFSTATE_STORAGE=$(resolve_tfstate_storage_name)

echo "=== Setup CI para ${HARNESS_PROJECT_NAME} ==="
echo "Repositorio GitHub: ${REPO_SLUG}"
echo ""

# 1. Aplicacion de Microsoft Entra + Service Principal, SIN secret (OIDC).
#    Idempotente: reutiliza la app si ya existe por displayName.
echo "Resolviendo aplicacion de Entra '${SP_NAME}'..."
APP_ID=$(az ad app list --display-name "$SP_NAME" --query "[0].appId" -o tsv 2>/dev/null) || APP_ID=""
if [ -z "$APP_ID" ] || [ "$APP_ID" = "None" ]; then
    echo "Creando aplicacion '${SP_NAME}'..."
    APP_ID=$(az ad app create --display-name "$SP_NAME" --query appId -o tsv)
else
    echo "La aplicacion ya existe (appId ${APP_ID}); se reutiliza."
fi

# Service principal de la app (idempotente).
if ! az ad sp show --id "$APP_ID" >/dev/null 2>&1; then
    echo "Creando service principal para appId ${APP_ID}..."
    az ad sp create --id "$APP_ID" -o none
fi
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

# 2. Contributor a nivel suscripcion: alcance necesario para el deploy de Functions e
#    infraestructura, no solo lectura del tfstate. Asignar por object-id + principal-type
#    evita el race de replicacion del SP recien creado en Microsoft Graph.
#    'az role assignment create' es idempotente (no falla si la asignacion ya existe).
echo "Asignando Contributor en ${SCOPE}..."
az role assignment create \
    --assignee-object-id "$SP_OBJECT_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Contributor" \
    --scope "$SCOPE" \
    -o none

# 3. Lectura del tfstate sobre la cuenta REAL resuelta (sufijo de unicidad, issue #92).
echo "Asignando Storage Blob Data Reader en ${TFSTATE_STORAGE}..."
az role assignment create \
    --assignee-object-id "$SP_OBJECT_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Storage Blob Data Reader" \
    --scope "${SCOPE}/resourceGroups/${TFSTATE_RG}/providers/Microsoft.Storage/storageAccounts/${TFSTATE_STORAGE}" \
    -o none

# 4. Federated credential para GitHub Actions OIDC. El subject debe coincidir EXACTO con
#    el claim que GitHub pone en el token. El workflow de deploy del scaffolder dispara en
#    'push: branches: [main]' (+ workflow_dispatch desde main), jobs NO atados a un
#    Environment, asi que el subject es 'repo:<owner/repo>:ref:refs/heads/main'.
#    Fuentes: learn.microsoft.com/azure/app-service/deploy-github-actions y
#    learn.microsoft.com/entra/workload-id/workload-identity-federation-create-trust.
FED_NAME="github-actions-deploy-main"
FED_SUBJECT="repo:${REPO_SLUG}:ref:refs/heads/main"
_existing_fed=$(az ad app federated-credential list --id "$APP_ID" \
    --query "[?subject=='${FED_SUBJECT}'] | [0].name" -o tsv 2>/dev/null) || _existing_fed=""
if [ -n "$_existing_fed" ] && [ "$_existing_fed" != "None" ]; then
    echo "Federated credential para '${FED_SUBJECT}' ya existe; se reutiliza."
else
    echo "Creando federated credential para '${FED_SUBJECT}'..."
    FED_PARAMS=$(cat <<EOF
{
  "name": "${FED_NAME}",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "${FED_SUBJECT}",
  "description": "GitHub Actions OIDC: deploy de ${HARNESS_PROJECT_NAME} desde la rama main",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF
)
    az ad app federated-credential create --id "$APP_ID" --parameters "$FED_PARAMS" -o none
fi
unset _existing_fed

echo ""
echo "=== Configura estos secrets en GitHub ==="
echo "Settings > Secrets and variables > Actions > New repository secret"
echo ""
echo "  AZURE_CLIENT_ID       = ${APP_ID}"
echo "  AZURE_TENANT_ID       = ${TENANT_ID}"
echo "  AZURE_SUBSCRIPTION_ID = ${SUBSCRIPTION_ID}"
echo ""
echo "Autenticacion por OIDC (Workload Identity Federation): NO hay client secret que"
echo "copiar ni que expire. El workflow de deploy ya declara 'permissions: id-token: write'"
echo "y se loguea con azure/login pasando esos tres valores (sin AZURE_CREDENTIALS)."
echo ""
echo "El federated credential confia en la rama 'main' (subject ${FED_SUBJECT})."
echo "Si despliegas desde otra rama, tag o un GitHub Environment, anade otro federated"
echo "credential con el subject correspondiente (ver ADR-0022)."
echo ""
echo "Listo."

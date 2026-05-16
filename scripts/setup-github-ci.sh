#!/bin/bash
# Crea el Service Principal para GitHub Actions CI y asigna permisos en el tfstate.
# Uso: ./scripts/setup-github-ci.sh <subscription-id>
# Ejemplo: ./scripts/setup-github-ci.sh 50fc1901-9723-4971-9d63-b3f1a015e8b8
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
    echo "Uso: $0 <subscription-id>"
    echo "Ejemplo: $0 50fc1901-9723-4971-9d63-b3f1a015e8b8"
    exit 1
fi

SUBSCRIPTION_ID="$1"
SP_NAME="$HARNESS_SP_NAME"
TFSTATE_STORAGE="$HARNESS_TFSTATE_STORAGE"
TFSTATE_RG="${HARNESS_RG_PREFIX}-tfstate"
SCOPE="/subscriptions/${SUBSCRIPTION_ID}"

echo "=== Setup CI para ${HARNESS_PROJECT_NAME} ==="
echo ""

echo "Creando service principal '${SP_NAME}'..."
SP_OUTPUT=$(az ad sp create-for-rbac \
    --name "$SP_NAME" \
    --role "Contributor" \
    --scopes "$SCOPE" \
    --query "{clientId:appId, clientSecret:password, tenantId:tenant}" \
    -o json)

CLIENT_ID=$(echo "$SP_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['clientId'])")
CLIENT_SECRET=$(echo "$SP_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['clientSecret'])")
TENANT_ID=$(echo "$SP_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['tenantId'])")

echo "Asignando Storage Blob Data Reader en ${TFSTATE_STORAGE}..."
az role assignment create \
    --assignee "$CLIENT_ID" \
    --role "Storage Blob Data Reader" \
    --scope "${SCOPE}/resourceGroups/${TFSTATE_RG}/providers/Microsoft.Storage/storageAccounts/${TFSTATE_STORAGE}" \
    -o none

echo ""
echo "=== Configura estos secrets en GitHub ==="
echo "Settings > Secrets and variables > Actions > New repository secret"
echo ""
echo "  AZURE_CLIENT_ID       = ${CLIENT_ID}"
echo "  AZURE_CLIENT_SECRET   = ${CLIENT_SECRET}"
echo "  AZURE_TENANT_ID       = ${TENANT_ID}"
echo "  AZURE_SUBSCRIPTION_ID = ${SUBSCRIPTION_ID}"
echo ""
echo "NOTA: El client secret expira en 1 ano. Renovar con:"
echo "  az ad sp credential reset --id ${CLIENT_ID}"
echo ""
echo "Listo."

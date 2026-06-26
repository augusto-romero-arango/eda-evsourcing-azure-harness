#!/bin/bash
# Crea el Service Principal para GitHub Actions CI y asigna permisos en el tfstate.
# Uso: ./scripts/setup-github-ci.sh <subscription-id>
# Ejemplo: ./scripts/setup-github-ci.sh 50fc1901-9723-4971-9d63-b3f1a015e8b8
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
    echo "Uso: $0 <subscription-id>"
    echo "Ejemplo: $0 50fc1901-9723-4971-9d63-b3f1a015e8b8"
    exit 1
fi

SUBSCRIPTION_ID="$1"
SP_NAME="$HARNESS_SP_NAME"
TFSTATE_RG="${HARNESS_RG_PREFIX}-tfstate"
SCOPE="/subscriptions/${SUBSCRIPTION_ID}"

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

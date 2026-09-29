#!/bin/bash
# Configura la autenticacion de GitHub Actions hacia Azure para que CI aplique
# infraestructura y despliegue codigo (MEF-ADR-0022, reformado issue #196). Usa OIDC
# (Workload Identity Federation): crea el Service Principal SIN secret y le anade
# los federated credentials que confian en los tokens que GitHub emite para la
# rama main (deploy/apply) y para pull_request (plan). El workflow de deploy y
# el de CI de Terraform (infra-cd.yml) se autentican con azure/login pasando
# client-id / tenant-id / subscription-id (sin AZURE_CREDENTIALS ni secret que
# expire). Asigna ademas, a nivel suscripcion: Contributor (deploy + infra) y
# Role Based Access Control Administrator con condicion anti-escalacion (para que
# el apply de CI pueda crear los role assignments que emiten los scaffolders,
# MEF-ADR-0025); y sobre la Storage del tfstate: Storage Blob Data Contributor
# (lectura+escritura por AAD, backend keyless de #198).
#
# Uso: ./scripts/setup-github-ci.sh <subscription-id> [<owner/repo>]
# Ejemplo: ./scripts/setup-github-ci.sh 50fc1901-9723-4971-9d63-b3f1a015e8b8 acme/mi-proyecto
#
# El slug owner/repo del repositorio (subject de los federated credentials) se
# resuelve automaticamente con 'gh repo view' o el remote 'origin'; pasalo como
# 2do argumento para forzarlo.
#
# Resuelve la pareja REAL de Resource Group y Storage Account del tfstate desde
# backend.tf antes de asignar el rol. Correr DESPUES de bootstrap-backend.sh.
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
SCOPE="/subscriptions/${SUBSCRIPTION_ID}"

# Resuelve la pareja durable del backend ANTES de la primera llamada a Azure. No
# deriva ninguno de sus valores desde el config: backend.tf es el registro que
# terraform init realmente consume (MEF-ADR-0045). Leer ambos helpers sobre
# directorios distintos podria combinar ambientes, por eso se aceptan solo pares
# completos del mismo directorio y se rechaza cualquier ambiguedad.
resolve_tfstate_backend_pair() {
    local dir rg storage backend_count
    local pairs=() problems=()

    for dir in infra/environments/*; do
        [ -d "$dir" ] || continue
        backend_count=$(grep -hE 'backend[[:space:]]*"azurerm"' "$dir"/*.tf 2>/dev/null | wc -l | tr -d '[:space:]') || backend_count=0
        if [ "$backend_count" -eq 0 ]; then
            problems+=("${dir}: no contiene un bloque backend azurerm")
            continue
        fi

        if [ "$backend_count" -ne 1 ]; then
            problems+=("${dir}: contiene ${backend_count} bloques backend azurerm")
            continue
        fi

        rg=$(read_backend_resource_group_name "$dir")
        storage=$(read_backend_storage_account_name "$dir")
        if [ -z "$rg" ] || [ -z "$storage" ]; then
            problems+=("${dir}: resource_group_name y storage_account_name deben ser literales y completos")
            continue
        fi
        pairs+=("${dir}|${rg}|${storage}")
    done

    if [ ${#problems[@]} -gt 0 ] || [ ${#pairs[@]} -ne 1 ]; then
        echo "ERROR: no se pudo resolver una unica pareja completa del backend Terraform." >&2
        if [ ${#pairs[@]} -gt 0 ]; then
            echo "  Candidatos completos:" >&2
            printf '  - %s\n' "${pairs[@]}" >&2
        fi
        if [ ${#problems[@]} -gt 0 ]; then
            echo "  Candidatos problematicos:" >&2
            printf '  - %s\n' "${problems[@]}" >&2
        fi
        if [ ${#pairs[@]} -eq 0 ] && [ ${#problems[@]} -eq 0 ]; then
            echo "  No se encontro un backend azurerm bajo infra/environments/*/." >&2
        fi
        echo "  Ejecuta scripts/bootstrap-backend.sh para un ambiente o corrige el backend antes de reintentar." >&2
        return 1
    fi

    TFSTATE_RG="${pairs[0]#*|}"
    TFSTATE_RG="${TFSTATE_RG%%|*}"
    TFSTATE_STORAGE="${pairs[0]##*|}"
    export TFSTATE_RG TFSTATE_STORAGE
}

resolve_tfstate_backend_pair || exit 1

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

if ! [[ "$REPO_SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "ERROR: el repositorio debe tener el formato owner/repo; se recibio '${REPO_SLUG}'." >&2
    exit 1
fi

resolve_github_repository_identity() {
    local metadata metadata_slug owner_id repository_id
    metadata=$(gh api "repos/${REPO_SLUG}" 2>/dev/null) || {
        echo "ERROR: no se pudo consultar la metadata de GitHub para '${REPO_SLUG}'." >&2
        echo "  Autentica 'gh' con acceso al repositorio o verifica el argumento owner/repo antes de reintentar." >&2
        return 1
    }
    metadata_slug=$(jq -r '.full_name // empty' <<<"$metadata" 2>/dev/null) || metadata_slug=""
    owner_id=$(jq -r '.owner.id // empty' <<<"$metadata" 2>/dev/null) || owner_id=""
    repository_id=$(jq -r '.id // empty' <<<"$metadata" 2>/dev/null) || repository_id=""
    if [ "$metadata_slug" != "$REPO_SLUG" ]; then
        echo "ERROR: GitHub devolvio metadata de '${metadata_slug:-un repositorio desconocido}', no de '${REPO_SLUG}'." >&2
        echo "  Verifica el argumento owner/repo, el remote origin y la autenticacion de gh antes de reintentar." >&2
        return 1
    fi
    if ! [[ "$owner_id" =~ ^[1-9][0-9]*$ ]] || ! [[ "$repository_id" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: la metadata de GitHub para '${REPO_SLUG}' no contiene IDs inmutables validos de owner y repositorio." >&2
        echo "  Verifica que 'gh api repos/${REPO_SLUG}' pueda leer .owner.id e .id antes de reintentar." >&2
        return 1
    fi
    GITHUB_OWNER_ID="$owner_id"
    GITHUB_REPOSITORY_ID="$repository_id"
    GITHUB_OWNER="${metadata_slug%%/*}"
    GITHUB_REPOSITORY="${metadata_slug#*/}"
}

# El formato inmutable intercala los IDs en el componente del repositorio:
# `repo:<owner>@<owner_id>/<repo>@<repository_id>:<contexto>`. No se deben
# confundir los nombres de los claims auxiliares con la sintaxis del `sub`.
# Fuentes: https://docs.github.com/en/actions/reference/security/oidc y
# https://learn.microsoft.com/entra/workload-id/workload-identities-github-immutable-subjects
resolve_github_repository_identity || exit 1
IMMUTABLE_REPOSITORY="${GITHUB_OWNER}@${GITHUB_OWNER_ID}/${GITHUB_REPOSITORY}@${GITHUB_REPOSITORY_ID}"
FED_SUBJECT_MAIN="repo:${IMMUTABLE_REPOSITORY}:ref:refs/heads/main"
FED_SUBJECT_PR="repo:${IMMUTABLE_REPOSITORY}:pull_request"

# Fijar la suscripcion explicitamente despues de validar GitHub y antes de la
# primera operacion Azure. Las operaciones de Entra usan el tenant activo.
echo "Fijando la suscripcion activa..."
az account set --subscription "$SUBSCRIPTION_ID" || {
    echo "ERROR: no se pudo fijar la suscripcion '$SUBSCRIPTION_ID'." >&2
    echo "  Verifica que 'az login' este hecho y que la suscripcion exista." >&2
    exit 1
}

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

# 3. Role Based Access Control Administrator a nivel suscripcion, con una condicion
#    ABAC (version 2.0) anti-escalacion. 'Contributor' EXCLUYE explicitamente
#    'Microsoft.Authorization/roleAssignments/write' (Azure built-in roles,
#    learn.microsoft.com/azure/role-based-access-control/built-in-roles/general#contributor),
#    asi que sin este rol el 'terraform apply' de CI falla con AuthorizationFailed al
#    crear los role assignments que emiten los scaffolders (Key Vault Secrets User,
#    roles de datos de Storage; MEF-ADR-0025). 'Role Based Access Control Administrator' es
#    el rol de MENOR privilegio documentado para delegar gestion de role assignments
#    (frente a 'User Access Administrator', que ademas puede reclamar el rol de
#    administrador de acceso para si mismo). La condicion sigue la plantilla integrada
#    "Allow all except specific roles" (Azure portal) / "Constrain roles that can be
#    assigned": excluye que el SP pueda asignar los roles privilegiados Owner, User
#    Access Administrator o el propio Role Based Access Control Administrator, para que
#    este rol no se convierta en una via de escalacion a Owner.
#    Fuentes: learn.microsoft.com/azure/role-based-access-control/delegate-role-assignments-overview
#    y learn.microsoft.com/azure/role-based-access-control/delegate-role-assignments-examples
#    (seccion "Allow most roles, but don't allow others to assign roles").
#
# Los IDs de rol se resuelven por nombre (no se hardcodean los GUIDs) para no
# depender de que coincidan entre nubes/tenants.
resolve_role_definition_id() {
    az role definition list --name "$1" --query "[0].name" -o tsv 2>/dev/null
}
OWNER_ROLE_ID=$(resolve_role_definition_id "Owner")
USER_ACCESS_ADMIN_ROLE_ID=$(resolve_role_definition_id "User Access Administrator")
RBAC_ADMIN_ROLE_ID=$(resolve_role_definition_id "Role Based Access Control Administrator")
if [ -z "$OWNER_ROLE_ID" ] || [ -z "$USER_ACCESS_ADMIN_ROLE_ID" ] || [ -z "$RBAC_ADMIN_ROLE_ID" ]; then
    echo "ERROR: no se pudieron resolver los IDs de los roles integrados Owner," >&2
    echo "  'User Access Administrator' y/o 'Role Based Access Control Administrator'." >&2
    exit 1
fi

ANTI_ESCALATION_CONDITION="((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {${OWNER_ROLE_ID}, ${RBAC_ADMIN_ROLE_ID}, ${USER_ACCESS_ADMIN_ROLE_ID}})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {${OWNER_ROLE_ID}, ${RBAC_ADMIN_ROLE_ID}, ${USER_ACCESS_ADMIN_ROLE_ID}}))"

echo "Asignando Role Based Access Control Administrator (con condicion anti-escalacion) en ${SCOPE}..."
az role assignment create \
    --assignee-object-id "$SP_OBJECT_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Role Based Access Control Administrator" \
    --scope "$SCOPE" \
    --condition "$ANTI_ESCALATION_CONDITION" \
    --condition-version "2.0" \
    -o none

# 4. Storage Blob Data Contributor (lectura+escritura) sobre la cuenta REAL resuelta
#    (sufijo de unicidad, issue #92). El 'terraform apply' escribe el state y toma el
#    lease/lock del blob; con el backend keyless por AAD (use_azuread_auth, #198) el SP
#    necesita escritura, no solo lectura. Reemplaza a 'Storage Blob Data Reader'.
echo "Asignando Storage Blob Data Contributor en ${TFSTATE_STORAGE}..."
az role assignment create \
    --assignee-object-id "$SP_OBJECT_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Storage Blob Data Contributor" \
    --scope "${SCOPE}/resourceGroups/${TFSTATE_RG}/providers/Microsoft.Storage/storageAccounts/${TFSTATE_STORAGE}" \
    -o none

# 5. Federated credentials para GitHub Actions OIDC. El subject debe coincidir EXACTO
#    con el claim que GitHub pone en el token; el matching de patrones no esta
#    soportado para ramas/tags (MEF-ADR-0022). El SP de CI necesita DOS:
#    - 'ref:refs/heads/main': lo usan el workflow de deploy del scaffolder y el job
#      'apply' de infra-cd.yml, que disparan en 'push: branches: [main]'.
#    - 'pull_request': lo usa el job 'plan' de infra-cd.yml (modelo plan-en-PR /
#      apply-en-merge-a-main, MEF-ADR-0022); su subject NO lleva el ref de la rama.
#    Fuentes: learn.microsoft.com/azure/app-service/deploy-github-actions y
#    learn.microsoft.com/entra/workload-id/workload-identity-federation-create-trust.
ensure_federated_credential() {
    local name="$1" subject="$2" description="$3" credentials managed_count exact_count params
    credentials=$(az ad app federated-credential list --id "$APP_ID" -o json) || {
        echo "ERROR: no se pudieron inspeccionar las federated credentials de la aplicacion '${APP_ID}'." >&2
        return 1
    }
    if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$credentials"; then
        echo "ERROR: Azure devolvio una lista invalida de federated credentials para '${APP_ID}'." >&2
        return 1
    fi
    managed_count=$(jq --arg name "$name" '[.[] | select(.name == $name)] | length' <<<"$credentials")
    if [ "$managed_count" -gt 1 ]; then
        echo "ERROR: Azure devolvio mas de una federated credential con el nombre administrado '${name}'." >&2
        return 1
    fi
    if [ "$managed_count" -eq 1 ] && jq -e --arg name "$name" --arg subject "$subject" \
        '.[] | select(.name == $name) | .subject == $subject and
         .issuer == "https://token.actions.githubusercontent.com" and
         .audiences == ["api://AzureADTokenExchange"]' >/dev/null <<<"$credentials"; then
        echo "Federated credential administrada '${name}' ya existe; se reutiliza."
        return 0
    fi
    params=$(jq -n --arg name "$name" --arg subject "$subject" --arg description "$description" '{
        name: $name,
        issuer: "https://token.actions.githubusercontent.com",
        subject: $subject,
        description: $description,
        audiences: ["api://AzureADTokenExchange"]
    }')
    if [ "$managed_count" -eq 1 ]; then
        echo "Reconciliando federated credential administrada '${name}' al subject, issuer y audience efectivos..."
        az ad app federated-credential update --id "$APP_ID" \
            --federated-credential-id "$name" --parameters "$params" -o none
        return 0
    fi
    exact_count=$(jq --arg subject "$subject" '[.[] | select(
        .issuer == "https://token.actions.githubusercontent.com" and .subject == $subject
    )] | length' <<<"$credentials")
    if [ "$exact_count" -ne 0 ]; then
        echo "ERROR: una federated credential ajena ya usa el subject efectivo de '${name}'." >&2
        echo "  Renombrala al nombre administrado '${name}' o retirala antes de reintentar; no se modifico automaticamente." >&2
        return 1
    fi
    echo "Creando federated credential administrada '${name}' para el subject efectivo..."
    az ad app federated-credential create --id "$APP_ID" --parameters "$params" -o none
}

ensure_federated_credential "github-actions-deploy-main" "$FED_SUBJECT_MAIN" \
    "GitHub Actions OIDC: deploy de codigo y apply de infra de ${HARNESS_PROJECT_NAME} desde la rama main"

ensure_federated_credential "github-actions-plan-pr" "$FED_SUBJECT_PR" \
    "GitHub Actions OIDC: terraform plan de ${HARNESS_PROJECT_NAME} en pull requests"

echo ""
echo "=== Roles asignados al Service Principal (${SP_NAME}) ==="
echo ""
echo "  Contributor                              -> ${SCOPE}"
echo "  Role Based Access Control Administrator  -> ${SCOPE}"
echo "    (con condicion anti-escalacion: no puede asignar Owner, User Access"
echo "    Administrator ni Role Based Access Control Administrator)"
echo "  Storage Blob Data Contributor            -> Storage Account del tfstate (${TFSTATE_STORAGE})"
echo ""
echo "=== Configura estos secrets en GitHub ==="
echo "Settings > Secrets and variables > Actions > New repository secret"
echo ""
echo "  AZURE_CLIENT_ID       = ${APP_ID}"
echo "  AZURE_TENANT_ID       = ${TENANT_ID}"
echo "  AZURE_SUBSCRIPTION_ID = ${SUBSCRIPTION_ID}"
echo ""
echo "Autenticacion por OIDC (Workload Identity Federation): NO hay client secret que"
echo "copiar ni que expire. Los workflows ya declaran 'permissions: id-token: write'"
echo "y se loguean con azure/login pasando esos tres valores (sin AZURE_CREDENTIALS)."
echo ""
echo "=== Federated credentials (subjects OIDC) ==="
echo ""
echo "  ${FED_SUBJECT_MAIN}"
echo "    (deploy de codigo y apply de infra: push a main)"
echo "  ${FED_SUBJECT_PR}"
echo "    (terraform plan de infra: pull_request)"
echo ""
echo "Si despliegas desde otra rama, tag o un GitHub Environment, anade otro federated"
echo "credential con el subject correspondiente (ver MEF-ADR-0022)."
echo ""
echo "=== Por que el SP necesita estos permisos ==="
echo ""
echo "El apply de infraestructura ocurre en CI bajo esta identidad federada, nunca"
echo "localmente (MEF-ADR-0022). El SP necesita:"
echo "  - Contributor: aplicar infra (Function Apps, Storage, etc.) y desplegar codigo."
echo "  - Role Based Access Control Administrator: crear los role assignments que"
echo "    emiten los scaffolders (Key Vault Secrets User, roles de datos de Storage;"
echo "    MEF-ADR-0025) -- Contributor los excluye explicitamente."
echo "  - Storage Blob Data Contributor: escribir el tfstate y tomar su lock por AAD"
echo "    (backend keyless, MEF-ADR-0025)."
echo "  - Federated credential 'pull_request': autenticar el 'terraform plan' que"
echo "    corre en cada PR sobre infra/** (modelo plan-en-PR / apply-en-merge-a-main)."
echo ""
echo "Listo."

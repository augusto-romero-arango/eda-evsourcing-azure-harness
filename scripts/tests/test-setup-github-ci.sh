#!/usr/bin/env bash
# test-setup-github-ci.sh -- Pruebas hermeticas del bootstrap OIDC de CI (#1208).
#
# Cubre la resolucion fail-closed de la pareja durable RG/Storage del backend y
# una reejecucion sobre una aplicacion/SP/roles ya existentes. az y gh se
# sustituyen por stubs: ninguna prueba consulta Azure ni GitHub reales.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETUP_SCRIPT="$REPO_ROOT/scripts/setup-github-ci.sh"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_contains() {
    local name="$1" needle="$2" file="$3"
    if grep -qF -- "$needle" "$file"; then pass "$name"; else fail "$name (ausente: $needle)"; fi
}
assert_not_contains() {
    local name="$1" needle="$2" file="$3"
    if grep -qF -- "$needle" "$file"; then fail "$name (presente: $needle)"; else pass "$name"; fi
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
FAKE_CONSUMER="$TMP_DIR/consumer"
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_CONSUMER/.claude" "$FAKE_BIN"

cat > "$FAKE_CONSUMER/.claude/harness.config.json" <<'JSON'
{
  "projectName": "Certificacion",
  "namespacePrefix": "Certificacion",
  "solutionFile": "Certificacion.slnx",
  "githubServicePrincipalName": "github-certificacion-ci",
  "domainLabels": ["certificacion"],
  "boundedContext": { "name": "Certificacion", "domains": ["certificacion"] }
}
JSON

cat > "$FAKE_BIN/git" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--show-toplevel" ]; then
    printf '%s\n' "$FAKE_CONSUMER"
    exit 0
fi
if [ "${1:-}" = "remote" ]; then
    printf '%s\n' 'https://github.com/acme/certificacion.git'
    exit 0
fi
exit 0
STUB

cat > "$FAKE_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$STUB_LOG"
printf '%s\n' 'acme/certificacion'
STUB

cat > "$FAKE_BIN/az" <<'STUB'
#!/usr/bin/env bash
printf 'az %s\n' "$*" >> "$STUB_LOG"
case "${1:-} ${2:-} ${3:-}" in
    "ad app list") printf '%s\n' 'app-existing' ;;
    "ad sp show")
        case " $* " in *" --query id "*) printf '%s\n' 'sp-object-existing' ;; esac
        ;;
    "account show --query") printf '%s\n' 'tenant-existing' ;;
    "role definition list")
        case " $* " in
            *" Owner "*) printf '%s\n' 'owner-id' ;;
            *" User Access Administrator "*) printf '%s\n' 'uaa-id' ;;
            *) printf '%s\n' 'rbac-id' ;;
        esac
        ;;
esac
STUB
chmod +x "$FAKE_BIN/git" "$FAKE_BIN/gh" "$FAKE_BIN/az"

write_backend() {
    local environment="$1" rg="$2" storage="$3"
    mkdir -p "$FAKE_CONSUMER/infra/environments/$environment"
    cat > "$FAKE_CONSUMER/infra/environments/$environment/backend.tf" <<EOF
terraform {
  backend "azurerm" {
    resource_group_name  = "$rg"
    storage_account_name = "$storage"
  }
}
EOF
}

run_case() {
    local scenario="$1"
    rm -rf "$FAKE_CONSUMER/infra"
    mkdir -p "$FAKE_CONSUMER/infra/environments"
    STUB_LOG="$TMP_DIR/$scenario.log"
    : > "$STUB_LOG"
    case "$scenario" in
        caf)
            write_backend dev 'rg-tfstate-mefisto-certification-dev-eus2-001' 'sttfstatemefisdeveus2001'
            ;;
        legacy)
            write_backend dev 'rg-certificacion-tfstate-legacy' 'stlegacycertificacion001'
            ;;
        invalid)
            mkdir -p "$FAKE_CONSUMER/infra/environments/dev"
            cat > "$FAKE_CONSUMER/infra/environments/dev/backend.tf" <<'EOF'
terraform {
  backend "azurerm" {
    resource_group_name  = var.tfstate_rg
    storage_account_name = "stvalidcertificacion001"
  }
}
EOF
            ;;
        partial)
            write_backend dev 'rg-tfstate-mefisto-certification-dev-eus2-001' 'sttfstatemefisdeveus2001'
            ;;
    esac
    (
        cd "$FAKE_CONSUMER" || exit 99
        FAKE_CONSUMER="$FAKE_CONSUMER" STUB_LOG="$STUB_LOG" PATH="$FAKE_BIN:$PATH" \
            "$SETUP_SCRIPT" subscription-test acme/certificacion
    ) >"$TMP_DIR/$scenario.out" 2>&1
    LAST_RC=$?
}

echo "[1] Backend CAF: usa exactamente la pareja durable (CA-1/CA-2)"
run_case caf
if [ "$LAST_RC" -eq 0 ]; then pass "backend CAF completa la configuracion"; else fail "backend CAF deberia completar (rc $LAST_RC)"; fi
assert_contains "scope CAF usa el RG real" '/resourceGroups/rg-tfstate-mefisto-certification-dev-eus2-001/providers/Microsoft.Storage/storageAccounts/sttfstatemefisdeveus2001' "$STUB_LOG"
assert_contains "crea subject main" 'repo:acme/certificacion:ref:refs/heads/main' "$STUB_LOG"
assert_contains "crea subject pull request" 'repo:acme/certificacion:pull_request' "$STUB_LOG"

echo "[2] Backend legacy: conserva ambos literales (CA-3)"
run_case legacy
if [ "$LAST_RC" -eq 0 ]; then pass "backend legacy completa la configuracion"; else fail "backend legacy deberia completar (rc $LAST_RC)"; fi
assert_contains "scope legacy conserva RG y Storage" '/resourceGroups/rg-certificacion-tfstate-legacy/providers/Microsoft.Storage/storageAccounts/stlegacycertificacion001' "$STUB_LOG"

echo "[3] Backend incompleto/no literal: aborta antes de Azure (CA-4)"
run_case invalid
if [ "$LAST_RC" -ne 0 ]; then pass "backend invalido aborta"; else fail "backend invalido no debe continuar"; fi
assert_contains "nombra candidato problematico" 'infra/environments/dev: resource_group_name y storage_account_name deben ser literales y completos' "$TMP_DIR/invalid.out"
assert_not_contains "backend invalido no llama Azure" 'az account set' "$STUB_LOG"

echo "[4] Reejecucion parcial: reutiliza identidad y completa roles/OIDC (CA-5)"
run_case partial
if [ "$LAST_RC" -eq 0 ]; then pass "reejecucion parcial completa"; else fail "reejecucion parcial deberia completar (rc $LAST_RC)"; fi
assert_not_contains "no recrea aplicacion existente" 'az ad app create' "$STUB_LOG"
assert_not_contains "no recrea SP existente" 'az ad sp create' "$STUB_LOG"
ROLE_CREATES=$(grep -cF 'az role assignment create' "$STUB_LOG" || true)
if [ "$ROLE_CREATES" -eq 3 ]; then pass "reaplica exactamente los tres roles idempotentes"; else fail "deberia aplicar tres roles (obtenido $ROLE_CREATES)"; fi
DATA_ROLE_CREATES=$(grep -cF 'Storage Blob Data Contributor' "$STUB_LOG" || true)
if [ "$DATA_ROLE_CREATES" -eq 1 ]; then pass "asigna un unico rol de datos"; else fail "deberia asignar un rol de datos (obtenido $DATA_ROLE_CREATES)"; fi
FEDERATED_CREATES=$(grep -cF 'az ad app federated-credential create' "$STUB_LOG" || true)
if [ "$FEDERATED_CREATES" -eq 2 ]; then pass "crea exactamente dos credenciales federadas"; else fail "deberia crear dos credenciales (obtenido $FEDERATED_CREATES)"; fi
assert_not_contains "OIDC no crea client secret" 'credential reset' "$STUB_LOG"

echo
echo "Resumen: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]

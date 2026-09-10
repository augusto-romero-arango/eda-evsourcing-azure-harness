#!/usr/bin/env bash
# test-setup-github-ci.sh -- Pruebas hermeticas del bootstrap OIDC de CI (#1216).
#
# Cubre metadata GitHub, subjects inmutables, reconciliacion e idempotencia sin
# perder las regresiones de backend y RBAC de #1210. az, gh y git son stubs:
# ninguna prueba consulta servicios reales ni obtiene tokens OIDC.

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
assert_count() {
    local name="$1" needle="$2" file="$3" expected="$4" actual
    actual=$(grep -cF -- "$needle" "$file" || true)
    if [ "$actual" -eq "$expected" ]; then pass "$name"; else fail "$name (esperado $expected, obtenido $actual)"; fi
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
elif [ "${1:-}" = "remote" ]; then
    printf '%s\n' 'https://github.com/acme/certificacion.git'
fi
STUB

cat > "$FAKE_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$STUB_LOG"
case "${1:-}" in
    repo) printf '%s\n' "$GH_SLUG" ;;
    api)
        [ "${GH_API_FAIL:-0}" -eq 0 ] || exit 1
        printf '%s\n' "$GH_METADATA"
        ;;
    *) exit 1 ;;
esac
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
    "ad app federated-credential")
        action="${4:-}"
        if [ "$action" = "list" ]; then
            cat "$FED_STATE"
            exit 0
        fi
        params=""
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "--parameters" ]; then shift; params="${1:-}"; break; fi
            shift
        done
        [ -n "$params" ] || exit 2
        if [ "$action" = "create" ]; then
            jq --argjson item "$params" '. + [$item]' "$FED_STATE" > "${FED_STATE}.next"
        elif [ "$action" = "update" ]; then
            jq --argjson item "$params" 'map(if .name == $item.name then $item else . end)' "$FED_STATE" > "${FED_STATE}.next"
        else
            exit 2
        fi
        mv "${FED_STATE}.next" "$FED_STATE"
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

write_credential_state() {
    local name="$1" subject="$2"
    jq -n --arg name "$name" --arg subject "$subject" '{
        name: $name,
        issuer: "https://token.actions.githubusercontent.com",
        subject: $subject,
        description: "fixture",
        audiences: ["api://AzureADTokenExchange"]
    }'
}

run_case() {
    local scenario="$1" slug="${2:-acme/certificacion}" runs="${3:-1}" rc=0 i
    rm -rf "$FAKE_CONSUMER/infra"
    mkdir -p "$FAKE_CONSUMER/infra/environments/dev"
    STUB_LOG="$TMP_DIR/$scenario.log"
    FED_STATE="$TMP_DIR/$scenario.state"
    GH_SLUG='acme/certificacion'
    GH_METADATA='{"full_name":"acme/certificacion","owner":{"id":101},"id":202}'
    GH_API_FAIL=0
    printf '[]\n' > "$FED_STATE"
    : > "$STUB_LOG"

    case "$scenario" in
        backend-caf|automatico|explicito|metadata-ajena|metadata-sin-ids|metadata-no-disponible|legacy|idempotente|contrato-invalido)
            write_backend dev 'rg-tfstate-mefisto-certification-dev-eus2-001' 'sttfstatemefisdeveus2001'
            ;;
        backend-legacy)
            write_backend dev 'rg-certificacion-tfstate-legacy' 'stlegacycertificacion001'
            ;;
        backend-invalido)
            cat > "$FAKE_CONSUMER/infra/environments/dev/backend.tf" <<'EOF'
terraform {
  backend "azurerm" {
    resource_group_name  = var.tfstate_rg
    storage_account_name = "stvalidcertificacion001"
  }
}
EOF
            ;;
        backend-ausente)
            printf '%s\n' 'terraform { required_version = ">= 1.9" }' > "$FAKE_CONSUMER/infra/environments/dev/versions.tf"
            ;;
        backend-incompleto)
            cat > "$FAKE_CONSUMER/infra/environments/dev/backend.tf" <<'EOF'
terraform {
  backend "azurerm" {
    resource_group_name = "rg-tfstate-incompleto"
  }
}
EOF
            ;;
        backend-ambiguo)
            write_backend dev 'rg-tfstate-dev' 'sttfstatecertdev001'
            write_backend prod 'rg-tfstate-prod' 'sttfstatecertprod001'
            ;;
    esac

    case "$scenario" in
        explicito) GH_METADATA='{"full_name":"acme/explicito","owner":{"id":303},"id":404}' ;;
        metadata-ajena) GH_METADATA='{"full_name":"acme/otro","owner":{"id":101},"id":202}' ;;
        metadata-sin-ids) GH_METADATA='{"full_name":"acme/certificacion","owner":{"id":0},"id":202}' ;;
        metadata-no-disponible) GH_API_FAIL=1 ;;
        legacy)
            jq -s '.' \
                <(write_credential_state 'github-actions-deploy-main' 'repo:acme/certificacion:ref:refs/heads/main') \
                <(write_credential_state 'github-actions-plan-pr' 'repo:acme/certificacion:pull_request') \
                <(write_credential_state 'credencial-ajena' 'repo:otra/identidad:pull_request') > "$FED_STATE"
            ;;
        contrato-invalido)
            jq -s '.[0].audiences = ["audience-incorrecta"]' \
                <(write_credential_state 'github-actions-deploy-main' 'repo:acme@101/certificacion@202:ref:refs/heads/main') > "$FED_STATE"
            ;;
    esac

    : > "$TMP_DIR/$scenario.out"
    for ((i=1; i<=runs; i++)); do
        rc=0
        if [ "$scenario" = "automatico" ]; then
            (cd "$FAKE_CONSUMER" && FAKE_CONSUMER="$FAKE_CONSUMER" STUB_LOG="$STUB_LOG" FED_STATE="$FED_STATE" \
                GH_SLUG="$GH_SLUG" GH_METADATA="$GH_METADATA" GH_API_FAIL="$GH_API_FAIL" PATH="$FAKE_BIN:$PATH" \
                "$SETUP_SCRIPT" subscription-test) >> "$TMP_DIR/$scenario.out" 2>&1 || rc=$?
        else
            (cd "$FAKE_CONSUMER" && FAKE_CONSUMER="$FAKE_CONSUMER" STUB_LOG="$STUB_LOG" FED_STATE="$FED_STATE" \
                GH_SLUG="$GH_SLUG" GH_METADATA="$GH_METADATA" GH_API_FAIL="$GH_API_FAIL" PATH="$FAKE_BIN:$PATH" \
                "$SETUP_SCRIPT" subscription-test "$slug") >> "$TMP_DIR/$scenario.out" 2>&1 || rc=$?
        fi
        [ "$rc" -eq 0 ] || break
    done
    LAST_RC=$rc
}

echo "[1] Creacion limpia y resolucion automatica usan el subject inmutable documentado"
run_case automatico
[ "$LAST_RC" -eq 0 ] && pass "creacion limpia completa" || fail "creacion limpia deberia completar (rc $LAST_RC)"
assert_contains "consulta metadata del slug resuelto" 'gh api repos/acme/certificacion' "$STUB_LOG"
assert_contains "subject main intercala IDs" 'repo:acme@101/certificacion@202:ref:refs/heads/main' "$STUB_LOG"
assert_contains "subject PR intercala IDs" 'repo:acme@101/certificacion@202:pull_request' "$STUB_LOG"
assert_count "crea dos credenciales administradas" 'az ad app federated-credential create' "$STUB_LOG" 2
assert_not_contains "OIDC no crea client secret" 'credential reset' "$STUB_LOG"

echo "[2] El argumento explicito consulta y valida ese mismo slug"
run_case explicito acme/explicito
[ "$LAST_RC" -eq 0 ] && pass "argumento explicito completa" || fail "argumento explicito deberia completar (rc $LAST_RC)"
assert_contains "consulta metadata del argumento" 'gh api repos/acme/explicito' "$STUB_LOG"
assert_contains "subject explicito usa sus IDs" 'repo:acme@303/explicito@404:pull_request' "$STUB_LOG"

echo "[3] Metadata invalida o inaccesible aborta antes de cualquier efecto Azure"
run_case metadata-ajena
[ "$LAST_RC" -ne 0 ] && pass "metadata ajena aborta" || fail "metadata ajena no debe continuar"
assert_contains "explica metadata no correspondiente" "no de 'acme/certificacion'" "$TMP_DIR/metadata-ajena.out"
assert_not_contains "metadata ajena no llama Azure" 'az ' "$STUB_LOG"
run_case metadata-sin-ids
[ "$LAST_RC" -ne 0 ] && pass "metadata sin IDs aborta" || fail "metadata sin IDs no debe continuar"
assert_contains "explica IDs invalidos" 'IDs inmutables validos' "$TMP_DIR/metadata-sin-ids.out"
assert_not_contains "metadata sin IDs no llama Azure" 'az ' "$STUB_LOG"
run_case metadata-no-disponible
[ "$LAST_RC" -ne 0 ] && pass "metadata inaccesible aborta" || fail "metadata inaccesible no debe continuar"
assert_contains "error de metadata es accionable" "Autentica 'gh' con acceso" "$TMP_DIR/metadata-no-disponible.out"
assert_not_contains "metadata inaccesible no llama Azure" 'az ' "$STUB_LOG"

echo "[4] Reconcilia solo los nombres administrados y preserva credenciales ajenas"
run_case legacy
[ "$LAST_RC" -eq 0 ] && pass "migracion completa" || fail "migracion deberia completar (rc $LAST_RC)"
assert_count "reconcilia exactamente dos credenciales" 'az ad app federated-credential update' "$STUB_LOG" 2
assert_count "migracion no crea duplicados" 'az ad app federated-credential create' "$STUB_LOG" 0
[ "$(jq 'length' "$FED_STATE")" -eq 3 ] && pass "estado conserva tres credenciales" || fail "estado deberia conservar tres credenciales"
[ "$(jq '[.[] | select(.name == "credencial-ajena")] | length' "$FED_STATE")" -eq 1 ] && pass "preserva credencial ajena" || fail "no preservo credencial ajena"
assert_contains "estado main queda inmutable" 'repo:acme@101/certificacion@202:ref:refs/heads/main' "$FED_STATE"
assert_contains "estado PR queda inmutable" 'repo:acme@101/certificacion@202:pull_request' "$FED_STATE"

echo "[5] Repara issuer/audience del nombre administrado aunque el subject ya coincida"
run_case contrato-invalido
[ "$LAST_RC" -eq 0 ] && pass "repara contrato OIDC" || fail "deberia reparar contrato OIDC (rc $LAST_RC)"
assert_count "reconcilia contrato invalido" 'az ad app federated-credential update' "$STUB_LOG" 1
[ "$(jq '[.[] | select(.audiences == ["api://AzureADTokenExchange"])] | length' "$FED_STATE")" -eq 2 ] && pass "audiences finales son canonicas" || fail "audiences finales deberian ser canonicas"

echo "[6] Una segunda ejecucion deja exactamente dos credenciales administradas"
run_case idempotente acme/certificacion 2
[ "$LAST_RC" -eq 0 ] && pass "dos ejecuciones completan" || fail "segunda ejecucion deberia completar (rc $LAST_RC)"
assert_count "dos ejecuciones crean solo dos credenciales" 'az ad app federated-credential create' "$STUB_LOG" 2
assert_count "segunda ejecucion no reconcilia" 'az ad app federated-credential update' "$STUB_LOG" 0
[ "$(jq '[.[] | select(.name | startswith("github-actions-"))] | length' "$FED_STATE")" -eq 2 ] && pass "estado final tiene dos administradas" || fail "estado final deberia tener dos administradas"
assert_contains "informa reutilizacion" 'ya existe; se reutiliza' "$TMP_DIR/idempotente.out"

echo "[7] Conserva la pareja durable del tfstate y los tres roles RBAC"
run_case backend-caf
[ "$LAST_RC" -eq 0 ] && pass "backend CAF completa" || fail "backend CAF deberia completar (rc $LAST_RC)"
assert_contains "scope usa RG y Storage reales" '/resourceGroups/rg-tfstate-mefisto-certification-dev-eus2-001/providers/Microsoft.Storage/storageAccounts/sttfstatemefisdeveus2001' "$STUB_LOG"
assert_count "asigna exactamente tres roles" 'az role assignment create' "$STUB_LOG" 3
assert_count "asigna un rol de datos del tfstate" 'Storage Blob Data Contributor' "$STUB_LOG" 1
assert_not_contains "no recrea aplicacion existente" 'az ad app create' "$STUB_LOG"
assert_not_contains "no recrea SP existente" 'az ad sp create' "$STUB_LOG"
run_case backend-legacy
[ "$LAST_RC" -eq 0 ] && pass "backend legacy completa" || fail "backend legacy deberia completar (rc $LAST_RC)"
assert_contains "scope legacy conserva ambos literales" '/resourceGroups/rg-certificacion-tfstate-legacy/providers/Microsoft.Storage/storageAccounts/stlegacycertificacion001' "$STUB_LOG"

echo "[8] Backends invalidos siguen fallando antes de GitHub y Azure"
for scenario in backend-invalido backend-ausente backend-incompleto backend-ambiguo; do
    run_case "$scenario"
    [ "$LAST_RC" -ne 0 ] && pass "$scenario aborta" || fail "$scenario no debe continuar"
    assert_not_contains "$scenario no consulta GitHub" 'gh ' "$STUB_LOG"
    assert_not_contains "$scenario no llama Azure" 'az ' "$STUB_LOG"
done
assert_contains "reporta backend no literal" 'resource_group_name y storage_account_name deben ser literales y completos' "$TMP_DIR/backend-invalido.out"
assert_contains "reporta backend ausente" 'no contiene un bloque backend azurerm' "$TMP_DIR/backend-ausente.out"
assert_contains "reporta backend incompleto" 'resource_group_name y storage_account_name deben ser literales y completos' "$TMP_DIR/backend-incompleto.out"
assert_contains "reporta candidato dev ambiguo" 'infra/environments/dev|rg-tfstate-dev|sttfstatecertdev001' "$TMP_DIR/backend-ambiguo.out"
assert_contains "reporta candidato prod ambiguo" 'infra/environments/prod|rg-tfstate-prod|sttfstatecertprod001' "$TMP_DIR/backend-ambiguo.out"

echo
echo "Resumen: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]

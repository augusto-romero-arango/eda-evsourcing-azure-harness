#!/usr/bin/env bash
# test-setup-github-ci.sh -- Pruebas hermeticas del bootstrap OIDC de CI (#1216).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETUP_SCRIPT="$REPO_ROOT/scripts/setup-github-ci.sh"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_contains() { grep -qF -- "$2" "$3" && pass "$1" || fail "$1 (ausente: $2)"; }
assert_not_contains() { grep -qF -- "$2" "$3" && fail "$1 (presente: $2)" || pass "$1"; }
assert_count() { local actual; actual=$(grep -cF -- "$2" "$3" || true); [ "$actual" -eq "$4" ] && pass "$1" || fail "$1 (esperado $4, obtenido $actual)"; }

TMP_DIR=$(mktemp -d); trap 'rm -rf "$TMP_DIR"' EXIT
FAKE_CONSUMER="$TMP_DIR/consumer"; FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_CONSUMER/.claude" "$FAKE_BIN"
cat > "$FAKE_CONSUMER/.claude/harness.config.json" <<'JSON'
{"projectName":"Certificacion","namespacePrefix":"Certificacion","solutionFile":"Certificacion.slnx","githubServicePrincipalName":"github-certificacion-ci","domainLabels":["certificacion"],"boundedContext":{"name":"Certificacion","domains":["certificacion"]}}
JSON
cat > "$FAKE_BIN/git" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "rev-parse" ]; then printf '%s\n' "$FAKE_CONSUMER"; elif [ "${1:-}" = "remote" ]; then printf '%s\n' 'https://github.com/acme/certificacion.git'; fi
STUB
cat > "$FAKE_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$STUB_LOG"
if [ "${1:-}" = "repo" ]; then printf '%s\n' "$GH_SLUG"; elif [ "${1:-}" = "api" ]; then printf '%s\n' "$GH_METADATA"; else exit 1; fi
STUB
cat > "$FAKE_BIN/az" <<'STUB'
#!/usr/bin/env bash
printf 'az %s\n' "$*" >> "$STUB_LOG"
case "${1:-} ${2:-} ${3:-}" in
  "ad app list") printf '%s\n' 'app-existing' ;;
  "ad sp show") case " $* " in *" --query id "*) printf '%s\n' 'sp-object-existing' ;; esac ;;
  "account show --query") printf '%s\n' 'tenant-existing' ;;
  "role definition list") case " $* " in *" Owner "*) printf '%s\n' 'owner-id' ;; *" User Access Administrator "*) printf '%s\n' 'uaa-id' ;; *) printf '%s\n' 'rbac-id' ;; esac ;;
  "ad app federated-credential")
    case "${4:-}" in
      list)
        query="${*: -3:1}"; name=$(printf '%s' "$query" | grep -o "name=='[^']*'" | cut -d"'" -f2)
        if [ -n "$name" ] && [ -f "$FED_STATE" ]; then grep -F "${name}|" "$FED_STATE" | cut -d'|' -f2 | head -n 1; fi
        ;;
      create|update)
        params="${*: -3:1}"; entry=$(printf '%s' "$params" | jq -r '.name + "|" + .subject'); name="${entry%%|*}"
        grep -v -F "${name}|" "$FED_STATE" > "${FED_STATE}.next" || true; mv "${FED_STATE}.next" "$FED_STATE"; printf '%s\n' "$entry" >> "$FED_STATE"
        ;;
    esac ;;
esac
STUB
chmod +x "$FAKE_BIN/git" "$FAKE_BIN/gh" "$FAKE_BIN/az"

write_backend() {
    mkdir -p "$FAKE_CONSUMER/infra/environments/dev"
    cat > "$FAKE_CONSUMER/infra/environments/dev/backend.tf" <<'EOF'
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-mefisto-certification-dev-eus2-001"
    storage_account_name = "sttfstatemefisdeveus2001"
  }
}
EOF
}
run_case() {
    local scenario="$1" slug="${2:-acme/certificacion}" runs="${3:-1}" rc=0 i
    rm -rf "$FAKE_CONSUMER/infra"; write_backend
    STUB_LOG="$TMP_DIR/$scenario.log"; FED_STATE="$TMP_DIR/$scenario.state"; : > "$STUB_LOG"; : > "$FED_STATE"
    GH_SLUG='acme/certificacion'; GH_METADATA='{"full_name":"acme/certificacion","owner":{"id":101},"id":202}'
    case "$scenario" in
      metadata-invalida) GH_METADATA='{"full_name":"acme/otro","owner":{"id":101},"id":202}' ;;
      metadata-sin-ids) GH_METADATA='{"full_name":"acme/certificacion","owner":{"id":0},"id":202}' ;;
      legacy) printf '%s\n' 'github-actions-deploy-main|repo:acme/certificacion:ref:refs/heads/main' 'github-actions-plan-pr|repo:acme/certificacion:pull_request' > "$FED_STATE" ;;
      explicito) GH_METADATA='{"full_name":"acme/explicito","owner":{"id":303},"id":404}' ;;
    esac
    : > "$TMP_DIR/$scenario.out"
    for ((i=1; i<=runs; i++)); do
      if [ "$scenario" = "automatico" ]; then
        (cd "$FAKE_CONSUMER" && FAKE_CONSUMER="$FAKE_CONSUMER" STUB_LOG="$STUB_LOG" FED_STATE="$FED_STATE" GH_SLUG="$GH_SLUG" GH_METADATA="$GH_METADATA" PATH="$FAKE_BIN:$PATH" "$SETUP_SCRIPT" subscription-test) >> "$TMP_DIR/$scenario.out" 2>&1 || rc=$?
      else
        (cd "$FAKE_CONSUMER" && FAKE_CONSUMER="$FAKE_CONSUMER" STUB_LOG="$STUB_LOG" FED_STATE="$FED_STATE" GH_SLUG="$GH_SLUG" GH_METADATA="$GH_METADATA" PATH="$FAKE_BIN:$PATH" "$SETUP_SCRIPT" subscription-test "$slug") >> "$TMP_DIR/$scenario.out" 2>&1 || rc=$?
      fi
    done
    LAST_RC=$rc
}

echo "[1] Resolucion automatica y creacion limpia usan subjects OIDC inmutables"
run_case automatico
[ "$LAST_RC" -eq 0 ] && pass "creacion limpia completa" || fail "creacion limpia deberia completar"
assert_contains "consulta metadata del slug" 'gh api repos/acme/certificacion' "$STUB_LOG"
assert_contains "subject main con IDs" 'repo:acme/certificacion:repository_owner_id:101:repository_id:202:ref:refs/heads/main' "$STUB_LOG"
assert_contains "subject PR con IDs" 'repo:acme/certificacion:repository_owner_id:101:repository_id:202:pull_request' "$STUB_LOG"
assert_count "crea dos credenciales administradas" 'az ad app federated-credential create' "$STUB_LOG" 2
assert_not_contains "OIDC no crea client secret" 'credential reset' "$STUB_LOG"

echo "[2] Argumento explicito consulta y valida ese mismo slug"
run_case explicito acme/explicito
[ "$LAST_RC" -eq 0 ] && pass "argumento explicito completa" || fail "argumento explicito deberia completar"
assert_contains "metadata consulta argumento explicito" 'gh api repos/acme/explicito' "$STUB_LOG"
assert_contains "subject explicito usa sus IDs" 'repo:acme/explicito:repository_owner_id:303:repository_id:404:pull_request' "$STUB_LOG"

echo "[3] Metadata ajena aborta antes de toda mutacion Azure"
run_case metadata-invalida
[ "$LAST_RC" -ne 0 ] && pass "metadata invalida aborta" || fail "metadata invalida no debe continuar"
assert_contains "explica metadata no correspondiente" "no de 'acme/certificacion'" "$TMP_DIR/metadata-invalida.out"
assert_not_contains "metadata invalida no llama Azure" 'az ' "$STUB_LOG"

echo "[4] Metadata sin IDs validos aborta antes de toda mutacion Azure"
run_case metadata-sin-ids
[ "$LAST_RC" -ne 0 ] && pass "metadata sin IDs aborta" || fail "metadata sin IDs no debe continuar"
assert_contains "explica IDs invalidos" 'IDs inmutables validos' "$TMP_DIR/metadata-sin-ids.out"
assert_not_contains "metadata sin IDs no llama Azure" 'az ' "$STUB_LOG"

echo "[5] Migra los dos subjects nominales solo por nombres administrados"
run_case legacy
[ "$LAST_RC" -eq 0 ] && pass "migracion completa" || fail "migracion deberia completar"
assert_count "reconcilia exactamente dos credenciales" 'az ad app federated-credential update' "$STUB_LOG" 2
assert_count "migracion no duplica credenciales" 'az ad app federated-credential create' "$STUB_LOG" 0
assert_contains "estado main migrado" 'github-actions-deploy-main|repo:acme/certificacion:repository_owner_id:101:repository_id:202:ref:refs/heads/main' "$FED_STATE"
assert_contains "estado PR migrado" 'github-actions-plan-pr|repo:acme/certificacion:repository_owner_id:101:repository_id:202:pull_request' "$FED_STATE"

echo "[6] Segunda ejecucion es idempotente"
run_case idempotente acme/certificacion 2
[ "$LAST_RC" -eq 0 ] && pass "dos ejecuciones completan" || fail "segunda ejecucion deberia completar"
assert_count "dos ejecuciones crean solo dos credenciales" 'az ad app federated-credential create' "$STUB_LOG" 2
assert_count "segunda ejecucion no reconcilia" 'az ad app federated-credential update' "$STUB_LOG" 0
assert_count "estado final tiene dos credenciales" 'github-actions-' "$FED_STATE" 2
assert_contains "informa reutilizacion" 'ya existe; se reutiliza' "$TMP_DIR/idempotente.out"

echo; echo "Resumen: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]

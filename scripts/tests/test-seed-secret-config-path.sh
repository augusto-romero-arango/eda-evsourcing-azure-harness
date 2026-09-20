#!/usr/bin/env bash
# test-seed-secret-config-path.sh -- Contrato de escritura canonica de /seed-secret (#1505).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/seed-secret.sh"
COMMAND="$REPO_ROOT/commands/seed-secret.md"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq no esta instalado; seed-secret requiere jq." >&2
    exit 0
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

write_config() {
    local path="$1" project="$2"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<JSON
{
  "projectName": "$project",
  "namespacePrefix": "$project.Dominio",
  "solutionFile": "$project.slnx",
  "infraResourceGroupPrefix": "rg-$project",
  "terraformStateStorage": "st${project}state",
  "domainLabels": ["facturacion"],
  "boundedContext": { "name": "Principal", "domains": ["facturacion"] }
}
JSON
}

prepare_consumer() {
    local root="$1"
    mkdir -p "$root/infra/environments/dev"
    git init -q "$root"
    cat > "$root/infra/environments/dev/dominio-facturacion.tf" <<'HCL'
module "function_app_facturacion" {
  app_settings = {}
}
HCL
}

run_seed_secret() {
    local root="$1" output="$2"
    (
        cd "$root" || exit 1
        "$SCRIPT" stripe-api-key --domain facturacion --from-output stripe_api_key
    ) > "$output" 2>&1
}

echo "[0] Sintaxis del script"
if bash -n "$SCRIPT"; then
    pass "seed-secret.sh tiene sintaxis Bash valida"
else
    fail "seed-secret.sh tiene errores de sintaxis Bash"
fi

echo "[1] Consumidor canonico: registra y anuncia la ruta escrita"
CANONICAL_ROOT="$TMP_DIR/canonical"
prepare_consumer "$CANONICAL_ROOT"
write_config "$CANONICAL_ROOT/.mefisto/harness.config.json" canonical
CANONICAL_OUT="$TMP_DIR/canonical.out"
CANONICAL_PATH="$(cd "$CANONICAL_ROOT" && pwd -P)/.mefisto/harness.config.json"
RC=0; run_seed_secret "$CANONICAL_ROOT" "$CANONICAL_OUT" || RC=$?
if [ "$RC" -eq 0 ]; then pass "canonico termina con exit 0"; else fail "canonico termino con exit $RC"; fi
if grep -Fq "OK: 'stripe-api-key' registrado en $CANONICAL_PATH > secrets[]" "$CANONICAL_OUT" \
    && grep -Fxq "Registro: $CANONICAL_PATH" "$CANONICAL_OUT"; then
    pass "OK y Registro nombran la ruta canonica efectiva"
else
    fail "OK o Registro no nombran la ruta canonica efectiva"
fi
if [ "$(jq -r '.secrets[0] | [.name, .source.type, .source.value] | join("|")' "$CANONICAL_ROOT/.mefisto/harness.config.json")" = "stripe-api-key|output|stripe_api_key" ]; then
    pass "secrets[] se actualiza en el config canonico"
else
    fail "secrets[] no se actualizo en el config canonico"
fi

echo "[2] Ambos configs: escribe solo el canonico"
BOTH_ROOT="$TMP_DIR/both"
prepare_consumer "$BOTH_ROOT"
write_config "$BOTH_ROOT/.mefisto/harness.config.json" canonical
write_config "$BOTH_ROOT/.claude/harness.config.json" legacy
cp "$BOTH_ROOT/.claude/harness.config.json" "$TMP_DIR/legacy-both.before"
BOTH_OUT="$TMP_DIR/both.out"
BOTH_PATH="$(cd "$BOTH_ROOT" && pwd -P)/.mefisto/harness.config.json"
RC=0; run_seed_secret "$BOTH_ROOT" "$BOTH_OUT" || RC=$?
if [ "$RC" -eq 0 ] && cmp -s "$TMP_DIR/legacy-both.before" "$BOTH_ROOT/.claude/harness.config.json"; then
    pass "ambos conserva byte a byte el legacy"
else
    fail "ambos fallo o modifico el legacy"
fi
if [ "$(jq -r '.secrets[0].name' "$BOTH_ROOT/.mefisto/harness.config.json")" = "stripe-api-key" ] \
    && grep -Fxq "Registro: $BOTH_PATH" "$BOTH_OUT"; then
    pass "ambos registra y anuncia solo el canonico"
else
    fail "ambos no registro o anuncio el canonico"
fi

echo "[3] Consumidor solo legacy: aborta sin mutar ni migrar"
LEGACY_ROOT="$TMP_DIR/legacy"
prepare_consumer "$LEGACY_ROOT"
write_config "$LEGACY_ROOT/.claude/harness.config.json" legacy
cp "$LEGACY_ROOT/.claude/harness.config.json" "$TMP_DIR/legacy-only.before"
LEGACY_OUT="$TMP_DIR/legacy.out"
RC=0; run_seed_secret "$LEGACY_ROOT" "$LEGACY_OUT" || RC=$?
if [ "$RC" -eq 1 ] && [ ! -e "$LEGACY_ROOT/.mefisto/harness.config.json" ] \
    && cmp -s "$TMP_DIR/legacy-only.before" "$LEGACY_ROOT/.claude/harness.config.json"; then
    pass "solo legacy aborta y queda byte a byte intacto"
else
    fail "solo legacy no aborto o muto el config"
fi
if grep -Fq "Migra conscientemente el archivo completo" "$LEGACY_OUT"; then
    pass "solo legacy indica migrar antes"
else
    fail "solo legacy no indica migrar antes"
fi

echo "[4] Script y skill no presentan el config legacy como destino del consumidor"
if grep -Eq '^[[:space:]]*#.*\.claude/harness\.config\.json|^[[:space:]]*echo.*\.claude/harness\.config\.json' "$SCRIPT"; then
    fail "seed-secret vuelve a anunciar el config legacy"
else
    pass "seed-secret no anuncia el config legacy"
fi
if grep -Eq 'git add[[:space:]].*\.claude/harness\.config\.json|\.claude/harness\.config\.json' "$COMMAND"; then
    fail "seed-secret.md vuelve a instruir el uso del config legacy"
else
    pass "seed-secret.md usa solo el contrato canonico para el registro"
fi

echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]

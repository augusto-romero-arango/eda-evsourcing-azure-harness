#!/usr/bin/env bash
# test-bootstrap-backend-config-path.sh -- Contrato de azureLocation efectivo (#1503).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/bootstrap-backend.sh"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/az" <<'EOF'
#!/usr/bin/env bash
# El resumen ya se imprimio; no se permite ninguna operacion real de Azure.
exit 1
EOF
chmod +x "$TMP_DIR/bin/az"

write_config() {
    local path="$1" location="$2" location_fragment=""
    mkdir -p "$(dirname "$path")"
    if [ -n "$location" ]; then
        location_fragment=$(printf '  "azureLocation": "%s",\n' "$location")
    fi
    cat > "$path" <<EOF
{
  "projectName": "Prueba",
  "namespacePrefix": "Prueba.Backend",
  "solutionFile": "Prueba.slnx",
  "infraResourceGroupPrefix": "rg-prueba",
  "terraformStateStorage": "stpruebatfstate",
  "githubServicePrincipalName": "github-prueba-ci",
  "appInsightsApp": "appi-prueba",
  "domainLabels": ["prueba"],
${location_fragment}  "boundedContext": { "name": "Principal", "domains": ["prueba"] }
}
EOF
}

run_bootstrap() {
    local root="$1"
    (cd "$root" && PATH="$TMP_DIR/bin:$PATH" "$SCRIPT" --subscription suscripcion-ficticia 2>&1)
}

assert_region() {
    local label="$1" root="$2" expected="$3" output
    output=$(run_bootstrap "$root") || true
    if grep -Fq "Region:          $expected" <<< "$output"; then
        pass "$label resuelve '$expected'"
    else
        fail "$label no resolvio '$expected': $output"
    fi
}

echo "[1] Consumidor canonico sin --location"
CANONICAL_ROOT="$TMP_DIR/canonical"
mkdir -p "$CANONICAL_ROOT"
git -C "$CANONICAL_ROOT" init -q
write_config "$CANONICAL_ROOT/.mefisto/harness.config.json" "westeurope"
assert_region "canonico" "$CANONICAL_ROOT" "westeurope"

echo "[2] Ambos configs divergentes"
BOTH_ROOT="$TMP_DIR/both"
mkdir -p "$BOTH_ROOT"
git -C "$BOTH_ROOT" init -q
write_config "$BOTH_ROOT/.mefisto/harness.config.json" "eastus2"
write_config "$BOTH_ROOT/.claude/harness.config.json" "centralus"
BOTH_ROOT_PHYSICAL=$(cd "$BOTH_ROOT" && pwd -P)
BOTH_OUTPUT=$(run_bootstrap "$BOTH_ROOT") || true
if grep -Fq "Region:          eastus2" <<< "$BOTH_OUTPUT" \
    && ! grep -Fq "Region:          centralus" <<< "$BOTH_OUTPUT" \
    && grep -Fq "AVISO: se usara el config canonico $BOTH_ROOT_PHYSICAL/.mefisto/harness.config.json; se ignora el legacy $BOTH_ROOT_PHYSICAL/.claude/harness.config.json." <<< "$BOTH_OUTPUT"; then
    pass "coexistencia avisa y usa solo el config canonico"
else
    fail "coexistencia no respeto la precedencia canonica: $BOTH_OUTPUT"
fi

echo "[3] Consumidor legacy"
LEGACY_ROOT="$TMP_DIR/legacy"
mkdir -p "$LEGACY_ROOT"
git -C "$LEGACY_ROOT" init -q
write_config "$LEGACY_ROOT/.claude/harness.config.json" "uksouth"
assert_region "legacy" "$LEGACY_ROOT" "uksouth"

echo "[4] El flag conserva prioridad"
FLAG_OUTPUT=$(cd "$CANONICAL_ROOT" && PATH="$TMP_DIR/bin:$PATH" "$SCRIPT" --subscription suscripcion-ficticia --location northeurope 2>&1) || true
if grep -Fq "Region:          northeurope" <<< "$FLAG_OUTPUT"; then
    pass "--location prevalece sobre el config"
else
    fail "--location no prevalecio: $FLAG_OUTPUT"
fi

echo "[5] Campo ausente"
MISSING_ROOT="$TMP_DIR/missing"
mkdir -p "$MISSING_ROOT"
git -C "$MISSING_ROOT" init -q
write_config "$MISSING_ROOT/.mefisto/harness.config.json" ""
MISSING_OUTPUT=$(run_bootstrap "$MISSING_ROOT")
MISSING_RC=$?
if [ "$MISSING_RC" -ne 0 ] \
    && grep -Fq 'Pasa --location <region>' <<< "$MISSING_OUTPUT" \
    && grep -Fq '"azureLocation"' <<< "$MISSING_OUTPUT" \
    && ! grep -Fq '.claude/harness.config.json' <<< "$MISSING_OUTPUT"; then
    pass "ausencia aborta sin nombrar la ruta legacy"
else
    fail "ausencia no emitio el diagnostico esperado: $MISSING_OUTPUT"
fi

echo "[6] Anti-regresion de lecturas y mensajes legacy"
if grep -Eq '(^|[;&|[:space:]])(jq|cat)[[:space:]].*\.claude/harness\.config\.json|<[[:space:]]*[^[:space:]]*\.claude/harness\.config\.json' "$SCRIPT"; then
    fail "reaparecio una lectura directa del config legacy"
else
    pass "no hay lecturas directas del config legacy"
fi
if grep -Fq '.claude/harness.config.json' "$SCRIPT"; then
    fail "reaparecio la ruta legacy en el script"
else
    pass "el script no nombra la ruta legacy"
fi
if grep -Fq "jq -r '.azureLocation // empty' \"\$HARNESS_CONFIG_PATH\"" "$SCRIPT"; then
    pass "azureLocation se lee desde HARNESS_CONFIG_PATH"
else
    fail "azureLocation no usa HARNESS_CONFIG_PATH"
fi

echo "----------------------------------------"
echo "  Resumen: $PASS pass, $FAIL fail"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]

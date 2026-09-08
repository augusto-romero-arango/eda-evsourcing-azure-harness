#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONTRACT_DIR="$REPO_ROOT/src/published/contract"
VALIDATOR="$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh"
PASS=0 FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "[pre] contrato publicado"
for f in "$CONTRACT_DIR/published-artifact.schema.json" "$VALIDATOR" "$REPO_ROOT/src/published/scripts/lib/jsonschema-lite.jq"; do [ -f "$f" ] && pass "existe: ${f#"$REPO_ROOT"/}" || fail "no existe: ${f#"$REPO_ROOT"/}"; done
[ -x "$VALIDATOR" ] && pass "validador ejecutable" || fail "validador no ejecutable"
grep -q '^#!/usr/bin/env bash$' "$VALIDATOR" && pass "validador declara intérprete Bash" || fail "validador sin shebang Bash"
jq empty "$CONTRACT_DIR/published-artifact.schema.json" >/dev/null 2>&1 && pass "schema JSON válido" || fail "schema JSON inválido"
bash -n "$VALIDATOR" >/dev/null 2>&1 && pass "sintaxis Bash válida" || fail "sintaxis Bash inválida"

echo "[valid] fixtures válidos"
for f in "$CONTRACT_DIR"/fixtures/valid/*.md; do out=$(bash "$VALIDATOR" "$f" 2>&1); rc=$?; [ "$rc" -eq 0 ] && pass "$(basename "$f")" || fail "$(basename "$f"): $out"; done

echo "[invalid] fixtures inválidos"
check_invalid() {
    local name="$1" expected="$2" out rc
    out=$(bash "$VALIDATOR" "$CONTRACT_DIR/fixtures/invalid/$name" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then fail "$name fue aceptado"
    elif printf '%s' "$out" | grep -qF -- "$expected"; then pass "$name: $expected"
    else fail "$name fue rechazado por otro motivo: $out"
    fi
}
check_invalid "frontmatter-not-json.md" "frontmatter: no es JSON valido"
check_invalid "missing-description.md" "description: campo requerido ausente"
check_invalid "extra-property.md" "foo: propiedad adicional no permitida"
check_invalid "invalid-kind.md" "kind: valor"
check_invalid "invalid-profile.md" "profile: valor"
check_invalid "invalid-mode.md" "mode: valor"
check_invalid "missing-mode.md" "mode: campo requerido ausente"
check_invalid "invalid-capability.md" "capabilities.0: valor"
check_invalid "mismatched-id.md" "id: 'other-id' distinto"
check_invalid "mefisto-prefixed-id.md" "id: 'mefisto-prefixed-id' no coincide"
check_invalid "id-with-colon.md" "id: 'mefisto:id-with-colon' no coincide"
check_invalid "model-field.md" "model: propiedad adicional"
check_invalid "tools-field.md" "tools: propiedad adicional"
check_invalid "allowed-tools-field.md" "allowed-tools: propiedad adicional"
check_invalid "permission-field.md" "permission: propiedad adicional"
check_invalid "mode-on-command.md" "mode: propiedad adicional"
check_invalid "command-fields-on-agent.md" "agent: propiedad adicional"
check_invalid "body-runtime-reference.md" "body: linea 5 referencia un runtime"
check_invalid "missing-guard.md" "body: falta {{mefisto:assert-consumer-repo}}"
check_invalid "unknown-directive.md" "directiva mefisto desconocida"
check_invalid "malformed-directive.md" "directiva mefisto mal formada"
check_invalid "malformed-mcp.md" "mcp.0"
check_invalid "unknown-mcp.md" "mcp.0: valor"
check_invalid "runtime-variable.md" 'placeholder no permitido: $CLAUDE_PLUGIN_ROOT'
check_invalid "guard-outside-body.md" "body: falta {{mefisto:assert-consumer-repo}}"
check_invalid "partially-malformed-directive.md" "directiva mefisto mal formada"

echo "[no-args] fuentes publicadas"
out=$(bash "$VALIDATOR" 2>&1); rc=$?; [ "$rc" -eq 0 ] && pass "sin fuentes aún" || fail "sin argumentos: $out"
echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]

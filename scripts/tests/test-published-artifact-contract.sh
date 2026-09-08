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
grep -q '^#!/usr/bin/env bash$' "$VALIDATOR" && pass "validador declara intérprete Bash" || fail "validador sin shebang Bash"
jq empty "$CONTRACT_DIR/published-artifact.schema.json" >/dev/null 2>&1 && pass "schema JSON válido" || fail "schema JSON inválido"
bash -n "$VALIDATOR" >/dev/null 2>&1 && pass "sintaxis Bash válida" || fail "sintaxis Bash inválida"

echo "[valid] fixtures válidos"
for f in "$CONTRACT_DIR"/fixtures/valid/*.md; do out=$(bash "$VALIDATOR" "$f" 2>&1); rc=$?; [ "$rc" -eq 0 ] && pass "$(basename "$f")" || fail "$(basename "$f"): $out"; done

echo "[invalid] fixtures inválidos"
for f in "$CONTRACT_DIR"/fixtures/invalid/*.md; do out=$(bash "$VALIDATOR" "$f" 2>&1); rc=$?; [ "$rc" -ne 0 ] && pass "$(basename "$f")" || fail "$(basename "$f") fue aceptado"; done

echo "[no-args] fuentes publicadas"
out=$(bash "$VALIDATOR" 2>&1); rc=$?; [ "$rc" -eq 0 ] && pass "sin fuentes aún" || fail "sin argumentos: $out"
echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]

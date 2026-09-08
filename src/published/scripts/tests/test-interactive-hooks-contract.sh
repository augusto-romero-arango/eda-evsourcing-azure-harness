#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
HOOKS="$REPO_ROOT/src/published/hooks"
VALIDATOR="$REPO_ROOT/src/published/scripts/validate-interactive-hooks.sh"
FIXTURES="$HOOKS/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "[pre] contrato y schema"
for file in "$HOOKS/interactive-hooks.json" "$HOOKS/interactive-hooks.schema.json" "$VALIDATOR"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT"/}" || fail "falta ${file#"$REPO_ROOT"/}"; done
jq empty "$HOOKS/interactive-hooks.schema.json" >/dev/null 2>&1 && pass "schema JSON valido" || fail "schema JSON invalido"
bash -n "$VALIDATOR" && pass "validador Bash valido" || fail "validador Bash invalido"

echo "[valid] descriptor y fixture"
out=$(bash "$VALIDATOR" "$HOOKS/interactive-hooks.json" 2>&1); [ $? -eq 0 ] && pass "descriptor vigente" || fail "descriptor vigente: $out"
out=$(bash "$VALIDATOR" "$FIXTURES/valid/interactive-hooks.json" 2>&1); [ $? -eq 0 ] && pass "fixture valido" || fail "fixture valido: $out"

for fixture in "$FIXTURES"/invalid/*.jq; do
    candidate="$WORK/$(basename "$fixture" .jq).json"
    jq -f "$fixture" "$FIXTURES/valid/interactive-hooks.json" > "$candidate"
    out=$(bash "$VALIDATOR" "$candidate" 2>&1)
    [ $? -ne 0 ] && pass "$(basename "$fixture")" || fail "$(basename "$fixture") fue aceptado: $out"
done

echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]

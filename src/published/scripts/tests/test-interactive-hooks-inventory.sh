#!/usr/bin/env bash
# Demuestra la trazabilidad uno-a-uno desde los seis comandos legacy.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
LEGACY="$REPO_ROOT/hooks/hooks.json"
CONTRACT="$REPO_ROOT/src/published/hooks/interactive-hooks.json"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq no instalado"; exit 0; }

echo "[pre] inventario legacy y contrato"
if jq empty "$LEGACY" && jq empty "$CONTRACT"; then pass "ambos documentos son JSON validos"; else fail "algún documento no es JSON valido"; fi
legacy_count=$(jq '[.hooks[][].hooks[]?.command] | length' "$LEGACY")
contract_count=$(jq '.bindings | length' "$CONTRACT")
[ "$legacy_count" = "6" ] && [ "$contract_count" = "6" ] && pass "ambos inventarios contienen exactamente seis comportamientos" || fail "conteos legacy=$legacy_count contrato=$contract_count"

trace() {
    local id="$1" filter="$2"
    legacy=$(jq -r "$filter" "$LEGACY")
    neutral=$(jq -r --arg id "$id" '[.bindings[] | select(.id == $id)] | length' "$CONTRACT")
    if [ "$legacy" = "1" ] && [ "$neutral" = "1" ]; then pass "$id traza un handler legacy"; else fail "$id: legacy=$legacy neutral=$neutral"; fi
}

trace record-active-release '[.hooks.SessionStart[].hooks[].command | select(contains(".plugin-root"))] | length'
trace append-session '[.hooks.SessionStart[].hooks[].command | select(contains("sessions.jsonl"))] | length'
trace remind-field-notes '[.hooks.PostToolUse[] | select(.matcher == "ExitPlanMode") | .hooks[].command] | length'
trace append-file-change '[.hooks.PostToolUse[] | select(.matcher == "Write|Edit") | .hooks[].command] | length'
trace append-dotnet-test-result '[.hooks.PostToolUse[] | select(.matcher == "Bash") | .hooks[].command | select(contains("dotnet test"))] | length'
trace append-terraform-result '[.hooks.PostToolUse[] | select(.matcher == "Bash") | .hooks[].command | select(contains("terraform (plan|apply|init|validate)"))] | length'

ids=$(jq -r '[.bindings[].id] | sort | join(" ")' "$CONTRACT")
expected='append-dotnet-test-result append-file-change append-session append-terraform-result record-active-release remind-field-notes'
[ "$ids" = "$expected" ] && pass "no hay bindings huerfanos" || fail "bindings inesperados: $ids"
echo "RESULTADO: $PASS pasaron, $FAIL fallaron"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)"
MATRIX="$ROOT/src/published/contract/source-verification.json"
REGISTRY="$ROOT/src/published/contract/mcp-servers.json"
FILTER="$ROOT/src/published/scripts/lib/source-verification.jq"
REPORT="$ROOT/src/published/scripts/validate-source-verification.sh"
PASS=0 FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { "$@" >/dev/null 2>&1 && pass "$1" || fail "$1"; }

check jq empty "$MATRIX"
check bash -n "$REPORT"
if jq -e '.schemaVersion == 1 and (.roles | length) == 22 and ([.roles[].id] | length == (unique | length))' "$MATRIX" >/dev/null; then pass 'matriz clasifica exactamente los 22 roles sin duplicados'; else fail 'matriz no clasifica exactamente los 22 roles'; fi
out="$(bash "$REPORT" --require planner/non-microsoft-official --require domain-scaffolder/nuget-api --require infra-writer/provider-pin 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && jq -e '([.cases[] | select(.id == "planner" and .caseId == "microsoft-platform" and .status == "declared")]|length)==1 and ([.cases[] | select(.id == "planner" and .caseId == "non-microsoft-official" and .status == "capability-missing")]|length)==1 and ([.cases[] | select(.id == "domain-scaffolder" and .caseId == "nuget-api" and .status == "capability-missing")]|length)==1 and ([.cases[] | select(.id == "infra-writer" and .caseId == "provider-pin" and .status == "external-unobserved")]|length)==1 and ([.cases[] | select(.status == "not-required")]|length)>0' <<< "$out" >/dev/null; then pass 'informe actual distingue MCP bundleado, gaps web, externo y condicional'; else fail "informe actual: $out"; fi

envelope="$(jq -cn --slurpfile matrix "$MATRIX" --slurpfile registry "$REGISTRY" '{matrix:$matrix[0],registry:$registry[0],roles:[$matrix[0].roles[] | {id,capabilities:["read","shell"],mcp:[]}],requiredCases:["infra-writer/provider-pin","workos-identity-scaffolder/package-signatures"]}')"
fallback="$(jq -c '(.roles[] | select(.id == "infra-writer")) |= (.capabilities += ["web"])' <<< "$envelope")"
out="$(printf '%s' "$fallback" | jq -f "$FILTER" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && jq -e '([.cases[] | select(.id == "infra-writer" and .caseId == "provider-pin" and .status == "declared")]|length)==1 and ([.cases[] | select(.id == "workos-identity-scaffolder" and .caseId == "package-signatures" and .status == "declared")]|length)==1' <<< "$out" >/dev/null; then pass 'fallback web y compilacion local son alternativas declaradas'; else fail "fallback: $out"; fi

broken="$(jq -c 'del(.matrix.roles[0])' <<< "$envelope")"
if printf '%s' "$broken" | jq -f "$FILTER" >/dev/null 2>&1; then fail 'rechaza rol faltante'; else pass 'rechaza rol faltante'; fi
if printf '%s' "$envelope" | jq '.requiredCases += ["planner/caso-ausente"]' | jq -f "$FILTER" >/dev/null 2>&1; then fail 'rechaza caso requerido inexistente'; else pass 'rechaza caso requerido inexistente'; fi
printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

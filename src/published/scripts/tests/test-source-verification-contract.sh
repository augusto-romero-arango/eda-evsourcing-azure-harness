#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)"
MATRIX="$ROOT/src/published/contract/source-verification.json"
REGISTRY="$ROOT/src/published/contract/mcp-servers.json"
FILTER="$ROOT/src/published/scripts/lib/source-verification.jq"
REPORT="$ROOT/src/published/scripts/validate-source-verification.sh"
FIXTURE="$ROOT/src/published/scripts/tests/fixtures/source-verification/role-metadata.json"
PINS_FIXTURE="$ROOT/src/published/scripts/tests/fixtures/source-verification/domain-scaffolder-pins.json"
PASS=0 FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

printf '[contrato y metadata]\n'
jq empty "$MATRIX" "$FIXTURE" "$PINS_FIXTURE" >/dev/null 2>&1 && pass 'JSON valido' || fail 'JSON invalido'
bash -n "$REPORT" && pass 'entrypoint tiene sintaxis valida' || fail 'entrypoint invalido'
if jq -e '.schemaVersion == 1 and (.roles | length) == 22 and ([.roles[].id] | length == (unique | length)) and all(.roles[]; (.evidence | length) > 0)' "$MATRIX" >/dev/null; then
    pass 'matriz clasifica exactamente los 22 roles con evidencia'
else
    fail 'matriz incompleta, duplicada o sin evidencia'
fi

if jq -e '
    (.pins | length) == 3 and
    any(.pins[]; .id == "Microsoft.Azure.Functions.Worker.OpenTelemetry" and .version == "1.2.0" and .effectiveDependencies == ["Microsoft.Azure.Functions.Worker.Core >= 2.52.0"]) and
    any(.pins[]; .id == "OpenTelemetry.Extensions.Hosting" and .version == "1.15.3") and
    any(.pins[]; .id == "FluentValidation.DependencyInjectionExtensions" and .version == "11.12.0" and .latestPublished == "12.0.0" and .requiredMajor == 11)
' "$PINS_FIXTURE" >/dev/null; then
    pass 'fixture fija Worker/OTel, dependencia de nuspec y limite major de FluentValidation'
else
    fail 'fixture de pines no distingue existencia, latest y dependencia efectiva'
fi

actual='[]'
for file in "$ROOT"/src/published/agents/*.md; do
    frontmatter="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$file")"
    role="$(printf '%s\n' "$frontmatter" | jq -c '{id,capabilities:(.capabilities // []),skills:(.skills // []),mcp:(.mcp // [])}')" || { fail "frontmatter invalido: $file"; continue; }
    actual="$(jq -cn --argjson prior "$actual" --argjson role "$role" '$prior + [$role]')" || exit 1
done
if jq -e --argjson actual "$actual" '(.roles | sort_by(.id)) == ($actual | sort_by(.id))' "$FIXTURE" >/dev/null; then
    pass 'fixture fija MCP, web, Task y Skills previos sin grants causados por la matriz'
else
    fail 'metadata de roles cambio sin actualizar el contrato explicito'
fi

printf '[informe actual]\n'
out="$(bash "$REPORT" \
    --require planner/non-microsoft-official \
    --require domain-scaffolder/nuget-version \
    --require domain-scaffolder/nuget-api \
    --require infra-writer/provider-pin \
    --require infra-reviewer/provider-argument \
    --require apim-gateway-scaffolder/workos-discovery \
    --require bug-investigator/external-diagnosis 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && jq -e '
    all(.cases[]; has("subject") and (.status as $status | ["declared","capability-missing","external-unobserved","not-required"] | index($status))) and
    any(.cases[]; .id == "planner" and .caseId == "microsoft-platform" and .status == "declared") and
    any(.cases[]; .id == "planner" and .caseId == "non-microsoft-official" and .status == "declared") and
    any(.cases[]; .id == "domain-scaffolder" and .caseId == "nuget-version" and .status == "declared") and
    any(.cases[]; .id == "domain-scaffolder" and .caseId == "nuget-api" and .status == "capability-missing") and
    any(.cases[]; .id == "infra-writer" and .caseId == "provider-pin" and .status == "external-unobserved") and
    any(.cases[]; .id == "infra-reviewer" and .caseId == "provider-argument" and .status == "capability-missing") and
    any(.cases[]; .id == "apim-gateway-scaffolder" and .caseId == "workos-discovery" and .status == "declared") and
    any(.cases[]; .id == "bug-investigator" and .caseId == "external-diagnosis" and .status == "declared") and
    any(.cases[]; .status == "not-required")' <<< "$out" >/dev/null; then
    pass 'informe distingue bundle, web, CLI, externo y casos no requeridos'
else
    fail "informe actual: $out"
fi

roles="$(jq -c '[.roles[] | {id,capabilities,mcp}]' "$FIXTURE")"
envelope="$(jq -cn --slurpfile matrix "$MATRIX" --slurpfile registry "$REGISTRY" --argjson roles "$roles" '{matrix:$matrix[0],registry:$registry[0],roles:$roles,requiredCases:["infra-writer/provider-pin"]}')"
without_external="$(jq -c '(.roles[] | select(.id == "infra-writer")).mcp=[]' <<< "$envelope")"
with_web="$(jq -c '(.roles[] | select(.id == "infra-writer")).capabilities += ["web"]' <<< "$without_external")"
status_without="$(printf '%s' "$without_external" | jq -r -f "$FILTER" | jq -r '.cases[] | select(.id == "infra-writer" and .caseId == "provider-pin") | .status')"
status_web="$(printf '%s' "$with_web" | jq -r -f "$FILTER" | jq -r '.cases[] | select(.id == "infra-writer" and .caseId == "provider-pin") | .status')"
if [ "$status_without" = capability-missing ] && [ "$status_web" = declared ]; then
    pass 'Terraform ausente bloquea y web declarado actua como fallback alternativo'
else
    fail "fallback Terraform inesperado: sin MCP=$status_without, con web=$status_web"
fi

planner_without_mcp="$(jq -c '(.roles[] | select(.id == "planner")).mcp=[]' <<< "$envelope")"
planner_without_sources="$(jq -c '(.roles[] | select(.id == "planner")).mcp=[] | (.roles[] | select(.id == "planner")).capabilities -= ["web"]' <<< "$envelope")"
planner_mcp_absent_status="$(printf '%s' "$planner_without_mcp" | jq -r -f "$FILTER" | jq -r '.cases[] | select(.id == "planner" and .caseId == "microsoft-platform") | .status')"
planner_without_sources_status="$(printf '%s' "$planner_without_sources" | jq -r -f "$FILTER" | jq -r '.cases[] | select(.id == "planner" and .caseId == "microsoft-platform") | .status')"
if [ "$planner_mcp_absent_status" = declared ] && [ "$planner_without_sources_status" = capability-missing ]; then
    pass 'Microsoft usa web como fallback del MCP ausente y la ausencia total no se certifica'
else
    fail "fallback Microsoft inesperado: MCP ausente=$planner_mcp_absent_status, sin fuentes=$planner_without_sources_status"
fi
if jq -e '
    .roles[] | select(.id == "planner") |
    all(.cases[] | select(.caseId == "microsoft-platform" or .caseId == "non-microsoft-official"); .onMissing == "not-verified")
' "$MATRIX" >/dev/null; then
    pass 'planner marca NO VERIFICADO cuando falta la fuente externa requerida'
else
    fail 'planner bloquea o certifica un claim sin fuente externa'
fi

if jq -e '
    [.roles[] | select(.id == "domain-scaffolder" or .id == "mcp-scaffolder" or .id == "projections-scaffolder") | .cases[] | select(.caseId == "nuget-version")] as $pins |
    ($pins | length) == 3 and all($pins[]; (.subject | contains("pin") and contains("no la ultima absoluta")) and (.options == [{"kind":"package-cli","reference":"dotnet package search --exact-match para el id y el pin requeridos"}]))' "$MATRIX" >/dev/null; then
    pass 'NuGet consulta id y pin exactos sin convertir latest absoluto en criterio'
else
    fail 'casos NuGet no conservan pin exacto frente a latest absoluto'
fi

if jq -e '
    .roles[] | select(.id == "workos-identity-scaffolder") |
    (.cases | length) == 2 and
    any(.cases[]; .caseId == "package-signatures" and .options == [{"kind":"local-artifact","reference":"paquete restaurado y compilacion"}]) and
    any(.cases[]; .caseId == "package-version" and .options == [{"kind":"package-cli","reference":"dotnet package search WorkOS.net --exact-match"}] and .onMissing == "not-verified")' "$MATRIX" >/dev/null; then
    pass 'WorkOS separa compilacion de firmas y consulta CLI best-effort'
else
    fail 'WorkOS trata indebidamente CLI y compilacion como alternativas'
fi

local_ids='["historiador","implementer","infra-base-scaffolder","infra-bootstrap","pr-sync","projection-implementer","projection-test-writer","reviewer","smoke-test-writer","test-writer","tooling-investigator","tooling-reviewer","tooling-writer"]'
if jq -e --argjson ids "$local_ids" 'all(.roles[] | select(.id as $id | $ids | index($id)); all(.cases[].options[]; .kind != "web" and .kind != "bundled-mcp" and .kind != "external-mcp"))' "$MATRIX" >/dev/null; then
    pass 'roles locales no reciben web ni MCP por uniformidad'
else
    fail 'un rol local recibio una via externa no pedida'
fi

printf '[rechazos]\n'
assert_rejected() {
    local label="$1" candidate="$2"
    if printf '%s' "$candidate" | jq -f "$FILTER" >/dev/null 2>&1; then fail "$label"; else pass "$label"; fi
}
assert_rejected 'rechaza rol faltante' "$(jq -c 'del(.matrix.roles[0])' <<< "$envelope")"
assert_rejected 'rechaza rol nuevo sin clasificar' "$(jq -c '.roles += [{id:"rol-nuevo",capabilities:["read"],mcp:[]}]' <<< "$envelope")"
assert_rejected 'rechaza evidencia vacia' "$(jq -c '.matrix.roles[0].evidence=[]' <<< "$envelope")"
assert_rejected 'rechaza requiredCases duplicados' "$(jq -c '.requiredCases += [.requiredCases[0]]' <<< "$envelope")"
assert_rejected 'rechaza servidor MCP malformado' "$(jq -c '.registry.servers[0].authentication="token"' <<< "$envelope")"
assert_rejected 'rechaza caso requerido inexistente' "$(jq -c '.requiredCases=["planner/caso-ausente"]' <<< "$envelope")"

printf '[empaquetado]\n'
packaged=1
for runtime in claude opencode; do
    for asset in src/published/contract/source-verification.json src/published/contract/mcp-servers.json src/published/scripts/lib/source-verification.jq; do
        cmp -s "$ROOT/$asset" "$ROOT/dist/$runtime/$asset" || packaged=0
        jq -e --arg asset "$asset" 'any(.assets[]; .adapter == "tooling-closure" and .source == $asset and .destination == $asset)' "$ROOT/dist/$runtime/.mefisto-generated-assets.json" >/dev/null || packaged=0
    done
done
[ "$packaged" -eq 1 ] && pass 'matriz, helper y registro neutral coinciden en ambas distribuciones e inventarios' || fail 'empaquetado distribuido incompleto o divergente'

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

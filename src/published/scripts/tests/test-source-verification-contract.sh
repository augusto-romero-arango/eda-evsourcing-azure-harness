#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)"
MATRIX="$ROOT/src/published/contract/source-verification.json"
REGISTRY="$ROOT/src/published/contract/mcp-servers.json"
FILTER="$ROOT/src/published/scripts/lib/source-verification.jq"
REPORT="$ROOT/src/published/scripts/validate-source-verification.sh"
FIXTURE="$ROOT/src/published/scripts/tests/fixtures/source-verification/role-metadata.json"
PINS_FIXTURE="$ROOT/src/published/scripts/tests/fixtures/source-verification/domain-scaffolder-pins.json"
DOMAIN_AGENT="$ROOT/src/published/agents/domain-scaffolder.md"
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
    def package($id): .packages[] | select(.id == $id);
    (.schemaVersion == 1 and (.packages | length) == 3) and
    (package("Microsoft.Azure.Functions.Worker.OpenTelemetry") as $worker |
        ($worker.index.versions | index($worker.requiredVersion)) != null and
        $worker.index.versions[-1] == $worker.requiredVersion and
        any($worker.nuspec.dependencies[];
            .id == "Microsoft.Azure.Functions.Worker.Core" and .version == "[2.52.0, )")) and
    (package("OpenTelemetry.Extensions.Hosting") as $otel |
        ($otel.index.versions | index($otel.requiredVersion)) != null and
        $otel.index.versions[-1] == $otel.requiredVersion) and
    (package("FluentValidation.DependencyInjectionExtensions") as $fluent |
        ($fluent.index.versions | index($fluent.requiredVersion)) != null and
        $fluent.index.versions[-1] == "12.0.0" and
        [$fluent.index.versions[] | select((split(".")[0] | tonumber) == $fluent.requiredMajor)][-1] == $fluent.requiredVersion)
' "$PINS_FIXTURE" >/dev/null; then
    pass 'fixture deriva existencia, latest, dependencia de nuspec y limite major de FluentValidation'
else
    fail 'fixture de pines no distingue existencia, latest y dependencia efectiva'
fi

domain_policy_ok=1
for statement in \
    'No consultes red automaticamente ni sustituyas un pin por `latest`.' \
    'fuente oficial publica de **la version y linea requeridas** con WebFetch/WebSearch' \
    'pero no demuestra el grafo del `.nuspec`.' \
    'informa **NO VERIFICADO**' \
    'no uses `curl` como sustituto' \
    'nunca configuracion del consumidor, secretos ni payloads.'; do
    grep -Fq "$statement" "$DOMAIN_AGENT" || domain_policy_ok=0
done
if [ "$domain_policy_ok" -eq 1 ]; then
    pass 'domain-scaffolder conserva fallback local, fuente oficial, degradacion y consultas sanitizadas'
else
    fail 'domain-scaffolder perdio una regla de reverificacion externa'
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
    --require mcp-scaffolder/nuget-version \
    --require mcp-scaffolder/nuget-api \
    --require infra-writer/provider-pin \
    --require infra-reviewer/provider-argument \
    --require apim-gateway-scaffolder/workos-discovery \
    --require bug-investigator/external-diagnosis 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && jq -e '
    all(.cases[]; has("subject") and (.status as $status | ["declared","capability-missing","external-unobserved","not-required"] | index($status))) and
    any(.cases[]; .id == "planner" and .caseId == "microsoft-platform" and .status == "declared") and
    any(.cases[]; .id == "planner" and .caseId == "non-microsoft-official" and .status == "declared") and
    any(.cases[]; .id == "domain-scaffolder" and .caseId == "nuget-version" and .status == "declared") and
    any(.cases[]; .id == "domain-scaffolder" and .caseId == "nuget-api" and .status == "declared") and
    any(.cases[]; .id == "mcp-scaffolder" and .caseId == "nuget-version" and .status == "declared") and
    any(.cases[]; .id == "mcp-scaffolder" and .caseId == "nuget-api" and .status == "declared") and
    any(.cases[]; .id == "infra-writer" and .caseId == "provider-pin" and .status == "external-unobserved") and
    any(.cases[]; .id == "infra-reviewer" and .caseId == "provider-argument" and .status == "declared") and
    any(.cases[]; .id == "apim-gateway-scaffolder" and .caseId == "workos-discovery" and .status == "declared") and
    any(.cases[]; .id == "bug-investigator" and .caseId == "external-diagnosis" and .status == "declared") and
    any(.cases[]; .status == "not-required")' <<< "$out" >/dev/null; then
    pass 'informe distingue bundle, web, CLI, externo y casos no requeridos'
else
    fail "informe actual: $out"
fi

roles="$(jq -c '[.roles[] | {id,capabilities,mcp}]' "$FIXTURE")"
envelope="$(jq -cn --slurpfile matrix "$MATRIX" --slurpfile registry "$REGISTRY" --argjson roles "$roles" '{matrix:$matrix[0],registry:$registry[0],roles:$roles,requiredCases:["infra-writer/provider-pin"]}')"
reviewer_without_web="$(jq -c '(.roles[] | select(.id == "infra-reviewer")).capabilities -= ["web"] | .requiredCases += ["infra-reviewer/provider-argument"]' <<< "$envelope")"
reviewer_external_status="$(printf '%s' "$reviewer_without_web" | jq -r -f "$FILTER" | jq -r '.cases[] | select(.id == "infra-reviewer" and .caseId == "provider-argument") | .status')"
reviewer_local_status="$(printf '%s' "$reviewer_without_web" | jq -r -f "$FILTER" | jq -r '.cases[] | select(.id == "infra-reviewer" and .caseId == "local-hcl") | .status')"
if [ "$reviewer_external_status" = capability-missing ] && [ "$reviewer_local_status" = declared ]; then
    pass 'reviewer conserva revision local y no certifica argumento externo sin fuente'
else
    fail "fallback reviewer inesperado: local=$reviewer_local_status, externo=$reviewer_external_status"
fi

if jq -e '
    .roles[] | select(.id == "infra-reviewer") |
    any(.cases[]; .caseId == "provider-argument" and .when == "conditional" and .onMissing == "not-verified" and .options == [{"kind":"web","reference":"documentacion oficial del provider"}])
' "$MATRIX" >/dev/null; then
    pass 'reviewer declara documentacion oficial condicional y resultado NO VERIFICADO'
else
    fail 'reviewer no conserva la degradacion de fuente oficial'
fi

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
    .roles[] | select(.id == "domain-scaffolder") |
    any(.cases[]; .caseId == "nuget-version" and (.subject | contains("exacta") and contains("no la ultima absoluta")) and .onMissing == "not-verified" and (.options | map(.kind) | sort) == ["package-cli","web"]) and
    any(.cases[]; .caseId == "nuget-api" and (.subject | contains("dependencia efectiva")) and .onMissing == "not-verified" and .options == [{"kind":"web","reference":".nuspec versionado de NuGet o documentacion/codigo oficial del SDK"}])
' "$MATRIX" >/dev/null; then
    pass 'domain-scaffolder distingue existencia, latest y dependencia efectiva del pin exacto'
else
    fail 'casos NuGet de domain-scaffolder no conservan la politica de reverificacion'
fi

domain_without_web="$(jq -c '(.roles[] | select(.id == "domain-scaffolder")).capabilities -= ["web"] | .requiredCases += ["domain-scaffolder/nuget-api"]' <<< "$envelope")"
domain_local_status="$(printf '%s' "$domain_without_web" | jq -r -f "$FILTER" | jq -r '.cases[] | select(.id == "domain-scaffolder" and .caseId == "local-scaffold") | .status')"
domain_nuspec_status="$(printf '%s' "$domain_without_web" | jq -r -f "$FILTER" | jq -r '.cases[] | select(.id == "domain-scaffolder" and .caseId == "nuget-api") | .status')"
if [ "$domain_local_status" = declared ] && [ "$domain_nuspec_status" = capability-missing ]; then
    pass 'fixture offline conserva el scaffold local y marca la reverificacion externa como no disponible'
else
    fail "fixture offline inesperado: local=$domain_local_status, nuspec=$domain_nuspec_status"
fi

if jq -e '
    .roles[] | select(.id == "mcp-scaffolder") |
    any(.cases[]; .caseId == "nuget-version" and (.subject | contains("exacta") and contains("no la ultima absoluta")) and .onMissing == "not-verified" and (.options | map(.kind) | sort) == ["package-cli","web"]) and
    any(.cases[]; .caseId == "nuget-api" and (.subject | contains(".nuspec") and contains("ModelContextProtocol") and contains("WorkOS") and contains("OAuth")) and .onMissing == "not-verified" and .options == [{"kind":"web","reference":".nuspec versionado de NuGet o documentacion/codigo oficial versionado del SDK"}])
' "$MATRIX" >/dev/null; then
    pass 'mcp-scaffolder distingue pin exacto, nuspec y SDKs versionados sin adoptar latest'
else
    fail 'casos NuGet y SDK de mcp-scaffolder no conservan la politica de reverificacion'
fi

mcp_without_web="$(jq -c '(.roles[] | select(.id == "mcp-scaffolder")).capabilities -= ["web"] | .requiredCases += ["mcp-scaffolder/nuget-api"]' <<< "$envelope")"
mcp_local_status="$(printf '%s' "$mcp_without_web" | jq -r -f "$FILTER" | jq -r '.cases[] | select(.id == "mcp-scaffolder" and .caseId == "local-scaffold") | .status')"
mcp_nuspec_status="$(printf '%s' "$mcp_without_web" | jq -r -f "$FILTER" | jq -r '.cases[] | select(.id == "mcp-scaffolder" and .caseId == "nuget-api") | .status')"
if [ "$mcp_local_status" = declared ] && [ "$mcp_nuspec_status" = capability-missing ]; then
    pass 'mcp-scaffolder conserva el scaffold local y marca NO VERIFICADO sin fuente web'
else
    fail "fallback mcp-scaffolder inesperado: local=$mcp_local_status, nuspec=$mcp_nuspec_status"
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

#!/usr/bin/env bash
# Verifica el corte vertical neutral de infra-writer/infra-reviewer (issue #1625):
# metadata/perfiles, fuente oficial condicional del reviewer, allowlist MCP por
# runtime, denegacion de terraform plan/apply y az en OpenCode, ausencia de
# tokens de runtime en la fuente y paridad byte a byte de los mirrors raiz Claude.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
SOURCE_FIXTURES="$HERE/fixtures/infra-reviewer-sources/cases.json"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }
frontmatter() { awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$1"; }
body() { awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$1"; }

echo '[a] metadata y perfiles de la fuente neutral'
for spec in 'infra-writer|balanced|["read","edit","shell"]' 'infra-reviewer|deep|["read","edit","shell","web"]'; do
    agent="${spec%%|*}"; rest="${spec#*|}"; expected_profile="${rest%%|*}"; expected_capabilities="${rest#*|}"
    source="$REPO_ROOT/src/published/agents/$agent.md"
    if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$source" >/dev/null; then pass "$agent valida contra el contrato"; else fail "$agent no valida contra el contrato"; fi
    metadata="$(frontmatter "$source")"
    if printf '%s' "$metadata" | jq -e --arg id "$agent" --arg profile "$expected_profile" \
        --argjson capabilities "$expected_capabilities" \
        '.kind == "agent" and .id == $id and .mode == "all" and .profile == $profile and .capabilities == $capabilities' >/dev/null; then
        pass "$agent declara kind/id/mode/profile/capabilities esperados"
    else
        fail "$agent no declara kind/id/mode/profile/capabilities esperados"
    fi
done
writer_mcp="$(frontmatter "$REPO_ROOT/src/published/agents/infra-writer.md" | jq -c '.mcp // []')"
reviewer_mcp="$(frontmatter "$REPO_ROOT/src/published/agents/infra-reviewer.md" | jq -c '.mcp // []')"
[ "$writer_mcp" = '["terraform"]' ] && pass 'infra-writer declara mcp: ["terraform"]' || fail "infra-writer declaro mcp inesperado: $writer_mcp"
[ "$reviewer_mcp" = '[]' ] && pass 'infra-reviewer no declara mcp' || fail "infra-reviewer declaro mcp inesperado: $reviewer_mcp"

echo '[fuentes] fallback condicional y degradacion verificable'
if jq -e '
    .schemaVersion == 1 and (.cases | length) == 4 and
    any(.cases[]; .id == "adr-schema-local" and .expected == "local-artifact") and
    any(.cases[]; .id == "provider-v4-versus-latest-v5" and .lockVersion == "4.81.0" and .constraint == "~> 4.0" and .latestVersion == "5.0.1" and (.queryTerms | index("4.81.0")) != null and (.queryTerms | index("5.0.1")) == null and .expected == "version-locked-official-docs") and
    any(.cases[]; .id == "external-source-absent" and (.queryTerms | length) > 0 and .expected == "NO VERIFICADO") and
    any(.cases[]; .id == "official-docs-available" and (.source | startswith("https://registry.terraform.io/providers/hashicorp/azurerm/4.81.0/")) and .expected == "semantic-review") and
    all(.cases[].queryTerms[]; IN("hashicorp azurerm", "4.81.0", "linux_function_app application_stack"))
' "$SOURCE_FIXTURES" >/dev/null 2>&1; then
    pass 'fixture cubre ADR/schema local, version v4 frente a latest v5, ausencia y fuente oficial'
else
    fail 'fixture de fuentes del infra-reviewer incompleta'
fi
reviewer_body="$(body "$REPO_ROOT/src/published/agents/infra-reviewer.md")"
for statement in \
    'ADRs del proyecto, el HCL y el schema/provider local son las primeras fuentes' \
    'version fijada en `.terraform.lock.hcl`; solo si el lock no existe, usa la linea permitida por el constraint del proyecto' \
    'documentacion `latest` de otra major' \
    'Nunca envies HCL completo, configuracion ni identificadores del consumidor, tokens, secretos o payloads' \
    'no demuestra conectividad ni que exista una fuente para la version requerida' \
    'marca ese argumento como **NO VERIFICADO** en el resumen y no apruebes su semantica' \
    'no convierte la revision local en una consulta de red obligatoria' \
    'MCP de Terraform al reviewer' \
    'contrato de fuentes de #1822 y MEF-ADR-0055'; do
    contains "$reviewer_body" "$statement" "reviewer conserva la regla de fuente: $statement"
done

echo '[d] ausencia de tokens de runtime en la fuente neutral'
for agent in infra-writer infra-reviewer; do
    agent_body="$(body "$REPO_ROOT/src/published/agents/$agent.md")"
    contains "$agent_body" '{{mefisto:assert-consumer-repo}}' "$agent conserva el guard"
    for token in '.claude' '.opencode' 'claude' 'opencode' 'marketplace' 'cache' 'model:' 'tools:' 'permission:' 'allowed-tools:'; do
        absent "$(printf '%s' "$agent_body" | tr '[:upper:]' '[:lower:]')" "$token" "$agent no menciona token de runtime: $token"
    done
done

echo '[integracion] generacion de las cuatro salidas y check limpio'
if "$GENERATOR" --out "$WORK" \
    "$REPO_ROOT/src/published/agents/infra-writer.md" \
    "$REPO_ROOT/src/published/agents/infra-reviewer.md" >/dev/null; then
    pass 'el generador procesa ambos agentes en conjunto'
else
    fail 'el generador no proceso ambos agentes en conjunto'
fi

echo '[b] allowlist MCP por runtime'
claude_writer="$(< "$WORK/dist/claude/agents/infra-writer.md")"
claude_reviewer="$(< "$WORK/dist/claude/agents/infra-reviewer.md")"
contains "$claude_writer" 'mcp__terraform__*' 'Claude writer expone el matcher corto de terraform'
contains "$claude_writer" 'mcp__plugin_terraform_terraform__*' 'Claude writer expone el matcher scoped del plugin terraform'
contains "$claude_writer" 'model: "sonnet"' 'Claude writer materializa perfil balanced'
contains "$claude_reviewer" 'model: "opus"' 'Claude reviewer materializa perfil deep'
contains "$claude_reviewer" 'tools: "Read, Glob, Grep, Edit, Write, Bash, WebFetch, WebSearch"' 'Claude reviewer conserva Read/Edit/Bash y suma solo el par web'
absent "$claude_reviewer" 'Skill' 'Claude reviewer conserva la ausencia previa de Skills'
absent "$claude_reviewer" 'mcp__' 'Claude reviewer no expone ningun matcher MCP'
opencode_writer="$(< "$WORK/dist/opencode/agents/infra-writer.md")"
opencode_reviewer="$(< "$WORK/dist/opencode/agents/infra-reviewer.md")"
contains "$opencode_writer" '"terraform_*":true' 'OpenCode writer habilita terraform_*'
contains "$opencode_reviewer" '"terraform_*":false' 'OpenCode reviewer deniega terraform_*'
contains "$opencode_reviewer" '"webfetch":"allow"' 'OpenCode reviewer permite WebFetch'
contains "$opencode_reviewer" '"websearch":"allow"' 'OpenCode reviewer permite WebSearch'
contains "$opencode_reviewer" '"skill":"deny"' 'OpenCode reviewer conserva la ausencia previa de Skills'
contains "$opencode_reviewer" '"list":"allow","glob":"allow","grep":"allow","bash"' 'OpenCode reviewer conserva lectura y shell'
contains "$opencode_reviewer" '"edit":{"*":"allow"' 'OpenCode reviewer conserva edicion'
contains "$opencode_writer" '"webfetch":"deny"' 'OpenCode writer no recibe web'
absent "$opencode_writer" 'model:' 'OpenCode writer no fija model'
absent "$opencode_reviewer" 'model:' 'OpenCode reviewer no fija model'

echo '[c] terraform plan/apply y az denegados en OpenCode'
for rendered_name in opencode_writer opencode_reviewer; do
    rendered="${!rendered_name}"
    contains "$rendered" '"bash":{"*":"deny"' "$rendered_name mantiene shell deny por defecto"
    contains "$rendered" '"terraform init -backend=false":"allow"' "$rendered_name permite terraform init -backend=false"
    contains "$rendered" '"terraform validate":"allow"' "$rendered_name permite terraform validate"
    contains "$rendered" '"terraform fmt -recursive ../..":"allow"' "$rendered_name permite terraform fmt"
    for denied in '"terraform plan' '"terraform apply' '"az '; do
        absent "$rendered" "$denied" "$rendered_name no declara allow explicito para: $denied"
    done
done

echo '[e] mirrors identicos'
for agent in infra-writer infra-reviewer; do
    if cmp -s "$WORK/agents/$agent.md" "$WORK/dist/claude/agents/$agent.md"; then
        pass "integracion publica el mirror raiz de $agent"
    else
        fail "integracion no publica el mirror raiz de $agent"
    fi
    if cmp -s "$REPO_ROOT/agents/$agent.md" "$REPO_ROOT/dist/claude/agents/$agent.md"; then
        pass "el mirror raiz versionado de $agent coincide con dist/claude"
    else
        fail "el mirror raiz versionado de $agent diverge de dist/claude"
    fi
done

echo '[inventario] ambas distribuciones registran los dos agentes'
for runtime in claude opencode; do
    inventory="$WORK/dist/$runtime/.mefisto-generated-assets.json"
    for agent in infra-writer infra-reviewer; do
        if jq -e --arg id "src/published/agents/$agent.md" 'any(.assets[]; .id == $id)' "$inventory" >/dev/null; then
            pass "$runtime inventaria $agent"
        else
            fail "$runtime no inventaria $agent"
        fi
    done
done

if "$GENERATOR" --check --out "$WORK" \
    "$REPO_ROOT/src/published/agents/infra-writer.md" \
    "$REPO_ROOT/src/published/agents/infra-reviewer.md" >/dev/null; then
    pass 'check aislado no detecta divergencias, huerfanos ni copias manuales'
else
    fail 'check aislado detecto divergencias, huerfanos o copias manuales'
fi
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"

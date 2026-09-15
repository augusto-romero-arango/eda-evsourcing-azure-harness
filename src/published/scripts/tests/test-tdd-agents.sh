#!/usr/bin/env bash
# Verifica el corte vertical de los agentes neutrales del pipeline TDD.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
frontmatter() { awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$1"; }
body() { awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$1"; }
body_without_guard() { body "$1" | awk '!/\{\{mefisto:assert-consumer-repo\}\}/ && !/Antes de continuar, aborta si existe `src\/internal\/scripts\/generate-internal-adapters.sh`/ && !/^<!-- GENERADO por /'; }

# La lista es el unico punto que los siguientes cortes de la serie deben ampliar.
agents=(test-writer implementer)

echo '[fuentes] contrato neutral, guard y doctrina preservada'
for agent in "${agents[@]}"; do
    source="$REPO_ROOT/src/published/agents/$agent.md"
    mirror="$REPO_ROOT/agents/$agent.md"
    if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$source" >/dev/null; then pass "$agent valida"; else fail "$agent no valida"; fi
    if frontmatter "$source" | jq -e --arg id "$agent" '
        .kind == "agent" and .id == $id and (.description | type == "string" and length > 0) and
        .mode == "all" and .profile == "balanced" and .capabilities == ["read", "edit", "shell"] and
        (keys | sort) == ["capabilities", "description", "id", "kind", "mode", "profile"]' >/dev/null; then
        pass "$agent declara el contrato neutral exacto"
    else
        fail "$agent no declara el contrato neutral exacto"
    fi
    if [ "$(body "$source" | awk 'NF { print; exit }')" = '{{mefisto:assert-consumer-repo}}' ]; then pass "$agent inicia con el guard"; else fail "$agent no inicia con el guard"; fi
    if grep -Fqx '<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/agents/'"$agent"'.md. No editar a mano. -->' "$mirror"; then pass "$agent generado conserva marcador"; else fail "$agent generado sin marcador"; fi
    if diff -u <(body_without_guard "$source") <(body_without_guard "$mirror") >/dev/null; then pass "$agent conserva el cuerpo al proyectar Claude"; else fail "$agent altera el cuerpo al proyectar Claude"; fi
done

echo '[salidas] proyecciones Claude y OpenCode'
for agent in "${agents[@]}"; do
    claude="$REPO_ROOT/dist/claude/agents/$agent.md"
    opencode="$REPO_ROOT/dist/opencode/agents/$agent.md"
    if cmp -s "$claude" "$REPO_ROOT/agents/$agent.md"; then pass "$agent mirror Claude coincide byte a byte"; else fail "$agent mirror Claude diverge"; fi
    grep -Fq 'model: "sonnet"' "$claude" && pass "$agent Claude materializa balanced como sonnet" || fail "$agent Claude no materializa sonnet"
    grep -Fq 'tools: "Read, Glob, Grep, Edit, Write, Bash"' "$claude" && pass "$agent Claude materializa capacidades" || fail "$agent Claude no materializa capacidades"
    grep -Fq 'permission: ' "$opencode" && grep -Fq '"read":{"*":"allow"' "$opencode" && grep -Fq '"edit":{"*":"allow"' "$opencode" && grep -Fq '"bash":{"*":"deny"' "$opencode" && pass "$agent OpenCode materializa permisos" || fail "$agent OpenCode no materializa permisos"
done

if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi
printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"

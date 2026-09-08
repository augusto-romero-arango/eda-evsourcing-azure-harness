#!/usr/bin/env bash
# Verifica el corte vertical de los agentes neutrales del pipeline de tooling.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
FIXTURES="$HERE/fixtures/tooling-agents"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

echo '[fuentes] contrato neutral y responsabilidades'
for agent in tooling-writer tooling-reviewer; do
    source="$REPO_ROOT/src/published/agents/$agent.md"
    if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$source" >/dev/null; then pass "$agent valida"; else fail "$agent no valida"; fi
    [ "$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$source" | jq -r '.id')" = "$agent" ] && pass "$agent conserva su id estable" || fail "$agent no conserva su id estable"
    body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$source")"
    contains "$body" '{{mefisto:assert-consumer-repo}}' "$agent conserva el guard"
    contains "$body" 'archivo de summary' "$agent declara el summary entregado"
    absent "$body" '.claude/' "$agent no fija rutas de runtime"
    absent "$body" '.mefisto/' "$agent no fija rutas de estado"
done
writer="$(< "$REPO_ROOT/src/published/agents/tooling-writer.md")"
reviewer="$(< "$REPO_ROOT/src/published/agents/tooling-reviewer.md")"
contains "$writer" '## Implementado' 'writer declara Implementado'
contains "$writer" '## Pendiente/bloqueos' 'writer declara Pendiente/bloqueos'
contains "$reviewer" 'Corrige directamente' 'reviewer corrige directamente'
contains "$reviewer" '## Correcciones' 'reviewer declara Correcciones'

echo '[salidas] snapshots y capacidades derivadas'
for runtime in claude opencode; do
    for agent in tooling-writer tooling-reviewer; do
        actual="$REPO_ROOT/dist/$runtime/agents/$agent.md"
        expected="$FIXTURES/expected-$runtime-$agent.md"
        if cmp -s "$expected" "$actual"; then pass "$runtime/$agent coincide con el snapshot"; else fail "$runtime/$agent difiere del snapshot"; fi
        rendered="$(< "$actual")"
        contains "$rendered" 'Antes de continuar, aborta si existe' "$runtime/$agent traduce el guard"
        absent "$rendered" '{{mefisto:' "$runtime/$agent no conserva directivas"
        absent "$rendered" 'mcp' "$runtime/$agent omite MCP"
        absent "$rendered" 'Skill' "$runtime/$agent omite Skills"
        absent "$rendered" 'WebFetch' "$runtime/$agent omite web"
        absent "$rendered" 'Task' "$runtime/$agent omite delegacion"
    done
done
claude_writer="$(< "$REPO_ROOT/dist/claude/agents/tooling-writer.md")"
claude_reviewer="$(< "$REPO_ROOT/dist/claude/agents/tooling-reviewer.md")"
contains "$claude_writer" 'name: "tooling-writer"' 'Claude expone el id del writer'
contains "$claude_reviewer" 'name: "tooling-reviewer"' 'Claude expone el id del reviewer'
contains "$claude_writer" 'tools: "Read, Glob, Grep, Edit, Write, Bash"' 'Claude writer deriva solo read/edit/shell'
contains "$claude_writer" 'model: "sonnet"' 'Claude materializa perfil balanced'
absent "$claude_reviewer" 'model:' 'Claude preserva herencia del perfil deep'
opencode_writer="$(< "$REPO_ROOT/dist/opencode/agents/tooling-writer.md")"
contains "$opencode_writer" '"read":{"*":"allow"' 'OpenCode permite lectura'
contains "$opencode_writer" '"edit":{"*":"allow"' 'OpenCode permite edicion'
contains "$opencode_writer" '"bash":{"*":"deny"' 'OpenCode mantiene shell deny por defecto'

echo '[integracion] generador sin divergencias ni huerfanos'
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"

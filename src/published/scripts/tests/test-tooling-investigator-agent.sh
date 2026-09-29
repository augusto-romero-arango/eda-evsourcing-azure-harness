#!/usr/bin/env bash
# Contrato del agente tooling-investigator neutral y sus proyecciones publicadas (issue #1668).
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/agents/tooling-investigator.md"
CLAUDE="$REPO_ROOT/dist/claude/agents/tooling-investigator.md"
OPENCODE="$REPO_ROOT/dist/opencode/agents/tooling-investigator.md"
MIRROR="$REPO_ROOT/agents/tooling-investigator.md"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

echo '[a] metadata y perfil'
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$SOURCE" >/dev/null; then pass 'la fuente valida'; else fail 'la fuente no valida'; fi
metadata="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$SOURCE")"
if printf '%s' "$metadata" | jq -e '.kind == "agent" and .id == "tooling-investigator" and .mode == "all" and .profile == "deep" and .capabilities == ["read","edit","shell"] and (has("mcp") | not)' >/dev/null; then
    pass 'metadata agent/tooling-investigator/all/deep/read-edit-shell sin mcp'
else
    fail 'metadata neutral invalida'
fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor presente'
contains "$body" '{{mefisto:run work-status-collect.sh' 'usa el colector'
contains "$body" '{{mefisto:config-path}}' 'lee el config via config-path'
contains "$body" '{{mefisto:instructions-path}}' 'lee directivas via instructions-path'
contains "$body" 'docs/bitacora/field-notes/' 'conserva la restriccion de escritura'
contains "$body" '.mefisto/' 'cubre .mefisto/'
contains "$body" 'repoSlug' 'conserva el routing via repoSlug'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
claude_body="$(< "$CLAUDE")"
opencode_body="$(< "$OPENCODE")"

echo '[b] invocacion del colector'
for var in claude_body opencode_body; do
    runtime="${var%_body}"
    text="${!var}"
    total="$(printf '%s\n' "$text" | grep -c 'work-status-collect\.sh')"
    good="$(printf '%s\n' "$text" | grep -c "MEFISTO_RUNTIME=$runtime \"\${MEFISTO_PACKAGE_ROOT}/scripts/work-status-collect.sh\"")"
    if [ "$total" -gt 0 ] && [ "$total" -eq "$good" ]; then pass "$runtime: $good invocaciones via MEFISTO_PACKAGE_ROOT"; else fail "$runtime: $good de $total invocaciones bien formadas"; fi
done

echo '[c] ausencia de acoplamientos'
for var in body claude_body opencode_body; do
    text="$(printf '%s\n' "${!var}" | grep -v '^permission: ' | grep -v '\.plugin-root')"
    absent "$text" '.claude/pipeline/' "$var sin .claude/pipeline/"
    absent "$text" 'tooling-status.json' "$var sin tooling-status.json"
    absent "$text" 'tooling-history.jsonl' "$var sin tooling-history.jsonl"
    absent "$text" 'status.json' "$var sin status.json"
    absent "$text" 'history.jsonl' "$var sin history.jsonl"
    absent "$text" 'Claude Code' "$var sin Claude Code"
done
absent "$body" '.claude/' 'la fuente sin .claude/'
absent "$body" 'CLAUDE.md' 'la fuente sin CLAUDE.md'

echo '[d] mirror e inventario'
if cmp -s "$MIRROR" "$CLAUDE"; then pass 'mirror identico a dist/claude'; else fail 'mirror diverge'; fi
for inventory in "$REPO_ROOT/dist/claude/.mefisto-generated-assets.json" "$REPO_ROOT/dist/opencode/.mefisto-generated-assets.json"; do
    if jq -e '.assets[] | select(.destination == "agents/tooling-investigator.md")' "$inventory" >/dev/null 2>&1; then
        pass "$(basename "$(dirname "$inventory")") inventaria el agente"
    else
        fail "$(basename "$(dirname "$inventory")") no inventaria el agente"
    fi
done
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check al dia'; else fail '--check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"

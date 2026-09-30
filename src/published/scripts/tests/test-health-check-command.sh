#!/usr/bin/env bash
# Contrato del comando health-check neutral y sus proyecciones publicadas.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/commands/health-check.md"
CLAUDE="$REPO_ROOT/dist/claude/commands/health-check.md"
OPENCODE="$REPO_ROOT/dist/opencode/commands/mefisto:health-check.md"
MIRROR="$REPO_ROOT/commands/health-check.md"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

echo '[fuente] contrato neutral'
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$SOURCE" >/dev/null; then pass 'la fuente valida'; else fail 'la fuente no valida'; fi
metadata="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$SOURCE")"
if printf '%s' "$metadata" | jq -e '.kind == "command" and .id == "health-check" and .profile == "balanced" and (keys | sort) == ["description", "id", "kind", "profile"]' >/dev/null; then pass 'metadata sin arguments, agent ni capabilities'; else fail 'metadata neutral invalida'; fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor presente'
contains "$body" '{{mefisto:run azure-account-info.sh 2>&1}}' 'fuente valida la sesion con azure-account-info.sh'
for q in health-summary dead-letters function-errors; do
    contains "$body" "{{mefisto:run appinsights-query.sh $q --hours 24}}" "fuente consulta $q a 24h"
done
contains "$body" 'NO VERIFICADO' 'conserva NO VERIFICADO sin runs'
contains "$body" 'gh run list --workflow=infra-cd.yml' 'estado de infra-cd.yml via gh'
contains "$body" '{{mefisto:command bug}}' 'sugerencias con command bug'
contains "$body" '{{mefisto:command health-check}}' 'tip final con command health-check'
contains "$body" 'appinsights.env' 'reporta ausencia de appinsights.env'
absent "$body" 'az ' 'fuente sin az directo'
for forbidden in '.plugin-root' 'plugins/cache' 'PLUGIN_SCRIPTS' 'CLAUDE_'; do absent "$body" "$forbidden" "fuente sin token prohibido: $forbidden"; done

echo '[salidas] adaptadores y mirror'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
claude_body="$(< "$CLAUDE")"
opencode_body="$(< "$OPENCODE")"
for pair in "claude:$claude_body" "opencode:$opencode_body"; do
    rt="${pair%%:*}"; f="${pair#*:}"
    for q in health-summary dead-letters function-errors; do
        contains "$f" "MEFISTO_RUNTIME=$rt \"\${MEFISTO_PACKAGE_ROOT}/scripts/appinsights-query.sh\" $q --hours 24" "$rt invoca appinsights-query.sh $q"
    done
    contains "$f" "MEFISTO_RUNTIME=$rt \"\${MEFISTO_PACKAGE_ROOT}/scripts/azure-account-info.sh\" 2>&1" "$rt invoca azure-account-info.sh"
    absent "$f" '{{mefisto:' "$rt sin directivas sin resolver"
    absent "$f" 'az ' "$rt sin az directo"
    absent "$f" 'PLUGIN_SCRIPTS' "$rt sin PLUGIN_SCRIPTS"
    absent "$f" 'plugins/cache' "$rt sin plugins/cache"
    # La validacion de sesion precede a la primera consulta.
    before="${f%%appinsights-query.sh*}"
    contains "$before" 'azure-account-info.sh' "$rt valida la sesion antes de consultar"
done
for forbidden in '.claude/' '.plugin-root' 'CLAUDE_'; do absent "$opencode_body" "$forbidden" "OpenCode sin token Claude: $forbidden"; done
contains "$claude_body" 'model: "sonnet"' 'Claude materializa el perfil balanced'
absent "$opencode_body" 'model:' 'OpenCode no emite model'
if cmp -s "$MIRROR" "$CLAUDE"; then pass 'mirror Claude coincide byte a byte'; else fail 'mirror Claude diverge'; fi
contains "$(< "$MIRROR")" 'GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/commands/health-check.md' 'mirror conserva marcador generado'
for runtime in claude opencode; do
    if jq -e '.. | strings | select(. == "commands/health-check.md" or . == "commands/mefisto:health-check.md")' "$REPO_ROOT/dist/$runtime/.mefisto-generated-assets.json" >/dev/null 2>&1; then pass "inventario de dist/$runtime lo incluye"; else fail "inventario de dist/$runtime no lo incluye"; fi
done
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"

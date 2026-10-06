#!/usr/bin/env bash
# Contrato del agente bug-investigator neutral y sus proyecciones publicadas (issue #1667).
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/agents/bug-investigator.md"
CLAUDE="$REPO_ROOT/dist/claude/agents/bug-investigator.md"
OPENCODE="$REPO_ROOT/dist/opencode/agents/bug-investigator.md"
MIRROR="$REPO_ROOT/agents/bug-investigator.md"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

echo '[a] metadata, perfil y capacidad web'
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$SOURCE" >/dev/null; then pass 'la fuente valida'; else fail 'la fuente no valida'; fi
metadata="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$SOURCE")"
if printf '%s' "$metadata" | jq -e '.kind == "agent" and .id == "bug-investigator" and .mode == "all" and .profile == "deep" and .capabilities == ["read","edit","shell","web"] and (has("mcp") | not)' >/dev/null; then
    pass 'metadata agent/bug-investigator/all/deep/read-edit-shell-web sin mcp'
else
    fail 'metadata neutral invalida'
fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor presente'
contains "$body" '{{mefisto:instructions-path}}' 'lee instrucciones via instructions-path'
contains "$body" '{{mefisto:config-path}}' 'lee el config via config-path'
contains "$body" 'docs/bitacora/field-notes/' 'conserva la restriccion de escritura'
contains "$body" 'plan-sites' 'usa plan-sites'
contains "$body" 'plan-metrics' 'usa plan-metrics'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
claude_body="$(< "$CLAUDE")"
opencode_body="$(< "$OPENCODE")"
contains "$claude_body" 'name: "bug-investigator"' 'Claude expone el id'
contains "$claude_body" 'model: "opus"' 'Claude materializa deep como opus'
contains "$claude_body" 'WebSearch' 'Claude emite WebSearch'
contains "$claude_body" 'WebFetch' 'Claude emite WebFetch'
absent "$opencode_body" 'model:' 'OpenCode no emite model'
permission="$(awk 'NR == 1 { next } /^permission: / { sub(/^permission: /, ""); print; exit }' "$OPENCODE")"
if printf '%s' "$permission" | jq -e '.websearch == "allow" and .webfetch == "allow"' >/dev/null 2>&1; then pass 'OpenCode permite websearch/webfetch'; else fail 'OpenCode sin websearch/webfetch allow'; fi

echo '[b] invocaciones de appinsights-query.sh'
for var in claude_body opencode_body; do
    runtime="${var%_body}"
    text="$(printf '%s\n' "${!var}" | grep -v '^permission: ')"
    total="$(printf '%s\n' "$text" | grep -c 'appinsights-query\.sh')"
    good="$(printf '%s\n' "$text" | grep -c "MEFISTO_RUNTIME=$runtime \"\${MEFISTO_PACKAGE_ROOT}/scripts/appinsights-query.sh\"")"
    if [ "$total" -gt 0 ] && [ "$total" -eq "$good" ]; then pass "$runtime: $good invocaciones via MEFISTO_PACKAGE_ROOT con su runtime"; else fail "$runtime: $good de $total invocaciones bien formadas"; fi
done

echo '[c] ausencia de acoplamientos'
for var in body claude_body opencode_body; do
    text="$(printf '%s\n' "${!var}" | grep -v '^permission: ')"
    if printf '%s\n' "$text" | grep -Eq '(^|[[:space:]=])/tmp/'; then fail "$var con /tmp/"; else pass "$var sin /tmp/"; fi
    absent "$text" './scripts/' "$var sin ./scripts/"
    if printf '%s\n' "$text" | grep -Eq '(^|[^A-Za-z])az [a-z]'; then fail "$var con az directo"; else pass "$var sin az directo"; fi
done
absent "$body" 'CLAUDE.md' 'la fuente sin CLAUDE.md'
absent "$body" 'curl ' 'la fuente sin curl'
for var in body opencode_body; do
    text="${!var}"
    absent "$text" 'MEFISTO_RUNTIME=claude' "$var sin runtime claude"
done
absent "$body" '{{mefisto:state-path tmp}}/../' 'sin escape del state-path'
contains "$body" '{{mefisto:state-path tmp}}/publish' 'publish bajo state-path tmp'
contains "$body" '{{mefisto:state-path tmp}}/decompiled-vieja' 'decompilado bajo state-path tmp'

echo '[d] cada comando ejecutable casa una regla allow de OpenCode'
allowed() {
    printf '%s' "$permission" | jq -e --arg c "$1" '[.bash | to_entries[] | . as $e | select($e.value == "allow" and (($e.key | endswith("*")) and ($c | startswith($e.key | sub("\\*$"; ""))) or $e.key == $c))] | length > 0' >/dev/null 2>&1
}
commands="$(printf '%s\n' "$opencode_body" | awk '/^```bash$/ { f=1; next } /^```/ { f=0 } f' \
    | grep -E '^[[:space:]]*(dotnet|gh|ls|git|ilspycmd|diff|date|MEFISTO_RUNTIME=[a-z]+ "[^"]+/scripts/appinsights-query.sh") ' | sed 's/^[[:space:]]*//; s/ *#.*$//' | sort -u)"
[ -n "$commands" ] && pass 'hay comandos en los bloques bash' || fail 'no se extrajeron comandos'
while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    if allowed "$cmd"; then pass "allow casa: ${cmd:0:80}"; else fail "ninguna regla allow casa: $cmd"; fi
done <<< "$commands"
for denied in 'az monitor metrics list' 'az appservice plan show' 'curl http://x'; do
    if allowed "$denied"; then fail "OpenCode permite '$denied'"; else pass "OpenCode deniega '$denied'"; fi
done

echo '[e] mirror e inventario'
if cmp -s "$MIRROR" "$CLAUDE"; then pass 'mirror identico a dist/claude'; else fail 'mirror diverge'; fi
for inventory in "$REPO_ROOT/dist/claude/.mefisto-generated-assets.json" "$REPO_ROOT/dist/opencode/.mefisto-generated-assets.json"; do
    if jq -e '.assets[] | select(.destination == "agents/bug-investigator.md")' "$inventory" >/dev/null 2>&1; then
        pass "$(basename "$(dirname "$inventory")") inventaria el agente"
    else
        fail "$(basename "$(dirname "$inventory")") no inventaria el agente"
    fi
done
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check al dia'; else fail '--check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"

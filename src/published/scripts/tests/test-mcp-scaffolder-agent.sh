#!/usr/bin/env bash
# Contrato del agente mcp-scaffolder neutral y sus proyecciones publicadas (issue #1661).
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/agents/mcp-scaffolder.md"
CLAUDE="$REPO_ROOT/dist/claude/agents/mcp-scaffolder.md"
OPENCODE="$REPO_ROOT/dist/opencode/agents/mcp-scaffolder.md"
MIRROR="$REPO_ROOT/agents/mcp-scaffolder.md"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

echo '[a] metadata y perfil'
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$SOURCE" >/dev/null; then pass 'la fuente valida'; else fail 'la fuente no valida'; fi
metadata="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$SOURCE")"
if printf '%s' "$metadata" | jq -e '.kind == "agent" and .id == "mcp-scaffolder" and .mode == "all" and .profile == "balanced" and .capabilities == ["read","edit","shell","web"] and (has("mcp") | not)' >/dev/null; then
    pass 'metadata agent/mcp-scaffolder/all/balanced/read-edit-shell-web sin mcp'
else
    fail 'metadata neutral invalida'
fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor presente'
contains "$body" '{{mefisto:config-path}}' 'lee el config via config-path'
contains "$body" '{{mefisto:instructions-path}}' 'lee los tokens via instructions-path'
contains "$body" '{{mefisto:command onboard}}' 'remite al contrato via command onboard'

echo '[fuentes] reverificacion condicional de pines'
SOURCE_FIXTURE="$HERE/fixtures/mcp-scaffolder-sources/cases.json"
if jq -e '
    .schemaVersion == 1 and (.cases | length) == 4 and
    any(.cases[]; .id == "local-pins-intactos" and .expected == "sin-red-extra") and
    any(.cases[]; .id == "nuget-pin-exacto" and .version == "1.6.0" and .queryTerms == ["Microsoft.Azure.Functions.Worker.Extensions.Mcp","1.6.0"] and .expected == "version-exacta-no-latest") and
    any(.cases[]; .id == "oauth-versionado" and .queryTerms == ["WorkOS AuthKit","version requerida","OAuth"] and .expected == "fuente-oficial-versionada") and
    any(.cases[]; .id == "fuente-ausente" and .expected == "NO VERIFICADO") and
    all(.cases[].queryTerms[]; IN("Microsoft.Azure.Functions.Worker.Extensions.Mcp", "1.6.0", "WorkOS AuthKit", "version requerida", "OAuth"))
' "$SOURCE_FIXTURE" >/dev/null 2>&1; then
    pass 'fixture separa pines intactos, paquete exacto, OAuth versionado y fuente ausente'
else
    fail 'fixture de reverificacion de mcp-scaffolder incompleta'
fi
for statement in \
    'no consultes red por defecto y conserva el flujo existente' \
    'fuente publica oficial de **esa version requerida**' \
    'prueban existencia y dependencias de la version exacta, no autorizan adoptar la ultima version absoluta' \
    'nunca `client_id`, secretos, keys, URLs privadas, tokens, configuracion ni payloads del BC' \
    'informa **NO VERIFICADO** y deja como propuesta sin aprobar el cambio dependiente' \
    'no sustituyas la consulta con `curl` ni con un MCP generico' \
    'no autoriza configurar auth ni promete disponibilidad efectiva'; do
    contains "$body" "$statement" "conserva la regla de fuente: $statement"
done

echo '[b] ausencia de acoplamientos'
absent "$body" '.claude/harness.config.json' 'sin config legacy'
absent "$body" 'export MEFISTO_INSTRUCTIONS_PATH' 'sin export de instrucciones'
absent "$body" 'claude --agent' 'sin invocacion directa del CLI'
absent "$body" 'CLAUDE.md' 'sin resolucion manual de directivas'
echo '[salidas]'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
claude_body="$(< "$CLAUDE")"
opencode_body="$(< "$OPENCODE")"
contains "$claude_body" 'name: "mcp-scaffolder"' 'Claude expone el id'
contains "$claude_body" 'model: "sonnet"' 'Claude materializa balanced como sonnet'
contains "$claude_body" 'tools: "Read, Glob, Grep, Edit, Write, Bash, WebFetch, WebSearch"' 'Claude suma solo el par web'
absent "$opencode_body" 'model:' 'OpenCode no emite model'
contains "$opencode_body" '"webfetch":"allow"' 'OpenCode permite webfetch solo en este agente'
contains "$opencode_body" '"websearch":"allow"' 'OpenCode permite websearch solo en este agente'
for text_var in claude_body opencode_body; do
    text="${!text_var}"
    absent "$text" 'export MEFISTO_INSTRUCTIONS_PATH="AGENTS.md"' "$text_var sin resolucion manual fija"
done

echo '[c] cada comando ejecutable casa una regla allow de OpenCode'
permission="$(awk 'NR == 1 { next } /^permission: / { sub(/^permission: /, ""); print; exit }' "$OPENCODE")"
allowed() {
    printf '%s' "$permission" | jq -e --arg c "$1" '[.bash | to_entries[] | . as $e | select($e.value == "allow" and (($e.key | endswith("*")) and ($c | startswith($e.key | sub("\\*$"; ""))) or $e.key == $c))] | length > 0' >/dev/null 2>&1
}
commands="$(printf '%s\n' "$body" | awk '/^```bash$/ { f=1; next } /^```/ { f=0 } f' \
    | grep -E '^[[:space:]]*(dotnet|terraform|sed|mkdir|cd|test|jq|grep|cat|echo|printf|awk|git) ' | sed 's/^[[:space:]]*//' | sort -u)"
[ -n "$commands" ] && pass 'hay comandos en los bloques bash' || fail 'no se extrajeron comandos'
while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    if allowed "$cmd"; then pass "allow casa: $cmd"; else fail "ninguna regla allow casa: $cmd"; fi
done <<< "$commands"
for sample in 'terraform fmt -recursive ../..' 'terraform validate' 'terraform init -backend=false' 'dotnet build' 'dotnet test' 'sed -n 1p x' 'mkdir -p x' 'git rev-parse --show-toplevel' 'awk -F- x' 'test -f x'; do
    if allowed "$sample"; then pass "bash permite '$sample'"; else fail "bash no permite '$sample'"; fi
done

echo '[d] comandos denegados'
for denied in 'az functionapp keys list -g x -n y' 'terraform plan' 'terraform apply' 'curl http://x'; do
    if allowed "$denied"; then fail "OpenCode permite '$denied'"; else pass "OpenCode deniega '$denied'"; fi
done
if printf '%s' "$permission" | jq -e '.bash["*"] == "deny"' >/dev/null 2>&1; then pass 'catch-all bash deny'; else fail 'sin catch-all bash deny'; fi
contains "$body" 'az functionapp keys list' 'la guia de onboarding conserva az functionapp keys list'

echo '[e] mirror'
if cmp -s "$MIRROR" "$CLAUDE"; then pass 'mirror identico a dist/claude'; else fail 'mirror diverge'; fi
for inventory in "$REPO_ROOT/dist/claude/.mefisto-generated-assets.json" "$REPO_ROOT/dist/opencode/.mefisto-generated-assets.json"; do
    if jq -e '.assets[] | select(.destination == "agents/mcp-scaffolder.md")' "$inventory" >/dev/null 2>&1; then
        pass "$(basename "$(dirname "$inventory")") inventaria el agente"
    else
        fail "$(basename "$(dirname "$inventory")") no inventaria el agente"
    fi
done
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check al dia'; else fail '--check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"

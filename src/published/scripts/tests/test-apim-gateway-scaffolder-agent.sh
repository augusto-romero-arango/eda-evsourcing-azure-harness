#!/usr/bin/env bash
# Contrato del agente apim-gateway-scaffolder neutral y sus proyecciones publicadas
# (issue #1656: migracion desde agents/apim-gateway-scaffolder.md hand-escrito Claude-only).
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/agents/apim-gateway-scaffolder.md"
CLAUDE="$REPO_ROOT/dist/claude/agents/apim-gateway-scaffolder.md"
OPENCODE="$REPO_ROOT/dist/opencode/agents/apim-gateway-scaffolder.md"
MIRROR="$REPO_ROOT/agents/apim-gateway-scaffolder.md"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

echo '[fuente] (a) metadata y perfil'
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$SOURCE" >/dev/null; then pass 'la fuente valida'; else fail 'la fuente no valida'; fi
metadata="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$SOURCE")"
if printf '%s' "$metadata" | jq -e '.kind == "agent" and .id == "apim-gateway-scaffolder" and .mode == "all" and .profile == "balanced" and .capabilities == ["read","edit","shell","web"] and (has("mcp") | not)' >/dev/null; then
    pass 'metadata declara agent/apim-gateway-scaffolder/all/balanced/read-edit-shell-web sin mcp'
else
    fail 'metadata neutral invalida'
fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor presente'
contains "$body" '{{mefisto:instructions-path}}' 'cita Verificacion de fuentes via instructions-path'
contains "$body" 'https://api.workos.com/user_management/<client_id>/.well-known/openid-configuration' 'Paso 0.3 apunta al discovery doc'
contains "$body" 'NO VERIFICADO -- reconfirmar antes de aplicar' 'se conserva la marca NO VERIFICADO'
for command in '(cd "infra/environments/${ENV}" && terraform fmt -recursive ../..)' '(cd "infra/environments/${ENV}" && terraform init -backend=false)' '(cd "infra/environments/${ENV}" && terraform validate)'; do
    contains "$body" "$command" "validacion local usa subshell para $command"
done
absent "$body" 'terraform -chdir=' 'validacion local no usa -chdir'
contains "$body" 'command -v terraform' 'consulta canonica de disponibilidad'

echo '[fuente] (b) ausencia de curl y de tokens de runtime'
for pattern in 'curl' 'export MEFISTO_INSTRUCTIONS_PATH' '.claude' 'claude --agent' 'opencode' 'AGENTS.md' 'CLAUDE.md'; do
    absent "$body" "$pattern" "fuente no contiene '$pattern'"
done

echo '[salidas] adaptadores y capacidad web'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
claude_body="$(< "$CLAUDE")"
opencode_body="$(< "$OPENCODE")"
contains "$claude_body" 'name: "apim-gateway-scaffolder"' 'Claude expone el id del agente'
contains "$claude_body" 'model: "sonnet"' 'Claude materializa el perfil balanced como sonnet'
contains "$claude_body" 'WebFetch' 'Claude emite WebFetch'
contains "$claude_body" 'WebSearch' 'Claude emite WebSearch'
absent "$opencode_body" 'model:' 'OpenCode no emite model'
contains "$opencode_body" 'mode: "all"' 'OpenCode conserva mode all'
permission="$(awk 'NR == 1 { next } /^permission: / { sub(/^permission: /, ""); print; exit }' "$OPENCODE")"
for tool in webfetch websearch; do
    if printf '%s' "$permission" | jq -e --arg t "$tool" '.[$t] == "allow"' >/dev/null 2>&1; then pass "OpenCode permite $tool"; else fail "OpenCode no permite $tool"; fi
done
for text_var in claude_body opencode_body; do
    text="${!text_var}"
    absent "$text" 'curl -' "$text_var no invoca curl"
    absent "$text" 'claude --agent' "$text_var no invoca el CLI de un runtime"
done

echo '[c] politica bash de OpenCode'
for pattern in 'git *' 'test *' 'echo *' 'grep *' 'command -v terraform' 'terraform fmt -recursive ../..' 'terraform fmt -check -recursive ../..' 'terraform validate' 'terraform validate -no-color' 'terraform init -backend=false' 'terraform init -backend=false -input=false'; do
    if printf '%s' "$permission" | jq -e --arg p "$pattern" '.bash[$p] == "allow"' >/dev/null 2>&1; then pass "bash permite '$pattern'"; else fail "bash no permite '$pattern'"; fi
done
if printf '%s' "$permission" | jq -e '.bash["curl *"] == "deny"' >/dev/null 2>&1; then pass 'curl denegado'; else fail 'curl no esta denegado'; fi
for cmd in 'az rest --method get' 'terraform plan' 'terraform apply'; do
    if printf '%s' "$permission" | jq -e --arg c "$cmd" '.bash as $b | ($b["*"] == "deny") and (($b | to_entries | map(select(.value == "allow" and (.key | endswith("*")) and (.key as $k | $c | startswith($k | sub("\\*$"; "")))))) | length == 0)' >/dev/null 2>&1; then
        pass "'$cmd' queda denegado"
    else
        fail "'$cmd' no queda denegado"
    fi
done

echo '[mirror] agents/apim-gateway-scaffolder.md pasa a generado'
if cmp -s "$MIRROR" "$CLAUDE"; then pass 'mirror Claude coincide byte a byte'; else fail 'mirror Claude diverge'; fi
contains "$(< "$MIRROR")" '<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/agents/apim-gateway-scaffolder.md. No editar a mano. -->' 'mirror conserva marcador generado'
for inventory in "$REPO_ROOT/dist/claude/.mefisto-generated-assets.json" "$REPO_ROOT/dist/opencode/.mefisto-generated-assets.json"; do
    if jq -e '.assets[] | select(.destination == "agents/apim-gateway-scaffolder.md")' "$inventory" >/dev/null 2>&1; then
        pass "$(basename "$(dirname "$inventory")") inventaria el agente"
    else
        fail "$(basename "$(dirname "$inventory")") no inventaria el agente"
    fi
done
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"

#!/usr/bin/env bash
# Contrato del agente infra-base-scaffolder neutral y sus proyecciones publicadas
# (issue #1649: migracion desde agents/infra-base-scaffolder.md hand-escrito Claude-only).
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
SOURCE="$REPO_ROOT/src/published/agents/infra-base-scaffolder.md"
CLAUDE="$REPO_ROOT/dist/claude/agents/infra-base-scaffolder.md"
OPENCODE="$REPO_ROOT/dist/opencode/agents/infra-base-scaffolder.md"
MIRROR="$REPO_ROOT/agents/infra-base-scaffolder.md"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }

echo '[fuente] (a) metadata y perfil'
if bash "$REPO_ROOT/src/published/scripts/validate-published-artifacts.sh" "$SOURCE" >/dev/null; then pass 'la fuente valida'; else fail 'la fuente no valida'; fi
metadata="$(awk 'NR == 1 { next } $0 == "---" { exit } { print }' "$SOURCE")"
if printf '%s' "$metadata" | jq -e '.kind == "agent" and .id == "infra-base-scaffolder" and .mode == "all" and .profile == "balanced" and .capabilities == ["read","edit","shell"] and (has("mcp") | not)' >/dev/null; then
    pass 'metadata declara agent/infra-base-scaffolder/all/balanced/read-edit-shell sin mcp'
else
    fail 'metadata neutral invalida'
fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor presente'
contains "$body" '{{mefisto:config-path}}' 'lee el config via config-path'
contains "$body" '{{mefisto:instructions-path}}' 'lee RootNamespace via instructions-path'
contains "$body" '{{mefisto:command onboard}}' 'remite al diagnostico via command onboard'
contains "$body" '{{mefisto:run register-harness-secret.sh' 'Paso 2b.0 delega en register-harness-secret.sh via run'

echo '[fuente] (b) ausencia de acoplamientos de runtime'
for pattern in 'source "$' 'source "${' '_pipeline-common.sh' '.plugin-root' 'plugins/cache' 'PLUGIN_ROOT' 'export MEFISTO_INSTRUCTIONS_PATH' '.claude/harness.config.json' 'upsert_harness_secret'; do
    absent "$body" "$pattern" "fuente no contiene '$pattern'"
done

echo '[salidas] adaptadores y mirror'
for file in "$CLAUDE" "$OPENCODE"; do [ -f "$file" ] && pass "existe ${file#"$REPO_ROOT/"}" || fail "falta ${file#"$REPO_ROOT/"}"; done
claude_body="$(< "$CLAUDE")"
opencode_body="$(< "$OPENCODE")"
contains "$claude_body" 'name: "infra-base-scaffolder"' 'Claude expone el id del agente'
contains "$claude_body" 'model: "sonnet"' 'Claude materializa el perfil balanced como sonnet'
absent "$opencode_body" 'model:' 'OpenCode no emite model'
contains "$opencode_body" 'mode: "all"' 'OpenCode conserva mode all'
contains "$opencode_body" '"microsoft-learn_*":false' 'OpenCode deniega las tools de microsoft-learn (sin mcp)'
contains "$opencode_body" '"terraform_*":false' 'OpenCode deniega las tools de terraform'
for text_var in claude_body opencode_body; do
    text="${!text_var}"
    absent "$text" 'source "${PLUGIN_ROOT' "$text_var no hace source del script comun"
    absent "$text" '_pipeline-common.sh' "$text_var no referencia _pipeline-common.sh"
    absent "$text" 'CONFIG="$REPO_ROOT' "$text_var no reconstruye la ruta del config a mano"
done

echo '[c] Paso 2b.0 invoca el script distribuido con el runtime de su adaptador'
contains "$claude_body" 'MEFISTO_RUNTIME=claude "${MEFISTO_PACKAGE_ROOT}/scripts/register-harness-secret.sh" "marten-connection" "composite" "marten-connection"' 'Claude registra marten-connection como composite'
contains "$opencode_body" 'MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/register-harness-secret.sh" "marten-connection" "composite" "marten-connection"' 'OpenCode registra marten-connection como composite'
contains "$opencode_body" '"app-insights-connection" "output" "app_insights_connection_string"' 'se conserva app-insights-connection como output'
contains "$opencode_body" '"github-secret" "SB_EXTERNAL_COSMOS_CONNECTION_STRING"' 'se conserva el registro por alias external como github-secret'

echo '[d] politica bash de OpenCode'
permission="$(awk 'NR == 1 { next } /^permission: / { sub(/^permission: /, ""); print; exit }' "$OPENCODE")"
for pattern in 'git *' 'jq *' 'test *' '[ *' 'echo *' 'printf *' 'grep *' 'mkdir *' 'terraform fmt*' 'terraform init -backend=false*' 'terraform validate*' '${MEFISTO_PACKAGE_ROOT}/scripts/*'; do
    if printf '%s' "$permission" | jq -e --arg p "$pattern" '.bash[$p] == "allow"' >/dev/null 2>&1; then pass "bash permite '$pattern'"; else fail "bash no permite '$pattern'"; fi
done
for command in 'terraform plan' 'terraform apply' 'az group list' 'source x.sh'; do
    if printf '%s' "$permission" | jq -e --arg c "$command" '.bash as $b | ($b | to_entries | map(select(.key != "*" and (.key | sub("\\*$"; "") as $pre | $c | startswith($pre))))) | length == 0 and $b["*"] == "deny"' >/dev/null 2>&1; then
        pass "'$command' queda denegado por el catch-all"
    else
        fail "'$command' no queda denegado"
    fi
done

echo '[mirror] agents/infra-base-scaffolder.md pasa a generado'
if cmp -s "$MIRROR" "$CLAUDE"; then pass 'mirror Claude coincide byte a byte'; else fail 'mirror Claude diverge'; fi
contains "$(< "$MIRROR")" '<!-- GENERADO por src/published/scripts/generate-published-adapters.sh desde src/published/agents/infra-base-scaffolder.md. No editar a mano. -->' 'mirror conserva marcador generado'
for inventory in "$REPO_ROOT/dist/claude/.mefisto-generated-assets.json" "$REPO_ROOT/dist/opencode/.mefisto-generated-assets.json"; do
    if jq -e '.assets[] | select(.destination == "agents/infra-base-scaffolder.md")' "$inventory" >/dev/null 2>&1; then
        pass "$(basename "$(dirname "$inventory")") inventaria el agente"
    else
        fail "$(basename "$(dirname "$inventory")") no inventaria el agente"
    fi
done
if "$GENERATOR" --check >/dev/null; then pass 'generate-published-adapters --check esta al dia'; else fail 'generate-published-adapters --check detecto divergencias'; fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"

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
if printf '%s' "$metadata" | jq -e '.kind == "agent" and .id == "mcp-scaffolder" and .mode == "all" and .profile == "balanced" and .capabilities == ["read","edit","shell"] and (has("mcp") | not)' >/dev/null; then
    pass 'metadata agent/mcp-scaffolder/all/balanced/read-edit-shell sin mcp'
else
    fail 'metadata neutral invalida'
fi
body="$(awk 'NR == 1 { next } $0 == "---" && !seen { seen=1; next } seen { print }' "$SOURCE")"
contains "$body" '{{mefisto:assert-consumer-repo}}' 'guard consumidor presente'
contains "$body" '{{mefisto:config-path}}' 'lee el config via config-path'
contains "$body" '{{mefisto:instructions-path}}' 'lee los tokens via instructions-path'
contains "$body" '{{mefisto:command onboard}}' 'remite al contrato via command onboard'

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
absent "$opencode_body" 'model:' 'OpenCode no emite model'
for text_var in claude_body opencode_body; do
    text="${!text_var}"
    absent "$text" 'export MEFISTO_INSTRUCTIONS_PATH="AGENTS.md"' "$text_var sin resolucion manual fija"
done

echo '[identidad] identidad derivada del token (issue #1934)'
contains "$body" 'internal async Task Ejecutar(' 'CA-1/2: IdentidadTenantMcpMiddleware con nucleo testeable'
contains "$body" 'tool.TryGetHttpTransport(out var transporte)' 'CA-1: lee el Bearer del transporte de ToolInvocationContext'
contains "$body" 'DerivadorIdentidadTenantMcp' 'CA-1: derivador org_id/sub'
contains "$body" 'builder.UseMiddleware<IdentidadTenantMcpMiddleware>();' 'CA-1: Program.cs registra el middleware de identidad'
contains "$body" 'despues de AutorizacionMcpMiddleware' 'CA-1: orden tras AutorizacionMcpMiddleware'
contains "$body" '<ProjectReference Include="..\<RootNamespace>.TenantResolver\' 'CA-1: ProjectReference a TenantResolver'
contains "$body" 'public async Task<ClaimsPrincipal?> ValidarAsync(' 'CA-1: validador expone el ClaimsPrincipal'
contains "$body" 'TenantExecutionContext.SetDerivedIdentity(' 'CA-2: publica identidad ambiente'
contains "$body" 'items[SesionUsuario.ClaveEnContexto]' 'CA-2: publica la sesion'
contains "$body" 'ErrorTokenSinOrganizacionOUsuario' 'CA-2: rechazo con mensaje resx'
contains "$body" 'Fallback explicito del camino SIN Bearer' 'CA-3: fallback explicito'
absent "$body" 'TODO(tenancy etapa b' 'CA-3: sin TODO de identidad derivada'
absent "$body" 'llegan a este worker SIN header Authorization' 'CA-3: ya no afirma que el Authorization nunca llega'
contains "$body" 'internal const string NombreTool = "obtener_sesion";' 'CA-4: tool obtener_sesion'
contains "$body" '"tenant_fijo"' 'CA-4: origen tenant_fijo'
contains "$body" 'Ejecutar_PublicaIdentidadAmbienteYSesion_CuandoElBearerEsValido' 'CA-5: test del middleware publica identidad y sesion'
contains "$body" 'Ejecutar_Rechaza_CuandoElTokenNoTraeOrgIdOSub' 'CA-5: rechazo sin org_id/sub'
contains "$body" 'ObtenerSesionTool.NombreTool' 'CA-5: composicion pinnea obtener_sesion'
contains "$body" 'ObtenerSesion_Responde_TenantFijo_CuandoSeInvocaConSystemKeySinBearer' 'CA-6: smoke obtener_sesion'

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
for sample in 'terraform fmt -check' 'terraform validate' 'terraform init -backend=false' 'dotnet build' 'dotnet test' 'sed -n 1p x' 'mkdir -p x' 'git rev-parse --show-toplevel' 'awk -F- x' '[ -f x ]'; do
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

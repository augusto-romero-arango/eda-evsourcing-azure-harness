#!/usr/bin/env bash
# Prueba el hook config generado sin iniciar OpenCode ni consultar red.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
ADAPTER="$REPO_ROOT/src/published/scripts/adapters/adapter-opencode.sh"
REGISTRY="$REPO_ROOT/src/published/contract/mcp-servers.json"
GENERATED="$REPO_ROOT/dist/opencode/plugins/mefisto-mcp.js"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

"$ADAPTER" render-asset mcp-config "$REGISTRY" > "$WORK/mefisto-mcp.js" || exit 1
cmp -s "$GENERATED" "$WORK/mefisto-mcp.js" && pass 'snapshot generado coincide con dist/opencode' || fail 'snapshot MCP publicado divergente'
RESULT="$(node --input-type=module <<EOF
import plugin from "file://$WORK/mefisto-mcp.js";
const expected = { type: "remote", url: "https://learn.microsoft.com/api/mcp", enabled: true, oauth: false };
const run = async (config) => { const logs = []; const hooks = await plugin({ client: { app: { log: async (entry) => logs.push(entry) } } }); await hooks.config(config); return { config, logs }; };
const empty = await run({});
const same = await run({ mcp: { "microsoft-learn": { ...expected }, foreign: { type: "remote", url: "https://example.test" } } });
const sensitive = { type: "remote", url: "SENTINELA", enabled: true, oauth: false, headers: { Authorization: "token-secreto" } };
const conflictConfig = { mcp: { "microsoft-learn": sensitive, foreign: { value: "preservado" } } };
const conflictBefore = JSON.stringify(conflictConfig);
const conflict = await run(conflictConfig);
const twice = await run({ mcp: {} }); await (await plugin({})).config(twice.config);
empty.config.mcp["microsoft-learn"].url = "mutada";
const isolated = await run({});
const hookFailureLogs = [];
const failureHooks = await plugin({ client: { app: { log: async (entry) => hookFailureLogs.push(entry) } } });
await failureHooks.config(Object.freeze({}));
const rejectedLogHooks = await plugin({ client: { app: { log: async () => { throw new Error("fallo-log"); } } } });
await rejectedLogHooks.config({ mcp: { "microsoft-learn": sensitive } });
const conflictLog = conflict.logs[0]?.body;
console.log(JSON.stringify([
  Object.keys(isolated.config.mcp).length === 1 && JSON.stringify(isolated.config.mcp["microsoft-learn"]) === JSON.stringify(expected),
  same.logs.length === 0 && same.config.mcp.foreign.url === "https://example.test",
  JSON.stringify(conflict.config) === conflictBefore && conflict.logs.length === 1 && conflictLog?.message === "mcp_config_conflict" && conflictLog?.extra?.event === "mcp_config_conflict" && conflictLog?.extra?.server === "microsoft-learn" && !JSON.stringify(conflict.logs[0]).includes("SENTINELA") && !JSON.stringify(conflict.logs[0]).includes("token-secreto"),
  JSON.stringify(twice.config.mcp["microsoft-learn"]) === JSON.stringify(expected) && Object.keys(twice.config.mcp).length === 1,
  hookFailureLogs.length === 1 && hookFailureLogs[0].body.message === "mcp_config_hook_failed"
]));
EOF
)"
[ "$RESULT" = '[true,true,true,true,true]' ] && pass 'vacía, idéntica, conflicto, ajena, doble invocación y fallos preservan el contrato' || fail "contrato del hook MCP invalido: $RESULT"
grep -Eq 'headers|timeout|environment|token|secret' "$WORK/mefisto-mcp.js" && fail 'plugin contiene configuracion sensible o ajena' || pass 'plugin no serializa headers, timeout, entorno ni secretos'
jq -e '[.servers[] | select(.provisioning == "external") | .id] == ["terraform"]' "$REGISTRY" >/dev/null && ! grep -q 'terraform' "$WORK/mefisto-mcp.js" && pass 'servidores external no se materializan' || fail 'servidor external materializado'
cp "$REGISTRY" "$WORK/invalid-registry.json"
jq '.servers[0].authentication = "oauth"' "$REGISTRY" > "$WORK/invalid-registry.json"
if "$ADAPTER" render-asset mcp-config "$WORK/invalid-registry.json" > "$WORK/invalid.js" 2>/dev/null; then fail 'registro inválido permitió generar'; else pass 'registro inválido falla durante generación'; fi
printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"

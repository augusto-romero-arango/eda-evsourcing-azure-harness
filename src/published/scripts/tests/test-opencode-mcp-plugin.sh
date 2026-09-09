#!/usr/bin/env bash
# Prueba el hook config generado sin iniciar OpenCode ni consultar red.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
ADAPTER="$REPO_ROOT/src/published/scripts/adapters/adapter-opencode.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

"$ADAPTER" render-asset mcp-config "$REPO_ROOT/src/published/contract/mcp-servers.json" > "$WORK/mefisto-mcp.js" || exit 1
RESULT="$(node --input-type=module <<EOF
import plugin from "file://$WORK/mefisto-mcp.js";
const expected = { type: "remote", url: "https://learn.microsoft.com/api/mcp", enabled: true, oauth: false };
const run = async (config) => { const logs = []; const hooks = await plugin({ client: { app: { log: async (entry) => logs.push(entry) } } }); await hooks.config(config); return { config, logs }; };
const empty = await run({});
const same = await run({ mcp: { "microsoft-learn": { ...expected }, foreign: { type: "remote", url: "https://example.test" } } });
const conflict = await run({ mcp: { "microsoft-learn": { type: "remote", url: "SENTINELA", enabled: true, oauth: false }, foreign: { value: "preservado" } } });
const twice = await run({ mcp: {} }); await (await plugin({})).config(twice.config);
console.log(JSON.stringify([JSON.stringify(empty.config.mcp["microsoft-learn"]) === JSON.stringify(expected) && Object.keys(empty.config.mcp).length === 1, same.logs.length === 0 && same.config.mcp.foreign.url === "https://example.test", conflict.config.mcp["microsoft-learn"].url === "SENTINELA" && conflict.config.mcp.foreign.value === "preservado" && conflict.logs.length === 1 && conflict.logs[0].body.event === "mcp_config_conflict" && !JSON.stringify(conflict.logs[0]).includes("SENTINELA"), JSON.stringify(twice.config.mcp["microsoft-learn"]) === JSON.stringify(expected) && Object.keys(twice.config.mcp).length === 1]));
EOF
)"
[ "$RESULT" = '[true,true,true,true]' ] && pass 'vacía, idéntica, conflicto, ajena y doble invocación preservan el contrato' || fail 'contrato del hook MCP invalido'
grep -Eq 'headers|timeout|environment|token|secret' "$WORK/mefisto-mcp.js" && fail 'plugin contiene configuracion sensible o ajena' || pass 'plugin no serializa headers, timeout, entorno ni secretos'
printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"

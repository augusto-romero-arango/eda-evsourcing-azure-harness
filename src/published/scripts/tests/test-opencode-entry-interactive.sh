#!/usr/bin/env bash
# Verifica (#2012) que el plugin de entrada OpenCode inyecta un command-entry-<id>
# por cada comando del catalogo en todos los estados de autonomia: interactivo
# (sin politica propia ni admision) cuando disabled/needs-approval, controlado
# cuando ready, y falla con la causa concreta cuando conflict. Sin runtime ni red.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
ADAPTER="$REPO_ROOT/src/published/scripts/adapters/adapter-opencode.sh"
SOURCE="$REPO_ROOT/src/published/contract/command-entry.json"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

VERSION="$(jq -r .version "$REPO_ROOT/src/published/release-identity.json")"; COMMIT="$(jq -r .commit "$REPO_ROOT/src/published/release-identity.json")"
make_release() { # root resolver-output-json
  local root="$1"
  mkdir -p "$root/plugins" "$root/scripts" "$root/fake"
  "$ADAPTER" render-asset command-entry-plugin "$SOURCE" > "$root/plugins/mefisto-command-entry.js" || exit 1
  cp "$REPO_ROOT/dist/opencode/command-entry-manifest.json" "$root/command-entry-manifest.json"
  jq -n --arg v "$VERSION" --arg c "$COMMIT" '{schemaVersion:1,runtime:"opencode",version:$v,commit:$c}' > "$root/mefisto-manifest.json"
  printf '%s\n' "$2" > "$root/fake/config.json"
  printf '#!/usr/bin/env bash\ncat >/dev/null\ncat "$(cd "$(dirname "$0")/.." && pwd -P)/fake/config.json"\n' > "$root/scripts/resolve-command-entry.sh"
  chmod 0755 "$root/scripts/resolve-command-entry.sh"
}
cat > "$WORK/run.mjs" <<'EOS'
import { pathToFileURL } from "node:url";
const [root, project] = process.argv.slice(2);
const factory = (await import(pathToFileURL(root + "/plugins/mefisto-command-entry.js").href)).default;
const calls = [];
const hooks = await factory({ client: { app: { log: async () => {} }, session: { get: async () => ({ data: { id: "s1", directory: project, permission: [] } }) } }, directory: project, worktree: project });
const ids = JSON.parse(process.env.CATALOG);
const cfg = { default_agent: "build", command: Object.fromEntries(ids.map((id) => ["mefisto:" + id, { template: "T-" + id, agent: "command-entry-" + id, subtask: false }])), agent: {} };
await hooks.config(cfg);
let result = "ok";
const hook = hooks["command.execute.before"];
try { await hook({ command: "mefisto:" + ids[0], sessionID: "s1", arguments: "" }, { parts: [] }); } catch (e) { result = String(e.message); }
const missing = ids.filter((id) => cfg.command["mefisto:" + id].agent && !cfg.agent[cfg.command["mefisto:" + id].agent]);
console.log(JSON.stringify({ agents: cfg.agent, missing, result, routed: ids.every((id) => cfg.command["mefisto:" + id].agent === "command-entry-" + id) }));
EOS
mkdir -p "$WORK/project/.claude"; printf '{}\n' > "$WORK/project/.claude/harness.config.json"; git -C "$WORK/project" init -q
CATALOG="$(jq -c '[.commands[].id]' "$SOURCE")"; export CATALOG
count="$(jq '[.commands[].id] | length' "$SOURCE")"
denied="$(jq -c '[.commands[].id | {command:("mefisto:"+.),agent:("command-entry-"+.),admitted:false}]' "$SOURCE")"
agents_rules="$(jq -c '[.commands[].id | {id:("command-entry-"+.),rules:[{permission:"read",pattern:"*",value:"deny"},{permission:"webfetch",pattern:"*",value:"deny"}]}]' "$SOURCE")"

run_state() { # name resolver-json
  local R="$WORK/r-$1"; make_release "$R" "$2"
  node "$WORK/run.mjs" "$R" "$WORK/project" 2>/dev/null
}
interactive_check() { # label json
  jq -e --argjson n "$count" '
    (.agents | length) == $n and (.missing | length) == 0 and .routed and
    all(.agents[]; (has("permission") | not) and .mode == "primary") and
    (.result == "ok")' <<< "$2" >/dev/null \
    && pass "$1: agente interactivo por comando, sin politica propia ni admision" || fail "$1: $2"
}

out="$(run_state noprofile '{"schemaVersion":1,"admissionScope":"entry","status":"disabled","reasonCode":"NO_PROFILE","agents":[],"bindings":[]}')"
interactive_check 'disabled/NO_PROFILE' "$out"
out="$(run_state revoked "$(jq -cn --argjson b "$denied" '{schemaVersion:1,admissionScope:"entry",status:"disabled",reasonCode:"CONSENT_REVOKED",agents:[],bindings:$b}')")"
interactive_check 'disabled/CONSENT_REVOKED' "$out"
out="$(run_state needs "$(jq -cn --argjson b "$denied" '{schemaVersion:1,admissionScope:"entry",status:"needs-approval",reasonCode:"NEEDS_APPROVAL",agents:[],bindings:$b}')")"
interactive_check 'needs-approval' "$out"

out="$(run_state ready "$(jq -cn --argjson b "$denied" --argjson a "$agents_rules" '{schemaVersion:1,admissionScope:"entry",status:"ready",reasonCode:"OK",projectionDigest:"d1",agents:$a,bindings:$b}')")"
jq -e --argjson n "$count" '(.agents | length) == $n and (.missing | length) == 0 and .routed and all(.agents[]; has("permission") and .permission.webfetch == "deny")' <<< "$out" >/dev/null \
  && pass 'ready: entrada controlada con politica de Mefisto, sin cambios' || fail "ready: $out"

out="$(run_state conflict "$(jq -cn --argjson b "$denied" '{schemaVersion:1,admissionScope:"entry",status:"conflict",reasonCode:"DELEGATE_MISSING",agents:[],bindings:$b}')")"
jq -e --argjson n "$count" '(.missing | length) == 0 and .routed and (.agents | length) == $n and (.result | startswith("mefisto_entry_not_admitted:"))' <<< "$out" >/dev/null \
  && pass 'conflict: agentes presentes y el comando falla con mefisto_entry_not_admitted:<codigo>' || fail "conflict: $out"

out="$(run_state conflict-empty '{"schemaVersion":1,"admissionScope":"entry","status":"conflict","reasonCode":"INSPECT_FAILED","agents":[],"bindings":[]}')"
jq -e '(.missing | length) == 0 and .routed and (.result | startswith("mefisto_entry_not_admitted:"))' <<< "$out" >/dev/null \
  && pass 'conflict sin filas: agentes presentes y falla con la causa, no Agent not found' || fail "conflict sin filas: $out"

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"

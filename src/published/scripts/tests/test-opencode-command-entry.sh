#!/usr/bin/env bash
# Prueba el plugin de entrada OpenCode con dobles de SDK, resolver y config.
# Sin runtime, LLM, GitHub, Azure ni red: el resolver es un script falso dentro
# de una release temporal y el cliente SDK un objeto en memoria.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
ADAPTER="$REPO_ROOT/src/published/scripts/adapters/adapter-opencode.sh"
GENERATED="$REPO_ROOT/dist/opencode/plugins/mefisto-command-entry.js"
SOURCE="$REPO_ROOT/src/published/contract/command-entry.json"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

"$ADAPTER" render-asset command-entry-plugin "$SOURCE" > "$WORK/plugin.js" || exit 1
cmp -s "$GENERATED" "$WORK/plugin.js" && pass 'snapshot generado coincide con dist/opencode' || fail 'snapshot del plugin divergente'
"$ADAPTER" assets | jq -e 'any(.[]; .id == "command-entry-plugin" and .destination == "plugins/mefisto-command-entry.js")' >/dev/null && pass 'asset registrado' || fail 'asset no registrado'
grep -Eq 'Authorization|headers|apiKey|provider|Object\.(keys|entries|values)\(process\.env|stringify\(process\.env' "$WORK/plugin.js" && fail 'plugin menciona secretos o providers' || pass 'plugin no serializa secretos ni providers'
count="$(jq '[.commands[].id] | length' "$SOURCE")"
rendered_all=1
for file in "$REPO_ROOT"/src/published/commands/*.md; do
  id="$(basename "$file" .md)"
  grep -q "^agent: \"command-entry-$id\"$" "$REPO_ROOT/dist/opencode/commands/mefisto:$id.md" && grep -q '^subtask: false$' "$REPO_ROOT/dist/opencode/commands/mefisto:$id.md" || rendered_all=0
done
[ "$rendered_all" -eq 1 ] && pass "los $count comandos distribuidos llevan agente tecnico y subtask false" || fail 'comando sin binding de entrada'
! grep -lE '^(agent|capabilities):' "$REPO_ROOT"/src/published/commands/*.md >/dev/null 2>&1 && pass 'Markdown neutral sin agent/capabilities' || fail 'Markdown neutral con agent'

VERSION="$(jq -r .version "$REPO_ROOT/src/published/release-identity.json")"; COMMIT="$(jq -r .commit "$REPO_ROOT/src/published/release-identity.json")"
make_release() {
  local root="$1" version="${2:-$VERSION}"
  mkdir -p "$root/plugins" "$root/scripts" "$root/fake"
  cp "$WORK/plugin.js" "$root/plugins/mefisto-command-entry.js"
  jq -n --arg v "$version" --arg c "$COMMIT" '{schemaVersion:1,runtime:"opencode",version:$v,commit:$c}' > "$root/mefisto-manifest.json"
  cat > "$root/scripts/resolve-opencode-entry.sh" <<'EOF'
#!/usr/bin/env bash
dir="$(cd "$(dirname "$0")/.." && pwd -P)/fake"
phase="$2"
printf '%s\n' "$*" >> "$dir/argv.log"
[ -f "$dir/$phase.json" ] && cat "$dir/$phase.json"
exit 0
EOF
  chmod 0755 "$root/scripts/resolve-opencode-entry.sh"
}
catalog_ids() { jq -r '.commands[].id' "$SOURCE"; }
# Respuestas del resolver: config (admitted false) y command (admitted segun el caso).
projection() { # status reasonCode admitted-for
  jq -n --arg status "$1" --arg reason "$2" --arg admit "$3" --slurpfile m "$SOURCE" '
    {schemaVersion:1,admissionScope:"entry",status:$status,reasonCode:$reason,snapshotDigest:"snap-1",
     agents:([$m[0].commands[].id] | map({key:("command-entry-"+.),value:{description:"entrada tecnica",permission:{"*":"deny",task:{"*":"deny"},read:{"/Users/x/Library/Application Support/mefisto/releases/0.40.2/scripts/*":"allow"}}}}) | from_entries),
     bindings:[$m[0].commands[].id | {command:.,agent:("command-entry-"+.),admitted:(. == $admit)}]}'
}
mkdir -p "$WORK/project"
cat > "$WORK/run.mjs" <<'EOF'
import { pathToFileURL } from "node:url";
import { readFileSync, writeFileSync } from "node:fs";
const [root, project, scenario] = process.argv.slice(2);
const catalog = JSON.parse(readFileSync(process.env.CATALOG, "utf8"));
const fake = root + "/fake";
process.env.FAKE_DIR = fake;
const factory = (await import(pathToFileURL(root + "/plugins/mefisto-command-entry.js").href)).default;
const logs = [];
const session = (permission, directory = project, fails = false) => ({ session: { get: async () => { if (fails) throw new Error("fallo-sdk"); return { data: { id: "s1", directory, ...(permission === undefined ? {} : { permission }) } }; } } });
const mk = (sdk = {}) => factory({ client: { app: { log: async (e) => logs.push(e) }, ...sdk }, directory: project, worktree: project });
const baseConfig = () => ({ default_agent: "build", command: Object.fromEntries(catalog.map((id) => [("mefisto:" + id), { template: "T-" + id, agent: "command-entry-" + id, subtask: false, model: "m-usuario" }])), agent: { ajeno: { mode: "primary" } } });
const attempt = async (hooks, command) => { try { await hooks["command.execute.before"]({ command, sessionID: "s1", arguments: "" }, {}); return "ok"; } catch (e) { return String(e.message); } };
const out = {};
if (scenario === "ready") {
  const cfg = baseConfig(); const before = JSON.stringify(cfg);
  const hooks = await mk(session([]));
  await hooks.config(cfg);
  out.agents = Object.keys(cfg.agent).filter((k) => k.startsWith("command-entry-")).length;
  out.primary = Object.values(cfg.agent).filter((a) => a.mode === "primary").length >= catalog.length;
  out.noModel = !Object.values(cfg.agent).some((a) => "model" in a);
  out.subtask = catalog.every((id) => cfg.command["mefisto:" + id].subtask === false && cfg.command["mefisto:" + id].agent === "command-entry-" + id);
  out.preserved = cfg.default_agent === "build" && cfg.command["mefisto:bitacora"].template === "T-bitacora" && cfg.command["mefisto:bitacora"].model === "m-usuario" && cfg.agent.ajeno.mode === "primary";
  out.grep = cfg.agent["command-entry-sequential"].permission.read["/Users/x/Library/Application Support/mefisto/releases/0.40.2/scripts/*"] === "allow";
  const again = JSON.stringify(cfg); await hooks.config(cfg); out.idempotent = JSON.stringify(cfg) === again && before !== again;
  out.admitted = await attempt(hooks, "mefisto:bitacora");
  out.notOurs = await attempt(hooks, "otro");
  writeFileSync(fake + "/command.json", JSON.stringify({ ...JSON.parse(readFileSync(fake + "/command-denied.json", "utf8")) }));
  out.denied = await attempt(hooks, "mefisto:bitacora");
  const argv = readFileSync(fake + "/argv.log", "utf8");
  out.argv = argv.includes("--phase config") && argv.includes("--phase command") && argv.includes("sessionPolicyKnown");
  out.leak = JSON.stringify(logs).includes("secreto");
}
if (scenario === "session") {
  const cfg = baseConfig();
  const empty = await mk(session([])); await empty.config(cfg);
  const known = readFileSync(fake + "/argv.log", "utf8");
  await attempt(empty, "mefisto:bitacora");
  const unknown = await mk(session(undefined, project, true)); await unknown.config(baseConfig());
  await attempt(unknown, "mefisto:bitacora");
  const other = await mk(session([], "/otro")); await other.config(baseConfig());
  await attempt(other, "mefisto:bitacora");
  const lines = readFileSync(fake + "/argv.log", "utf8").split("\n").filter((l) => l.includes("--phase command"));
  out.emptyKnown = lines[0].includes("\"sessionPolicyKnown\":true") && lines[0].includes("\"sessionPermission\":[]");
  out.failedUnknown = lines[1].includes("\"sessionPolicyKnown\":false") && lines[1].includes("\"sessionProjectMatches\":false");
  out.otherProject = lines[2].includes("\"sessionProjectMatches\":false");
}
if (scenario === "legacy") {
  const cfg = baseConfig(); cfg.command["mefisto:draft"].agent = "agente-usuario";
  const hooks = await mk(session([]));
  await hooks.config(cfg);
  out.restored = !("agent" in cfg.command["mefisto:bitacora"]) && !("subtask" in cfg.command["mefisto:bitacora"]) && cfg.command["mefisto:bitacora"].template === "T-bitacora" && cfg.command["mefisto:bitacora"].model === "m-usuario";
  out.foreignKept = cfg.command["mefisto:draft"].agent === "agente-usuario";
  out.noAgents = !Object.keys(cfg.agent).some((k) => k.startsWith("command-entry-"));
  const once = JSON.stringify(cfg); await hooks.config(cfg); out.idempotent = once === JSON.stringify(cfg);
  out.passes = await attempt(hooks, "mefisto:bitacora");
}
if (scenario === "deny") {
  const cfg = baseConfig(); const before = JSON.stringify(cfg);
  const hooks = await mk(session([]));
  await hooks.config(cfg);
  out.configAfter = JSON.stringify(cfg) === before ? "unchanged" : "changed";
  out.result = await attempt(hooks, "mefisto:sequential");
  out.logged = logs.length > 0;
}
if (scenario === "collision") {
  const cfg = baseConfig(); cfg.agent["command-entry-merge"] = { mode: "primary", permission: { "*": "allow" } };
  const before = JSON.stringify(cfg);
  const hooks = await mk(session([]));
  await hooks.config(cfg);
  out.untouched = JSON.stringify(cfg) === before;
  out.result = await attempt(hooks, "mefisto:merge");
}
if (scenario === "frozen") {
  const hooks = await mk(session([]));
  const deep = (o) => { Object.values(o).forEach((v) => v && typeof v === 'object' && deep(v)); return Object.freeze(o); };
  const frozen = deep(baseConfig()); await hooks.config(frozen);
  out.result = await attempt(hooks, "mefisto:bitacora");
}
if (scenario === "revoke") {
  const cfg = baseConfig(); const hooks = await mk(session([]));
  await hooks.config(cfg);
  writeFileSync(fake + "/config.json", readFileSync(fake + "/config-disabled.json", "utf8"));
  const cfg2 = baseConfig(); await hooks.config(cfg2);
  out.result = await attempt(hooks, "mefisto:bitacora");
  out.same = catalog.every((id) => cfg2.command["mefisto:" + id].agent === "command-entry-" + id);
}
console.log(JSON.stringify(out));
EOF
CATALOG_FILE="$WORK/catalog.json"; jq -c '[.commands[].id]' "$SOURCE" > "$CATALOG_FILE"
run() { CATALOG="$CATALOG_FILE" node "$WORK/run.mjs" "$1" "$WORK/project" "$2" 2>/dev/null; }
check() { # nombre json filtro
  if jq -e "$3" >/dev/null <<< "$2"; then pass "$1"; else fail "$1: $2"; fi
}

R="$WORK/r-ready"; make_release "$R"
projection ready OK none > "$R/fake/config.json"; projection ready OK bitacora > "$R/fake/command.json"; projection ready OK none > "$R/fake/command-denied.json"
out="$(run "$R" ready)"
check 'catalogo completo: un agente tecnico por comando, primarios, sin modelo' "$out" ".agents == $count and .primary and .noModel"
check 'subtask false, default_agent/template/modelo y agentes ajenos preservados' "$out" '.subtask and .preserved'
check 'Grep de la release con ruta macOS con espacios queda en la politica aplicada' "$out" '.grep'
check 'aplicacion idempotente' "$out" '.idempotent'
check 'command: admitted true pasa; comando ajeno se ignora; admitted false rechaza' "$out" '.admitted == "ok" and .notOurs == "ok" and (.denied | startswith("mefisto_entry_not_admitted"))'
check 'resolver por argv con fases config y command sin fugas' "$out" '.argv and (.leak | not)'

jq -n --slurpfile m "$SOURCE" '{}' >/dev/null
R="$WORK/r-session"; make_release "$R"; projection ready OK none > "$R/fake/config.json"; projection ready OK bitacora > "$R/fake/command.json"
out="$(run "$R" session)"
check 'sesion vacia observada vs no consultable vs otro proyecto' "$out" '.emptyKnown and .failedUnknown and .otherProject'

R="$WORK/r-legacy"; make_release "$R"
jq -n '{schemaVersion:1,admissionScope:"entry",status:"disabled",reasonCode:"NO_PROFILE",agents:{},bindings:[]}' > "$R/fake/config.json"
out="$(run "$R" legacy)"
check 'NO_PROFILE restaura solo routing propio, idempotente, conserva overrides' "$out" '.restored and .foreignKept and .noAgents and .idempotent and .passes == "ok"'

R="$WORK/r-revoked"; make_release "$R"
jq -n '{schemaVersion:1,admissionScope:"entry",status:"disabled",reasonCode:"CONSENT_REVOKED",controlledContext:true,agents:{},bindings:[]}' > "$R/fake/config.json"
out="$(run "$R" deny)"
check 'CONSENT_REVOKED no activa fallback legacy y rechaza' "$out" '.result | startswith("mefisto_entry_not_admitted")'

for status in needs-approval conflict; do
  R="$WORK/r-$status"; make_release "$R"; projection "$status" PENDING none > "$R/fake/config.json"; projection "$status" PENDING bitacora > "$R/fake/command.json"
  out="$(run "$R" deny)"
  check "$status instala agentes denegados y no admite" "$out" '.result | startswith("mefisto_entry_not_admitted")'
done

R="$WORK/r-noagent"; make_release "$R"; projection ready OK none | jq 'del(.agents["command-entry-sequential"])' > "$R/fake/config.json"
out="$(run "$R" deny)"
check 'entrada sin agente proyectado falla visible, sin mutar ni heredar' "$out" '.configAfter == "unchanged" and .result == "mefisto_entry_not_admitted:BINDING_INVALID"'

R="$WORK/r-nores"; make_release "$R"; rm "$R/scripts/resolve-opencode-entry.sh"
out="$(run "$R" deny)"
check 'resolver ausente: no admision sin mutar config' "$out" '.configAfter == "unchanged" and (.result | startswith("mefisto_entry_not_admitted:"))'

R="$WORK/r-badjson"; make_release "$R"; printf 'no-json' > "$R/fake/config.json"
out="$(run "$R" deny)"
check 'respuesta invalida del resolver: no admision' "$out" '.configAfter == "unchanged" and (.result | startswith("mefisto_entry_not_admitted:RESOLVER_FAILED"))'

R="$WORK/r-ident"; make_release "$R" "9.9.9"; projection ready OK none > "$R/fake/config.json"
out="$(run "$R" deny)"
check 'modulo A con root/manifiesto B: no admision y config intacta' "$out" '.configAfter == "unchanged" and .result == "mefisto_entry_not_admitted:IDENTITY_MISMATCH"'

R="$WORK/r-collision"; make_release "$R"; projection ready OK none > "$R/fake/config.json"; projection ready OK merge > "$R/fake/command.json"
out="$(run "$R" collision)"
check 'colision de ownership: sin mutacion parcial ni reemplazo, comando rechazado' "$out" '.untouched and .result == "mefisto_entry_not_admitted:COLLISION"'

R="$WORK/r-frozen"; make_release "$R"; projection ready OK none > "$R/fake/config.json"; projection ready OK bitacora > "$R/fake/command.json"
out="$(run "$R" frozen)"
check 'error ignorado del config no depende de la excepcion: guard rechaza' "$out" '.result | startswith("mefisto_entry_not_admitted:")'

R="$WORK/r-revoke"; make_release "$R"; projection ready OK none > "$R/fake/config.json"; projection ready OK bitacora > "$R/fake/command.json"
jq -n '{schemaVersion:1,admissionScope:"entry",status:"disabled",reasonCode:"NO_PROFILE",agents:{},bindings:[]}' > "$R/fake/config-disabled.json"
out="$(run "$R" revoke)"
check 'perfil retirado en instancia activada: sin fallback en caliente' "$out" '.result | startswith("mefisto_entry_not_admitted:")'

mkdir -p "$WORK/harness/src/published/contract" "$WORK/harness/.claude-plugin"; : > "$WORK/harness/src/published/contract/command-entry.json"; : > "$WORK/harness/.claude-plugin/plugin.json"
R="$WORK/r-harness"; make_release "$R"
res="$(CATALOG="$CATALOG_FILE" node --input-type=module -e "
import { pathToFileURL } from 'node:url';
const f = (await import(pathToFileURL('$R/plugins/mefisto-command-entry.js').href)).default;
const h = await f({ client: {}, directory: '$WORK/harness' });
const cfg = { command: {} }; await h.config(cfg);
console.log(JSON.stringify([JSON.stringify(cfg) === '{\"command\":{}}', await h['command.execute.before']({ command: 'mefisto:bitacora' }) === undefined]));")"
[ "$res" = '[true,true]' ] && pass 'repo del harness: plugin no-op' || fail "guard de harness: $res"

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"

#!/usr/bin/env bash
# Prueba el binding OpenCode (#1847): alias, guard chat.params, Task, handshake,
# pin por llamada y prefijo attach, con dobles de SDK, resolver y broker de
# contexto. Sin runtime, LLM ni red.
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
check() { if jq -e "$3" >/dev/null 2>&1 <<< "$2"; then pass "$1"; else fail "$1: $2"; fi; }

"$ADAPTER" render-asset command-entry-plugin "$SOURCE" > "$WORK/plugin.js" || exit 1
VERSION="$(jq -r .version "$REPO_ROOT/src/published/release-identity.json")"; COMMIT="$(jq -r .commit "$REPO_ROOT/src/published/release-identity.json")"
DIGEST="$(printf 'contrato' | shasum -a 256 | cut -d ' ' -f 1)"

make_release() { # root [image]
  local root="$1" image="${2:-img1}"
  mkdir -p "$root/plugins" "$root/scripts" "$root/fake" "$root/ctx"
  cp "$WORK/plugin.js" "$root/plugins/mefisto-command-entry.js"
  jq -n --arg v "$VERSION" --arg c "$COMMIT" '{schemaVersion:1,runtime:"opencode",version:$v,commit:$c}' > "$root/mefisto-manifest.json"
  cat > "$root/scripts/resolve-opencode-entry.sh" <<'EOF'
#!/usr/bin/env bash
dir="$(cd "$(dirname "$0")/.." && pwd -P)/fake"
[ -f "$dir/$2.json" ] && cat "$dir/$2.json"
exit 0
EOF
  cat > "$root/scripts/execution-context.sh" <<'EOF'
#!/usr/bin/env bash
dir="$(cd "$(dirname "$0")/.." && pwd -P)/fake"
printf '%s %s\n' "$1" "$(cat | tr -d '\n')" >> "$dir/ctx.log"
if [ -f "$dir/op-$1.json" ]; then cat "$dir/op-$1.json"; else printf '{"schemaVersion":1,"status":"ready","reasonCode":"OK","digest":"%s"}\n' "$(cat "$dir/digest")"; fi
exit 0
EOF
  chmod 0755 "$root/scripts/resolve-opencode-entry.sh" "$root/scripts/execution-context.sh"
  printf '%s' "$DIGEST" > "$root/fake/digest"
  jq -n --arg d "$DIGEST" --arg v "$VERSION" '{contractDigest:$d,contract:{release:$v,alias:"autonomy-reviewer",originalAgent:"reviewer",nonce:"nonce-1",projectId:"proj-1"}}' > "$root/ctx/ctx1.json"
  jq -n --arg p "$root/ctx/ctx1.json" '{schemaVersion:1,status:"ready",reasonCode:"VALID",path:$p}' > "$root/fake/op-validate.json"
  jq -n --arg i "$image" --slurpfile m "$SOURCE" '
    {schemaVersion:1,admissionScope:"entry",status:"ready",reasonCode:"OK",snapshotDigest:"snap-1",permissionImageDigest:$i,resourcesDigest:"res-1",
     agents:([$m[0].commands[].id] | map({key:("command-entry-"+.),value:{description:"entrada",permission:{"*":"deny"}}}) | from_entries),
     roleAliases:[{original:"reviewer",alias:"autonomy-reviewer",permission:{"*":"deny",read:{"/x/*":"allow"}}}],
     bindings:[$m[0].commands[].id | {command:., agent:("command-entry-"+.), admitted:false}]}' > "$root/fake/config.json"
}
mkdir -p "$WORK/project"
cat > "$WORK/run.mjs" <<'EOF'
import { pathToFileURL } from "node:url";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
const [root, project, scenario] = process.argv.slice(2);
const catalog = JSON.parse(readFileSync(process.env.CATALOG, "utf8"));
const fake = root + "/fake";
const sessions = { s1: { id: "s1", directory: project }, c1: { id: "c1", directory: project, parentID: "s1" }, x1: { id: "x1", directory: project, parentID: "otro" } };
const client = { app: { log: async () => {} }, session: { get: async ({ path }) => (sessions[path.id] ? { data: sessions[path.id] } : { error: "no" }) } };
const baseConfig = () => ({ command: Object.fromEntries(catalog.map((id) => ["mefisto:" + id, { template: "T", agent: "command-entry-" + id, subtask: false }])), agent: { reviewer: { mode: "subagent", model: "m-1", permission: { "*": "allow" } } } });
const hooks = await (await import(pathToFileURL(root + "/plugins/mefisto-command-entry.js").href)).default({ client, directory: project, worktree: project });
const cfg = baseConfig(); const original = JSON.stringify(cfg.agent.reviewer);
await hooks.config(cfg);
const tryHook = async (name, ...a) => { try { await hooks[name](...a); return "ok"; } catch (e) { return String(e.message); } };
const out = {};
const readyFile = root + "/ctx/ctx1/runtime-ready.json";
if (scenario === "ready") {
  const al = cfg.agent["autonomy-reviewer"];
  out.alias = !!al && al.hidden === true && al.mode === "all" && al.model === "m-1" && al.permission.read["/x/*"] === "allow";
  out.original = JSON.stringify(cfg.agent.reviewer) === original;
  out.noEnvelope = !Object.keys(cfg.agent).some((k) => k === "autonomy-envelope");
  const ready = existsSync(readyFile) ? readFileSync(readyFile, "utf8") : "";
  const parsed = ready ? JSON.parse(ready) : {};
  out.ready = parsed.schemaVersion === 1 && parsed.nonce === "nonce-1" && parsed.alias === "autonomy-reviewer" && parsed.result === "ready" && parsed.projectId === "proj-1" && !/model|prompt|secret|token/i.test(ready);
  out.defaultFallback = await tryHook("chat.params", { sessionID: "s1", agent: "build" }, {});
  out.noAgent = await tryHook("chat.params", { sessionID: "s1" }, {});
  out.noSession = await tryHook("chat.params", { sessionID: "ghost", agent: "autonomy-reviewer" }, {});
  out.good = await tryHook("chat.params", { sessionID: "s1", agent: "autonomy-reviewer" }, {});
  out.noCoverage = await tryHook("chat.params", { sessionID: "s1", agent: "reviewer" }, {});
  const env = { OPENCODE_SERVER_PASSWORD: "x", PATH: "/bin" }; await hooks["shell.env"]({}, { env });
  out.pin = env.MEFISTO_LOADED_RELEASE_ROOT === root.replace(/^\/private/, "") || env.MEFISTO_LOADED_RELEASE_ROOT.endsWith(root.split("/").pop());
  out.envCtx = env.MEFISTO_EXECUTION_CONTEXT === "run1:ctx1" && env.MEFISTO_EXECUTION_DIGEST === process.env.MEFISTO_EXECUTION_DIGEST;
  out.noSecret = !("OPENCODE_SERVER_PASSWORD" in env);
  const bash = { args: { command: "dotnet test --filter 'a b' $(echo hi)" } };
  const r1 = await tryHook("tool.execute.before", { tool: "bash", sessionID: "s1", callID: "call_1" }, bash);
  out.prefix = r1 === "ok" && bash.args.command.includes("attach --owner-pid \"$$\"") && bash.args.command.endsWith("\ndotnet test --filter 'a b' $(echo hi)") && bash.args.command.includes(">/dev/null || exit 1");
  const task = { args: { subagent_type: "reviewer", prompt: "p" } };
  out.taskOk = (await tryHook("tool.execute.before", { tool: "task", sessionID: "s1" }, task)) === "ok" && task.args.subagent_type === "autonomy-reviewer";
  out.taskBg = await tryHook("tool.execute.before", { tool: "task", sessionID: "s1" }, { args: { subagent_type: "reviewer", background: true } });
  out.taskUnknown = await tryHook("tool.execute.before", { tool: "task", sessionID: "s1" }, { args: { subagent_type: "planner" } });
  out.taskForeign = await tryHook("tool.execute.before", { tool: "task", sessionID: "s1" }, { args: { subagent_type: "reviewer", task_id: "x1" } });
  out.childUnknownParent = await tryHook("chat.message", { sessionID: "x1", agent: "autonomy-reviewer" });
  out.childOk = await tryHook("chat.message", { sessionID: "c1", agent: "autonomy-reviewer" });
  out.childParams = await tryHook("chat.params", { sessionID: "c1", agent: "autonomy-reviewer" }, {});
  out.childWrong = await tryHook("chat.params", { sessionID: "c1", agent: "build" }, {});
}
if (scenario === "failed") {
  out.ready = existsSync(readyFile);
  out.params = await tryHook("chat.params", { sessionID: "s1", agent: "autonomy-reviewer" }, {});
  const env = {}; await hooks["shell.env"]({}, { env });
  out.noPin = !("MEFISTO_LOADED_RELEASE_ROOT" in env) && "MEFISTO_EXECUTION_CONTEXT" in env;
  out.bash = await tryHook("tool.execute.before", { tool: "bash", sessionID: "s1", callID: "c" }, { args: { command: "ls" } });
}
if (scenario === "reserve") {
  const bash = { args: { command: "ls" } };
  out.bash = await tryHook("tool.execute.before", { tool: "bash", sessionID: "s1", callID: "call_9" }, bash);
  out.untouched = bash.args.command === "ls";
}
if (scenario === "image") {
  await hooks["chat.params"]({ sessionID: "s1", agent: "autonomy-reviewer" }, {});
  writeFileSync(fake + "/config.json", readFileSync(fake + "/config-same.json", "utf8"));
  out.same = await tryHook("chat.params", { sessionID: "s1", agent: "autonomy-reviewer" }, {});
  writeFileSync(fake + "/config.json", readFileSync(fake + "/config-new.json", "utf8"));
  out.changed = await tryHook("chat.params", { sessionID: "s1", agent: "autonomy-reviewer" }, {});
  out.log = existsSync(fake + "/ctx.log") ? readFileSync(fake + "/ctx.log", "utf8") : "";
}
if (scenario === "admission") {
  out.entry = await tryHook("command.execute.before", { command: "mefisto:bitacora", sessionID: "s1", arguments: "" }, {});
  out.log = readFileSync(fake + "/ctx.log", "utf8");
}
console.log(JSON.stringify(out));
EOF
CATALOG_FILE="$WORK/catalog.json"; jq -c '[.commands[].id]' "$SOURCE" > "$CATALOG_FILE"
run() { MEFISTO_EXECUTION_CONTEXT="run1:ctx1" MEFISTO_EXECUTION_DIGEST="$DIGEST" CATALOG="$CATALOG_FILE" node "$WORK/run.mjs" "$1" "$WORK/project" "$2" 2>/dev/null; }

R="$WORK/r-ready"; make_release "$R"
out="$(run "$R" ready)"
check 'config aplica alias oculto mode all clonado en memoria, original intacto, sin agente envolvente' "$out" '.alias and .original and .noEnvelope'
check 'handshake runtime-ready.json versionado con nonce/alias/proyecto y sin secretos, modelos ni prompts' "$out" '.ready'
check 'chat.params rechaza fallback a default, sin agente, sesion no observada y original sin alias' "$out" '(.defaultFallback|startswith("mefisto_entry_not_admitted:ACTOR_MISMATCH")) and (.noAgent|startswith("mefisto_entry_not_admitted:ACTOR_MISMATCH")) and (.noSession|endswith("SESSION_UNOBSERVED")) and (.noCoverage|endswith("ACTOR_MISMATCH")) and .good == "ok"'
check 'shell.env inyecta pin y contexto, y retira el secreto del servidor' "$out" '.pin and .envCtx and .noSecret'
check 'prefijo attach preserva el comando original integro y falla sin cuerpo' "$out" '.prefix'
check 'Task: original -> alias, background, destino desconocido y resume ajeno rechazados' "$out" '.taskOk and (.taskBg|endswith("BACKGROUND_UNSUPPORTED")) and (.taskUnknown|endswith("TASK_TARGET_UNKNOWN")) and (.taskForeign|endswith("TASK_RESUME_FOREIGN"))'
check 'hijo: ancestry desconocida rechazada, hijo de sesion conocida se une y exige su alias' "$out" '(.childUnknownParent|endswith("ANCESTRY_UNKNOWN")) and .childOk == "ok" and .childParams == "ok" and (.childWrong|endswith("ACTOR_MISMATCH"))'

R="$WORK/r-failed"; make_release "$R"; printf 'no-json' > "$R/fake/config.json"
out="$(run "$R" failed)"
check 'config fallido: sin ready, guard cerrado, sin pin y sin Bash' "$out" '(.ready|not) and (.params|startswith("mefisto_entry_not_admitted:")) and .noPin and (.bash|startswith("mefisto_entry_not_admitted:"))'

R="$WORK/r-reserve"; make_release "$R"
jq -n '{schemaVersion:1,status:"conflict",reasonCode:"PARENT_NOT_LIVE"}' > "$R/fake/op-reserve-child.json"
out="$(run "$R" reserve)"
check 'reserva fallida: el comando no se ejecuta ni se muta' "$out" '(.bash|endswith("PARENT_NOT_LIVE")) and .untouched'

R="$WORK/r-image"; make_release "$R"
jq '.snapshotDigest="snap-2"' "$R/fake/config.json" > "$R/fake/config-same.json"
jq '.snapshotDigest="snap-3" | .permissionImageDigest="img9"' "$R/fake/config.json" > "$R/fake/config-new.json"
out="$(run "$R" image)"
check 'misma imagen con assets nuevos refresca evidencia; imagen distinta exige nueva admision' "$out" '.same == "ok" and (.changed|endswith("READMISSION_REQUIRED")) and (.log|contains("refresh-observations"))'

R="$WORK/r-admission"; make_release "$R"; jq '.bindings |= map(if .command=="bitacora" then .admitted=true else . end)' "$R/fake/config.json" > "$R/fake/command.json"
out="$(run "$R" admission)"
check 'entrada registra entryAdmission sanitizado tras bind-session' "$out" '.entry == "ok" and (.log|contains("bind-session")) and (.log|contains("record-entry-admission")) and (.log|contains("\"policyResult\":\"allowed\""))'
R="$WORK/r-admission2"; make_release "$R"; jq '.bindings |= map(if .command=="bitacora" then .admitted=true else . end)' "$R/fake/config.json" > "$R/fake/command.json"
jq -n '{schemaVersion:1,status:"conflict",reasonCode:"ENTRY_ADMISSION_UNAUTHORIZED"}' > "$R/fake/op-record-entry-admission.json"
out="$(run "$R" admission)"
check 'registro de admision fallido: la entrada no se admite' "$out" '.entry|endswith("ADMISSION_NOT_RECORDED")'

# Preambulo pin-aware: con contexto aborta sin pin y nunca elige active; sin contexto conserva el camino legacy.
PRE="$(awk '/^```bash$/{i=1;next} /^```$/{if(i)exit} i' "$REPO_ROOT/dist/opencode/commands/mefisto:bitacora.md")"
if [ -n "$PRE" ]; then
  mkdir -p "$WORK/pin"; jq -n '{}' > "$WORK/pin/mefisto-manifest.json"
  (MEFISTO_EXECUTION_CONTEXT=run1:ctx1 bash -c "$PRE" >/dev/null 2>&1) && fail 'contexto sin pin debio abortar' || pass 'contexto sin pin aborta sin elegir active'
  (MEFISTO_EXECUTION_CONTEXT=run1:ctx1 MEFISTO_LOADED_RELEASE_ROOT="$WORK/pin" bash -c "$PRE"' ; [ "$MEFISTO_PACKAGE_ROOT" = "'"$(cd "$WORK/pin" && pwd -P)"'" ]' >/dev/null 2>&1) && pass 'contexto con pin valido usa la release pineada' || fail 'pin valido no se uso'
  (MEFISTO_EXECUTION_CONTEXT=run1:ctx1 MEFISTO_LOADED_RELEASE_ROOT="$WORK/inexistente" bash -c "$PRE" >/dev/null 2>&1) && fail 'pin invalido debio abortar' || pass 'pin invalido aborta'
else
  fail 'no se pudo extraer el preambulo OpenCode'
fi

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"

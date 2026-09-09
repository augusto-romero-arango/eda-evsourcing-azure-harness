#!/usr/bin/env bash
# Verifica el plugin OpenCode generado sin runtime ni red mediante Node local.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd -P)"
GENERATOR="$REPO_ROOT/src/published/scripts/generate-published-adapters.sh"
PLUGIN="$REPO_ROOT/dist/opencode/plugins/mefisto-observability.js"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

printf '%s\n' '[generacion] contrato, inventario y snapshot'
bash -n "$REPO_ROOT/src/published/scripts/adapters/adapter-opencode.sh" && pass 'adaptador Bash valido' || fail 'adaptador Bash invalido'
bash "$GENERATOR" --check >/dev/null && pass 'salida OpenCode vigente' || fail 'salida OpenCode divergente'
[ -f "$PLUGIN" ] && grep -q 'interactive-hooks.json' "$PLUGIN" && pass 'plugin generado atribuye el contrato neutral' || fail 'plugin generado ausente o sin atribucion'
jq -e '[.assets[] | select(.id == "interactive-observability" and .source == "src/published/hooks/interactive-hooks.json" and .destination == "plugins/mefisto-observability.js")] | length == 1' "$REPO_ROOT/dist/opencode/.mefisto-generated-assets.json" >/dev/null && pass 'inventario atribuye el asset' || fail 'inventario no atribuye el asset'
[ ! -e "$REPO_ROOT/dist/opencode/mefisto-manifest.json" ] && pass 'el manifiesto sigue perteneciendo al packager' || fail 'el adaptador usurpo el manifiesto del packager'

printf '%s\n' '[API 1.18.29] callbacks y campos fijados'
TYPES="$REPO_ROOT/.opencode/node_modules/@opencode-ai/plugin/dist/index.d.ts"
jq -e '.dependencies["@opencode-ai/plugin"] == "1.18.29"' "$REPO_ROOT/.opencode/package.json" >/dev/null &&
  grep -q '"chat.params".*(input' "$TYPES" && grep -q 'model: Model;' "$TYPES" &&
  grep -q '"tool.execute.after".*(input' "$TYPES" && grep -q 'metadata: any;' "$TYPES" &&
  pass 'prueba anclada a tipos locales de plugin 1.18.29' || fail 'tipos OpenCode fijados divergieron'

printf '%s\n' '[runtime] sesiones, herramientas y degradacion segura'
mkdir -p "$WORK/runtime/plugins" "$WORK/runtime-malformed/plugins" "$WORK/runtime-missing/plugins"
cp "$PLUGIN" "$WORK/runtime/plugins/mefisto-observability.mjs"
cp "$PLUGIN" "$WORK/runtime-malformed/plugins/mefisto-observability.mjs"
cp "$PLUGIN" "$WORK/runtime-missing/plugins/mefisto-observability.mjs"
jq -c '. + {runtime:"opencode",minimumRuntimeVersion:"1.18.29"}' "$REPO_ROOT/src/published/release-identity.json" > "$WORK/runtime/mefisto-manifest.json"
printf '%s\n' '{"schemaVersion":1,"runtime":"opencode","version":"SENTINELA-MANIFEST","commit":"invalido"}' > "$WORK/runtime-malformed/mefisto-manifest.json"
cat > "$WORK/probe.mjs" <<'EOF'
import fs from "node:fs/promises";
import path from "node:path";
import plugin from "./runtime/plugins/mefisto-observability.mjs";
import malformedPlugin from "./runtime-malformed/plugins/mefisto-observability.mjs";
import missingPlugin from "./runtime-missing/plugins/mefisto-observability.mjs";
const root = process.argv[2];
const logs = [];
const client = { app: { log: async (value) => logs.push(value) } };
const hooks = await plugin({ worktree: "", directory: root, client });
await hooks.event({ event: { type: "project.updated", properties: { value: "SENTINELA-EVENTO" } } });
await hooks.event({ event: { type: "session.created", properties: { info: { id: "s" } } } });
await Promise.all([
  hooks["chat.params"]({ sessionID: "s", model: { providerID: "azure", id: "a" } }, {}),
  hooks["chat.params"]({ sessionID: "s", model: { providerID: "azure", id: "a" } }, {}),
]);
await hooks["chat.params"]({ sessionID: "s", model: { providerID: "azure", id: "b" } });
await hooks["chat.params"]({ sessionID: "s", model: { providerID: "SENTINELA/MODELO", id: "x" } });
await hooks["tool.execute.after"]({ tool: "write", args: { filePath: "src/con espacios.cs", content: "SENTINELA-CONTENIDO" } }, {});
await hooks["tool.execute.after"]({ tool: "edit", args: { content: "SENTINELA-SIN-PATH" } }, {});
await hooks["tool.execute.after"]({ tool: "bash", args: { command: "dotnet test --logger SENTINELA" } }, { title: "", output: "SENTINELA-OUTPUT", metadata: { exitCode: 0 } });
await hooks["tool.execute.after"]({ tool: "bash", args: { command: "dotnet test SENTINELA" } }, { title: "", output: "", metadata: { exitCode: 1 } });
await hooks["tool.execute.after"]({ tool: "shell", args: { command: "terraform apply -var SENTINELA" } }, { title: "", output: "SENTINELA-OUTPUT", metadata: { exitCode: 1 } });
await hooks["tool.execute.after"]({ tool: "shell", args: { command: "terraform plan SENTINELA" } }, { title: "", output: "", metadata: { exitCode: 0 } });
await hooks["tool.execute.after"]({ tool: "bash", args: { command: "terraform validate SENTINELA" } }, { title: "", output: "", metadata: {} });
await hooks["tool.execute.after"]({ tool: "bash", args: { command: "echo SENTINELA" } }, { exitCode: 0 });
await hooks["tool.execute.after"]({ tool: "bash", args: { command: "echo dotnet test SENTINELA" } }, { metadata: { exitCode: 0 } });
await hooks.event({ event: { type: "session.created", properties: {} } });

const degradedRoot = `${root}-manifest-degradado`;
await fs.mkdir(degradedRoot);
const degraded = await malformedPlugin({ directory: degradedRoot, worktree: degradedRoot, client });
await degraded.event({ event: { type: "session.created", properties: { info: { id: "degraded" } } } });

const missingRoot = `${root}-manifest-ausente`;
await fs.mkdir(missingRoot);
const missing = await missingPlugin({ directory: missingRoot, worktree: missingRoot, client });
await missing.event({ event: { type: "session.created", properties: { info: { id: "missing" } } } });

const blockedRoot = `${root}-estado-bloqueado`;
await fs.mkdir(blockedRoot);
await fs.writeFile(path.join(blockedRoot, ".mefisto"), "bloqueo");
const blocked = await plugin({ directory: blockedRoot, worktree: blockedRoot, client });
await blocked.event({ event: { type: "session.created", properties: { info: { id: "blocked" } } } });

const throwing = await malformedPlugin({ directory: "relative", worktree: "", client: { app: { log: async () => { throw new Error("SENTINELA-LOG"); } } } });
await throwing.event({ event: { type: "session.created", properties: {} } });

console.log(JSON.stringify({
  sessions: await fs.readFile(path.join(root, ".mefisto/pipeline/sessions.jsonl"), "utf8"),
  events: await fs.readFile(path.join(root, ".mefisto/pipeline/events.log"), "utf8"),
  pluginRoot: await fs.readFile(path.join(root, ".mefisto/pipeline/.plugin-root"), "utf8"),
  degraded: await fs.readFile(path.join(degradedRoot, ".mefisto/pipeline/sessions.jsonl"), "utf8"),
  missing: await fs.readFile(path.join(missingRoot, ".mefisto/pipeline/sessions.jsonl"), "utf8"),
  logs,
}));
EOF
ROOT="$WORK/repo sin git y con espacios"; mkdir -p "$ROOT"
result="$(node "$WORK/probe.mjs" "$ROOT")"; rc=$?
[ "$rc" -eq 0 ] && pass 'callbacks toleran repo no Git y paths con espacios' || fail 'callbacks fallaron'
jq -e '.sessions | split("\n") | map(select(length > 0) | fromjson) | length == 3 and .[0] == {record_type:"session.started",session_id:"s",transcript_path:null,cwd:$root,source:null,timestamp:.[0].timestamp,runtime:"opencode",model:null,harness_version:.[0].harness_version,harness_commit:.[0].harness_commit} and [.[].model] == [null,"azure/a","azure/b"] and all(.[].timestamp; test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' --arg root "$ROOT" <<< "$result" >/dev/null && pass 'inicio null y modelos concurrente/repetido/cambiado respetan la allowlist' || fail 'sesiones o deduplicacion invalidas'
jq -e '.events | split("\n") | map(select(length > 0) | fromjson) | length == 7 and .[0].file_path == "src/con espacios.cs" and .[1].file_path == "(desconocido)" and .[2].result == "PASS" and .[3].result == "FAIL" and .[4] == {time:.[4].time,family:"terraform",terraform_subcommand:"apply",result:"ERROR"} and .[5].terraform_subcommand == "plan" and .[5].result == "OK" and .[6].terraform_subcommand == "validate" and .[6].result == "ERROR"' <<< "$result" >/dev/null && pass 'herramientas resumen success/error y defaults seguros sin comando/output' || fail 'resumen de herramientas invalido'
EXPECTED_RUNTIME="$(cd "$WORK/runtime" && pwd -P)"
jq -e '.pluginRoot == $expected' --arg expected "$EXPECTED_RUNTIME" <<< "$result" >/dev/null && [ ! -e "$ROOT/.claude" ] && pass 'plugin-root identifica la release cargada sin mirror legacy' || fail 'identidad de release activa incorrecta'
jq -e 'all(.degraded,.missing; split("\n") | map(select(length > 0) | fromjson) | .[0].harness_version == null and .[0].harness_commit == null)' <<< "$result" >/dev/null && pass 'manifiesto ausente o malformado degrada identidad a null' || fail 'manifiesto degradado invento identidad'
case "$result" in *SENTINELA*) fail 'no persiste centinelas sensibles' ;; *) pass 'no persiste centinelas sensibles' ;; esac
jq -e '([.logs[].body.message | select(contains("plan.completed no soportado"))] | length) == 4 and ([.logs[].body.message | select(contains("manifiesto de release"))] | length) == 2 and ([.logs[].body.message | select(contains("payload de session.created"))] | length) == 1 and ([.logs[].body.message | select(contains("payload de chat.params"))] | length) == 1 and ([.logs[].body.message | select(contains("inicio de sesion"))] | length) == 1' <<< "$result" >/dev/null && pass 'reporta una vez por instancia plan y degradaciones sin propagar fallos' || fail 'diagnosticos de degradacion invalidos'

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"

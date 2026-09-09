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

printf '%s\n' '[runtime] sesiones, herramientas y degradacion segura'
mkdir -p "$WORK/runtime/plugins"
cp "$PLUGIN" "$WORK/runtime/plugins/mefisto-observability.mjs"
cp "$REPO_ROOT/dist/opencode/mefisto-manifest.json" "$WORK/runtime/mefisto-manifest.json"
cat > "$WORK/probe.mjs" <<'EOF'
import fs from "node:fs/promises";
import path from "node:path";
import plugin from "./runtime/plugins/mefisto-observability.mjs";
const root = process.argv[2];
const logs = [];
const hooks = await plugin({ directory: root, client: { app: { log: async (value) => logs.push(value) } } });
await hooks.event({ event: { type: "session.created", properties: { info: { id: "s" } } } });
await hooks["chat.params"]({ sessionID: "s", model: { providerID: "azure", id: "a" } });
await hooks["chat.params"]({ sessionID: "s", model: { providerID: "azure", id: "a" } });
await hooks["chat.params"]({ sessionID: "s", model: { providerID: "azure", id: "b" } });
await hooks["chat.params"]({ sessionID: "s", model: { id: "SENTINELA-MODELO" } });
await hooks["tool.execute.after"]({ tool: "write", args: { filePath: "src/con espacios.cs", content: "SENTINELA-CONTENIDO" } }, {});
await hooks["tool.execute.after"]({ tool: "bash", args: { command: "dotnet test --logger SENTINELA" } }, { exitCode: 0 });
await hooks["tool.execute.after"]({ tool: "shell", args: { command: "terraform apply -var SENTINELA" } }, { exitCode: 1 });
await hooks["tool.execute.after"]({ tool: "bash", args: { command: "echo SENTINELA" } }, { exitCode: 0 });
console.log(JSON.stringify({ sessions: await fs.readFile(path.join(root, ".mefisto/pipeline/sessions.jsonl"), "utf8"), events: await fs.readFile(path.join(root, ".mefisto/pipeline/events.log"), "utf8"), logs }));
EOF
ROOT="$WORK/repo sin git y con espacios"; mkdir -p "$ROOT"
result="$(node "$WORK/probe.mjs" "$ROOT")"; rc=$?
[ "$rc" -eq 0 ] && pass 'callbacks toleran repo no Git y paths con espacios' || fail 'callbacks fallaron'
jq -e '.sessions | split("\n") | map(select(length > 0) | fromjson) | length == 3 and .[0] == {record_type:"session.started",session_id:"s",transcript_path:null,cwd:$root,source:null,timestamp:.[0].timestamp,runtime:"opencode",model:null,harness_version:.[0].harness_version,harness_commit:.[0].harness_commit} and [.[].model] == [null,"azure/a","azure/b"]' --arg root "$ROOT" <<< "$result" >/dev/null && pass 'inicio null y modelos inicial, repetido y cambiado respetan la allowlist' || fail 'sesiones o deduplicacion invalidas'
jq -e '.events | split("\n") | map(select(length > 0) | fromjson) | length == 3 and .[0].file_path == "src/con espacios.cs" and .[1].result == "PASS" and .[2] == {time:.[2].time,family:"terraform",terraform_subcommand:"apply",result:"ERROR"}' <<< "$result" >/dev/null && pass 'herramientas coincidentes resumen success/error sin comando' || fail 'resumen de herramientas invalido'
case "$result" in *SENTINELA*) fail 'no persiste centinelas sensibles' ;; *) pass 'no persiste centinelas sensibles' ;; esac
jq -e '(.logs | length == 1) and (.logs[0].body.message | contains("plan.completed no soportado"))' <<< "$result" >/dev/null && pass 'reporta una degradacion de plan sin persistirla' || fail 'degradacion de plan invalida'

printf 'RESULTADO: %s pasaron, %s fallaron\n' "$PASS" "$FAIL"
exit "$FAIL"

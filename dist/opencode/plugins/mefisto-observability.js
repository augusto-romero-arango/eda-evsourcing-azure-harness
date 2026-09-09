// GENERADO por src/published/scripts/adapters/adapter-opencode.sh desde src/published/hooks/interactive-hooks.json. No editar a mano.
import { appendFile, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const rootOf = (context) => typeof context.worktree === "string" ? context.worktree : context.directory;
const now = () => new Date().toISOString();
const clock = () => new Date().toISOString().slice(11, 19);
const safe = async (work) => { try { await work(); } catch { /* failure: continue */ } };
const pipeline = (root) => root && path.join(root, ".mefisto", "pipeline");
const identity = async (client) => {
  try {
    const manifest = JSON.parse(await readFile(path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "mefisto-manifest.json"), "utf8"));
    return manifest && manifest.schemaVersion === 1 && manifest.runtime === "opencode" && typeof manifest.version === "string" && typeof manifest.commit === "string" ? manifest : { version: null, commit: null };
  } catch { await diagnostic(client, "Mefisto: manifiesto de release no disponible."); return { version: null, commit: null }; }
};
const append = async (root, file, line) => { const state = pipeline(root); if (!state) return; await mkdir(state, { recursive: true }); await appendFile(path.join(state, file), `${JSON.stringify(line)}\n`, "utf8"); };
const observed = async (root, sessionID, model) => {
  try { const text = await readFile(path.join(pipeline(root), "sessions.jsonl"), "utf8"); return text.split("\n").some((line) => { try { const value = JSON.parse(line); return value.record_type === "session.model-observed" && value.session_id === sessionID && value.model === model; } catch { return false; } }); } catch { return false; }
};
const diagnostic = async (client, message) => safe(async () => { await client?.app?.log?.({ body: { service: "mefisto", level: "warn", message } }); });
const sessionID = (input) => input?.sessionID ?? input?.sessionId ?? input?.properties?.info?.id ?? input?.properties?.session?.id;
const toolName = (input) => String(input?.tool ?? input?.toolName ?? "").toLowerCase();
const args = (input) => input?.args && typeof input.args === "object" ? input.args : {};
const exitCode = (output) => output?.exitCode ?? output?.metadata?.exitCode ?? output?.metadata?.status;

export default async function mefistoObservability(context) {
  const root = rootOf(context);
  const release = await identity(context.client);
  let planReported = false;
  const planUnsupported = async () => { if (!planReported) { planReported = true; await diagnostic(context.client, "Mefisto: plan.completed no soportado por OpenCode."); } };
  await planUnsupported();
  return {
    event: async ({ event } = {}) => safe(async () => {
      if (event?.type !== "session.created") return;
      const id = sessionID(event); if (typeof id !== "string" || !root) return;
      const state = pipeline(root); await mkdir(state, { recursive: true });
       await writeFile(path.join(state, ".plugin-root"), path.dirname(path.dirname(fileURLToPath(import.meta.url))), "utf8");
      await append(root, "sessions.jsonl", { record_type: "session.started", session_id: id, transcript_path: null, cwd: root, source: null, timestamp: now(), runtime: "opencode", model: null, harness_version: release.version, harness_commit: release.commit });
    }),
    "chat.params": async (input) => safe(async () => {
      const id = sessionID(input); const model = input?.model;
      if (!root || typeof id !== "string" || !model || typeof model.id !== "string" || !model.id || typeof model.providerID !== "string" || !model.providerID) return;
      const value = `${model.providerID}/${model.id}`; if (await observed(root, id, value)) return;
      await append(root, "sessions.jsonl", { record_type: "session.model-observed", session_id: id, timestamp: now(), runtime: "opencode", model: value, harness_version: release.version, harness_commit: release.commit });
    }),
    "tool.execute.after": async (input, output) => safe(async () => {
      if (!root) return; const tool = toolName(input); const inputArgs = args(input);
      if (["write", "edit", "patch"].includes(tool)) { const file = inputArgs.filePath ?? inputArgs.file_path ?? inputArgs.path ?? "(desconocido)"; if (typeof file === "string") await append(root, "events.log", { time: clock(), family: "archivo", file_path: file }); return; }
      if (!["bash", "shell"].includes(tool)) return;
      const command = typeof inputArgs.command === "string" ? inputArgs.command : "";
      if (/(^|\s)dotnet\s+test(\s|$)/.test(command)) { await append(root, "events.log", { time: clock(), family: "test", result: exitCode(output) === 0 ? "PASS" : "FAIL" }); return; }
      const match = /(^|\s)terraform\s+(plan|apply|init|validate)(\s|$)/.exec(command);
      if (match) await append(root, "events.log", { time: clock(), family: "terraform", terraform_subcommand: match[2], result: exitCode(output) === 0 ? "OK" : "ERROR" });
    }),
  };
}

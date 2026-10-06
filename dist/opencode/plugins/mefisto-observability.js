// GENERADO por src/published/scripts/adapters/adapter-opencode.sh desde src/published/hooks/interactive-hooks.json. No editar a mano.
import { appendFile, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const rootOf = (context) => {
  const candidate = [context?.worktree, context?.directory].find((value) => typeof value === "string" && value.length > 0);
  return candidate && path.isAbsolute(candidate) ? candidate : null;
};
const now = () => new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
const clock = () => new Date().toISOString().slice(11, 19);
const pipeline = (root) => root && path.join(root, ".mefisto", "pipeline");
const diagnostic = async (client, message) => { try { await client?.app?.log?.({ body: { service: "mefisto", level: "warn", message } }); } catch { /* failure: continue */ } };
const safe = async (client, failure, work) => { try { await work(); } catch { await diagnostic(client, failure); } };
const releaseRoot = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const identity = async (client) => {
  try {
    const manifest = JSON.parse(await readFile(path.join(releaseRoot, "mefisto-manifest.json"), "utf8"));
    const semver = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;
    if (manifest?.schemaVersion === 1 && manifest.runtime === "opencode" && semver.test(manifest.version) && /^[0-9a-f]{40}$/.test(manifest.commit)) return manifest;
  } catch { /* diagnosticado abajo */ }
  await diagnostic(client, "Mefisto: manifiesto de release ausente o malformado.");
  return { version: null, commit: null };
};
const append = async (root, file, line) => { const state = pipeline(root); if (!state) return; await mkdir(state, { recursive: true }); await appendFile(path.join(state, file), `${JSON.stringify(line)}\n`, "utf8"); };
const sessionID = (input) => input?.sessionID ?? input?.properties?.info?.id;
const toolName = (input) => String(input?.tool ?? input?.toolName ?? "").toLowerCase();
const args = (input) => input?.args && typeof input.args === "object" ? input.args : {};
const successful = (output) => Number.isInteger(output?.metadata?.exitCode) && output.metadata.exitCode === 0;
const modelComponent = (value) => typeof value === "string" && value.length > 0 && value.length <= 256 && !/[\/\u0000-\u001f\u007f]/.test(value);
const observationIdentity = ["0.41.8","99656cb4818718e3a929f6f21d6e8268969f6c17"];
const observationMarker = Symbol.for("mefisto.original-tool-observation.v1");
const observationKey = (context, input) => JSON.stringify([observationIdentity[0], observationIdentity[1], context?.project?.id, context?.directory, sessionID(input), input?.callID]);
const classifiedObservation = (value) => value === null || (value && typeof value === "object" && !Array.isArray(value) && Object.keys(value).length === 2 && (value.family === "test" && value.subcommand === "test" || value.family === "terraform" && ["plan", "apply", "init", "validate"].includes(value.subcommand)));
const consumeOriginalObservation = (context, input) => {
  const store = globalThis[observationMarker];
  if (!(store instanceof Map)) return { found: false };
  const key = observationKey(context, input);
  if (!store.has(key)) return { found: false };
  const value = store.get(key); store.delete(key);
  return classifiedObservation(value) ? { found: true, value } : { found: false };
};
const classifyLegacyCommand = (command) => {
  if (/^\s*dotnet\s+test(?:\s|$)/.test(command)) return { family: "test", subcommand: "test" };
  const match = /^\s*terraform\s+(plan|apply|init|validate)(?:\s|$)/.exec(command);
  return match ? { family: "terraform", subcommand: match[1] } : null;
};

export default async function mefistoObservability(context) {
  const root = rootOf(context);
  const release = await identity(context.client);
  const observations = new Set();
  const changed = new Set();
  const reminded = new Set();
  const reminder = "[recordatorio] Si esta sesion tuvo descubrimientos de dominio, decisiones o alternativas descartadas, considera escribir field notes en docs/bitacora/field-notes/ antes de continuar.";
  return {
    event: async ({ event } = {}) => safe(context.client, "Mefisto: no se pudo registrar el inicio de sesion.", async () => {
      if (event?.type === "session.idle") {
        const idle = sessionID(event) ?? event?.properties?.sessionID;
        if (typeof idle === "string" && changed.has(idle) && !reminded.has(idle)) {
          reminded.add(idle);
          try { await context.client?.app?.log?.({ body: { service: "mefisto", level: "info", message: reminder } }); } catch { /* failure: continue */ }
        }
        return;
      }
      if (event?.type !== "session.created") return;
      const id = sessionID(event);
      if (typeof id !== "string" || id.length === 0 || !root) { await diagnostic(context.client, "Mefisto: payload de session.created no representable."); return; }
      const state = pipeline(root); await mkdir(state, { recursive: true });
      await writeFile(path.join(state, ".plugin-root"), releaseRoot, "utf8");
      await append(root, "sessions.jsonl", { record_type: "session.started", session_id: id, transcript_path: null, cwd: root, source: null, timestamp: now(), runtime: "opencode", model: null, harness_version: release.version, harness_commit: release.commit });
    }),
    "chat.params": async (input) => safe(context.client, "Mefisto: no se pudo registrar la observacion de modelo.", async () => {
      const id = sessionID(input); const model = input?.model;
      if (!root || typeof id !== "string" || id.length === 0 || !modelComponent(model?.providerID) || !modelComponent(model?.id)) { await diagnostic(context.client, "Mefisto: payload de chat.params no representable."); return; }
      const value = `${model.providerID}/${model.id}`; const key = JSON.stringify([id, value]);
      if (observations.has(key)) return;
      observations.add(key);
      try {
        const text = await readFile(path.join(pipeline(root), "sessions.jsonl"), "utf8").catch((error) => { if (error?.code === "ENOENT") return ""; throw error; });
        const exists = text.split("\n").some((line) => { try { const item = JSON.parse(line); return item.record_type === "session.model-observed" && item.session_id === id && item.model === value; } catch { return false; } });
        if (!exists) await append(root, "sessions.jsonl", { record_type: "session.model-observed", session_id: id, timestamp: now(), runtime: "opencode", model: value, harness_version: release.version, harness_commit: release.commit });
      } catch (error) { observations.delete(key); throw error; }
    }),
    "tool.execute.after": async (input, output) => safe(context.client, "Mefisto: no se pudo registrar el resumen de herramienta.", async () => {
      const tool = toolName(input); const inputArgs = args(input);
      if (["write", "edit", "patch"].includes(tool)) { if (!root) return; if (typeof input?.sessionID === "string" && input.sessionID.length > 0) changed.add(input.sessionID); const candidate = inputArgs.filePath ?? inputArgs.file_path ?? inputArgs.path; const file = typeof candidate === "string" && candidate.length > 0 ? candidate : "(desconocido)"; await append(root, "events.log", { time: clock(), family: "archivo", file_path: file }); return; }
      if (!["bash", "shell"].includes(tool)) return;
      const command = typeof inputArgs.command === "string" ? inputArgs.command : "";
      const observed = consumeOriginalObservation(context, input);
      if (!root) return;
      const classified = observed.found ? observed.value : classifyLegacyCommand(command);
      if (!classified) return;
      if (classified.family === "test") { await append(root, "events.log", { time: clock(), family: "test", result: successful(output) ? "PASS" : "FAIL" }); return; }
      await append(root, "events.log", { time: clock(), family: "terraform", terraform_subcommand: classified.subcommand, result: successful(output) ? "OK" : "ERROR" });
    }),
  };
}

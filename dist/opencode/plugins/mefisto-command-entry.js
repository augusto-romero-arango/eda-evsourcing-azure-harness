// GENERADO por src/published/scripts/adapters/adapter-opencode.sh desde src/published/contract/command-entry.json. No editar a mano.
const CATALOG = ["batch-stop","bitacora","bug","draft","eraser-diagram","fix-review","health-check","implement","infra","infra-base","install-apim","install-auth","install-workos","merge","next-order","onboard","parallel","purge-store","runtimes","scaffold","scaffold-mcp","scaffold-projections","seed-secret","sequential","tooling","upgrade","work-status"];
const IDENTITY = {"version":"0.40.2","commit":"c3c4a3d065cd99d1648d500d0ea03c6460ec5bee"};
const RESOLVER = "scripts/resolve-opencode-entry.sh";
import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";

const SAFE = /^[A-Za-z0-9_.-]{1,64}$/;
const owns = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
const plain = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const code = (value, fallback) => (typeof value === "string" && SAFE.test(value) ? value : fallback);
const agentId = (id) => "command-entry-" + id;
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const log = async (client, event, reason) => {
  try { await client?.app?.log?.({ body: { service: "mefisto", level: "warn", message: event, extra: { event, reason } } }); } catch { /* failure: continue */ }
};
const deny = (reason) => new Error("mefisto_entry_not_admitted:" + code(reason, "UNKNOWN"));

const runResolver = (root, args) => new Promise((resolve) => {
  execFile(join(root, RESOLVER), args, { timeout: 30000, maxBuffer: 1048576, windowsHide: true }, (error, stdout) => {
    try {
      const parsed = JSON.parse(String(stdout));
      resolve(plain(parsed) && parsed.schemaVersion === 1 && parsed.admissionScope === "entry" ? parsed : null);
    } catch { resolve(null); }
  });
});

const runtimeContext = (input) => {
  const env = (name) => (Object.prototype.hasOwnProperty.call(process.env, name) ? process.env[name] : null);
  return {
    platform: process.platform,
    homedir: homedir(),
    matcherHome: env("HOME"),
    xdg: { dataHome: env("XDG_DATA_HOME"), configHome: env("XDG_CONFIG_HOME"), stateHome: env("XDG_STATE_HOME"), cacheHome: env("XDG_CACHE_HOME") },
    directory: input.directory,
    worktree: input.worktree ?? null,
    nugetAssetsFiles: [],
  };
};

const readIdentity = (root) => {
  try {
    const manifest = JSON.parse(readFileSync(join(root, "mefisto-manifest.json"), "utf8"));
    return manifest.version === IDENTITY.version && manifest.commit === IDENTITY.commit;
  } catch { return false; }
};

export default async function mefistoCommandEntry(input = {}) {
  const client = input.client;
  const root = join(dirname(fileURLToPath(import.meta.url)), "..");
  const directory = input.directory;
  const state = { skip: false, failed: null, legacy: false, applied: false, snapshot: null, rejected: new Set() };
  if (typeof directory !== "string" || !isAbsolute(directory) ||
      (existsSync(join(directory, "src/published/contract/command-entry.json")) && existsSync(join(directory, ".claude-plugin/plugin.json")))) {
    state.skip = true;
  } else if (!readIdentity(root)) {
    state.failed = "IDENTITY_MISMATCH";
  }
  const context = state.skip ? null : runtimeContext(input);
  const base = (phase, extra) => ["--phase", phase, "--project-root", directory, "--context", JSON.stringify({ ...extra, runtimeContext: context })];
  const fail = async (reason) => { state.failed = code(reason, "UNKNOWN"); await log(client, "command_entry_failed", state.failed); };

  const config = async (cfg) => {
    try {
      if (state.skip) return;
      if (state.failed) { await log(client, "command_entry_failed", state.failed); return; }
      if (!plain(cfg)) throw new Error("invalid_config");
      const res = await runResolver(root, base("config", { catalog: CATALOG }));
      if (!res) return await fail("RESOLVER_FAILED");
      if (res.status === "disabled" && res.reasonCode === "NO_PROFILE" && !res.controlledContext && !state.applied) {
        for (const id of CATALOG) {
          const command = plain(cfg.command) ? cfg.command["mefisto:" + id] : undefined;
          if (plain(command) && command.agent === agentId(id) && command.subtask === false) { delete command.agent; delete command.subtask; }
        }
        state.legacy = true;
        return;
      }
      if (state.applied && res.status === "disabled") return await fail("PROFILE_REMOVED");
      const bindings = Array.isArray(res.bindings) ? res.bindings : [];
      const agents = plain(res.agents) ? res.agents : {};
      if (!same(bindings.map((row) => row?.command).sort(), [...CATALOG].sort())) return await fail("CATALOG_MISMATCH");
      const staged = [];
      const rejected = new Set();
      for (const row of bindings) {
        const name = agentId(row.command);
        const proposed = agents[name];
        if (row.agent !== name || row.admitted !== false || !plain(proposed)) return await fail("BINDING_INVALID");
        const agent = { ...proposed, mode: "primary" };
        delete agent.model; delete agent.variant;
        const existing = plain(cfg.agent) ? cfg.agent[name] : undefined;
        const command = plain(cfg.command) ? cfg.command["mefisto:" + row.command] : undefined;
        if (!plain(command)) return await fail("COMMAND_MISSING");
        if ((existing !== undefined && !same(existing, agent)) || (command.agent !== undefined && command.agent !== name)) rejected.add(row.command);
        staged.push({ id: row.command, name, agent });
      }
      if (rejected.size > 0) { state.rejected = rejected; await log(client, "command_entry_collision", "COLLISION"); return; }
      if (cfg.agent === undefined) cfg.agent = {};
      if (!plain(cfg.agent)) throw new Error("invalid_agent");
      for (const item of staged) { cfg.agent[item.name] = item.agent; cfg.command["mefisto:" + item.id].agent = item.name; cfg.command["mefisto:" + item.id].subtask = false; }
      state.applied = true;
      state.snapshot = typeof res.snapshotDigest === "string" ? res.snapshotDigest : null;
      if (res.status !== "ready") await log(client, "command_entry_not_ready", code(res.reasonCode, code(res.status, "UNKNOWN")));
    } catch { await fail("CONFIG_HOOK_FAILED"); }
  };

  const before = async (event) => {
    if (state.skip || state.legacy) return;
    const name = typeof event?.command === "string" ? event.command : "";
    if (!name.startsWith("mefisto:")) return;
    const id = name.slice("mefisto:".length);
    if (!CATALOG.includes(id)) return;
    if (state.failed) throw deny(state.failed);
    if (state.rejected.has(id)) throw deny("COLLISION");
    if (!state.applied) throw deny("NOT_APPLIED");
    let known = false; let matches = false; let rules = [];
    try {
      const session = await client.session.get({ path: { id: event.sessionID } });
      const data = session?.data;
      if (!session?.error && plain(data) && (data.permission === undefined || Array.isArray(data.permission))) {
        known = true;
        rules = Array.isArray(data.permission) ? data.permission : [];
        matches = data.directory === directory;
      }
    } catch { known = false; }
    const res = await runResolver(root, base("command", { commandId: id, sessionPolicyKnown: known, sessionProjectMatches: matches, sessionPermission: rules }));
    if (!res) throw deny("RESOLVER_FAILED");
    if (res.status !== "ready") throw deny(code(res.reasonCode, code(res.status, "NOT_READY")));
    const row = Array.isArray(res.bindings) ? res.bindings.find((item) => item?.command === id) : undefined;
    if (!row || row.agent !== agentId(id) || row.admitted !== true) throw deny(code(row?.reasonCode, "NOT_ADMITTED"));
    if (state.snapshot !== null && res.snapshotDigest !== state.snapshot) throw deny("SNAPSHOT_CHANGED");
  };

  return { config, "command.execute.before": before };
}

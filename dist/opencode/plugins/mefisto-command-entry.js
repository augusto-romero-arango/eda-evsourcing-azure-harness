// GENERADO por src/published/scripts/adapters/adapter-opencode.sh desde src/published/contract/command-entry.json. No editar a mano.
const CATALOG = ["batch-stop","bitacora","bug","draft","eraser-diagram","fix-review","health-check","implement","infra","infra-base","install-apim","install-auth","install-workos","merge","next-order","onboard","parallel","purge-store","runtimes","scaffold","scaffold-mcp","scaffold-projections","seed-secret","sequential","tooling","upgrade","work-status"];
const IDENTITY = {"version":"0.41.2","commit":"a42f2ad7692c396ed584db00568b0530b95d5078"};
const RESOLVER = "scripts/resolve-command-entry.sh";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, realpathSync, renameSync, writeFileSync } from "node:fs";
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

const digest = (value) => typeof value === "string" ? createHash("sha256").update(value.trim()).digest("hex") : "";
const policyFromRules = (rules) => {
  const permission = {};
  for (const rule of rules) {
    if (!plain(rule) || typeof rule.permission !== "string" || typeof rule.pattern !== "string" || !["allow", "ask", "deny"].includes(rule.value)) return null;
    const patterns = permission[rule.permission] ?? {};
    delete patterns[rule.pattern];
    patterns[rule.pattern] = rule.value;
    permission[rule.permission] = patterns;
  }
  return permission;
};
const projectResult = (result) => {
  if (!plain(result) || result.schemaVersion !== 1 || result.admissionScope !== "entry") return null;
  if (!Array.isArray(result.bindings) || !Array.isArray(result.agents)) return null;
  const agents = {};
  for (const row of result.agents) {
    if (typeof row?.id !== "string" || !Array.isArray(row.rules)) return null;
    const permission = policyFromRules(row.rules);
    if (!permission) return null;
    agents[row.id] = { description: "Entrada tecnica de Mefisto", permission, hidden: true };
  }
  return { ...result, reasonCode: result.reasonCode ?? result.diagnostics?.[0]?.code ?? result.status,
    agents, bindings: result.bindings.map((row) => ({ ...row, command: row.command?.startsWith("mefisto:") ? row.command.slice(8) : row.command })),
    snapshotDigest: result.projectionDigest, permissionImageDigest: result.projectionDigest,
    permissionBase: result.resourcesDigest };
};
const runResolver = (root, project, request) => new Promise((resolve) => {
  const child = execFile(join(root, RESOLVER), ["--project-root", project], { timeout: 30000, maxBuffer: 1048576, windowsHide: true }, (error, stdout) => {
    try {
      resolve(projectResult(JSON.parse(String(stdout))));
    } catch { resolve(null); }
  });
  child.stdin?.on?.("error", () => {});
  child.stdin?.end(JSON.stringify(request));
});

const runtimeContext = (input) => {
  const env = (name) => (Object.prototype.hasOwnProperty.call(process.env, name) ? process.env[name] : null);
  return {
    platform: process.platform,
    osHome: homedir(), home: env("HOME") ?? homedir(),
    xdgDataHome: env("XDG_DATA_HOME"), xdgConfigHome: env("XDG_CONFIG_HOME"), opencodeConfigDir: env("OPENCODE_CONFIG_DIR"),
    directory: input.directory,
    worktree: input.worktree ?? input.directory,
  };
};

// Pin fisico fijado al cargar el modulo: releer un symlink movido despues no cambia la release declarada.
const LOADED_ROOT = (() => { try { return realpathSync(join(dirname(fileURLToPath(import.meta.url)), "..")); } catch { return null; } })();
// Mismo contrato que _execution-context.sh (#1855): ruta del contexto bajo la raiz aprobada, no un id libre.
const CTX_RE = /^(\/.*)\/\.mefisto\/pipeline\/autonomy\/runs\/([A-Za-z0-9][A-Za-z0-9._-]{0,63})\/contexts\/([A-Za-z0-9][A-Za-z0-9._-]{0,63})\.json$/;
const DIGEST_RE = /^[0-9a-f]{64}$/;
const ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const sq = (value) => "'" + String(value).replaceAll("'", "'\\''") + "'";
const readContextRef = () => {
  const ref = owns(process.env, "MEFISTO_EXECUTION_CONTEXT") ? process.env.MEFISTO_EXECUTION_CONTEXT : undefined;
  const digest = owns(process.env, "MEFISTO_EXECUTION_DIGEST") ? process.env.MEFISTO_EXECUTION_DIGEST : undefined;
  if (ref === undefined && digest === undefined) return null;
  const match = typeof ref === "string" ? CTX_RE.exec(ref) : null;
  if (!match || typeof digest !== "string" || !DIGEST_RE.test(digest)) return { invalid: true, raw: ref ?? "", digest: digest ?? "" };
  return { base: match[1], runId: match[2], contextId: match[3], digest, raw: ref };
};
const runContextOp = (root, op, request) => new Promise((resolve) => {
  const child = execFile(join(root, "scripts/execution-context.sh"), [op], { timeout: 30000, maxBuffer: 1048576, windowsHide: true }, (error, stdout) => {
    try {
      const parsed = JSON.parse(String(stdout));
      resolve(plain(parsed) && parsed.schemaVersion === 1 ? parsed : null);
    } catch { resolve(null); }
  });
  child.stdin?.on?.("error", () => {});
  child.stdin?.end(JSON.stringify({ schemaVersion: 1, ...request }));
});

const readIdentity = (root) => {
  try {
    const manifest = JSON.parse(readFileSync(join(root, "mefisto-manifest.json"), "utf8"));
    return manifest.version === IDENTITY.version && manifest.commit === IDENTITY.commit;
  } catch { return false; }
};

export default async function mefistoCommandEntry(input = {}) {
  const client = input.client;
  const root = LOADED_ROOT ?? join(dirname(fileURLToPath(import.meta.url)), "..");
  const directory = input.directory;
  const state = { skip: false, failed: null, legacy: false, applied: false, snapshot: null, image: null, observed: null, owned: new Set(), rejected: new Set(), ctx: readContextRef(), actor: null, aliases: new Map(), sessions: new Map(), primary: new Set() };
  if (typeof directory !== "string" || !isAbsolute(directory) ||
      (existsSync(join(directory, "src/published/contract/command-entry.json")) && existsSync(join(directory, ".claude-plugin/plugin.json")))) {
    state.skip = true;
  } else if (!readIdentity(root)) {
    state.failed = "IDENTITY_MISMATCH";
  }
  const context = state.skip ? null : runtimeContext(input);
  const observe = (cfg) => {
    const manifest = JSON.parse(readFileSync(join(root, "command-entry-manifest.json"), "utf8"));
    return { schemaVersion: 1, home: context.home, configPolicyKnown: plain(cfg.permission) || cfg.permission === undefined,
      runtimeContext: context, nugetAssetsFiles: [],
      commands: manifest.templates.filter((row) => row.kind === "command").map((row) => {
        const actual = cfg.command?.["mefisto:" + row.id];
        return { name: "mefisto:" + row.id, sourceDigest: digest(actual?.template), agent: actual?.agent ?? null, subtask: actual?.subtask ?? null };
      }),
      delegateAgents: [...new Set(manifest.delegatedPrompts.map((row) => row.agent))].map((id) => {
        const actual = cfg.agent?.[id];
        return { id, available: plain(actual), sourceDigest: digest(actual?.prompt), mode: actual?.mode ?? null };
      }),
      foreignEntryAgents: Object.keys(cfg.agent ?? {}).filter((id) => id.startsWith("command-entry-") && !state.owned.has(id)),
      permission: { permission: cfg.permission ?? {} } };
  };
  const request = (phase, extra = {}) => ({ ...state.observed, phase, ...extra });
  const fail = async (reason) => { state.failed = code(reason, "UNKNOWN"); await log(client, "command_entry_failed", state.failed); };
  const getSession = async (id) => {
    try { const r = await client.session.get({ path: { id } }); return !r?.error && plain(r?.data) ? r.data : null; } catch { return null; }
  };
  const ctxBase = () => ({ projectRoot: state.ctx.base, runId: state.ctx.runId, contextId: state.ctx.contextId, digest: state.ctx.digest });
  const expectedActor = () => state.actor?.alias ?? state.actor?.original ?? null;
  const establish = async () => {
    const c = state.ctx;
    if (!c || c.invalid) return "CONTEXT_INVALID";
    const res = await runContextOp(root, "validate", ctxBase());
    if (!res || res.status !== "ready") return code(res?.reasonCode, "CONTEXT_NOT_READY");
    let doc;
    try { doc = JSON.parse(readFileSync(res.path, "utf8")); } catch { return "CONTEXT_UNREADABLE"; }
    const k = doc?.contract;
    if (!plain(k) || doc.contractDigest !== c.digest) return "CONTEXT_MISMATCH";
    if (k.release !== IDENTITY.version) return "RELEASE_MISMATCH";
    state.actor = { alias: k.alias ?? null, original: k.originalAgent ?? null, nonce: k.nonce, projectId: k.projectId, path: res.path };
    return null;
  };
  const writeReady = (res) => {
    try {
      const dir = join(dirname(state.actor.path), state.ctx.contextId);
      mkdirSync(dir, { recursive: true, mode: 0o700 });
      const body = { schemaVersion: 1, nonce: state.actor.nonce, contractDigest: state.ctx.digest, release: IDENTITY.version, projectId: state.actor.projectId, alias: expectedActor(), projectionDigest: typeof res.snapshotDigest === "string" ? res.snapshotDigest : null, instance: { pid: process.pid }, result: "ready" };
      const tmp = join(dir, ".runtime-ready." + process.pid + ".tmp");
      writeFileSync(tmp, JSON.stringify(body) + "\n", { mode: 0o600 });
      renameSync(tmp, join(dir, "runtime-ready.json"));
      return true;
    } catch { return false; }
  };
  // Revalida por llamada: misma imagen de permisos refresca evidencia; imagen distinta exige nueva admision.
  const recheck = async () => {
    const res = await runResolver(root, directory, request("config"));
    if (!res) return "RESOLVER_FAILED";
    if (res.status !== "ready") return code(res.reasonCode, "NOT_READY");
    const image = typeof res.permissionImageDigest === "string" ? res.permissionImageDigest : null;
    if (state.image !== null && image !== state.image) return "READMISSION_REQUIRED";
    if (state.snapshot !== null && res.snapshotDigest !== state.snapshot) {
      if (state.image === null) return "SNAPSHOT_CHANGED";
      const r = await runContextOp(root, "refresh-observations", { ...ctxBase(), controllerNonce: state.actor.nonce, observations: { resourcesDigest: res.resourcesDigest, permissionBase: res.permissionBase, permissionImageDigest: image, projection: res.snapshotDigest } });
      if (!r || r.status !== "ready") return code(r?.reasonCode, "REFRESH_FAILED");
      state.snapshot = res.snapshotDigest;
    }
    return null;
  };
  const bindSession = async (sessionID, role) => {
    const r = await runContextOp(root, "bind-session", { ...ctxBase(), sessionID, role: role ?? undefined, mode: "bind" });
    return r !== null && r.status === "ready";
  };

  const config = async (cfg) => {
    try {
      if (state.skip) return;
      if (state.failed) { await log(client, "command_entry_failed", state.failed); return; }
      if (!plain(cfg)) throw new Error("invalid_config");
      state.observed = observe(cfg);
      const res = await runResolver(root, directory, request("config"));
      if (!res) return await fail("RESOLVER_FAILED");
      if (res.status === "disabled" && res.reasonCode === "NO_PROFILE" && !res.controlledContext && !state.applied && !state.ctx) {
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
      // Alias autonomy-<id>: clon en memoria del rol original con la politica resuelta; el original no se toca.
      const aliasRows = Array.isArray(res.roleAliases) ? res.roleAliases : [];
      const stagedAliases = [];
      for (const row of aliasRows) {
        if (!plain(row) || typeof row.original !== "string" || typeof row.alias !== "string" || !row.alias.startsWith("autonomy-") || !plain(row.permission)) return await fail("ALIAS_INVALID");
        const origin = plain(cfg.agent) && plain(cfg.agent[row.original]) ? cfg.agent[row.original] : {};
        const alias = { ...origin, permission: row.permission, hidden: true, mode: "all" };
        const existing = plain(cfg.agent) ? cfg.agent[row.alias] : undefined;
        if (existing !== undefined && !same(existing, alias)) return await fail("ALIAS_COLLISION");
        stagedAliases.push({ original: row.original, name: row.alias, agent: alias });
      }
      if (cfg.agent === undefined) cfg.agent = {};
      if (!plain(cfg.agent)) throw new Error("invalid_agent");
      for (const item of stagedAliases) { cfg.agent[item.name] = item.agent; state.aliases.set(item.original, item); }
      for (const item of staged) { cfg.agent[item.name] = item.agent; cfg.command["mefisto:" + item.id].agent = item.name; cfg.command["mefisto:" + item.id].subtask = false; }
      for (const item of staged) state.owned.add(item.name);
      state.applied = true;
      state.snapshot = typeof res.snapshotDigest === "string" ? res.snapshotDigest : null;
      state.image = typeof res.permissionImageDigest === "string" ? res.permissionImageDigest : null;
      if (res.status !== "ready") await log(client, "command_entry_not_ready", code(res.reasonCode, code(res.status, "UNKNOWN")));
      if (state.ctx) {
        // Handshake headless: sin ready no hay evidencia y el caller no lanza el run.
        if (res.status !== "ready") return await fail(code(res.reasonCode, "NOT_READY"));
        if (LOADED_ROOT === null) return await fail("PIN_UNAVAILABLE");
        const why = await establish();
        if (why) return await fail(why);
        const expected = expectedActor();
        if (!expected) return await fail("ACTOR_UNDEFINED");
        if (state.actor.alias && ![...state.aliases.values()].some((item) => item.name === state.actor.alias)) return await fail("ALIAS_ABSENT");
        if (!writeReady(res)) return await fail("HANDSHAKE_FAILED");
      }
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
    const res = await runResolver(root, directory, request("command", { requestedCommand: id, sessionPolicyKnown: known, sessionProjectMatches: matches, sessionPermission: rules }));
    if (!res) throw deny("RESOLVER_FAILED");
    if (res.status !== "ready") throw deny(code(res.reasonCode, code(res.status, "NOT_READY")));
    const row = Array.isArray(res.bindings) ? res.bindings.find((item) => item?.command === id) : undefined;
    if (!row || row.agent !== agentId(id) || row.admitted !== true) throw deny(code(row?.reasonCode, "NOT_ADMITTED"));
    if (state.snapshot !== null && res.snapshotDigest !== state.snapshot) throw deny("SNAPSHOT_CHANGED");
    if (state.ctx) {
      // El veredicto sanitizado se registra solo tras revalidar sesion, proyecto y ownership; sin registro no hay entrada verificada.
      const why = await establish();
      if (why) throw deny(why);
      if (!(await bindSession(event.sessionID, state.actor.original))) throw deny("SESSION_BIND_FAILED");
      const admission = { sessionID: event.sessionID, commandId: id, release: IDENTITY.version, permissionImageDigest: res.permissionImageDigest, resourcesDigest: res.resourcesDigest, policyResult: "allowed", ownership: "verified" };
      const recorded = await runContextOp(root, "record-entry-admission", { ...ctxBase(), controllerNonce: state.actor.nonce, entryAdmission: admission });
      if (!recorded || recorded.status !== "ready") throw deny("ADMISSION_NOT_RECORDED");
      state.primary.add(event.sessionID);
    }
  };

  // Barrera previa a cada peticion al modelo: actor efectivo, sesion observada, contexto y politica vigentes.
  const params = async (event) => {
    if (state.skip) return;
    const sid = typeof event?.sessionID === "string" ? event.sessionID : "";
    const agent = typeof event?.agent === "string" ? event.agent : event?.agent?.name;
    if (!state.ctx) {
      if (typeof agent === "string" && agent.startsWith("command-entry-") && (state.failed || state.rejected.has(agent.slice("command-entry-".length)))) throw deny(state.failed ?? "COLLISION");
      return;
    }
    if (state.failed) throw deny(state.failed);
    let why = await establish();
    if (why) throw deny(why);
    const session = sid ? await getSession(sid) : null;
    if (!session || session.directory !== directory) throw deny("SESSION_UNOBSERVED");
    let expected = expectedActor();
    if (!expected) throw deny("ACTOR_UNDEFINED");
    if (typeof session.parentID === "string" && session.parentID) {
      const known = state.sessions.get(sid);
      if (!known) throw deny("ANCESTRY_UNKNOWN");
      expected = known.alias;
    } else if (!state.primary.has(sid)) {
      if (!(await bindSession(sid, state.actor.original))) throw deny("SESSION_BIND_FAILED");
      state.primary.add(sid);
    }
    if (agent !== expected) throw deny("ACTOR_MISMATCH");
    why = await recheck();
    if (why) throw deny(why);
  };

  const toolBefore = async (event, output) => {
    if (state.skip || !state.ctx) return;
    if (state.failed) throw deny(state.failed);
    const args = output?.args;
    if (event?.tool === "task") {
      if (!plain(args)) throw deny("TASK_ARGS_INVALID");
      if (args.background === true) throw deny("BACKGROUND_UNSUPPORTED");
      const target = args.subagent_type;
      const byOriginal = typeof target === "string" ? state.aliases.get(target) : undefined;
      const byAlias = typeof target === "string" ? [...state.aliases.values()].find((item) => item.name === target) : undefined;
      const hit = byOriginal ?? byAlias;
      if (!hit) throw deny("TASK_TARGET_UNKNOWN");
      if (args.task_id !== undefined) {
        const child = typeof args.task_id === "string" ? await getSession(args.task_id) : null;
        const known = typeof args.task_id === "string" ? state.sessions.get(args.task_id) : undefined;
        if (!child || child.parentID !== event.sessionID || !known || known.original !== hit.original) throw deny("TASK_RESUME_FOREIGN");
      }
      args.subagent_type = hit.name;
      return;
    }
    if (event?.tool === "bash") {
      const command = args?.command;
      const call = typeof event.callID === "string" ? event.callID : "";
      const child = ("tc-" + call).slice(0, 64);
      if (typeof command !== "string" || !ID_RE.test(child) || LOADED_ROOT === null) throw deny("TOOL_CALL_INVALID");
      const reserved = await runContextOp(root, "reserve-child", { ...ctxBase(), childContextId: child, reservationId: ("rs-" + call).slice(0, 64), callId: call, executionRoot: directory });
      if (!reserved || reserved.status !== "ready" || typeof reserved.digest !== "string") throw deny(code(reserved?.reasonCode, "RESERVE_FAILED"));
      const request = JSON.stringify({ schemaVersion: 1, projectRoot: state.ctx.base, runId: state.ctx.runId, contextId: child, digest: reserved.digest, handoffId: child });
      // Prefijo acotado: el comando original queda integro y visible; si attach falla el cuerpo no corre.
      args.command = sq(join(LOADED_ROOT, "scripts/execution-context.sh")) + ' attach --owner-pid "$$" <<\'MEFISTO_ATTACH_REQUEST\' >/dev/null || exit 1\n' + request + "\nMEFISTO_ATTACH_REQUEST\n" + command;
    }
  };

  const message = async (event) => {
    if (state.skip || !state.ctx) return;
    const sid = typeof event?.sessionID === "string" ? event.sessionID : "";
    const session = sid ? await getSession(sid) : null;
    if (!session) throw deny("SESSION_UNOBSERVED");
    if (typeof session.parentID !== "string" || !session.parentID) return;
    if (state.failed) throw deny(state.failed);
    if (state.sessions.has(sid)) return;
    if (!state.primary.has(session.parentID) && !state.sessions.has(session.parentID)) throw deny("ANCESTRY_UNKNOWN");
    const name = typeof event?.agent === "string" ? event.agent : event?.agent?.name;
    const hit = [...state.aliases.values()].find((item) => item.name === name);
    if (!hit) throw deny("ROLE_UNKNOWN");
    if (!(await bindSession(sid, hit.original))) throw deny("SESSION_BIND_FAILED");
    state.sessions.set(sid, { alias: hit.name, original: hit.original });
  };

  // El pin y el contexto viajan solo por llamada, nunca en el entorno global; el secreto del servidor no llega a las herramientas.
  const shellEnv = async (_event, output) => {
    if (state.skip || !state.ctx || !plain(output?.env)) return;
    output.env.MEFISTO_EXECUTION_CONTEXT = state.ctx.raw;
    output.env.MEFISTO_EXECUTION_DIGEST = state.ctx.digest;
    delete output.env.OPENCODE_SERVER_PASSWORD;
    delete output.env.OPENCODE_SERVER_USERNAME;
    if (!state.failed && !state.ctx.invalid && LOADED_ROOT !== null) output.env.MEFISTO_LOADED_RELEASE_ROOT = LOADED_ROOT;
    else delete output.env.MEFISTO_LOADED_RELEASE_ROOT;
  };

  return { config, "command.execute.before": before, "chat.params": params, "chat.message": message, "tool.execute.before": toolBefore, "shell.env": shellEnv };
}

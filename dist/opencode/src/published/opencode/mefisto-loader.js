// Cargador de Mefisto para OpenCode (MEF-ADR-0053 decision 2, issue #2261).
//
// Se commitea en el consumidor como .opencode/plugins/mefisto.js: es lo que activa
// Mefisto en ese repositorio y en sus worktrees. Registra la superficie de la release
// activa del usuario (agentes, comandos, Skills, MCP y hooks) sin copiarla al repo,
// asi que actualizar Mefisto no exige tocar el consumidor.
//
// Se inhibe cuando la superficie ya llega por otra via, para no cargarla dos veces:
//   - OPENCODE_CONFIG_DIR apunta a una release de Mefisto (agentes de pipeline);
//   - la proyeccion global opt-in de /mefisto:runtimes esta activa.
// Nunca rompe el arranque de OpenCode: ante cualquier fallo registra un aviso y no
// aporta nada.
import { access, readFile, readdir } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const dataRoot = () => {
  if (process.env.XDG_DATA_HOME) return path.join(process.env.XDG_DATA_HOME, "mefisto");
  if (process.platform === "darwin") return path.join(os.homedir(), "Library", "Application Support", "mefisto");
  return path.join(os.homedir(), ".local", "share", "mefisto");
};
const configRoot = () => process.env.OPENCODE_CONFIG_DIR
  || path.join(process.env.XDG_CONFIG_HOME || path.join(os.homedir(), ".config"), "opencode");
const exists = async (file) => { try { await access(file); return true; } catch { return false; } };
const isRelease = async (dir) => Boolean(dir) && await exists(path.join(dir, "mefisto-manifest.json"));

// El adaptador publicado emite cada valor del frontmatter como JSON en una sola linea.
const parse = (text) => {
  const match = /^---\n([\s\S]*?)\n---\n?([\s\S]*)$/.exec(text);
  if (!match) throw new Error("frontmatter ausente");
  const meta = {};
  for (const line of match[1].split("\n")) {
    const i = line.indexOf(": ");
    if (i > 0) meta[line.slice(0, i)] = JSON.parse(line.slice(i + 2));
  }
  return { meta, body: match[2].replace(/\n$/, "") };
};

// Misma forma que produce OpenCode al leer <config>/agents/*.md: `tools` se traduce a
// reglas de `permission` que preceden a las declaradas.
const asAgent = ({ meta, body }) => {
  const agent = { ...meta, prompt: body };
  if (meta.tools) {
    const fromTools = {};
    for (const [tool, enabled] of Object.entries(meta.tools)) fromTools[tool] = enabled ? "allow" : "deny";
    agent.permission = { ...fromTools, ...(meta.permission ?? {}) };
    delete agent.tools;
  }
  return agent;
};
const asCommand = ({ meta, body }) => ({ ...meta, template: body });

const surface = async (dir, shape) => {
  const out = {};
  for (const file of (await readdir(dir)).filter((name) => name.endsWith(".md")).sort()) {
    out[file.slice(0, -3)] = shape(parse(await readFile(path.join(dir, file), "utf8")));
  }
  return out;
};

const warn = async (client, message) => {
  try { await client?.app?.log?.({ body: { service: "mefisto", level: "warn", message } }); } catch { /* sin log */ }
};

const chain = (hooks, extra) => {
  for (const [name, fn] of Object.entries(extra ?? {})) {
    if (typeof fn !== "function") continue;
    const previous = hooks[name];
    hooks[name] = previous ? async (...args) => { await previous(...args); await fn(...args); } : fn;
  }
};

export default async function mefisto(input = {}) {
  const { client } = input;
  try {
    if (await isRelease(process.env.OPENCODE_CONFIG_DIR)) return {};
    if (await exists(path.join(configRoot(), ".mefisto-projection.json"))) return {};
    const release = path.join(dataRoot(), "active");
    if (!(await isRelease(release))) {
      await warn(client, "Mefisto: este repo lo habilita, pero no hay una release OpenCode instalada. Instalala con el bootstrap de la guia del consumidor.");
      return {};
    }
    const agents = await surface(path.join(release, "agents"), asAgent);
    const commands = await surface(path.join(release, "commands"), asCommand);
    const hooks = {};
    for (const file of (await readdir(path.join(release, "plugins"))).filter((name) => name.endsWith(".js")).sort()) {
      const plugin = await import(path.join(release, "plugins", file));
      chain(hooks, await plugin.default(input));
    }
    const releaseConfig = hooks.config;
    hooks.config = async (config) => {
      config.agent = { ...agents, ...(config.agent ?? {}) };
      config.command = { ...commands, ...(config.command ?? {}) };
      config.skills = { ...(config.skills ?? {}), paths: [...(config.skills?.paths ?? []), path.join(release, "skills")] };
      if (releaseConfig) await releaseConfig(config);
    };
    return hooks;
  } catch (error) {
    await warn(client, `Mefisto: no se pudo cargar la release activa (${error?.message ?? error}).`);
    return {};
  }
}

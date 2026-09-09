// GENERADO por src/published/scripts/adapters/adapter-opencode.sh desde src/published/contract/mcp-servers.json. No editar a mano.
const bundled = {"microsoft-learn":{"type":"remote","url":"https://learn.microsoft.com/api/mcp","enabled":true,"oauth":false}};
const owns = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
const identical = (actual, expected) => actual && typeof actual === "object" && !Array.isArray(actual) &&
  Object.keys(actual).length === Object.keys(expected).length &&
  Object.keys(expected).every((key) => actual[key] === expected[key]);
const log = async (client, event, server) => {
  try { await client?.app?.log?.({ body: { service: "mefisto", level: "warn", event, server } }); } catch { /* failure: continue */ }
};

export default async function mefistoMcp({ client } = {}) {
  return {
    config: async (config) => {
      try {
        if (!config || typeof config !== "object" || Array.isArray(config)) throw new Error("invalid_config");
        if (config.mcp === undefined) config.mcp = {};
        if (!config.mcp || typeof config.mcp !== "object" || Array.isArray(config.mcp)) throw new Error("invalid_mcp");
        for (const [server, expected] of Object.entries(bundled)) {
          if (!owns(config.mcp, server)) { config.mcp[server] = expected; continue; }
          if (!identical(config.mcp[server], expected)) await log(client, "mcp_config_conflict", server);
        }
      } catch { await log(client, "mcp_config_hook_failed", "microsoft-learn"); }
    },
  };
}

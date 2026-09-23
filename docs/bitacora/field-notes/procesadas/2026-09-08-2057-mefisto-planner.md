---
fecha: 2026-09-08
hora: 20:57
sesion: mefisto-planner
tema: Configuracion MCP publicada para OpenCode
---

## Contexto

Se refino #1056, segundo draft sin dependencia abierta del rollout publicado. El borrador mezclaba tres responsabilidades: declarar que servidores provee Mefisto, agregarlos a la configuracion efectiva OpenCode y traducir las referencias `mcp` de agentes/comandos.

## Descubrimientos

- OpenCode v1.18.29 configura servidores remotos bajo `Config.mcp` y registra sus tools con el prefijo `<servidor>_*`.
- Los plugins globales se cargan desde `~/.config/opencode/plugins/`; la API fijada expone `Hooks.config(input: Config)` y el runtime invoca secuencialmente ese hook con la configuracion efectiva.
- `project-opencode-release.sh` preserva `opencode.json` y proyecta `plugins/**`; por tanto, un plugin de configuracion evita fusionar o sobrescribir el archivo del usuario.
- El vocabulario neutral contiene `microsoft-learn` y `terraform`, pero solo Microsoft Learn esta bundleado en `.mcp.json`. Terraform es externo y administrado por el usuario/plugin oficial.
- OpenCode controla MCP por agente mediante `tools`, no mediante `permission`. Los comandos no tienen `tools`; su declaracion MCP debe satisfacerse mediante el agente al que delegan.

## Decisiones

- Se crea #1144 como prerequisito listo: registro neutral bundled/external y gate de equivalencia exacta con `.mcp.json`.
- #1056 queda limitado al asset `plugins/mefisto-mcp.js`, generado desde entradas bundleadas del registro mediante #1104.
- El hook `config` agrega Microsoft Learn solo si la clave esta ausente, con `type: remote`, endpoint canonico, `enabled: true` y `oauth: false`, sin headers.
- Ante una clave de usuario distinta, prevalece el usuario y se emite `mcp_config_conflict` sin serializar el valor conflictivo.
- Terraform nunca se configura desde #1056.
- Se crea #1145 para el mapping `mcp` -> `<servidor>_*`, cerrado por agente; depende de #1144/#1056.
- #1056 pasa a `estado:listo` y conserva `bloqueado` por #1144. #1066 suma la dependencia explicita #1145.

## Descartado

- Modificar `opencode.json` global o del consumidor: introduce merge destructivo y ownership ambiguo.
- Importar `.mcp.json` como fuente conceptual del adaptador OpenCode: es una proyeccion Claude y no distingue servidores externos.
- Bundlear Terraform: requiere entorno/binarios/configuracion que Mefisto no custodia y contradice la evidencia historica #754.
- Habilitar MCP mediante un wildcard global: concede tools a agentes que no las declararon.
- Mantener registro, plugin y allowlists en #1056: excedia una sola pasada y mezclaba tres componentes.

## Preguntas abiertas

- #1145 debe probar la validacion cruzada comando -> agente para impedir que un comando solicite una tool que su agente ejecutor mantiene deshabilitada.
- La conexion real y el listado de tools Microsoft Learn se verifican en #1066; CI de #1056 permanece determinista y sin red.

## Referencias

Issues creados: #1144 `Definir el registro neutral de servidores MCP publicados`; #1145 `Traducir referencias MCP en el adaptador OpenCode`.

Drafts refinados: #1056 `Adaptar la configuracion MCP publicada para OpenCode`.

Issues ajustados: #1066 (dependencia de #1145).

Fuentes: MEF-ADR-0019/0025/0049/0050/0053; [OpenCode v1.18.29 - MCP servers](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/web/src/content/docs/mcp-servers.mdx); [OpenCode v1.18.29 - Plugins](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/web/src/content/docs/plugins.mdx); `packages/opencode/src/plugin/index.ts` en tag v1.18.29.

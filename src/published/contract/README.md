# Contrato de artefactos publicados (`src/published/contract/`)

Las fuentes de `src/published/{agents,commands}/` describen capacidades sobre
un proyecto consumidor, nunca sobre el repositorio de Mefisto (MEF-ADR-0019 y
MEF-ADR-0053). Cada archivo se llama `<id>.md`, contiene frontmatter JSON entre
`---` y un body Markdown. El `id` es kebab-case sin `mefisto-`, `mefisto:` ni
separadores de runtime. `$ARGUMENTS` es el único placeholder de argumentos.

## Frontmatter

`published-artifact.schema.json` es la única declaración de campos. Todos los
objetos rechazan propiedades adicionales.

| Campo | Agente | Comando | Claude Code | OpenCode |
|---|---|---|---|---|
| `kind` | requerido | requerido | selecciona tipo de salida; no se emite | selecciona tipo de salida; no se emite |
| `id` | requerido | requerido | nombre de archivo/ruta; no se emite | nombre de archivo/ruta; no se emite |
| `description` | requerido | requerido | `description` | `description` |
| `mode` | requerido | no | selecciona la forma de ejecución; no se emite | `mode` |
| `profile` | sí | sí | `model` resuelto por tabla del adaptador | no se emite `model`; hereda la configuración interactiva del usuario |
| `capabilities` | sí | sí | `tools`/`allowed-tools` generados | `permission` generado |
| `skills` | sí | sí | `skills` con ids fuente, sin prefijo | disponibilidad del Skill adaptado `mefisto-<id>` |
| `mcp` | sí | sí | matcher scoped por id lógico | entrada `mcp`/permiso por id lógico |
| `agent` | no | sí | delegación al agente generado | `agent` + ejecución como subtask |
| `arguments` | no | sí | `argument-hint` | hint equivalente si el runtime lo admite |

Las capacidades son intenciones cerradas: `read`, `edit`, `shell`, `web`,
`skill`, `task`. Este es el mapping que los adaptadores deben materializar;
cualquier tool o permiso no derivado queda denegado:

| Capacidad | Claude Code (`tools`/`allowed-tools`) | OpenCode (`permission`) |
|---|---|---|
| `read` | `Read`, `Glob`, `Grep` | `read`, `list`, `glob`, `grep` |
| `edit` | `Edit`, `Write` | `edit`, `write`, `patch` |
| `shell` | `Bash` | `bash` |
| `web` | `WebFetch`, `WebSearch` | `webfetch`, `websearch` |
| `skill` | `Skill` | `skill` |
| `task` | `Task` | `task` |

El mapping solo concede permisos sobre el consumidor. `edit` queda sujeto al
scope/gate del pipeline consumidor correspondiente: no sourcea ni replica como
autoridad `is_path_in_mefisto_scope`. En OpenCode tampoco habilita `lsp` de
forma implícita (MEF-ADR-0052).

`mcp` no es una tool ni un permiso de runtime: es una lista de ids lógicos
kebab-case. Los ids iniciales son `mcp: ["microsoft-learn"]` y
`mcp: ["terraform"]`. El schema registra esos mappings iniciales como un
vocabulario cerrado: agregar otro id requiere actualizar el contrato y los
mappings de todos los adaptadores. Si un runtime carece del mapping de un id
declarado, su validación/generación aborta; nunca concede MCP genérico.

Toda referencia `skills` debe resolver a un `skills/<id>/SKILL.md` publicado.
Las referencias `skills` y `agent`, igual que los argumentos `<id>` de las
directivas, conservan ids fuente sin prefijo. Un runtime sin plugin transforma
cada Skill en la salida a `mefisto-<id>`. El prefijo adaptado no pertenece a la
fuente.

## Directivas del body

Todo artefacto incluye `{{mefisto:assert-consumer-repo}}`, que aborta si el cwd
es el repositorio de Mefisto. Cualquier directiva `{{mefisto:...}}` no listada
o mal formada se rechaza.

| Directiva | Claude Code | OpenCode |
|---|---|---|
| `{{mefisto:assert-consumer-repo}}` | guard generado que aborta en el repo de Mefisto | el mismo guard de consumidor, sin importar políticas internas |
| `{{mefisto:launch-agent <id>}}` | delegación al agente generado del plugin | delegación al agente global generado |
| `{{mefisto:run <script> <args>}}` | script bajo la raíz instalada del plugin + argumentos | script bajo la release activa + argumentos |
| `{{mefisto:package-root}}` | raíz instalada del plugin | raíz de la release activa |
| `{{mefisto:config-path}}` | `.mefisto/harness.config.json` del consumidor | `.mefisto/harness.config.json` del consumidor |
| `{{mefisto:state-path <rel>}}` | `.mefisto/pipeline/<rel>` del consumidor | `.mefisto/pipeline/<rel>` del consumidor |
| `{{mefisto:command <id>}}` | `/mefisto:<id>` | `/mefisto:<id>` |

Los adaptadores materializan comandos como `/mefisto:<id>`. El body no puede
nombrar CLIs, variables, cachés, directorios ni metadata de un runtime. Tampoco
admite placeholders distintos de `$ARGUMENTS`.

## Validación

```bash
src/published/scripts/validate-published-artifacts.sh [archivo...]
```

Sin argumentos valida `src/published/{agents,commands}/*.md`. Cada rechazo usa
`<archivo>: <campo|body>: <motivo>`. El script requiere Bash 3.2 y `jq`; los
fixtures y su prueba están en este contrato y en
`scripts/tests/test-published-artifact-contract.sh`.

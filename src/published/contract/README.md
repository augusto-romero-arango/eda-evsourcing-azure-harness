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
| `skills` | sí | sí | `skills` con ids fuente, sin prefijo | preámbulo que solicita la carga nativa on-demand de `mefisto-<id>` |
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

Toda referencia `skills` debe resolver a un `skills/<id>/SKILL.md` publicado,
ser única y conservar el id lógico sin prefijo. Claude Code materializa esos
ids directamente en su frontmatter. OpenCode transforma cada uno en
`mefisto-<id>` y antepone una instrucción mínima para cargarlo mediante su tool
nativa `skill`, antes del body; no copia la doctrina ni menciona rutas. En los
agentes OpenCode, declarar referencias exige además la capacidad neutral
`skill`: su `permission.skill` niega `*` y permite exactamente los nombres
adaptados. Si la capacidad existe sin referencias, conserva la política general
de la capacidad. Los comandos solo solicitan la carga: el permiso efectivo es
el del agente que los ejecuta y una denegación permanece visible.

| Referencia neutral | Claude Code | OpenCode |
|---|---|---|
| `skills: ["x"]` | frontmatter `skills: ["x"]` | preámbulo `skill` para `mefisto-x`; en agentes con capacidad `skill`, allowlist exacta en `permission.skill` |

Toda referencia `skills` debe resolver a un `skills/<id>/SKILL.md` publicado.
Las referencias `skills` y `agent`, igual que los argumentos `<id>` de las
directivas, conservan ids fuente sin prefijo. Un runtime sin plugin transforma
cada Skill en la salida a `mefisto-<id>`. El prefijo adaptado no pertenece a la
fuente.

## Layout de Skills empaquetados

Los Skills publicados son fuente de solo lectura bajo `skills/<id>/`: `SKILL.md`
es Nivel 2 y sus recursos relativos son Nivel 3 (MEF-ADR-0033). El adaptador
OpenCode enumera ese árbol de forma determinista y lo materializa como
`dist/opencode/skills/mefisto-<id>/`. Solo transforma el campo `name` del primer
frontmatter de `SKILL.md` al mismo nombre del directorio; todos los recursos se
copian byte a byte. La proyección global enlaza después esos archivos en
`<config>/opencode/skills/mefisto-<id>/`. La prueba de carga on-demand mediante
la tool `skill` corresponde a la certificación #1066.

## Directivas del body

Todo artefacto incluye `{{mefisto:assert-consumer-repo}}`, que aborta si el cwd
es el repositorio de Mefisto. Cualquier directiva `{{mefisto:...}}` no listada
o mal formada se rechaza.

| Directiva | Claude Code | OpenCode |
|---|---|---|
| `{{mefisto:assert-consumer-repo}}` | guard generado que aborta en el repo de Mefisto | el mismo guard de consumidor, sin importar políticas internas |
| `{{mefisto:launch-agent <id>}}` | delegación al agente generado del plugin | delegación al agente global generado |
| `{{mefisto:run <script> <args>}}` | script bajo `MEFISTO_PACKAGE_ROOT` + argumentos | script bajo `MEFISTO_PACKAGE_ROOT` + argumentos |
| `{{mefisto:package-root}}` | `MEFISTO_PACKAGE_ROOT` | `MEFISTO_PACKAGE_ROOT` |
| `{{mefisto:config-path}}` | `.mefisto/harness.config.json` del consumidor | `.mefisto/harness.config.json` del consumidor |
| `{{mefisto:state-path <rel>}}` | `.mefisto/pipeline/<rel>` del consumidor | `.mefisto/pipeline/<rel>` del consumidor |
| `{{mefisto:command <id>}}` | `/mefisto:<id>` | `/mefisto:<id>` |

Los adaptadores materializan comandos como `/mefisto:<id>`. El body no puede
nombrar CLIs, variables, cachés, directorios ni metadata de un runtime. Tampoco
admite placeholders distintos de `$ARGUMENTS`.

Cuando un body usa `run` o `package-root`, el adaptador antepone un bloque Bash
que valida y exporta una única raíz física sin barra final:
`MEFISTO_PACKAGE_ROOT`. Claude valida la distribución cargada desde su variable
de runtime o los markers canónico/legacy del consumidor; OpenCode consulta el
launcher de la release activa. Esta mecánica es exclusiva de cada salida: la
fuente neutral y sus callers no conocen variables ni layouts de runtime.

## Validación

```bash
src/published/scripts/validate-published-artifacts.sh [archivo...]
```

Sin argumentos valida `src/published/{agents,commands}/*.md`. Cada rechazo usa
`<archivo>: <campo|body>: <motivo>`. El script requiere Bash 3.2 y `jq`; los
fixtures y su prueba están en este contrato y en
`scripts/tests/test-published-artifact-contract.sh`.

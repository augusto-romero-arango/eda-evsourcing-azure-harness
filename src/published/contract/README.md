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
| `kind`, `id`, `description` | requerido | requerido | metadata equivalente | metadata equivalente |
| `mode` | requerido | no | perfil de ejecución | `mode` |
| `profile` | sí | sí | modelo por tabla del adaptador | selección configurable |
| `capabilities` | sí | sí | tools/allowlist generada | permisos generados |
| `skills` | sí | sí | `skills` generado | Skill adaptado si aplica |
| `mcp` | sí | sí | matcher scoped generado | permiso/configuración generado |
| `agent`, `arguments` | no | sí | directiva/hint generado | `agent`/subtask generado |

Las capacidades son intenciones cerradas: `read`, `edit`, `shell`, `web`,
`skill`, `task`. El mapeo es deny-by-default y solo concede herramientas o
permisos del consumidor: `read` lee, `edit` edita bajo el scope/gate del
pipeline consumidor, `shell` ejecuta comandos, `web` usa web, `skill` carga
Skills y `task` delega subagentes. No sourcea ni replica como autoridad
`is_path_in_mefisto_scope`.

`mcp` no es una tool ni un permiso de runtime: es una lista de ids lógicos
kebab-case. Los ids iniciales son `mcp: ["microsoft-learn"]` y
`mcp: ["terraform"]`. Cada adaptador debe tener un mapping explícito y
fail-closed: una ausencia aborta validación/generación, nunca concede MCP
genérico.

Toda referencia `skills` debe resolver a un `skills/<id>/SKILL.md` publicado.
La fuente conserva el id sin prefijo; un runtime sin plugin transforma la
salida a `mefisto-<id>`. El prefijo adaptado no pertenece a la fuente.

## Directivas del body

Todo artefacto incluye `{{mefisto:assert-consumer-repo}}`, que aborta si el cwd
es el repositorio de Mefisto. Cualquier directiva `{{mefisto:...}}` no listada
o mal formada se rechaza.

| Directiva | Expansión por adaptador |
|---|---|
| `{{mefisto:assert-consumer-repo}}` | guard que rechaza el repo de Mefisto |
| `{{mefisto:launch-agent <id>}}` | lanzamiento/enrutamiento del agente publicado |
| `{{mefisto:run <script> <args>}}` | invocación del script publicado correspondiente |
| `{{mefisto:package-root}}` | raíz instalada del paquete del runtime |
| `{{mefisto:config-path}}` | ruta de configuración del consumidor |
| `{{mefisto:state-path <rel>}}` | ruta de estado del consumidor |
| `{{mefisto:command <id>}}` | namespace de comando del adaptador |

Los adaptadores materializan comandos como `/mefisto:<id>`. El body no puede
nombrar CLIs, variables, cachés, directorios ni metadata de un runtime.

## Validación

```bash
src/published/scripts/validate-published-artifacts.sh [archivo...]
```

Sin argumentos valida `src/published/{agents,commands}/*.md`. Cada rechazo usa
`<archivo>: <campo|body>: <motivo>`. El script requiere Bash 3.2 y `jq`; los
fixtures y su prueba están en este contrato y en
`scripts/tests/test-published-artifact-contract.sh`.

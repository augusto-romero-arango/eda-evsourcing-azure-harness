# Contrato de artefactos internos (`src/internal/contract/`)

Esta carpeta contiene exclusivamente el contrato del lado interno para
`src/internal/{agents,commands}/` y la configuracion que usa su generador de
adaptadores. No es un formato para proyectos consumidores (MEF-ADR-0019).
El stream JSONL neutral de ejecucion vive en el nucleo comun:
[`src/runtime/contract/README.md`](../../runtime/contract/README.md).

## Formato de artefacto

Cada archivo `src/internal/{agents,commands}/<id>.md` empieza con frontmatter
JSON entre dos lineas `---`, seguido de Markdown. `id` coincide con el nombre
del archivo y tiene prefijo `mefisto-`; el body no nombra runtimes concretos.
`$ARGUMENTS` es el unico placeholder neutral de argumentos.

`internal-artifact.schema.json` es la fuente de verdad de los campos. Los
comunes son `kind`, `id`, `description`, `profile`, `capabilities` y `skills`.
Los agentes requieren `mode`; los comandos pueden declarar `agent` y
`arguments`. Todos los objetos cierran `additionalProperties: false`.

Los vocabularios cerrados son `profile` (`fast`, `balanced`, `deep`) y las
capacidades `read`, `edit`, `shell`, `web`, `skill`, `task`, `mcp`. Expresan
intencion, no herramientas ni permisos de un runtime.

## Generacion y validacion internas

`src/internal/scripts/generate-internal-adapters.sh` transforma la fuente
neutral en `.claude/{agents,commands}/` y `.opencode/{agents,commands}/`.
Estas salidas son generadas y llevan su marcador; `--check` verifica que no
divergan. Las directivas `{{mefisto:launch-agent ...}}`,
`{{mefisto:run ...}}` y `{{mefisto:command-path ...}}` son la unica forma de
que un body neutral solicite una traduccion del adaptador.

`src/internal/scripts/validate-internal-artifacts.sh` valida el frontmatter,
la coincidencia de `id` con el archivo y la neutralidad del body. Usa
`jsonschema-lite.jq`, sin toolchain adicional. Sus fixtures viven en
`fixtures/{valid,invalid}/`.

`opencode-permissions.json` contiene el mapping declarativo interno de
capacidades a permisos. `neutrality-allowlist.json` documenta las excepciones
permanentes del gate de neutralidad; no contiene el schema de eventos comun.

## Interfaz interna de runner y adaptadores

Mientras #1045 extrae su mecanica, `src/internal/scripts/mefisto-run-agent.sh`
`--prompt-file`, `--event-log`, y opcionalmente runtime, modelo, timeout,
logs y reanudacion. Carga `runtime-<id>.sh`; cada adaptador implementa
`runtime_<id>_build_cmd`, `runtime_<id>_translate` y, opcionalmente,
`runtime_<id>_supports_resume`. El runner escribe `run.started`, delega la
traduccion de datos concretos y normaliza el cierre conforme al contrato comun

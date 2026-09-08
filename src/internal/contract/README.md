# Contrato de artefactos y ejecucion internos (`src/internal/contract/`)

Esta carpeta contiene el contrato exclusivo del lado interno para
`src/internal/{agents,commands}/`, la configuracion de su generador de
adaptadores y, hasta #1045, la interfaz ejecutable del runner interno. No es un
formato para proyectos consumidores (MEF-ADR-0019).

El vocabulario, schema, taxonomia de fallos, cardinalidad terminal y fixtures
del stream JSONL son parte del nucleo comun y se documentan unicamente en
[`src/runtime/contract/README.md`](../../runtime/contract/README.md).

## Formato de un artefacto

Cada archivo es `src/internal/{agents,commands}/<id>.md`:

```text
---
{ ... objeto JSON ... }
---

Cuerpo Markdown. $ARGUMENTS es el unico placeholder neutral de argumentos.
```

El frontmatter debe ser un objeto valido tanto en JSON como en YAML 1.2. `id`
coincide con el nombre del archivo, usa kebab-case y lleva prefijo `mefisto-`.
El body no nombra runtimes concretos; el generador introduce esas diferencias.
Las excepciones fisicas permanentes son `.claude-plugin/` y
`.claude/scripts/`, esta ultima superficie estable de invocacion interna para
todos los adaptadores.

`internal-artifact.schema.json` es la unica declaracion de campos validos:

| Campo | Aplica a | Regla |
|---|---|---|
| `kind` | ambos | `agent` o `command` |
| `id`, `description` | ambos | obligatorios |
| `profile` | ambos | `fast`, `balanced` o `deep` |
| `capabilities`, `skills` | ambos | listas opcionales |
| `mode` | agente | `primary`, `subagent` o `all` |
| `agent`, `arguments` | comando | opcionales |

Todos los objetos usan `additionalProperties: false`. Las capacidades forman
el vocabulario `read`, `edit`, `shell`, `web`, `skill`, `task`, `mcp` y
expresan intenciones, nunca nombres de tools o claves de permisos.

## Generacion de adaptadores

`src/internal/scripts/generate-internal-adapters.sh` transforma las fuentes
neutrales en `.claude/{agents,commands}/` y
`.opencode/{agents,commands}/`. Las salidas incluyen un marcador estable de
archivo generado y no se editan a mano. El modo `--check` genera en un temporal
y detecta salidas faltantes, distintas, huerfanas o sin marcador.

Mapeo principal:

| Campo neutral | Adaptador Claude Code | Adaptador OpenCode |
|---|---|---|
| `description` | `description` | `description` |
| `mode` | se omite | `mode` |
| `capabilities` | `tools` / `allowed-tools` | `permission` en agentes |
| `skills` | `skills` | se omite |
| `agent` de comando | directiva de body | `agent` + `subtask: true` |
| `arguments` | `argument-hint` | se omite |
| `profile` | modelo por tabla fija | se omite; el usuario configura el modelo interactivo |

El mapping de modelos en ejecucion headless vive en los adaptadores y en
`mefisto-models.sh`; el generador no lee `.mefisto/models.json`, porque eso
haria no determinista su `--check`. Una resolucion vacia significa heredar y
el caller omite el flag de modelo.

Las directivas de body son el unico escape neutral y una directiva desconocida
aborta la generacion:

| Directiva | Efecto |
|---|---|
| `{{mefisto:launch-agent <id>}}` | Lanza o enruta al agente indicado |
| `{{mefisto:run <script> <args>}}` | Invoca la superficie estable `.claude/scripts/` con el runtime activo |
| `{{mefisto:command-path <id>}}` | Resuelve la ruta de comando propia del adaptador |

`opencode-permissions.json` traduce capacidades al vocabulario cerrado de
permisos verificado para el adaptador. La politica es deny-por-defecto, incluye
siempre `external_directory: deny` y no deja claves en `ask` durante ejecucion
headless. `mcp` no tiene mapping implicito: el generador aborta hasta que haya
una decision explicita. `neutrality-allowlist.json` registra solo excepciones
permanentes del gate de neutralidad; el schema comun de eventos no pertenece a
esa lista interna.

## Validacion de artefactos

```bash
src/internal/scripts/validate-internal-artifacts.sh [archivo...]
```

Sin argumentos valida `src/internal/{agents,commands}/*.md`. Extrae el
frontmatter, aplica `internal-artifact.schema.json`, compara `id` con el nombre
del archivo y comprueba la neutralidad del body. Usa
`src/internal/scripts/lib/jsonschema-lite.jq`, sin un validador externo. Los
fixtures propios de este contrato permanecen en `fixtures/{valid,invalid}/` y
los ejercita `test-internal-artifact-contract.sh`.

## Runner interno

Hasta que #1045 extraiga la mecanica, la interfaz es:

```bash
src/internal/scripts/mefisto-run-agent.sh \
  --agent <id> --cwd <dir> --prompt-file <archivo> \
  --event-log <jsonl> \
  [--runtime <id>] [--model <opaco>] [--system-file <archivo>] \
  [--timeout <segundos>] [--raw-log <archivo>] \
  [--stderr-log <archivo>] [--resume-session <id>]
```

Es un proceso con argumentos, exit code y archivo de eventos explicitos. Los
argumentos invalidos terminan con exit 64. Modelo vacio o ausente significa
heredar y no llega como flag al runtime. El runner escribe `run.started`,
delega al adaptador la traduccion del wire format y normaliza el cierre contra
el [contrato comun](../../runtime/contract/README.md).

La seleccion de runtime respeta esta precedencia: `--runtime`,
`MEFISTO_RUNTIME`, autodeteccion. La autodeteccion solo acepta exactamente un
runtime disponible; cero o mas de uno exigen desambiguar. La libreria se
descubre como `$MEFISTO_RUNTIME_LIB_DIR/runtime-<id>.sh`, sin una lista cerrada
de runtimes (MEF-ADR-0050).

### Interfaz de adaptador

Cada `src/internal/scripts/lib/runtime-<id>.sh` implementa:

| Funcion | Contrato interno |
|---|---|
| `runtime_<id>_build_cmd <agent> <cwd> <prompt_file> <model> <system_file> [<resume_session_id>]` | Rellena el array global `MEFISTO_RUNTIME_CMD` sin `eval`; traduce opciones y omite las vacias |
| `runtime_<id>_translate <raw_file> <runtime_id> <model> [<exit_code>] [<stderr_file>]` | Emite por stdout el JSONL comun derivado del wire format; nunca emite `run.started` |
| `runtime_<id>_supports_resume` | Devuelve 0 si soporta reanudacion y 1 en otro caso; ausente equivale a no soportada |

El runner siempre entrega exit code y stderr al traductor para distinguir una
muerte por senal o un error que el CLI no escribio en stdout. El traductor
puede ignorarlos. El caller consulta `supports_resume` en un subshell antes de
decidir reanudar; el runner solo reenvia el identificador opaco a `build_cmd`.

El anexo de eventos no terminales durante una corrida es best-effort y
append-only. Al cierre se detiene el anexo en vivo, se agregan los eventos que
faltan y se normaliza un unico terminal. El watchdog sintetiza timeout; cero o
varios terminales del traductor producen protocolo invalido. Las reglas
completas del stream, incluida la cardinalidad, viven exclusivamente en el
contrato comun.

### Reanudacion y telemetria interna

Tras un hold, el pipeline puede reanudar si el terminal conserva `session_id`
y el adaptador declara soporte. Degrada a una corrida nueva si falta el id, la
capacidad no existe o la sesion reanudada vuelve a morir sin resumen de stage.
El prompt de continuacion es corto y nunca bifurca la sesion. Esta decision
pertenece al caller, no al runner.

`--events-log` es la telemetria legible del pipeline y no debe confundirse con
`--event-log`, que es el JSONL comun. A partir de este ultimo registra actividad
de tools, archivos y el estado del stage. Un fallo de escritura de telemetria
solo produce un aviso: no modifica el exit code ni el terminal ya emitido.

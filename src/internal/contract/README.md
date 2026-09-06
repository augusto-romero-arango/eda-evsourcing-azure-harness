# Contrato neutral de agentes y comandos internos (`src/internal/contract/`)

Fuente de verdad del formato que todo agente/comando de
`src/internal/{agents,commands}/` debe cumplir (MEF-ADR-0049 CA-6, issue
#853). Es la **interfaz canonica del generador de adaptadores**
(`src/internal/scripts/generate-internal-adapters.sh`, issue #854): el
generador consume estos archivos `.md` y produce `.claude/{agents,commands}/*.md`
+ `.opencode/{agents,commands}/*.md`. **No es un formato para que un proyecto
consumidor lo adopte**: vive enteramente del lado interno del propio plugin
Mefisto (MEF-ADR-0019).

Ningun agente ni comando real de `.claude/{agents,commands}/` esta migrado
todavia a este formato: eso es alcance de #865-#867, y hasta entonces
`src/internal/{agents,commands}/` esta vacio.

## Formato de un artefacto

Cada archivo es `src/internal/{agents,commands}/<id>.md`:

```
---
{ ... objeto JSON ... }
---

Cuerpo Markdown. $ARGUMENTS es el unico placeholder neutral de argumentos.
```

- **Linea 1**: literalmente `---`.
- **Bloque JSON**: un objeto (puede ocupar varias lineas), valido tanto como
  JSON como YAML 1.2 (escalares JSON-quoted + *flow mappings*, MEF-ADR-0049
  CA-6) -- cualquier runtime que lea frontmatter YAML lo acepta tal cual, sin
  traduccion.
- **Linea de cierre**: `---` sola, en su propia linea.
- **Body**: Markdown libre. Nunca referencia `claude`, `opencode`, `.claude/`
  ni `.opencode/` -- esas las introduce el generador o el adaptador, no la
  fuente neutral. `$ARGUMENTS` es el unico placeholder de argumentos
  reconocido. El validador **aplica** esta regla: rechaza toda linea del body
  que contenga `claude` u `opencode` (sin distinguir mayusculas), citando el
  numero de linea. Solo se inspecciona el body: el `description` del
  frontmatter puede nombrar un runtime cuando ese runtime *es* el tema (p. ej.
  al describir por que un campo esta prohibido).

## Regla de extraccion del frontmatter

El bloque JSON es todo lo que hay entre la primera linea (`---`) y la
siguiente linea que sea *exactamente* `---`. Un objeto JSON nunca contiene una
linea que sea solo `---`, asi que el corte con un `awk` de una sola pasada es
robusto sin necesitar un parser JSON para encontrar el limite:

```bash
awk 'NR==1 && $0!="---"{exit 1} NR>1 && $0=="---"{exit} NR>1' archivo.md
```

`validate-internal-artifacts.sh` implementa exactamente esta regla.

## Campos

Comunes a `agent` y `command`:

| Campo | Tipo | Obligatorio | Descripcion |
|---|---|---|---|
| `kind` | `"agent"` \| `"command"` | si | Discrimina el resto del schema (`oneOf` por `kind`) |
| `id` | string kebab-case, prefijo `mefisto-` | si | Debe coincidir con el nombre de archivo (sin `.md`) |
| `description` | string no vacio | si | Descripcion funcional del artefacto |
| `profile` | `fast` \| `balanced` \| `deep` | no | Perfil logico de modelo (MEF-ADR-0049 CA-4) |
| `capabilities` | lista de capacidades (ver tabla abajo) | no | Que puede hacer el artefacto, en terminos semanticos |
| `skills` | lista de ids de Agent Skills | no | Agent Skills (MEF-ADR-0033) precargados |

Solo `agent`:

| Campo | Tipo | Obligatorio | Descripcion |
|---|---|---|---|
| `mode` | `primary` \| `subagent` \| `all` | si | Lo consume OpenCode; el adaptador Claude Code lo ignora, pero se exige igual para que la fuente neutral quede completa |

Solo `command`:

| Campo | Tipo | Obligatorio | Descripcion |
|---|---|---|---|
| `agent` | string, mismo patron que `id` | no | Id del agente bajo el que corre este comando (resuelve #866 CA-3: OpenCode lo mapea a su frontmatter `agent`; el adaptador Claude Code decide su mecanismo en #859/#866) |
| `arguments` | string no vacio | no | Hint textual de los argumentos esperados |

`additionalProperties: false` en todos los niveles: ninguna propiedad fuera de
esta tabla es valida en ningun artefacto.

## Vocabularios cerrados

- `profile`: `fast`, `balanced`, `deep` (MEF-ADR-0049 CA-4). Nunca un alias de
  proveedor (`sonnet`, `opus`, `fable`) ni un id de modelo concreto.
- `capabilities`: subconjunto de `read`, `edit`, `shell`, `web`, `skill`,
  `task`, `mcp`.

Ningun nombre de modelo, proveedor, tool de Claude Code (`Bash`, `Read`,
`Write`, ...) ni clave de permiso de OpenCode (`permission`, `bash`,
`external_directory`, ...) es un valor valido en ningun campo de este
contrato.

### Mapeo semantico de `capabilities`

Cada valor describe una **intencion**, no una tool ni un permiso de un
runtime concreto. El mapeo a permisos/tools reales de cada runtime es
responsabilidad de un issue de seguimiento (#862), no de este contrato:

| Capacidad | Intencion |
|---|---|
| `read` | Leer archivos del repo (codigo, docs, config) |
| `edit` | Modificar o crear archivos del repo |
| `shell` | Ejecutar comandos de shell (git, gh, jq, scripts del propio harness) |
| `web` | Consultar documentacion o recursos externos (fetch/search) |
| `skill` | Invocar Agent Skills (progressive disclosure, MEF-ADR-0033) |
| `task` | Delegar trabajo en un subagente |
| `mcp` | Invocar tools expuestas por un servidor MCP |

## Mapeo campo neutral -> campo por runtime

Lo aplica `src/internal/scripts/generate-internal-adapters.sh` (issue #854), un
adaptador por runtime en `src/internal/scripts/lib/adapter-{claude,opencode}.sh`.

| Campo neutral | Claude Code | OpenCode 1.18.29 |
|---|---|---|
| `id` (agente) | `name` | -- (el nombre lo da el archivo) |
| `id` (comando) | -- | -- (el nombre lo da el archivo) |
| `description` | `description` | `description` |
| `mode` (agente) | -- (lo ignora) | `mode` |
| `capabilities` | `tools` (agente) / `allowed-tools` (comando) | -- (diferido a #862) |
| `skills` | `skills` (MEF-ADR-0033) | -- |
| `agent` (comando) | -- (lo resuelve la directiva de body) | `agent` + `subtask: true` |
| `arguments` | `argument-hint` | -- (OpenCode no tiene equivalente) |
| `profile` | `model` (tabla fija: `fast`->`haiku`, `balanced`->`sonnet`, `deep`->-- omitido) | -- (sin tabla, siempre hereda) |
| body | body, tras el marcador de generado | body (`template`), tras el marcador |

Un `--` significa que ese runtime no recibe el campo: o no tiene un equivalente
(`argument-hint`, `skills`), o lo ignora (`mode` en Claude Code), o su emision
esta diferida a un issue de seguimiento (`tools`/`permission` de OpenCode ->
#862). Ningun campo se emite "por si acaso": lo que no esta en esta tabla, el
generador no lo escribe.

### `profile` -> `model` de Claude Code (MEF-ADR-0049 CA-4 enmendada, issue #857)

Cuando la fuente declara `profile`, el generador consulta la tabla fija de
`adapter_claude_default_model` (`src/internal/scripts/lib/adapter-claude.sh`)
-- **nunca** el mapping local `.mefisto/models.json` -- y emite `model:` solo
si esa tabla devuelve un valor no vacio:

| `profile` | `model` emitido (Claude) | `model` emitido (OpenCode) |
|---|---|---|
| `fast` | `"haiku"` | (nunca se emite) |
| `balanced` | `"sonnet"` | (nunca se emite) |
| `deep` | (se omite el campo -- hereda el modelo activo) | (nunca se emite) |

El generador no lee `.mefisto/models.json` a proposito: es estado de maquina,
y leerlo romperia el determinismo (misma fuente -> mismos bytes) que sostiene
su modo `--check`. Ese mapping local solo interviene en **tiempo de
ejecucion**, via `mefisto_resolve_model` (`src/internal/scripts/lib/
mefisto-models.sh`) -- la funcion que usaran los pipelines headless (#859,
#869), no el generador. Su precedencia completa (override `--models` ->
mapping local -> tabla del adaptador -> herencia) esta documentada en el
propio archivo y en MEF-ADR-0049 decision 4.

`mefisto_resolve_model` imprime cadena vacia cuando corresponde heredar; el
caller debe entonces omitir por completo el argumento de modelo (`--model` de
`claude -p`, `-m` de `opencode run`) en vez de pasarlo vacio.

### Listar ids de modelo reales (para poblar `.mefisto/models.json`)

`.mefisto/models.json` nunca se commitea (`.gitignore`, MEF-ADR-0049
decision 4); solo se versiona la plantilla `src/internal/models.example.json`
con placeholders `<provider/model>`. Para poblarlo con ids reales:

- **Claude Code**: `claude --help` lista los alias de familia disponibles
  (`fast`, `sonnet`, `opus`, ...) y como pinnear una version concreta
  (`claude-opus-5[1m]`, etc.).
- **OpenCode**: `opencode models <provider>` lista los ids `provider/model`
  que ese provider expone.

Los ids de OpenCode los certifica el mantenedor al cerrar el dogfooding
(issue #874) y quedan registrados ahi como evidencia -- no en este repo.

El modelo **interactivo** por agente en OpenCode (fuera de un pipeline
headless) no se fija en `.mefisto/models.json`: OpenCode lo resuelve desde la
config global del usuario (`~/.config/opencode/opencode.json`), fuera del
alcance de Mefisto.

### `capabilities` -> `tools`/`allowed-tools` de Claude Code

| Capacidad | Tools emitidas |
|---|---|
| `read` | `Read, Glob, Grep` |
| `edit` | `Edit, Write` |
| `shell` | `Bash` |
| `web` | `WebFetch, WebSearch` |
| `skill` | `Skill` |
| `task` | `Task` |
| `mcp` | **sin mapeo**: el generador aborta con `capacidad mcp sin mapeo Claude definido` |

`mcp` aborta a proposito en vez de degradar a "sin tools": ningun artefacto
interno lo declara todavia, y un mapeo inventado hoy (`mcp__*` con que scope?)
seria una decision de seguridad tomada sin caso de uso. El primer artefacto que
lo necesite trae consigo la decision.

Las tools se concatenan en el orden en que las capacidades aparecen en la
fuente: `["read", "edit"]` -> `tools: "Read, Glob, Grep, Edit, Write"`.

### Directivas de body

Unico mecanismo por el que un body neutral referencia un runtime o un script
sin nombrarlos (el validador rechaza `claude`/`opencode` en el body, ver
arriba). Cada adaptador las traduce; **una directiva `{{mefisto:...}}`
desconocida aborta la generacion**, nunca se copia tal cual.

| Directiva | Claude Code | OpenCode |
|---|---|---|
| `{{mefisto:launch-agent <id>}}` (linea completa) | bloque bash con `claude --agent <id> "$ARGUMENTS"` | frontmatter `agent: <id>` + `subtask: true`, y la frase ``Actua como `<id>` con este mensaje inicial: $ARGUMENTS`` en lugar de la directiva |
| `{{mefisto:run <script.sh> <args>}}` | `MEFISTO_RUNTIME=claude ./.claude/scripts/<script.sh> <args>` | `MEFISTO_RUNTIME=opencode ./.claude/scripts/<script.sh> <args>` |
| `{{mefisto:command-path <id>}}` | `.claude/commands/<id>.md` | `.opencode/commands/<id>.md` |

`{{mefisto:run}}` apunta a `.claude/scripts/` en **ambos** runtimes: esos shims
son la superficie estable de invocacion (#864), y lo que cambia entre runtimes
es la variable `MEFISTO_RUNTIME` que reciben, no su ruta.

`{{mefisto:launch-agent}}` solo se reconoce cuando ocupa una linea completa
(el frontmatter `agent:` de OpenCode es por-archivo, no por-ocurrencia); las
otras dos se traducen en el sitio exacto de la linea, para poder anidarlas
(`cat "{{mefisto:command-path <id>}}"`).

## Marcador de generado y `--check`

Cada archivo generado lleva, como primera linea de su body, exactamente:

```
<!-- GENERADO por src/internal/scripts/generate-internal-adapters.sh desde <ruta-fuente>. No editar a mano. -->
```

Sin fecha ni hash: el determinismo (misma fuente -> mismos bytes) es lo que
hace verificable a `--check`, y un timestamp lo romperia en cada corrida.

`generate-internal-adapters.sh --check` no escribe nada -- ni siquiera el
directorio de salida: genera en un temporal y compara contra lo versionado,
imprimiendo una linea `<ruta>: faltante|distinta|huerfana` por divergencia y
saliendo con exit 1. *Huerfana* es un archivo **con** el marcador cuya fuente
ya no existe. Un archivo **sin** marcador se tolera (es de autoria manual):
es la toleracion transitoria que sostiene a `.claude/{agents,commands}/`
mientras #865-#867 migran, y que #873 retira.

## Subconjunto de JSON Schema soportado

`internal-artifact.schema.json` se valida con `jsonschema-lite.jq`
(`src/internal/scripts/lib/jsonschema-lite.jq`), un programa `jq` -- no un
validador JSON Schema externo (MEF-ADR-0049 CA-6: `ajv`, `jsonschema`, etc.
quedan fuera del toolchain bash + jq + git + gh). Soporta exactamente estas
palabras clave:

| Palabra clave | Semantica soportada |
|---|---|
| `type` | `"object"`, `"array"`, `"string"` |
| `required` | Lista de campos obligatorios de un objeto |
| `properties` | Sub-schema por campo de un objeto |
| `additionalProperties` | Solo `false`: rechaza cualquier campo fuera de `properties` |
| `enum` | Vocabulario cerrado de valores validos |
| `items` | Sub-schema aplicado a cada elemento de un array |
| `pattern` | Regex (sintaxis Oniguruma de `jq`) aplicado a un string |
| `minLength` | Longitud minima de un string |
| `oneOf` | Solo la forma "dispatch por `kind`": cada rama declara `properties.kind.enum` con un unico valor; el validador elige la rama cuyo `kind` coincide con el `kind` de la instancia y valida solo esa rama en profundidad (mensajes de error especificos por campo, no un generico "0/N ramas coinciden" de un `oneOf` JSON Schema estandar) |

No implementado (y no necesario para este contrato): `$ref`, `allOf`,
`anyOf`, `if`/`then`/`else`, `const`, `not`, `contains`,
`patternProperties`, `$schema`/meta-validacion.

## Validador

```bash
src/internal/scripts/validate-internal-artifacts.sh [archivo...]
```

Sin argumentos, valida todo `src/internal/{agents,commands}/*.md` (vacio hoy:
#865-#867 todavia no migraron ningun artefacto real, asi que el validador sale
con exit 0 sin encontrar nada que rechazar). Cada rechazo imprime una linea
`<archivo>: <campo>: <motivo>` y el proceso sale con exit distinto de cero si
cualquier archivo se rechaza. Corre con bash 3.2 + jq 1.7, sin red ni
paquetes (MEF-ADR-0049 CA-6).

El schema es la unica declaracion de campos validos: el script no duplica esa
lista, solo orquesta la extraccion del frontmatter y los tres chequeos que el
schema no puede expresar porque no dependen solo del frontmatter:

1. **Estructura del archivo**: frontmatter ausente, sin delimitador de cierre,
   vacio o no-JSON (cada caso con su propio motivo).
2. **`id` vs. nombre de archivo**: el nombre no viaja en la instancia, asi que
   el schema no puede compararlos.
3. **Neutralidad del body** (CA-1): ninguna linea del body nombra `claude` ni
   `opencode`.

El schema corre **primero** y es quien juzga los campos: si `id` falta, no es
un string o la instancia ni siquiera es un objeto JSON, el motivo que se
imprime es el del schema (`tipo esperado string`, `se esperaba un objeto
JSON`, ...) y no un generico "id ausente" que ocultaria la causa real. Un
archivo con varios defectos los reporta todos, uno por linea, en vez de parar
en el primero.

## Fixtures

`fixtures/valid/` contiene un agente y un comando completos, con todos los
campos opcionales poblados. `fixtures/invalid/` contiene un archivo por
motivo de rechazo: frontmatter ausente, frontmatter no-JSON, `id` que no
coincide con el archivo, `id` mal tipado (fija que el motivo lo da el schema y
no el chequeo de nombre de archivo), propiedad adicional (incluidos `model`,
`tools`, `permission` y `allowed-tools` como casos explicitos), `profile` y
`capabilities` fuera de vocabulario, `mode` ausente en un agente, y un body
que nombra un runtime concreto.
`.claude/scripts/tests/test-internal-artifact-contract.sh` corre el
validador contra cada fixture y comprueba exit code **y** el motivo esperado
en el mensaje, para que un fixture invalido no pase por la razon equivocada.

## Protocolo de ejecucion y eventos

Contrato de **como se invoca un agente** y **que eventos produce esa
invocacion**, neutral a runtime (MEF-ADR-0049 CA-1, issue #858). Antes de
este contrato, el unico pipeline interno invocaba `claude -p` directamente
(`.claude/scripts/mefisto-tooling-pipeline.sh:463`) y todas sus decisiones
(exito, clasificacion de fallo, metricas) dependian de nombres de campo
propios de Claude Code (`is_error`, `stop_reason`, `subtype`, `num_turns`).
Este protocolo es la frontera: un pipeline que lo consuma no necesita conocer
flags ni eventos de ningun runtime concreto.

### `mefisto-run-agent.sh`

```
src/internal/scripts/mefisto-run-agent.sh \
    --agent <id> --cwd <dir> --prompt-file <f> --event-log <jsonl> \
    [--runtime <id>] [--model <opaco>] [--system-file <f>] \
    [--timeout <s>] [--raw-log <f>] [--stderr-log <f>]
```

Es un **script**, no una funcion `source`ada: un subproceso con argumentos
explicitos, exit code y archivo de eventos, para que el contrato se pruebe
con un adaptador falso sin tocar ningun pipeline. Valida sus argumentos
(archivos existentes, `--timeout` entero > 0) y aborta con uso y **exit 64**
ante faltantes o invalidos. `--model` vacio o ausente se trata como
"heredar": no llega al adaptador -- `build_cmd` nunca ve un flag de modelo en
ese caso.

`run_agent_with_watchdog` (issue #424, hoy en `.claude/scripts/
_mefisto-common.sh`) se reutiliza tal cual -- ya es neutral a runtime -- y el
runner la envuelve, traduciendo su senal de timeout a `run.failed{status:
"timeout"}`. El traslado de esa lib comun a `src/internal/scripts/` es
alcance de #869, no de este contrato.

### Seleccion de runtime (`lib/mefisto-runtime.sh`)

`mefisto_resolve_runtime` resuelve, en este orden de precedencia:

1. `--runtime <id>` explicito.
2. `MEFISTO_RUNTIME` (entorno).
3. Autodeteccion: `command -v claude` / `command -v opencode`. Exactamente
   uno instalado lo selecciona; **cero o ambos abortan** (exit 69 en el
   runner) con un mensaje que nombra `MEFISTO_RUNTIME` para desambiguar.

Un runtime resuelto por cualquiera de las tres vias que no tenga libreria de
adaptador `src/internal/scripts/lib/runtime-<id>.sh` aborta igual. La
funcion vive en su propio archivo (no en `mefisto-run-agent.sh`) para que el
pipeline (#879) y el batch (#870) la reutilicen en su chequeo de
dependencias sin duplicar la precedencia. `MEFISTO_RUNTIME_LIB_DIR` es
overrideable (mismo patron `: "${VAR:=default}"` que `mefisto-state.sh`):
producción resuelve siempre contra el directorio real de la libreria, un
test puede apuntarlo a un directorio temporal con adaptadores de prueba.

### Interfaz de adaptador: dos funciones por runtime

Cada `src/internal/scripts/lib/runtime-<id>.sh` (`source`ado por el runner)
implementa:

| Funcion | Contrato |
|---|---|
| `runtime_<id>_build_cmd <agent> <cwd> <prompt_file> <model> <system_file>` | Rellena el array global `MEFISTO_RUNTIME_CMD` con el argv completo a invocar via `run_agent_with_watchdog`, **sin `eval`**. `<model>`/`<system_file>` pueden llegar vacios; el adaptador decide si eso omite un flag o usa un valor propio (permisos como `--permission-mode bypassPermissions` / `--auto` son responsabilidad de esta funcion, no del runner). |
| `runtime_<id>_translate <raw_file> <runtime_id> <model>` | Imprime por stdout, una linea JSON por evento, el JSONL neutral (`message`/`tool.*`/terminal) derivado de `<raw_file>`. **Nunca emite `run.started`** -- eso lo hace el runner directo, porque no depende de ningun dato especifico del adaptador. |

Este issue (#858) entrega **solo** `lib/runtime-fake.sh`: reproduce guiones
(exito, fallo con exit N, cuelgue hasta timeout, sin evento terminal, dos
terminales, JSON malformado, `--model` recibido/omitido) via la variable de
entorno `MEFISTO_FAKE_SCRIPT`, para poder probar el runner sin invocar
`claude` ni `opencode`. Los adaptadores reales son #859 (Claude Code) y #860
(OpenCode).

### Vocabulario de eventos (`run-events.schema.json`)

Todo evento del JSONL neutral lleva `v: 1` y `type` (vocabulario cerrado en
el array `types` del schema):

| `type` | Campos propios |
|---|---|
| `run.started` | `ts`, `runtime`, `agent`, `model\|null`, `cwd` |
| `message` | `ts`, `role`, `text`, `kind?: "text"\|"thinking"` |
| `tool.started` | `ts`, `tool`, `input_summary\|null` |
| `tool.completed` | `ts`, `tool`, `ok`, `duration_ms\|null` |
| `run.completed` / `run.failed` | `status: "success"\|"failed"\|"timeout"\|"protocol_invalid"`, `runtime`, `model\|null`, `session_id\|null`, `duration_ms`, `tokens {input\|null, output\|null}`, `cost_usd\|null`, `turns\|null`, `denials\|null`, `ttft_ms\|null`, `api_duration_ms\|null`, `error\|null` |

`error`, cuando no es `null`, es `{kind, detail}` con `kind` en
`timeout`/`killed`/`api_error`/`stream_cut`/`nonzero_exit`/`no_result`/
`protocol_invalid`. Ningun campo lleva un nombre propio de Claude Code
(`is_error`, `stop_reason`, `subtype`, `num_turns`); campos no disponibles
son siempre `null`, nunca un cero fabricado (MEF-ADR-0049 CA-1) -- `duration_ms`
de un evento terminal es la unica excepcion aparente: el runner SIEMPRE lo
sobreescribe con el tiempo real medido alrededor de la invocacion completa
(el unico reloj de pared que existe fuera del proceso del adaptador), nunca
con un placeholder.

**`run-events.schema.json` no usa `oneOf`** para dispatchar por `type`: el
`oneOf` de `jsonschema-lite.jq` (#853) esta fijado al discriminador `kind`
(el de `internal-artifact.schema.json`), y el discriminador de este contrato
es `type`. En su lugar, el archivo declara `definitions.<type>` -- un
sub-schema completo por cada valor de `types` -- y quien valida una linea
selecciona `definitions[.type]` antes de invocar `jsonschema-lite.jq` (ver
`validate_event_line` en `.claude/scripts/tests/test-mefisto-run-agent.sh`).
Un campo documentado como "`<tipo>` o null" (la mayoria de los campos del
evento terminal) se declara **sin** la palabra clave `type` en su
sub-schema: `jsonschema-lite.jq` solo aplica `type`/`required`/`properties`
cuando la instancia es del jtype que esas palabras clave asumen, asi que
omitir `type` deja pasar tanto el valor tipado como `null` -- a costa de no
poder rechazar aqui un tipo intermedio incorrecto. Es una limitacion
documentada del subconjunto de JSON Schema (#853), no un descuido.

### Exactamente un evento terminal (MEF-ADR-0031, CA-5 de #858)

El runner **garantiza** que `--event-log` termine con exactamente un evento
terminal (`run.completed` o `run.failed`), sin importar cuantos haya emitido
el adaptador:

| Situacion | `status` del terminal | Exit code |
|---|---|---|
| El adaptador emitio exactamente 1 terminal `success` | `success` | `0` |
| El adaptador emitio exactamente 1 terminal no-exitoso | `failed` (u otro) | El exit code del adaptador (!= 0) |
| El watchdog mato el proceso por timeout | `timeout` | `124` |
| El adaptador emitio 0 o >=2 terminales | `protocol_invalid` | `65` |

En los dos ultimos casos el runner **sintetiza** el evento terminal el mismo
(descartando cualquier terminal parcial que el adaptador haya alcanzado a
traducir): un timeout no es confiable a mitad de vuelo, y un protocolo
invalido no tiene un terminal legitimo entre los que sobran o faltan. Es la
misma doctrina de MEF-ADR-0031 (gates deterministas por evidencia
verificable) aplicada al desenlace de un proceso, no solo a su readiness.

### Fixtures (`fixtures/run-events/`)

`valid-*.jsonl` son corridas completas (con `run.started` y exactamente un
terminal) que validan linea a linea. `invalid-two-terminals.jsonl` es
**valido linea a linea** -- cada `run.completed`/`run.failed` individual
cumple su schema -- pero viola la invariante cross-linea de la seccion
anterior (2 terminales): documenta que ese invariante no lo puede expresar
`run-events.schema.json` por si solo, hace falta contarlos.
`invalid-missing-field.jsonl` y `invalid-unknown-type.jsonl` si son
rechazables linea a linea (campo requerido ausente; `type` fuera de
`types`). `.claude/scripts/tests/test-mefisto-run-agent.sh` corre el runner
real contra cada guion de `runtime-fake.sh` y valida ambas dimensiones a la
vez sobre su propia salida.

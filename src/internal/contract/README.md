# Contrato neutral de agentes y comandos internos (`src/internal/contract/`)

Fuente de verdad del formato que todo agente/comando de
`src/internal/{agents,commands}/` debe cumplir (MEF-ADR-0049 CA-6, issue
#853). Es la **interfaz canonica del generador de adaptadores**
(`src/internal/scripts/generate-internal-adapters.sh`, issue #854): el
generador consume estos archivos `.md` y produce `.claude/{agents,commands}/*.md`
+ `.opencode/{agents,commands}/*.md`. **No es un formato para que un proyecto
consumidor lo adopte**: vive enteramente del lado interno del propio plugin
Mefisto (MEF-ADR-0019).

Estado de la migracion: los cinco agentes internos (los tres de #865 y los
dos de stage del pipeline de tooling, `mefisto-{writer,reviewer}`, de #909) y los once comandos
internos -- los cinco de analisis y seguimiento,
`mefisto-{plan,bug,bitacora,work-status,fix-review}` (#866), los cinco de
ejecucion, `mefisto-{tooling,tooling-verbose,sequential,merge,release}`
(#867), y `mefisto-next-order` (#939) -- ya nacen de este formato.

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

  Dos excepciones literales (issue #866): `.claude-plugin/` (el manifiesto
  fisico del Claude Code Plugin, identico e indispensable en ambos runtimes --
  el "guard inverso" que abre todo comando lo cita tal cual) y
  `.claude/scripts/` (la superficie estable de invocacion de los pipelines
  internos, identica en la salida de ambos adaptadores -- ver "Directivas de
  body" mas abajo). Ninguna otra forma de `.claude/` (`.claude/pipeline`,
  `.claude/agents`, `.claude/commands`) ni de `claude`/`opencode` a secas
  entra en esta excepcion.

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
| `capabilities` | `tools` (agente) / `allowed-tools` (comando) | `permission` (solo agente, issue #862) |
| `skills` | `skills` (MEF-ADR-0033) | -- |
| `agent` (comando) | -- (lo resuelve la directiva de body) | `agent` + `subtask: true` |
| `arguments` | `argument-hint` | -- (OpenCode no tiene equivalente) |
| `profile` | `model` (tabla fija: `fast`->`haiku`, `balanced`->`sonnet`, `deep`->-- omitido) | -- (`model` se omite; hereda la configuracion del usuario) |
| body | body, tras el marcador de generado | body (`template`), tras el marcador |

Un `--` significa que ese runtime no recibe el campo: o no tiene un equivalente
(`argument-hint`, `skills`, `tools` de OpenCode -- no tiene una restriccion
declarativa de tools mas alla de `permission`), o lo ignora (`mode` en Claude
Code). Ningun campo se emite "por si acaso": lo que no esta en esta tabla, el
generador no lo escribe.

### `profile` -> `model` por runtime (MEF-ADR-0049 CA-4, issues #857 y #961)

El generador Claude consulta `adapter_claude_default_model` y emite `model:`
solo si su tabla devuelve un valor no vacio. El generador OpenCode **siempre
omite** `model:` en agentes y comandos: asi la ejecucion interactiva hereda el
proveedor/modelo configurado por el usuario, comportamiento documentado por
OpenCode ([Agents](https://opencode.ai/docs/agents/#model),
[Commands](https://opencode.ai/docs/commands/#model)). Su tabla versionada se
usa exclusivamente en `mefisto_resolve_model`, para pipelines headless:

| `profile` | `model` emitido (Claude) | fallback headless OpenCode | `model` emitido (OpenCode) |
|---|---|---|---|
| `fast` | `"haiku"` | `openai/gpt-5.6-luna` | (se omite) |
| `balanced` | `"sonnet"` | `openai/gpt-5.6-terra` | (se omite) |
| `deep` | (se omite -- hereda) | `openai/gpt-5.6-sol` | (se omite) |

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

Los defaults OpenCode versionados se verifican contra este catalogo; cualquier
otro proveedor/modelo se selecciona en la configuracion local o global.

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

### `capabilities` -> `permission` de OpenCode (issue #862, MEF-ADR-0049 decision 5)

Solo agentes (los comandos de OpenCode no declaran `permission`: enrutan a
traves de un agente via `agent`). `opencode run --auto` aprueba todo lo que
quedaria en `ask` y solo respeta `deny` -- headless sin un bloque `permission`
cerrado por defecto no aisla nada. El mapping declarativo
`src/internal/contract/opencode-permissions.json` traduce cada capacidad al
vocabulario de 17 claves verificado contra el binario **OpenCode 1.18.29**
(`bash`, `edit`, `write`, `patch`, `read`, `list`, `glob`, `grep`, `question`,
`skill`, `task`, `lsp`, `todowrite`, `websearch`, `webfetch`,
`external_directory`, `doom_loop`) -- distinto de la doc publica
(<https://opencode.ai/docs/permissions/>), que funde `write`/`patch` bajo
`edit`. **Toda clave recibe un valor explicito**, nunca hereda un default
global; un agente con `capabilities: []` (o sin el campo) obtiene las 17
claves en `deny`.

| Capacidad (o `mode`) | Claves de `permission` | Regla |
|---|---|---|
| (siempre) | `external_directory`, `doom_loop` | `deny`, sin excepcion |
| `mode` del agente | `question` | `allow` solo si `mode: primary`; `deny` en `subagent`/`all` (headless no tiene a quien preguntar) |
| `web` | `webfetch`, `websearch` | `allow` si esta declarada, si no `deny` |
| `skill` | `skill` | idem |
| `task` | `task` | idem |
| `read` | `list`, `glob`, `grep`, `lsp`, `todowrite` | idem |
| `shell` | `bash` (mapa de patrones) | `{"*": "deny"}` si no esta declarada; si esta, `"*": "deny"` + patrones de `git`, `gh`, `jq`, coreutils de lectura (con y sin argumentos), los scripts del repo bajo `scripts/tests/`, `.claude/scripts/` y `src/internal/scripts/` (como `bash <script>`, como invocacion directa y en la forma exacta que emite `{{mefisto:run}}`, `MEFISTO_RUNTIME=opencode ./.claude/scripts/*`), `shasum`, `mkdir`, `date`, `mktemp`, `diff` en `allow` -- `rm`, `curl`, `ssh`, `scp`, `sudo`, `npm`, `pip`, `brew`, `git push --force*`, `gh repo delete*` quedan `deny` aunque `shell` este presente |
| `edit` | `edit`, `write`, `patch` (mismo mapa de patrones) | `{"*": "deny"}` si no esta declarada; si esta, `"*": "deny"` + las rutas de `is_path_in_mefisto_scope` (`.claude/scripts/_mefisto-common.sh`) mas `.mefisto/pipeline/summaries/**` y `.claude/pipeline/summaries/**` en `allow` |
| `read` | `read` (mapa de patrones) | `{"*": "deny"}` si no esta declarada; si esta, `"*": "allow"` + `.env`, `.env.*`, `**/.env`, `**/.env.*`, `**/auth.json`, `**/.aws/**`, `**/.ssh/**`, `~/.local/share/opencode/**`, `~/.claude/**` en `deny` |
| `mcp` | -- | **sin mapeo**: el generador aborta con `capacidad mcp sin mapeo OpenCode` (mismo criterio que `mcp` en la tabla Claude de arriba) |

OpenCode evalua cada mapa de patrones en el orden declarado y **gana la
ultima coincidencia**: por eso el catch-all `"*"` va siempre primero y las
reglas especificas despues, y el emisor (`opencode_permission_json` en
`adapter-opencode.sh`) preserva ese orden (`jq` sin `-S`) al construir el
objeto. `src/internal/scripts/lib/opencode-permission-eval.jq` reproduce
unicamente esa regla de orden para los tests (no el motor real de OpenCode);
`.claude/scripts/tests/test-opencode-permissions.sh` lo ejercita, incluida
una paridad `edit` vs `is_path_in_mefisto_scope` sobre una muestra de rutas.
Si el dogfooding (#874) revela una discrepancia con OpenCode real, se corrige
el mapping, nunca el test.

### Scope temprano en OpenCode (issue #863)

`mefisto-scope-hook.sh` (`.claude/scripts/mefisto-scope-hook.sh`, PostToolUse
de `.claude/settings.json`) solo aplica a sesiones **Claude Code**: avisa
DESPUES de una escritura fuera de la allowlist interna, porque un hook
PostToolUse no puede bloquear retroactivamente lo que el tool ya ejecuto. Ese
mecanismo no se porta a OpenCode -- no existe un `.opencode/plugins/`
equivalente (ver "Notas tecnicas" del issue #863) -- porque OpenCode ya tiene
algo mas fuerte: el `edit` deny-por-defecto del bloque `permission` (tabla de
arriba) **rechaza la escritura antes de que ocurra**, para cualquier ruta
fuera de `is_path_in_mefisto_scope`. En ambos runtimes, el gate final
(`validate_mefisto_scope_changes`, evaluado sobre `git diff`/`git status` al
cierre del stage) sigue siendo el juez -- ni el aviso posterior de Claude Code
ni el deny previo de OpenCode lo sustituyen (MEF-ADR-0031).

## Telemetria de herramientas (`--events-log`, issue #863)

`mefisto-run-agent.sh` acepta un flag separado, `--events-log <archivo>`
(default `mefisto_state_path events.log`), para la telemetria **legible**
del pipeline -- nunca confundir con `--event-log` (el JSONL neutral de este
contrato): son dos artefactos distintos, con nombres deliberadamente
parecidos por historia (`--event-log` es anterior, issue #858).

Por cada linea de `--event-log` que sea `tool.completed`, el runner agrega a
`--events-log` `[HH:MM:SS][tool] <agente> <tool> <ok|fail> <ruta-o-resumen|->`;
por cada `tool.started` **de un tool de archivo** (`edit`/`write`/`read`, sin
distinguir mayusculas: `Edit`/`Write`/`Read` en Claude Code, `edit`/`write`/
`read` en OpenCode) cuyo `input_summary` no sea `null`, agrega
`[HH:MM:SS][archivo] <ruta>` (mismo formato de linea que hoy produce el hook
publicado, `hooks/hooks.json`). `Bash`/`bash` tambien lleva `input_summary`
-- los primeros 80 caracteres del comando -- pero NO produce linea
`[archivo]`: un comando no es una ruta, y `/mefisto-work-status` lee ese tag
como actividad de archivos. Las lineas `[test]` y `[terraform]` del hook
publicado no tienen equivalente aqui: dependen del RESULTADO de un comando,
que el JSONL neutral no transporta. El evento terminal siempre agrega
`[HH:MM:SS][stage] <agente> <status>`. El `HH:MM:SS` de cada linea es el de
`.ts` del propio evento neutral (nunca el reloj de al escribir): asi la
telemetria es reproducible a partir del mismo `--event-log`. El
emparejamiento entre un `tool.completed` y el `input_summary` de su
`tool.started` es por nombre de tool en orden FIFO (el JSONL neutral no
conserva un id de llamada tras la traduccion); la "ruta-o-resumen" es `-`
cuando el tool no es de archivo ni `Bash`/`bash` -- nunca se inventa.

Un fallo al escribir `--events-log` (directorio inexistente, sin permisos)
degrada a un aviso en stderr: nunca altera el exit code del runner ni el
evento terminal que ya quedo escrito en `--event-log`.

Cuatro detalles de la semantica de 1.18.29 que condicionan la **forma** de los
patrones (verificados leyendo el bundle del binario; el mapping los repite en
su `$comment_semantica_verificada` para que sobrevivan a este README):

1. La evaluacion es `findLast(regla => match(permiso, regla.permiso) &&
   match(candidato, regla.patron))` con default `{action: "ask"}`. De ahi las
   dos reglas de diseno: catch-all primero (gana la ultima coincidencia) y
   **valor explicito en toda clave** -- lo que no matchea ninguna regla queda
   en `ask`, y `--auto` auto-aprueba todo `ask`. Una clave omitida no es un
   default seguro: es un permiso abierto.
2. El candidato de `bash` no es el nombre del programa sino el **texto
   completo de cada nodo `command`** del arbol tree-sitter (un candidato por
   comando de la tuberia, prefijo de asignaciones de entorno incluido). Por
   eso los coreutils llevan su forma desnuda ademas de `X *`, y los scripts
   del repo llevan la forma que emite `{{mefisto:run}}`. El anclaje al inicio
   del texto es deliberado en los `deny` (`rm *` no matchea `FOO=1 rm x`), asi
   que ningun `allow` empieza con un comodin que pueda absorber un prefijo de
   entorno arbitrario.
3. El candidato de `edit` y `read` es la **ruta relativa al worktree** en
   POSIX. Por eso los patrones de ruta son relativos; los que empiezan por `~`
   se expanden a `$HOME` y nunca casan con un candidato relativo -- quedan
   como defensa en profundidad, y lo que de verdad contiene el acceso fuera
   del worktree es `external_directory: deny`.
4. `write` y `patch` son **inertes** en 1.18.29: las tools `edit`, `write` y
   `apply_patch` preguntan todas bajo el permiso `edit`, que es el que manda.
   Se emiten igual (CA-1 pide valor explicito en todo el vocabulario, y si
   OpenCode separa las claves no quedan abiertas), con el mismo mapa de rutas
   que `edit` para que no puedan divergir.

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
imprimiendo una linea `<ruta>: faltante|distinta|huerfana|sin marcador` por
divergencia y saliendo con exit 1. *Huerfana* es un archivo **con** el marcador
cuya fuente ya no existe; *sin marcador* es un `.md` bajo `.claude/{agents,commands}`
u `.opencode/{agents,commands}` cuyo body no empieza por el marcador. Ambos son
divergencia: no queda ningun adaptador de autoria manual bajo esas rutas, asi
que la toleracion transitoria de #854 se retiro (issue #913, MEF-ADR-0049
decision 2).

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

Sin argumentos, valida todo `src/internal/{agents,commands}/*.md` (hoy los
cinco agentes internos de #865/#909 y los diez comandos internos de #866/#867).
Cada rechazo imprime una linea
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

`run_agent_with_watchdog` (issue #424, hoy en
`.claude/scripts/_mefisto-common.sh`) se reutiliza tal cual -- ya es neutral a runtime -- y el
runner la envuelve, traduciendo su senal de timeout a `run.failed{status:
"timeout"}`. El traslado de esa lib comun a `src/internal/scripts/` es
alcance de #869, no de este contrato.

### Anexo en vivo de eventos no terminales (issue #924)

Mientras el agente corre, el runner reanexa a `--event-log`, cada
`MEFISTO_RUN_AGENT_LIVE_INTERVAL` segundos (entero > 0, default 2; un valor
invalido cae al default con un aviso en stderr), los eventos **no
terminales** nuevos que produce `runtime_<id>_translate` sobre el raw log
parcial -- el mismo traductor que ya usa el cierre de la corrida, nunca un
traductor linea-a-linea aparte que pudiera divergir de el. `--event-log` es
**append-only durante toda la corrida**: nunca se trunca ni se reescribe, ni
en vivo ni al cierre.

El bucle vive en el proceso padre del runner (nunca dentro del `$(...)` que
envuelve a `run_agent_with_watchdog`) y fuera del grupo de procesos del
agente, para que el `kill -9 -"$pid"` del watchdog nunca lo alcance; se
detiene por archivo senal (nunca `kill`, para no cortar un `printf` de anexo
a mitad de escritura) antes de la traduccion final del cierre; el bucle
duerme el intervalo en rebanadas cortas y no en una sola pieza, para que esa
parada le cueste al cierre una fraccion de segundo y no un intervalo entero
de espera muerta por corrida. El cierre solo
anexa los no terminales que el bucle todavia no habia alcanzado a escribir
mas exactamente un evento terminal. Si el runner muere sin llegar a correr su
`trap EXIT` (un SIGKILL desde afuera) y por lo tanto sin dejar nunca la
senal, el bucle igual termina solo: comprueba en cada rebanada que el PID del
runner siga vivo, para no quedar huerfano anexando al `--event-log` de una
corrida que ya no existe. Es best-effort (MEF-ADR-0031): un fallo
de `jq`, un raw log todavia inexistente o un `--event-log` no escribible en
un tick nunca alteran el exit code del runner ni el evento terminal, que
siguen decidiendose exclusivamente al cierre. `run-events.schema.json` no
cambia: el vocabulario y la forma de cada evento son los mismos, solo cambia
CUANDO se anexan.

`lib/runtime-fake.sh` gana el guion `slow-success` (identico a `success` pero
con un `sleep ${MEFISTO_FAKE_STEP_DELAY_S:-2}` entre cada linea) para poder
ejercer este anexo en vivo contra el runner real sin depender de la latencia
de un CLI verdadero.

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
| `runtime_<id>_translate <raw_file> <runtime_id> <model> [<exit_code>] [<stderr_file>]` | Imprime por stdout, una linea JSON por evento, el JSONL neutral (`message`/`tool.*`/terminal) derivado de `<raw_file>`. **Nunca emite `run.started`** -- eso lo hace el runner directo, porque no depende de ningun dato especifico del adaptador. Los dos ultimos argumentos son **opcionales para el adaptador** (ignorarlos es una implementacion valida -- `runtime-fake.sh` lo hace) pero el runner **siempre los pasa**: sin el exit code y el stderr crudo no hay forma de clasificar una muerte por senal (`killed`, exit 137/143) ni el `API Error: <status>` que un CLI escribe solo por stderr (los dos canales siguen separados, #425), y el adaptador tendria que devolver `no_result` para desenlaces que si son distinguibles. |

`lib/runtime-fake.sh` (#858) reproduce guiones (exito, fallo con exit N,
cuelgue hasta timeout, sin evento terminal, dos terminales, JSON malformado,
`--model` recibido/omitido) via la variable de entorno `MEFISTO_FAKE_SCRIPT`,
para poder probar el runner sin invocar ningun CLI real.

`lib/runtime-claude.sh` + `lib/runtime-claude.jq` (#859) es el adaptador de
Claude Code: el **unico** lugar del repo, fuera de tests y fixtures, que
compone `claude -p` con `--permission-mode bypassPermissions`,
`--output-format stream-json --verbose`, `--append-system-prompt` (desde
`--system-file`) y `--model` (solo cuando el runner entrega un valor no
vacio), y el unico que conoce los nombres de evento de ese CLI (`is_error`,
`stop_reason`, `subtype`, `num_turns`, `api_error_status`). Su clasificacion
reproduce el orden de `classify_agent_failure`
(`.claude/scripts/_mefisto-common.sh`) y su criterio de exito el de
`agent_stream_completed_successfully`, de modo que la migracion del pipeline
(#869) no cambia ningun veredicto.

Esa paridad ya tiene un consumidor real: desde #906 `run_agent`
(`src/internal/scripts/mefisto-tooling-pipeline.sh`) traduce con
`runtime_claude_translate` la traza cruda de cada intento a
`<log_base>.events.jsonl` y las funciones de clasificacion de
`lib/_mefisto-common.sh` (`derive_stage_log_from_stream`,
`agent_stream_completed_successfully`, `agent_events_error_kind` /
`agent_events_error_detail`, `agent_failure_is_unrecoverable`,
`classify_agent_failure`) leen **solo** ese archivo -- la traza cruda queda
para diagnostico y ningun gate la parsea. Es un puente: la invocacion sigue
siendo `claude -p` directo hasta que #879 conecte el runner neutral.
`.claude/scripts/tests/test-runtime-claude.sh` lo ejerce contra una CLI
`claude` falsa puesta primero en el `PATH`.

`lib/runtime-opencode.sh` + `lib/runtime-opencode.jq` (#860) es el adaptador de
OpenCode, el runtime del dogfooding interno (MEF-ADR-0049 CA-5): el **unico**
lugar del repo, fuera de tests y fixtures, que compone `opencode run --agent
<id> --dir <cwd> --format json --auto` (mas `-m <modelo>` solo cuando el runner
entrega un valor no vacio) y que conoce los nombres de evento de ese CLI
(`step_start`, `step_finish`, `text`, `tool_use`). Tres diferencias con el
adaptador Claude Code condicionan todo lo demas:

1. **No hay flag equivalente a `--append-system-prompt`**: el `--system-file`
   se inyecta como **prefijo del mensaje** (`"<system>\n\n<prompt>"`), que
   viaja como unico argumento posicional -- misma restriccion de `ARG_MAX` que
   `claude -p "$prompt"`.
2. **No hay senal propia de exito/fallo** (nada equivalente a `is_error` /
   `subtype` / `stop_reason`), asi que la clasificacion completa depende del
   exit code y del stderr crudo que el runner siempre pasa. Su orden es:
   exito (exit 0 + texto visible) > `nonzero_exit` > `no_result` (stream
   vacio) > `protocol_invalid` (linea no-JSON) > `no_result` (exit 0 sin texto
   visible). `timeout` lo sigue sintetizando el runner.
3. **No hay evento `result` con el acumulado de la corrida**: cada
   `step_finish` reporta los tokens y el costo de SU paso, asi que el terminal
   los **suma** (quedarse con el ultimo reportaria el costo del cierre como si
   fuera el de la corrida entera, y `mefisto-metrics-report.sh` lo propaga a
   `cost_usd_total`). Ningun evento trae un id de modelo, asi que `model`
   degrada siempre al parametro que pidio el runner. `turns`, `denials`,
   `ttft_ms` y `api_duration_ms` son siempre `null`: este wire format no
   tiene equivalente.

Un `type` de evento no reconocido se **descarta** (nunca cuenta como exito, ni
se filtra al JSONL neutral); su cardinalidad se cuenta y se emite por el stderr
del propio programa `jq` (`raw_ignored=<n>`) y no como campo del terminal,
porque `run-events.schema.json` fija `additionalProperties: false` sobre
`run.completed`/`run.failed` y este contrato no cambia con la llegada de un
runtime nuevo.

El adaptador **no** lee, copia, valida ni menciona el almacen de credenciales
local de OpenCode ni ninguna variable de API key de proveedor: autenticacion y
disponibilidad del provider son responsabilidad exclusiva del CLI
(MEF-ADR-0049 CA-5), y `test-runtime-opencode.sh` lo verifica con un grep sobre
el propio adaptador. Ese test lo ejerce contra una CLI `opencode` falsa puesta
primero en el `PATH`, que reproduce capturas reales de **OpenCode 1.18.29**
congeladas en `.claude/scripts/tests/fixtures/runtime-opencode/*-1.18.29.jsonl`
(procedencia, comandos de captura y regla de "no editar un fixture viejo" en el
`README.md` de ese directorio). `--format json` esta documentado solo como "raw
JSON events" (<https://opencode.ai/docs/cli/>), sin especificacion estable: si
una version futura cambia el formato, se **agrega** un fixture con su version
en el nombre, nunca se edita el viejo.

### Vocabulario de eventos (`run-events.schema.json`)

Todo evento del JSONL neutral lleva `v: 1` y `type` (vocabulario cerrado en
el array `types` del schema):

| `type` | Campos propios |
|---|---|
| `run.started` | `ts`, `runtime`, `agent`, `model\|null`, `cwd` |
| `message` | `ts`, `role`, `text`, `kind?: "text"\|"thinking"` |
| `tool.started` | `ts`, `tool`, `input_summary\|null` |
| `tool.completed` | `ts`, `tool`, `ok`, `duration_ms\|null` |
| `run.completed` / `run.failed` | `status`, `runtime`, `model\|null`, `session_id\|null`, `duration_ms`, `tokens {input\|null, output\|null}`, `cost_usd\|null`, `turns\|null`, `denials\|null`, `ttft_ms\|null`, `api_duration_ms\|null`, `error\|null` |

El vocabulario de `status` de CA-4 esta **partido entre los dos terminales**:
`run.completed` solo admite `success` y `run.failed` admite `failed`,
`timeout` y `protocol_invalid`. Asi un `run.completed{status:"timeout"}` es
irrepresentable -- la tabla de exit codes de la seccion siguiente no sabria
puntuarlo, y un gate que leyera solo `.type` y otro que leyera solo `.status`
llegarian a veredictos distintos sobre la misma corrida.

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
Los eventos **no terminales** (`message`, `tool.*`) se conservan siempre,
tambien tras un timeout: son hechos completos y ya ocurridos, y son la
evidencia con la que se diagnostica donde se colgo la corrida.

El `timeout` de la tercera fila exige **dos evidencias coincidentes**: la senal
que deja el watchdog en disco y el reloj de pared que el runner mide alrededor
de la invocacion completa (`ELAPSED_S >= --timeout`). La senal sola no alcanza:
el watchdog de `run_agent_with_watchdog` duerme y despues hace `touch`, asi que
un `sleep` que no llegue a dormir (una maquina cargada que no puede forkearlo)
deja la senal puesta en el mismo instante en que arranco. Se observo bajo carga:
corridas con la senal presente, `elapsed=0` y `--timeout 1800`, clasificadas
como TIMEOUT sin haber esperado nada. El corte por reloj no puede descartar un
timeout real -- con segundos truncados el elapsed medido nunca queda por debajo
de la duracion real, y una corrida que el watchdog mato duro al menos el
timeout -- pero si descarta las senales que el reloj desmiente, que es lo que
MEF-ADR-0031 pide de un gate: decidir por estado verificable, no por un unico
indicio.

La primera fila de la tabla lee "el adaptador declaro exito" y no "el proceso
salio con cero" a proposito: si el runtime alcanzo a declarar que cumplio su
contrato, un exit distinto de cero o una senal **posteriores** a esa
declaracion no invalidan el trabajo, y el terminal sigue siendo
`run.completed{status:"success"}` (opcionalmente con constancia de esa muerte
en `error`). Es la misma excepcion que el pipeline ya aplica desde el PR #446
(`agent_failure_is_unrecoverable` en `.claude/scripts/_mefisto-common.sh`),
trasladada al contrato neutral en vez de re-derivada por cada consumidor.

### Fixtures (`fixtures/run-events/`)

`valid-*.jsonl` son corridas completas (con `run.started` y exactamente un
terminal) que validan linea a linea. `invalid-two-terminals.jsonl` es
**valido linea a linea** -- cada `run.completed`/`run.failed` individual
cumple su schema -- pero viola la invariante cross-linea de la seccion
anterior (2 terminales): documenta que ese invariante no lo puede expresar
`run-events.schema.json` por si solo, hace falta contarlos.
`invalid-missing-field.jsonl`, `invalid-unknown-type.jsonl` e
`invalid-status-mismatch.jsonl` si son rechazables linea a linea (campo
requerido ausente; `type` fuera de `types`; `run.completed` declarando un
`status` que solo `run.failed` admite).
`.claude/scripts/tests/test-mefisto-run-agent.sh` corre el runner
real contra cada guion de `runtime-fake.sh` y valida ambas dimensiones a la
vez sobre su propia salida.

## Abrir Mefisto con OpenCode (issue #868)

Config raiz para que el checkout del propio plugin -- rama principal o
cualquier worktree -- cargue localmente sus agentes/comandos internos con
OpenCode, sin instalar el plugin publicado ni fijar proveedor/modelo
(MEF-ADR-0049 CA-5). `opencode.json`, en la raiz del repo, es la unica pieza
de configuracion de proyecto que introduce este issue:

```json
{
  "$schema": "https://opencode.ai/config.json"
}
```

- **Sin `plugin`**: el scope temprano en OpenCode no necesita un
  `.opencode/plugins/*.js` -- lo cubre el `edit` deny-por-defecto del bloque
  `permission` por agente (MEF-ADR-0049 decision 5, issue #863, ver "Scope
  temprano en OpenCode" arriba); no hay razon para declarar `plugin` aqui
  tampoco.
- **Sin `instructions`**: verificado contra la doc publica
  (<https://opencode.ai/docs/rules/>) y confirmado leyendo el binario OpenCode
  1.18.29 (mismo criterio de verificacion que el resto de este contrato):
  `Instruction.systemPaths` recorre los candidatos de proyecto
  `["AGENTS.md", "CLAUDE.md", "CONTEXT.md"]` y corta (`break`) en el primero
  con alguna coincidencia, de modo que la resolucion es "el primero que existe
  gana" -- si `AGENTS.md` esta presente, `CLAUDE.md` **ni se lee** -- no una
  carga aditiva de ambos archivos. La evidencia queda registrada en
  `docs/testing/agents-md-shim-smoke.md`. Como este repo ya tiene `AGENTS.md` como fuente canonica
  (MEF-ADR-0049 decision 3, issue #855), declarar `instructions: ["AGENTS.md"]`
  seria redundante: OpenCode ya lo descubre por convencion, sin config
  explicita. Si una version futura de OpenCode cambiara esa precedencia a
  aditiva, `instructions: ["AGENTS.md"]` acotaria la carga a un solo archivo.
- **Sin `provider`, `model`, `permission` global, tokens ni rutas al auth
  store**: el runtime resuelve proveedor/modelo desde la config global del
  usuario (`~/.config/opencode/opencode.json`, fuera de este repo) y las
  credenciales por su cuenta (MEF-ADR-0049 decision 5); los permisos van por
  agente (`permission` en cada `.opencode/agents/*.md` generado, issue #862),
  nunca a nivel de proyecto.
- **`MEFISTO_RUNTIME` no vive aqui**: `opencode.json` no tiene mecanismo de
  entorno. Lo antepone cada comando generado en el momento de invocar un
  script (`{{mefisto:run}}`, issue #867): `MEFISTO_RUNTIME=opencode
  ./.claude/scripts/<script>`.

### Que descubre OpenCode al abrir este repo

Sin ninguna instalacion adicional, OpenCode 1.18.29 descubre en la raiz (o en
cualquier worktree):

| Ruta | Contenido |
|---|---|
| `.opencode/agents/*.md` | Agentes internos generados (#865): hoy `mefisto-{planner,investigator,historiador}` |
| `.opencode/commands/*.md` | Los diez comandos internos generados (#866/#867), disponibles como `/mefisto-*` |
| `AGENTS.md` | Directivas canonicas del repo (MEF-ADR-0049 decision 3) |
| `.claude/skills/*/SKILL.md` | Agent Skills internos, ruta Claude-compatible que OpenCode ya reconoce nativamente (MEF-ADR-0049 seccion 2) |

`opencode agent list` lista los agentes; `opencode debug config` expone el
resto de la config resuelta (comandos incluidos, bajo `.command`).

Claude Code, en el mismo checkout, sigue sin leer `opencode.json`: sus
adaptadores (`.claude/agents/`, `.claude/commands/`, `CLAUDE.md` via el shim
`@AGENTS.md`) son independientes de esta config (CA-6) -- `scripts/tests/test-guards.sh`
y `.claude/scripts/tests/test-agents-md-shim.sh` lo verifican.

### Chequeo local

```bash
.claude/scripts/tests/test-opencode-discovery.sh
```

Valida, sin invocar ningun modelo: las fuentes neutrales de agentes/comandos
(`validate-internal-artifacts.sh`), que el generador este en `--check` (sin
divergencias entre fuente y adaptadores versionados), que `opencode.json` y
`AGENTS.md` existan, que `opencode.json` no declare mas claves que `$schema`
(ni `plugin`/`provider`/`model`/`permission`/tokens/API keys/auth store), que
ningun comando de ejecucion que use `{{mefisto:run}}` pierda el prefijo
`MEFISTO_RUNTIME=opencode`, y que cada agente traiga su bloque `permission`
con `external_directory` en `deny`. Si el CLI `opencode` esta instalado,
ademas corre `opencode agent list` y `opencode debug config` para confirmar
el descubrimiento real; si no, omite esos pasos con un aviso.

## Workspace herdr con el runtime activo (issue #875)

`scripts/herdr-workspace.sh` (publicado, issue #691) abre el workspace de dos
panes (`planner` + `ejecucion`) que da acceso al resto de este contrato. Solo
su rama Mefisto (deteccion por `.claude-plugin/plugin.json`, igual que
`planner_agent_for_repo`) honra `MEFISTO_RUNTIME`: ambos panes arrancan con
`herdr agent start --kind "${MEFISTO_RUNTIME:-claude}"` y heredan
`MEFISTO_RUNTIME` (y `MEFISTO_MODELS_FILE` si esta definida) en su entorno via
`--env` de `herdr workspace create`/`herdr pane split` -- el script nunca fija
provider, modelo ni credenciales, ni lee `opencode.json` o un auth store. La
rama consumidor no cambia: el runtime sigue siendo siempre Claude Code, y un
`MEFISTO_RUNTIME` distinto de `claude` se ignora con un aviso.

Ese `--env` es lo que cierra el lazo con `mefisto-herdr-pipeline.sh` (#872,
seccion "`mefisto-herdr-pipeline.sh`" mas arriba): al despachar `/mefisto-
tooling` o `/mefisto-batch` desde el pane de ejecucion, ese script lee
`MEFISTO_RUNTIME`/`MEFISTO_MODELS_FILE` del entorno del PROPIO pane (heredado
al crearlo) y los antepone como asignacion de entorno al comando que despacha
en el pane run (su `ENV_PREFIX`), de donde el sub-pipeline los hereda como
cualquier proceso hijo -- sin que `herdr-workspace.sh` necesite conocer nada
de ese runner. Smoke documental (sin depender de un servidor herdr real): con
`MEFISTO_RUNTIME=opencode` fijado antes de abrir el workspace, un pane de
ejecucion recien creado reporta `echo $MEFISTO_RUNTIME` -> `opencode`, y
`mefisto-herdr-pipeline.sh --tooling <issue>` corrido ahi antepone
`MEFISTO_RUNTIME=opencode` al comando del pane run, de modo que
`mefisto-tooling-pipeline.sh` corre con ese runtime sin que el humano lo haya
fijado a mano en ese pane.
`scripts/tests/test-herdr-workspace.sh` cubre el `--kind`/`--env` de
`herdr-workspace.sh` con un stub de `herdr`;
`.claude/scripts/tests/test-mefisto-herdr-pipeline.sh` (bloques 1-5) cubre por
separado que `mefisto-herdr-pipeline.sh` reenvia esas mismas variables al pane
run -- ningun test corre ambos scripts encadenados contra un servidor herdr
real.

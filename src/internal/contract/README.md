# Contrato neutral de agentes y comandos internos (`src/internal/contract/`)

Fuente de verdad del formato que todo agente/comando de
`src/internal/{agents,commands}/` debe cumplir (MEF-ADR-0049 CA-6, issue
#853). Es la **interfaz canonica del generador de adaptadores** (issue #854,
todavia sin implementar): el generador consumira estos archivos `.md` y
producira `.claude/agents/*.md` + `.opencode/agent/*.md` (y sus equivalentes
de comando). **No es un formato para que un proyecto consumidor lo adopte**:
vive enteramente del lado interno del propio plugin Mefisto (MEF-ADR-0019).

Este issue (#853) no migra ningun agente ni comando real de
`.claude/{agents,commands}/` a este formato (eso es alcance de #865-#867) ni
implementa el generador (#854): solo fija el contrato y su validador.

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

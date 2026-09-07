---
name: agent-skill-authoring
description: Notas operativas para definir o modificar agentes y comandos -- fuente neutral `src/internal/{agents,commands}/*.md` regenerada con `generate-internal-adapters.sh` para el lado interno, `agents/*.md`/`commands/*.md` de Claude Code para el lado publicado -- y Agent Skills (`skills/<nombre>/SKILL.md`, `.claude/skills/<nombre>/SKILL.md`) del propio plugin Mefisto: el frontmatter portable obligatorio de todo `SKILL.md` (`allowed-tools` prohibido), la declaracion de tools MCP en allowlists Claude Code y su prefijo scoped cuando el servidor lo provee un plugin, el mapeo `capabilities`/`profile` del contrato neutral hacia cada adaptador (Claude Code, OpenCode), y el checklist para agregar el adaptador de un runtime nuevo sin tocar la fuente neutral (MEF-ADR-0050). Usar al crear o editar un agente, un comando o un Skill de este repo.
---

# Notas para definir agentes y skills

## Regla de oro: la fuente neutral primero (MEF-ADR-0050)

Los agentes y comandos **internos** (prefijo `mefisto-`, MEF-ADR-0019) se escriben **solo** en
`src/internal/{agents,commands}/<id>.md`: frontmatter JSON del contrato (`kind`, `id`,
`description`, `capabilities` en vez de `tools`, `profile` en vez de `model`, mas
`mode`/`agent`/`arguments` segun aplique) y un body que nunca nombra `claude` ni `opencode` (el
validador rechaza esa linea). Se regeneran con `src/internal/scripts/generate-internal-adapters.sh`.
**Nunca se edita a mano** `.claude/{agents,commands}/*.md` ni `.opencode/{agents,commands}/*.md`
-- son adaptadores generados; una edicion manual se pierde en la siguiente regeneracion y
`--check` la reporta como divergencia. Contrato completo (campos, vocabularios cerrados, mapeo
por runtime): `src/internal/contract/README.md`.

Esta regla es **solo del lado interno**. El lado publicado (`agents/*.md`, `commands/*.md`)
todavia no tiene fuente neutral propia -- MEF-ADR-0049 lo difiere a #874 (rollout
interno-primero) -- asi que se sigue editando directamente en formato Claude Code (frontmatter
YAML, `tools:`, `skills:`); ver la subseccion especifica de Claude Code mas abajo. La regla de
no-regresion de MEF-ADR-0050 (seccion 1) aplica igual a lo nuevo que se agregue ahi: ningun
script publicado nuevo invoca el CLI de un runtime, y ningun `SKILL.md` publicado nuevo usa
frontmatter no portable.

## Agent Skills (ambos lados)

Frontmatter de todo `SKILL.md` portable -- publicado (`skills/<nombre>/SKILL.md`) o interno
(`.claude/skills/<nombre>/SKILL.md`) -- limitado a los cinco campos del estandar abierto: `name`,
`description`, `license`, `compatibility`, `metadata` [1]. **`allowed-tools` prohibido**: es una
extension *Experimental* de Claude Code que OpenCode **ignora en silencio** [2] -- un Skill que
dependiera de ese campo para restringir que tools puede invocar al dispararse degradaria sin
ninguna senal bajo OpenCode. La regla F5 del bloque `[F]` de `scripts/tests/test-guards.sh` lo
verifica (MEF-ADR-0050 seccion 3, issue #937).

- `name` = nombre del directorio, patron `^[a-z0-9]+(-[a-z0-9]+)*$` (la spec no admite `:`; F1 ya
  verifica esta igualdad).
- Recursos de **Nivel 3** (scripts, plantillas que el body invoca bajo demanda): solo bash + jq +
  gh -- el mismo toolchain que el resto del harness (MEF-ADR-0049 seccion 6), nunca Node, Python
  ni un binario que no este ya disponible en cualquier maquina que corra los pipelines de Mefisto.
- Ubicacion: `.claude/skills/` (interno) o `skills/` (publicado). `.claude/skills/` es la
  **unica** ruta fisica que ambos runtimes leen -- Claude Code y OpenCode descubren el mismo
  `SKILL.md` sin traduccion ni copia [3][2] -- por eso no hay generador para Skills, a diferencia
  de agentes/comandos.
- Doctrina extensa que solo aplica a algunas tareas: envolverla en un Agent Skill en vez de crecer
  el body de un agente (progressive disclosure, MEF-ADR-0033) -- se carga por niveles y no se
  paga cuando la tarea no lo necesita. Si el propio Skill crece mas alla del presupuesto de Nivel
  2 (<5k tokens), mover el detalle a un recurso de Nivel 3 dentro del mismo directorio en vez de
  seguir inflando el body.

## Nuevo runtime = nuevo adaptador

El conjunto de runtimes soportados es abierto: "soportado" significa unicamente "tiene adaptador
en el repo" (MEF-ADR-0050 seccion 1). Agregar el runtime `<id>` nunca edita
`src/internal/{agents,commands}/*.md` -- solo maquinaria de adaptacion (checklist completo de
diez pasos, con el archivo exacto de cada uno: MEF-ADR-0050 seccion 2):

1. `src/internal/scripts/lib/runtime-<id>.sh` (+ `.jq` si el runtime emite un wire format propio
   que traducir) y `adapter-<id>.sh` (traduce las directivas `{{mefisto:...}}` del contrato y
   expone `adapter_<id>_default_model`).
2. Cableado en `generate-internal-adapters.sh` (incluido su `--check`) y en
   `mefisto_resolve_runtime` (`lib/mefisto-runtime.sh`).
3. Entradas espejo en las dos allowlists de scope: `is_path_in_mefisto_scope` (interno) e
   `is_path_in_consumer_blocklist` (publicado).
4. Excepcion en `neutrality-allowlist.json` si el adaptador necesita nombrar su propio runtime en
   texto.
5. Tests: `test-runtime-<id>.sh` (contrato del adaptador) + cobertura de discovery equivalente a
   `test-opencode-discovery.sh`.

## Especifico del adaptador Claude Code -- lado publicado

- Las herramientas MCP requieren declaracion explicita cuando un agente usa allowlist `tools:`.
  Usa wildcard: `mcp__<servidor>__*`.
- Cuando el servidor MCP lo provee un **plugin** (declarado en `.mcp.json` en la raiz del plugin,
  propio o de terceros), el nombre real de sus tools va scoped con el prefijo del plugin, asi que
  la allowlist se escribe `mcp__plugin_<plugin>_<servidor>__*`, no `mcp__<servidor>__*`. Fuente:
  [4] -- *"Tool matchers and `if` fields take the scoped tool name
  `mcp__plugin_<plugin-name>_<server-name>__<tool>` ... A matcher written against the bare server
  key never fires"*. Ejemplo: el servidor `microsoft-learn` bundleado por este plugin (`mefisto`)
  se declara en `.mcp.json` y se referencia en `tools:` como
  `mcp__plugin_mefisto_microsoft-learn__*`.
- Si el agente **no** define `tools:`, hereda todas incluyendo MCP.
- Un agente publicado precarga un Agent Skill con el campo frontmatter `skills:` (no requiere la
  tool `Skill` en `tools:`).

## Especifico del adaptador OpenCode -- lado interno

Nunca se hand-authorea: es lo que `generate-internal-adapters.sh` produce en
`.opencode/{agents,commands}/*.md` a partir del contrato neutral. Util para escribir
`capabilities`/`profile` en la fuente sabiendo a que se traducen:

- `capabilities` -> bloque `permission` deny-por-defecto (17 claves, mapping declarativo
  `src/internal/contract/opencode-permissions.json`) -- nunca `tools:` ni `allowed-tools`, que
  OpenCode no tiene.
- Un comando enruta a su agente con frontmatter `agent: <id>` + `subtask: true` (campo neutral
  `agent` del comando) -- OpenCode no tiene namespace de plugin, asi que no hay un equivalente
  directo a un comando "de plugin".
- **Sin `skills:`**: OpenCode no tiene ese campo de frontmatter de agente; un Agent Skill se
  dispara solo por su `description` via la tool nativa `skill` (misma mecanica de progressive
  disclosure, distinto punto de enganche que Claude Code).
- `profile` no resuelve a ningun `model:` fijo en este adaptador -- OpenCode siempre hereda el
  modelo activo de la sesion salvo mapping local (`mefisto_resolve_model`), a diferencia de la
  tabla fija de Claude Code (`fast`->`haiku`, `balanced`->`sonnet`).

Mapeo completo campo-a-campo, incluidas las directivas de body (`{{mefisto:launch-agent}}`,
`{{mefisto:run}}`, `{{mefisto:command-path}}`): `src/internal/contract/README.md`.

## Fuentes

- **[1]** "Agent Skills Specification" -- agentskills.io. Fija los seis campos de frontmatter
  reconocidos, marca `allowed-tools` como *Experimental* y fija el patron
  `name: ^[a-z0-9]+(-[a-z0-9]+)*$`. Verificado (fetch HTTP, 2026-09-06).
  https://agentskills.io/specification
- **[2]** "Skills" -- OpenCode Docs. Confirma los cinco campos que OpenCode reconoce (sin
  `allowed-tools`), la cita *"Unknown frontmatter fields are ignored"*, y que sus rutas de
  descubrimiento incluyen la ruta Claude-compatible `.claude/skills/<name>/SKILL.md`. Verificado
  (fetch HTTP, 2026-09-06). https://opencode.ai/docs/skills/
- **[3]** "Using skill frontmatter outside Claude Code" -- Claude Code Docs. Tabla de campos
  estandar vs extensiones propias de Claude Code, y las ubicaciones que Claude Code reconoce
  (`.claude/skills/`, `<plugin>/skills/` -- nunca `.agents/skills/`). Verificado (fetch HTTP,
  2026-09-06). https://code.claude.com/docs/en/skills#using-skill-frontmatter-outside-claude-code
- **[4]** "Plugins reference" -- Claude Code Docs. Fija el prefijo scoped
  `mcp__plugin_<plugin-name>_<server-name>__<tool>` para tools MCP provistas por un plugin.
  Verificado (fetch HTTP, 2026-09-06). https://code.claude.com/docs/en/plugins-reference
- MEF-ADR-0050 (principio de neutralidad de runtime): fuente de la regla de oro, el frontmatter
  portable de `SKILL.md` y el checklist de adaptador nuevo.
- MEF-ADR-0049 (arquitectura neutral runtime/proveedor): fuente del layout `src/internal/` +
  adaptadores generados, los perfiles `fast|balanced|deep` y el toolchain bash+jq.
- `src/internal/contract/README.md`: contrato completo del generador (campos, vocabularios
  cerrados, mapeo por runtime, permisos de OpenCode).

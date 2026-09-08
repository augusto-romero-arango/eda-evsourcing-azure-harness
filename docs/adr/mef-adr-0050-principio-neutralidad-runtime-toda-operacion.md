# MEF-ADR-0050: Principio de neutralidad de runtime para toda operacion de Mefisto

- **Fecha**: 2026-09-06
- **Estado**: aceptado
- **Aplica a**: todo artefacto de Mefisto -- skill/comando, agente, pipeline bash, hook y Agent Skill -- en ambos lados de MEF-ADR-0019 (publicado e interno). Generaliza MEF-ADR-0049 (que fija la arquitectura concreta del rollout interno: fuente `src/internal/` + adaptadores generados, perfiles de modelo, toolchain bash+jq) a un principio transversal, sin reemplazarlo. Cross-referencia MEF-ADR-0049 (arquitectura que este ADR generaliza), MEF-ADR-0033 (Agent Skills: fija aqui el frontmatter portable de `SKILL.md`), MEF-ADR-0019 (publicado vs interno: el principio aplica a ambos lados) y MEF-ADR-0030 (esquema de identificacion, fija el numero `0050` como libre).

**Issues bloqueados por este ADR**: #937 (regla F5, frontmatter portable de `SKILL.md`, en el bloque `[F]` de `scripts/tests/test-guards.sh`), #938 (reescritura neutral del skill interno `agent-skill-authoring`).

## Contexto

MEF-ADR-0049 fijo la *arquitectura* neutral del lado interno -- fuente `src/internal/` + adaptadores generados, dos runtimes concretos (OpenCode como dogfooding, Claude Code como runtime compatible, Pi descartado) -- y difirio el lado publicado a un ADR posterior (#874). Ese ADR deja tres cabos sueltos que hoy generan deuda:

1. **No existe un principio transversal.** Nada obliga a que una operacion nueva nazca neutral. Una recomendacion externa reciente (Claude Insights) propuso crear `.claude/skills/next-order/SKILL.md` con frontmatter especifico de Claude Code -- perfectamente valido segun MEF-ADR-0049 (que exime `.claude/skills/` de la generacion) y sin embargo inutil como slash command bajo OpenCode, donde los Skills se cargan via la tool `skill`, no como `/comando`.
2. **`.claude/skills/` quedo fuera de la fuente neutral "porque no la necesita"**, con la degradacion silenciosa del frontmatter no portable anotada como riesgo y delegada a "un ADR de seguimiento" (MEF-ADR-0049 decision 2, tercer punto). Este ADR es ese seguimiento.
3. **El conjunto de runtimes se trato como cerrado** (dos nombres). El mantenedor quiere abrirlo: manana puede aparecer otro runtime del mercado, y agregarlo debe ser *solo* escribir un adaptador, nunca tocar la fuente neutral.

Ademas, `mefisto-writer` y `mefisto-reviewer` (los dos agentes del pipeline interno de tooling que producen y revisan cambios sobre el propio repo) tienen **cero** menciones de neutralidad en su fuente: hoy el gate de neutralidad (issue #923, `mefisto-neutrality-gate.sh`) los frena post-hoc si violan alguna regla, pero ninguno de los dos conoce la regla de antemano. `AGENTS.md` -- el archivo de directivas canonicas que ambos runtimes cargan (MEF-ADR-0049 decision 3) -- es el vehiculo natural para que la conozcan sin tocar sus fuentes.

Estas decisiones se tomaron en la sesion de planeacion del 2026-09-06 y este ADR las fija formalmente.

### Alcance

Este ADR fija un **principio** valido para toda operacion de Mefisto, en ambos lados de MEF-ADR-0019: que nace neutral a runtime, que el conjunto de runtimes soportados es abierto, cual es el punto de extension verificable para un runtime nuevo, cual es el frontmatter portable obligatorio de todo `SKILL.md`, como se nombra un artefacto publicado en cualquier runtime, y como se verifica "agnostico" contra los gates que ya existen.

### Que queda fuera de este ADR

- **La implementacion del adaptador OpenCode del lado publicado y su distribucion** (#874): este ADR fija la regla de no-regresion que rige mientras tanto, no la implementacion.
- **La migracion de `.claude/skills/` a fuente generada**: se descarta explicitamente mientras ambos runtimes lean el mismo archivo fisico (ver decision 3) -- no hay divergencia que un generador resuelva.
- **La mecanica concreta de generacion, validacion y adaptadores** (`src/internal/scripts/generate-internal-adapters.sh`, `validate-internal-artifacts.sh`, `mefisto-neutrality-gate.sh`): ya vive en MEF-ADR-0049 y en el contrato (`src/internal/contract/README.md`). Este ADR los referencia, no los reabre.

## Decision

### 1. Toda operacion nace neutral; el conjunto de runtimes es abierto (CA-1)

Toda operacion de Mefisto -- skill (`commands/`, `.claude/commands/`), agente (`agents/`, `.claude/agents/`), pipeline bash (`scripts/`, `.claude/scripts/`), hook (`hooks/`, `.claude/settings.json`) y Agent Skill (`skills/`, `.claude/skills/`) -- en ambos lados de MEF-ADR-0019, es neutral a runtime. Ninguna pieza nueva de doctrina, comportamiento o automatizacion asume que Claude Code (ni ningun otro runtime concreto) es el unico interprete posible.

El conjunto de runtimes soportados es **abierto**, no una enumeracion cerrada de dos nombres: "runtime soportado" significa unicamente **"tiene adaptador en el repo"** -- hoy Claude Code (`.claude/`) y OpenCode (`.opencode/`), los dos verificados end-to-end por MEF-ADR-0049. Agregar un tercer runtime del mercado manana es, por definicion de este principio, escribir el adaptador que describe la decision 2 -- nunca tocar la fuente neutral de un artefacto ya existente.

**Regla de no-regresion en el lado publicado**, vigente mientras siga siendo, como hoy, un unico Claude Code Plugin (hasta que #874 resuelva su distribucion multi-runtime): ningun artefacto publicado nuevo agrega acoplamiento adicional a un runtime concreto. Dos ejemplos concretos:

- Un `scripts/*.sh` publicado nuevo no invoca el CLI de un runtime (`claude`, `opencode`) si puede evitarlo -- el mismo criterio que la regla R2 de `mefisto-neutrality-gate.sh` ya aplica a todo su universo de archivos (`src/internal/`, `.claude/`, `.opencode/`, `AGENTS.md`, `opencode.json`), aunque ese universo no incluya `scripts/` -- el arbol publicado entero esta declarado fuera de alcance en `scope_excluded` de `neutrality-allowlist.json`.
- Un `skills/*/SKILL.md` publicado nuevo usa unicamente el frontmatter portable que fija la decision 3 (`name`, `description`, `license`, `compatibility`, `metadata`) -- nunca `allowed-tools` ni otra extension propia de Claude Code -- aunque hoy solo Claude Code cargue Skills publicados via marketplace.

### 2. Punto de extension de un runtime nuevo: checklist verificable, sin tocar la fuente neutral (CA-2)

Agregar el runtime `<id>` (hoy `claude`/`opencode`; manana cualquier otro) es, exhaustivamente, esta lista -- ningun paso edita `src/internal/{agents,commands}/*.md`, la fuente neutral de doctrina: todo lo que se toca es maquinaria de adaptacion.

| Paso | Archivo/mecanismo a crear | Ya implementado hoy para |
|---|---|---|
| 1 | `src/runtime/lib/runtime-<id>.sh` (`runtime_<id>_build_cmd`, `runtime_<id>_translate` y, opcionalmente, `runtime_<id>_default_model`; contrato en `src/runtime/contract/README.md`) | `runtime-claude.sh`, `runtime-opencode.sh` |
| 2 (solo si el runtime emite un wire format propio que traducir al JSONL neutral) | `src/runtime/lib/runtime-<id>.jq` | `runtime-claude.jq`, `runtime-opencode.jq` |
| 3 | `src/internal/scripts/lib/adapter-<id>.sh`: traduce las directivas `{{mefisto:...}}` del contrato neutral; mientras el generador interno no migre, puede envolver sin duplicar `runtime_<id>_default_model` | `adapter-claude.sh`, `adapter-opencode.sh` |
| 4 | Cableado del adaptador nuevo en `src/internal/scripts/generate-internal-adapters.sh`: exigirlo entre sus librerias requeridas, emitir `.<id>/{agents,commands}/*.md` junto a los destinos ya existentes, e incluir ese arbol en el barrido de divergencia de `--check` | las ramas `.claude/` y `.opencode/` del generador |
| 5 | Rama de autodeteccion en `mefisto_resolve_runtime` (`src/internal/scripts/lib/mefisto-runtime.sh`) | ramas `has_claude`/`has_opencode` |
| 6 | Entrada en `is_path_in_mefisto_scope` (`src/internal/scripts/lib/_mefisto-common.sh`) | entradas `.claude/*`, `.opencode/*` |
| 7 | Entrada en el blocklist publicado `is_path_in_consumer_blocklist` (`scripts/_pipeline-common.sh`) | mismas rutas, lado espejo |
| 8 | Entrada(s) en `src/internal/contract/neutrality-allowlist.json` si el adaptador nuevo necesita nombrar su propio runtime en texto (mismo patron que las excepciones ya declaradas para `adapter-claude.sh`/`adapter-opencode.sh`) | seccion `exceptions` del archivo |
| 9 | Soporte del kind `<id>` en el propio Herdr, si un pipeline orquesta ese runtime en un pane: `runtime_kind_for_repo` (`scripts/herdr-workspace.sh`) ya reenvia `MEFISTO_RUNTIME` tal cual como `--kind`, asi que del lado de Mefisto no hay nada que editar -- solo verificar que Herdr reconozca ese kind | `--kind claude`, `--kind opencode` |
| 10 | Tests: `test-runtime-<id>.sh` (contrato del adaptador) + cobertura de discovery equivalente a `test-opencode-discovery.sh` | `.claude/scripts/tests/test-runtime-claude.sh`, `test-runtime-opencode.sh`, `test-opencode-discovery.sh` |

### 3. Frontmatter portable de todo `SKILL.md` (CA-3)

Todo `SKILL.md` del repo -- publicado (`skills/<nombre>/SKILL.md`) o interno (`.claude/skills/<nombre>/SKILL.md`) -- declara **unicamente** los cinco campos que el estandar abierto define y que OpenCode reconoce: `name`, `description`, `license`, `compatibility`, `metadata` [1][2]. Los cuatro `SKILL.md` existentes en el repo (`skills/projections`, `skills/comment-cleanup`, `.claude/skills/harness-config-contract`, `.claude/skills/agent-skill-authoring`) ya cumplen esto -- ninguno declara un campo fuera de esa lista.

**`allowed-tools` queda prohibido.** Es una extension de Claude Code marcada *Experimental* en la especificacion abierta [1] y que OpenCode **ignora en silencio** -- "Unknown frontmatter fields are ignored" [2]. Un Skill que dependa de `allowed-tools` para su seguridad (p. ej. para restringir que herramientas puede invocar al dispararse) degrada sin ninguna señal bajo OpenCode: el Skill carga igual, pero la restriccion nunca se aplica.

Los **recursos de Nivel 3** (scripts, plantillas, referencias que el body de un `SKILL.md` invoca bajo demanda) se restringen al mismo toolchain que el resto del harness: bash + jq + gh (coherente con el toolchain que fija MEF-ADR-0049 seccion 6), nunca Node, Python ni un binario que no este ya disponible en cualquier maquina que corra los pipelines de Mefisto.

**`.claude/skills/` sigue siendo la unica ubicacion fisica que ambos runtimes cargan** -- verificado: Claude Code descubre Skills de proyecto en `.claude/skills/<skill-name>/SKILL.md` y de plugin en `<plugin>/skills/<skill-name>/SKILL.md`, nunca en `.agents/skills/` [3]. No hay una ubicacion neutral tercera a la que migrar; MEF-ADR-0049 decision 2 acierta al no generar hacia esa ruta, y este ADR no reabre esa decision (ver "Que queda fuera").

Con esta decision, **MEF-ADR-0049 decision 2 deja de decir "un ADR de seguimiento decidira"**: el frontmatter portable ya queda fijado aqui. El cuerpo de MEF-ADR-0049 se actualiza en consecuencia (sin texto marcado como obsoleto: la mencion al ADR de seguimiento se reemplaza por la remision a MEF-ADR-0050, y el control de cambios de MEF-ADR-0049 registra la enmienda).

### 4. Namespace `mefisto`: intencion neutral, separador por adaptador (CA-4)

Todo artefacto publicado invocable lleva la intencion neutral de namespace `mefisto`, sea cual sea el runtime que lo interprete. Como se materializa ese namespace es una decision de **cada adaptador**, no de la fuente neutral:

- **Claude Code**: namespace nativo del plugin (`/mefisto:sequential`).
- **Runtimes sin concepto de plugin** (OpenCode hoy; cualquier otro futuro sin esa primitiva): separador **`:`** literal en el nombre del comando, produciendo el mismo `/mefisto:sequential` visible para el consumidor.

Esto preserva la distincion ya vigente entre `mefisto:` (publicado, namespace de plugin/separador) y `mefisto-` (interno, prefijo llano de MEF-ADR-0019). Los **Agent Skills** publicados, en esos mismos runtimes sin plugin, llevan en cambio el prefijo llano **`mefisto-`** -- nunca `:` -- porque la especificacion abierta fija el `name` de un Skill con el patron `^[a-z0-9]+(-[a-z0-9]+)*$` [1], que no admite `:`. El adaptador que scaffoldee ese Skill para un runtime sin plugin renombra a la vez el directorio y el campo `name` (p. ej. `skills/projections/` -> `mefisto-projections` en ese adaptador), nunca uno sin el otro.

**Evidencia empirica registrada** (OpenCode 1.18.29, verificado por el mantenedor el 2026-09-06): un comando `mefisto:x` se registra y se invoca via `opencode run --command`, tanto si viene de un archivo literal `mefisto:x.md` como si viene de la clave `command` en `opencode.json`. Esta tolerancia **no esta documentada** en la referencia publica de Commands [4] -- se deja registrada aqui como evidencia de un binario concreto, a cubrir con un test dedicado cuando #874 materialice el adaptador OpenCode del lado publicado.

**Limite conocido**: `:` es un caracter ilegal en nombres de archivo NTFS. Irrelevante mientras el harness siga siendo bash sobre macOS/Linux/WSL (MEF-ADR-0049 seccion 6) -- se deja anotado para que un futuro soporte Windows nativo lo revise antes de asumir que el separador literal es portable a ese filesystem.

### 5. Definicion operativa de "agnostico": checklist contra los gates existentes (CA-5)

Un artefacto de Mefisto es "agnostico a runtime" cuando pasa, sin excepcion declarada, los gates que **ya existen** (MEF-ADR-0018: extender un mecanismo nuevo cuando uno existente basta es la extraccion prematura que esa heuristica desaconseja):

- **R1-R4 y `adapters-check` de `src/internal/scripts/mefisto-neutrality-gate.sh`** (issue #911): ausencia de alias de modelo/tools/permisos crudos en la fuente neutral (R1), de invocaciones directas de CLI de runtime (R2), de rutas/variables propias de un runtime (R3), de shims de `.claude/scripts/*.sh` divergentes de su plantilla (R4), y paridad entre la fuente y los adaptadores generados (`adapters-check`).
- **Bloque `[F]` de `scripts/tests/test-guards.sh`**: integridad de todo `SKILL.md` -- `name` coincide con el directorio (F1), `description` no vacia (F2), recursos de Nivel 3 referenciados existen (F3), y toda referencia `skills:` de un agente resuelve a un Skill real (F4).
- **`src/internal/scripts/validate-internal-artifacts.sh`**: conformidad de todo `src/internal/{agents,commands}/*.md` contra `internal-artifact.schema.json` -- incluida la neutralidad del body (ninguna linea nombra `claude` ni `opencode` fuera de las dos excepciones literales documentadas en `src/internal/contract/README.md`).

**Regla nueva que este ADR manda crear, todavia pendiente**: una **F5** en el bloque `[F]` de `test-guards.sh` que verifique el frontmatter portable de todo `SKILL.md` (decision 3) -- que ningun campo fuera de `name`/`description`/`license`/`compatibility`/`metadata` este presente, `allowed-tools` en particular. Hoy ningun `SKILL.md` del repo la viola (verificado, ver decision 3), pero el gate que lo garantice de forma continua no existe todavia: lo entrega el issue #937, que este ADR bloquea.

### 6. `AGENTS.md` porta el principio sin tocar las fuentes de `mefisto-writer`/`mefisto-reviewer` (CA-6)

`AGENTS.md` -- que ambos runtimes cargan como directivas canonicas del repo (MEF-ADR-0049 decision 3) -- gana una linea de principio que referencia este ADR. Al ser una directiva de proyecto y no un campo de frontmatter de agente, `mefisto-writer` y `mefisto-reviewer` (los dos agentes del pipeline interno de tooling, hoy sin ninguna mencion de neutralidad en su fuente) la reciben en cada corrida, en cualquiera de los dos runtimes, sin que su `.md` en `src/internal/agents/` cambie una sola linea.

## Alternativas consideradas

### Alt a: Enmendar MEF-ADR-0049 en vez de crear un ADR nuevo

Anadir estas seis decisiones como una seccion mas de MEF-ADR-0049.

**Descartada**: MEF-ADR-0049 es arquitectura concreta del *rollout interno* -- fuente `src/internal/`, perfiles de modelo, ejecucion headless de OpenCode -- y esta explicitamente acotado a diferir el lado publicado a #874. Ese ADR va a seguir evolucionando (o cerrandose) junto con el dogfooding; un principio transversal que aplica a ambos lados por igual sobrevive mejor separado de esa arquitectura especifica, igual que MEF-ADR-0012 y MEF-ADR-0018 conviven como heuristicas independientes sin fusionarse.

### Alt b: Separador `-` para runtimes sin concepto de plugin

Usar `mefisto-sequential` (guion) en vez de `mefisto:sequential` (dos puntos) para runtimes sin plugin, por ser universal (sin restriccion de caracteres) y ya documentado como convencion de Skills/comandos internos.

**Descartada**: colisiona nominalmente con la convencion ya vigente de `mefisto-` = interno (MEF-ADR-0019). Un consumidor viendo `/mefisto-sequential` no puede distinguir, por el nombre solo, si es un comando publicado corriendo bajo un runtime sin plugin o un comando interno del propio harness -- exactamente la ambiguedad que el prefijo doble (`mefisto:` vs `mefisto-`) existe para evitar. Ademas introduce dos grafias distintas del mismo comando publicado segun el runtime (`/mefisto:sequential` en Claude Code, `/mefisto-sequential` en el otro), forzando al consumidor a recordar cual aplica donde.

### Alt c: Separador `/` via subcarpeta

Organizar los comandos publicados bajo una subcarpeta `mefisto/` (p. ej. `commands/mefisto/sequential.md`), aprovechando que OpenCode soporta namespaces por subcarpeta nativamente.

**Descartada**: semantica divergente entre runtimes. OpenCode derivaria el namespace de la subcarpeta, pero Claude Code Plugins ignora la jerarquia de carpetas para el nombre del comando (el nombre lo da el archivo, no la ruta) -- el mismo artefacto fisico produciria `/mefisto/sequential` en un runtime y `/sequential` a secas en el otro, perdiendo el namespace exactamente donde mas hace falta (Claude Code, el runtime de mayor uso hoy).

### Alt d: Permitir `allowed-tools` en `SKILL.md`

No prohibirlo, dejandolo como extension opcional de Claude Code que un autor de Skill puede usar si lo desea.

**Descartada**: es precisamente el modo de falla silencioso que origina la decision 3 -- OpenCode lo ignora sin ningun aviso [2], asi que un Skill que dependa de el para su seguridad parece funcionar en ambos runtimes cuando en realidad solo restringe en uno. Prohibirlo de raiz es mas barato que confiar en que cada autor recuerde no depender de el.

## Consecuencias

### Positivas

- **Ninguna operacion nueva puede "olvidar" ser neutral**: el principio aplica por default a todo artefacto nuevo, en vez de descubrirse post-hoc cuando el gate de neutralidad (#923) lo frena.
- **Agregar un runtime es un ejercicio mecanico**: la tabla de la decision 2 convierte "soportar un runtime nuevo" en una checklist verificable contra archivos reales, sin que nadie tenga que re-descubrir el punto de extension desde cero.
- **`.claude/skills/` deja de tener un riesgo sin dueño**: el frontmatter portable (decision 3) cierra el cabo suelto que MEF-ADR-0049 dejo explicitamente para "un ADR de seguimiento".
- **`mefisto-writer`/`mefisto-reviewer` conocen la regla de antemano**: la linea en `AGENTS.md` mueve la neutralidad de "gate que frena post-hoc" a "directiva que el agente ya trae al arrancar", sin tocar sus fuentes.
- **El namespace `mefisto` queda resuelto para cualquier runtime futuro sin plugin**, con la evidencia empirica de OpenCode ya registrada para cuando #874 la necesite.

### Negativas

- **F5 queda fijada pero no implementada**: este ADR manda crear la regla (decision 5) sin entregarla -- issue #937 la implementa. Hasta entonces, un `SKILL.md` con `allowed-tools` seguiria pasando el bloque `[F]` de `test-guards.sh` sin que ningun gate automatizado lo detecte (aunque hoy ninguno lo tiene).
- **La tolerancia de namespace `mefisto:x` en OpenCode 1.18.29 es evidencia empirica de un binario concreto, no documentacion oficial** [4]: una version futura de OpenCode podria dejar de aceptarla sin aviso, y el adaptador que #874 construya debe reverificarla antes de depender de ella en produccion.
- **La regla de no-regresion del lado publicado (decision 1) no tiene gate automatizado propio**: a diferencia del lado interno (`mefisto-neutrality-gate.sh`), nada escanea hoy `scripts/`, `commands/`, `skills/` publicados en busca de acoplamiento nuevo a un runtime -- la regla se aplica por revision humana/de agente hasta que un gate equivalente exista del lado publicado (fuera del alcance de este ADR).
- **Separador distinto segun el tipo de artefacto en runtimes sin plugin** (`:` para comandos, `-` para Skills, decision 4) es una asimetria que un contribuyente nuevo debe aprender -- aceptada porque la spec de Skills la fuerza (`name` no admite `:`), no por preferencia estetica.

## Referencias

- **[1]** "Agent Skills Specification" -- agentskills.io. Fija los seis campos de frontmatter reconocidos (`name`, `description`, `license`, `compatibility`, `metadata`, `allowed-tools`), marca `allowed-tools` como *Experimental*, y fija el patron `name: ^[a-z0-9]+(-[a-z0-9]+)*$`. Fuente de las decisiones 3 y 4. Verificado (fetch HTTP, 2026-09-06). https://agentskills.io/specification
- **[2]** "Skills" -- OpenCode Docs. Confirma los cinco campos que OpenCode reconoce (sin `allowed-tools`), la cita *"Unknown frontmatter fields are ignored"*, y las rutas de descubrimiento de Skills incluyendo `.claude/skills/`. Fuente de la decision 3. Verificado (fetch HTTP, 2026-09-06). https://opencode.ai/docs/skills/
- **[3]** "Using skill frontmatter outside Claude Code" -- Claude Code Docs. Tabla de campos estandar vs extensiones propias de Claude Code, y las ubicaciones que Claude Code reconoce (`.claude/skills/`, `<plugin>/skills/` -- nunca `.agents/skills/`). Fuente de la decision 3. Verificado (fetch HTTP, 2026-09-06). https://code.claude.com/docs/en/skills#using-skill-frontmatter-outside-claude-code
- **[4]** "Commands" -- OpenCode Docs. Documenta que el nombre de un comando de OpenCode lo da el archivo, sin namespace de plugin nativo -- contexto de por que un runtime sin plugin necesita el separador `:` de la decision 4 para reproducir el namespace `mefisto:`. No documenta la tolerancia a `:` en el nombre; esa tolerancia es evidencia empirica de la version instalada (OpenCode 1.18.29), registrada aparte en la decision 4. Verificado (fetch HTTP, 2026-09-06). https://opencode.ai/docs/commands/
- "Plugins" -- OpenCode Docs, citada de contexto: confirma que los plugins de OpenCode son modulos JS/TS de hooks, no un mecanismo de empaquetado de comandos -- por lo que un runtime sin esa primitiva de plugin resuelve el namespace por convencion de nombre de archivo (decision 4), no por manifiesto. Verificado (fetch HTTP, 2026-09-06). https://opencode.ai/docs/plugins/
- MEF-ADR-0049 (arquitectura neutral runtime/proveedor): este ADR generaliza su principio subyacente sin reemplazar su arquitectura concreta del rollout interno; su decision 2 queda enmendada para remitir aqui en vez de a "un ADR de seguimiento".
- MEF-ADR-0033 (Agent Skills): fuente del modelo de Skills que la decision 3 restringe con el frontmatter portable.
- MEF-ADR-0019 (publicado vs interno): el principio de este ADR aplica a ambos lados que ese ADR separa; el registro de rutas nuevas (seccion E) sigue rigiendo para cualquier artefacto que un runtime nuevo introduzca.
- MEF-ADR-0030 (esquema de identificacion de ADRs): fija el numero `MEF-ADR-0050` (verificado libre: `docs/adr/` llegaba a `MEF-ADR-0049` antes de este ADR, sin issue ni PR que reservara `0050`).
- MEF-ADR-0018 (heuristicas de evolucion y reuso): justifica, en la decision 5, por que el checklist de "agnostico" referencia gates existentes en vez de crear un mecanismo nuevo.
- Issue #935: origen de este ADR.

## Control de cambios

- 2026-09-06: creacion como `aceptado` (issue #935). Fija el principio de neutralidad de runtime para toda operacion de Mefisto en ambos lados de MEF-ADR-0019 -- conjunto de runtimes abierto ("soportado" = tiene adaptador) y regla de no-regresion en el lado publicado hasta #874 (seccion 1); el checklist verificable de extension para un runtime nuevo, citando en cada paso el archivo real que hoy lo implementa para claude/opencode -- incluido el cableado del adaptador en `generate-internal-adapters.sh` (seccion 2); el frontmatter portable obligatorio de todo `SKILL.md` (`name`, `description`, `license`, `compatibility`, `metadata`; `allowed-tools` prohibido; recursos de Nivel 3 en bash+jq+gh; `.claude/skills/` como unica ubicacion fisica) (seccion 3); el namespace `mefisto` con separador nativo de plugin en Claude Code y `:` en runtimes sin esa primitiva, prefijo llano `mefisto-` para Skills en esos mismos runtimes, evidencia empirica de OpenCode 1.18.29 y el limite NTFS conocido (seccion 4); la definicion operativa de "agnostico" contra los gates ya existentes (R1-R4 + adapters-check de `mefisto-neutrality-gate.sh`, bloque `[F]` de `test-guards.sh`, `validate-internal-artifacts.sh`) y la regla F5 pendiente que este ADR manda crear (issue #937) (seccion 5); y la linea de principio en `AGENTS.md` que `mefisto-writer`/`mefisto-reviewer` reciben sin cambiar su fuente (seccion 6). Bloquea #937 y #938.

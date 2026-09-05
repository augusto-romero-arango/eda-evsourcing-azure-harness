# MEF-ADR-0049: Arquitectura neutral de runtime y proveedor de Mefisto

- **Fecha**: 2026-09-05
- **Estado**: aceptado
- **Aplica a**: arquitectura de fuente y distribucion del propio harness Mefisto -- que runtime de agente lo ejecuta, que proveedor de modelo usa cada runtime, y como el codigo interno (`.claude/`) y su futuro equivalente para otro runtime dejan de estar acoplados a un runtime o proveedor concreto. Fija el rollout interno (dogfooding) y difiere explicitamente la distribucion publicada (ver "Que queda fuera de este ADR"). Cross-referencia MEF-ADR-0019 (separacion publicado/interno: el layout de esta decision se superpone con esa separacion sin reemplazarla), MEF-ADR-0030 (esquema de identificacion, fija el numero `0049` como libre), MEF-ADR-0031 (gates deterministas por evidencia verificable, precedente que este ADR extiende a un futuro protocolo neutral de eventos) y MEF-ADR-0033 (Agent Skills: esta decision fija el tratamiento de `.claude/skills/` frente a la fuente neutral).

**Issues bloqueados por este ADR**: #852 (registro de rutas nuevas en los gates de scope), #853, #855, #856, y transitivamente todo el backlog #852-#875 que de ellos depende.

## Contexto

Mefisto mezcla hoy tres conceptos que deberian ser independientes: el **runtime** de agente (el CLI que interpreta agentes, comandos y permisos -- hoy Claude Code), el **proveedor** de modelo (quien sirve las respuestas del modelo -- hoy Anthropic) y el **modelo concreto** (el identificador de un modelo especifico de ese proveedor). Los tres estan hoy hardcodeados en un solo lado: el runtime es Claude Code porque es el unico que el repo invoca, el proveedor es Anthropic porque es el unico que Claude Code sabe hablar por defecto, y el modelo va fijo en el frontmatter de cada agente interno.

Acoplamientos medidos en el lado interno (2026-09-05, ver issue #851):

- `claude -p` invocado directamente en `.claude/scripts/mefisto-tooling-pipeline.sh:463`.
- `claude --agent` invocado directamente en `.claude/commands/mefisto-plan.md`, `.claude/commands/mefisto-bug.md` y `.claude/commands/mefisto-bitacora.md`.
- La ruta `.claude/pipeline` citada en un numero significativo de archivos internos (scripts, comandos, tests) como *el* directorio de estado del pipeline, sin ninguna capa de indireccion.
- `model:` fijo en el frontmatter de los 3 agentes internos existentes (`.claude/agents/mefisto-historiador.md: sonnet`, `.claude/agents/mefisto-investigator.md: opus`, `.claude/agents/mefisto-planner.md: fable`) -- alias propios de Claude Code, ilegibles para cualquier otro runtime.

Esa mezcla impide dos cosas que el mantenedor necesita hoy: ejecutar el desarrollo interno del harness con **OpenCode** como runtime de dogfooding, y elegir proveedor/modelo con libertad en vez de heredarlos implicitamente de que CLI se invoque. Antes de abrir rutas, contratos o adaptadores nuevos (#852 en adelante), hace falta fijar la arquitectura que los va a gobernar a todos -- exactamente el mismo motivo por el que MEF-ADR-0039 fijo la composicion de ensamblados antes de que cada BC la reinventara por su cuenta, y MEF-ADR-0047 fijo la doctrina de servidores MCP antes del primer scaffold.

Dos decisiones ya se tomaron en la sesion de planeacion que origino este ADR, y quedan fijadas aqui formalmente:

1. El toolchain de generacion y validacion de los adaptadores es **Bash + jq** -- coherente con el resto del harness, que hoy ya depende unicamente de `bash + jq + git + gh` (ver `scripts/*.sh` y `.claude/scripts/*.sh`). Sin Node, sin Python, sin `yq`.
2. El alcance de este ADR se particiona deliberadamente: fija la arquitectura y el rollout **interno**. El layout `dist/`, la distribucion GitHub-only del plugin y el concepto de "version activa global por usuario" se **difieren** a un ADR posterior, tras completar el dogfooding (#874).

### Alcance

Este ADR fija doctrina de arquitectura para el propio harness Mefisto: como se declara un agente/comando/pipeline de forma neutral a runtime y proveedor, que runtime ejecuta el dogfooding interno, y el vocabulario de modelo que la fuente neutral puede usar. No fija la implementacion del generador ni de los adaptadores (issues de seguimiento, #852 en adelante) mas alla de las restricciones que esta decision les impone.

### Que queda fuera de este ADR

- **El layout `dist/`** con el que un futuro lado publicado empaquetaria el harness para runtimes distintos de Claude Code: fuera de alcance hasta que el dogfooding interno (este ADR) haya corrido lo suficiente para informar esa decision.
- **La distribucion GitHub-only** del plugin (hoy vive en un marketplace de Claude Code Plugins) y su equivalente para OpenCode: mismo motivo, diferida a un ADR posterior (#874).
- **La "version activa global por usuario"** (el equivalente, para un runtime neutral, de "que version de Mefisto tengo instalada" que hoy resuelve `/upgrade`): diferida al mismo ADR posterior.
- **La implementacion concreta del generador de adaptadores, del protocolo neutral de eventos y del mapping de permisos**: son los issues #852-#875 que este ADR bloquea sin resolverlos.

## Decision

### 1. Runtime, proveedor y modelo son tres conceptos independientes (CA-1)

Ningun componente de la fuente neutral (definida en la decision 2) nombra un proveedor de modelo ni un identificador de modelo concreto. Un agente, comando o pipeline de la fuente neutral solo puede referirse a un runtime por su rol funcional (que adaptador lo interpreta) y a un modelo por su perfil logico (decision 4) -- nunca por `anthropic`, `openai`, `claude-sonnet-5`, `gpt-5.1` o equivalente.

- **OpenCode es el runtime del dogfooding interno.** Es el runtime bajo el que se desarrolla y valida la evolucion futura del propio Mefisto (issues #852 en adelante). Verificado en la maquina del mantenedor (2026-09-05): OpenCode `1.18.29`; `opencode run` acepta `--agent`, `--dir`, `--format json`, `--model provider/model` y `--auto` [1]; y Herdr (el multiplexor de terminal que ya orquesta los pipelines de Mefisto) acepta `--kind opencode` como tipo de sesion.
- **Claude Code se conserva como runtime compatible detras de un adaptador.** No se retira: sigue siendo un adaptador de primera clase (decision 2), generado desde la misma fuente neutral que alimenta al adaptador de OpenCode. El desarrollo interno con Claude Code (como el que produce este mismo ADR) sigue siendo valido mientras el adaptador `.claude/` exista.
- **Los proveedores son intercambiables y los administra el runtime, nunca el harness.** Anthropic, OpenAI u otro proveedor que un runtime soporte se seleccionan y autentican enteramente dentro de ese runtime (ver decision 5); Mefisto no declara, valida ni asume ningun proveedor especifico en su fuente neutral.
- **Pi queda fuera.** Se evaluo como tercer candidato a runtime de dogfooding y se descarta por decision explicita del mantenedor (ver Alternativas, Alt d) -- no por una limitacion tecnica medida.

### 2. Layout interno: fuente canonica neutral + adaptadores generados (CA-2)

- **`src/internal/{agents,commands,scripts}`** es la **fuente canonica**: la unica ubicacion donde se escribe o edita a mano la doctrina, el comportamiento y los pipelines internos de Mefisto. Su contrato es neutral a runtime (decision 1) y su formato de metadata es JSON parseable por `jq` (decision 6), no el frontmatter YAML que Claude Code consume directamente.
- **`.claude/` y `.opencode/`** son **adaptadores generados y versionados**: un programa (issue de seguimiento, #852 en adelante) transforma la fuente neutral de `src/internal/` en el formato que cada runtime espera (frontmatter YAML + `.md` para Claude Code; el formato equivalente de agente/comando que OpenCode documenta [3]). Se versionan en git -- no se `.gitignore`an como un `dist/` desechable -- porque Claude Code y OpenCode los cargan directamente del working tree; pero **nunca se editan a mano**: cualquier cambio manual a un archivo generado se pierde en la siguiente regeneracion, y el generador (con su modo `--check`, ver Consecuencias) es quien verifica que ningun adaptador diverja de lo que su fuente neutral produciria.
- **Los Agent Skills internos (`.claude/skills/`, MEF-ADR-0033) quedan explicitamente fuera de la fuente neutral en esta fase.** El modelo de *progressive disclosure* de tres niveles que MEF-ADR-0033 adopta (metadata siempre cargada, instrucciones al disparo, recursos bajo demanda) es una primitiva documentada especificamente para Claude Code [4]; ni la documentacion de agentes de OpenCode consultada [3] ni la de configuracion [5] describen un mecanismo equivalente. Migrar `.claude/skills/` a la fuente neutral antes de verificar si OpenCode tiene (o necesita) un primitivo analogo seria disenar contra una premisa no confirmada. `.claude/skills/` sigue existiendo como artefacto de autoria manual del lado Claude Code -- no generado, no cubierto por este ADR -- hasta que un ADR de seguimiento, informado por el dogfooding, decida si entra a la fuente neutral o permanece como una capacidad especifica de ese adaptador.

### 3. `AGENTS.md` y `.mefisto/pipeline` como canonicos, con fallback indefinido (CA-3)

- **`AGENTS.md`** pasa a ser el archivo de **directivas canonicas** del repo -- el equivalente neutral de `CLAUDE.md`. OpenCode documenta exactamente este archivo como su mecanismo de instrucciones de proyecto: *"You can provide custom instructions to opencode by creating an `AGENTS.md` file"* [5]. Claude Code, a su vez, ya reconoce `AGENTS.md` como fuente de instrucciones de proyecto, por lo que un mismo archivo sirve a ambos adaptadores sin traduccion.
- **`.mefisto/pipeline`** pasa a ser el **estado canonico** del harness (lo que hoy resuelve `.claude/pipeline`: worktrees activos, resumenes de stage, metricas). Es una ruta neutral a runtime, sin el prefijo `.claude/` que hoy ata ese estado a un runtime especifico.
- **El fallback a `CLAUDE.md` y `.claude/pipeline` es indefinido: no lleva fecha de retiro.** Mientras el adaptador Claude Code siga siendo compatible (decision 1), cualquier pipeline o agente que busque directivas o estado puede seguir encontrando `CLAUDE.md`/`.claude/pipeline` si `AGENTS.md`/`.mefisto/pipeline` no existen todavia -- sin que este ADR fije un momento en el que ese fallback deje de honrarse. Fijar una fecha de retiro exigiria saber hoy cuando termina el dogfooding y que consumidores dependen de los nombres viejos, informacion que este ADR no tiene todavia.

### 4. Perfiles logicos de modelo: `fast|balanced|deep` (CA-4)

- **Vocabulario unico en la fuente neutral**: todo agente o comando de `src/internal/` que necesite declarar una preferencia de modelo lo hace con uno de tres perfiles logicos -- `fast`, `balanced`, `deep` -- nunca con un alias de proveedor (`sonnet`, `opus`, `fable`) ni con un ID de modelo. El perfil describe una intencion de costo/capacidad, no un modelo.
- **Precedencia de resolucion, de mayor a menor prioridad**:
  1. **Override explicito**: si el propio agente o la invocacion fijan un modelo concreto de forma explicita (mecanismo del adaptador destino, fuera del alcance de este ADR), ese valor gana siempre.
  2. **Mapping local runtime+perfil**: `.mefisto/models.json` resuelve el par (runtime activo, perfil logico) a un modelo concreto (`provider/model-id` para OpenCode [3], alias de Claude Code para ese adaptador). Es una tabla local, no parte de la fuente neutral.
  3. **Herencia del modelo activo del runtime**: si no hay override ni mapping local para ese perfil, el agente hereda el modelo que el runtime ya tiene activo en la sesion -- el mismo comportamiento que OpenCode ya documenta para un agente sin `model` propio (*"If no model is specified, primary agents use the model configured globally... subagents inherit the model of the primary agent that invoked them"* [3]) y que Claude Code ya ofrece via sus alias (`sonnet`, `opus`) resueltos por el propio runtime.
- **`.mefisto/models.json` no se versiona.** Solo se versiona `.mefisto/models.json.example` (una plantilla con los tres perfiles y valores de ejemplo). Es la misma politica que el resto del marco ya aplica a no documentar modelos concretos en el repo (ver memoria de sesion del mantenedor): un mapping concreto de modelo es una eleccion de maquina/momento, no doctrina del harness.

### 5. Ejecucion headless de OpenCode: `--auto` bajo permisos deny-por-defecto generados, sin custodia de credenciales (CA-5)

- **`opencode run --auto`** es el mecanismo de ejecucion desatendida que los pipelines internos usan para invocar agentes bajo OpenCode -- el equivalente de `claude -p --permission-mode bypassPermissions` de hoy. La documentacion oficial lo confirma como el modo pensado para automatizacion: *"Start OpenCode with `--auto` to automatically approve permission requests"* [2].
- **Los permisos son deny-por-defecto, pero ese default lo genera Mefisto, no OpenCode.** OpenCode por si mismo es permisivo (*"Most permissions default to `allow`"* [2]); el archivo de permisos que el generador de adaptadores emite por cada agente invierte ese default explicitamente a deny, listando solo lo que ese agente concreto necesita -- el mismo espiritu que el `tools:`/`disallowedTools:` que un agente de Claude Code ya declara hoy.
- **`external_directory` queda denegado explicitamente**, no solo dejado en su default. OpenCode ya trata este permiso de forma mas cautelosa que el resto (*"`external_directory` adopt a more cautious default of `ask`"* [2]), pero un `ask` interactivo no tiene sentido en un pipeline headless sin humano al otro lado -- se fija en `deny` explicito para que ningun agente generado pueda tocar rutas fuera del working directory sin que el pipeline lo apruebe primero por otra via.
- **La autenticacion y las credenciales las administra exclusivamente el runtime.** Mefisto nunca lee auth stores, tokens ni API keys de OpenCode (ni de ningun otro runtime): ni el generador de adaptadores ni ningun pipeline interno inspeccionan donde OpenCode guarda sus credenciales de proveedor. Es la misma doctrina de custodia de secretos que MEF-ADR-0025 ya fija para el resto del marco, aplicada aqui a las credenciales del propio runtime de agente.

### 6. Toolchain Bash + jq, rollout interno-primero, y particion explicita del alcance (CA-6)

- **El contrato neutral es parseable por `jq`: metadata JSON, no YAML libre.** Cada archivo de `src/internal/{agents,commands}` declara su metadata como un bloque JSON (escalares JSON-quoted, *flow mappings* -- el subconjunto de YAML que es JSON valido), nunca como YAML con anclas, tags o multi-linea de bloque que `jq` no pueda leer sin un traductor adicional. Un generador en Bash necesita poder extraer esa metadata con `jq '.campo'` directo, sin invocar un parser YAML.
- **La validacion es un programa `jq`, no JSON Schema con validador externo.** Verificar que un agente/comando de la fuente neutral tiene la forma correcta se expresa como un filtro `jq` que falla con exit distinto de cero ante metadata invalida -- coherente con el patron que `scripts/tests/test-guards.sh` ya usa hoy para el resto del harness --, no como un esquema JSON Schema que exigiria un validador externo (`ajv`, `jsonschema`, etc.) fuera de `bash + jq + git + gh`.
- **La emision de frontmatter usa escalares JSON-quoted y *flow mappings*.** Cuando el generador escribe el frontmatter YAML que Claude Code consume, emite los valores como literales JSON-quoted (`"texto"`, nunca YAML sin comillas que dependa de reglas de escape propias de YAML) dentro de mapas de flujo (`{clave: valor}`) cuando la estructura lo permite -- ambas formas son YAML valido y a la vez el subconjunto que un generador basado en `jq` puede producir de forma determinista sin una libreria de serializacion YAML.
- **Rollout interno-primero.** El soporte para el lado publicado (que un consumidor del marco pueda elegir runtime/proveedor igual que Mefisto lo hace internamente) solo se considera **despues** de que el dogfooding interno alcance paridad completa entre los adaptadores `.claude/` y `.opencode/` -- no en paralelo, no antes.
- **Se difiere explicitamente** (ver "Que queda fuera de este ADR") el layout `dist/`, la distribucion GitHub-only y la version activa global por usuario a un ADR posterior, tras el dogfooding (#874).

## Alternativas consideradas

### Alt a: Node como toolchain del generador

Usar Node.js (con `js-yaml`, `ajv` u otro paquete del ecosistema npm) para el generador de adaptadores y su validador.

**Descartada**: introduce un segundo ecosistema de build y de tests junto al `bash + jq + git + gh` que el resto del harness ya usa exclusivamente -- un `package.json`, un lockfile, una version de Node que fijar y actualizar, y una superficie de dependencias transitivas que auditar. Bash 3.2 (el shell que trae macOS por defecto, sin actualizar por la licencia GPLv3 desde la version 4) y jq 1.7.1 ya cubren el caso de uso completo: leer/escribir JSON, invocar filtros de validacion, y emitir texto formateado. Verificado en la maquina del mantenedor (2026-09-05): Bash `3.2.57`, jq `1.7.1`.

### Alt b: Claude Code como unico runtime, con proveedor alterno

Mantener Claude Code como el unico runtime del harness, y resolver la necesidad de "elegir proveedor libremente" a traves de lo que Claude Code ya soporte (proveedores alternos vía configuracion propia de Claude Code).

**Descartada**: no resuelve ninguno de los dos acoplamientos medidos en el Contexto -- `claude -p`/`claude --agent` seguirian siendo la unica via de invocacion, y `.claude/` seguiria siendo la unica ubicacion de agentes/comandos/pipelines. El problema no es solo "que proveedor sirve el modelo", es "que CLI interpreta el agente"; esta alternativa solo ataca el primero.

### Alt c: mantener a mano dos copias, `.claude/` y `.opencode/`

Escribir y mantener manualmente el equivalente de cada agente/comando/pipeline en ambos formatos, sin una fuente neutral ni generador.

**Descartada**: divergencia garantizada. Dos copias editadas a mano de la misma doctrina inevitablemente se desincronizan -- un fix aplicado a `.claude/agents/mefisto-planner.md` que no se replica a mano en su equivalente de `.opencode/` dentro de la misma sesion de trabajo, o un `model:` fijado en un lado y no en el otro. Es exactamente el mismo riesgo que MEF-ADR-0019 ya acepto conscientemente para *publicado vs interno* citando la regla de tres (MEF-ADR-0018) -- pero ahi la duplicacion es entre dos lados con **contenido distinto** por diseno; aqui seria duplicar **el mismo contenido** dos veces, sin ninguna razon de negocio para que difieran.

### Alt d: Pi como runtime

Adoptar Pi como runtime adicional o alterno de dogfooding, junto a o en vez de OpenCode.

**Descartada por decision del mantenedor.** No es un descarte por limitacion tecnica medida (a diferencia de Alt a/b/c): el mantenedor fijo OpenCode como unico runtime de dogfooding interno y Claude Code como runtime compatible; Pi queda fuera de esta arquitectura sin evaluacion tecnica adicional.

## Consecuencias

### Positivas

- **Ningun futuro adaptador de runtime reinventa esta arquitectura desde cero**: la separacion runtime/proveedor/modelo, el layout fuente-neutral + adaptadores generados, y el vocabulario de perfiles logicos quedan fijados una vez, antes de que #852 en adelante abran codigo sobre una premisa distinta cada uno.
- **El dogfooding interno puede arrancar con OpenCode sin retirar Claude Code**: ambos adaptadores conviven, generados desde la misma fuente, mientras dure la transicion -- nadie pierde su runtime de trabajo actual el dia que el primer generador exista.
- **Cero mecanismo de build nuevo**: el generador y su validador se apoyan integramente en `bash + jq`, ya presentes en toda maquina que hoy corre los pipelines del marco -- ninguna dependencia nueva que instalar o pinnear.
- **Custodia de credenciales sin superficie nueva**: Mefisto nunca lee tokens/auth stores de ningun runtime (decision 5), evitando exactamente el tipo de riesgo que MEF-ADR-0025 ya previene para el resto del marco.
- **El fallback indefinido a `CLAUDE.md`/`.claude/pipeline` no fuerza una migracion big-bang**: cualquier pipeline o agente existente sigue funcionando mientras `AGENTS.md`/`.mefisto/pipeline` no existan, sin fecha limite que atender bajo presion.

### Negativas

- **Dos adaptadores que mantener sincronizados**: aunque generados (no editados a mano), `.claude/` y `.opencode/` son dos artefactos versionados que un `--check` debe verificar en cada cambio -- trabajo de CI/gate que no existia cuando solo habia un adaptador. La implementacion de ese `--check` es alcance de #854/#873, no de este ADR.
- **El soporte publicado queda pospuesto indefinidamente hasta paridad completa**: un consumidor del marco no gana la capacidad de elegir runtime/proveedor con este ADR -- solo el propio Mefisto, del lado interno. Es una decision deliberada (rollout interno-primero, decision 6), no un olvido.
- **`.mefisto/models.json` no versionado exige configuracion manual por maquina**: cada entorno donde corra el dogfooding necesita poblar su propio mapping local desde `.mefisto/models.json.example` antes de que los perfiles logicos resuelvan a un modelo real -- coherente con la politica de no documentar modelos concretos en el repo, pero un paso de setup que no existia cuando el modelo iba fijo en el frontmatter.
- **Bash 3.2 sin arrays asociativos restringe al generador**: macOS trae Bash 3.2.57 sin actualizar (licenciamiento GPLv3 desde Bash 4), y el generador debe funcionar sobre esa version -- sin `declare -A`, cualquier tabla clave-valor del generador se resuelve con el propio `jq` o con convenciones de nombre de variable, nunca con arrays asociativos nativos de Bash.
- **`.claude/skills/` queda sin cubrir por la fuente neutral en esta fase**: mientras un ADR posterior no revise el tratamiento de Agent Skills frente a OpenCode, ese tercer tipo de artefacto sigue siendo autoria manual del lado Claude Code exclusivamente, sin el beneficio de generacion/verificacion que este ADR da a agentes/comandos/scripts.
- **Layout `dist/`, distribucion GitHub-only y version activa global quedan sin resolver**: un consumidor que preguntara hoy "como instalo Mefisto sobre OpenCode" no tiene respuesta hasta el ADR posterior que este mismo documento difiere (#874).

## Referencias

- **[1]** OpenCode Docs, "CLI" -- documenta `opencode run` y sus flags, incluidas `--agent`, `--dir`, `--format`, `--model` y `--auto` (aprobacion automatica de permisos), y describe el modo no interactivo como pensado para *scripting*/automatizacion. Verificado (WebFetch, 2026-09-05) contra la version instalada por el mantenedor (OpenCode `1.18.29`). https://opencode.ai/docs/cli/
- **[2]** OpenCode Docs, "Permissions" -- fija que la mayoria de permisos por defecto son `allow` (*"Most permissions default to `allow`"*), que `external_directory` adopta un default mas cauteloso (*"adopt a more cautious default of `ask`"*), y que `--auto` aprueba automaticamente las solicitudes de permiso (*"Start OpenCode with `--auto` to automatically approve permission requests"*). Fuente de la decision 5: el deny-por-defecto y el `deny` explicito de `external_directory` son una politica que Mefisto genera encima de este comportamiento permisivo, no el default de OpenCode. https://opencode.ai/docs/permissions/
- **[3]** OpenCode Docs, "Agents" -- confirma el campo `model` por agente (*"Use the `model` config to override the model for this agent"*), el formato `provider/model-id`, y la herencia de modelo de un subagente sin `model` propio desde el agente primario que lo invoca. Fuente de la decision 4 (perfiles logicos resueltos a un modelo concreto por runtime) y de la mencion, en la decision 2, al formato de agente que el adaptador `.opencode/` debe producir. https://opencode.ai/docs/agents/
- **[4]** Claude Docs, "Agent Skills" -- modelo de *progressive disclosure* de tres niveles que MEF-ADR-0033 adopta para Claude Code, citado aqui como la primitiva especifica de ese runtime que motiva dejar `.claude/skills/` fuera de la fuente neutral en esta fase (decision 2). https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview
- **[5]** OpenCode Docs, "Rules" -- confirma `AGENTS.md` como el archivo de instrucciones de proyecto de OpenCode (*"You can provide custom instructions to opencode by creating an `AGENTS.md` file. This is similar to Cursor's rules"*), y documenta la configuracion de modelo/proveedor por defecto (`model`, `small_model`) que ancla el nivel mas bajo de precedencia de la decision 4. https://opencode.ai/docs/rules/ y https://opencode.ai/docs/config/
- OpenAI separa la facturacion de una sesion ChatGPT (autenticada por OAuth, bajo el plan de suscripcion) de una llamada a la API (autenticada por API key, facturada por uso) -- conocimiento general de la industria, sin una URL unica que citar como fuente dedicada; se deja constancia explicita de que no es una cita verificada contra documentacion oficial de OpenAI. Relevante para la decision 5: un runtime que hable con proveedores OpenAI debe distinguir ambos mecanismos de auth, y Mefisto no administra ninguno de los dos.
- MEF-ADR-0019 (separacion publicado/interno): el layout `src/internal/` + adaptadores generados de la decision 2 se superpone con, pero no reemplaza, la separacion publicado/interno que ese ADR ya fija -- `src/internal/` es un tercer nivel de indireccion por-encima de `.claude/` que ese ADR ya trata como lado interno del plugin.
- MEF-ADR-0025 (custodia de secretos): fuente de la doctrina general que la decision 5 aplica a las credenciales de OpenCode -- Mefisto nunca las lee, igual que nunca lee ninguna otra credencial del marco.
- MEF-ADR-0030 (esquema de identificacion de ADRs): fija el numero `MEF-ADR-0049` (numero verificado libre, `docs/adr/` llegaba a `MEF-ADR-0048` antes de este ADR).
- MEF-ADR-0031 (readiness gate por SHA/gates deterministas por evidencia verificable): precedente de exigir evidencia verificable en vez de asumir estado -- el mismo principio que la decision 6 extiende al futuro protocolo neutral de eventos (#858) y al modo `--check` de generacion determinista (#854, #873).
- MEF-ADR-0033 (adopcion de Agent Skills): fuente del modelo de *progressive disclosure* que la decision 2 excluye de la fuente neutral en esta fase, y del propio `.claude/skills/` cuyo tratamiento futuro este ADR deja abierto.
- Issue #851 de este repo: origen de este ADR y de la medicion de acoplamientos citada en el Contexto.
- Issues bloqueados, todavia sin implementar: #852 (registro de rutas en los gates de scope), #853, #855, #856 (directamente bloqueados), #858 (protocolo neutral de eventos), #854/#873 (generacion determinista y verificable con `--check`), #860/#862/#874 (prohibicion de leer tokens/auth store de OpenCode y cierre del dogfooding), #874 (ADR posterior que resuelve `dist/`, distribucion GitHub-only y version activa global).

## Control de cambios

- 2026-09-05: creacion como `aceptado` (issue #851). Fija runtime, proveedor y modelo como tres conceptos independientes -- OpenCode como runtime del dogfooding interno, Claude Code como runtime compatible detras de un adaptador, proveedores intercambiables administrados por el runtime, Pi fuera por decision del mantenedor (seccion 1); el layout `src/internal/{agents,commands,scripts}` como fuente canonica con `.claude/`/`.opencode/` como adaptadores generados y versionados nunca editados a mano, y `.claude/skills/` explicitamente fuera de la fuente neutral en esta fase (seccion 2); `AGENTS.md`/`.mefisto/pipeline` como directivas/estado canonicos con fallback indefinido, sin fecha de retiro, a `CLAUDE.md`/`.claude/pipeline` (seccion 3); los perfiles logicos `fast|balanced|deep` como unico vocabulario de modelo de la fuente neutral, con precedencia override explicito -> mapping local runtime+perfil (`.mefisto/models.json`, no versionado, solo `.example`) -> herencia del modelo activo del runtime (seccion 4); la ejecucion headless de OpenCode con `--auto` bajo permisos deny-por-defecto generados por agente, `external_directory` denegado explicitamente, y custodia de credenciales exclusiva del runtime (seccion 5); y el toolchain Bash + jq -- contrato neutral parseable por `jq`, validacion como programa `jq`, frontmatter emitido con escalares JSON-quoted y *flow mappings* -- con rollout interno-primero y el layout `dist/`/distribucion GitHub-only/version activa global diferidos explicitamente a un ADR posterior tras el dogfooding (#874, seccion 6). No implementa ningun generador, adaptador ni protocolo: fija la arquitectura que #852-#875 materializan.

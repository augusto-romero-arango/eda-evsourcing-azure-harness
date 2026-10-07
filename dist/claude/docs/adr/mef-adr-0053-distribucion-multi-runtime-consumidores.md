# MEF-ADR-0053: Distribucion multi-runtime de Mefisto para consumidores

- **Fecha**: 2026-09-07
- **Estado**: aceptado
- **Aplica a**: la arquitectura publicada de Mefisto que se distribuye a proyectos consumidores. Resuelve los tres diferidos de MEF-ADR-0049 -- layout `dist/`, distribucion para runtimes sin plugin y version activa global por usuario -- despues del cierre de su gate interno (#874 y #879). No reemplaza la separacion publicado/interno de MEF-ADR-0019, la arquitectura interna de MEF-ADR-0049 ni el principio transversal de MEF-ADR-0050.

**Issues bloqueados por este ADR**: #1043, #1047, #1049, #1050, #1051 y #1057; y, transitivamente, el rollout #1044-#1066.

## Contexto

El rollout interno de MEF-ADR-0049 ya resolvio `MEFISTO_RUNTIME`, el runner neutral y los adaptadores internos. El artefacto publicado, en cambio, sigue siendo exclusivamente un Claude Code Plugin: el marketplace apunta a la raiz del checkout, `plugin.json` porta su version y los comandos/pipelines publicados conocen `CLAUDE_PLUGIN_ROOT`, el cache de marketplace, `CLAUDE.md` y `.claude/*`.

No basta con copiar ese checkout para que OpenCode lo consuma. Un consumidor necesita una instalacion global, versionada y reversible; un contrato de proyecto neutral; y paridad observable entre comandos, agentes, Skills, hooks, MCP y ejecucion interactiva/headless. Las rutas de proyecto `.opencode/` y las globales no se presumen equivalentes: la documentacion de OpenCode las documenta por tipo de capacidad.

### Alcance

Este ADR fija la arquitectura de fuente, distribucion, contrato consumidor, versionado y certificacion del lado publicado. Decide **que** se genera, donde vive una instalacion OpenCode y que evidencia debe existir antes de migrar el catalogo.

### Que queda fuera

- No crea `src/published/`, `src/runtime/`, `dist/`, instaladores, artefactos de Release ni adaptadores publicados. MEF-ADR-0019.E obliga primero a registrar sus rutas en los gates; #1043 es ese PR y no puede poblarlas.
- No migra ningun comando distinto del corte vertical `/mefisto:tooling`, ni borra contratos legacy ni modifica credenciales de runtime.

## Decision

### 1. Fuente publicada neutral, nucleo mecanico acotado y distribuciones generadas (CA-1)

- `src/published/` sera la fuente neutral y de autoria manual de los artefactos **publicados**: comandos, agentes, Agent Skills, scripts, permisos, hooks, MCP y su doctrina de consumidor.
- `src/runtime/` sera un nucleo comun limitado a la mecanica de runner y eventos: contrato de ejecucion, traduccion de eventos, telemetria neutral y utilidades que no expresen doctrina ni scope de ningun lado.
- `dist/{claude,opencode}/` seran las raices generadas, reproducibles y no editables a mano de cada distribucion. Claude recibira el artefacto apto para marketplace; OpenCode recibira el artefacto apto para la instalacion global de esta decision.

No se extraen al nucleo doctrina, agentes, skills, reglas de scope, guards, orquestacion de worktrees ni pipelines de los lados publicado e interno. Esos lados siguen fisicamente separados conforme a MEF-ADR-0019; compartir mas que runner/eventos seria una extraccion prematura bajo MEF-ADR-0018. Toda ruta nueva queda vacia hasta que #1043 registre primero `src/published/`, `src/runtime/` y `dist/` en ambos gates de scope.

### 2. Instalacion OpenCode global, versionada y reversible (CA-2)

OpenCode se instalara por usuario desde un artefacto de GitHub Release, nunca copiando un checkout, un worktree ni configuracion de un consumidor. Cada release descomprimira en una ruta inmutable:

| Plataforma | Raiz de datos de Mefisto | Release | Puntero activo |
|---|---|---|---|
| Linux/XDG | `${XDG_DATA_HOME:-$HOME/.local/share}/mefisto` | `releases/<semver>/` | `active` |
| macOS sin `XDG_DATA_HOME` | `$HOME/Library/Application Support/mefisto` | `releases/<semver>/` | `active` |

Si `XDG_DATA_HOME` esta definido en macOS, tambien prevalece sobre el fallback. `active` es el unico puntero de version activa por usuario y se reemplaza atómicamente solo despues de validar checksum, estructura y completitud del release nuevo. La activacion conserva el puntero anterior hasta que el nuevo queda valido; el rollback es otro reemplazo atomico de `active` hacia una release inmutable ya instalada. Ni el repositorio principal ni worktrees hermanos son parte de la instalacion: ambos resuelven el mismo `active`, por lo que descubren la misma version activa sin depender de su cwd.

La raiz global efectiva de configuracion de OpenCode es
`$OPENCODE_CONFIG_DIR` cuando ese override esta definido y, en caso contrario,
`${XDG_CONFIG_HOME:-$HOME/.config}/opencode`, **tambien en macOS**. No se usa
`$HOME/Library/Application Support/opencode`: ese es el fallback elegido arriba
para los datos propios de Mefisto, no una ruta que OpenCode documente. La
separacion se comprobo el 2026-09-07 contra la documentacion oficial vigente y
OpenCode 1.18.29, la version soportada al aceptar este ADR.

Esta es la superficie global documentada que el proyector publicado proyecta
desde `active`: enlaces simbolicos por archivo a `active/{commands,agents,skills,plugins}`.
El enlace hacia `active` hace que un cambio de release no deje residuos de la
anterior. El proyector no escribe `opencode.json`: conserva providers, modelos,
permisos y `mcp` del usuario, y declara visiblemente las capacidades ausentes.
El mecanismo se verifico el 2026-09-08 contra OpenCode **1.18.29** (version
minima soportada) y la documentacion oficial vigente.

| Capacidad | Ubicacion global de OpenCode |
|---|---|
| Configuracion | `<config>/opencode.json` u `opencode.jsonc`; `OPENCODE_CONFIG` puede seleccionar un archivo explicito |
| Comandos | `<config>/commands/*.md` |
| Agentes | `<config>/agents/*.md` |
| Agent Skills | `<config>/skills/*/SKILL.md`; OpenCode tambien descubre las ubicaciones globales compatibles `~/.claude/skills/` y `~/.agents/skills/` |
| Plugins y hooks | `<config>/plugins/*.{js,ts}` para plugins locales, o el array `plugin` de la configuracion para paquetes; los hooks son API de plugin, no una carpeta global independiente |
| Permisos | clave `permission` de la configuracion o frontmatter de agente; no tienen una raiz de archivos propia |
| MCP | clave `mcp` de la configuracion; no tiene una raiz global de archivos propia |

En la tabla, `<config>` es la raiz resuelta del parrafo anterior. La instalacion
Mefisto permanece bajo su propia raiz de datos y `.opencode/` permanece como
forma de proyecto: no se asume que copiarla a `<config>` produzca una
instalacion global valida. Los secrets/auth stores del runtime quedan fuera de
esas rutas y de toda inspeccion de Mefisto, conforme a MEF-ADR-0025.

### 3. Un release, dos adaptadores y diagnostico de deriva (CA-3, enmendado por #1126)

Cada release publica **una sola** version SemVer `<semver>` y el tag Git
`v<semver>` para Claude Code y OpenCode. El destino Claude del release es
`dist/claude/`: cuando exista esa salida, la entrada `mefisto` de
`.claude-plugin/marketplace.json` dejara de apuntar a la raiz del repo y
apuntara a esa raiz generada, cuyo `plugin.json` llevara el mismo `<semver>`.
El destino OpenCode del mismo tag es el asset de GitHub Release
`mefisto-opencode-v<semver>.tar.gz`, acompanado por
`mefisto-opencode-v<semver>.tar.gz.sha256`. Una version no se reedita: tag,
contenido de ambos adaptadores, asset y checksum son inmutables.

Cada distribucion incluye esa identidad en `mefisto-manifest.json` y el runtime
la expone, sin secretos, como `runtime`, `version` SemVer y `commit`. El campo
`commit` es el **commit fuente**: un SHA Git completo de 40 caracteres
hexadecimales de `origin/main` desde el que `/mefisto-release` crea la rama de
preparacion. Se resuelve y captura inmediatamente despues de actualizar
`origin/main`; la rama nace exactamente en ese SHA, antes de consolidar
fragmentos, modificar `CHANGELOG.md`, cambiar la version o generar metadata.
Responde a «¿de que snapshot funcional se construyeron ambos adaptadores?»,
mientras el tag/version responde «¿que release mecanico los publico?»; son
valores distintos y comparables.

El tag `v<semver>` apunta al commit squash de release posterior. Ese commit
etiquetado debe tener un primer y unico padre igual al `commit fuente` declarado.
Si `origin/main` avanza durante la preparacion, la rama queda rebasada; si el
merge no es squash y lineal; o si padre, SHA fuente o manifiestos no coinciden,
`publish` aborta antes de crear el tag y exige regenerar la preparacion desde el
`origin/main` vigente. Esta relacion es verificable localmente: el modelo de Git
crea un commit a partir de un tree y sus padres, por lo que no puede contener en
un archivo versionado el SHA del propio commit sin alterar el tree y producir
otro SHA [Git `commit-tree`].

El delta `commit fuente..commit etiquetado` queda limitado a la allowlist
mecanica de release: version y metadata generada, consolidacion de CHANGELOG e
indice ADR, y borrado de fragmentos ya consolidados. Ningun cambio ejecutable o
doctrinal nuevo puede entrar en ese delta para quedar fuera de la procedencia
declarada. El gate de release falla cerrado ante cualquier ruta fuera de esa
allowlist.

Claude y OpenCode exponen el mismo `version` y `commit fuente`, cada uno con su
propio `runtime`; OpenCode puede conservar `minimumRuntimeVersion`. Al iniciar o
inspeccionar un workspace, Mefisto lee exclusivamente esos manifiestos de las
instalaciones disponibles, valida el `runtime` esperado de cada uno y compara la
igualdad de `version` y `commit`. Si version o commit difieren, informa una
degradacion visible con ambos valores y la accion de alinear/activar la version;
no consulta Git, red, caches arbitrarios, tokens, auth stores, API keys ni
configuracion de proveedor para diagnosticarla.

Los tags historicos sin manifiesto Claude permanecen `metadata_missing`: no se
reedita una version ni un tag existente. La primera release posterior a la
implementacion operativa de este contrato lo establece; una pareja instalacion
vieja/nueva se reporta como degradacion, nunca recibe una identidad inventada.

### 4. Contrato canonico de consumidor con lectura legacy indefinida (CA-4)

El contrato neutral de un consumidor es:

- `AGENTS.md` para directivas.
- `.mefisto/harness.config.json` para configuracion del harness.
- `.mefisto/pipeline/` para estado, logs, metricas y summaries propios del pipeline.

Todo escritor nuevo escribe solo esas ubicaciones canonicas. Los lectores conservan indefinidamente fallback a `CLAUDE.md` y `.claude/*` -- incluidos `.claude/harness.config.json` y `.claude/pipeline/` -- cuando el equivalente canonico no existe. No hay migracion destructiva ni fecha de retiro del fallback.

#### Enmienda transitoria: mirror de identidad de release del adaptador Claude (#1099)

La regla de escritura solo canonica tiene una unica excepcion, transitoria y estrecha: `record-active-release` del adaptador publicado Claude puede, ademas de escribir obligatoria y primariamente `canonical-state`/`release-identity`, reflejar la misma identidad de la distribucion ya cargada observada desde `CLAUDE_PLUGIN_ROOT` en `.claude/pipeline/.plugin-root` y limpiar `.claude/pipeline/.plugin-root.previous`. No resuelve independientemente el mirror ni usa la version mas reciente del cache: esta puede no ser la version que la sesion mantiene cargada. El marker no contiene credenciales ni configuracion del proveedor.

Ningun otro binding recibe permiso para escribir rutas legacy. En particular, `sessions.jsonl` y `events.log` se escriben exclusivamente bajo `.mefisto/pipeline/`. Si el mirror falla, el adaptador informa la degradacion aplicable pero no invalida la sesion; el destino canonico permanece el contrato primario. La capacidad `legacy-release-marker` pertenece solo al adaptador Claude publicado: no se propaga a OpenCode ni a hooks internos, conforme a MEF-ADR-0019 y MEF-ADR-0050.

El mirror solo se retira mediante un issue posterior, tras comprobar un inventario verificable sin lectores de `.claude/pipeline/.plugin-root` ni `.claude/pipeline/.plugin-root.previous`. El cierre de #1054 no satisface ese gate ni autoriza el retiro implicito.

El puente minimo de un consumidor que conserva Claude Code es un `CLAUDE.md` con `@AGENTS.md`; no duplica la doctrina. Las señales neutrales ya definidas bajo `pipeline-state/` no se absorben en `.mefisto/pipeline/`: permanecen gobernadas por MEF-ADR-0017 y su semantica transitoria no cambia.

### 5. Paridad distribuible y fallos visibles (CA-5)

La distribucion tiene paridad como producto, no solo como conjunto de Markdown: comandos, agentes, Agent Skills, scripts, permisos, hooks, MCP y observabilidad -- logs, metricas, sesiones y eventos -- se adaptan o se declaran expresamente no disponibles. OpenCode expone comandos publicados como `/mefisto:*`; los Agent Skills adaptados para runtimes sin plugin usan `mefisto-`, conforme a MEF-ADR-0050 y al nombre portable de Skills.

El generador debe abortar si una capacidad requerida no tiene equivalente o no puede declararse con seguridad. Cuando una capacidad puede operar con menor funcionalidad, el adaptador la marca y reporta como degradacion visible en discovery/ejecucion. Ninguna capacidad desaparece silenciosamente. Los `SKILL.md` conservan el frontmatter portable de MEF-ADR-0033 y MEF-ADR-0050; permisos y hooks se traducen sin ampliar privilegios por omision.

### 6. Rollout corte-vertical-primero y gate reproducible (CA-6)

El primer unico flujo publicado a migrar es `/mefisto:tooling`. Antes de migrar el resto del catalogo debe superar una certificacion reproducible que registre evidencia de:

1. instalacion real de la **misma** version/tag en Claude Code y OpenCode, con checksum de artefacto OpenCode;
2. descubrimiento de comandos, agentes, Skills, scripts, permisos, hooks y MCP en ambos runtimes;
3. una ejecucion headless de `/mefisto:tooling` hasta un PR real y un smoke interactivo de la misma version que ejerza sus hooks; ambas modalidades deben producir observabilidad correlacionable;
4. Herdr con Claude en la fila superior, OpenCode en la inferior y pools de panes separados por runtime;
5. logs, metricas y sesiones que identifiquen `runtime`, `modelo`, `version` y el `commit fuente`, sin secretos ni inputs sensibles.

La presencia de archivos generados no satisface este gate: la evidencia debe ser ejecutable y repetible, en coherencia con MEF-ADR-0031. Si una variante falla o degrada, el rollout se detiene en el corte vertical; no se migra el resto del catalogo para ocultar la incompatibilidad entre volumen de adaptaciones.

## Alternativas consideradas

### Alt a: mantener distribucion solo Claude Code

**Descartada**: conserva los acoplamientos publicados y niega el runtime OpenCode ya validado internamente.

### Alt b: dos repositorios o releases con versiones independientes

**Descartada**: impide comparar una misma entrega y hace inevitable la deriva de versiones/commits que la decision 3 debe detectar.

### Alt c: copiar el checkout completo como instalacion OpenCode

**Descartada**: hace mutable la instalacion, depende del cwd y de worktrees, no da activacion atomica ni rollback y puede arrastrar estado local o secretos.

### Alt d: generar dos taxonomias de eventos

**Descartada**: duplica la mecanica que `src/runtime/` comparte legitimamente y rompe la observabilidad comparable entre runtimes.

### Alt e: migrar todo el catalogo antes del corte vertical

**Descartada**: multiplica superficie sin demostrar que una experiencia completa funciona. El gate de `/mefisto:tooling` expone antes incompatibilidades de runner, hooks, MCP y Herdr.

### Alt f: SHA autorreferencial, solo SemVer, cache/Git/red del consumidor o hash de contenido

**Descartada**: un SHA autorreferencial es imposible porque alterar el
manifiesto altera el tree que identifica el commit. Solo SemVer no prueba la
procedencia comun. El nombre de un cache, `git rev-parse` en el consumidor y una
consulta de red por tag dependen de estado externo, mutable o no disponible y
rompen el diagnostico local y sin credenciales. Un hash de contenido puede
verificar bytes, pero renombrarlo `commit` oculta que no identifica el snapshot
Git ni permite comprobar la relacion padre/tag.

## Consecuencias

### Positivas

- Consumidores OpenCode obtienen una instalacion global estable, reversible y util desde checkout principal o worktree.
- El mismo SemVer/tag permite atribuir una divergencia a un adaptador y no a versiones distintas.
- El `commit fuente` permite atribuir ambos adaptadores al mismo snapshot
  funcional sin volver circular la metadata del release.
- El contrato canonico deja de llevar el nombre de un runtime sin romper consumidores legacy.
- La certificacion valida la experiencia operativa completa y no solo la generacion de archivos.

### Negativas

- Se mantienen dos distribuciones y una proyeccion global que deben probarse en cada release.
- La instalacion por usuario requiere administrar almacenamiento de releases inmutables y retencion segura para rollback.

## Referencias

- MEF-ADR-0017: `pipeline-state/` conserva sus señales neutrales fuera de `.mefisto/pipeline/`.
- MEF-ADR-0018: solo se extrae mecanica estable; doctrina y orquestacion permanecen separadas.
- MEF-ADR-0019: separacion publicado/interno y secuencia obligatoria registrar rutas antes de poblarlas.
- MEF-ADR-0025: el runtime custodia sus credenciales; Mefisto no las lee ni distribuye.
- MEF-ADR-0030: esquema de identificadores y reserva de `MEF-ADR-0053`.
- MEF-ADR-0031: gates sustentados por evidencia reproducible, no por archivos presentes.
- MEF-ADR-0033: Agent Skills y frontmatter portable como parte de la distribucion.
- MEF-ADR-0049: arquitectura neutral interna cuyo diferido publicado queda resuelto aqui.
- MEF-ADR-0050: neutralidad, namespace `/mefisto:*` y prefijo `mefisto-` para Skills adaptados.
- Git: [`git-commit-tree`](https://git-scm.com/docs/git-commit-tree), modelo de
  creacion de commits desde tree y padres que fundamenta la imposibilidad de un
  SHA autorreferencial y la verificacion de la relacion padre/tag.
- OpenCode Docs: [CLI](https://opencode.ai/docs/cli/), [Config](https://opencode.ai/docs/config/), [Commands](https://opencode.ai/docs/commands/), [Agents](https://opencode.ai/docs/agents/), [Skills](https://opencode.ai/docs/skills/), [Plugins](https://opencode.ai/docs/plugins/), [Permissions](https://opencode.ai/docs/permissions/) y [MCP servers](https://opencode.ai/docs/mcp-servers/). Fuente de las rutas y formas globales de la decision 2; verificadas el 2026-09-08 contra OpenCode 1.18.29, la version minima soportada.
- Claude Code Docs: [Plugins](https://docs.anthropic.com/en/docs/claude-code/plugins) y [Memory](https://docs.claude.com/en/docs/claude-code/memory).
- [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/latest/).
- `docs/testing/opencode-dogfooding.md`: evidencia del gate interno que habilita esta decision.
- Issue #1042: origen de este ADR.

## Control de cambios

- 2026-09-07: creacion como `aceptado` (issue #1042). Resuelve los diferidos publicados de MEF-ADR-0049: fuente neutral `src/published/`, nucleo exclusivo de runner/eventos `src/runtime/` y distribuciones generadas `dist/{claude,opencode}/`, sin poblar rutas antes de #1043; instalacion OpenCode global, versionada, inmutable y reversible con puntero activo atomico; un SemVer/tag para ambos adaptadores y diagnostico visible de deriva; contrato consumidor `AGENTS.md`/`.mefisto` con lectura legacy indefinida; paridad distribuible sin degradacion silenciosa; y corte vertical `/mefisto:tooling` certificado hasta PR antes de migrar el catalogo restante.
- 2026-09-08: enmienda la decision 2 (issue #1091). Fija el proyector global por enlaces a `active`, la version minima OpenCode 1.18.29 y la preservacion no destructiva de configuracion ajena; registra degradaciones de capacidades que el release aun no contiene.
- 2026-09-08: enmienda la decision 4 (issue #1099). Autoriza exclusivamente a `record-active-release` del adaptador publicado Claude a mantener temporalmente el mirror `.claude/pipeline/.plugin-root` y limpiar `.plugin-root.previous`, siempre junto a la escritura canonica primaria; reserva su retiro a un issue posterior con inventario verificable de lectores legacy eliminado.
- 2026-09-08: enmienda la decision 3 (issue #1126). Define `commit` como el commit fuente de `origin/main` capturado antes de la preparacion mecanica, no como el commit etiquetado; exige que el commit squash del tag tenga ese SHA como padre unico, limita su delta a metadata mecanica y fija manifests comparables sin diagnostico externo. Descarta SHA autorreferencial, solo SemVer, cache, Git o red del consumidor y hash de contenido renombrado como commit. Follow-ups separados: #1135 (registro de raiz transitoria), #1131 (manifiesto Claude), #1134 (alineacion OpenCode), #1132 (release) y la futura raiz Claude autocontenida.

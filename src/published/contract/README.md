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
| `kind` | requerido | requerido | selecciona tipo de salida; no se emite | selecciona tipo de salida; no se emite |
| `id` | requerido | requerido | nombre de archivo/ruta; no se emite | nombre de archivo/ruta; no se emite |
| `description` | requerido | requerido | `description` | `description` |
| `mode` | requerido | no | selecciona la forma de ejecución; no se emite | `mode` |
| `profile` | sí | sí | `model` resuelto por tabla del adaptador | no se emite `model`; hereda la configuración interactiva del usuario |
| `capabilities` | sí | sí | `tools`/`allowed-tools` generados | `permission` generado |
| `skills` | sí | sí | `skills` con ids fuente, sin prefijo | preámbulo que solicita la carga nativa on-demand de `mefisto-<id>` |
| `mcp` | sí | sí | matcher scoped por id lógico | en agentes, política `tools` cerrada por servidor; en comandos, se materializa mediante el agente delegado |
| `agent` | no | sí | delegación al agente generado | `agent` + ejecución como subtask |
| `arguments` | no | sí | `argument-hint` | hint equivalente si el runtime lo admite |

Las capacidades son intenciones cerradas: `read`, `edit`, `shell`, `web`,
`skill`, `task`. Este es el mapping que los adaptadores deben materializar;
cualquier tool o permiso no derivado queda denegado:

| Capacidad | Claude Code (`tools`/`allowed-tools`) | OpenCode (`permission`) |
|---|---|---|
| `read` | `Read`, `Glob`, `Grep` | `read`, `list`, `glob`, `grep` |
| `edit` | `Edit`, `Write` | `edit`, `write`, `patch` |
| `shell` | `Bash` | `bash` |
| `web` | `WebFetch`, `WebSearch` | `webfetch`, `websearch` |
| `skill` | `Skill` | `skill` |
| `task` | `Task` | `task` |

El mapping solo concede permisos sobre el consumidor. `edit` queda sujeto al
scope/gate del pipeline consumidor correspondiente: no sourcea ni replica como
autoridad `is_path_in_mefisto_scope`. En OpenCode tampoco habilita `lsp` de
forma implícita (MEF-ADR-0052).

## Autonomia desatendida por proyecto

MEF-ADR-0055 define una autonomia opt-in y neutral: el perfil se declara en
`.mefisto/harness.config.json` y el consentimiento se conserva por separado.
`autonomy-profile.validate.jq` es un validador puro: recibe un único JSON por
stdin, no lee disco, Git, red, reloj ni variables del host, y no activa perfiles
ni materializa permisos. Un consumidor sin `autonomy`, incluido uno con el
contrato legacy, permanece `disabled` sin obligación de adopción.

### Envelope de entrada

El caller extrae `autonomy` del config y construye este objeto cerrado:

```json
{
  "profile": { "schemaVersion": 1, "id": "operacion-local", "revision": 1,
    "commands": ["sequential"], "administration": [] },
  "consent": null,
  "context": { "projectId": "proyecto-demo", "profileDigest": "<sha-256>" },
  "catalog": ["sequential", "bitacora"]
}
```

`profile` es `null` cuando no hay declaración; de otro modo es exactamente el
subobjeto `autonomy`. Sus campos son cerrados: `schemaVersion: 1`, `id`
kebab-case, `revision` entero positivo, `commands` no vacío, único y sin el
prefijo `mefisto:`, y `administration` (posiblemente vacío). Cada grant tiene
solo `command`, `action`, `environment`, `resources` y, opcionalmente,
`planDigest`. Los ids lógicos de `command` deben estar en `commands`; los
recursos son referencias no vacías, no valores de credenciales. `planDigest`,
cuando la operación exige plan o diagnóstico aprobado, es SHA-256. El contrato
valida forma y referencias; no deduce del texto de un issue una autorización
para una operación real.

`catalog` es el array no vacío y sin duplicados de ids kebab-case suministrado
por la release. Así un id agregado o retirado exige actualizar el catálogo del
caller: no hay permisos por prefijo ni catálogo piloto hardcodeado.

El consentimiento separado es `null` o el objeto cerrado
`{schemaVersion:1,projectId,profileDigest,decision,recordedAt}`. `decision` es
`approved` o `revoked`, `profileDigest` es SHA-256 y `recordedAt` es ISO-8601
con zona horaria. El digest enlaza el registro al perfil, pero no es firma ni
prueba criptográfica de identidad humana. La ausencia de registro nunca
aprueba; un proyecto ajeno o datos malformados son conflicto.

### Digest normalizado

El caller calcula `profileDigest` sobre los bytes UTF-8, sin salto final, de:

```bash
jq -j -cS '.autonomy' .mefisto/harness.config.json
```

`-cS` produce JSON compacto con las claves ordenadas del subobjeto válido y
`-j` evita que `jq` agregue un salto final. Se calcula SHA-256 directamente
sobre esos bytes; no sobre la salida habitual de `jq -cS`, que termina en
salto de línea. La normalización no
incluye el resto del config, timestamps, rutas de worktree ni la release. Por
tanto un cambio ajeno a `autonomy` conserva el digest, mientras que una
revisión, comando o grant distinto lo cambia. Los fixtures sintéticos y su hash
estable están en `src/published/scripts/tests/fixtures/autonomy/`; los cambios de release o
recursos técnicos se revalidan aparte y no equivalen por sí mismos a nuevo
consentimiento.

### Salida

La salida siempre es el objeto cerrado
`{schemaVersion,status,reasonCode,projectId,profileDigest,profile}`. Los
estados son `disabled`, `needs-approval`, `ready` y `conflict`; `reasonCode` es
estable (`NO_PROFILE`, `CONSENT_REQUIRED`, `CONSENT_DIGEST_MISMATCH`,
`CONSENT_REVOKED`, `CONSENT_APPROVED` o un `INVALID_*`/`PROJECT_MISMATCH`).
Solo una aprobación válida con proyecto y digest coincidentes produce `ready`.
Una revocación coincidente produce `disabled`; la declaración ausente también.
No representa aislamiento del host ni certificación de un runtime.

### Lifecycle del operador

`scripts/autonomy-profile.sh` es la única interfaz local para que un operador
previsualice, apruebe o revoque un perfil. Recibe siempre una raíz explícita:

```bash
scripts/autonomy-profile.sh preview --project-root /ruta/al/consumidor
scripts/autonomy-profile.sh approve --project-root /ruta/al/consumidor --expected-digest <sha-256>
scripts/autonomy-profile.sh revoke --project-root /ruta/al/consumidor
scripts/autonomy-profile.sh inspect --project-root /ruta/al/consumidor
```

`preview` no escribe y entrega el perfil, sus grants administrativos y el digest
que debe volver en `approve`. La aprobación no ejecuta acciones administrativas
ni reemplaza sus validaciones de entorno, recurso o plan. `revoke` es idempotente
y solo impide admisiones nuevas; snapshots ya admitidos y la política de parada
conservan su ciclo propio.

Cuando `inspect` se ejecuta dentro de un checkout o worktree, la raíz explícita
debe compartir su directorio Git común normalizado. Un worktree puede consultar
la raíz principal aprobada del mismo proyecto, pero no reutilizar el registro de
otro clon o repositorio. Las operaciones de operador pueden ejecutarse desde un
directorio ajeno a Git, manteniendo siempre `--project-root` explícito.

Los adaptadores y etapas son lectores: usan exclusivamente `inspect`, cuya salida
estándar es el JSON neutral del validador. Sus códigos son 0 para `disabled` o
`ready`, 1 para `needs-approval` o `conflict`, y 2 para errores de uso o ejecución.
El registro canónico es `.mefisto/pipeline/autonomy/consent.json`; no se lee ni
escribe configuración legacy, stores de autenticación, secretos o servicios remotos.
Cuando solo existe la configuración legacy, el lector responde `disabled` sin
interpretar ni migrar una declaración que pudiera contener.
El digest ata el registro al perfil, pero no prueba identidad humana ni aísla el
registro de otro proceso con el mismo usuario del host.

```bash
jq -c -f src/published/contract/autonomy-profile.validate.jq envelope.json
src/published/scripts/tests/test-autonomy-profile-contract.sh
```

## Permisos Bash de OpenCode

La capacidad neutral `shell` genera `permission.bash` con `"*": "deny"`.
Solo se amplía para comandos que una doctrina publicada ejecuta, no para
comandos que meramente menciona. La política vigente permite `git`, `gh`,
`jq`, `cat`, `ls`, `find`, `grep`, `sort`, los scripts distribuidos, `mkdir` y
`mktemp`; el toolchain TDD añade `dotnet`, `func init`, `terraform init
-backend=false` / `validate` / `fmt`, `python3 -` (incluido `-m json.tool`),
`cd`, `echo`, `test`, `[`, `touch`, `tr`, `cut`, `head`, `tail`, `awk`, `sed`, `mv` e
`ilspycmd`. Las cuatro últimas utilidades de texto previas a `mv` cubren
subcomandos reales de tuberías y sustituciones de comando de esa doctrina.
`terraform plan`/`apply`, `func start` y `az` continúan denegados por el
default (MEF-ADR-0049 y MEF-ADR-0053). El agente `planner` (issue #1640)
sumó `date` y `printf`, ya requeridos por su propia doctrina (marcas de
tiempo de sesión, cierre documental) y ausentes hasta entonces del registro.
El agente `projections-scaffolder` (issue #1652) sumó `basename`.
El agente `bug-investigator` (issue #1667) sumó `diff`, que compara los ensamblados decompilados bajo `{{mefisto:state-path tmp}}` (nunca `/tmp`, bloqueado por `external_directory`); `az` sigue denegado y sus consultas pasan por `appinsights-query.sh` (`plan-sites`/`plan-metrics`).
El agente `test-writer` (issue #1813) suma `cut` para extraer la ruta del caché global de NuGet en su fallback de decompilación; es una utilidad de lectura de la misma familia que `tr`, `head` y `sort`, no una ampliación del shell genérico.

El issue #1750 sumó tres reglas exactas, sin comodines, porque el preámbulo OpenCode de la release activa se evalúa nodo a nodo contra esta política: `"$mefisto_opencode_launcher" package-root` (el candidato conserva las comillas literales; solo el lanzador resuelto por el preámbulo), `export MEFISTO_PACKAGE_ROOT` (exporta únicamente esa variable) y `exit 1` (aborto con diagnóstico en lugar de una denegación). No se agregan `*`, `bash *`, `sh *`, `eval *` ni `env *`. El preámbulo se reescribió sin funciones, `uname` ni `pwd -P` (usa `OSTYPE`, `cd -P` y `printf`, ya permitidos) y declara que debe repetirse en cada llamada bash que use `${MEFISTO_PACKAGE_ROOT}`, pues no se asume estado de shell persistente entre llamadas. `test-opencode-bash-permissions.sh` extrae los comandos del artefacto generado de `test-writer` y los evalúa con la semántica descrita abajo.

`docker *` continúa denegado: la política `permission.bash` es global y no
admite overrides por agente, y `docker build` ejecuta los `RUN` del Dockerfile,
así que una regla `allow` equivaldría a ejecución arbitraria para todo agente
con `shell`. La validación opcional del Dockerfile del worker de proyecciones
se expone como `scripts/validate-dockerfile.sh`, un script distribuido que se
invoca por la regla `${MEFISTO_PACKAGE_ROOT}/scripts/*`, valida que la ruta sea
relativa y esté bajo `src/`, y solo ejecuta `docker info` y `docker build -f`.

`rm *`, `curl *`, `ssh *`, `scp *` y `sudo *` conservan denegación explícita.
La excepción de `rm` casa exclusivamente candidatos cuyo texto comienza por
`rm -f`/`rm -rf` y una ruta relativa bajo `src/`, o por `rm -f` y una ruta
relativa bajo `tests/`, con variantes para una ruta entre comillas. Es una
contención léxica por prefijo, que no sustituye la normalización de comandos
de #1374. `rm -rf tests/` y los candidatos que comienzan por una ruta fuera de
esos árboles siguen denegados; además, `external_directory: deny` contiene el
acceso fuera del worktree.

La comprobación empírica contra OpenCode 1.18.29 (2026-09-15) estableció que
el patrón `*` cruza `/`, que el candidato preserva las comillas literales y
que se evalúa un candidato por cada nodo `command` del árbol de Bash (también
en listas compuestas). Las reglas se resuelven por última coincidencia, por lo
que el deny general de `rm` aparece antes de las excepciones acotadas que lo
sobrescriben. Este orden y las variantes entre comillas son deliberados.

Al ampliar esta lista, se inventarían primero los comandos realmente
ejecutados por la doctrina publicada, se conservaría la denegación por defecto
y se acotaría por prefijo de ruta cuando el matcher lo permita
(MEF-ADR-0031). La normalización pendiente de los `rm` de
`domain-scaffolder` se apoya en estos hallazgos (issue #1374).

## Lectura externa de OpenCode (`external_directory`)

El runtime publicado lee fuera del worktree la release de Mefisto y la
configuración de agentes instalada. Con las capacidades `read` o `shell`,
`external_directory` es un mapa (`PermissionRuleConfig`, igual que `bash`;
`@opencode-ai/sdk` 1.18.29, `dist/v2/gen/types.gen.d.ts`) con `"*": "deny"` y
`allow` solo para esta lista blanca; sin esas capacidades queda en `deny`
escalar. La reciben los agentes con `read` o `shell`; hoy son los 22 agentes
publicados: `apim-gateway-scaffolder`, `bug-investigator`, `domain-scaffolder`,
`historiador`, `implementer`, `infra-base-scaffolder`, `infra-bootstrap`,
`infra-reviewer`, `infra-writer`, `mcp-scaffolder`, `planner`, `pr-sync`,
`projection-implementer`, `projection-test-writer`, `projections-scaffolder`,
`reviewer`, `smoke-test-writer`, `test-writer`, `tooling-investigator`,
`tooling-reviewer`, `tooling-writer` y `workos-identity-scaffolder`.

| Ruta permitida (lectura) | Contenido |
|---|---|
| `~/Library/Application Support/mefisto/*` (macOS) | raíz de datos: release activa y releases instaladas |
| `~/.local/share/mefisto/*` (Linux) | ídem |
| `~/.config/opencode/{agents,commands,skills}/*` | adaptadores instalados |

Sintaxis de patrones ([Permissions de OpenCode
1.18.29](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/web/src/content/docs/permissions.mdx)):
el candidato es el directorio padre absoluto del archivo más `/*`, `*` cruza
`/` (así una raíz con espacios casa sin escapes) y `~`/`$HOME` al inicio del
patrón se expande al home, por lo que el JSON generado no necesita rutas reales
y `project-opencode-release.sh` no cambia. La comparación es léxica: no se
resuelven symlinks, de modo que `active/` (enlace dentro de la raíz permitida)
funciona, y un enlace dentro de la lista blanca que apunte afuera no se
contiene por este mecanismo.

Siguen denegados por el `*` del mapa: `~/.config/opencode/opencode.jsonc`
(puede contener API keys, MEF-ADR-0025), `plugins/`, `node_modules/`,
`~/.local/share/opencode` (credenciales del runtime) y toda otra ruta externa.
Las denegaciones de `read` de `.env*`, `auth.json`, `.aws` y `.ssh` se
conservan y se añaden `**/opencode.jsonc` y `**/.local/share/opencode/**`.

La excepción es solo lectura: `edit`/`write`/`patch` deniegan `../*` (el
candidato de una ruta externa es relativo al worktree y empieza por `../`) y los
patrones `~` de la lista blanca; `bash` deniega `touch`, `mv`, `mkdir`, `rm`,
`cp` y `sed -i` cuyo texto contenga un marcador de ruta de la raíz de datos,
de la configuración de OpenCode o de `MEFISTO_PACKAGE_ROOT`, evaluado después de
todos los `allow` (gana la última coincidencia). Límites: `XDG_DATA_HOME` y
`XDG_CONFIG_HOME` no estándar no se expresan con patrones estáticos y quedan
denegados (falla cerrado); las redirecciones de shell (`>`) no forman parte del
candidato de un nodo `command` y no se contienen aquí, igual que antes de este
cambio. El test de contrato `test-opencode-external-directory.sh` evalúa el
permiso generado con esta semántica (sin OpenCode real).

`mcp` no es una tool ni un permiso de runtime: es una lista de ids lógicos
kebab-case. `mcp-servers.json` es la autoridad neutral de esos ids y de su
provisioning; `published-artifact.schema.json` debe conservar exactamente el
mismo enum y orden. El registro inicial distingue `microsoft-learn` como
`bundled` (HTTP remoto HTTPS, sin autenticación) de `terraform` como
`external` (sin transporte, URL ni autenticación): Mefisto no distribuye ni
custodia Terraform. Agregar otro id requiere actualizar el registro, el
contrato y los mappings de todos los adaptadores. Si un runtime carece del
mapping de un id declarado, su validación/generación aborta; nunca concede MCP
genérico.

El registro no admite headers, environment, OAuth, tokens, secretos ni otras
credenciales. Para cada entrada `bundled`,
`validate-published-mcp.sh` deriva en memoria la proyección Claude
(`remote-http` a `type: http`) y exige que `.mcp.json` sea idéntico, sin
servidores externos ni claves adicionales. `.mcp.json` sigue versionado como
adaptador Claude, no como autoridad conceptual.

| Provisioning neutral | Claude Code | OpenCode |
|---|---|---|
| `microsoft-learn` / `bundled` | `.mcp.json`, HTTP remoto sin autenticación | `plugins/mefisto-mcp.js`, proyectado globalmente; el hook `config` agrega `type: "remote"`, `enabled: true` y `oauth: false` solo si la clave no existe |
| `terraform` / `external` | instalación externa al plugin | instalación externa al plugin; nunca se agrega a `config.mcp` |

El plugin OpenCode se genera como asset suplementario desde el registro, se
instala y retira mediante el ledger global, y no lee ni modifica
`opencode.json`. Ante una definición preexistente distinta, la configuración
del usuario gana y el hook emite `mcp_config_conflict` sin incluir su valor.
OpenCode emite para cada agente una entrada `tools` por cada servidor del
registro: `false` por defecto y `true` solo para `<id>_*` solicitado. Un
comando no tiene un campo equivalente: si declara `mcp`, debe delegar a un
agente neutral existente cuyo `mcp` sea un superconjunto; el validador rechaza
la ausencia de agente o cualquier subconjunto incumplido. `external` no cambia
esta allowlist y su ausencia queda visible en OpenCode; Mefisto no instala
binarios, plugins ni credenciales. El smoke real de conexión y listado queda
diferido a #1066. El formato del servidor remoto y la carga de
plugins globales siguen la documentación oficial de OpenCode 1.18.29:
[MCP servers](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/web/src/content/docs/mcp-servers.mdx)
y [Plugins](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/web/src/content/docs/plugins.mdx).

Toda referencia `skills` debe resolver a un `skills/<id>/SKILL.md` publicado,
ser única y conservar el id lógico sin prefijo. Claude Code materializa esos
ids directamente en su frontmatter. OpenCode transforma cada uno en
`mefisto-<id>` y antepone una instrucción mínima para cargarlo mediante su tool
nativa `skill`, antes del body; no copia la doctrina ni menciona rutas. En los
agentes OpenCode, declarar referencias exige además la capacidad neutral
`skill`: su `permission.skill` niega `*` y permite exactamente los nombres
adaptados. Si la capacidad existe sin referencias, conserva la política general
de la capacidad. Los comandos solo solicitan la carga: el permiso efectivo es
el del agente que los ejecuta y una denegación permanece visible.

| Referencia neutral | Claude Code | OpenCode |
|---|---|---|
| `skills: ["x"]` | frontmatter `skills: ["x"]` | preámbulo `skill` para `mefisto-x`; en agentes con capacidad `skill`, allowlist exacta en `permission.skill` |

Las referencias `agent`, igual que los argumentos `<id>` de las directivas,
también conservan ids fuente sin prefijo. El prefijo adaptado no pertenece a la
fuente. La carga on-demand y el override por agente custom siguen el contrato
oficial de [Agent Skills de OpenCode
1.18.29](https://github.com/anomalyco/opencode/blob/v1.18.29/packages/web/src/content/docs/skills.mdx).

## Layout de Skills empaquetados

Los Skills publicados son fuente de solo lectura bajo `skills/<id>/`: `SKILL.md`
es Nivel 2 y sus recursos relativos son Nivel 3 (MEF-ADR-0033). El adaptador
OpenCode enumera ese árbol de forma determinista y lo materializa como
`dist/opencode/skills/mefisto-<id>/`. Solo transforma el campo `name` del primer
frontmatter de `SKILL.md` al mismo nombre del directorio; todos los recursos se
copian byte a byte. La proyección global enlaza después esos archivos en
`<config>/opencode/skills/mefisto-<id>/`. La prueba de carga on-demand mediante
la tool `skill` corresponde a la certificación #1066.

## Directivas del body

Todo artefacto incluye `{{mefisto:assert-consumer-repo}}`, que aborta si el cwd
es el repositorio de Mefisto. Cualquier directiva `{{mefisto:...}}` no listada
o mal formada se rechaza.

| Directiva | Claude Code | OpenCode |
|---|---|---|
| `{{mefisto:assert-consumer-repo}}` | guard generado que aborta en el repo de Mefisto | el mismo guard de consumidor, sin importar políticas internas |
| `{{mefisto:launch-agent <id> <mensaje>}}` | instrucción de invocar la tool `Task` con el agente `mefisto:<id>` y el mensaje dado | instrucción de invocar la tool `task` con el agente global generado `<id>` y el mensaje dado |
| `{{mefisto:run <script> <args>}}` | `MEFISTO_RUNTIME=claude` + script bajo `MEFISTO_PACKAGE_ROOT` + argumentos | `MEFISTO_RUNTIME=opencode` + script bajo `MEFISTO_PACKAGE_ROOT` + argumentos |
| `{{mefisto:package-root}}` | `MEFISTO_PACKAGE_ROOT` | `MEFISTO_PACKAGE_ROOT` |
| `{{mefisto:skill-root <id>}}` | raíz de `skills/<id>/` bajo `MEFISTO_PACKAGE_ROOT` | raíz de `skills/mefisto-<id>/` bajo `MEFISTO_PACKAGE_ROOT` |
| `{{mefisto:command-doc <id>}}` | ruta de `commands/<id>.md` bajo `MEFISTO_PACKAGE_ROOT` | ruta de `commands/mefisto:<id>.md` bajo `MEFISTO_PACKAGE_ROOT` |
| `{{mefisto:config-path}}` | `MEFISTO_CONFIG_PATH` (ruta efectiva de lectura) | `MEFISTO_CONFIG_PATH` (ruta efectiva de lectura) |
| `{{mefisto:instructions-path}}` | `MEFISTO_INSTRUCTIONS_PATH` (ruta efectiva de lectura) | `MEFISTO_INSTRUCTIONS_PATH` (ruta efectiva de lectura) |
| `{{mefisto:state-path <rel>}}` | `.mefisto/pipeline/<rel>` del consumidor | `.mefisto/pipeline/<rel>` del consumidor |
| `{{mefisto:command <id>}}` | `/mefisto:<id>` | `/mefisto:<id>` |

### Delegación en agentes

Hay dos formas, excluyentes dentro de un mismo comando:

1. **Delegación de comando completo**: el frontmatter `agent: <id>`. En OpenCode
   emite `agent` + `subtask: true`; en Claude el body queda precedido por la
   instrucción de invocar `Task` con `mefisto:<id>`, pasándole `$ARGUMENTS`
   y las instrucciones del body, sin que la sesión primaria las ejecute (paridad
   con el template que OpenCode entrega al subtask).
2. **Delegación puntual**: `{{mefisto:launch-agent <id> <mensaje>}}` en el body.
   El mensaje es obligatorio, texto libre en una línea (sin `{` ni `}`), y puede
   citar variables que el comando ya resolvió. El adaptador lo traduce a la
   invocación de la tool de subagentes sobre el agente generado de su
   distribución; el agente devuelve su resultado final y el comando continúa
   con el paso siguiente. Nunca convierte el comando en subtask, así que los
   pasos propios del comando conservan su política de permisos (MEF-ADR-0031).

Un body puede tener varias delegaciones puntuales (alternativas o sucesivas). Un
comando que declara `agent` no puede además usar `launch-agent`. El validador
rechaza `launch-agent` sin mensaje, con un id inexistente en
`src/published/agents/` o junto a `agent`; la regla de MCP considera la unión de
los `mcp` de todos los agentes delegados. `command-doc` compone comandos por
lectura del body, por eso la delegación puntual, expresada en el body, es la
forma que sobrevive a esa composición.

Decisión sobre la capacidad `task`: el comando no la declara; la sesión primaria
del usuario ya dispone de la tool de subagentes y `allowed-tools` solo
preaprueba, no restringe su disponibilidad.

Verificación empírica (CA-6, #1687): pendiente. Requiere una sesión interactiva
real de cada runtime con un comando fixture de delegación puntual; no se pudo
ejecutar en el pipeline no interactivo. Hasta registrar fecha y versión de cada
runtime, la devolución del resultado al comando no está certificada.

Los adaptadores materializan comandos como `/mefisto:<id>`. El body no puede
nombrar CLIs, variables, cachés, directorios ni metadata de un runtime. Tampoco
admite placeholders distintos de `$ARGUMENTS`.

`skill-root` acepta exclusivamente un id kebab-case lógico, sin prefijo de
runtime. El id debe existir bajo `skills/<id>/SKILL.md` y estar declarado en
`skills` por ese mismo artefacto; por tanto expresa una dependencia ya cargada,
no un inventario alternativo. `command-doc` acepta exclusivamente un id kebab-case lógico de un comando
publicado (`src/published/commands/<id>.md`), sin prefijo de runtime, y un
comando no puede referirse a sí mismo. La ruta apunta al comando **generado de
la distribución activa**, que ya trae sus directivas traducidas para esa
sesión. Su uso previsto es la composición por lectura (leer la doctrina de otro
comando en lugar de duplicarla), no su ejecución.

Cuando un body usa `run`, `package-root`, `skill-root` o
`command-doc`, el adaptador antepone un bloque Bash
que valida y exporta una única raíz física sin barra final:
`MEFISTO_PACKAGE_ROOT`. Claude valida la distribución cargada desde su variable
de runtime o los markers canónico/legacy del consumidor; OpenCode consulta el
launcher de la release activa. Esta mecánica es exclusiva de cada salida: la
fuente neutral y sus callers no conocen variables ni layouts de runtime.

Cada invocación traducida de `{{mefisto:run <script> <args>}}` fija además,
como asignación en línea inmediatamente antes del script, `MEFISTO_RUNTIME=<id
del adaptador>` (`claude` o `opencode`). El adaptador impone su propio runtime
sobre cualquier valor que ya traiga el entorno: es la misma garantía de
`mefisto_resolve_runtime` (MEF-ADR-0050) que evita que un pipeline lanzado
desde un runtime corra sus scripts bajo el identificador de otro cuando la
máquina tiene ambos instalados y el entorno no fija la variable.

`config-path` e `instructions-path` no traducen a una ruta canónica literal:
resuelven la ruta efectiva de lectura del contrato consumidor descrita en
MEF-ADR-0053 sección 4 (canónica primero, fallback legacy de lectura
únicamente si la canónica falta, aborto con diagnóstico si no existe ninguna).
Cuando un body usa una o ambas directivas, el adaptador antepone un único
bloque Bash adicional -- independiente del de `package-root` -- que resuelve
cada ruta usada exactamente una vez y exporta `MEFISTO_CONFIG_PATH` y/o
`MEFISTO_INSTRUCTIONS_PATH`; cada aparición inline de la directiva se traduce
a la variable ya resuelta, de modo que varios usos en el mismo body comparten
esa única inicialización. Si existen ambas variantes de una misma ruta, el
bloque generado elige la canónica, informa por stderr que ignora la legacy y
nunca combina contenido de las dos. Para `config-path`, la precedencia y el
texto de los diagnósticos coinciden con `resolve_harness_config_path read` de
`scripts/_pipeline-common.sh` -- con las rutas expresadas relativas a la raíz
del consumidor, donde el resolver las interpola absolutas; para `instructions-path`, el mismo mecanismo
aplica sobre las directivas del consumidor y el diagnóstico de ausencia total
apunta a `{{mefisto:command onboard}}`. Los nombres de archivo legacy
concretos sólo existen dentro de ese bloque generado, nunca en la fuente
neutral ni en este contrato.

## Matriz de entrada de comandos

`command-entry.json` declara exclusivamente las necesidades directas de los 27
comandos publicados. `command-entry.jq` comprueba ids, campos cerrados,
referencias `command-doc` y `launch-agent`, ciclos y calcula la clausura de
composición. La clausura une necesidades de comandos compuestos; nunca hereda
las capacidades de un agente delegado ni interpreta
`{{mefisto:command ...}}` como llamada. Sí enumera los agentes alcanzables para
que esa topología pueda verificarse sin convertirla en capacidades del padre.
El adaptador OpenCode emite `command-entry-manifest.json`: hashes SHA-256 del
contenido Markdown renderizado y recortado por el loader, sin incluir cuerpos.
Su huella técnica permite revalidar snapshots, no equivale a consentimiento.

## Biblioteca de rutas de recursos

`scripts/lib/resource-paths.sh` es una biblioteca Bash 3.2 + `jq` que se carga
sin efectos y expone consultas puntuales, sin crear directorios ni cambiar el
cwd del caller:

```bash
resource_path_resolve /ruta/absoluta existing # JSON: logicalRoot, physicalRoot, exists
resource_path_resolve /ruta/absoluta planned
resource_path_relative /base/absoluta /destino/absoluto # string JSON; igualdad es ""
resource_path_contains /padre/absoluto /hijo/absoluto
```

Las entradas deben ser absolutas, sin controles ni componentes `.` o `..`.
`resolve` sigue enlaces de directorios existentes; en `planned` conserva sin
escribir el primer sufijo inexistente bajo un ancestro ya normalizado. `resolve`
y `relative` retornan JSON; `relative` y `contains` operan por segmentos sobre
la forma léxica normalizada y no vuelven a consultar el filesystem. `resolve`
usa 0 para éxito, 1 para filesystem no resoluble y 2 para uso inválido;
`contains` retorna 0 para igualdad/descendencia por
segmentos, 1 para no contención y 2 para entrada inválida. Es una observación
puntual, no una defensa TOCTOU, un walker seguro de todo el árbol ni una
autorización de recursos. No recorre contenidos de home, configuración o stores
de autenticación (MEF-ADR-0019, MEF-ADR-0025, MEF-ADR-0031 y MEF-ADR-0053).

La regresión vive en `scripts/tests/test-resource-paths.sh`; compara su corpus
de relativos con `node:path.relative` solo durante pruebas. Node no es una
dependencia productiva de la biblioteca.

## Validación

```bash
src/published/scripts/validate-published-artifacts.sh [archivo...]
```

Sin argumentos valida `src/published/{agents,commands}/*.md`. Cada rechazo usa
`<archivo>: <campo|body>: <motivo>`. El script requiere Bash 3.2 y `jq`; los
fixtures y su prueba están en este contrato y en
`scripts/tests/test-published-artifact-contract.sh`.

```bash
src/published/scripts/validate-published-mcp.sh
```

El segundo validador comprueba el schema del registro, sus reglas cruzadas, la
sincronía del enum MCP y la proyección `.mcp.json`; tampoco realiza llamadas de
red.

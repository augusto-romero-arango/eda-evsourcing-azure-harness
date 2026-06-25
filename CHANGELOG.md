# Changelog

Todo cambio notable a este proyecto se documenta aquí. Sigue [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y [Semantic Versioning](https://semver.org/lang/es/).

## [Unreleased]

### Added

- **`scripts/bootstrap-backend.sh` y campo opcional `azureLocation` para inicializar el backend de Terraform en greenfield** (issue #83): se crea el script publicado `bootstrap-backend.sh` que materializa, de forma **idempotente**, el backend remoto del `tfstate` -- prerequisito del pipeline IaC, que recien despues levanta los App Service Plans/Function Apps por dominio (ADR-0020). El camino documentado se rompia porque ese script no existia: nada creaba el Resource Group `rg-<proyecto>-tfstate`, la Storage Account ni el container `tfstate`, y `setup-github-ci.sh` ya asumia el backend creado (solo asignaba `Storage Blob Data Reader` al Service Principal). El script lleva la cabecera estandar (`set -euo pipefail`, `source _pipeline-common.sh`, guard defensivo `.claude-plugin/plugin.json` que aborta si se invoca dentro de Mefisto -- ADR-0019 --, `load_harness_config`); parsea `--env <dev|staging|prod>` (default `dev`), `--location <region>` y `--subscription <id>` (tambien posicional); resuelve nombres desde el config sin hardcodear (`RG="${HARNESS_RG_PREFIX}-tfstate"`, `STORAGE="${HARNESS_TFSTATE_STORAGE}"`, `CONTAINER="tfstate"`); fija la suscripcion explicitamente (`az account set`) antes de operar; crea con verificacion de existencia previa en cada paso (`az group create`, `az storage account create` con TLS 1.2 minimo, `--https-only true`, `--allow-blob-public-access false`, versioning + soft-delete de blobs, y `az storage container create --auth-mode login`); escribe `infra/environments/<env>/backend.tf` con el bloque `backend "azurerm"` resuelto (`key = "<env>.tfstate"`) de forma idempotente; e imprime el bloque resultante para que cuadre con el `terraform init` del `infra-reviewer`. Se anade el campo **opcional** `azureLocation` al schema de `harness.config.json`: si no se pasa `--location`, el script lo lee inline con `jq` (mismo patron que `repoSlug` en `_pipeline-common.sh`); si tampoco existe, aborta pidiendo el flag o el campo. Al ser opcional (default + override por flag) NO es un cambio incompatible del schema (no es MAJOR). Se documenta una seccion nueva "Primeros pasos con el harness (greenfield)" en `README.md` (modelo de ejecucion `$PLUGIN_SCRIPTS`/hook `SessionStart`, orden de bootstrap `bootstrap-backend.sh` -> `setup-github-ci.sh` -> primer `/infra`, scaffold + primer ciclo TDD, y tabla "que corre donde") y el campo `azureLocation` en el esquema de la seccion 3. El script entra en la cobertura del test `scripts/tests/test-guards.sh`. Origen: greenfield real (consumidor `MiControlPlane` con `mefisto@0.6.0`).

### Changed

- **El check de `[Unreleased]` del pipeline interno `/mefisto-tooling` pasa de warning a GATE, y el writer redacta la entrada por defecto** (issue #70): el patron cinturon + tirantes sube el liston de "recordatorio pasivo" a "trabajo exigido". *Cinturon*: el `STAGE1_PROMPT` del writer (`.claude/scripts/mefisto-tooling-pipeline.sh`) gana una instruccion explicita para anadir una entrada bajo `## [Unreleased]` en `CHANGELOG.md` con la categoria Keep a Changelog correcta (`Added`/`Changed`/`Fixed`/`Removed`), con excepcion de cambios que toquen exclusivamente bitacora o gobierno no notable. *Tirantes*: el bloque que antes solo emitia `warn` (introducido en #36, que en modo no-interactivo se ignoraba y dejaba PRs sin entrada que `/mefisto-release` tenia que backfillear -evidencia: PRs #62/#63/#67-) ahora ABORTA cuando el cambio es notable y `[Unreleased]` no recibio contenido. Se anaden a `.claude/scripts/_mefisto-common.sh` las funciones `is_path_changelog_exempt` (clasifica rutas exentas: `docs/bitacora/**`, `README.md`, `CLAUDE.md`, `.gitignore`) y `changes_require_changelog` (un cambio es notable si toca al menos una ruta no exenta). El gate corre tras el reviewer (Stage 2) y antes de crear el PR; si el writer omitio la entrada, el operador la anade y retoma con `--from-stage 2`. Se mantiene la degradacion benigna sin `python3` (no aborta para evitar falsos positivos). Cubierto por el test interno `.claude/scripts/tests/test-changelog-gate.sh`. Acotado al pipeline INTERNO (ADR-0019); el equivalente para el pipeline publicado queda como follow-up opt-in.

### Fixed

- **`agents/infra-bootstrap.md` resuelve los scripts del plugin con el patron canonico `$PLUGIN_SCRIPTS` en vez de rutas relativas rotas** (issue #83): el agente invocaba `./infra/scripts/bootstrap-backend.sh` y `./scripts/iac-pipeline.sh` (lineas 38, 48 y 69), que con `cwd = repo consumidor` resolvian contra `<consumer>/...` (inexistente) -- los scripts del harness viven en el cache del plugin (read-only). `infra-bootstrap` habia quedado fuera del patron `$PLUGIN_SCRIPTS` que ya usan `commands/` y los agentes `planner`/`reviewer` (mecanismo `.plugin-root` de los issues #31/#61). Ahora resuelve `PLUGIN_ROOT`/`PLUGIN_SCRIPTS` (lee `.claude/pipeline/.plugin-root` con fallback por glob al cache) e invoca `"$PLUGIN_SCRIPTS/bootstrap-backend.sh"` y `"$PLUGIN_SCRIPTS/iac-pipeline.sh"`, pasando `--subscription` explicitamente. Ademas indica que si `bootstrap-backend.sh` reporta que el backend ya existe (idempotencia, exit 0) debe continuar al pipeline IaC, no abortar.

## [0.6.0] - 2026-06-24

### Added

- **Convencion "el modelo de dominio rico no cruza el bus" en `IPublicEvent`** (issue #65): se amplia ADR-0012 con una seccion ("Frontera de serializacion: event store vs bus") que establece que el payload de un `IPublicEvent` solo contiene tipos serializables con el serializador por defecto (primitivos, enums, `string`, fechas, `record` DTO planos); el modelo de dominio rico (campos privados, factory privado, `ConfigurarSerializacion`) NO cruza el bus y se traduce a una forma plana al publicar. Motivacion: `ConfigurarSerializacion` (resolver STJ custom) solo esta registrado en el event store de Marten del dominio productor; cuando el mismo tipo cruza Azure Service Bus el serializador de destino no tiene ese resolver y el payload se vuelve lossy/no-portable (bug reproducido en un consumidor). La convencion se hace cumplir en el flujo de agentes publicados: `planner` incluye las consideraciones de construccion del evento publico (payload plano y portable) en el handoff de la tarea; `implementer` documenta la restriccion de forma en la tabla de ubicacion de eventos; `reviewer` vigila problemas de serializacion contra Azure Service Bus; y `test-writer` exige un test de round-trip con `JsonSerializerOptions` por defecto (SIN el resolver custom), que distingue "viaja por el bus" de "viaja por Marten" -el guardrail de round-trip anterior corria CON el resolver y no detectaba el defecto-. Indice tematico de ADRs en `CLAUDE.md` actualizado.

### Fixed

- **Los pipelines que crean worktree ramifican siempre desde `origin/main` actualizado** (issue #66): los cinco scripts que crean un worktree nuevo (`scripts/tdd-pipeline.sh`, `scripts/tooling-pipeline.sh`, `scripts/iac-pipeline.sh`, `scripts/scaffold-pipeline.sh` y el interno `.claude/scripts/mefisto-tooling-pipeline.sh`) lo hacian desde el HEAD del directorio donde se lanzaba el pipeline. Si el cwd estaba parado en una rama de feature vieja, el worktree nacia de una base desactualizada y los conflictos con main aparecian tarde (en la sincronizacion final de la fase verde) en vez de evitarse desde el inicio. El antipatron era identico en los cinco: un guard que solo emitia `warn` si el cwd no estaba en `main`/`master` (sin abortar ni corregir), un `git pull origin "$CURRENT_BRANCH"` que actualizaba la rama equivocada, y un `git worktree add ... -b <rama>` sin commit-ish base. Se reemplaza por `git fetch origin main` (con `abort` si falla) + `git worktree add ... -b <rama> origin/main`, replicando el patron ya probado de `.claude/scripts/mefisto-release.sh`. El worktree se ramifica **siempre** desde `origin/main` sea cual sea la rama del cwd (el guard queda degradado a contexto informativo en el log); el `fetch` es seguro desde cualquier rama porque no muta el working tree ni el HEAD del cwd. La sincronizacion final con `origin/main` (`merge origin/main --no-edit`) se mantiene intacta como red de seguridad para PRs mergeados durante la ejecucion, pero en el caso comun `BEHIND_COUNT` sera 0. Cubre lado publicado (`scripts/`) e interno (`.claude/scripts/`); los orquestadores (`parallel-pipeline.sh`, `batch-pipeline.sh`, `mefisto-batch-pipeline.sh`) no crean worktrees y quedan cubiertos transitivamente. Origen: pipeline TDD del consumidor Bitakora.ControlAsistencia cuyo worktree nacio 7 commits detras de `origin/main`.

## [0.5.0] - 2026-06-24

### Added

- **Regla del "oraculo independiente" en `test-writer` y ADR-0002** (issue #59): el agente `test-writer` gana la regla absoluta 20, que exige construir el valor esperado de toda asercion (`Then`, `And<>`, `ThenIsPublished*`) a mano como oraculo independiente -armado con las primitivas y factories del dominio- y **prohibe** derivarlo ejecutando la logica bajo prueba (ni el SUT ni los colaboradores de produccion que esa logica invoca). Un esperado calculado por el mismo codigo que se verifica vuelve el test tautologico: el bug contamina por igual el esperado y el actual, ambos coinciden y la prueba pasa sin detectar la regresion. La seccion "Verificacion del estado del agregado" (paso 4) lo refuerza con ejemplo de antipatron (`var esperado = ConsolidadorDesgloseHoras.Consolidar(...)`) y de patron correcto (esperado armado con `new DesgloseHoras(...)` + `IntervaloTemporal.Crear(...)`). El principio queda registrado como decision arquitectonica en **ADR-0002**, subseccion "Oraculo independiente (no-tautologia)", al mismo nivel normativo que la cobertura obligatoria Then + And ya documentada ahi, y la regla 20 lo referencia como fuente. Origen: review del PR #180 del consumidor Bitakora.ControlAsistencia, donde sin esta prohibicion el test-writer tomo el atajo de calcular el esperado con la misma consolidacion del SUT. Acotado a `test-writer`; `smoke-test-writer` no se toca.

### Fixed

- **Resolucion de los scripts del plugin contra la raiz instalada en vez de ruta relativa al cwd** (issue #31, PR #62): los 9 comandos publicados (`implement`, `tooling`, `scaffold`, `sequential`, `infra`, `parallel`, `merge`, `health-check`, `bug`) invocaban sus scripts como `./scripts/<x>.sh`; con `cwd = repo consumidor` esa ruta resolvia contra `<consumer>/scripts/` (inexistente) en vez del cache del marketplace donde vive el plugin, asi que el pipeline no arrancaba y el script parecia "ausente". Se anade un hook `SessionStart` en `hooks/hooks.json` que persiste `${CLAUDE_PLUGIN_ROOT}` -disponible en los hooks del plugin, no en los bloques bash de un slash command- en `.claude/pipeline/.plugin-root`, y cada comando resuelve `PLUGIN_ROOT` leyendo ese archivo con fallback automatico a un glob ordenado del cache (`~/.claude/plugins/cache/*/mefisto/*/`, `sort -V`) e invoca `"$PLUGIN_SCRIPTS/<x>.sh"`. Los comandos internos `.claude/commands/mefisto-*` no se tocan: corren con `cwd = repo de Mefisto`, donde la ruta relativa es la correcta (ADR-0019).
- **Resolucion de referencias a ADRs contra la raiz del plugin en skills y agentes publicados** (issue #61, PR #63): `commands/implement.md` (fase 1.5, validacion de Definition of Ready) y los agentes `planner`, `reviewer` y `test-writer` referenciaban los ADRs del marco como `docs/adr/NNNN-*.md` relativos al cwd; con `cwd = consumidor` resolvian contra `<consumer>/docs/adr/` y el ADR parecia "ausente" (sintoma observado en campo: ADR-0011 / Definition of Ready ausente al correr `/implement`). Se reutiliza el mecanismo `.plugin-root` de #31: cada artefacto resuelve e imprime `PLUGIN_ROOT` antes de abrir el ADR y referencia `"$PLUGIN_ROOT/docs/adr/<archivo>.md"`. Cubre las 8 referencias en los 4 archivos (incluida la de `test-writer.md` a ADR-0002 que anadio #59). El lado interno `.claude/` no se modifica (ADR-0019).

## [0.4.1] - 2026-06-23

### Fixed

- **`tmux-pipeline.sh` (publicado) arranca el pipeline en el pane correcto con `pane-base-index 1`** (issue #56): las 6 funciones que abren panes (`cmd_single`, `cmd_batch`, `cmd_parallel`, `cmd_tooling`, `cmd_infra`, `cmd_scaffold`) ya no direccionan el pane del sub-script por indice implicito (`"$session:main.1"`) sino por su `pane_id` (`%N`), estable e independiente de `base-index`/`pane-base-index`. El tail captura su id con `tmux list-panes -F '#{pane_id}' | head -n1` y cada `split-window` devuelve el suyo con `-P -F '#{pane_id}'`. Con `setw -g pane-base-index 1` en `~/.tmux.conf` los panes se numeran 1 y 2 (no 0 y 1), por lo que `main.1` apuntaba al pane del `tail` (que ignora stdin) y el pipeline nunca arrancaba: no aparecia el status file y `/work-status` no mostraba progreso. `cmd_parallel` tenia la variante mas grave (todos los `send-keys` apuntaban a `"$session:main"`, el pane del tail, con cualquier `pane-base-index`); ahora cada issue recibe su sub-script en el `pane_id` que devuelve su propio `split-window`. Es la deuda de paridad de ADR-0019: el mismo patron `pane_id` se aplico solo al gemelo interno (`.claude/scripts/mefisto-tmux-pipeline.sh`, PR #12) y nunca se propago al lado publicado, que es el que consume el proyecto.

## [0.4.0] - 2026-06-23

### Added

- **Microconvencion de estilo "condiciones en positivo"** en `implementer.md`: prescribe preferir `if (existe)` sobre `if (!existe)`, ordenar las ramas `if`/`else` para que la guarda quede afirmativa, y documenta la excepcion de las guard clauses / early-return. El `reviewer` la verifica en fase refactor bajo el lente "Legible". Tambien se corrigio el ejemplo canonico de crear-o-actualizar que mostraba la guarda negada.
- **Recordatorio de CHANGELOG en `/mefisto-tooling`**: el pipeline interno verifica al final (warning, no gate) si el PR anadio contenido bajo `## [Unreleased]` en `CHANGELOG.md` y, de no ser asi, emite un recordatorio accionable. El PR se crea igual. Evita que los cambios lleguen a `main` con `[Unreleased]` vacio y rompan la fase *prepare* de `/mefisto-release` (issue #36).
- **ADR-0020** "Hosting de Azure Functions - un App Service Plan por dominio" (issue #44): fija la directiva canonica del marco de **un App Service Plan dedicado por Function App (dominio)**, no compartido. Documenta la restriccion dura de `DurabilityMode.Solo` (un solo nodo -> prohibido escalar horizontal -> solo eje vertical -> aislar por app), el sintoma noisy-neighbor de los agentes de durabilidad always-on, las proscripciones (no Consumption `Y1` con .NET 10+, no Wolverine `Serverless` mode), los defaults (`B1`, `worker_count = 1`, `always_on` OFF en dev / evaluar ON en prod) y el contrato del modulo `modules/service-plan` del consumidor. Se registra en el indice de `CLAUDE.md` (junto con ADR-0019, antes omitido) y se corrige el conteo de ADRs en `README.md` (18 -> 20).

### Changed

- **Scaffolder emite un App Service Plan dedicado por Function App** (issue #43): el agente `domain-scaffolder` (Paso 4) ahora genera un `module service_plan_<dominio>` propio por dominio (`source ../../modules/service-plan`, `name = asp-...-<dominio>`, `sku_name`, `worker_count = 1`, `os_type`, `always_on`) y enlaza la Function App a ese plan (`service_plan_id = module.service_plan_<dominio>.id`), en lugar de apuntar todas a un `module.service_plan` compartido (la causa del noisy-neighbor que origino el #43). El flujo de aprovisionamiento (Parametros de entrada y Paso 0) **pide/acepta los parametros de hosting** (SKU default `B1`, `always_on` OFF en dev) con override del usuario y los muestra en el resumen de confirmacion. Se anade un aviso si el modulo `modules/service-plan` del consumidor no acepta esos inputs (mismo patron que el aviso de `module.postgresql`). El `infra-writer` actualiza el naming de Service Plans a `asp-<proyecto>-<env>-<dominio>`, el `infra-reviewer` agrega al checklist de Arquitectura "cada Function App tiene su Service Plan dedicado" y lo refleja en el resumen del plan, y `/scaffold` incluye el Service Plan dedicado en el resumen de "lo que se va a crear". Alinea el harness con ADR-0020 (#44). Aplica a dominios nuevos; no migra infra existente.
- **Fase 5 de `/fix-review` (publicado) adaptada al modelo plugin** (issue #38): las mejoras a agentes/skills del harness ya no se editan en la rama del PR del consumidor (esos archivos viven read-only en el cache del plugin), sino que se enrutan como **draft** (`estado:borrador`) al repo de Mefisto via `gh -R`, reutilizando el routing cross-repo del `planner` y el `tooling-investigator`. La edicion en-rama queda reservada a lo que realmente vive en el consumidor (ADR local, convenciones de su `CLAUDE.md`). Se documenta la deteccion de modelo plugin y la field note sigue generandose en el consumidor.
- **`bug-investigator` detecta el noisy-neighbor y verifica el aislamiento por Service Plan** (issue #45): el paso de verificacion de infra del triage de deploy se **re-ancla a ADR-0020 del harness** como fuente de verdad del aislamiento por plan (antes apuntaba vagamente "al ADR de hosting del proyecto consumidor"; el consumidor puede tener un ADR local complementario que no la contradiga) e incorpora el chequeo de que cada Function App corre en su propio App Service Plan dedicado (`asp-<proyecto>-<env>-<dominio>`), con comando de verificacion (`az appservice plan show --query numberOfSites`) y su equivalente en Terraform (`service_plan_id` por dominio). Se anade la seccion **"Patron de diagnostico: noisy neighbor por plan compartido"** que ensena a reconocer la firma del sintoma (CPU del plan alta en reposo con 0 requests y 0 mensajes de Service Bus), su verificacion (`az monitor metrics list --metric CpuPercentage` cruzado con el trafico real), la causa raiz (`DurabilityMode.Solo` con su agente de durabilidad always-on) y el eje de mitigacion critico (solo vertical o aislar por app; **nunca** escalar out con `Solo`). Alinea el agente con ADR-0020 (#44); origen #43.
- **Sync verificado y fail-loud de `main` entre eslabones del secuencial interno** (issue #46): `mefisto-batch-pipeline.sh` reemplaza el viejo `git pull origin main || warn (continuando)` (best-effort, que silenciaba el fallo y dejaba que el siguiente eslabon partiera de un main potencialmente atrasado) por un sync **verificado** tras cada merge: `git fetch origin main`, fast-forward (`--ff-only`) de main local a `origin/main` y **confirmacion** de que el commit de merge del PR quedo presente en main local antes de arrancar el siguiente issue. Si el sync no se concreta y aun quedan eslabones, **aborta la cadena** en vez de construir el siguiente sobre un main desactualizado (degrada a warning solo en el ultimo eslabon, del que nada depende). Ademas el motor exige arrancar en `main`/`master` y aborta con mensaje claro si no, porque cada worktree del tooling-pipeline se crea desde la rama activa del repo. Se documenta en el header del script y en la seccion "Sincronizacion verificada entre eslabones" de `/mefisto-sequential`. Habilita cadenas con dependencias seguras (prerequisito de #47).
- **El secuencial interno admite cadenas cuyos bloqueos se resuelven por el orden del propio batch** (issue #47): `/mefisto-sequential` reescribe su paso 1.5 para **clasificar** cada dependencia abierta de un issue `bloqueado`, en vez de abortar ante cualquier `OPEN`: (a) *satisfactible por el batch* -- es otro issue del mismo batch que aparece **antes** en el orden, asi que la cadena `pipeline -> PR -> merge -> sync -> siguiente` (con el sync verificado de #46) la resuelve durante la ejecucion; o (b) *bloqueo real* -- esta fuera del batch y sigue `OPEN`, o esta dentro del batch pero **despues** en el orden (mal ordenada). Si todas son (a) -- o ya estan `CLOSED`/`MERGED` -- el batch se lanza y se **retira** el label `bloqueado` al validar (CA-5); si hay al menos un bloqueo (b), **aborta** mostrando cual y por que, y si es intra-batch mal ordenada sugiere el reordenamiento concreto (p. ej. "mueve #44 antes de #43"). La mutacion de labels es atomica: solo ocurre si todo el batch pasa la validacion. Habilita lanzar cadenas como `/mefisto-sequential 44 43 45` (donde #43 y #45 dependen de #44). Solo afecta al skill interno; la version publicada `commands/sequential.md` no tiene paso 1.5. Depende de #46.

## [0.3.0] - 2026-06-17

### Added

- **Set de skills, agentes y pipelines internos** para evolucionar el propio harness (no se publican vía marketplace; viven en `.claude/`): agentes `mefisto-planner` y `mefisto-investigator`, y comandos `/mefisto-plan`, `/mefisto-tooling`, `/mefisto-bug`, `/mefisto-fix-review`, `/mefisto-merge`, `/mefisto-work-status`, con sus pipelines `_mefisto-common.sh`, `mefisto-tmux-pipeline.sh` y `mefisto-tooling-pipeline.sh`.
- **Skill interno `/mefisto-release`** para versionar y publicar el plugin siguiendo SemVer y Keep a Changelog (fases prepare y publish).
- **Skill interno `/mefisto-sequential`** para procesar varios issues internos en cadena dentro de una sesión tmux, con `mefisto-batch-pipeline.sh`.
- **Routing de drafts cross-repo**: el `planner` y el `tooling-investigator` publicados pueden crear drafts (`estado:borrador`) en el repo de Mefisto cuando detectan que un problema del consumidor pertenece al harness.
- **Slug del repo de Mefisto configurable** en `validate_consumer_scope_changes`, en lugar de estar hardcoded.
- **Guards defensivos "cwd != Mefisto"** en todos los skills publicados, en los pipelines TDD/IaC/scaffold/tmux y en los scripts auxiliares (`appinsights-query`, `eda-lint`, `setup-github-*`), para que el tooling publicado nunca opere por error sobre el repo del propio plugin.
- **Scope-gate del `/tooling` publicado**, que lo restringe a archivos del consumidor y rechaza el PR si toca rutas reservadas al plugin.
- **ADR-0019** "Skills publicados vs internos", que formaliza la separación entre el paquete distribuido y el tooling interno.
- **Suite de tests de guards y scope** en `scripts/tests/test-guards.sh`.
- **LICENSE MIT** al publicar el repositorio.

### Changed

- **Documentado el modelo de skills publicados vs internos** en `CLAUDE.md` y `README.md`.
- **Regla de entrega**: todo cambio se hace en rama y se entrega vía Pull Request; nunca contra `main` directo (documentado en `CLAUDE.md`).
- **`eda-modeler`**: eliminados los dominios y contratos hardcoded de un consumidor concreto.
- **`tooling-investigator`**: aclarados sus límites y retirada la etiqueta `dom:tooling` (inexistente en Mefisto).
- **Eliminado el `git push` directo a `main`** en el agente `historiador` y en los skills `fix-review` / `mefisto-fix-review`; ahora pasan por rama + PR.
- **README**: añadida la sección "El nombre" con la cita de Fausto que origina el nombre interno `mefisto`.

### Fixed

- **Resolución del repo objetivo del consumidor** en `tmux-pipeline.sh` y `eda-lint.sh`: ya no se deriva de la ubicación del script (`$SCRIPT_DIR/..`, que bajo el modelo de plugin apunta al propio harness) sino del toplevel del repo activo vía `git rev-parse --show-toplevel`.
- **Referencias rotas** en los skills `draft`, `health-check` y `show-flow`, y en el ADR-0007.
- **Referencias a ADRs con numeración del consumidor** en los agentes publicados (`planner`, `reviewer`, `test-writer`) y en `implement`.
- **Resolución del pane del script en tmux** vía `pane_id` en lugar del índice de pane, frágil ante reordenamientos.

## [0.2.0] — 2026-05-15

### Changed (BREAKING)

- **Renombrar el plugin de `eda-evsourcing-azure-harness` a `mefisto`** para acortar el namespace de los skills. Los skills ahora son `/mefisto:implement`, `/mefisto:scaffold`, `/mefisto:infra`, etc. (antes `/eda-evsourcing-azure-harness:implement`, etc.).
- `.claude-plugin/plugin.json.name`: `eda-evsourcing-azure-harness` → `mefisto`.
- `.claude-plugin/marketplace.json.plugins[0].name`: `eda-evsourcing-azure-harness` → `mefisto`.

El nombre del marketplace (`augusto-romero-arango-harness`) y la URL del repositorio (`eda-evsourcing-azure-harness`) no cambian.

### Migración para consumidores

Quien tuviera v0.1.x instalado debe reinstalar:

```
/plugin uninstall eda-evsourcing-azure-harness@augusto-romero-arango-harness
/plugin marketplace update augusto-romero-arango-harness
/plugin install mefisto@augusto-romero-arango-harness
```

Y reemplazar referencias en `CLAUDE.md` del proyecto: `/eda-evsourcing-azure-harness:*` → `/mefisto:*`.

## [0.1.2] — 2026-05-15

### Fixed

- `hooks/hooks.json`: el contenido debía estar envuelto en `{ "hooks": {...} }` en lugar de tener los eventos como root. Sin este fix, `claude plugin doctor` reporta: `Hook load failed: expected record, received undefined at path "hooks"`.

## [0.1.1] — 2026-05-15

### Fixed

- `.claude-plugin/marketplace.json`: el `source` del plugin pasa de `"."` (no soportado, falla con "This plugin uses a source type your Claude Code version does not support") a `"./"`, formato esperado por el schema (pattern `^\.\/.*`). Sin este fix, `/plugin install` falla.

## [0.1.0] — 2026-05-15

### Added

- Extracción inicial del harness desde el repo `Bitakora.ControlAsistencia` como Claude Code Plugin independiente.
- **14 skills** (slash commands) en `commands/`: scaffold, implement, tooling, sequential, show-flow, draft, fix-review, infra, parallel, health-check, work-status, bug, merge, eraser-diagram.
- **16 agentes** en `agents/`: planner, test-writer, implementer, reviewer, smoke-test-writer, domain-scaffolder, eda-modeler, event-stormer, historiador, infra-writer, infra-reviewer, infra-applier, infra-bootstrap, pr-sync, bug-investigator, tooling-investigator.
- **Pipelines bash** en `scripts/`: tdd, tooling, iac, scaffold, parallel, batch, tmux, pr-sync, eda-lint, appinsights-query, setup-github-ci, setup-github-labels, _pipeline-common.
- **`scripts/_pipeline-common.sh`** con `load_harness_config()` que parsea `.claude/harness.config.json` del consumidor y exporta variables `HARNESS_*`.
- **18 ADRs** del marco en `docs/adr/`, renumerados secuencialmente:
  - ADR-0001 Service Bus topics por evento
  - ADR-0002 Estrategia de testing con event sourcing
  - ADR-0003 Event Sourcing con Marten y Wolverine
  - ADR-0004 Manejo de errores en ES
  - ADR-0005 Naming y versionado de eventos
  - ADR-0006 Convenciones de nombramiento de funciones Azure
  - ADR-0007 Gestión de proyecto con GitHub Issues
  - ADR-0008 Knowledge Crunching como propósito del planner
  - ADR-0009 Mensajes con .resx per-aggregate
  - ADR-0010 Pipeline de conocimiento del dominio
  - ADR-0011 Definition of Ready
  - ADR-0012 Estilo de modelado de objetos de dominio
  - ADR-0013 Smoke tests contra entorno dev
  - ADR-0014 Coverage gate en pipeline TDD
  - ADR-0015 Snapshots de Marten como excepción
  - ADR-0016 Convención de naming de tests
  - ADR-0017 Archivo señal de refactor fuera de `.claude/`
  - ADR-0018 Heurísticas de evolución y reuso
- **`hooks/hooks.json`** con PostToolUse para logging de archivos modificados, tests y operaciones Terraform.
- **`.claude-plugin/plugin.json`** y **`marketplace.json`** con metadata del plugin y catálogo del marketplace `augusto-romero-arango-harness`.
- **`CLAUDE.md`** y **`README.md`** documentando el harness, su contrato con el consumidor y la instalación.

### Contrato con el consumidor (nuevo)

- `.claude/harness.config.json` con campos: `projectName`, `namespacePrefix`, `solutionFile`, `infraResourceGroupPrefix`, `terraformStateStorage`, `githubServicePrincipalName`, `appInsightsApp`, `domainLabels`.
- Sección "Tokens del harness" en `CLAUDE.md` raíz del consumidor declarando `RootNamespace`, `SolutionFile`, `ProjectDisplayName`.

### Notas

- Algunos ADRs referencian ADRs del proyecto consumidor (Function App por dominio, Contracts, control de costos de App Insights, hosting de Azure Functions). Esas referencias quedan como "ADR del proyecto consumidor sobre X" hasta que cada proyecto las nombre.
- Los agentes `reviewer` e `implementer` mantienen el placeholder literal `ADR-XXXX` en sus plantillas de reporte (no es un bug; el agente lo sustituye en tiempo de ejecución por el número real del ADR aplicable).
- Los ejemplos de código en `test-writer.md`, `implementer.md` y `smoke-test-writer.md` conservan nombres concretos de un proyecto consumidor (`Programacion`, `ControlHoras`) anotados en el "Contrato con el consumidor" de cada agente como ejemplos pedagógicos.

[Unreleased]: https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/compare/v0.2.0...v0.3.0
[0.1.0]: https://github.com/augusto-romero-arango/eda-evsourcing-azure-harness/releases/tag/v0.1.0

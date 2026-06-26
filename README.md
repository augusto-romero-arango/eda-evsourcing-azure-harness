# mefisto

> Repositorio: `eda-evsourcing-azure-harness` · Nombre del plugin: `mefisto`

Plugin de [Claude Code](https://code.claude.com/docs/en/plugins) que provee un harness opinionado para construir aplicaciones .NET 10 serverless en Azure con Event Driven Architecture y Event Sourcing.

> Estado: **v0.1.0 (internal alpha)** — extraído del proyecto Bitakora.ControlAsistencia el 2026-05-15. La API del harness puede cambiar entre versiones menores hasta `v1.0.0`.

## El nombre

`mefisto` es un guiño a Mefistófeles, el espíritu de *Fausto* de Goethe. La analogía es simple: quien invoca el harness encarna a Fausto — fija la intención y firma el pacto —; el plugin, como Mefisto, ejecuta esa voluntad bajo las reglas del marco (EDA, Event Sourcing, Azure Functions, TDD).

> «Ich will mich hier zu deinem Dienst verbinden,
> auf deinen Wink nicht rasten und nicht ruhn».
>
> — Mefistófeles, *Fausto* I, escena «Studierzimmer», vv. 1656-1657
>
> *«Aquí me ataré a tu servicio, a tu menor seña no descansaré ni cesaré».*

## Qué incluye

- **14 skills** (slash commands): `/implement`, `/tooling`, `/infra`, `/scaffold`, `/parallel`, `/sequential`, `/bug`, `/draft`, `/fix-review`, `/health-check`, `/work-status`, `/show-flow`, `/eraser-diagram`, `/merge`.
- **16 agentes** especializados: `planner`, `test-writer`, `implementer`, `reviewer`, `smoke-test-writer`, `domain-scaffolder`, `eda-modeler`, `event-stormer`, `historiador`, `infra-writer`, `infra-reviewer`, `infra-applier`, `infra-bootstrap`, `pr-sync`, `bug-investigator`, `tooling-investigator`.
- **Pipelines bash** que orquestan el ciclo TDD, IaC y tooling sobre `tmux` y `git worktree`.
- **20 ADRs** del marco arquitectónico.
- **Hooks** para logging del pipeline.

## Stack supuesto en el consumidor

- .NET 10 + Azure Functions isolated worker
- Marten (event store) + Wolverine (mediador) sobre PostgreSQL
- Azure Service Bus (topic por evento)
- xUnit v3 + `Cosmos.EventSourcing.Testing.Utilities`
- Terraform para IaC
- GitHub Actions para CI/CD

Si tu proyecto no encaja con este stack, este harness no es para ti.

## Instalación

### 1. Registrar el marketplace en `.claude/settings.json` del repo consumidor

```json
{
  "extraKnownMarketplaces": {
    "augusto-romero-arango-harness": {
      "source": {
        "source": "github",
        "repo": "augusto-romero-arango/eda-evsourcing-azure-harness"
      }
    }
  }
}
```

### 2. Instalar el plugin (desde Claude Code)

```
/plugin marketplace add augusto-romero-arango-harness
/plugin install mefisto@augusto-romero-arango-harness
```

> **Si vas a correr los pipelines (`/infra`, `/implement`, `/scaffold`), instala a scope `user`**, no `project`: `claude plugin install mefisto@augusto-romero-arango-harness --scope user`. Esos pipelines invocan a sus agentes dentro de un git worktree hermano del repo consumidor (`${REPO_ROOT}/../<rama>`), que un scope `project` no carga. Ver "Primeros pasos con el harness (greenfield)", paso 1, para el porqué detallado.

### 3. Configurar el consumidor

Crea `.claude/harness.config.json` en la raíz del proyecto consumidor:

```json
{
  "projectName": "MiProyecto",
  "namespacePrefix": "MiOrg.MiProyecto",
  "solutionFile": "MiProyecto.slnx",
  "infraResourceGroupPrefix": "rg-miproyecto",
  "terraformStateStorage": "stmiproyectotfstatedev",
  "githubServicePrincipalName": "github-miproyecto-ci",
  "appInsightsApp": "miproyecto-dev-ai",
  "domainLabels": ["dominio1", "dominio2"]
}
```

**Campo `terraformStateStorage` (nombre BASE)**: el nombre de una Storage Account es un endpoint DNS público (`*.blob.core.windows.net`) y por tanto **único en todo Azure**, no solo en tu suscripción. Por eso `scripts/bootstrap-backend.sh` trata este campo como un nombre **base**: le anexa un sufijo aleatorio de 6 caracteres para garantizar unicidad global (mismo patrón `random_string` que el scaffolder usa en las Storage de dominio) y valida la disponibilidad con `az storage account check-name` antes de crear. El nombre **final** (con sufijo) es el que queda en `infra/environments/<env>/backend.tf`, así que `terraform init` usa exactamente la cuenta creada. Declara la base sin sufijo (ej. `stmiproyectotfstatedev`); si la base más el sufijo no cabe en el límite de 24 caracteres de Azure, el script trunca la base y avisa. Las corridas posteriores reutilizan la cuenta ya creada (idempotente; ancla el nombre en el `backend.tf` versionado y en la cuenta existente del Resource Group del tfstate), no generan un sufijo nuevo.

**Campo opcional `azureLocation`**: la región de Azure (ej. `"eastus2"`, `"westeurope"`) donde `scripts/bootstrap-backend.sh` crea el backend de Terraform (Resource Group, Storage Account y container del tfstate). Si lo declaras, el bootstrap lo usa por defecto sin tener que pasar `--location` en cada corrida; el flag `--location` siempre lo sobrescribe. Si no lo declaras y tampoco pasas `--location`, el bootstrap aborta pidiéndote uno de los dos. Es **opcional**, así que añadirlo no es un cambio incompatible del schema (no es MAJOR).

Y añade una sección a `CLAUDE.md` raíz del consumidor declarando los tokens:

```markdown
### Tokens del harness

- **RootNamespace**: MiOrg.MiProyecto
- **SolutionFile**: MiProyecto.slnx
- **ProjectDisplayName**: MiProyecto
```

### 4. Verificar instalación

```
/mefisto:show-flow
/mefisto:work-status
```

Si responden sin errores, está listo.

## Primeros pasos con el harness (greenfield)

Esta es la ruta de arranque para un proyecto **nuevo** (sin código ni infraestructura aún), en orden. Asume que ya completaste la sección **Instalación**.

### 1. Habilitar el plugin **a scope user** y verificar

Registra el marketplace e instala el plugin (sección Instalación, pasos 1-2), pero **instálalo a scope `user`, no a scope `project`** (es requisito para que los pipelines funcionen — ver el recuadro "Por qué scope `user`" al final de este paso).

Registra el marketplace desde una sesión de Claude Code:

```
/plugin marketplace add augusto-romero-arango-harness
```

E **instala con `--scope user`** desde una terminal en la raíz del repo consumidor (el flag `--scope` solo existe en el CLI; el slash `/plugin install` no lo acepta). Verificado contra Claude Code 2.1.x:

```bash
claude plugin install mefisto@augusto-romero-arango-harness --scope user
```

> Si prefieres el flujo interactivo (`/plugin install mefisto@augusto-romero-arango-harness` dentro de la sesión), elige **user** cuando te pregunte por el scope. El comando de terminal de arriba lo fija explícito y es el camino verificado en campo.

Comprueba que los skills responden:

```
/mefisto:work-status
```

Si `/mefisto:work-status` responde sin errores, el plugin está cargado.

> **Por qué scope `user` y no `project` (requisito para los pipelines).** Los pipelines (`/infra`, `/implement`, `/scaffold`) **no** corren sus agentes dentro de tu repo: crean un **git worktree** en `${REPO_ROOT}/../<rama>` —un directorio **hermano del repo consumidor, fuera de él**— e invocan cada agente ahí con `claude -p ... --agent <nombre> ...` (ver `scripts/iac-pipeline.sh`, `scripts/tdd-pipeline.sh` y `scripts/scaffold-pipeline.sh`, que comparten el patrón `WORKTREE_PATH="${REPO_ROOT}/../${BRANCH_NAME}"`). Con el plugin a **scope `project`**, Claude Code solo lo carga para el path del repo consumidor; ese worktree hermano queda fuera de alcance, el agente no se encuentra y el pipeline aborta con `agent '<nombre>' not found`. El **scope `user`** carga el plugin para todos los paths de tu usuario —incluido el worktree—, por eso es **requisito antes del paso 4 (Bootstrap de infraestructura / `/infra`)**, el primer paso de esta guía que dispara un pipeline. En Claude Code 2.1.x `--scope user` es además el default de `claude plugin install`; declararlo explícito evita que un flujo interactivo previo lo haya dejado a scope `project` (la causa raíz del fallo en el primer greenfield real del harness).

### 2. Crear `.claude/harness.config.json`

Crea el archivo de configuración en la raíz del consumidor (sección Instalación, paso 3). Para el bootstrap de infra conviene declarar también el campo opcional `azureLocation` con tu región de Azure (ej. `"eastus2"`), así no tienes que pasar `--location` en cada corrida. Añade además la sección "Tokens del harness" a tu `CLAUDE.md` raíz.

### 3. Entender el modelo de ejecución (importante)

**Los scripts del harness NO viven en tu repo.** El plugin se instala en el cache del marketplace (`~/.claude/plugins/cache/.../mefisto/.../`, read-only). Por eso **nunca** invocas `./scripts/...` desde el consumidor: esa ruta resolvería contra `<tu-repo>/scripts/...` (inexistente). Los skills y agentes localizan el script por **ruta absoluta al plugin** pero operan sobre tu repo (`cwd = consumidor`, vía `git rev-parse --show-toplevel` y `load_harness_config`).

El patrón canónico para resolver la raíz del plugin es:

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
PLUGIN_SCRIPTS="${PLUGIN_ROOT%/}/scripts"
"$PLUGIN_SCRIPTS/<script>.sh" <args>
```

`.claude/pipeline/.plugin-root` lo escribe el hook `SessionStart` del plugin al abrir la sesión (persiste `${CLAUDE_PLUGIN_ROOT}`); el fallback localiza el plugin por glob sobre el cache tomando la versión más reciente. Normalmente **no necesitas correr esto a mano**: lo hacen los skills (`/infra`, etc.) y los agentes (`infra-bootstrap`, `planner`) por ti.

### 4. Bootstrap de infraestructura

El backend remoto de Terraform (donde vive el `tfstate`) es prerequisito de todo lo demás. El orden es:

1. **Crear el backend del tfstate** con `bootstrap-backend.sh` (idempotente; crea Resource Group `rg-<proyecto>-tfstate`, Storage Account endurecida —con un **sufijo de unicidad global** sobre el nombre base de `terraformStateStorage`, ver la nota de ese campo arriba— y container `tfstate`, y escribe `infra/environments/<env>/backend.tf` con el nombre final resuelto):

   ```bash
   PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
   [ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
   PLUGIN_SCRIPTS="${PLUGIN_ROOT%/}/scripts"
   "$PLUGIN_SCRIPTS/bootstrap-backend.sh" --subscription <subscription-id> --env dev
   ```

   (Pasa `--location <region>` si no declaraste `azureLocation` en el config.) También puedes dejar que lo orqueste el agente `infra-bootstrap`, que encadena este paso con el primer `/infra`.

   > **Nota**: el script escribe `backend.tf` en tu working tree. El pipeline IaC (`/infra`) ramifica su worktree desde `origin/main`, así que **automatiza** que ese `backend.tf` llegue al worktree: lo copia del working tree al worktree y lo commitea en la rama del pipeline, de modo que viaja en el PR y se versiona en `main` vía merge. No necesitas commitearlo ni subirlo a `main` a mano antes del primer `/infra` (el `terraform init` del reviewer ya encuentra el backend remoto y no cae a estado local).

2. **Configurar el Service Principal de CI** con `setup-github-ci.sh` (crea el SP de GitHub Actions y le asigna lectura sobre el tfstate ya creado):

   ```bash
   "$PLUGIN_SCRIPTS/setup-github-ci.sh" <subscription-id>
   ```

   Copia los secrets que imprime a *Settings > Secrets and variables > Actions* de tu repo.

3. **Primer `/infra`**: lanza el pipeline IaC para tu primer issue `tipo:infra`, que escribe el HCL, ejecuta `terraform plan` y aplica:

   ```
   /mefisto:infra <numero-de-issue>
   ```

### 5. Scaffold del primer dominio y primer ciclo TDD

Con el backend listo, crea el scaffold de tu primer dominio y arranca el ciclo TDD:

```
/mefisto:scaffold <dominio>      # estructura src/ + tests/ + módulos de infra del dominio
/mefisto:draft "primera capacidad del dominio"   # captura la idea como issue borrador
# el planner refina el issue a estado:listo
/mefisto:implement <issue>       # pipeline TDD: test-writer (rojo) -> implementer (verde) -> reviewer -> PR
```

### 6. Qué corre dónde

| Acción | `cwd` | Dónde vive el binario/artefacto |
|---|---|---|
| Skills (`/infra`, `/implement`, `/scaffold`, ...) | tu repo consumidor | definición en el plugin (cache del marketplace) |
| `bootstrap-backend.sh`, `setup-github-ci.sh`, `iac-pipeline.sh`, `tdd-pipeline.sh`, ... | operan sobre tu repo consumidor | binario en el plugin; se resuelven vía `$PLUGIN_SCRIPTS` |
| ADRs del marco (`docs/adr/`) | — | en el plugin; los agentes los leen vía `$PLUGIN_ROOT/docs/adr/` |
| `.claude/harness.config.json`, `CLAUDE.md`, `src/`, `tests/`, `infra/` | tu repo consumidor | **tu repo** (los crea/edita el harness operando sobre el consumidor) |
| `infra/environments/<env>/backend.tf` | tu repo consumidor | **tu repo** (lo escribe `bootstrap-backend.sh` en runtime) |

Regla mnemónica: **los binarios viven en el plugin; los archivos del proyecto viven en tu repo.** Nunca edites archivos dentro del cache del plugin ni invoques sus scripts con rutas relativas.

## Uso

Los skills aparecen con el namespace del plugin: `/mefisto:implement <issue>`, `/mefisto:scaffold <dominio>`, etc.

Flujo típico:

```
/draft "registrar marcaciones biométricas"     # captura idea como issue borrador
# planner refina el issue a estado:listo
/implement <issue>                              # pipeline TDD
# pr-sync mergea el PR
```

## Estructura del plugin

```
.claude-plugin/
  plugin.json          # metadata (name, version, author)
  marketplace.json     # catálogo
commands/              # skills publicados (los que ve el consumidor)
agents/                # agentes publicados
scripts/               # pipelines + utilidades bash publicadas
hooks/hooks.json       # PostToolUse para logging
.claude/               # skills/agentes/pipelines INTERNOS (no se publican)
  commands/            # /mefisto-tooling, /mefisto-plan, /mefisto-bug, ...
  agents/              # mefisto-investigator, mefisto-planner
  scripts/             # _mefisto-common.sh, mefisto-tooling-pipeline.sh, ...
docs/
  adr/                 # ADRs del marco
  tmux-cheatsheet.md
  testing/harness-cheatsheet.md
CLAUDE.md              # documentación viva para Claude Code
CHANGELOG.md
```

## Desarrollo del propio plugin

Si vas a evolucionar Mefisto (este repo), **no instales el plugin sobre sí mismo**. Claude Code carga automáticamente los skills internos desde `.claude/commands/` y `.claude/agents/` del repo activo (separadamente del plugin distribuido).

Skills internos disponibles (todos con prefijo `mefisto-`):

- `/mefisto-tooling <issue>` — pipeline writer+reviewer para mejorar el plugin.
- `/mefisto-plan` — planear, refinar, desglosar issues del repo de Mefisto.
- `/mefisto-bug <síntoma>` — diagnosticar problemas del propio plugin.
- `/mefisto-fix-review <pr>` — resolver comentarios de un PR del repo.
- `/mefisto-merge <pr>` — squash + delete-branch sobre PRs del repo.
- `/mefisto-work-status` — dashboard de pipelines internos en tmux.

Cada skill interno verifica al inicio que estás en el repo de Mefisto (presencia de `.claude-plugin/plugin.json`) y aborta si no.

Cuando descubras desde un consumidor un problema atribuible al plugin, el tooling-investigator publicado puede **crear un draft cross-repo** en este repo (con `gh issue create -R augusto-romero-arango/eda-evsourcing-azure-harness --label "estado:borrador" …`). Luego, dentro del repo de Mefisto, refinas el draft con `/mefisto-plan` y lo implementas con `/mefisto-tooling`.

## Compatibilidad y versionado

Sigue [SemVer](https://semver.org/):

- **MAJOR**: cambios incompatibles del schema de `harness.config.json` o de paths/contratos esperados del consumidor.
- **MINOR**: nuevos skills/agentes/scripts.
- **PATCH**: fixes.

Cambios **incompatibles** al schema de `harness.config.json` (quitar o renombrar campos, cambiar su tipo, o volver obligatorio uno que no lo era) ⇒ MAJOR + nota de migración en `CHANGELOG.md`. Añadir un campo **opcional** (con default o flag que lo sobrescriba, como `azureLocation`) es retrocompatible ⇒ MINOR, no requiere nota de migración.

## Actualizar a una versión nueva

```
/plugin update mefisto
```

Revisa el `CHANGELOG.md` para notas de migración antes de actualizar entre majors.

## Requisitos del entorno

- `bash` 3.2+ (compatible con macOS nativo)
- `jq` (parser JSON, usado por `_pipeline-common.sh`)
- `gh` CLI autenticado
- `dotnet` 10.x
- `terraform` 1.6+
- `tmux` (para pipelines paralelos)
- `git` 2.x con soporte de worktrees

## Licencia

PROPRIETARY (uso interno).

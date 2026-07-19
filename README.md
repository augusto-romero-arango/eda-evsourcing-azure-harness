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

- **17 skills** (slash commands): `/onboard`, `/implement`, `/tooling`, `/infra`, `/infra-base`, `/scaffold`, `/seed-secret`, `/parallel`, `/sequential`, `/bug`, `/draft`, `/fix-review`, `/health-check`, `/work-status`, `/show-flow`, `/eraser-diagram`, `/merge`.
- **16 agentes** especializados: `planner`, `test-writer`, `implementer`, `reviewer`, `smoke-test-writer`, `domain-scaffolder`, `infra-base-scaffolder`, `eda-modeler`, `event-stormer`, `historiador`, `infra-writer`, `infra-reviewer`, `infra-bootstrap`, `pr-sync`, `bug-investigator`, `tooling-investigator`.
- **Pipelines bash** que orquestan el ciclo TDD, IaC y tooling sobre `tmux` y `git worktree`.
- **30 ADRs** del marco arquitectónico (prefijo `MEF-ADR-`).
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

### 1. Configurar `.claude/settings.json` del repo consumidor

Crea (o extiende) `.claude/settings.json` en la raíz del repo consumidor con tres bloques — el marketplace, la habilitación del plugin y los permisos recomendados:

```json
{
  "extraKnownMarketplaces": {
    "augusto-romero-arango-harness": {
      "source": {
        "source": "github",
        "repo": "augusto-romero-arango/eda-evsourcing-azure-harness"
      }
    }
  },
  "enabledPlugins": {
    "mefisto@augusto-romero-arango-harness": true
  },
  "permissions": {
    "allow": [
      "Bash(dotnet:*)",
      "Bash(git:*)",
      "Bash(gh:*)",
      "Bash(terraform:*)",
      "Bash(az:*)"
    ],
    "deny": [
      "Bash(terraform destroy:*)",
      "Bash(az group delete:*)",
      "Bash(git push --force:*)"
    ]
  }
}
```

- **`extraKnownMarketplaces`** registra el marketplace que aloja a Mefisto (el repo de GitHub). El esquema del bloque `source` usa la clave `source` (no `type`) con valor `"github"` — ver issue #75.
- **`enabledPlugins`** habilita el plugin de forma **reproducible y commiteable**: al estar en el `settings.json` versionado, cualquiera que clone el repo arranca con Mefisto ya habilitado. La clave es `<plugin.name>@<marketplace.name>` = `mefisto@augusto-romero-arango-harness` (verificado contra `.claude-plugin/plugin.json` y `.claude-plugin/marketplace.json`). El `/plugin install` interactivo del paso 2 habilita el plugin en tu instalación local pero **no deja artefacto en el repo**, así que sin esta clave la habilitación no es reproducible.
- **`permissions`** es un **punto de partida ajustable** (sintaxis `Bash(<cmd>:*)` de Claude Code; ver la [doc de settings](https://code.claude.com/docs/en/settings)). El `allow` evita la fricción de aprobar uno a uno los `dotnet`/`git`/`gh`/`terraform`/`az` que disparan los pipelines; el `deny` es una red de seguridad contra comandos destructivos (`terraform destroy`, `az group delete`, `git push --force`). Endurécelo o relájalo según la política de tu equipo — el `deny` tiene prioridad sobre el `allow`.

### 2. Instalar el plugin (desde Claude Code)

```
/plugin marketplace add augusto-romero-arango-harness
/plugin install mefisto@augusto-romero-arango-harness
```

> El `/plugin install` interactivo no deja rastro en el repo; el bloque `enabledPlugins` del paso 1 es lo que hace la habilitación reproducible y commiteable. Si declaraste `enabledPlugins`, este paso sigue siendo útil la primera vez para que Claude Code descargue el plugin al cache local.

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
  "azureLocation": "eastus2",
  "domainLabels": ["dominio1", "dominio2"],
  "boundedContext": {
    "name": "Principal",
    "domains": ["dominio1", "dominio2"]
  },
  "secrets": [
    {
      "name": "stripe-api-key",
      "source": { "type": "github-secret", "value": "STRIPE_API_KEY" }
    }
  ]
}
```

**Campo `terraformStateStorage` (nombre BASE)**: el nombre de una Storage Account es un endpoint DNS público (`*.blob.core.windows.net`) y por tanto **único en todo Azure**, no solo en tu suscripción. Por eso `scripts/bootstrap-backend.sh` trata este campo como un nombre **base**: le anexa un sufijo aleatorio de 6 caracteres para garantizar unicidad global (mismo patrón `random_string` que el scaffolder usa en las Storage de dominio) y valida la disponibilidad con `az storage account check-name` antes de crear. El nombre **final** (con sufijo) es el que queda en `infra/environments/<env>/backend.tf`, así que `terraform init` usa exactamente la cuenta creada. Declara la base sin sufijo (ej. `stmiproyectotfstatedev`, 22 chars). **Restricción de Azure**: el nombre de una Storage Account debe tener **3-24 caracteres, solo minúsculas y dígitos** ([Microsoft Learn — reglas de nombres de recursos, `Microsoft.Storage`](https://learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules#microsoftstorage)). El patrón sugerido `st<proyecto>tfstate<env>` deja ~12 caracteres para `<proyecto>` (`st`=2, `tfstate`=7, `dev`=3), así que **para nombres largos abrevia el prefijo del proyecto**: p. ej. `micontrolplane` produce `stmicontrolplanetfstatedev` = **26 chars (inválido)**; abreviado a `mcp` queda `stmcptfstatedev` = 15 chars (válido). `load_harness_config` valida este formato (`^[a-z0-9]{3,24}$`) al cargar el config (issue #78) y aborta temprano si no cumple, en vez de fallar tarde en el `apply`. Si la base **válida** más el sufijo de unicidad no cabe en 24 caracteres, `bootstrap-backend.sh` trunca la base y avisa. Las corridas posteriores reutilizan la cuenta ya creada (idempotente; ancla el nombre en el `backend.tf` versionado y en la cuenta existente del Resource Group del tfstate), no generan un sufijo nuevo.

**Campo opcional `azureLocation`**: la región de Azure (ej. `"eastus2"`, `"westeurope"`) donde `scripts/bootstrap-backend.sh` crea el backend de Terraform (Resource Group, Storage Account y container del tfstate). Si lo declaras, el bootstrap lo usa por defecto sin tener que pasar `--location` en cada corrida; el flag `--location` siempre lo sobrescribe. Si no lo declaras y tampoco pasas `--location`, el bootstrap aborta pidiéndote uno de los dos. Es **opcional**, así que añadirlo no es un cambio incompatible del schema (no es MAJOR).

> **`azureLocation` (backend del tfstate) ≠ región de PostgreSQL.** `azureLocation` solo fija dónde vive el backend del `tfstate` (Resource Group, Storage Account, container); **no** es la región del PostgreSQL Flexible Server que `/infra-base` provisiona como event store de Marten (MEF-ADR-0003, MEF-ADR-0021). Esa región es `postgresql_location` en `infra/environments/<env>/terraform.tfvars` y **puede —y a veces debe— diferir** de `azureLocation`: en el primer greenfield real (`Bitakora.ControlAsistencia`), `eastus2` —válido para el backend del tfstate— devolvió `LocationIsOfferRestricted` al crear el PostgreSQL Flexible Server, y se resolvió usando `centralus`. Ese error depende de tu **suscripción/oferta** (la región figura como soportada en la [lista oficial de regiones de Postgres](https://learn.microsoft.com/azure/postgresql/overview#azure-regions), pero la oferta no está habilitada para tu suscripción ahí), no es una indisponibilidad global de la región — por eso no hay una región "apta" universal y conviene verificar la tuya **antes del primer `terraform apply`**, no descubrir la restricción en el apply:
>
> ```bash
> az postgres flexible-server list-skus --location <region> -o table
> ```
>
> Si lista SKUs (entre ellas `Standard_B1ms`, la SKU de cómputo que usa el módulo `postgresql` — `list-skus` y `--sku-name` la nombran así, con el tier `Burstable` como parámetro aparte; el provider `azurerm` la declara en `sku_name` como `B_Standard_B1ms`, anteponiendo el tier, que es el valor que figura en la tabla de módulos del MEF-ADR-0021), la región sirve para tu suscripción; si sale vacío o falla, elige otra (p. ej. `centralus`). El comando es la referencia oficial de Azure CLI ([`az postgres flexible-server list-skus`](https://learn.microsoft.com/cli/azure/postgres/flexible-server)). Ver MEF-ADR-0021, sección "Región de PostgreSQL Flexible Server".

**Campo `boundedContext`** (**obligatorio**, MEF-ADR-0023): declara el Bounded Context del proyecto. Un BC es un grupo de dominios relacionados que comparte un resource group de Azure y dos namespaces de Azure Service Bus (interno e integración). `load_harness_config` valida los dos subfields y exporta `HARNESS_BC_NAME` y `HARNESS_BC_DOMAINS`:

- **`name`**: nombre del BC, 1-63 caracteres alfanuméricos y guiones. Puede coincidir o no con `projectName` (ej: "Principal", "Admin", "Core").
- **`domains`**: array de dominios del BC, no vacío. Cada elemento debe estar en `domainLabels`. Los dominios del BC son un subconjunto de todos los dominios del proyecto (en proyectos con un solo BC, el subconjunto es igual a `domainLabels`).

El resource group del BC se forma como `infraResourceGroupPrefix`+`-`+`name` (ej: `rg-miproyecto-principal`). El context map (registro de BCs externos) es trabajo diferido; hoy el BC solo se nombra a sí mismo.

> **Proyectos existentes (que vienen de una versión sin este campo)**: si `boundedContext` no está en tu config, `load_harness_config` aborta con un mensaje accionable que muestra el shape exacto a añadir y un ejemplo con tus `domainLabels` actuales. Corre `/mefisto:onboard` para obtener el diagnóstico, o lee la sección **"Migración para consumidores existentes"** al final de este documento.

**Campo opcional `repoSlug`**: el slug `owner/repo` del repositorio de Mefisto al que se enrutan los **drafts cross-repo** (`estado:borrador`) que crean el `planner` y el `tooling-investigator` cuando detectan que un problema descubierto en tu proyecto pertenece al harness. Sirve para redirigir esos drafts a **tu fork** de Mefisto en vez del repo upstream. Si no lo declaras, el default es `augusto-romero-arango/eda-evsourcing-azure-harness`. No se exporta como variable `HARNESS_*`: se lee directo con `jq` donde se necesita (`scripts/_pipeline-common.sh`, `agents/planner.md`, `agents/tooling-investigator.md`). Es **opcional** (añadirlo no es MAJOR).

**Campo opcional `secrets`** (issue #256): registro **declarativo** de todo secreto del BC que el step de siembra de `infra-cd.yml` itera en runtime, sin ninguna línea hardcodeada por secreto. Cada entrada declara:

- **`name`**: el nombre del secreto en el Key Vault del BC.
- **`source.type`**: de dónde CI toma el valor a sembrar -- `output` (un único `terraform output`, derivable) o `github-secret` (un único GitHub secret, no derivable; lo crea manualmente un admin). Un tercer valor, `composite` (fórmula fija reservada para `marten-connection`, el único secreto compuesto de varios outputs + un GitHub secret), lo escribe **únicamente** `infra-base-scaffolder` -- nunca lo emite `/seed-secret`.
- **`source.value`**: el nombre del output de Terraform o del GitHub secret, según `source.type`.

`infra-base-scaffolder` registra idempotentemente los secretos **fijos** del BC (el interno de ASB, `app-insights-connection`, `marten-connection` y uno por cada alias de `serviceBus.external[]`) la primera vez que genera `infra-cd.yml` (ver "Bootstrap de infraestructura", paso 3). Para sembrar un secreto **nuevo** después del greenfield -- p. ej. la API key de un proveedor externo --, usa el skill `/seed-secret` (ver catálogo de skills), que registra la entrada y cablea la referencia en la Function App del dominio que la consume. `load_harness_config` valida la forma del array (`name` único, `source.type` en el vocabulario de arriba, `source.value` no vacío); es **opcional** (añadirlo no es MAJOR).

Y añade una sección a `CLAUDE.md` raíz del consumidor declarando los tokens:

```markdown
### Tokens del harness

- **RootNamespace**: MiOrg.MiProyecto
- **SolutionFile**: MiProyecto.slnx
- **ProjectDisplayName**: MiProyecto
- **BoundedContext**: Principal  (nombre del BC; corresponde a `boundedContext.name` en harness.config.json)
- **BoundedContextDomains**: dominio1, dominio2  (lista separada por comas; corresponde a `boundedContext.domains`)
```

`BoundedContext` es el nombre del Bounded Context: grupo de dominios relacionados que comparte resource group y namespaces de Azure Service Bus (MEF-ADR-0023).

Añade también, verbatim, la sección "Verificación de fuentes" al mismo `CLAUDE.md` — propaga al consumidor el principio de verificación de fuentes del propio harness, para que aplique aunque el usuario nunca invoque los skills/agentes de Mefisto:

```markdown
### Verificación de fuentes (obligatorio para agentes)

Antes de proponer o aplicar un ajuste técnico, verifica el enfoque contra la
**documentación oficial y vigente** de las tecnologías del stack (.NET, Azure
Functions, Marten, Wolverine, Azure Service Bus, Terraform, …). No te apoyes en
conocimiento memorizado: puede estar desactualizado. Al afirmar una best practice
o recomendación, **cita la fuente** (URL oficial, versión del paquete, ADR). Si un
dato no pudiste verificarlo contra la fuente, decláralo como *no verificado* en
tu propuesta en vez de darlo por cierto.
```

### 4. Verificar instalación

El objetivo es confirmar que el plugin quedó **instalado y habilitado**, no que existan flujos o pipelines (que en un proyecto recién creado todavía no hay). Dos checks que funcionan en greenfield, sin depender de artefactos de runtime (`docs/eda/flows/`, `.claude/pipeline/`):

1. **El plugin aparece instalado.** Lista los plugins instalados sin abrir el gestor:

   ```
   /plugin list
   ```

   Debe aparecer `mefisto@augusto-romero-arango-harness` (con `/plugin list --enabled` ves solo los habilitados). Como alternativa, `/plugin` abre el gestor: en la pestaña **Installed** el plugin aparece con los componentes que aporta (skills, agentes, hooks). Ver la [doc oficial de plugins](https://code.claude.com/docs/en/discover-plugins#manage-installed-plugins).

2. **Los skills `/mefisto:*` están disponibles.** Corre:

   ```
   /help
   ```

   y verifica que los comandos del namespace del plugin aparecen en el catálogo (p. ej. `/mefisto:draft`, `/mefisto:implement`, `/mefisto:onboard`). Que `/help` liste los skills bajo el namespace del plugin es la señal documentada de que el plugin cargó (ver la [guía oficial de plugins](https://code.claude.com/docs/en/plugins), sección «Test your plugin»).

El criterio de éxito es **"los comandos `/mefisto:*` aparecen disponibles"**, no "responden sin datos".

> **En un proyecto greenfield es esperable que los skills de runtime no muestren nada — y eso NO indica un fallo de instalación.** `/mefisto:show-flow` lee `docs/eda/flows/` (carpeta que aún no existe) y responde "No hay flujos en docs/eda/flows/"; `/mefisto:work-status` lee `.claude/pipeline/pipeline-status-*.json` (aún sin pipelines corridos) y muestra un dashboard vacío. Esa salida vacía solo significa que todavía no has modelado flujos ni corrido pipelines: la instalación se verifica con los dos checks de arriba, no con que esos skills devuelvan datos.

Para un diagnóstico del onboarding (¿está bien formado el `harness.config.json`?, ¿existen los labels?, ¿está configurado el CI?), corre el doctor de onboarding (por defecto solo diagnostica):

```
/mefisto:onboard
```

Imprime un checklist con estado por ítem (OK / FALTA / NO VERIFICADO) y, para cada FALTA, el comando que lo resuelve. Por defecto no crea ni modifica nada; como excepciones opt-in puede provisionar los labels faltantes y configurar el CI hacia Azure (OIDC, MEF-ADR-0022), pero solo tras tu confirmación explícita para cada una.

## Primeros pasos con el harness (greenfield)

Esta es la ruta de arranque para un proyecto **nuevo** (sin código ni infraestructura aún), en orden. Asume que ya completaste la sección **Instalación**.

> **¿Prefieres la versión corta primero?** [`docs/greenfield-quickstart.md`](docs/greenfield-quickstart.md) narra este mismo camino en 10 pasos y el modelo de dos roles (admin/infra vs dev ongoing) — léelo si quieres el mapa antes del detalle exhaustivo de abajo.

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

Comprueba que el plugin cargó (mismo criterio que "Verificar instalación", paso 4 de la sección Instalación):

```
/plugin list
```

`mefisto@augusto-romero-arango-harness` debe aparecer instalado, y `/help` debe listar los skills `/mefisto:*`. En este punto greenfield aún no hay pipelines, así que `/mefisto:work-status` mostrará un dashboard vacío: eso es esperable y no indica un fallo de instalación.

> **Por qué scope `user` y no `project` (requisito para los pipelines).** Los pipelines (`/infra`, `/implement`, `/scaffold`) **no** corren sus agentes dentro de tu repo: crean un **git worktree** en `${REPO_ROOT}/../<rama>` —un directorio **hermano del repo consumidor, fuera de él**— e invocan cada agente ahí con `claude -p ... --agent <nombre> ...` (ver `scripts/iac-pipeline.sh`, `scripts/tdd-pipeline.sh` y `scripts/scaffold-pipeline.sh`, que comparten el patrón `WORKTREE_PATH="${REPO_ROOT}/../${BRANCH_NAME}"`). Con el plugin a **scope `project`**, Claude Code solo lo carga para el path del repo consumidor; ese worktree hermano queda fuera de alcance, el agente no se encuentra y el pipeline aborta con `agent '<nombre>' not found`. El **scope `user`** carga el plugin para todos los paths de tu usuario —incluido el worktree—, por eso es **requisito antes del paso 5 (Bootstrap de infraestructura / `/infra`)**, el primer paso de esta guía que dispara un pipeline. En Claude Code 2.1.x `--scope user` es además el default de `claude plugin install`; declararlo explícito evita que un flujo interactivo previo lo haya dejado a scope `project` (la causa raíz del fallo en el primer greenfield real del harness).

### 2. Crear `.claude/harness.config.json`

Crea el archivo de configuración en la raíz del consumidor (sección Instalación, paso 3). Para el bootstrap de infra conviene declarar también el campo opcional `azureLocation` con tu región de Azure (ej. `"eastus2"`), así no tienes que pasar `--location` en cada corrida. Añade además las secciones "Tokens del harness" y "Verificación de fuentes" a tu `CLAUDE.md` raíz.

Cuando lo tengas, corre `/mefisto:onboard` para verificar de un vistazo que el config está bien formado y qué te falta (labels, CI). Por defecto solo diagnostica; bajo tu confirmación explícita puede además provisionar los **labels** faltantes (el script subyacente es destructivo) y configurar el **CI** hacia Azure (crea recursos reales en Azure vía OIDC; debe correr **después** de `bootstrap-backend.sh`, ver paso 5). También puedes correr `setup-github-labels.sh` / `setup-github-ci.sh` a mano si prefieres.

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

### 4. Bootstrap del repo del consumidor (labels y CI)

Antes del primer `/draft` o `/implement`, tu repo necesita dos prerequisitos operativos que el harness **no** crea solo: el esquema de **labels** de GitHub y la **autenticación de CI** hacia Azure. Ambos se provisionan con scripts del plugin, así que se invocan **plugin-relative** (nunca `./scripts/...` desde tu repo —los scripts del harness no viven en él, ver paso 3): resuelve `$PLUGIN_SCRIPTS` y llama al script por ruta absoluta. Los dos llevan el guard defensivo de MEF-ADR-0019 y **abortan si se corren dentro del repo de Mefisto** (solo aplican al consumidor).

Para verificar de un vistazo qué falta (labels ausentes, CI sin configurar) antes y después de este paso, corre el doctor de onboarding `/mefisto:onboard` (por defecto solo diagnostica; bajo tu confirmación puede provisionar los labels faltantes y configurar el CI hacia Azure —este último, después del bootstrap del backend del paso 5).

**a. Labels de GitHub** — `setup-github-labels.sh`. El `planner`, `/draft` y los pipelines exigen los labels dimensionales `tipo:*`, `dom:*` y `estado:{borrador|listo}` como prerequisito operativo (**MEF-ADR-0007**); sin ellos el primer `/draft` falla al etiquetar. El script **borra 8 de los 9 labels default de GitHub** (`documentation`, `duplicate`, `enhancement`, `good first issue`, `help wanted`, `invalid`, `question`, `wontfix`) y **recrea `bug`** con el esquema del harness, además de crear el resto del esquema, incluyendo un `dom:<x>` por cada entrada de `domainLabels` en `.claude/harness.config.json`. **Prerequisitos**: `gh auth login` y el campo `domainLabels` ya declarado en el config (paso 2).

```bash
PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
[ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
PLUGIN_SCRIPTS="${PLUGIN_ROOT%/}/scripts"
"$PLUGIN_SCRIPTS/setup-github-labels.sh"
```

**b. CI hacia Azure** — `setup-github-ci.sh <subscription-id>`. Configura, vía OIDC, la autenticación de GitHub Actions hacia Azure (**MEF-ADR-0022**). **Prerequisitos**: `gh auth login`, `az login` y el `<subscription-id>` de Azure. Como **resuelve el nombre real de la Storage Account del tfstate** (con el sufijo de unicidad que le puso el bootstrap) para asignar el rol de acceso, **depende del backend del tfstate y debe ejecutarse DESPUÉS de crearlo**: la descripción completa (roles asignados, federated credentials) y la invocación viven en el paso 5 (Bootstrap de infraestructura, sub-paso 2), no aquí.

### 5. Bootstrap de infraestructura

El backend remoto de Terraform (donde vive el `tfstate`) es prerequisito de todo lo demás. El orden es:

1. **Crear el backend del tfstate** con `bootstrap-backend.sh` (idempotente; crea Resource Group `rg-<proyecto>-tfstate`, Storage Account endurecida —con un **sufijo de unicidad global** sobre el nombre base de `terraformStateStorage`, ver la nota de ese campo arriba— y container `tfstate`, y escribe `infra/environments/<env>/backend.tf` con el nombre final resuelto):

   ```bash
   PLUGIN_ROOT=$(cat .claude/pipeline/.plugin-root 2>/dev/null)
   [ -z "$PLUGIN_ROOT" ] && PLUGIN_ROOT=$(ls -d "$HOME"/.claude/plugins/cache/*/mefisto/*/ 2>/dev/null | sort -V | tail -1)
   PLUGIN_SCRIPTS="${PLUGIN_ROOT%/}/scripts"
   "$PLUGIN_SCRIPTS/bootstrap-backend.sh" --subscription <subscription-id> --env dev
   ```

   (Pasa `--location <region>` si no declaraste `azureLocation` en el config.) También puedes dejar que lo orqueste el agente `infra-bootstrap`, que encadena este paso con el primer `/infra`.

   > **Primera corrida: rol de datos requerido.** La primera vez que corres `bootstrap-backend.sh`, el paso que crea el container `tfstate` usa `--auth-mode login` (acceso por AAD, sin access key): tu identidad de Azure (`az login`) necesita el rol de datos **`Storage Blob Data Contributor`** sobre la Storage Account del tfstate, además de los permisos de control plane para crearla. Si eres `Owner` de la suscripción/resource group ya lo tienes implícito; si solo eres `Contributor` (que no otorga acceso a datos de blobs), asígnatelo tú mismo o pide que te lo asignen antes de correr el script. Si falta, el script aborta con un mensaje que nombra el rol; es idempotente, así que basta reintentar tras la propagación RBAC (unos minutos).

   > **Nota**: el script escribe `backend.tf` en tu working tree. El pipeline IaC (`/infra`) ramifica su worktree desde `origin/main`, así que **automatiza** que ese `backend.tf` llegue al worktree: lo copia del working tree al worktree y lo commitea en la rama del pipeline, de modo que viaja en el PR y se versiona en `main` vía merge. No necesitas commitearlo ni subirlo a `main` a mano antes del primer `/infra` (el `terraform init` del reviewer ya encuentra el backend remoto y no cae a estado local).

2. **Configurar la autenticación de CI hacia Azure** con `setup-github-ci.sh`. Usa **OIDC** (Workload Identity Federation, ver **MEF-ADR-0022**): crea el Service Principal de GitHub Actions **sin secret** y le asigna, a nivel suscripción, `Contributor` (deploy de Functions e infraestructura) y `Role Based Access Control Administrator` con una condición ABAC anti-escalación (para que el `apply` de CI pueda crear los role assignments que emiten los scaffolders — **MEF-ADR-0025** — sin poder auto-asignarse `Owner`, `User Access Administrator` ni el propio rol); y sobre el tfstate ya creado, `Storage Blob Data Contributor` (lectura+escritura por AAD, backend keyless) — resuelve el nombre **final** de la Storage Account —con el sufijo que le puso el bootstrap— leyéndolo del `backend.tf` recién escrito, así que la asignación de rol apunta a la cuenta real, no al nombre base del config. Le añade además **dos federated credentials**: uno que confía en la rama `main` del repo (deploy de código y `apply` de infra) y otro en el evento `pull_request` (el `terraform plan` que corre en cada PR). Por eso corre **después** del paso 1:

   > **Idempotencia parcial de la condición ABAC.** `az role assignment create` es idempotente (no falla si la asignación ya existe), pero **no actualiza la condición** de una asignación que ya exista con el mismo principal/rol/alcance. La asignación de `Role Based Access Control Administrator` con la condición anti-escalación la introdujo el issue #195 (antes, el script solo asignaba `Contributor` y lectura del tfstate), así que en un onboarding limpio se crea de una vez **con** la condición. El caso a vigilar: si el SP ya tuviera una asignación de `Role Based Access Control Administrator` **sin** esa condición —creada fuera de este script (p. ej. a mano), o si una versión futura del script cambia la expresión de la condición—, re-correr `setup-github-ci.sh` detecta la asignación existente y la deja tal cual: **no** le aplica ni actualiza la condición, y el SP queda con el rol sin la restricción anti-escalación. **Diagnóstico**: `az role assignment list --assignee <appId> --query "[?roleDefinitionName=='Role Based Access Control Administrator'].condition"` — si sale vacío, borra la asignación (`az role assignment delete`) y vuelve a correr el script para que la recree **con** la condición. El arreglo del script (detectar y recrear automáticamente) queda diferido a un issue aparte.

   ```bash
   "$PLUGIN_SCRIPTS/setup-github-ci.sh" <subscription-id>
   ```

   El slug `owner/repo` (subject del federated credential) se resuelve automáticamente vía `gh` o el remote `origin`; pásalo como 2º argumento si necesitas forzarlo. Copia los **tres** secrets que imprime —`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`— a *Settings > Secrets and variables > Actions* de tu repo. **No hay client secret que expire**: el workflow de deploy del scaffolder se autentica con `azure/login` por OIDC (declara `permissions: id-token: write`), no con el JSON único `AZURE_CREDENTIALS`.

3. **Generar la infraestructura base** con `/infra-base` (agente `infra-base-scaffolder`). Es el eslabón entre el backend y el primer `/infra`: escribe los 8 módulos Terraform base (`resource-group`, `monitoring`, `postgresql`, `service-bus`, `service-plan`, `storage`, `function-app`, `key-vault`) y el esqueleto del entorno (`main.tf`, `variables.tf`, `providers.tf`, `outputs.tf`) — **sin** `backend.tf` (ese lo escribió el paso 1). Es idempotente: si ya existen archivos, los respeta. Ver **MEF-ADR-0021**.

   ```
   /mefisto:infra-base dev
   ```

   `variables.tf` declara dos variables requeridas sin default -- `alert_email` y `postgresql_admin_password` -- que **nunca** van en un `terraform.tfvars` commiteado (MEF-ADR-0025): `infra-cd.yml` las alimenta como `TF_VAR_alert_email`/`TF_VAR_postgresql_admin_password` desde una GitHub **variable** (`ALERT_EMAIL`) y un GitHub **secret** (`TF_VAR_POSTGRESQL_ADMIN_PASSWORD`) que **crea manualmente el admin del repo** en *Settings > Secrets and variables > Actions* (pestañas *Variables* y *Secrets* respectivamente) -- `setup-github-ci.sh` no los toca. Usa como valor del secret el **mismo** password que CI reutiliza, dentro del mismo `apply`, para sembrar `marten-connection` en el Key Vault (ver paso 5), para no manejar dos valores. `subscription_id` ya no es una variable de este entorno: el provider `azurerm` la resuelve nativamente de `ARM_SUBSCRIPTION_ID` (secret ya copiado en el paso 2). El scaffolder también genera un `.gitignore` en el entorno que excluye `terraform.tfvars`, por si lo usas localmente para overridear defaults no sensibles (`project`, `project_short`, `postgresql_location`); revísalos ahí. Sin esta base, `/infra` y `/scaffold` asumen módulos que no existirían y fallarían.

   > **Valida `postgresql_location` antes del primer `terraform apply`.** No tiene por qué coincidir con `azureLocation` (que es solo la región del backend del tfstate). Algunas regiones devuelven `LocationIsOfferRestricted` al crear el PostgreSQL Flexible Server según tu suscripción —`eastus2` lo hizo en el primer greenfield real, resuelto con `centralus`—. Verifica la tuya con `az postgres flexible-server list-skus --location <region> -o table` (debe listar `Standard_B1ms`); ver la nota del campo `azureLocation` (sección "Configurar el consumidor") y MEF-ADR-0021.

4. **Primer `/infra`**: lanza el pipeline IaC para tu primer issue `tipo:infra`. El pipeline escribe y revisa el HCL de forma **estática** (sin `terraform plan` ni `apply` local, sin credenciales de Azure) y abre un PR:

   ```
   /mefisto:infra <numero-de-issue>
   ```

   > **El apply es de CI, no local (MEF-ADR-0021, MEF-ADR-0022).** En el flujo *ongoing* el desarrollador que usa Mefisto no aplica ni planifica local: no necesita `az login` con permisos elevados de Azure ni acceso al tfstate. `/infra` solo escribe/revisa el HCL y abre el PR (que **no** lleva `Closes #N`). El `terraform plan` real se publica como comentario del PR y el `terraform apply` real corre al mergearlo a `main`, ambos en CI (workflow `Infra CD`); ese workflow cierra el issue cuando el apply termina exitosamente. El bootstrap inicial (backend + CI, pasos 1-2) sí es una operación privilegiada de una sola vez que corre un admin con permisos de Azure.

5. **GitHub secrets que alimentan la siembra de secretos en CI** -- ya no hay ninguna acción manual sobre el Key Vault (**MEF-ADR-0025** decisión #10, perfil (c) reformado). Tras el `apply` que corre en CI al mergear el PR del paso 4, el mismo job itera `harness.config.json > secrets[]` y siembra con `az keyvault secret set` **todos** los secretos del BC -- Terraform nunca escribe su valor (MEF-ADR-0025 decisión #6) --, habilitado por el rol de datos `Key Vault Secrets Officer` que el propio `apply` se autoasigna sobre el vault (mecanismo M1, **MEF-ADR-0022**). Ningún humano necesita un rol de datos de Key Vault. `/infra-base` ya registró en `secrets[]`, de forma idempotente, los secretos fijos del BC (ver campo `secrets` en "Configurar el consumidor"); el step de siembra es **data-driven**: no tiene ninguna línea hardcodeada por secreto, así que agregar uno nuevo después del greenfield (`/seed-secret`, ver catálogo de skills) nunca exige editar `infra-cd.yml` a mano.

   Lo único que le queda al admin del repo es crear, en *Settings > Secrets and variables > Actions*, los GitHub secrets que alimentan los valores que CI no puede derivar de `terraform output`:

   | Secreto de Key Vault | GitHub secret que lo alimenta | Cuándo crearlo |
   |---|---|---|
   | `marten-connection` | `TF_VAR_POSTGRESQL_ADMIN_PASSWORD` | ya lo creaste en el paso 3 -- el mismo valor sirve para crear el servidor PostgreSQL y para componer este secreto |
   | cada `serviceBus.external[].secretName` con `alcance: "compartido"` | `SB_EXTERNAL_<ALIAS>_CONNECTION_STRING` (uno por alias, MEF-ADR-0024 decisión #4) | antes del primer `apply` que declare ese alias, con el valor que provee el equipo de infra dueño del backbone compartido |
   | cada secreto nuevo con `source.type: "github-secret"` (`/seed-secret --from-github-secret`) | el nombre que declares en `source.value` | antes del primer `apply` que lo siembre |

   `serviceBus.internal.secretName` y `app-insights-connection` no requieren ningún GitHub secret: CI los deriva directamente de `terraform output` (`service_bus_interno_connection_string` y `app_insights_connection_string`, respectivamente); lo mismo aplica a cualquier secreto nuevo registrado con `source.type: "output"`.

### 6. Scaffold del primer dominio y primer ciclo TDD

Con el backend listo, crea el scaffold de tu primer dominio y arranca el ciclo TDD:

```
/mefisto:scaffold <dominio>      # estructura src/ + tests/ + módulos de infra del dominio
/mefisto:draft "primera capacidad del dominio"   # captura la idea como issue borrador
# el planner refina el issue a estado:listo
/mefisto:implement <issue>       # pipeline TDD: test-writer (rojo) -> implementer (verde) -> reviewer -> PR
```

Si tu dominio necesita un secreto nuevo (una API key de un proveedor externo, otra cadena de conexión, etc.), registra y cablea la referencia con:

```
/mefisto:seed-secret <nombre> --domain <Dominio> (--from-output <output-de-terraform> | --from-github-secret <NOMBRE_DEL_GITHUB_SECRET>)
```

### 7. Qué corre dónde

| Acción | `cwd` | Dónde vive el binario/artefacto |
|---|---|---|
| Skills (`/infra`, `/implement`, `/scaffold`, ...) | tu repo consumidor | definición en el plugin (cache del marketplace) |
| `bootstrap-backend.sh`, `setup-github-ci.sh`, `iac-pipeline.sh`, `tdd-pipeline.sh`, ... | operan sobre tu repo consumidor | binario en el plugin; se resuelven vía `$PLUGIN_SCRIPTS` |
| `terraform plan` (en cada PR) / `terraform apply` (al mergear a `main`) | **runner de GitHub Actions**, nunca tu máquina | workflow `.github/workflows/infra-cd.yml` (lo genera `/infra-base`; MEF-ADR-0021, MEF-ADR-0022) |
| ADRs del marco (`docs/adr/`) | — | en el plugin; los agentes los leen vía `$PLUGIN_ROOT/docs/adr/` |
| `.claude/harness.config.json`, `CLAUDE.md`, `src/`, `tests/`, `infra/` | tu repo consumidor | **tu repo** (los crea/edita el harness operando sobre el consumidor) |
| `infra/environments/<env>/backend.tf` | tu repo consumidor | **tu repo** (lo escribe `bootstrap-backend.sh` en runtime) |

Regla mnemónica: **los binarios viven en el plugin; los archivos del proyecto viven en tu repo.** Nunca edites archivos dentro del cache del plugin ni invoques sus scripts con rutas relativas. Y desde la reforma de la oleada "apply en CI" (MEF-ADR-0021, MEF-ADR-0022): **el plan/apply de infraestructura vive en CI, nunca en tu máquina** — la única excepción es el bootstrap inicial (backend + CI, sección "Bootstrap de infraestructura" arriba), una operación privilegiada de una sola vez que corre un admin con permisos de Azure. La siembra de los secretos de Key Vault (mismo paso 5) **ya no** es un tercer perfil manual recurrente: es un step automático dentro del mismo `apply` de CI, habilitado por el rol de datos que el propio `apply` se autoasigna sobre el vault (mecanismo M1, MEF-ADR-0022) — ningún humano necesita un rol de datos de Key Vault. Los perfiles de acceso **humanos** del marco quedan en dos (el tercer perfil de la decisión #10, la siembra, ya no lo ejecuta una persona sino CI): (a) desarrollador ongoing, cero credenciales de Azure, y (b) bootstrap, privilegiado y de una sola vez.

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

## Migración para consumidores existentes

### Añadir `boundedContext`

El campo `boundedContext` es **obligatorio** (MEF-ADR-0023). Si actualizas desde una versión que no lo exigía, `load_harness_config` abortará con un mensaje que muestra el shape exacto a añadir. Para migrar:

1. **Abre `.claude/harness.config.json`** de tu proyecto y añade el campo `boundedContext` antes del cierre `}`:

   ```json
   "boundedContext": {
     "name": "Principal",
     "domains": ["dominio1", "dominio2"]
   }
   ```

   - `name`: elige un nombre para tu BC (ej: "Principal", "Admin", "Core"). Puede coincidir con `projectName`.
   - `domains`: lista tus `domainLabels` actuales. Si todos tus dominios pertenecen a un solo BC (caso más común), pon todos. Si tienes múltiples BCs futuros, pon solo los que pertenecen a este BC.

2. **Añade los tokens al `CLAUDE.md`** de tu proyecto (sección "Tokens del harness"):

   ```markdown
   - **BoundedContext**: Principal
   - **BoundedContextDomains**: dominio1, dominio2
   ```

3. **Verifica con `/mefisto:onboard`**: el checklist mostrará `[OK] boundedContext declarado: name='Principal' domains='...'`.

> **Tip**: si tienes dudas sobre el nombre del BC, usa el mismo `projectName`. La convención del harness es `BC name ≈ projectName` cuando hay un solo BC por proyecto.

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

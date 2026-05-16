# ADR-0019: Separacion fisica de skills publicados (consumidor) vs internos (Mefisto)

- **Fecha**: 2026-05-15
- **Estado**: aceptado
- **Aplica a**: estructura del repo del plugin, skills, agentes, pipelines, hooks.

## Contexto

Antes de la separacion del repo, los skills del harness (`/tooling`, `/draft`, `/bug`, etc.) coexistian con el codigo de la aplicacion en un solo repositorio. Tras extraer el harness a `eda-evsourcing-azure-harness` y publicarlo como Claude Code Plugin (`mefisto`), aparecieron dos contextos de trabajo distintos:

1. **Proyecto consumidor**: el plugin se instala via marketplace. Los skills publicados (`/tooling`, `/implement`, ...) modifican archivos del consumidor.
2. **Repo del propio plugin**: para evolucionar el harness (anadir skills, refactorizar pipelines, crear ADRs) se necesitan operaciones equivalentes pero contra archivos del propio plugin.

Sin barrera explicita, el mismo `/tooling` podia:

- Modificar archivos del consumidor si se invocaba en su repo.
- Modificar archivos del plugin si se invocaba en el repo del plugin.

Eso permitia errores cruzados (un agente del consumidor tocando `commands/`, `agents/` o `.claude-plugin/` por accidente) y mezclaba la conversacion: "estoy mejorando mi proyecto" vs "estoy mejorando el harness".

## Decision

Separar fisicamente los dos sets:

### A. Lado publicado (distribuido via marketplace)

Permanece en el top-level del repo del plugin:

- `commands/` -- skills publicados.
- `agents/` -- agentes publicados.
- `scripts/` -- pipelines bash publicados.
- `hooks/hooks.json` -- hooks publicados.

Los skills publicados:

- Solo operan sobre archivos del consumidor (workflows en `.github/`, fixtures de `tests/`, `.claude/harness.config.json`, `.claude/settings.json`, `pipeline-state/`, scripts ad-hoc del consumidor).
- Tienen un **guard defensivo** al inicio que aborta si detectan `.claude-plugin/plugin.json` en el cwd (i.e., si por error alguien los invoca dentro del repo de Mefisto).
- El pipeline `scripts/tooling-pipeline.sh` aplica un **gate de scope** (`validate_consumer_scope_changes`) que rechaza el PR si el agente toca `commands/`, `agents/`, `hooks/`, `.claude-plugin/` o `docs/adr/` (rutas reservadas al plugin).
- Los pipelines de orquestacion (`parallel-pipeline.sh`, `batch-pipeline.sh`, `pr-sync.sh`) abortan si se invocan dentro del repo de Mefisto.

### B. Lado interno (NO distribuido)

Vive en `.claude/` del repo del propio plugin:

- `.claude/commands/` -- skills internos con prefijo `mefisto-` (`/mefisto-tooling`, `/mefisto-plan`, `/mefisto-bug`, `/mefisto-fix-review`, `/mefisto-merge`, `/mefisto-work-status`).
- `.claude/agents/` -- agentes internos (`mefisto-investigator`, `mefisto-planner`).
- `.claude/scripts/` -- pipelines internos (`_mefisto-common.sh`, `mefisto-tooling-pipeline.sh`, `mefisto-tmux-pipeline.sh`).

Los skills internos:

- Solo operan sobre archivos del propio plugin (`commands/`, `agents/`, `scripts/`, `hooks/`, `docs/`, `.claude-plugin/`, `.claude/{commands,agents,scripts}/`, gobierno del repo).
- Tienen un **guard inverso**: abortan si NO detectan `.claude-plugin/plugin.json` (i.e., si alguien los invoca fuera del repo de Mefisto).
- Claude Code los carga automaticamente cuando se abre el repo de Mefisto, **sin necesidad de instalar el plugin sobre si mismo**. Esto se basa en que `.claude/commands/` y `.claude/agents/` son convenciones de configuracion por-repo del propio Claude Code, separadas del plugin distribuido.

### C. Routing cross-repo: solo drafts

La unica operacion permitida desde el consumidor hacia el repo de Mefisto es **crear un draft** (`estado:borrador`). El refinamiento, desglose, oleadas, backlog, analisis y limpieza de issues del plugin se hacen exclusivamente con `/mefisto-plan` dentro del repo del plugin.

- `agents/tooling-investigator.md` y `agents/planner.md` (publicados) implementan esta restriccion: si la causa raiz vive en el plugin, abren un draft con `gh -R augusto-romero-arango/eda-evsourcing-azure-harness ...` y detienen el flujo.
- El slug del repo de Mefisto se lee de `.claude-plugin/plugin.json` (campo `repoSlug`) o de `.claude/harness.config.json` (campo `harnessRepoSlug`); default: `augusto-romero-arango/eda-evsourcing-azure-harness`. Esto soporta forks.

### D. Grupos de trabajo homogeneos

Los pipelines de orquestacion (`/parallel`, `/sequential`, `scripts/batch-pipeline.sh`) consultan cada issue con `gh issue view N` sin `-R`. Issues de otros repos retornan `UNKNOWN` y se descartan automaticamente. No se admiten flags `-R` ni grupos mixtos.

## Skills sin equivalente interno

Mefisto es un harness, no un producto. Estos skills publicados **no tienen version interna** porque no aplican conceptualmente al harness:

- `/implement` (TDD .NET de dominio).
- `/infra` (Terraform/Azure).
- `/scaffold` (crear nuevo dominio).
- `/health-check` (App Insights).
- `/show-flow`, `/eraser-diagram` (flujos EDA y diagramas).

Aun asi, todos llevan guard defensivo "cwd != Mefisto" para evitar invocaciones erroneas.

## Alternativas consideradas

### Alt 1: Un solo skill `/tooling` context-aware

Detectar el modo (`plugin` vs `consumer`) en el script via marcadores fisicos y bifurcar comportamiento.

**Descartado**: el usuario manifesto explicitamente que el lado publicado **no debe poder modificar el plugin**, ni siquiera con context-awareness, para reducir el riesgo de cruces y para que los dos sets puedan **diverger libremente** con el tiempo. Un skill unico forzaria a mantener ambas variantes en el mismo archivo, frenando la divergencia.

### Alt 2: Flag explicito `--target plugin|consumer`

Un solo `/tooling` con flag obligatorio que declare la intencion.

**Descartado**: agrega friccion al uso comun (90% del tiempo el usuario sabe en que repo esta), y no resuelve el problema de fondo (los skills del consumidor deberian NO poder modificar el plugin bajo ninguna circunstancia).

### Alt 3: Dos paquetes de plugin separados (`mefisto-core` + `mefisto-dev`)

Pros: separacion fisica dura. Contras: dos artefactos a publicar y mantener, dependencias circulares.

**Descartado**: la separacion via `.claude/` interna ya es suficiente (no se publica, fisicamente separada) sin requerir un segundo paquete.

## Consecuencias

### Positivas

- **Imposible cruzar el limite por accidente**: los skills publicados nunca tocan el plugin (gate de scope + guard defensivo); los skills internos nunca tocan el consumidor (guard inverso + scope hardcoded).
- **Divergencia libre**: los dos sets pueden evolucionar en direcciones distintas. El interno puede simplificarse (sin App Insights, sin Terraform, sin `dom:`), el publicado puede enriquecerse para el consumidor.
- **UX clara**: prefijo `mefisto-` en pantalla declara explicitamente "esto es para evolucionar Mefisto". El desarrollador del harness ve solo `/mefisto-*` (no se expone a `/implement`, `/infra` que no aplican).
- **Routing cross-repo preserva contexto**: cuando un consumidor descubre un bug del harness, el draft se crea en el repo correcto con la URL de las field notes locales como puente.

### Negativas

- **Duplicacion inicial**: los pipelines y agentes empezaran muy parecidos (mefisto-tooling-pipeline.sh es ~85% identico a tooling-pipeline.sh). Aceptado deliberadamente; refactorizar a un common compartido solo cuando la duplicacion duela en la practica (regla de tres -- ADR-0018).
- **Guard defensivo en cada skill**: cada `.md` lleva un bloque de pre-condicion. Un developer puede olvidarlo al anadir un skill nuevo. Mitigacion: test de guards (`scripts/tests/`) que itera sobre todos los skills publicados y verifica que abortan al invocarse en Mefisto.
- **Fork del repo de Mefisto**: el slug hardcodeado en el routing del publicado queda incorrecto para forks. Mitigado con `HARNESS_REPO_SLUG` configurable (campo nuevo `repoSlug` en `plugin.json` o `harnessRepoSlug` en `.claude/harness.config.json`).
- **Documentacion adicional**: este ADR + secciones nuevas en CLAUDE.md y README.md son necesarias para que un nuevo developer entienda los dos sets.

## Referencias

- Conversacion de diseno y plan detallado: `~/.claude/plans/me-qued-con-una-quiet-bunny.md` (commits del 2026-05-15).
- ADR-0018 (heuristicas de evolucion y reuso): justifica posponer el refactor a un common compartido entre lado publicado e interno.
- ADR-0007 (gestion de proyecto con GitHub Issues): los labels `tipo:tooling` y `estado:borrador|listo` se aplican igual en ambos repos.
- ADR-0011 (Definition of Ready por tipo de issue): el DoR del harness es una version simplificada del DoR del consumidor (sin "Modelo de eventos", sin `dom:`).

---
model: opus
---

Resuelve los comentarios de revision de un pull request. Comunicate en **espanol**.

## Pre-condicion: cwd != Mefisto

Este skill es del plugin publicado y solo aplica al repo consumidor. Para PRs del propio plugin, usa `/mefisto-fix-review`:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: no estas en un repositorio git"; exit 1; }
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
    echo "ERROR: /fix-review no aplica al repo de Mefisto. Usa /mefisto-fix-review en su lugar."
    exit 1
fi
```

## Entrada

El numero de PR esta en: $ARGUMENTS

Si `$ARGUMENTS` esta vacio, responde: `Uso: /fix-review <numero-de-PR>`

---

## Fase 1: Triaje

### 1.1 Obtener datos del PR

Lee en paralelo:

```bash
gh pr view $ARGUMENTS --json title,body,state,headRefName,baseRefName,url
```

```bash
gh api repos/{owner}/{repo}/pulls/$ARGUMENTS/comments --jq '.[] | "---\nid: \(.id)\nfile: \(.path)\nline: \(.line // .original_line)\nbody: \(.body)\n"'
```

Si el PR no existe o esta cerrado, informa y detente.

Verifica que estas en la rama correcta del PR (`headRefName`). Si no:

```bash
git checkout <headRefName>
```

### 1.2 Explorar el codigo referenciado

Para cada comentario, lee el archivo y las lineas referenciadas. Usa la herramienta `Read` directamente (no Bash).

Si un comentario referencia un ADR, convencion o patron, leelo tambien para tener contexto completo.

### 1.3 Clasificar cada comentario

Clasifica cada comentario en una de estas categorias:

| Categoria     | Significado                                              | Accion                                  |
|---------------|----------------------------------------------------------|-----------------------------------------|
| **resuelto**  | El codigo ya esta correcto (cambio posterior lo resolvio) | Responder explicando que ya esta resuelto |
| **explicar**  | El codigo esta bien pero falta contexto                  | Responder con explicacion tecnica        |
| **corregir**  | El reviewer tiene razon, hay que cambiar codigo          | Planificar y ejecutar cambio             |
| **investigar**| No hay respuesta inmediata, requiere trabajo separado    | Proponer issue de seguimiento            |

### 1.4 Presentar triaje al usuario

Muestra una tabla con la clasificacion:

```
## Triaje de comentarios — PR #N

| # | Archivo                    | Categoria   | Resumen                              |
|---|----------------------------|-------------|--------------------------------------|
| 1 | src/.../MiArchivo.cs:42    | corregir    | Falta parametro X en constructor     |
| 2 | tests/.../MiTest.cs:15     | explicar    | El patron es correcto segun MEF-ADR-0005  |
| 3 | infra/.../main.tf:51       | resuelto    | Ya corregido en commit abc1234       |
| 4 | tests/.../Smoke.cs:14      | investigar  | Requiere investigacion de approach   |
```

**Espera confirmacion del usuario.** El usuario puede:
- Aprobar el triaje tal cual
- Reclasificar comentarios (ej: "el 2 tambien hay que corregirlo")
- Agregar contexto que cambie la clasificacion

**No avances a la Fase 2 sin aprobacion explicita del triaje.**

---

## Fase 2: Plan

### 2.1 Entrar en plan mode

Usa `EnterPlanMode` para planificar los cambios. Escribe el plan en el archivo que el sistema te asigne.

### 2.2 Estructura del plan

El plan debe tener esta estructura:

```markdown
# Plan: Resolver comentarios del PR #N

## Contexto
[Por que se hace este cambio — el PR, los comentarios, el issue original]

## Comentarios a corregir
[Para cada comentario clasificado como "corregir":]

### C<id>: <resumen del comentario>
- **Archivo**: <path>:<linea>
- **Cambio**: <descripcion concreta del cambio>
- **Impacto**: <otros archivos afectados>

## Comentarios a explicar
[Para cada comentario clasificado como "explicar":]

### C<id>: <resumen>
- **Borrador de respuesta**: <texto que se publicara como respuesta>

## Comentarios ya resueltos
[Lista breve]

## Comentarios a investigar
[Para cada uno, propuesta de issue de seguimiento]

## Orden de ejecucion
[Cambios agrupados por dependencia]

## Verificacion
[Comandos para validar: build, tests]
```

### 2.3 Salir de plan mode

Usa `ExitPlanMode` para que el usuario revise y apruebe el plan.

**No avances a la Fase 3 sin aprobacion del plan.**

---

## Fase 3: Ejecutar

### 3.1 Aplicar cambios de codigo

Ejecuta los cambios del plan en el orden definido. Usa `Edit` para modificar archivos existentes, `Write` solo para archivos nuevos.

### 3.2 Verificar

```bash
dotnet build
dotnet test
```

Si hay errores, corrigelos antes de continuar. Si un test falla por una razon no relacionada con tus cambios, informalo al usuario.

### 3.3 Commit y push

Crea un commit con mensaje descriptivo que referencie el PR:

```
fix(hu-N): resolver comentarios de revision del PR #N

- [resumen de cambios principales]

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
```

Haz push a la rama del PR.

---

## Fase 4: Responder

### 4.1 Redactar respuestas finales

Para **cada** comentario del PR, redacta una respuesta informada por lo que realmente se hizo:

- **corregir**: "Corregido en [commit]. [descripcion breve del cambio]."
- **explicar**: La explicacion tecnica del plan (puede ajustarse si durante la ejecucion aprendiste algo nuevo).
- **resuelto**: "Este punto ya estaba resuelto en [commit/contexto]. [explicacion breve]."
- **investigar**: "Creado issue #N para investigar este punto. [enlace]."

### 4.2 Presentar borradores al usuario

Muestra todas las respuestas en una tabla o lista antes de publicarlas:

```
## Respuestas a publicar — PR #N

### Comentario 1 (src/.../MiArchivo.cs:42) — corregir
> [cita del comentario original]

Respuesta: "Corregido en abc1234. Se agrego el parametro X al constructor..."

### Comentario 2 (tests/.../MiTest.cs:15) — explicar
> [cita del comentario original]

Respuesta: "El patron es correcto segun MEF-ADR-0005 porque..."
```

**Espera aprobacion del usuario antes de publicar.**

### 4.3 Publicar respuestas en GitHub

Para cada respuesta aprobada:

```bash
gh api repos/{owner}/{repo}/pulls/$ARGUMENTS/comments \
  -f body="<respuesta>" \
  -F in_reply_to=<comment-id>
```

> **Importante:** El endpoint correcto para responder a un review comment es `POST /pulls/{pr}/comments` con el parametro `in_reply_to` apuntando al ID del comentario original. NO uses el sub-endpoint `/replies` — no existe y retorna 404.

Confirma al final:

```
Listo. PR #N:
- N comentarios respondidos
- N cambios aplicados (commit abc1234)
- N issues de seguimiento creados
```

---

## Fase 5: Mejora continua

Cada comentario de review es evidencia de un gap en las instrucciones de un agente. Esta fase traza las correcciones hasta su origen y propone mejoras.

> **Modelo plugin.** Tras la extraccion del harness al plugin `mefisto`, los agentes/skills del marco ya **no viven en el repo consumidor**: estan en el cache del plugin (`~/.claude/plugins/cache/.../mefisto/<version>/agents/`), read-only y versionado. Por eso una mejora a un agente/skill del harness **no se puede editar en la rama del PR del consumidor**: se enruta como **draft** (`estado:borrador`) al repo de Mefisto via `gh -R`, igual que hacen el `planner` y el `tooling-investigator` publicados (ver `CLAUDE.md` "Routing cross-repo: solo drafts" y MEF-ADR-0019). La edicion en-rama queda reservada a lo que realmente vive en el consumidor (un ADR local del proyecto, convenciones de su `CLAUDE.md`, un fixture/helper propio).

### 5.1 Trazar correcciones a su origen

Lee el body del PR — el pipeline TDD registra decisiones de cada agente (test-writer, implementer, reviewer) en secciones `<details>`. Para cada comentario clasificado como "corregir":

- **¿Que agente produjo el codigo?** (test-writer, implementer, reviewer, infra-writer, domain-scaffolder, etc.)
- **¿Que tipo de gap causo el error?**
  - Regla faltante: el agente no tenia instruccion sobre este caso
  - Regla ignorada: la instruccion existe pero no se siguio (reforzar o reformular)
  - Conocimiento de dominio: el agente no tenia contexto de negocio o arquitectura
  - Limitacion del framework: el agente no conocia un overload, API o patron del framework

### 5.2 Proponer ajustes concretos

Para cada gap identificado, proponer:

```
## Propuesta de mejora — PR #N

### Ajuste 1: [descripcion breve]
- **Agente/skill afectado**: `implementer` (o `reviewer`, `test-writer`, skill, pipeline). Si es del harness, vive en el plugin `mefisto`, no en `.claude/agents/` del consumidor.
- **Destino del ajuste**: draft en el harness | edicion local en el consumidor
- **Seccion**: [nombre de la seccion donde iria el cambio]
- **Tipo de gap**: regla faltante | regla ignorada | conocimiento dominio | limitacion framework
- **Causa raiz**: [por que el agente tomo la decision incorrecta]
- **Cambio propuesto**: [descripcion del ajuste — nueva regla, ejemplo, reformulacion]

### Ajuste 2: ...
```

El **destino** se decide por donde vive el archivo a tocar: un agente/skill/pipeline/hook del harness va como **draft a Mefisto** (no es editable desde el consumidor); un ADR local o una convencion del `CLAUDE.md` del consumidor se **edita en-rama**. La Fase 5.4 detalla cada caso.

Si el PR no tuvo correcciones que ameriten mejoras (todos los comentarios eran "explicar" o "resuelto"), indica que no hay ajustes necesarios y salta a la field note.

### 5.3 Presentar plan de mejora al usuario

Muestra las propuestas. **Espera aprobacion explicita.** El usuario puede:
- Aprobar todas
- Descartar algunas
- Reformular la redaccion de una regla
- Agregar contexto que enriquezca la mejora

### 5.4 Aplicar los ajustes aprobados

Cada ajuste aprobado tiene un **destino** segun donde viva el archivo a tocar:

| Destino | Donde vive el archivo | Accion |
|---|---|---|
| **Harness** (`mefisto`) | Cache del plugin (`~/.claude/plugins/cache/.../mefisto/<version>/`), read-only y versionado | **Crear un draft** (`estado:borrador`) en el repo de Mefisto via `gh -R` |
| **Consumidor** (este repo) | ADR local del proyecto (`docs/adr/`), convencion de su `CLAUDE.md`, fixture/helper propio | **Editar en-rama** con `Edit`, commit en la rama del PR |

#### Detectar el modelo (plugin vs local)

El guard del inicio del skill ya garantiza que **no** hay `.claude-plugin/plugin.json` en el cwd (no estas en Mefisto). Falta confirmar si los agentes del harness viven localmente o en el cache del plugin:

```bash
# Modelo plugin: el harness se instala via marketplace; sus agentes NO estan en el consumidor.
if [ ! -d ".claude/agents" ] || [ -z "$(ls -A .claude/agents 2>/dev/null)" ]; then
    echo "Modelo plugin: las mejoras a agentes/skills del harness se enrutan como DRAFT a Mefisto."
fi
```

- **Modelo plugin** (caso normal hoy): no hay `.claude/agents/` propios en el consumidor → toda mejora a un agente/skill del harness se enruta como draft a Mefisto (siguiente bloque).
- **Modelo local** (legado pre-extraccion): si el consumidor todavia conserva copias locales en `.claude/agents/`, esos archivos si se pueden editar en-rama como cualquier archivo del consumidor.

#### Si el ajuste es al harness: crear un draft cross-repo

Reutiliza el mismo routing que el `planner` y el `tooling-investigator` publicados (ver `CLAUDE.md` "Routing cross-repo: solo drafts" y MEF-ADR-0019). Lee el slug del repo de Mefisto (configurable para forks):

```bash
HARNESS_REPO_SLUG=$(jq -r '.repoSlug // empty' .claude/harness.config.json 2>/dev/null)
[ -z "$HARNESS_REPO_SLUG" ] && HARNESS_REPO_SLUG="augusto-romero-arango/eda-evsourcing-azure-harness"
```

Crea un draft por cada ajuste aprobado (o uno agrupando ajustes al mismo agente), describiendo el gap y el cambio propuesto:

```bash
gh issue create -R "$HARNESS_REPO_SLUG" \
  --title "[verbo infinitivo] [que cosa]" \
  --label "estado:borrador,tipo:tooling" \
  --body "$(cat <<'DRAFTEOF'
## Idea
[Gap detectado + cambio propuesto en el agente/skill del harness]

## Origen
- Descubierto desde el consumidor [nombre o slug del repo del consumidor], review del PR #<numero>
- Agente/skill del harness afectado: <implementer | reviewer | test-writer | ...>
- Tipo de gap: regla faltante | regla ignorada | conocimiento dominio | limitacion framework
- Causa raiz: [por que el agente tomo la decision incorrecta]
- Field notes: [URL del field-note de la Fase 5.5]
DRAFTEOF
)"
```

**Importante** (igual que el resto del routing cross-repo):
- Solo `estado:borrador` y `tipo:tooling`. **No agregues** `dom:`, `estado:listo`, ni intentes refinar el draft. El refinamiento ocurre dentro del repo de Mefisto con `/mefisto-plan`.
- Captura el numero del draft creado: va en la columna "Ajuste aplicado" de la field note (5.5) como `Draft propuesto en harness #N`.
- Si `gh -R` falla con 403 (sin permisos), no insistas: indica al usuario que cree el draft manualmente desde la UI de GitHub con los datos recopilados.

> El #37 del repo de Mefisto es exactamente el resultado de aplicar este routing a mano cuando la Fase 5.4 todavia asumia edicion en-rama; sirve de ejemplo del comportamiento esperado.

#### Si el ajuste es local del consumidor: editar en-rama

Solo para lo que **realmente vive en el consumidor** (un ADR local del proyecto, una convencion de su `CLAUDE.md`, un fixture/helper). Edita con `Edit` y commitea en la **misma rama del PR**, en commit separado del de correcciones de codigo.

Antes de commitear, verifica que **no estas en `main`** (guard idempotente; en el flujo normal ya estas en la rama del PR por el `git checkout <headRefName>` de la Fase 1.1, asi que no dispara):

```bash
BRANCH=$(git symbolic-ref --short HEAD)
if [ "$BRANCH" = "main" ]; then
    git switch -c "docs/convenciones-pr-${ARGUMENTS}" 2>/dev/null \
        || git switch "docs/convenciones-pr-${ARGUMENTS}"
fi
BRANCH=$(git symbolic-ref --short HEAD)
if [ "$BRANCH" = "main" ]; then
    echo "ERROR: no se pudo cambiar de main. Aborta la Fase 5.4."
    exit 1
fi
```

```
docs(convenciones): ajustar [archivo local] a partir del review del PR #N

- [resumen del ajuste]

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
```

Push a la rama del PR. No pushees nunca directo a `main`: la politica del marco (ver `CLAUDE.md` raiz) exige entregar siempre via rama + PR.

### 5.5 Field note

Genera una field note en `docs/bitacora/field-notes/` **del consumidor** con el registro de las lecciones aprendidas. Nombre: `review-pr-<numero>.md`. La field note siempre vive en el consumidor, aunque el ajuste se haya enrutado como draft al harness — solo cambia el destino del "ajuste", no donde se documenta el review.

Estructura:

```markdown
# Field Note: Review del PR #<numero>

**Fecha**: <fecha>
**PR**: <url del PR>
**Issue**: #<numero del issue original>

## Comentarios del review

| # | Categoria  | Resumen                          |
|---|------------|----------------------------------|
| 1 | corregir   | ...                              |
| 2 | explicar   | ...                              |

## Correcciones aplicadas

[Resumen breve de los cambios de codigo hechos en Fase 3]

## Mejoras a agentes

| Agente       | Gap              | Destino     | Ajuste aplicado                       |
|--------------|------------------|-------------|---------------------------------------|
| implementer  | regla faltante   | harness     | Draft propuesto en harness #N         |
| test-writer  | limitacion fw    | harness     | Draft propuesto en harness #N         |
| (ADR local)  | conocimiento dom | consumidor  | Editado en-rama (commit abc1234)      |

## Lecciones

[1-3 bullet points con las lecciones clave para el proyecto]
```

---

## Reglas

- **Nunca publiques una respuesta sin aprobacion del usuario.** Los borradores siempre se presentan primero.
- **Nunca auto-resuelvas comentarios.** Eso lo decide el reviewer original, no nosotros.
- **Si un cambio planificado no es viable durante la ejecucion**, detente, informa al usuario, y ajusta el plan antes de continuar.
- **Agrupa cambios relacionados en un solo commit.** No hagas un commit por comentario.
- **Si el triaje revela que todos los comentarios ya estan resueltos**, salta directamente a la Fase 4 (responder).
- **Siempre verifica build + tests antes de hacer push.** Si fallan, no hagas push.
- **Las mejoras a agentes/skills del harness se enrutan como draft (`estado:borrador`) al repo de Mefisto via `gh -R`**, no se editan en la rama del PR del consumidor: esos archivos viven en el cache del plugin (read-only). Solo los ajustes a archivos que viven en el consumidor (ADR local, convenciones de su `CLAUDE.md`, fixtures propios) se editan en-rama, en commit separado y nunca directo a `main`.
- **La field note siempre se genera**, incluso si no hubo mejoras a agentes — el registro del review tiene valor historico.
- Comunica en espanol. Las respuestas a los comentarios del PR se redactan en el mismo idioma del comentario original.

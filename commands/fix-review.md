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
| 2 | tests/.../MiTest.cs:15     | explicar    | El patron es correcto segun ADR-0005  |
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

Respuesta: "El patron es correcto segun ADR-0005 porque..."
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
- **Agente/skill afectado**: .claude/agents/implementer.md (o skill, o script)
- **Seccion**: [nombre de la seccion donde iria el cambio]
- **Tipo de gap**: regla faltante | regla ignorada | conocimiento dominio | limitacion framework
- **Causa raiz**: [por que el agente tomo la decision incorrecta]
- **Cambio propuesto**: [descripcion del ajuste — nueva regla, ejemplo, reformulacion]

### Ajuste 2: ...
```

Si el PR no tuvo correcciones que ameriten mejoras (todos los comentarios eran "explicar" o "resuelto"), indica que no hay ajustes necesarios y salta a la field note.

### 5.3 Presentar plan de mejora al usuario

Muestra las propuestas. **Espera aprobacion explicita.** El usuario puede:
- Aprobar todas
- Descartar algunas
- Reformular la redaccion de una regla
- Agregar contexto que enriquezca la mejora

### 5.4 Aplicar ajustes aprobados

Edita los archivos de agentes/skills con los cambios aprobados. Usa `Edit` para modificar archivos existentes.

Antes de commitear, verifica que **no estas en `main`**. Si lo estuvieras (caso excepcional), crea una rama dedicada antes de cualquier cambio:

```bash
BRANCH=$(git symbolic-ref --short HEAD)
if [ "$BRANCH" = "main" ]; then
    # Idempotente: si la rama ya existe (re-ejecucion del fix-review),
    # hace switch a ella; si no, la crea.
    git switch -c "docs/agentes-mejoras-pr-${ARGUMENTS}" 2>/dev/null \
        || git switch "docs/agentes-mejoras-pr-${ARGUMENTS}"
fi

# Re-verifica antes de commitear. Si por algun motivo seguis en main,
# aborta para no pushear directo.
BRANCH=$(git symbolic-ref --short HEAD)
if [ "$BRANCH" = "main" ]; then
    echo "ERROR: no se pudo cambiar de main. Aborta la Fase 5.4."
    exit 1
fi
```

En el flujo normal de fix-review ya estas en la rama del PR (Fase 1.1 hace `git checkout <headRefName>`), asi que el bloque anterior simplemente no dispara.

Commit separado del de correcciones de codigo, en la **misma rama del PR**:

```
docs(agentes): mejorar instrucciones a partir de review del PR #N

- [resumen de ajustes por agente]

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
```

Push a la rama del PR (la misma a la que pusheaste las correcciones en la Fase 3.3). No pushees nunca directo a `main`: la politica del marco (ver `CLAUDE.md` raiz) exige entregar siempre via rama + PR.

Si el usuario pidio explicitamente partir las mejoras en un PR separado, crea una rama nueva con `git switch -c docs/agentes-mejoras-pr-<numero>`, commitea ahi y abre un segundo PR con `gh pr create --base main`. Por defecto, todo va en la rama del PR original.

### 5.5 Field note

Genera una field note en `docs/bitacora/field-notes/` con el registro de las lecciones aprendidas. Nombre: `review-pr-<numero>.md`.

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

| Agente       | Gap              | Ajuste aplicado                  |
|--------------|------------------|----------------------------------|
| implementer  | regla faltante   | Agregar regla sobre StreamId...  |
| test-writer  | limitacion fw    | Documentar overload de Then()... |

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
- **Las mejoras a agentes van en commit separado en la misma rama del PR.** Nunca se pushean directo a `main`; si el usuario quiere partirlas en otro PR, crea rama nueva y abre un segundo PR contra `main`.
- **La field note siempre se genera**, incluso si no hubo mejoras a agentes — el registro del review tiene valor historico.
- Comunica en espanol. Las respuestas a los comentarios del PR se redactan en el mismo idioma del comentario original.

---
{
  "kind": "command",
  "id": "fix-review",
  "description": "Resuelve los comentarios de revision de un PR del consumidor: triaje, plan, ejecucion, respuestas y mejora continua.",
  "profile": "deep",
  "arguments": "<numero-de-PR> [--prepare | --apply-approved <plan-id-sha256>]"
}
---

Resuelve los comentarios de revision de un pull request. Comunicate en **espanol**.

**Alcance**: este comando solo resuelve PRs del proyecto consumidor.

{{mefisto:assert-consumer-repo}}

## Entrada

El numero de PR esta en: $ARGUMENTS

Si `$ARGUMENTS` esta vacio, responde: `Uso: {{mefisto:command fix-review}} <numero-de-PR> [--prepare | --apply-approved <plan-id-sha256>]`

### Formas de `$ARGUMENTS` (cerradas)

Solo se aceptan tres formas. Valida `$ARGUMENTS` **antes** de ejecutar `gh` o editar nada:

| Forma | Modo |
|---|---|
| `<PR>` | **Interactivo**: el flujo de las Fases 1 a 5 de abajo, con sus gates humanos. Es el unico modo sin perfil ni consentimiento previo. |
| `<PR> --prepare` | **Preparar**: triaje y plan exactos con el usuario **fuera de lote** (ver "Modo preparar"). |
| `<PR> --apply-approved <plan-id-sha256>` | **Aprobado**: consume exclusivamente un plan ya aprobado (ver "Modo aprobado"). |

`<PR>` es un entero positivo y `<plan-id-sha256>` son 64 caracteres hex en minuscula. Cualquier otro argumento, flag desconocido, flags mezclados o SHA malformado se rechaza con el mensaje de uso, sin tocar `gh` ni archivos. Que exista un perfil `autonomy` no activa el modo aprobado: solo lo activa `--apply-approved`. Las Fases 1 a 5 describen el modo interactivo; los modos `--prepare` y `--apply-approved` solo siguen sus secciones propias.

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

Para cada comentario, lee el archivo y las lineas referenciadas. Lee los archivos directamente con la herramienta de lectura de tu runtime, sin pasar por el shell.

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

### 2.1 Redactar el plan

Redacta el plan completo **en el chat**, sin editar ningun archivo todavia. El gate es el mismo en cualquier runtime y no depende de una herramienta de plan nativa.

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

### 2.3 Gate de aprobacion

Presenta el plan completo y detente. Exige aprobacion explicita del usuario antes de editar cualquier archivo.

**No avances a la Fase 3 sin aprobacion del plan.**

---

## Fase 3: Ejecutar

### 3.1 Aplicar cambios de codigo

Ejecuta los cambios del plan en el orden definido. Modifica los archivos existentes con la herramienta de edicion y crea archivos nuevos solo cuando el plan lo indique.

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
```

No escribas una linea de atribucion a mano: sigue la convencion de atribucion de tu runtime o del usuario.

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

> **Harness read-only.** Los agentes y skills del marco no viven en el repo consumidor: estan en la release instalada del plugin `mefisto`, read-only y versionada, en `{{mefisto:package-root}}/agents/`. Por eso una mejora a un artefacto del harness **no se puede editar en la rama del PR del consumidor**: se enruta como **draft** (`estado:borrador`) al repo de Mefisto via `gh -R`, igual que hacen el `planner` y el `tooling-investigator` publicados (ver la seccion C "Routing cross-repo: solo drafts" de MEF-ADR-0019, `{{mefisto:package-root}}/docs/adr/mef-adr-0019-*.md`). La edicion en-rama queda reservada a lo que realmente vive en el consumidor (un ADR local del proyecto, convenciones de su `AGENTS.md`, un fixture/helper propio).

### 5.1 Trazar correcciones a su origen

Lee el body del PR — el pipeline TDD registra decisiones de cada agente (test-writer, implementer, reviewer) en secciones `<details>`. Para cada comentario clasificado como "corregir", lee la definicion del agente del harness que produjo el codigo en `{{mefisto:package-root}}/agents/<id>.md` y responde:

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
- **Agente/skill afectado**: `implementer` (o `reviewer`, `test-writer`, skill, pipeline). Si es del harness, lee su definicion en `{{mefisto:package-root}}/agents/<id>.md`; no vive en el consumidor.
- **Destino del ajuste**: draft en el harness | edicion local en el consumidor
- **Seccion**: [nombre de la seccion donde iria el cambio]
- **Tipo de gap**: regla faltante | regla ignorada | conocimiento dominio | limitacion framework
- **Causa raiz**: [por que el agente tomo la decision incorrecta]
- **Cambio propuesto**: [descripcion del ajuste — nueva regla, ejemplo, reformulacion]

### Ajuste 2: ...
```

El **destino** se decide por donde vive el archivo a tocar: un agente/skill/pipeline/hook del harness va como **draft a Mefisto** (no es editable desde el consumidor); un ADR local o una convencion del `AGENTS.md` del consumidor se **edita en-rama**. La Fase 5.4 detalla cada caso.

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
| **Harness** (`mefisto`) | Release instalada del plugin (`{{mefisto:package-root}}/`), read-only y versionada | **Crear un draft** (`estado:borrador`) en el repo de Mefisto via `gh -R` |
| **Consumidor** (este repo) | ADR local del proyecto (`docs/adr/`), convencion de su `AGENTS.md`, fixture/helper propio | **Editar en-rama**, commit en la rama del PR |

#### Si el ajuste es al harness: crear un draft cross-repo

Reutiliza el mismo routing que el `planner` y el `tooling-investigator` publicados (ver la seccion C "Routing cross-repo: solo drafts" de MEF-ADR-0019, `{{mefisto:package-root}}/docs/adr/mef-adr-0019-*.md`). Lee el slug del repo de Mefisto (configurable para forks):

Lee `repoSlug` desde `{{mefisto:config-path}}` (MEF-ADR-0053 decision 4). El campo es opcional: si el config no lo declara o esta vacio, aplica el default sin abortar:

```bash
SLUG=$(jq -r '.repoSlug // empty' "{{mefisto:config-path}}" 2>/dev/null); echo "${SLUG:-augusto-romero-arango/eda-evsourcing-azure-harness}"
```

Cada bloque `bash` corre en un shell nuevo: en el `gh issue create -R "<slug>"` de mas abajo, sustituye `<slug>` por el slug que imprimio este bloque.

Crea un draft por cada ajuste aprobado (o uno agrupando ajustes al mismo agente), describiendo el gap y el cambio propuesto:

```bash
gh issue create -R "<slug>" \
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

Solo para lo que **realmente vive en el consumidor** (un ADR local del proyecto, una convencion de su `AGENTS.md`, un fixture/helper). Edita y commitea en la **misma rama del PR**, en commit separado del de correcciones de codigo.

Antes de commitear, verifica que **no estas en `main`** (guard idempotente; en el flujo normal ya estas en la rama del PR por el `git checkout <headRefName>` de la Fase 1.1, asi que no dispara):

```bash
git symbolic-ref --short HEAD
```

Si imprime `main`, cambia a una rama de docs y vuelve a verificar:

```bash
git switch -c "docs/convenciones-pr-<numero-de-PR>" 2>/dev/null || git switch "docs/convenciones-pr-<numero-de-PR>"
git symbolic-ref --short HEAD
```

Si tras eso la rama sigue siendo `main`, aborta la Fase 5.4: no estas en la rama del PR.

```
docs(convenciones): ajustar [archivo local] a partir del review del PR #N

- [resumen del ajuste]
```

Push a la rama del PR. No pushees nunca directo a `main`: la politica del marco (ver el archivo efectivo de instrucciones: `AGENTS.md`) exige entregar siempre via rama + PR.

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

## Modo preparar (`<PR> --prepare`)

Prepara triaje y plan para que el operador los apruebe **fuera de este stage**. No aprueba nada ni modifica el perfil.

1. Lee `gh pr view <PR> --json title,body,state,headRefName,headRefOid,baseRefName,url` y **todas las paginas** de los review comments (`gh api --paginate repos/{owner}/{repo}/pulls/<PR>/comments`). Si el PR no existe o esta cerrado, informa y detente.
2. Exige un worktree limpio (`git status --porcelain` vacio) cuyo `HEAD` coincida con `headRefOid`. Si no, informa y detente. **No** hagas `git checkout`, edicion, commit, push, respuesta ni draft.
3. Lee el codigo referenciado y clasifica cada comentario como en 1.3.
4. Redacta el plan JSON del contrato de `{{mefisto:package-root}}/src/published/contract/fix-review-plan.example.json` (cada `commentId`, categoria, archivos, cambio, acciones secundarias y cupos; `triage.edits` lista exactamente los cambios de comentarios `corregir`) y su Markdown equivalente. Escribe ambos bajo `.mefisto/pipeline/summaries/` (ignorado por git; el helper rechaza otra ubicacion).
5. Registra el snapshot:

```bash
{{mefisto:run fix-review-prepare.sh --project-root <raiz-del-worktree> --pr <PR> --plan-file <plan.json> --plan-text <plan.md>}}
```

6. Muestra triaje, plan Markdown exacto, `planDigest` y `requiredGrants`, y termina con las acciones para el operador: versionar los grants en `{{mefisto:config-path}}` mediante un PR previo del consumidor y ejecutar `autonomy-profile.sh preview` y `approve` de forma explicita. **No invoques `approve`** ni edites el perfil. Si cambia el triaje o el plan, se prepara otro id y requiere nueva aprobacion. No esperes respuesta dentro del stage.

---

## Modo aprobado (`<PR> --apply-approved <plan-id-sha256>`)

Sin preguntas dentro del stage: no hay gates humanos ni fallback al modo interactivo. La politica es cooperativa (no aisla el host): cada fase se verifica con evidencia y se aborta si el plan deja de corresponder. No leas tool calls de otra sesion como permiso.

Consulta antes de cada fase (la salida es JSON con `status` `authorized`, `blocked` o `incomplete`; solo `authorized` permite continuar):

```bash
{{mefisto:run fix-review-admission.sh check --project-root <raiz-del-worktree> --pr <PR> --plan-id <plan-id> --phase pre-edit}}
```

Las demas fases usan el mismo comando con `--phase pre-push`, `--phase pre-reply --comment-id <id>`, `--phase pre-improvement --action <categoria>` y `--phase finish`.

1. **pre-edit**: ejecuta el check `pre-edit`. Exige `planMarkdown` con digest verificado, inspect `ready` y grants exactos para correcciones y para las acciones opcionales del plan. Si el plan selecciona respuestas y falta el grant `fix-review-reply`, bloquea **antes de editar**.
2. **Cambios de codigo**: solo los comentarios `corregir` listados en `triage.edits`, en los archivos y con el cambio del plan. Un archivo nuevo fuera de ese conjunto requiere un plan nuevo. Cotejar el diff con el plan: si no puedes justificar un cambio semantico, no lo publiques.
3. **Verificar**: `dotnet build` y `dotnet test` antes del commit. Si fallan, no hagas push.
4. **pre-push**: ejecuta el check `pre-push`; commit en el idioma de las convenciones del repo, push a la rama del PR (nunca a `main`) y registra el recibo antes de seguir:

```bash
printf '%s' '<json-de-la-transicion>' | {{mefisto:run fix-review-receipts.sh record-push --project-root <raiz-del-worktree> --plan-id <plan-id>}}
```

   El JSON de la transicion lleva `schemaVersion: 1`, `runId`, `phase` (`corrections` o `improvements`), `from` (head inicial o ultimo recibido), `to` (el SHA empujado) y `verification` (`[{command,exitCode}]` de build/test); nunca bodies ni secretos. El SHA propio del push, registrado por recibo, no invalida la aprobacion; un SHA nuevo ajeno si.
5. **Respuestas**: si el plan declara `replyPolicy: freeform-factual` y el grant vigente, ejecuta el check `pre-reply` por comentario, redacta segun los hechos reales y la categoria (en el idioma del comentario) y publica **una sola respuesta por `commentId` aprobado**, sin confirmacion humana. Registra cada una con `record-reply` (JSON con `schemaVersion`, `runId` y `replyId`). La libertad es textual: no alegues tests, commits ni issues que no ocurrieron, no incluyas secretos y no respondas a comentarios nuevos. Si el plan declara `replyPolicy: none`, no publiques y reporta la salida parcial pactada.
6. **Mejoras**: con grants y cupos vigentes y el check `pre-improvement`, puedes crear un issue de seguimiento en el consumidor (comentario `investigar` o gap nuevo de este PR; `record-consumer-issue`), un draft **solo** en el repo de Mefisto para un gap del harness (como en 5.4; `record-harness-draft`) o editar clases locales `consumer-adr`, `consumer-directives` o `consumer-test-helper` segun el perfil, en la misma rama y en un commit separado. Esta prohibido editar la release o los agentes del harness, `src` productivo no planeado, infra, workflows, config o consentimiento, crear otro tipo de issue o cerrar/refinar issues de Mefisto. Sin grant o cupo, o fuera de clase, anota el ajuste en la field note como **pendiente** sin ejecutarlo.
7. **Field note**: se genera siempre como en 5.5; incluye lo pendiente.
8. **finish**: ejecuta el check `finish` y reporta el resultado.

**Detencion**: una revision o comentario nuevo o editado por un tercero, PR cerrado, permiso remoto ausente, plan desviado, error de un helper, `blocked`/`incomplete` o recibo incierto (`unknown`) -> detente **sin preguntar**, reporta el progreso y la accion para re-preparar o reautorizar fuera del lote, y no repitas a ciegas una salida remota con recibo incierto. Si una salida remota falla o su recibo queda `unknown`, confirma con evidencia **una sola vez** y repite solo el registro, nunca el POST. Nunca amplies categorias, archivos ni cupos y nunca resuelvas threads.

---

## Reglas

- **Nunca publiques una respuesta sin aprobacion del usuario.** Los borradores siempre se presentan primero.
- **Nunca auto-resuelvas comentarios.** Eso lo decide el reviewer original, no nosotros.
- **Si un cambio planificado no es viable durante la ejecucion**, detente, informa al usuario, y ajusta el plan antes de continuar.
- **Agrupa cambios relacionados en un solo commit.** No hagas un commit por comentario.
- **Si el triaje revela que todos los comentarios ya estan resueltos**, salta directamente a la Fase 4 (responder).
- **Siempre verifica build + tests antes de hacer push.** Si fallan, no hagas push.
- **Las mejoras a agentes/skills del harness se enrutan como draft (`estado:borrador`) al repo de Mefisto via `gh -R`**, no se editan en la rama del PR del consumidor: esos archivos viven en la release instalada del plugin (read-only). Solo los ajustes a archivos que viven en el consumidor (ADR local, convenciones de su `AGENTS.md`, fixtures propios) se editan en-rama, en commit separado y nunca directo a `main`.
- **La field note siempre se genera**, incluso si no hubo mejoras a agentes — el registro del review tiene valor historico.
- Comunica en espanol. Las respuestas a los comentarios del PR se redactan en el mismo idioma del comentario original.
- **Los modos `--prepare` y `--apply-approved` no publican nada que el plan aprobado no liste** y nunca preguntan dentro del stage; el modo interactivo conserva todas las reglas anteriores.

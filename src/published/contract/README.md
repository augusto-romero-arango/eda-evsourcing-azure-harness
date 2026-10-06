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
scripts/autonomy-profile.sh propose-max --project-root /ruta/al/consumidor
```

`propose-max` escribe en `.mefisto/harness.config.json` el perfil máximo de la
release (`id: maximo`, `commands` con todo el catálogo publicado ordenado y
`administration` preservada, o vacía si no existía) sin tocar el resto del
archivo. Es idempotente: si el bloque no cambia reporta `changed: false`; si
cambia incrementa `revision`. Imprime `configPath`, `changed`, `revision` y el
`profileDigest` que `preview` calcularía, para encadenar `approve
--expected-digest`. No aprueba nada ni escribe el registro de consentimiento, y
sin configuración canónica falla con código 2 sin migrar ni crear archivos
(MEF-ADR-0055 §1-3).

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
Un caller distingue `disabled` con `NO_PROFILE`, que conserva el flujo legacy,
de `disabled` con `CONSENT_REVOKED`; este último, así como un contexto controlado
inválido, no habilita fallback de una corrida automática (MEF-ADR-0055).
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

### Admisión previa de autonomía (preflight)

`scripts/autonomy-preflight.sh --project-root <raíz-Git> --runtime <id> [--context <ruta>]`
lee por stdin un único plan JSON `schemaVersion:1` (`launchKind: sequential|parallel|pane`,
`source: command|direct|pipeline`, `issues:[{number,pipelineKind}]`, `requestedOperations:[]` cerrado en
este corte) y responde un único JSON `admissionScope: pre-dispatch` con `status`
`ready-to-dispatch|legacy|blocked|incomplete`, `projectId`, `profileDigest`, `release`,
`planDigest`, `resourcesDigest` (o null), `checks:[{code,state,owner,actionCode}]` y
`diagnostics` sanitizados. Exit 0 para `ready-to-dispatch`/`legacy`, 1 para
`blocked`/`incomplete`, 2 para protocolo o uso.

Es solo lectura: consulta `autonomy-profile.sh inspect` y `execution-context.sh validate`,
verifica clausura de scripts y binarios con consultas sin efectos y nunca ejecuta `prepare`,
`approve`, `project`, `install` ni `restore`, ni escribe logs, config, consentimiento,
contexto o worktrees. `source:command` exige `--context` (debe vivir en la ruta canónica del
run del mismo proyecto) con `entryAdmission` ya ligada a la sesión iniciadora; `source:direct`
no admite contexto y marca la entrada `not-applicable`; `source:pipeline` es el contexto hijo reservado por un orquestador (exige `--context` con `parentContextId` y `rootCommand`/`allowedPipelines`/`allowedRoles` que cubran el plan; nunca lleva `entryAdmission` propia: el padre del mismo run debe listarlo en `state.children` con su `contractDigest` y compartir su `source`, si no `PARENT_CONTEXT_MISMATCH`; se verifica la `entryAdmission` del padre si este vino de un comando, si no la entrada es `not-applicable`). Sin perfil y sin contexto, o con
Claude sin contexto, el resultado es `legacy`; consentimiento revocado, sin aprobar o contexto
de otro runtime bloquean sin fallback.

`ready-to-dispatch` **no** certifica la sesión futura, permisos remotos ni la finalización de
una tarea: lo que solo puede probarse después (worktree, actor/modelo/permisos de la etapa,
fuentes condicionales por rol de la matriz #1822) queda `deferred` con owner
`run-published-agent.sh/#1858`, y la red/credenciales externas se declaran `remote-unverified`.
Una fuente condicional sin alternativa disponible ahora jamás es `pass`. El cableado en los
orquestadores (#1826) es un issue aparte; `onboard-diagnose.sh` conserva su contrato
informativo independiente.

```bash
scripts/tests/test-autonomy-preflight.sh
```

### Plan preautorizado de fix-review

`fix-review-plan.validate.jq` (issue #1886) es el contrato puro del plan
revisable de `/fix-review` y de su huella; no consulta GitHub, no aprueba
perfiles, no publica respuestas ni cambia el comando. Recibe por stdin
`{"plan": <plan>, "grants": null|[<grant>], "context": {"projectId": <kebab>}}`
y responde `{schemaVersion,status,reasonCode,canonical,requiredActions,authorization}`:
`status` es `valid`/`invalid` con `reasonCode` estable (`PLAN_VALID`,
`INVALID_*`, `PROJECT_MISMATCH`, `FORK_NOT_SUPPORTED`, `DUPLICATE_COMMENT_ID`,
`TRIAGE_SNAPSHOT_MISMATCH`, `SENSITIVE_CONTENT`); un plan malformado nunca se normaliza.
El ejemplo sintetico versionado es `fix-review-plan.example.json`.

El plan es JSON `schemaVersion: 1` de claves cerradas: `projectId` (el de `inspect`),
`repoSlug`, `prNumber`, `baseRef`, `headRefName`, `headRepository` (igual a `repoSlug`
en este corte; un fork se rechaza), `expectedHeadSha` (40 hex), `commentSnapshot`
(`{id,bodyDigest,path,line,originalLine,inReplyToId}`, sin body), `triage` uno a uno
por `commentId` con `category` `corregir|explicar|resuelto|investigar` (solo `corregir`
lleva `edits:[{path,change,impact}]`, rutas relativas seguras y nunca workflows, config,
adaptadores o infra), `verification` (`["dotnet build","dotnet test"]` si hay
correcciones, `[]` si no), `planTextDigest` (SHA-256 del plan Markdown mostrado al
operador), `secondary` (`replyPolicy`, `consumerIssues`, `harnessDrafts`,
`localImprovementClasses` entre `consumer-adr|consumer-directives|consumer-test-helper`),
`limits` (`drafts`, `consumerIssues`, `localFiles`: cero si la clase no se habilita,
positivo si se habilita) y `planDigest`. Los secundarios dan discrecion sobre el texto de
respuestas y mejoras nuevas solo dentro de esas clases y cupos; no amplian `triage.edits`.

`canonical` es el JSON con claves ordenadas, sin `planDigest`, con `commentSnapshot` y
`triage` ordenados por id y `localImprovementClasses` ordenadas. El caller calcula
`planDigest` como SHA-256 de esos bytes UTF-8 sin salto final:

```bash
jq -c -f src/published/contract/fix-review-plan.validate.jq envelope.json | jq -j .canonical | shasum -a 256
```

`planDigest` no incluye hora, modelo, token, bodies ni URLs de auth, y no es firma de
identidad humana ni sandbox: `planTextDigest` solo vincula el texto mostrado.

Con `grants` no nulo, `authorization` es `{status: authorized|unauthorized, missing}`.
Cada accion requerida (`fix-review-correct`, `-reply`, `-consumer-issue`,
`-harness-draft`, `-local-improvement`, derivadas de triage/secondary; nunca un
`fix-review-all`) exige un grant con `command: fix-review`, `environment: repository`,
`planDigest` igual al del plan (obligatorio aqui aunque el validador general lo admita
opcional) y recursos `pr:<n>` mas su scope (`scope:planned-files`,
`scope:review-comments`, `scope:consumer-issue`, `scope:harness-draft`,
`scope:consumer-docs`). No cambia el schema de `autonomy-profile.validate.jq` ni confiere
RBAC de GitHub. Prueba: `src/published/scripts/tests/test-fix-review-plan-contract.sh`.

### Preparación del snapshot revisable de fix-review

`scripts/fix-review-prepare.sh` (issue #1887) captura lecturas verificables de GitHub y
deja un plan sellado para revisión humana; no aprueba, no ejecuta `/fix-review` y no
hace checkout ni escrituras en GitHub:

```bash
scripts/fix-review-prepare.sh --project-root <Git-root> --pr <n> \
  --plan-file .mefisto/pipeline/summaries/plan.json --plan-text .mefisto/pipeline/summaries/plan.md
```

- Exige el PR abierto del repositorio consumidor activo, con cabeza en el mismo repo (un fork
  ajeno solo da diagnóstico), un worktree propio en la rama del PR, con `HEAD == headRefOid` y
  sin cambios versionados. Si falta, el operador prepara el worktree; el script nunca lo crea.
- Lee `gh pr view` y los review comments con `--paginate` (no `/issues/{n}/comments`), repite
  cabeza y comentarios antes de sellar y compara el snapshot del plan (hash de body, path,
  line/original_line) tras ordenar por id; cualquier omisión, agregado o edición es `conflict`.
- `--plan-file` y `--plan-text` deben estar bajo `.mefisto/pipeline/summaries/`; el Markdown con
  material sensible se rechaza hasta que esté redactado. El script calcula `planTextDigest` y
  `planDigest` con `fix-review-plan.validate.jq` y rechaza digests declarados que no coincidan.
- Persiste (0700/0600, sin symlinks, atómico, idempotente) el plan sellado en
  `.mefisto/pipeline/autonomy/fix-review/<planDigest>.json` y la copia redactada del Markdown en
  `.mefisto/pipeline/summaries/fix-review/<planDigest>.md` (su SHA-256 es `planTextDigest`); ambos
  ignorados por Git.
- Responde `{schemaVersion,status:prepared|conflict,pr,expectedHeadSha,planDigest,
  commentSnapshotDigest,planPath,requiredGrants,diagnostics}` sin bodies.

Handoff del operador (el hash no es consentimiento): revisar el Markdown, incorporar los
`requiredGrants` exactos a `autonomy.administration[]` con `planDigest` mediante un PR del
consumidor y, fuera de la etapa del lote, ejecutar `autonomy-profile.sh preview` y `approve`.
Prueba: `src/published/scripts/tests/test-fix-review-prepare.sh`.

### Recibos de pushes y respuestas de fix-review

`scripts/fix-review-receipts.sh` (issue #1888) registra **solo** las transiciones que la corrida
aprobada ya ejecuto; no hace push, no publica respuestas, no aprueba ni repara config y no es un
bypass de revision. Un agente o el comando final lo invocan despues de cada accion remota:

```bash
printf '%s' "$REQUEST_JSON" | scripts/fix-review-receipts.sh \
  <record-push|record-reply|record-consumer-issue|record-harness-draft> \
  --project-root <approved-root> --plan-id <planDigest> [--reference <id>]
scripts/fix-review-receipts.sh status --project-root <approved-root> --plan-id <planDigest>
```

- Request JSON `schemaVersion: 1` de claves cerradas, sin bodies: `runId` mas `phase`
  (`corrections|improvements`), `from`, `to`, `improvementClass?`, `verification?`
  (`[{command,exitCode}]`) para `record-push`; `replyId` para `record-reply`; `origin`
  (`comment:<id>|improvement:<id-local>`), `issueNumber`, `repo` para issues/drafts.
  `--reference` es opcional y debe coincidir con `to`/`replyId`/`issueNumber`.
- La accion nunca viene del request: se deriva de la operacion y se compara con el plan sellado
  (#1887) y los grants exactos de `autonomy-profile.sh inspect` (#1886); consentimiento no `ready`,
  perfil cambiado o `runId` distinto del fijado en la primera transicion es `conflict`.
- `record-push`: `from` = head inicial o ultimo recibido, `to` = HEAD local = `headRefOid`, misma
  rama/repo, descendencia sin merges ni symlinks. `corrections` solo toca rutas de los edits
  exactos del triaje y exige las verificaciones declaradas; `improvements` solo rutas de la clase
  aprobada y dentro de `limits.localFiles`. Una ruta permitida no prueba semantica: en duda, falla.
- `record-reply`: GET del review comment nuevo (autor = identidad de la corrida, PR esperado,
  `in_reply_to_id` entre los comentarios del plan); una respuesta por padre; no abre destinatarios
  ni resuelve threads.
- `record-consumer-issue`: solo `comment:<id>` con categoria `investigar` o `improvement:<id>` con
  `consumerIssues` aprobado, repo consumidor, dentro del cupo y con referencia al PR en el issue.
  `record-harness-draft`: solo repo Mefisto (`repoSlug` del config o el default), labels
  `estado:borrador` + `tipo:tooling`, cupo `limits.drafts`.
- Libro `.mefisto/pipeline/autonomy/fix-review/<planDigest>.receipts.json` (0600, sin symlinks,
  `mkdir`-lock + temp/rename + CAS por `revision`): `headTransitions`, `replies` (`replyId`,
  `parentId`) e `issues` (tipo, repo, numero, origen, PR). Nunca bodies, comandos, texto del plan ni
  secretos.
- Respuesta `{schemaVersion,status:recorded|conflict|unknown|ok|none,operation,planDigest,runId,
  code,recovery,revision}`; salida de proceso 0 recorded/ok/none, 1 conflict, 2 uso/entorno,
  3 unknown. Codigos `conflict` estables: `ACTION_NOT_GRANTED`, `CONSENT_NOT_READY`,
  `RUN_ID_MISMATCH`, `PROFILE_DIGEST_MISMATCH`, `HEAD_CHAIN_BROKEN`, `REMOTE_HEAD_MISMATCH`,
  `PATH_NOT_PLANNED`, `PATH_NOT_IN_CLASS`, `CLASS_NOT_APPROVED`, `LOCAL_FILES_QUOTA_EXCEEDED`,
  `VERIFICATION_NOT_DECLARED`, `DUPLICATE_REPLY`, `REPLY_PARENT_NOT_APPROVED`,
  `REPLY_AUTHOR_MISMATCH`, `ORIGIN_NOT_INVESTIGAR`, `QUOTA_EXCEEDED`, `DRAFT_LABELS_INVALID`,
  `RECEIPTS_INSECURE`, `STATE_SYMLINK`, `RECEIPTS_CAS_FAILED`, `LOCK_HELD`.
- Recuperacion: una API que falla (`unknown`, `REPLY_UNCONFIRMED`/`ISSUE_UNCONFIRMED`) no registra
  nada y no autoriza repetir el POST: confirma con evidencia **una sola vez** y repite el registro.
  Ausencia de recibo tras una operacion remota no es consentimiento: `status` solo diagnostica.
  `LOCK_HELD` persistente: verifica que no haya otro escritor y elimina el directorio `.lock`.

Es un libro de contabilidad local, no un sandbox: un proceso con permisos de shell del mismo
usuario puede editar el libro. Prueba: `src/published/scripts/tests/test-fix-review-receipts.sh`.

### Gate de admision de fix-review

`scripts/fix-review-admission.sh` (issue #1889) es el gate de **consulta** que cada etapa de la
corrida preautorizada de `/fix-review` consulta antes de actuar. No publica, no edita, no muta el
contexto, no invoca `approve`/`revoke` ni modifica `fix-review.md` (la entrada ejecutable se cablea
en #1821). Una llamada interactiva sin `--plan-id` no usa este guard y conserva los gates actuales:
ningun estado `authorized` sale de defaults, `--yes` ni del texto del issue.

```bash
scripts/fix-review-admission.sh check --project-root <approved-root> --pr <N> --plan-id <planDigest> \
  --phase <pre-edit|pre-push|pre-reply|pre-improvement|finish> [--comment-id <id>] [--action <categoria>]
```

- Salida `{schemaVersion:1,status:authorized|blocked|incomplete,phase,projectId,planDigest,
  currentHead,allowedActions,diagnostics:[{code,actionCode}]}`; proceso 0 authorized, 1
  blocked/incomplete, 2 protocolo. Nunca imprime bodies, Markdown del plan, texto de respuestas,
  tokens ni settings; `gh` usa su propia custodia (el guard no lee credenciales).
- Valida siempre: `autonomy-profile.sh inspect` en `ready`/`CONSENT_APPROVED` con el `projectId` del
  plan; plan sellado (#1887) con digest recomputado (#1886); copia Markdown con SHA-256 ==
  `planTextDigest` (ausente o alterada: `incomplete`); grant exacto por accion (`command:
  fix-review`, `environment: repository`, resources `pr:N` + clase, `planDigest` presente e igual).
- Estado remoto solo lectura: PR abierto del repo/rama del plan; `headRefOid` debe ser el head
  inicial o el ultimo de la cadena de recibos (#1888), que debe encadenarse sin huecos desde el head
  sellado (`HEAD_CHAIN_BROKEN`); todas las paginas de review comments contra
  el snapshot (id/bodyDigest/path/line/originalLine/replies) mas las respuestas con recibo; cambios
  de `line` se toleran solo tras pushes propios. Edicion, comentario nuevo, respuesta sin recibo,
  cabeza ajena, PR cerrado o mas de 30 comentarios ajenos (las respuestas propias con recibo no
  cuentan): `blocked`; API ausente o ambigua: `incomplete`
  (sin reintento ciego de POST ni reparacion; el comentario nuevo no entra al plan).
- Fases: `pre-edit` (triaje exacto, worktree limpio en la rama y cabeza vigente; sin comentarios
  `corregir` no exige grant de edicion), `pre-push` (diff local acotado a los paths planeados o a la
  clase `--action <clase>`; la verificacion build/test declarada la exige `record-push`), `pre-reply`
  (solo ids del snapshot, una respuesta por id, texto factual libre, sin resolver threads),
  `pre-improvement` (`--action` = clase local aprobada, `fix-review-consumer-issue` o
  `fix-review-harness-draft`, dentro de cupos; cualquier otra accion es `ACTION_OUT_OF_SCOPE`),
  `finish` (cotejo con recibos: codigo/respuestas/seguimientos pendientes salen como `PARTIAL_*`
  en `incomplete`, nunca como completitud).
- Un path permitido no acredita la semantica del cambio: ante desvio del plan, el agente se detiene
  y pide una nueva preparacion fuera del lote. La politica es cooperativa, no un sandbox frente al
  proceso o usuario anfitrion, y no representa permisos remotos de GitHub.

Prueba: `src/published/scripts/tests/test-fix-review-admission.sh`.

### Cableado de los modos preautorizados en `/fix-review`

`src/published/commands/fix-review.md` (issue #1821) acepta solo tres formas: `<PR>` (modo
interactivo vigente, sin perfil), `<PR> --prepare` (triaje y plan fuera de lote; invoca
`fix-review-prepare.sh` y entrega el handoff al operador, sin `approve`) y
`<PR> --apply-approved <planDigest>` (consume el plan sellado: `fix-review-admission.sh` antes de
cada fase y `fix-review-receipts.sh` tras cada salida remota; se detiene sin preguntar ante
`blocked`/`incomplete`/`unknown`). Son las unicas tres referencias `{{mefisto:run ...}}` nuevas y
por eso los unicos scripts sumados al mapping de OpenCode; `autonomy-profile.sh` sigue sin patron.
Prueba: `src/published/scripts/tests/test-fix-review-command.sh`.

## Permisos Bash de OpenCode

La capacidad neutral `shell` genera `permission.bash` con `"*": "deny"`.
Solo se amplía para comandos que una doctrina publicada ejecuta, no para
comandos que meramente menciona. La política vigente permite `git`, `gh`,
`jq`, `cat`, `ls`, `find`, `grep`, `sort`, los scripts distribuidos, `mkdir` y
`mktemp`; el toolchain TDD añade `dotnet`, `func init`, las formas locales
enumeradas de `terraform init -backend=false`, `validate` y `fmt`, `python3 -`
(incluido `-m json.tool`), `cd`, `echo`, `test`, `touch`, `tr`, `cut`, `head`,
`tail`, `awk`, `sed`, `mv` e `ilspycmd`. Las cuatro últimas utilidades de texto previas a `mv` cubren
subcomandos reales de tuberías y sustituciones de comando de esa doctrina.
`terraform plan`/`apply`, `func start` y `az` continúan denegados por el
default (MEF-ADR-0049 y MEF-ADR-0053). El agente `planner` (issue #1640)
sumó `date` y `printf`, ya requeridos por su propia doctrina (marcas de
tiempo de sesión, cierre documental) y ausentes hasta entonces del registro.
El agente `projections-scaffolder` (issue #1652) sumó `basename`.
El agente `bug-investigator` (issue #1667) sumó `diff`, que compara los ensamblados decompilados bajo `{{mefisto:state-path tmp}}` (nunca `/tmp`, bloqueado por `external_directory`); `az` sigue denegado y sus consultas pasan por `appinsights-query.sh` (`plan-sites`/`plan-metrics`).
El agente `test-writer` (issue #1813) suma `cut` para extraer la ruta del caché global de NuGet en su fallback de decompilación; es una utilidad de lectura de la misma familia que `tr`, `head` y `sort`, no una ampliación del shell genérico.

El contrato de candidatos está pinneado a OpenCode 1.18.29,
tree-sitter-bash 0.25.0 y web-tree-sitter 0.25.10. El recolector visita nodos
`command`; cuando su padre inmediato es `redirected_statement`, evalúa los
bytes de ese padre, y en otro caso los bytes del `command`, tras recortar solo
los extremos. Por tanto preserva asignaciones inline, comillas, espacios y
redirecciones. `declaration_command`, asignaciones aisladas, tests bracket y
definiciones de función no son candidatos por sí mismos; sus comandos hijos,
incluidas sustituciones ejecutables, sí se recorren.

Cada `run` publicado se emite como una regla por script concreto con el prefijo
literal `MEFISTO_RUNTIME=opencode` y la ruta entre comillas. No existe una
regla genérica para `${MEFISTO_PACKAGE_ROOT}/scripts/*`, ni se insertan
comodines entre la asignación y el ejecutable. El preámbulo de package-root
permite solamente su consulta de launcher y diagnósticos necesarios. El de
lifecycle está aplanado a asignaciones, `if` y `OSTYPE`; sus únicas llamadas
permitidas son `projection-status`, `project` y `deactivate`. Cada llamada que
usa variables resueltas incluye su propio preámbulo.

`test-opencode-bash-permissions.sh` consume el corpus versionado
`scripts/tests/fixtures/bash-candidates/opencode-1.18.29.json`, verifica bytes
en los artefactos generados y evalúa los candidatos mediante la biblioteca
`opencode-entry-permissions.jq` (#1838). No es un parser Bash, no descarga
dependencias ni ejecuta OpenCode. El corpus cubre asignaciones, declaraciones,
bracket tests, `cd`, pipes/listas, redirecciones, sustituciones y funciones;
un cambio de forma requiere caracterización explícita.

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

El matcher conserva que `*` cruza `/` y decide por la última coincidencia. Esto
es una contención léxica de candidatos caracterizados, no un sandbox ni una
certificación de todos los efectos de un proceso. Permanecen denegados shell
genérico, `env`, `eval`, `source` arbitrario, `curl` directo, `sudo`/`ssh`/`scp`,
Terraform `plan`/`apply`/`destroy` e `init` sin `-backend=false` o con un
segundo backend.

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
comandos publicados. Todas las filas declaran los recursos legibles base
`project`, `release`, `state` y `runtime-tool-output`; `state` no concede
escritura, que sigue determinada exclusivamente por `edit` y `writeScope`.
`fix-review` declara además `nuget-packages`. `command-entry.jq` comprueba ids,
campos cerrados, referencias `command-doc` y `launch-agent`, ciclos y calcula
la clausura de composición. También cierra `executionClass`: la ejecución
ordinaria o los parsers puros y sin evaluación `runtimes-v1` y `upgrade-v1`.
La clasificación rechaza ids ajenos al inventario y formas no canónicas,
repetidas, mezcladas o desconocidas. La clausura une necesidades de comandos compuestos; nunca hereda
las capacidades de un agente delegado ni interpreta
`{{mefisto:command ...}}` como llamada. Sí enumera los agentes alcanzables para
que esa topología pueda verificarse sin convertirla en capacidades del padre.
El adaptador OpenCode emite `command-entry-manifest.json`: hashes SHA-256 del
contenido Markdown renderizado y recortado por el loader, sin incluir cuerpos,
el binding nativo observado y el binding legacy derivado de la semántica
neutral anterior. Si el renderer no expone el header nativo, su valor es
`null`; los metadatos se validan separadamente del body. Su huella técnica
permite revalidar snapshots, no equivale a admisión, certificación ni
consentimiento.

## Roles de ejecución controlada

`agent-execution.json` es el inventario neutral cerrado de los 22 agentes
publicados. Declara solamente ownership (`writeScope`), recursos y las tablas de
pipelines/raíces autorizantes; capacidades, MCP y Skills se derivan del
frontmatter actual y no se duplican. La generación rechaza agentes faltantes,
desconocidos, duplicados, `writeScope` incoherente con `edit`, o una llamada real
del runner que no corresponda a las tablas TDD, tooling, IaC o scaffold.

OpenCode recibe `agent-execution-manifest.json`, generado desde el renderer
actual. Cada rol conserva su metadata renderizada, el digest SHA-256 del body
recortado y el alias oculto `autonomy-<id>` para ejecución controlada. El alias
no sustituye el id original ni acredita por sí mismo ownership; su admisión la
deciden las raíces declaradas. El manifest no serializa modelos u overrides del
consumidor.

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

## Observación de procesos registrados

`src/published/scripts/lib/release-use-process.sh` se carga sin efectos y expone
`release_use_process_capture <pid>` y `release_use_process_observe`. La captura
emite una identidad JSON versión 1 local al host: hash de la identidad de host,
boot, PID, token de inicio y PGID. La observación recibe esa identidad por stdin
y emite exclusivamente JSON con `state` (`live`, `gone` o `unknown`),
`groupState` (`live`, `empty` o `unknown`) y una razón estable. Su código 0
incluye `unknown`; 2 indica uso o protocolo inválido.

En Linux usa `machine-id`, `boot_id` y metadata de `/proc`; en macOS usa el
identificador de plataforma, `kern.bootsessionuuid` y columnas `uid`, `lstart`
y `pgid` de `ps` con locale y zona horaria fijos. Nunca consulta argv, entorno,
comando ni archivos abiertos, no usa TTL, no crea archivos ni envía señales.
Un host distinto, metadata ausente o ambigua, o un fallo de observación conserva
`unknown`. Un reboot verificable del mismo host prueba la terminación de los
procesos del boot anterior. La precisión limitada de `lstart` conserva una
posible colisión como retención, no como prueba de muerte.

El observador no certifica la completitud del árbol histórico: un proceso que
creó otra sesión puede sobrevivir aunque el PID original haya terminado y su
PGID esté vacío. Tampoco libera locks o leases; el caller debe combinar esta
evidencia con su grafo de referencias, handoffs y cobertura de lanzamientos
(MEF-ADR-0031, MEF-ADR-0050 y MEF-ADR-0053).

## Descubrimiento de recursos NuGet

`scripts/resolve-nuget-resources.sh --worktree-root <raíz-absoluta>` consulta
la carpeta `global-packages` con el único argv documentado de la CLI y observa
los `obj/project.assets.json` v3 del worktree. Puede sumar
`--assets-file <archivo-absoluto>` para layouts personalizados. Devuelve un
envelope JSON versión 1 con `resolved`, `unavailable` o `conflict`, las roots
lógicas/físicas deduplicadas y su procedencia, hashes y rutas relativas de los
assets, sin volcar configuración, endpoints ni salida cruda de la CLI.

La cobertura `global-only` no certifica un restore; `observed-assets` describe
solamente las carpetas registradas por esos assets en ese instante. El resolver
no ejecuta restore, build ni evaluación de proyectos, no lee configuración de
NuGet y no crea directorios. Rechaza roots amplias y assets explícitos ausentes,
corruptos o fuera del worktree físico. Se distribuye junto con
`src/published/scripts/lib/resource-paths.sh`, que conserva su ruta relativa
para que el script sea una clausura autocontenida (MEF-ADR-0031 y MEF-ADR-0053).
Invoca exclusivamente `dotnet nuget locals global-packages --list
--force-english-output`, por argumentos y desde la raíz física indicada. Usa 0
para `resolved`, 1 para `unavailable`/`conflict` con envelope JSON y 2 para uso
o protocolo inválido; nunca sustituye una consulta fallida por el home.

## Descubrimiento de raíces OpenCode

`scripts/adapters/lib/opencode-resource-roots.sh` es una biblioteca pura que se
carga después de `scripts/lib/resource-paths.sh` y expone
`opencode_resource_roots <loaded-release-root>`. Recibe por stdin un
envelope JSON versión 1 con `platform`, `osHome`, `home`, los overrides XDG y
`opencodeConfigDir`; `null` expresa ausencia y el string vacío conserva su
semántica. `osHome` es la observación del sistema y nunca se sustituye por
`home`. La salida contiene raíces lógicas/físicas observadas, la release que
cargó el caller y el estado del ledger propio; retorna 0 para `resolved`, 1
para `conflict` con envelope válido y 2 para protocolo inválido.

La tabla verificada para OpenCode 1.18.29 usa `XDG_DATA_HOME/mefisto` o el
fallback de Mefisto por plataforma; los datos del runtime son
`XDG_DATA_HOME/opencode` o `osHome/.local/share/opencode`, también en macOS.
La única clase candidata de lectura global es su `tool-output/`, cuyo registro
lleva `exists: false` si falta y que nunca se crea ni enumera. Configuración usa
primero `OPENCODE_CONFIG_DIR`, luego `XDG_CONFIG_HOME/opencode` y finalmente
`osHome/.config/opencode`; overrides vacíos, relativos o no representables son
conflictos. Esta observación no lee `opencode.json`, proveedores, credenciales,
logs ni sesiones y no sustituye una admisión de recursos (MEF-ADR-0031).

La release se verifica contra su propio `mefisto-manifest.json` y debe ser la
release física del almacén efectivo. `active` solo produce diagnóstico de
deriva: nunca reemplaza la release cargada. El ledger se lee sin invocar el
proyector y solo se siguen metadatos de los enlaces que declara, incluido su
target canónico mediante `active`; `absent`,
`drift` y `conflict` no equivalen a alineación ni reparan el estado. Es una
instantánea sin defensa contra TOCTOU; una versión futura del runtime con otra
semántica de raíces requiere revalidación antes de reutilizar este oráculo.

## Snapshot de recursos OpenCode

`scripts/resolve-opencode-resources.sh --project-root <raíz-aprobada> --worktree-root <raíz-de-ejecución>`
(release OpenCode, wrapper de `src/published/scripts/adapters/lib/opencode-resources.sh`) ensambla
el descriptor de recursos de una corrida controlada. Recibe por stdin un envelope cerrado:
`schemaVersion: 1`, `runtimeContext` (los campos de las raíces del host más `directory` y
`worktree` absolutos observados por el plugin), `requiredResources` (ids cerrados `release`,
`project`, `state`, `runtime-tool-output`, y `nuget-packages` solo si el caller lo declara) y
`nugetAssetsFiles`. El caller confiable deriva esos requisitos de su matriz; ni un issue ni una
tool call los amplían, y la release es siempre la que contiene al wrapper.

La salida es `resolutionScope: resources` con `status` `disabled|needs-approval|ready|conflict`,
`projectId`, `profileDigest`, `resourcesDigest`, `release`, `project`, `permissionBase`,
`resources`, `protectedRoots`, `projection`, `nuget` y `diagnostics` (solo códigos, sin volcar
entradas, configuración ni stderr). Exit 0 para `disabled`/`ready`, 1 para
`needs-approval`/`conflict` con envelope válido y 2 para uso o protocolo inválido. `disabled` y
`needs-approval` no entregan recursos; `NO_PROFILE` y `CONSENT_REVOKED` se distinguen en
`diagnostics`, y la revocación no autoriza un fallback.

Cada recurso lleva `id`, `root` física, `exists`, `maxAccess` (`read|project|state`, un límite de
clase y **no un grant**: el rol conserva su `writeScope`), `relativeRoot` calculado contra el
`worktree` lógico exacto, `aliases` verificados, `excludedPaths` y procedencia. Hay filas
múltiples `project`/`state`/`nuget-packages`, identificadas por `id` + `root`. La carpeta
`tool-output` completa del runtime es una clase `read` (decisión expresa del mantenedor: incluye
resultados de otras sesiones, que pueden ser sensibles); `protectedRoots` conserva config,
datos del runtime, `runtime-use/`, credenciales del home y los contextos de autonomía, con esa
única excepción. Un consumidor debe usar ambas formas del candidato: la relativa al `worktree`
(lectura) y la absoluta + `/*` (directorio externo). `ready` significa recursos solicitados
descritos y verificados: no es permiso efectivo, restore fresco ni admisión de una operación.

`resourcesDigest` es el SHA-256 del snapshot de datos canónico (release, base, roots, aliases,
exclusiones, ledger y hashes de assets); excluye existencia, contenido o listado de
`tool-output` y timestamps, de modo que crear una salida no invalida la autorización. Los
errores de projection (`absent`, `drift`, `conflict`) impiden un `ready` nuevo y nunca cambian
`active` ni adoptan otra release. Se prueba con `src/published/scripts/tests/test-opencode-resources.sh`
(MEF-ADR-0031, MEF-ADR-0050 y MEF-ADR-0055).

## Proyección de permisos por rol (alias controlados)

`scripts/resolve-agent-execution.sh < envelope.json` (release OpenCode, wrapper de
`src/published/scripts/adapters/lib/opencode-agent-projection.sh` y su programa `.jq`) compila la
política propia de cada alias `autonomy-<id>` (#1856, sobre #1853/#1838/#1825). Solo calcula: no
aplica config, no autoriza una sesión, no escribe, no usa SDK, LLM ni red, y los agentes originales
no cambian. Corre desde la release copiada (manifest + inventario `agent-execution.json` + la
biblioteca `opencode-entry-permissions.jq` empaquetada), sin source checkout.

Entrada cerrada `schemaVersion: 1`: `phase` (`config|verify`), `profile`, `snapshot` (salida
`ready` de `resolve-opencode-resources.sh`), `home`, `roles` (`role`, `taskTargets` exactos y, para
roles con shell, `attach` con `executable`/`pid`/`controlRoot`/`request` y `suffix` literal opcional),
`originals` (hash de prompt, `mode`, `permission`/`tools` ya normalizados, sin modelo, provider ni
prompt), `globalPolicy` (conocida; `null` es conflicto), `sessionPolicy` (`null` si no se observó),
`collisions` (alias ocupados) y, opcionales, `entryTaskPolicies` (`entryId`, `targets`, `digest` =
SHA-256 de `{entryId,targets}` canónico y ordenado) y `observed` (solo en `verify`: `name`, `mode`,
`promptHash`, `rules` ordenadas efectivas y `available`).

Salida: `status` `ready|conflict`, `admissionScope: agent-projection`, `catalogDigest`,
`resourcesDigest`, `projectionDigest` (calculado por el helper sobre reglas ordenadas; el SDK no lo
entrega), `actors` (`originalId`, `alias`, `permission`, `taskBindings`), `entryTaskBindings` por
`entryId` y `diagnostics` (solo código y rol, sin prompts, config ni patrones). En `verify` agrega
`observations` con el digest de la imagen observada. Exit 0 ready, 1 conflicto, 2 protocolo.

Reglas: la política estática propia del original (idéntica a la del manifest) se reemplaza por su
forma dinámica; cualquier divergencia de prompt, `mode`, `permission` o `tools` es conflicto y
nunca se borra un override del usuario. `M` se deriva de `writeScope`/recursos del rol y se compone
con la política global mediante `opencode-entry-permissions.jq` (#1838, sin segundo matcher). `read`
y `edit` usan `relativeRoot`; `external_directory`, raíces absolutas. Solo el execution-root y su
estado son editables, con exclusiones y raíces protegidas denegadas; `tool-output` es solo lectura y
NuGet solo para roles que lo declaran. Task exige que el destino original y su alias no sean `deny`
(el original además debe permitirlo); el par original/alias queda con la misma decisión y los
comodines de sesión cuya contención no se demuestre son conflicto. Los roles shell reciben solo el
prefijo de `execution-context.sh attach` de la release (PID y request bajo el `controlRoot`), nunca
prepare/approve/finish genéricos. Se prueba con
`src/published/scripts/tests/test-opencode-agent-projection.sh` (MEF-ADR-0050, MEF-ADR-0053,
MEF-ADR-0055).

## Matriz de verificación de fuentes

`source-verification.json` declara las vías suficientes para cada uno de los 22
roles publicados. Sus opciones son alternativas suficientes **dentro de cada
caso**, no grants: una URL citada por un issue no añade permisos. Comprobaciones
distintas, como listar una versión de WorkOS y compilar contra sus firmas, viven
en casos separados. El helper puro `scripts/lib/source-verification.jq` recibe
matriz, registro MCP, frontmatters ya extraídos y los casos condicionales que el
cambio exige; no lee disco, red, reloj ni credenciales.

```bash
src/published/scripts/validate-source-verification.sh
src/published/scripts/validate-source-verification.sh --require planner/non-microsoft-official
```

La salida por caso es `declared`, `capability-missing`,
`external-unobserved` o `not-required`. `declared` prueba solo metadata:
contenido/fuente suficiente, tool descubierta y permiso efectivo de una sesión
son tres fronteras distintas. Un MCP externo declarado queda
`external-unobserved`; una tool web o MCP no certifica conexión, discovery ni
autorización efectiva. El preflight posterior verifica disponibilidad derivada
del rol y del plan, no certifica una sesión futura al generar este JSON.

Las distribuciones incluyen la matriz, el helper y el registro MCP neutral que
lo alimenta. El entrypoint anterior es una comprobación de mantenimiento del
checkout fuente: extrae sus frontmatters neutrales; no se empaqueta como si
pudiera reconstruirlos desde metadata ya adaptada de una instalación.

Los casos condicionales solo se evalúan cuando el cambio los requiere. Los gaps
que aún no se han resuelto siguen visibles como `capability-missing` al
requerirlos; los issues #1878, #1879, #1880, #1881, #1882 y #1883 cubren esas
capacidades por rol. La metadata solo declara rutas y permisos: las tool calls
efectivas se verifican en #1847 y la conectividad MCP/web real en #1827.

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

## Binding de entrada OpenCode

El adaptador OpenCode emite `plugins/mefisto-command-entry.js` (asset
`command-entry-plugin`) y, solo en los comandos distribuidos, las cabeceras
`agent: command-entry-<id>` y `subtask: false`; los Markdown neutrales no
declaran `agent` ni `capabilities` y el adaptador Claude no cambia. El plugin
solo enlaza una proyección ya resuelta por el resolver de la entrada
(`scripts/resolve-opencode-entry.sh`, invocado por argv con `--phase
config|command`, `--project-root` y un `--context` JSON acotado con el
`runtimeContext` capturado en el proceso); no crea perfiles, no aprueba ni
compila políticas. Responde `admissionScope: entry`, que nunca equivale a
consentimiento administrativo.

- Hook `config`: instala en memoria los agentes `command-entry-<id>`
  (`mode: primary`, sin modelo, sin tocar `default_agent`) para todo el
  catálogo, con `admitted: false`, incluidos los no aprobados con permisos
  denegados. Solo `NO_PROFILE` inicial sin contexto controlado ni proyección
  previa restaura la semántica legacy quitando los campos de routing propios;
  `CONSENT_REVOKED`, `needs-approval`, `conflict`, retiro del perfil en una
  instancia activada, colisión de ownership, identidad de release distinta de
  su manifiesto o fallo del resolver producen no-admisión, nunca el agente
  activo. Aplicación atómica e idempotente; no-op en el repo del harness.
- Hook `command.execute.before`: solo revalida. Consulta `permission` y
  `directory` de la sesión (`sessionPolicyKnown`, `sessionProjectMatches`; una
  consulta fallida no equivale a reglas vacías), reutiliza el resolver en fase
  `command` y exige `admitted: true` de la fila solicitada y el mismo snapshot.
  No selecciona agente ni es un sandbox.
- La certificación con runtime real y el control Claude pertenecen a #1827; las
  pruebas (`test-opencode-command-entry.sh`) usan dobles de SDK y resolver.

## Contexto de ejecución y handoffs del consumidor

`scripts/execution-context.sh` es el broker durable de contextos de ejecución de
la autonomía del consumidor (MEF-ADR-0055); `scripts/_execution-context.sh` es la
biblioteca sourceable de callbacks para pipelines. Hacer `source` no tiene
efectos. Ninguna variable heredada de tmux ni marker ajeno acredita autorización:
todo caller valida contra el archivo y contra el digest de su referencia.

Archivo propio por contexto, regular y sin seguir symlinks:
`<raíz-aprobada>/.mefisto/pipeline/autonomy/runs/<run-id>/contexts/<context-id>.json`.
Se escribe de forma atómica con CAS por `state.revision` bajo un lock `mkdir`;
un lock huérfano responde `busy` (75) y nunca se limpia por TTL. El modo local no
lo vuelve inaccesible a procesos del mismo usuario: un hash no es identidad
humana ni sandbox.

- `contract` inmutable (schemaVersion, runId/contextId/parentContextId,
  projectId/profileDigest, rootCommand, pipelineKind/logicalStage/originalAgent/
  alias, release, allowedRoles/allowedPipelines, clases de recursos derivadas del
  catálogo, approved/execution roots, runtime esperado, leaseId, nonce).
  `contractDigest` excluye estado y timestamps; la autoedición se detecta contra
  el digest de la referencia de uso (variable de transporte o ancla del padre),
  no contra el checksum del propio archivo.
- `state`: `prepared|attached|finished|conflict`, `revision`, sesiones,
  hijos, recibos de handoff y `entryAdmission` opcional. `observations` por nonce
  conserva `resourcesDigest`/`permissionBase`/`permissionImageDigest`/proyección.
  Sin prompts, modelos, tokens, datos de negocio ni auth stores.

Operaciones (request/respuesta JSON `schemaVersion: 1` por stdin/stdout; exit 0
ready/disabled/finished, 75 busy, 1 conflicto, 2 uso/protocolo):

| Operación | Efecto |
|---|---|
| `prepare` | Valida runtime, `inspect` (status y `reasonCode`), `rootCommand` aprobado y su `executionClass` del catálogo, pipeline/rol. Claude o `NO_PROFILE` → `disabled` sin archivos. `maintenance/query/prune` solo para clases `by-operation` y nunca dentro de un execute vivo del run |
| `reserve-child` | Reserva anterior al dispatch: el hijo solo reduce alcance, exige worktree registrado del mismo repositorio y queda anclado (digest) en el padre |
| `attach [--owner-pid <pid>]` | Vincula PID/identidad antes de efectos o modelo; idempotente para el mismo owner; reserva retirada → `HANDOFF_LATE` |
| `validate` | Revalida consentimiento, identidad, release y anclas; revocación o deriva impiden nuevas admisiones sin matar trabajo lanzado |
| `bind-session` | Vincula `sessionID` → contexto/rol/stage/release; `mode: resume` exige vínculo y huellas compatibles (sin fresh start silencioso) |
| `record-entry-admission` | Guarda solo el veredicto acotado de la entrada `source: command`; exige nonce del controlador, contexto raíz y sesión vinculada; un hijo no lo fabrica |
| `refresh-observations` | Escritura explícita distinta de `validate`: actualiza evidencia del mismo nonce solo si `permissionImageDigest` no cambia; otro cambio exige nueva admisión |
| `finish` | Cierre del controlador, no prueba de CAs; no cierra hijos vivos (`liveChildren`, `leaseReleased`); la cobertura de descendencia no demostrada queda `recovery: unknown` |

Callbacks: `published_execution_open <pipeline-kind> <project-root> <package-root>`
valida/adjunta el contexto transportado (`MEFISTO_EXECUTION_CONTEXT` y
`MEFISTO_EXECUTION_DIGEST`, solo ruta y digest) contra la raíz aprobada del propio
contexto, o prepara una raíz standalone; publica `MEFISTO_EXECUTION_ENABLED` sin
escribir a stdout. Un contexto que no valida impide admisiones y nunca degrada a
legacy; solo la ausencia de contexto y de perfil (o runtime Claude) conserva el
flujo previo. `published_execution_close <outcome>` cierra solo el uso propio.

Dependencias abiertas: el registro/recuperador de #1852 aporta la reserva y
retención del `leaseId`; este broker solo lo referencia y deja el recibo
incompleto como `unknown`, sin habilitar recuperación automática.

## Binding OpenCode del snapshot de recursos (#1847)

`plugins/mefisto-command-entry.js` es el unico propietario del binding. Con
contexto de ejecucion (`MEFISTO_EXECUTION_CONTEXT` con la ruta del contexto y
`MEFISTO_EXECUTION_DIGEST`, el mismo contrato que `_execution-context.sh`,
definidos antes de cargar el plugin; el broker se invoca con la raiz aprobada
que contiene esa ruta) instala los
alias `autonomy-<id>`, escribe `runtime-ready.json` (junto al contexto, en
`<contextId>/`) y activa los hooks `chat.params`, `chat.message`,
`tool.execute.before` y `shell.env`. Sin contexto conserva el flujo legacy. El
guard no es sandbox ni cubre la interpolacion previa del comando. El pin
`MEFISTO_LOADED_RELEASE_ROOT` viaja solo por llamada y el preambulo OpenCode
aborta si hay contexto sin pin valido. Pruebas:
`src/published/scripts/tests/test-opencode-binding-guard.sh`.

## Launcher de etapas publicadas preparadas (#1858)

`scripts/run-published-agent.sh --pipeline <tdd|tooling|iac|scaffold> --context <ruta> --context-digest <sha> [--startup-timeout <s>] -- <argv del runner neutral>`
lanza una etapa OpenCode solo despues de verificar la instancia privada que la ejecutara
(MEF-ADR-0055). Corre desde la clausura de su propia release: broker, resolvers, runner y
biblioteca de servicio salen de esa release; un override del runner es incompatible, no un bypass.
No inicia este modo por la presencia de OpenCode en PATH, no invoca `approve` y no concede
consentimiento. Sin perfil o con Claude los callers conservan su invocacion previa.

Secuencia: (1) valida contexto/rol/pipeline/release y deriva el alias `autonomy-<rol>` del
catalogo (el caller no pasa `--runtime-endpoint` ni `--execution-agent`); (2) reserva un contexto
hijo con nonce propio (`reserve-child` + `attach`) antes del spawn e inicia un servicio privado
con ese contexto; (3) `GET /agent` sobre la misma instancia, alias unico y no `subagent`, espera
el `runtime-ready.json` del hijo dentro del plazo (30 s por defecto, 1-300) y compara
nonce/digest/release/proyecto/alias/`projectionDigest`/PID de instancia contra el servicio propio y
contra la observacion registrada en el broker; la observacion acotada (`name`, `mode`, hash de
prompt, reglas) pasa por `resolve-agent-execution.sh` en fase `verify` (#1856); (4) cualquier
fallo -- plugin ausente, config ignorado, alias ausente/subagent, ready ajeno o stale, error de SDK,
sesion no verificable -- sale con **78** y `invocationStatus: not-started` en
`<run>/launcher/<intento>.json`, sin invocar el runner (un SDK error no es una lista vacia
conocida); (5) solo entonces invoca el runner con sus argumentos originales mas
`--runtime-endpoint`/`--execution-agent`; el guard `chat.params` del binding rechaza un fallback
del CLI antes del modelo. `--resume-session` exige `bind-session` en modo `resume` del broker y
metadata SDK de la sesion (mismo `directory`); nunca degrada a sesion nueva.

Salida: stdout es el del runner; el exit despues de iniciar es el del runner (cancelacion: 143); una cancelacion antes de entregar el prompt aborta el preflight con 78 `not-started`.
Preflight no iniciado: 78; contexto/reserva ocupados: 75. Al cierre confirma el cierre del
servicio por PID/identidad propios (`runtime_service_stop`); si queda desconocido registra
`cleanup: unknown` y conserva la referencia hija. La referencia padre nunca se libera aqui (hold/
retry). Cada intento tiene nonce e identidad nuevos. Limitaciones: la politica global del verify
se toma del `permission` de `opencode.json` del proyecto (ausente = vacia, ilegible = fallo); la
configuracion global del usuario no se lee. La certificacion instalada queda en #1827. Pruebas:
`scripts/tests/test-run-published-agent.sh` (dobles; sin runtime, LLM ni red).

## Proyección de entrada por comando (#1836)

`scripts/resolve-command-entry.sh --project-root <raíz>` (biblioteca `opencode-command-entry.sh` + programa `.jq`) ensambla la proyección OpenCode de entrada de los 27 comandos publicados. Solo calcula: no escribe config, consentimiento ni recursos, no aprueba ni revoca y su clausura es la propia release (`command-entry-manifest.json`, `src/published/contract/command-entry.json`, `opencode-entry-permissions.jq` de #1838); no consulta un checkout.

- **Entrada** (un objeto JSON por stdin): `schemaVersion: 1`, `phase: config|command`, `home`, `configPolicyKnown`, `runtimeContext` (el de `resolve-opencode-resources.sh`; su `home` debe coincidir), `nugetAssetsFiles`, `commands` (`name`, `sourceDigest`, `agent`, `subtask` observados), `delegateAgents`, `foreignEntryAgents`, `permission` (política ya normalizada por el runtime, o null) y, en `command`, `requestedCommand`, `sessionPolicyKnown`, `sessionProjectMatches`, `sessionPermission`. Una sesión no observada es desconocida, nunca `[]`.
- **Secuencia**: inspect del perfil (sin perfil o consumidor ajeno: `disabled` legacy; `CONSENT_REVOKED` conserva su motivo y las filas denegadas) → recursos de la misma release derivados de las filas aprobadas → ownership por hash del cuerpo con `trim()` y de los destinos Task → política propia por la clausura de `composes` → composición ordenada con #1838 → operaciones requeridas y controles negativos.
- **Salida**: `status: disabled|needs-approval|ready|conflict`, `admissionScope: entry`, digests (`catalogDigest`, `resourcesDigest`, `projectionDigest` con el orden de las reglas), `agents` (`command-entry-<id>`, primarios, ocultos, sin modelo, reglas ordenadas) y `bindings` (`mefisto:<id>`, `subtask: false`, `admitted`). En `config` todos los bindings llevan `admitted: false`; en `command` solo la fila solicitada puede admitirse. Una fila no aprobada conserva un agente con permisos denegados. Exit 0 disabled/ready, 1 needs-approval/conflict, 2 protocolo.
- **Plantillas shell por comando**: la política shell de cada fila se deriva de `src/published/contract/command-shell-templates.json` (`{schemaVersion:1, commands:{<id>:[patrón…]}}`), contrato **generado** por el adaptador OpenCode (asset `command-shell-templates`, `--check` detecta divergencia) y empaquetado en la release; no se edita a mano. Cada fila de `command-entry.json` declara opcionalmente `shellExtra` (array de strings, default `[]`) con los patrones de los comandos que el documento ejecuta fuera de `{{mefisto:run …}}` (p. ej. `batch-stop`: `git rev-parse*`, `pgrep -f*`, `mkdir -p*`, `touch*`); no se extraen de los bloques ```bash. El adaptador une, por comando, un patrón estrecho por cada `{{mefisto:run X …}}` del documento (`MEFISTO_RUNTIME=opencode "${MEFISTO_PACKAGE_ROOT}/scripts/X"*`, nunca `*` sobre el script) con su `shellExtra`, ordenado y sin duplicados. No copia la política `bash` global de los agentes (`opencode-permissions.json`) ni un permiso shell de un worker. `test-command-shell-templates.sh` afirma que ningún patrón es `*` y que cada comando raíz de los bloques ```bash de `commands/<id>.md` queda cubierto por algún patrón de su fila.
- `ready` es una proyección de entrada verificable: no autoriza una purga, recursos cloud ni una tarea, y no es un sandbox ni RBAC de acciones administrativas.
